import Foundation
import Darwin
import CryptoKit

/// A binary delivery is deliberately smaller than a source checkout. The same layout is
/// enforced before publishing and after signature verification by the installer.
public enum ManagedPayloadRules {
    public static func requiredPaths(for product:ManagedReleaseProduct,format:Int=1)->Set<String> {
        var result:Set<String>=[product.entrypoint,"LICENSE","NOTICE"]
        if product == .advancedCLI {
            result.formUnion(["publisher.pub","licenses/VideoAdvanced.txt","licenses/VideoGame.txt","licenses/VideoCartoon.txt"])
            if format==1{result.insert("render-catalog.videomodules")}
            if format==2{for id in PluginPackageRules.moduleSuffixes.keys{let prefix=try! PluginPackageRules.packagePath(pluginID:id)+"/";result.formUnion(try! PluginPackageRules.requiredPaths(pluginID:id).map{prefix+$0});result.formUnion([prefix+PluginPackageRules.manifestName,prefix+PluginPackageRules.policyName])}}
        }
        return result
    }
    public static func allowedPaths(for product:ManagedReleaseProduct,format:Int=1)->Set<String> {
        var result=requiredPaths(for:product,format:format).union(["bin/video-install"])
        if product == .advancedCLI && format==2{for id in PluginPackageRules.moduleSuffixes.keys{let prefix=try! PluginPackageRules.packagePath(pluginID:id)+"/";result.formUnion(try! PluginPackageRules.allowedPaths(pluginID:id).map{prefix+$0})}}
        return result
    }
    public static func executablePaths(for product:ManagedReleaseProduct,format:Int=1)->Set<String>{
        var result:Set<String>=[product.entrypoint,"bin/video-install"]
        if product == .advancedCLI && format==2{for id in PluginPackageRules.moduleSuffixes.keys{let prefix=try! PluginPackageRules.packagePath(pluginID:id)+"/";result.formUnion(try! PluginPackageRules.executablePaths(pluginID:id).map{prefix+$0})}}
        return result
    }
    public static func validate(_ files:[ManagedReleaseFile],product:ManagedReleaseProduct,format:Int=1)throws {
        guard format==1 || (format==2 && product == .advancedCLI) else{throw VideoError.invalid("未知二进制发行布局，未回落旧格式")}
        let paths=Set(files.map(\.path)),required=requiredPaths(for:product,format:format)
        guard paths.count==files.count,required.isSubset(of:paths),paths.isSubset(of:allowedPaths(for:product,format:format)) else {
            throw VideoError.invalid("二进制发行库存缺少许可/声明或包含未允许文件；源码、调试映射、用户许可证和凭据不能进入发行payload")
        }
        for file in files {
            let isExecutable=executablePaths(for:product,format:format).contains(file.path)
            guard file.executable==isExecutable else{throw VideoError.invalid("发行文件执行权限与固定入口不符")}
            if !isExecutable {
                guard file.bytes>0,file.bytes<=2*1024*1024 else{throw VideoError.invalid("发行许可、公钥或目录文件为空或超过2MiB")}
            }
            if file.path=="publisher.pub" && file.bytes != 32{throw VideoError.invalid("发行公钥须为32字节")}
        }
    }
}

