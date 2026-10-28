import XCTest
import CryptoKit
import Darwin
@testable import VideoCore

/// Ephemeral signatures and inert bytes test the package gate, never production code/signing.
final class PluginPackageTests:XCTestCase {
    private var roots:[URL]=[]
    private let now=Date(timeIntervalSince1970:1_790_000_000)
    override func tearDown(){for root in roots{try? FileManager.default.removeItem(at:root)};super.tearDown()}
    private func directory()throws->URL{let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("plugin-package-rule-"+Codec.id());try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);roots.append(root);return root}
    private func sign<T:Encodable>(_ value:T,key:Curve25519.Signing.PrivateKey)throws->SignedDocument{let data=try Codec.data(value);return SignedDocument(payload:data,signature:try key.signature(for:data))}
    private func write<T:Encodable>(_ value:T,to path:URL)throws{let e=PropertyListEncoder();e.outputFormat = .binary;try e.encode(value).write(to:path)}
    private func fixture(id:String="video.game")throws->(URL,PluginPackageManifest,CommercialPolicy,Curve25519.Signing.PrivateKey){
        let root=try directory(),execution=try PluginExecutionDescriptor(pluginID:id,architecture:"x86_64"),key=Curve25519.Signing.PrivateKey()
        let executablePaths=try PluginPackageRules.executablePaths(pluginID:id)
        for path in try PluginPackageRules.requiredPaths(pluginID:id){let file=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("inert fixture bytes, no production code".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:executablePaths.contains(path) ? 0o700:0o600],ofItemAtPath:file.path)}
        let h:[String:Any] = ["CFBundleIdentifier":execution.serviceName+".host","CFBundleExecutable":"video-plugin-bridge","CFBundlePackageType":"APPL","LSBackgroundOnly":true,"VideoPluginServiceName":execution.serviceName]
        let x:[String:Any] = ["CFBundleIdentifier":execution.serviceName,"CFBundleExecutable":URL(fileURLWithPath:execution.serviceExecutable).lastPathComponent,"CFBundlePackageType":"XPC!"]
        try PropertyListSerialization.data(fromPropertyList:h,format:.binary,options:0).write(to:root.appendingPathComponent("PluginHost.app/Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList:x,format:.binary,options:0).write(to:root.appendingPathComponent("PluginHost.app/Contents/XPCServices/"+execution.serviceName+".xpc/Contents/Info.plist"))
        let module=PluginManifest(id:id,version:"1.0.0",capabilities:[PluginPackageRules.capabilities[id]!],implementationDigest:Codec.hash(Data("synthetic native probe result".utf8)),permissions:[])
        let manifest=PluginPackageManifest(module:module,execution:execution,files:try PluginPackageRules.inventory(root))
        let policy=CommercialPolicy(pluginID:id,version:4,access:"paid",updatedAt:now)
        try write(sign(manifest,key:key),to:root.appendingPathComponent(PluginPackageRules.manifestName));try write(sign(policy,key:key),to:root.appendingPathComponent(PluginPackageRules.policyName))
        return(root,manifest,policy,key)
    }
    private func verified(_ root:URL,_ manifest:PluginPackageManifest,_ key:Curve25519.Signing.PrivateKey,counter:inout Int)throws->VerifiedPluginPackage{
        try PluginPackageRules.verify(root:root,publicKey:key.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,now:now,implementationDigest:{_ in counter+=1;return manifest.implementationDigest},validateCode:{_,_ in counter+=1})
    }
    func testIndependentModuleIdentitiesAreNotForcedToSameHostDigest()throws{
        let (r,m,p,k)=try fixture();var counter=0;let value=try verified(r,m,k,counter:&counter)
        XCTAssertEqual(value.rootURL.standardizedFileURL.path,r.standardizedFileURL.path);XCTAssertEqual(value.module,m.module);XCTAssertEqual(counter,2)
        var other=try fixture(id:"video.cartoon").1;other.module.implementationDigest=String(repeating:"b",count:64);other.implementationDigest=other.module.implementationDigest
        var policy=p;policy.pluginID=other.module.id
        XCTAssertNoThrow(try PluginPackageRules.validate(other,policy:policy,architecture:"x86_64",osMajor:14,now:now))
    }
    func testWrongSignatureAndTamperedFileAreRejectedBeforeCodeProbe()throws{
        let (r,m,_,k)=try fixture();var n=0
        XCTAssertThrowsError(try verified(r,m,Curve25519.Signing.PrivateKey(),counter:&n));XCTAssertEqual(n,0)
        try Data("tampered".utf8).write(to:r.appendingPathComponent(m.execution.serviceExecutable))
        XCTAssertThrowsError(try verified(r,m,k,counter:&n));XCTAssertEqual(n,0)
    }
    func testUnknownFormatEntryServiceArchitectureABIAndPolicyAreRejected()throws{
        let (_,original,p,_)=try fixture()
        for index in 0..<8 {var m=original;switch index {case 0:m.format=2;case 1:m.execution.entrypoint="/bin/sh";case 2:m.execution.serviceName="other.service";case 3:m.execution.architecture="arm64";case 4:m.module.abi=99;case 5:m.policyRef="../policy";case 6:m.module.permissions=["network"];default:m.module.capabilities=["unknown"]}
            XCTAssertThrowsError(try PluginPackageRules.validate(m,policy:p,architecture:"x86_64",osMajor:14,now:now))
        }
        var wrongPolicy=p;wrongPolicy.pluginID="video.cartoon";XCTAssertThrowsError(try PluginPackageRules.validate(original,policy:wrongPolicy,architecture:"x86_64",osMajor:14,now:now))
        XCTAssertThrowsError(try PluginPackageRules.validate(original,policy:p,architecture:"x86_64",osMajor:14,minimumPolicyVersion:5,now:now))
    }
    func testPaidToFreeOnlyChangesIndependentPolicyNotCodeOrCaller()throws{
        let (_,m,p,_)=try fixture();var free=p;free.access="free";free.version+=1
        let before=try Codec.data(m);try PluginPackageRules.validate(m,policy:free,architecture:"x86_64",osMajor:14,minimumPolicyVersion:free.version,now:now);XCTAssertEqual(before,try Codec.data(m));XCTAssertEqual(m.module.id,free.pluginID)
        var visibility=free;visibility.sourceVisibility="open";XCTAssertThrowsError(try PluginPackageRules.validate(m,policy:visibility,architecture:"x86_64",osMajor:14,now:now))
    }
    func testUnknownFilesDirectoriesLinksAndPipeNeverBecomePackageInputs()throws{
        let (r,m,_,k)=try fixture();var n=0
        let extra=r.appendingPathComponent("hidden.swift");try Data("private".utf8).write(to:extra);XCTAssertThrowsError(try verified(r,m,k,counter:&n));try FileManager.default.removeItem(at:extra)
        try FileManager.default.createDirectory(at:r.appendingPathComponent(".git"),withIntermediateDirectories:false);XCTAssertThrowsError(try verified(r,m,k,counter:&n));try FileManager.default.removeItem(at:r.appendingPathComponent(".git"))
        let license=r.appendingPathComponent("LICENSE"),external=try directory().appendingPathComponent("source");try Data("outside".utf8).write(to:external);try FileManager.default.removeItem(at:license)
        try FileManager.default.createSymbolicLink(at:license,withDestinationURL:external);XCTAssertThrowsError(try verified(r,m,k,counter:&n));try FileManager.default.removeItem(at:license)
        XCTAssertEqual(mkfifo(license.path,0o600),0);XCTAssertThrowsError(try verified(r,m,k,counter:&n));XCTAssertEqual(n,0)
    }
    func testActualNativeMismatchAndMutationDuringNativeProbeCannotCreateVerifiedValue()throws{
        let (r,m,_,k)=try fixture()
        XCTAssertThrowsError(try PluginPackageRules.verify(root:r,publicKey:k.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,now:now,implementationDigest:{_ in String(repeating:"0",count:64)},validateCode:{_,_ in XCTFail("identity must fail first")}))
        XCTAssertThrowsError(try PluginPackageRules.verify(root:r,publicKey:k.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,now:now,implementationDigest:{_ in m.implementationDigest},validateCode:{root,_ in try Data("changed".utf8).write(to:root.appendingPathComponent("LICENSE"))}))
    }
    func testSeparateHigherFreeDeclarationsUseOnlyIdenticalSealedRootCode()throws{
        let (root,manifest,paid,key)=try fixture(),declarations=try directory();var free=paid;free.version+=1;free.access="free"
        try write(sign(manifest,key:key),to:declarations.appendingPathComponent(PluginPackageRules.manifestName));try write(sign(free,key:key),to:declarations.appendingPathComponent(PluginPackageRules.policyName))
        var paths:[URL]=[]
        let value=try PluginPackageRules.verify(root:root,declarationsRoot:declarations,publicKey:key.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,minimumPolicyVersion:free.version,now:now,implementationDigest:{url in paths.append(url);return manifest.implementationDigest},validateCode:{url,_ in paths.append(url)})
        XCTAssertEqual(value.rootURL.standardizedFileURL.path,root.standardizedFileURL.path);XCTAssertEqual(value.policy.access,"free");XCTAssertEqual(value.policy.version,free.version);XCTAssertEqual(value.manifest.files,manifest.files)
        XCTAssertEqual(paths,[root.appendingPathComponent(manifest.execution.serviceExecutable),root])
        var counter=0;XCTAssertEqual(try verified(root,manifest,key,counter:&counter).policy.access,"paid")
    }
    func testSeparateDeclarationsRejectDifferentInventoryAndActualDigest()throws{
        let (root,manifest,policy,key)=try fixture(),declarations=try directory()
        try write(sign(policy,key:key),to:declarations.appendingPathComponent(PluginPackageRules.policyName))
        var changed=manifest;changed.files[0].sha256=String(repeating:"0",count:64)
        try write(sign(changed,key:key),to:declarations.appendingPathComponent(PluginPackageRules.manifestName));var probed=false
        XCTAssertThrowsError(try PluginPackageRules.verify(root:root,declarationsRoot:declarations,publicKey:key.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,now:now,implementationDigest:{_ in probed=true;return manifest.implementationDigest},validateCode:{_,_ in XCTFail("inventory must fail before native probe")}));XCTAssertFalse(probed)
        changed=manifest;changed.module.implementationDigest=String(repeating:"0",count:64);changed.implementationDigest=changed.module.implementationDigest
        try write(sign(changed,key:key),to:declarations.appendingPathComponent(PluginPackageRules.manifestName))
        XCTAssertThrowsError(try PluginPackageRules.verify(root:root,declarationsRoot:declarations,publicKey:key.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,now:now,implementationDigest:{_ in manifest.implementationDigest},validateCode:{_,_ in XCTFail("actual service digest must fail first")}))
    }
    func testSeparateDeclarationsRejectAdditionalFilesLinksAndOlderPolicy()throws{
        let (root,manifest,policy,key)=try fixture(),declarations=try directory()
        let manifestPath=declarations.appendingPathComponent(PluginPackageRules.manifestName),policyPath=declarations.appendingPathComponent(PluginPackageRules.policyName)
        try write(sign(manifest,key:key),to:manifestPath);try write(sign(policy,key:key),to:policyPath)
        func verify(_ minimum:Int=1)throws{_=try PluginPackageRules.verify(root:root,declarationsRoot:declarations,publicKey:key.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,minimumPolicyVersion:minimum,now:now,implementationDigest:{_ in manifest.implementationDigest},validateCode:{_,_ in})}
        XCTAssertThrowsError(try verify(policy.version+1))
        let extra=declarations.appendingPathComponent("PluginHost.app");try FileManager.default.createDirectory(at:extra,withIntermediateDirectories:false);XCTAssertThrowsError(try verify());try FileManager.default.removeItem(at:extra)
        let original=try Data(contentsOf:policyPath);try FileManager.default.removeItem(at:policyPath)
        try FileManager.default.createSymbolicLink(at:policyPath,withDestinationURL:root.appendingPathComponent(PluginPackageRules.policyName));XCTAssertThrowsError(try verify());try FileManager.default.removeItem(at:policyPath)
        try FileManager.default.linkItem(at:root.appendingPathComponent(PluginPackageRules.policyName),to:policyPath);XCTAssertThrowsError(try verify());try FileManager.default.removeItem(at:policyPath)
        try original.write(to:policyPath);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:policyPath.path);XCTAssertThrowsError(try verify())
    }
    func testSeparateDeclarationsCannotChangeDuringNativeVerification()throws{
        let (root,manifest,policy,key)=try fixture(),declarations=try directory()
        try write(sign(manifest,key:key),to:declarations.appendingPathComponent(PluginPackageRules.manifestName));try write(sign(policy,key:key),to:declarations.appendingPathComponent(PluginPackageRules.policyName))
        XCTAssertThrowsError(try PluginPackageRules.verify(root:root,declarationsRoot:declarations,publicKey:key.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,now:now,implementationDigest:{_ in manifest.implementationDigest},validateCode:{_,_ in var changed=policy;changed.version+=1;try self.write(self.sign(changed,key:key),to:declarations.appendingPathComponent(PluginPackageRules.policyName))}))
    }
    func testVersionTwoManagedLayoutIsExplicitAndNeverAcceptedByLegacyOrCore()throws{
        let required=ManagedPayloadRules.requiredPaths(for:.advancedCLI,format:2),exec=ManagedPayloadRules.executablePaths(for:.advancedCLI,format:2)
        let files=required.sorted().map{ManagedReleaseFile(path:$0,sha256:String(repeating:"a",count:64),bytes:$0=="publisher.pub" ? 32:1,executable:exec.contains($0))}
        XCTAssertNoThrow(try ManagedPayloadRules.validate(files,product:.advancedCLI,format:2));XCTAssertThrowsError(try ManagedPayloadRules.validate(files,product:.advancedCLI));XCTAssertThrowsError(try ManagedPayloadRules.validate(files,product:.coreCLI,format:2))
        XCTAssertFalse(required.contains("render-catalog.videomodules"));XCTAssertTrue(required.contains("plugins/video.game.videoplugin/manifest.videoplugin"));XCTAssertEqual(ManagedPayloadRules.requiredPaths(for:.advancedCLI).count,8)
    }
    func testSubprocessSourcePublicationInventoryRequiresExplicitNewFormat()throws{
        XCTAssertEqual(try ModuleCatalogPublicationRules.sourcePaths(pluginID:"video.game").count,2)
        XCTAssertEqual(try ModuleCatalogPublicationRules.sourcePaths(pluginID:"video.game",executionFormat:2),["Sources/VideoGame/GameModule.swift","Sources/VideoGame/LICENSE","Sources/VideoGamePlugin/main.swift"])
        XCTAssertThrowsError(try ModuleCatalogPublicationRules.sourcePaths(pluginID:"video.game",executionFormat:3))
    }
    func testThreeReadOnlyProbeResponsesRequireMatchingDescriptorAndPhysicalExit()throws{
        let (_,manifest,_,_)=try fixture();let requests=try PluginPackageProbeRules.requests(now:now);XCTAssertEqual(requests.map(\.method),[.handshake,.describe,.health]);XCTAssertFalse(try PluginPackageProbeRules.input(requests).isEmpty)
        func transcript(exit:Bool=true,wrong:Bool=false,healthState:String="idle")throws->Data {var data=Data();for r in requests {let d=PluginDescription(pluginID:wrong ? "other":manifest.module.id,capabilityID:manifest.module.capabilities[0],version:manifest.module.version);let response=PluginRPCResponse(requestID:r.requestID,ok:true,state:r.method == .health ? healthState:"ready",descriptor:d);var object=try JSONSerialization.jsonObject(with:Codec.data(response)) as! [String:Any];object["__video_transport"]=["event":"response","peer_pid":12345];data.append(try JSONSerialization.data(withJSONObject:object));data.append(10)};if exit{data.append(Data("{\"__video_transport\":{\"event\":\"peer_exited\",\"peer_pid\":12345}}\n".utf8))};return data}
        XCTAssertNoThrow(try PluginPackageProbeRules.validate(transcript(),requests:requests,manifest:manifest));XCTAssertThrowsError(try PluginPackageProbeRules.validate(transcript(exit:false),requests:requests,manifest:manifest));XCTAssertThrowsError(try PluginPackageProbeRules.validate(transcript(wrong:true),requests:requests,manifest:manifest));XCTAssertThrowsError(try PluginPackageProbeRules.validate(transcript(healthState:"running"),requests:requests,manifest:manifest));XCTAssertThrowsError(try PluginPackageProbeRules.validate(transcript(healthState:"closing"),requests:requests,manifest:manifest))
    }

    /// Pure protocol DTOs only: these records never authorize a package or claim
    /// a real peer. Signed native Publisher preflight is verified independently.
    private func currentProbe(_ id:String,_ schema:Int)throws->(PluginPackageManifest,[PluginRPCRequest],PluginDescription) {
        let module=PluginManifest(id:id,version:"1.3.0",capabilities:[PluginPackageRules.capabilities[id]!],inputSchema:schema,implementationDigest:String(repeating:"a",count:64),permissions:[])
        let manifest=PluginPackageManifest(module:module,execution:try PluginExecutionDescriptor(pluginID:id,architecture:"x86_64"),files:[])
        return(manifest,try PluginPackageProbeRules.requests(now:now),PluginDescription(pluginID:id,capabilityID:module.capabilities[0],version:module.version,inputSchemaVersion:schema))
    }
    private func probeTranscript(_ requests:[PluginRPCRequest],_ description:PluginDescription)throws->Data {
        var data=Data()
        for request in requests {
            let reply=PluginRPCResponse(requestID:request.requestID,ok:true,state:request.method == .health ? "idle":"ready",descriptor:description)
            var object=try JSONSerialization.jsonObject(with:Codec.data(reply)) as! [String:Any]
            object["__video_transport"]=["event":"response","peer_pid":12345]
            data.append(try JSONSerialization.data(withJSONObject:object));data.append(10)
        }
        data.append(Data("{\"__video_transport\":{\"event\":\"peer_exited\",\"peer_pid\":12345}}\n".utf8));return data
    }
    func testCurrentServiceSchemasUseMatchingPublicationDefaultsAndKeepExplicitLegacySelection()throws {
        for (id,schema,legacy) in [("video.game",6,2),("video.cartoon",4,1)] {
            let (manifest,requests,description)=try currentProbe(id,schema)
            let transcript=try probeTranscript(requests,description)
            var defaultManifest=manifest
            defaultManifest.module.inputSchema=try PluginInputCompatibility.publicationSchema(pluginID:id)
            XCTAssertEqual(defaultManifest.module.inputSchema,schema)
            XCTAssertEqual(try PluginInputCompatibility.publicationSchema(pluginID:id,requested:String(schema)),schema)
            XCTAssertNoThrow(try PluginPackageProbeRules.validate(transcript,requests:requests,manifest:defaultManifest))
            var old=manifest
            old.module.inputSchema=try PluginInputCompatibility.publicationSchema(pluginID:id,requested:String(legacy))
            XCTAssertEqual(old.module.inputSchema,legacy)
            XCTAssertThrowsError(try PluginPackageProbeRules.validate(transcript,requests:requests,manifest:old),"Legacy declarations must not silently describe a current service")
        }
    }
    func testCurrentReadOnlyProbeRejectsRealDescriptorContractDrift()throws {
        for (id,schema) in [("video.game",6),("video.cartoon",4)] {
            let (manifest,requests,original)=try currentProbe(id,schema)
            for change in 0..<8 {
                var description=original
                switch change {
                case 0:description.version="9.0.0"
                case 1:description.inputSchemaVersion=1
                case 2:description.outputSchemaVersion=2
                case 3:description.methods.removeLast()
                case 4:description.capabilityID="other.capability"
                case 5:description.pluginID="other.plugin"
                case 6:description.filesystemAccess=true
                default:description.networkAccess=true
                }
                XCTAssertThrowsError(try PluginPackageProbeRules.validate(probeTranscript(requests,description),requests:requests,manifest:manifest),"Descriptor drift \(id) \(change)")
            }
        }
    }
    func testPublisherProbeWireCannotRequestMakingOrClosingCustomerTasks()throws {
        let (_,requests,_)=try currentProbe("video.game",6)
        for method in [PluginMethod.validate,.estimate,.execute,.progress,.cancel] {
            var changed=requests;changed[1].method=method
            XCTAssertThrowsError(try PluginPackageProbeRules.input(changed))
        }
        var changed=requests;changed[1].taskID="customer-task"
        XCTAssertThrowsError(try PluginPackageProbeRules.input(changed))
    }
}
