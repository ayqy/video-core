import Foundation

public enum ManagedReleaseProduct:String,Codable,CaseIterable,Sendable {
    case coreCLI="com.ayqy.video.cli"
    case advancedCLI="com.ayqy.video.advanced"
    public var entrypoint:String {self == .coreCLI ? "bin/video":"bin/video-advanced"}
}
public struct ManagedReleaseFile:Codable,Equatable,Sendable {
    public var path:String;public var sha256:String;public var bytes:Int;public var executable:Bool
    public init(path:String,sha256:String,bytes:Int,executable:Bool){self.path=path;self.sha256=sha256;self.bytes=bytes;self.executable=executable}
}
/// Signed data only. No command, script, external trust root, URL or unpacking recipe can be imported.
public struct ManagedReleaseManifest:Codable,Sendable {
    public var format=1
    public var product:ManagedReleaseProduct
    public var version:String
    public var build:Int
    public var platform="macOS"
    public var architecture:String
    public var minimumOSMajor=14
    public var coreABI=1
    public var repositorySchema=1
    public var minimumRollbackBuild:Int
    public var publisherKeySHA256:String
    public var appleTeamID:String
    public var createdAt:Date
    public var files:[ManagedReleaseFile]
    public init(product:ManagedReleaseProduct,version:String,build:Int,architecture:String,minimumRollbackBuild:Int,publisherKeySHA256:String,appleTeamID:String,createdAt:Date=Date(),files:[ManagedReleaseFile],format:Int=1) {
        self.format=format
        self.product=product;self.version=version;self.build=build;self.architecture=architecture;self.minimumRollbackBuild=minimumRollbackBuild;self.publisherKeySHA256=publisherKeySHA256;self.appleTeamID=appleTeamID;self.createdAt=createdAt;self.files=files
    }
}
public enum ManagedReleaseRules {
    public static let documentName="release.videorelease"
    public static func relativePath(_ value:String)throws {
        if value.hasPrefix("plugins/") {
            guard value.count<=512,(ManagedPayloadRules.allowedPaths(for:.advancedCLI,format:2).contains(value) || ManagedPayloadRules.allowedPaths(for:.advancedCLI,format:2).contains(where:{$0.hasPrefix(value+"/")})) else{throw VideoError.invalid("独立插件发行子路径不在明确白名单")};return
        }
        let parts=value.split(separator:"/",omittingEmptySubsequences:false)
        guard value.utf8.count<=512,!parts.isEmpty,parts.count<=12,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$",options:.regularExpression) != nil}),!parts.contains(where:{$0.lowercased().hasSuffix(".p8") || $0.lowercased().hasSuffix(".key") || $0.lowercased().contains("credential") || $0==".git"}) else{throw VideoError.invalid("发行文件路径无效或含敏感/目录穿越标识")}
    }
    public static func validate(_ manifest:ManagedReleaseManifest,publicKey:Data,architecture:String,osMajor:Int,teamID:String,now:Date=Date())throws {
        guard (manifest.format==1 || (manifest.format==2 && manifest.product == .advancedCLI)),manifest.version.range(of:"^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[A-Za-z0-9.-]+)?$",options:.regularExpression) != nil,manifest.version.utf8.count<=100,manifest.build>0,manifest.minimumRollbackBuild>0,manifest.minimumRollbackBuild<=manifest.build else{throw VideoError.invalid("发行版本、构建号或回滚下限不合法")}
        guard manifest.platform=="macOS",["arm64","x86_64"].contains(manifest.architecture),manifest.architecture==architecture,manifest.minimumOSMajor>=14,osMajor>=manifest.minimumOSMajor,manifest.coreABI==1,manifest.repositorySchema==1 else{throw VideoError.unavailable("发行系统/架构/ABI/数据库主版本不兼容；原安装和数据保留")}
        guard publicKey.count==32,manifest.publisherKeySHA256==Codec.hash(publicKey),manifest.appleTeamID==teamID,!teamID.isEmpty,manifest.createdAt<=now.addingTimeInterval(300) else{throw VideoError.permission("发行者身份、Team或签名时间不符")}
        guard !manifest.files.isEmpty,manifest.files.count<=1000,Set(manifest.files.map(\.path)).count==manifest.files.count else{throw VideoError.invalid("发行文件集合为空、重复或超限")}
        try ManagedPayloadRules.validate(manifest.files,product:manifest.product,format:manifest.format)
        var total=0
        for file in manifest.files {
            try relativePath(file.path)
            guard file.bytes>0,file.bytes<=512*1024*1024,file.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,!file.executable || ManagedPayloadRules.executablePaths(for:manifest.product,format:manifest.format).contains(file.path) else{throw VideoError.invalid("发行文件大小、摘要或可执行位置无效")}
            guard total<=2*1024*1024*1024-file.bytes else{throw VideoError.invalid("发行包超过2GiB")};total += file.bytes
        }
        guard manifest.files.contains(where:{$0.path==manifest.product.entrypoint && $0.executable}) else{throw VideoError.invalid("发行包缺少该产品固定的实际CLI入口")}
        if manifest.product == .advancedCLI && manifest.format==1 {guard manifest.files.contains(where:{$0.path=="render-catalog.videomodules"}) else{throw VideoError.invalid("独立高级包须含对应实现的签名模块目录")}}
    }
    public static func verified(_ document:SignedDocument,publicKey:Data,architecture:String,osMajor:Int,teamID:String,now:Date=Date())throws->ManagedReleaseManifest {
        guard document.payload.count<=2*1024*1024,document.signature.count==64 else{throw VideoError.permission("发行签名封套大小或格式无效")}
        let manifest=try document.verified(as:ManagedReleaseManifest.self,publicKey:publicKey)
        try validate(manifest,publicKey:publicKey,architecture:architecture,osMajor:osMajor,teamID:teamID,now:now);return manifest
    }
    public static func validateUpgrade(from old:ManagedReleaseManifest,to new:ManagedReleaseManifest)throws {
        guard old.product==new.product,old.architecture==new.architecture,old.appleTeamID==new.appleTeamID,new.build>old.build,new.minimumRollbackBuild>=old.minimumRollbackBuild else{throw VideoError.conflict("更新必须属于同一产品/架构/发行者且构建号单调增加；降级请使用受限rollback")}
    }
    /// File inventory performs no extraction, shell execution, symlink following or hard-link copying.
    public static func inventory(_ root:URL)throws->[ManagedReleaseFile] {
        let fm=FileManager.default;try safeDirectory(root)
        guard let enumerator=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey],options:[]) else{throw VideoError.invalid("无法读取发行payload目录")}
        var files:[ManagedReleaseFile]=[]
        while let path=enumerator.nextObject() as? URL {
            // DirectoryEnumerator returns /private/var URLs even when Foundation has
            // normalized the root to /var. Compare the same representation before slicing.
            let base=root.standardizedFileURL.path,child=path.standardizedFileURL.path
            guard child.hasPrefix(base+"/") else{throw VideoError.permission("payload枚举路径不属于明确根目录")}
            let relative=String(child.dropFirst(base.count+1));try relativePath(relative)
            let attrs=try fm.attributesOfItem(atPath:path.path)
            if attrs[.type] as? FileAttributeType == .typeDirectory{continue}
            guard attrs[.type] as? FileAttributeType == .typeRegular,((attrs[.referenceCount] as? NSNumber)?.intValue ?? 0)==1,let size=(attrs[.size] as? NSNumber)?.intValue,size>0,size<=512*1024*1024 else{throw VideoError.permission("payload只接受普通单链接文件，拒绝软链接/硬链接/设备或过大文件")}
            let executable=((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0)&0o111 != 0
            files.append(ManagedReleaseFile(path:relative,sha256:Codec.hash(try Data(contentsOf:path,options:.mappedIfSafe)),bytes:size,executable:executable))
            guard files.count<=1000 else{throw VideoError.invalid("发行文件超限")}
        }
        return files.sorted{$0.path<$1.path}
    }
    public static func verifyFiles(_ manifest:ManagedReleaseManifest,root:URL)throws {
        let actual=try inventory(root)
        guard actual==manifest.files.sorted(by:{$0.path<$1.path}) else{throw VideoError.permission("发行文件缺失、添加、权限/大小或哈希被修改；没有执行候选程序")}
    }
    public static func safeDirectory(_ url:URL)throws {
        let path=url.standardizedFileURL
        guard url.isFileURL,path.path != "/",path.pathComponents.count>=3 else{throw VideoError.invalid("须为明确的本地目录")}
        var cursor=path
        while cursor.path != "/" {
            if let attrs=try? FileManager.default.attributesOfItem(atPath:cursor.path) {
                // Foundation standardizes /private/var back to /var on macOS. Trust only
                // these root-owned OS aliases with their exact built-in destinations;
                // user/payload links remain forbidden, including aliases to the same target.
                let systemTargets=["/var":"private/var","/tmp":"private/tmp"]
                let systemAlias:Bool
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink,let expected=systemTargets[cursor.path],(attrs[.ownerAccountID] as? NSNumber)?.intValue==0,let target=try? FileManager.default.destinationOfSymbolicLink(atPath:cursor.path) {
                    systemAlias=target==expected || target=="/"+expected
                }else{systemAlias=false}
                guard attrs[.type] as? FileAttributeType == .typeDirectory || systemAlias else{throw VideoError.permission("发行/受管路径含软链接或非目录节点")}
            }
            cursor.deleteLastPathComponent()
        }
    }
}

