import Foundation
import Darwin

/// Separate from the in-process render catalog. Unknown formats never fall back to that ABI.
public struct PluginExecutionDescriptor: Codable, Equatable, Sendable {
    public var entrypoint: String
    public var serviceName: String
    public var serviceExecutable: String
    public var platform: String
    public var architecture: String
    public var minimumOSMajor: Int
    public init(pluginID: String, architecture: String) throws {
        guard let suffix=PluginPackageRules.moduleSuffixes[pluginID], ["arm64","x86_64"].contains(architecture) else {throw VideoError.invalid("未知独立插件或架构")}
        entrypoint="PluginHost.app/Contents/MacOS/video-plugin-bridge"
        serviceName="com.ayqy.video.plugin."+suffix
        serviceExecutable="PluginHost.app/Contents/XPCServices/"+serviceName+".xpc/Contents/MacOS/video-"+suffix+"-plugin"
        platform="macOS";self.architecture=architecture;minimumOSMajor=14
    }
}
public struct PluginPackageManifest: Codable, Sendable {
    public var format=1
    public var module: PluginManifest
    public var execution: PluginExecutionDescriptor
    public var files: [ManagedReleaseFile]
    public var implementationDigest: String
    public var policyRef="policy.videopolicy"
    public init(module:PluginManifest,execution:PluginExecutionDescriptor,files:[ManagedReleaseFile]) {
        self.module=module;self.execution=execution;self.files=files;implementationDigest=module.implementationDigest
    }
}
/// Constructed only after both publisher signatures, exact files and actual native code probes.
public struct VerifiedPluginPackage: Sendable {
    public let rootURL:URL
    public let manifest:PluginPackageManifest
    public let policy:CommercialPolicy
    public var module:PluginManifest{manifest.module}
    public var execution:PluginExecutionDescriptor{manifest.execution}
    fileprivate init(rootURL:URL,manifest:PluginPackageManifest,policy:CommercialPolicy){self.rootURL=rootURL;self.manifest=manifest;self.policy=policy}
}
public enum PluginPackageRules {
    public static let manifestName="manifest.videoplugin"
    public static let policyName="policy.videopolicy"
    public static let moduleSuffixes=["video.game":"game","video.cartoon":"cartoon"]
    public static let capabilities=["video.game":"game.simulate","video.cartoon":"cartoon.animate"]
    public static let methods:Set<String>=["handshake","describe","validate","estimate","execute","progress","cancel","health"]
    public static func packagePath(pluginID:String)throws->String {
        guard moduleSuffixes[pluginID] != nil else{throw VideoError.invalid("未知独立插件")};return "plugins/"+pluginID+".videoplugin"
    }
    public static func executablePaths(pluginID:String)throws->Set<String>{let e=try PluginExecutionDescriptor(pluginID:pluginID,architecture:"x86_64");return [e.entrypoint,e.serviceExecutable]}
    public static func requiredPaths(pluginID:String)throws->Set<String>{
        let e=try PluginExecutionDescriptor(pluginID:pluginID,architecture:"x86_64")
        let app="PluginHost.app/Contents", service=app+"/XPCServices/"+e.serviceName+".xpc/Contents"
        return [e.entrypoint,e.serviceExecutable,app+"/Info.plist",service+"/Info.plist",app+"/_CodeSignature/CodeResources",service+"/_CodeSignature/CodeResources","LICENSE","NOTICE","SOURCES.md"]
    }
    public static func allowedPaths(pluginID:String)throws->Set<String>{
        let e=try PluginExecutionDescriptor(pluginID:pluginID,architecture:"x86_64")
        return try requiredPaths(pluginID:pluginID).union(["PluginHost.app/Contents/PkgInfo","PluginHost.app/Contents/embedded.provisionprofile","PluginHost.app/Contents/XPCServices/"+e.serviceName+".xpc/Contents/PkgInfo","PluginHost.app/Contents/XPCServices/"+e.serviceName+".xpc/Contents/embedded.provisionprofile"])
    }
    public static func validate(_ manifest:PluginPackageManifest,policy:CommercialPolicy,architecture:String,osMajor:Int,minimumPolicyVersion:Int=1,now:Date=Date())throws {
        let module=manifest.module,expected=try PluginExecutionDescriptor(pluginID:module.id,architecture:architecture)
        guard manifest.format==1,manifest.policyRef==policyName,manifest.execution==expected,osMajor>=expected.minimumOSMajor,
              module.abi==1,module.minimumCore==1,PluginInputCompatibility.supports(pluginID:module.id,version:module.inputSchema),module.outputSchema==1,
              module.capabilities==[capabilities[module.id]!],module.permissions.isEmpty,
              module.version.utf8.count<=100,module.version.range(of:"^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[A-Za-z0-9.-]+)?$",options:.regularExpression) != nil,
              manifest.implementationDigest==module.implementationDigest,module.implementationDigest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              ["open","closed"].contains(module.sourceVisibility),policy.pluginID==module.id,
              ["free","paid","disabled"].contains(policy.access),policy.sourceVisibility==module.sourceVisibility,
              policy.version>=max(1,minimumPolicyVersion),policy.updatedAt<=now.addingTimeInterval(300) else {
            throw VideoError.permission("独立插件包格式、固定入口、平台/架构、ABI、代码身份或独立策略不匹配")
        }
        try validateFiles(manifest.files,pluginID:module.id)
    }
    public static func validateFiles(_ files:[ManagedReleaseFile],pluginID:String)throws{
        let paths=Set(files.map(\.path)),allowed=try allowedPaths(pluginID:pluginID),required=try requiredPaths(pluginID:pluginID),executables=try executablePaths(pluginID:pluginID)
        guard files.count<=32,paths.count==files.count,required.isSubset(of:paths),paths.isSubset(of:allowed) else{throw VideoError.permission("独立插件库存缺项、重复或夹带未批准源码/资源")}
        var total=0
        for file in files {
            guard file.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,file.bytes>0,file.bytes<=(executables.contains(file.path) ? 512*1024*1024:2*1024*1024),file.executable==executables.contains(file.path),total<=1024*1024*1024-file.bytes else{throw VideoError.invalid("独立插件文件摘要、体积或执行权限不合法")};total+=file.bytes
        }
    }
    /// Bounded regular single-link reads; neither a final link nor a FIFO is followed.
    public static func read(_ url:URL,limit:Int)throws->Data {
        try ManagedReleaseRules.safeDirectory(url.deletingLastPathComponent())
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);guard fd>=0 else{throw VideoError.permission("独立插件文件不能安全打开")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? handle.close()};var a=stat()
        guard fstat(fd,&a)==0,a.st_mode&S_IFMT==S_IFREG,a.st_nlink==1,a.st_size>0,a.st_size<=limit else{throw VideoError.permission("独立插件仅接受有限普通单链接文件")}
        let data=try handle.read(upToCount:Int(a.st_size)+1) ?? Data();var b=stat()
        guard data.count==a.st_size,fstat(fd,&b)==0,b.st_size==a.st_size,b.st_mode==a.st_mode,b.st_nlink==1 else{throw VideoError.conflict("独立插件读取期间文件变化")};return data
    }
    public static func inventory(_ root:URL,includeDocuments:Bool=false)throws->[ManagedReleaseFile]{
        try ManagedReleaseRules.safeDirectory(root);let fm=FileManager.default
        guard let enumerator=fm.enumerator(at:root,includingPropertiesForKeys:nil,options:[]) else{throw VideoError.invalid("无法枚举独立插件包")}
        let allowed=try moduleSuffixes.keys.reduce(into:Set([manifestName,policyName])){result,id in result.formUnion(try allowedPaths(pluginID:id))}
        var result:[ManagedReleaseFile]=[]
        while let path=enumerator.nextObject() as? URL {
            let base=root.standardizedFileURL.path,child=path.standardizedFileURL.path
            guard child.hasPrefix(base+"/") else{throw VideoError.permission("独立插件库存越界")}
            let relative=String(child.dropFirst(base.count+1)),attrs=try fm.attributesOfItem(atPath:path.path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else{throw VideoError.permission("独立插件包拒绝符号链接")}
            if attrs[.type] as? FileAttributeType == .typeDirectory{guard allowed.contains(where:{$0.hasPrefix(relative+"/")}) else{throw VideoError.permission("独立插件包含未批准目录")};continue}
            guard allowed.contains(relative) else{throw VideoError.permission("独立插件包含未批准文件")}
            guard result.count<34 else{throw VideoError.invalid("独立插件包库存超限")}
            let data=try read(path,limit:512*1024*1024)
            if !includeDocuments && [manifestName,policyName].contains(relative){continue}
            result.append(ManagedReleaseFile(path:relative,sha256:Codec.hash(data),bytes:data.count,executable:((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0)&0o111 != 0))
        }
        return result.sorted{$0.path<$1.path}
    }
    public static func verifyFiles(_ manifest:PluginPackageManifest,root:URL)throws{
        try validateFiles(manifest.files,pluginID:manifest.module.id)
        guard try inventory(root)==manifest.files.sorted(by:{$0.path<$1.path}) else{throw VideoError.permission("独立插件实际库存与签名摘要不同")}
        let e=manifest.execution
        func plist(_ relative:String)throws->[String:Any]{guard let value=try PropertyListSerialization.propertyList(from:read(root.appendingPathComponent(relative),limit:2*1024*1024),format:nil) as? [String:Any] else{throw VideoError.invalid("独立插件Info.plist无效")};return value}
        let host=try plist("PluginHost.app/Contents/Info.plist"),service=try plist("PluginHost.app/Contents/XPCServices/"+e.serviceName+".xpc/Contents/Info.plist")
        guard host["CFBundleIdentifier"] as? String==e.serviceName+".host",host["LSBackgroundOnly"] as? Bool==true,host["CFBundlePackageType"] as? String=="APPL",host["CFBundleExecutable"] as? String=="video-plugin-bridge",host["VideoPluginServiceName"] as? String==e.serviceName,
              service["CFBundleIdentifier"] as? String==e.serviceName,service["CFBundleExecutable"] as? String==URL(fileURLWithPath:e.serviceExecutable).lastPathComponent,service["CFBundlePackageType"] as? String=="XPC!" else{throw VideoError.permission("独立插件实际bundle/service身份与固定描述不同")}
    }
    /// Separate declarations may update metadata for identical sealed code; no code is read or executed there.
    private static func declarations(_ root:URL)throws->(manifest:Data,policy:Data){
        try ManagedReleaseRules.safeDirectory(root)
        let paths=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil,options:[])
        guard paths.count==2,Set(paths.map(\.lastPathComponent))==[manifestName,policyName] else{throw VideoError.permission("独立插件声明目录只能包含签名manifest和policy")}
        for path in paths {
            let attrs=try FileManager.default.attributesOfItem(atPath:path.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0)&0o111==0 else{throw VideoError.permission("独立插件声明拒绝目录、链接或可执行文件")}
        }
        return(try read(root.appendingPathComponent(manifestName),limit:2*1024*1024),try read(root.appendingPathComponent(policyName),limit:2*1024*1024))
    }
    public static func verify(root:URL,declarationsRoot:URL?=nil,publicKey:Data,architecture:String,osMajor:Int,minimumPolicyVersion:Int=1,now:Date=Date(),implementationDigest:(URL)throws->String,validateCode:(URL,PluginExecutionDescriptor)throws->Void)throws->VerifiedPluginPackage {
        let declarationBytes:(manifest:Data,policy:Data)
        if let declarationsRoot{declarationBytes=try declarations(declarationsRoot)}else{declarationBytes=(try read(root.appendingPathComponent(manifestName),limit:2*1024*1024),try read(root.appendingPathComponent(policyName),limit:2*1024*1024))}
        let document=try PropertyListDecoder().decode(SignedDocument.self,from:declarationBytes.manifest)
        let policyDocument=try PropertyListDecoder().decode(SignedDocument.self,from:declarationBytes.policy)
        guard publicKey.count==32,document.signature.count==64,policyDocument.signature.count==64 else{throw VideoError.permission("独立插件包签名封套无效")}
        let manifest=try document.verified(as:PluginPackageManifest.self,publicKey:publicKey),policy=try policyDocument.verified(as:CommercialPolicy.self,publicKey:publicKey)
        try validate(manifest,policy:policy,architecture:architecture,osMajor:osMajor,minimumPolicyVersion:minimumPolicyVersion,now:now)
        try verifyFiles(manifest,root:root)
        guard try implementationDigest(root.appendingPathComponent(manifest.execution.serviceExecutable))==manifest.implementationDigest else{throw VideoError.permission("独立插件实际服务Mach-O代码身份不匹配")}
        try validateCode(root,manifest.execution)
        // Native probes and file inspection may not silently mutate candidate bytes.
        try verifyFiles(manifest,root:root)
        if let declarationsRoot {
            let current=try declarations(declarationsRoot)
            guard current.manifest==declarationBytes.manifest,current.policy==declarationBytes.policy else{throw VideoError.conflict("独立插件验签期间声明被改写")}
        }
        return VerifiedPluginPackage(rootURL:root.standardizedFileURL,manifest:manifest,policy:policy)
    }
}

