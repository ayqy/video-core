import Foundation
import VideoCore
import VideoMedia
#if os(macOS)
import Darwin

/// A shipping binary has exactly one publisher and Apple team. There is no trust override flag,
/// environment variable, script hook, network updater, or unsigned installation mode.
private enum InstallerTrust {
    static let publicKey=Data([4,197,11,39,33,67,73,250,185,57,219,140,119,71,222,17,101,229,30,199,163,202,43,117,143,121,100,109,100,171,183,16])
    static let teamID="VTU3X26EU8"
    static var architecture:String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
}
private struct InstallArguments {
    var command:String;var slot:URL;var package:URL?;var data:URL?
    init(_ values:[String])throws {
        guard let command=values.first,["install","update","rollback","status"].contains(command) else{throw VideoError.invalid("请使用--help查看install/update/rollback/status")}
        var options:[String:String]=[:];var index=1
        while index<values.count {
            let flag=values[index]
            guard ["--slot","--package","--data"].contains(flag),options[flag]==nil,index+1<values.count,!values[index+1].hasPrefix("--"),!values[index+1].isEmpty,values[index+1].utf8.count<=4096,!values[index+1].unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw VideoError.invalid("未知、重复、缺值或不合法的安装选项")}
            options[flag]=values[index+1];index += 2
        }
        let required:Set<String> = command=="install" || command=="update" ? ["--slot","--package"]:["--slot"]
        let allowed=command=="install" ? required.union(["--data"]):required
        guard required.isSubset(of:Set(options.keys)),Set(options.keys).isSubset(of:allowed),let path=options["--slot"] else{throw VideoError.invalid("安装选项与命令不符；--data仅供首次安装使用")}
        self.command=command;slot=URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL
        package=options["--package"].map{URL(fileURLWithPath:$0,isDirectory:true).standardizedFileURL}
        data=options["--data"].map{URL(fileURLWithPath:$0,isDirectory:true).standardizedFileURL}
    }
}
private enum CandidateSelfTest {
    /// Execute only fixed native commands after all signed file bytes were verified. Capture
    /// bounded output in protected temporary files; never inherit provider/authentication env.
    static func run(_ executable:URL,_ arguments:[String],root:URL,timeout:TimeInterval=20,includeStderr:Bool=false,inputData:Data?=nil)throws->Data {
        let fm=FileManager.default,cache=root.appendingPathComponent(".installer-probe-"+Codec.id())
        try fm.createDirectory(at:cache,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:cache)}
        let out=cache.appendingPathComponent("stdout"),err=cache.appendingPathComponent("stderr")
        guard fm.createFile(atPath:out.path,contents:nil,attributes:[.posixPermissions:0o600]),fm.createFile(atPath:err.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw VideoError.unavailable("无法建立受保护的候选自检输出")}
        let stdout=try FileHandle(forWritingTo:out),stderr=try FileHandle(forWritingTo:err)
        defer{try? stdout.close();try? stderr.close()}
        let task=Process();task.executableURL=executable;task.arguments=arguments;task.currentDirectoryURL=root
        task.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8","LC_ALL":"en_US.UTF-8","TMPDIR":cache.path]
        let stdin=inputData==nil ? nil:Pipe()
        if let stdin{task.standardInput=stdin}else{task.standardInput=FileHandle.nullDevice};task.standardOutput=stdout;task.standardError=stderr
        try task.run()
        if let inputData,let stdin{try stdin.fileHandleForWriting.write(contentsOf:inputData);try stdin.fileHandleForWriting.close()}
        let deadline=Date().addingTimeInterval(timeout)
        while task.isRunning && Date()<deadline {
            let a=(try? out.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0,b=(try? err.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            if a>4*1024*1024 || b>1024*1024{task.terminate();break}
            Thread.sleep(forTimeInterval:0.025)
        }
        if task.isRunning{task.terminate();let stop=Date().addingTimeInterval(1);while task.isRunning && Date()<stop{Thread.sleep(forTimeInterval:0.025)};if task.isRunning{kill(task.processIdentifier,SIGKILL)}}
        task.waitUntilExit();try stdout.synchronize();try stderr.synchronize()
        guard task.terminationReason == .exit,task.terminationStatus==0,Date()<deadline,(try out.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=4*1024*1024,(try err.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=1024*1024 else{throw VideoError.unavailable("候选程序签名、系统信任或有限自检未通过；原安装和数据保留")}
        // codesign writes its identity to stderr. This data is inspected in memory only.
        return try Data(contentsOf:out)+(includeStderr ? Data(contentsOf:err):Data())
    }
    static func envelope(_ data:Data,command:String,requireIndependentRevocationABI:Bool=false)throws {
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],object["ok"] as? Bool==true,object["state"] as? String=="succeeded",object["schema_version"] as? String==AgentContract.version,object["error"] is NSNull || object["error"]==nil,let result=object["result"] as? [String:Any],!result.isEmpty else{throw VideoError.unavailable("候选"+command+"未返回当前ABI的成功封套")}
        if command=="schema"{guard result["schema_version"] as? String==AgentContract.version else{throw VideoError.unavailable("候选schema主版本不兼容")}}
        if command=="doctor"{
            let database=result["database"] as? [String:Any]
            let advanced=result["repository_schema"] as? Int
            guard advanced==1 || (database?["schema"] as? Int==1 && database?["validated"] as? Bool==true && database?["read_only"] as? Bool==true) else{throw VideoError.unavailable("候选doctor未实际确认恢复后的数据库兼容性")}
            try IndependentLicenseRevocationABI.validate(result[IndependentLicenseRevocationABI.field],required:requireIndependentRevocationABI)
        }
    }
    static func inspect(program:URL,data:URL,manifest:ManagedReleaseManifest)throws {
        for file in manifest.files where file.executable {
            let executable=program.appendingPathComponent(file.path)
            _=try run(URL(fileURLWithPath:"/usr/bin/codesign"),["--verify","--strict",executable.path],root:data)
            let identity=try run(URL(fileURLWithPath:"/usr/bin/codesign"),["--display","--verbose=4",executable.path],root:data,includeStderr:true)
            let lines=String(decoding:identity,as:UTF8.self).split(separator:"\n")
            guard lines.contains(Substring("TeamIdentifier="+InstallerTrust.teamID)),lines.contains(where:{$0.hasPrefix("Authority=Developer ID Application:")}) else{throw VideoError.permission("候选可执行文件不属于固定Apple Developer ID发行Team")}
            if file.path==manifest.product.entrypoint{guard lines.contains(Substring("Identifier="+manifest.product.rawValue)) else{throw VideoError.permission("候选CLI签名标识与固定产品不一致")}}
            _=try run(URL(fileURLWithPath:"/usr/sbin/spctl"),["--assess","--type","execute",executable.path],root:data)
        }
        if manifest.product == .advancedCLI && manifest.format==1 {
            let binary=program.appendingPathComponent(manifest.product.entrypoint)
            let digest=try MachOCodeIdentity.digest(Data(contentsOf:binary,options:.mappedIfSafe))
            let history=try ModulePolicyHistoryFileStore(root:data).read()
            _=try RenderCatalogResolver.verify(Data(contentsOf:program.appendingPathComponent("render-catalog.videomodules")),publicKey:InstallerTrust.publicKey,implementationDigest:digest,minimumPolicyVersions:history.versions,supportedCapabilities:["video.game":"game.simulate","video.cartoon":"cartoon.animate"],policyHistory:history)
            // A preserved licence is evidence, never an automatic grant. Actual jobs run the
            // same signature/expiry/revocation and module entitlement checks again.
            let licence=data.appendingPathComponent("independent.videolicense")
            if FileManager.default.fileExists(atPath:licence.path){let signed=try PropertyListDecoder().decode(SignedDocument.self,from:Data(contentsOf:licence));_=try signed.verified(as:ModuleLicense.self,publicKey:InstallerTrust.publicKey)}
        }
        if manifest.product == .advancedCLI && manifest.format==2 {
            let history=try ModulePolicyHistoryFileStore(root:data).read(),type:UInt32=manifest.architecture=="arm64" ? 0x0100000c:0x01000007
            guard try PluginPackageRules.read(program.appendingPathComponent("publisher.pub"),limit:32)==InstallerTrust.publicKey else{throw VideoError.permission("独立插件发行公钥不匹配")}
            for id in PluginPackageRules.moduleSuffixes.keys {
                let root=program.appendingPathComponent(try PluginPackageRules.packagePath(pluginID:id))
                let package=try PluginPackageRules.verify(root:root,publicKey:InstallerTrust.publicKey,architecture:manifest.architecture,osMajor:ProcessInfo.processInfo.operatingSystemVersion.majorVersion,minimumPolicyVersion:history.versions[id] ?? 1,implementationDigest:{url in try MachOCodeIdentity.digest(PluginPackageRules.read(url,limit:512*1024*1024),cpuType:type)},validateCode:PluginNativeCode.verify)
                guard package.module.id==id else{throw VideoError.permission("独立插件位置和身份不符")}
                _=try history.observing([package.policy])
                let requests=try PluginPackageProbeRules.requests(),wire=try PluginPackageProbeRules.input(requests)
                let result=try run(root.appendingPathComponent(package.execution.entrypoint),[],root:data,timeout:25,inputData:wire)
                try PluginPackageProbeRules.validate(result,requests:requests,manifest:package.manifest)
                try PluginPackageRules.verifyFiles(package.manifest,root:root)
            }
        }
        let candidate=program.appendingPathComponent(manifest.product.entrypoint)
        try envelope(run(candidate,["schema"],root:data),command:"schema")
        let requireRevocationABI = manifest.product == .advancedCLI ? try IndependentLicenseRevocationStore.production(publicKey:InstallerTrust.publicKey).hasRevocations() : false
        try envelope(run(candidate,["doctor","--workspace",data.path],root:data),command:"doctor",requireIndependentRevocationABI:requireRevocationABI)
    }
}
@main private struct VideoInstall {
    static let help="""
    video-install：固定发行者签名的本机目录包安装/更新，不适用于替换iOS App代码。
      install --package <目录.videorelease> --slot <独立受管目录> [--data <已有工程>]
      update --package <目录.videorelease> --slot <同一受管目录>
      rollback --slot <同一受管目录>
      status --slot <同一受管目录>
    发行包：release.videorelease + payload/；无需解压，不执行包内安装脚本。
    current/program/bin/video 或 video-advanced 为实际入口，current/data为同代数据。
    真实签名、Gatekeeper、schema、doctor与备份恢复全部通过后才切换；保留旧程序/数据。
    rollback切回旧业务快照，更新后的数据仍保留；不会换发、刷新或恢复已移除的独立许可。
    iOS更新继续通过App Store；本工具不证明购买、公开发行或真实用户链验收。
    """
    static func main() {
        let supplied=Array(CommandLine.arguments.dropFirst())
        if supplied.isEmpty || supplied==["--help"]{print(help);return}
        do {
            let args=try InstallArguments(supplied)
            let installer=ManagedReleaseInstaller(publicKey:InstallerTrust.publicKey,architecture:InstallerTrust.architecture,osMajor:ProcessInfo.processInfo.operatingSystemVersion.majorVersion,teamID:InstallerTrust.teamID,probe:CandidateSelfTest.inspect)
            let result:ManagedInstallResult
            switch args.command {
            case "install":result=try installer.install(package:args.package!,slot:args.slot,data:args.data)
            case "update":result=try installer.update(package:args.package!,slot:args.slot)
            case "rollback":result=try installer.rollback(slot:args.slot)
            default:result=try installer.status(slot:args.slot)
            }
            FileHandle.standardOutput.write(try Codec.data(result));FileHandle.standardOutput.write(Data("\n".utf8))
        }catch let error as VideoError{FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(error.exitCode)}
        catch{FileHandle.standardError.write(Data("安装未完成：有限本机文件、自检或数据恢复失败；未回显底层输出、凭据或私钥。\n".utf8));exit(8)}
    }
}
#else
@main private struct VideoInstall {static func main(){print("本机CLI更新器仅支持macOS；iOS App通过App Store更新。")}}
#endif