public enum ManagedPayloadPreparation {
    private static func readSource(_ source:URL,name:String,copyTo:FileHandle?=nil)throws->ManagedReleaseFile {
        try ManagedReleaseRules.safeDirectory(source.deletingLastPathComponent())
        // Open before inspecting, and never follow a last-component link. A FIFO must not
        // block the release process before fstat can reject it as a non-regular source.
        let descriptor=open(source.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        guard descriptor>=0 else{throw VideoError.permission("payload来源不能安全打开；未读取链接目标")}
        defer{close(descriptor)}
        var attributes=stat()
        guard fstat(descriptor,&attributes)==0,attributes.st_mode&S_IFMT==S_IFREG,attributes.st_nlink==1,
              attributes.st_size>0,attributes.st_size<=512*1024*1024 else {
            throw VideoError.permission("payload来源须为有限的普通单链接文件；没有复制链接目标")
        }
        let input=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
        var total=0,hasher=SHA256()
        while let bytes=try input.read(upToCount:1024*1024),!bytes.isEmpty {
            guard bytes.count<=512*1024*1024-total else{throw VideoError.permission("读取期间payload来源增长超限；未发布候选目录")}
            total+=bytes.count;hasher.update(data:bytes);try copyTo?.write(contentsOf:bytes)
        }
        var after=stat()
        guard fstat(descriptor,&after)==0,total==attributes.st_size,after.st_size==attributes.st_size,
              after.st_nlink==1,after.st_mode==attributes.st_mode else{throw VideoError.permission("读取期间payload来源大小或权限变化；未发布候选目录")}
        return ManagedReleaseFile(path:name,sha256:hasher.finalize().map{String(format:"%02x",$0)}.joined(),bytes:total,executable:attributes.st_mode&0o111 != 0)
    }
    /// Prepare a new exact file set, without signing, Keychain access, execution or replacing
    /// an existing payload. The caller validates native code/catalog bytes in the staging
    /// directory before the single exclusive rename makes those bytes visible.
    @discardableResult
    public static func prepare(product:ManagedReleaseProduct,sources:[String:URL],output:URL,
                               format:Int=1,validate:(_ staged:URL,_ files:[ManagedReleaseFile])throws->Void)throws->[ManagedReleaseFile] {
        let fm=FileManager.default,target=output.standardizedFileURL,parent=target.deletingLastPathComponent()
        try ManagedReleaseRules.safeDirectory(target)
        guard !fm.fileExists(atPath:target.path) else{throw VideoError.conflict("payload输出已存在，原内容保留；请选择新的明确目录")}
        guard Set(sources.keys).isSubset(of:ManagedPayloadRules.allowedPaths(for:product,format:format)),
              ManagedPayloadRules.requiredPaths(for:product,format:format).isSubset(of:Set(sources.keys)) else {
            throw VideoError.invalid("payload来源集合不符合固定产品边界")
        }
        var expected:[ManagedReleaseFile]=[]
        for name in sources.keys.sorted() {
            try ManagedReleaseRules.relativePath(name)
            expected.append(try readSource(sources[name]!.standardizedFileURL,name:name))
        }
        try ManagedPayloadRules.validate(expected,product:product,format:format)
        try fm.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let staged=parent.appendingPathComponent(".video-payload-stage-"+Codec.id())
        try fm.createDirectory(at:staged,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? fm.removeItem(at:staged)}
        for file in expected {
            let destination=staged.appendingPathComponent(file.path)
            try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let permissions:mode_t=file.executable ? 0o700:0o600
            let descriptor=open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,permissions)
            guard descriptor>=0 else{throw VideoError.permission("无法建立独立payload候选文件；未覆盖任何目标")}
            do {
                defer{close(descriptor)}
                guard fchmod(descriptor,permissions)==0 else{throw VideoError.permission("无法设置payload候选文件权限")}
                let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
                guard try readSource(sources[file.path]!,name:file.path,copyTo:handle)==file else{throw VideoError.permission("复制期间payload来源已变化；未发布候选目录")}
                try handle.synchronize()
            }
        }
        let actual=try ManagedReleaseRules.inventory(staged)
        guard actual==expected else{throw VideoError.permission("复制期间payload来源已变化；未发布候选目录")}
        try validate(staged,actual)
        // Validation may read arbitrary structures but must not mutate any staged bytes.
        guard try ManagedReleaseRules.inventory(staged)==expected else{throw VideoError.permission("验证期间候选payload变化；未发布目录")}
        try ManagedReleaseRules.safeDirectory(target)
        let status=staged.path.withCString {source in target.path.withCString {destination in
            renameatx_np(AT_FDCWD,source,AT_FDCWD,destination,UInt32(RENAME_EXCL))
        }}
        guard status==0 else{throw VideoError.conflict("payload目标已存在或原子发布失败；原目标保留")}
        let descriptor=open(parent.path,O_RDONLY);if descriptor>=0{_=fsync(descriptor);close(descriptor)}
        return expected
    }
}