/// Install probes are read-only protocol calls, never validate/estimate/execute a customer frame.
public enum PluginPackageProbeRules {
    public static func requests(now:Date=Date())throws->[PluginRPCRequest]{
        let invocation=PluginInvocation(workspaceID:"installation-probe",projectID:"installation-probe",revisionID:"installation-probe",revisionDigest:Codec.hash(Data("installation-probe-no-customer-input".utf8)),invocationID:Codec.id(),budgetReference:"installation-probe-no-execution",currency:"CNY",deadlineUnixTime:now.timeIntervalSince1970+20)
        try PluginProtocolRules.validate(invocation,now:now)
        return [PluginMethod.handshake,.describe,.health].map{PluginRPCRequest(requestID:Codec.id(),method:$0,invocation:invocation)}
    }
    public static func input(_ requests:[PluginRPCRequest])throws->Data{
        guard requests.map(\.method)==[.handshake,.describe,.health],requests.allSatisfy({$0.input==nil && $0.taskID==nil && $0.invocation==requests.first?.invocation}),Set(requests.map(\.requestID)).count==3 else{throw VideoError.invalid("安装探针只允许同一冻结身份的三个只读方法")}
        return try requests.reduce(into:Data()){bytes,request in bytes.append(try Codec.data(request));bytes.append(10)}
    }
    public static func validate(_ data:Data,requests:[PluginRPCRequest],manifest:PluginPackageManifest)throws{
        _=try input(requests)
        guard data.count<=1024*1024,let text=String(data:data,encoding:.utf8) else{throw VideoError.invalid("插件安装探针输出无效或超限")}
        let expected=Set(requests.map(\.requestID));var seen=Set<String>(),peer:Int?,exited=false
        let lines=text.split(separator:"\n",omittingEmptySubsequences:true)
        guard lines.count==4 else{throw VideoError.unavailable("插件安装探针缺少三方法回执或物理退出回执")}
        for line in lines {
            let bytes=Data(line.utf8)
            guard let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let transport=object["__video_transport"] as? [String:Any],let event=transport["event"] as? String,let pid=transport["peer_pid"] as? Int,pid>1,peer==nil || peer==pid else{throw VideoError.permission("插件安装探针缺少一致的真实peer身份")}
            peer=pid
            if event=="peer_exited" {guard !exited,seen==expected,Set(object.keys)==["__video_transport"] else{throw VideoError.permission("插件退出回执顺序或字段不合法")};exited=true;continue}
            guard event=="response",!exited else{throw VideoError.permission("插件探针出现未知传输事件")}
            let response=try Codec.decoder().decode(PluginRPCResponse.self,from:bytes)
            let method=requests.first(where:{$0.requestID==response.requestID})?.method
            guard expected.contains(response.requestID),seen.insert(response.requestID).inserted,response.state==(method == .health ? "idle":"ready"),response.ok,response.protocolMajor==1,response.error==nil,response.task==nil,response.cost==nil,response.inputDigest==nil,let descriptor=response.descriptor,
                  descriptor.pluginID==manifest.module.id,descriptor.capabilityID==manifest.module.capabilities.first,descriptor.version==manifest.module.version,
                  Set(descriptor.methods)==Set(PluginMethod.allCases),descriptor.methods.count==8,descriptor.inputSchemaVersion==manifest.module.inputSchema,descriptor.outputSchemaVersion==manifest.module.outputSchema,!descriptor.filesystemAccess,!descriptor.networkAccess else{throw VideoError.permission("插件三方法描述/版本不符，或安装探针意外返回制作任务")}
        }
        guard exited,seen==expected else{throw VideoError.unavailable("插件peer尚未证实退出；不能切换安装")}
    }
}