public struct ManagedInstallGeneration:Codable,Sendable {
    public var format=1
    public var id:String
    public var product:ManagedReleaseProduct
    public var previousGeneration:String?
    public var manifestDigest:String
    public var rollbackFloor:Int
    public var installedAt:Date
    public var dataDigest:String
    public init(id:String,product:ManagedReleaseProduct,previousGeneration:String?,manifestDigest:String,rollbackFloor:Int,installedAt:Date=Date(),dataDigest:String){self.id=id;self.product=product;self.previousGeneration=previousGeneration;self.manifestDigest=manifestDigest;self.rollbackFloor=rollbackFloor;self.installedAt=installedAt;self.dataDigest=dataDigest}
}
public enum ManagedInstallRules {
    public static let markerName="generation.videoinstall"
    public static let slotMarker="managed.videoslot"
    public static func validID(_ value:String)->Bool {value.range(of:"^gen-[a-f0-9-]{36}$",options:.regularExpression) != nil}
    /// Called after BEGIN IMMEDIATE. A pre-existing Repository handle points to its real generation,
    /// so a pointer switch can never make an old SQLite handle writable again.
    public static func authorizeWrite(repositoryRoot:URL)throws {
        let root=repositoryRoot.standardizedFileURL.resolvingSymlinksInPath(),generation=root.deletingLastPathComponent()
        guard root.lastPathComponent=="data",generation.deletingLastPathComponent().lastPathComponent=="generations" else{return}
        let slot=generation.deletingLastPathComponent().deletingLastPathComponent(),fm=FileManager.default
        guard fm.fileExists(atPath:slot.appendingPathComponent(slotMarker).path) else{return}
        // Staging restore writes before its generation marker exists; it is not published as current.
        guard fm.fileExists(atPath:generation.appendingPathComponent(markerName).path) else{return}
        let state=try PropertyListDecoder().decode(ManagedInstallGeneration.self,from:Data(contentsOf:generation.appendingPathComponent(markerName)))
        guard state.format==1,state.id==generation.lastPathComponent,validID(state.id),let target=try? fm.destinationOfSymbolicLink(atPath:slot.appendingPathComponent("current").path),target=="generations/"+state.id else{throw VideoError.permission("此工程属于受管历史安装代，允许读取/备份但禁止旧进程继续写；请从current/data重新打开")}
    }
}
