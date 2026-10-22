#if os(macOS)
import Foundation
import CSQLite
import Darwin

public struct ManagedInstallResult:Codable,Sendable {
    public var operation:String;public var generation:String;public var version:String;public var build:Int
    public var program:String;public var data:String;public var previousGeneration:String?
    public var note:String
}

/// The shipping CLI supplies a fixed codesign/Gatekeeper/schema/doctor probe. The engine owns
/// verified inventory, SQLite quiescence, complete backup/restore and the one atomic pointer.
public final class ManagedReleaseInstaller {
    public typealias CandidateProbe=(URL,URL,ManagedReleaseManifest)throws->Void
    private let publicKey:Data
    private let architecture:String
    private let osMajor:Int
    private let teamID:String
    private let probe:CandidateProbe
    private let fm=FileManager.default
    public init(publicKey:Data,architecture:String,osMajor:Int,teamID:String,probe:@escaping CandidateProbe){self.publicKey=publicKey;self.architecture=architecture;self.osMajor=osMajor;self.teamID=teamID;self.probe=probe}
    public func status(slot:URL)throws->ManagedInstallResult {
        try validateSlot(slot)
        let current=try active(slot)
        let manifest=try manifest(at:current.url)
        try ManagedReleaseRules.verifyFiles(manifest,root:current.url.appendingPathComponent("program"))
        return result("status",current.state,manifest,slot:slot,note:"已验证签名与受管当前代；不表示已购买、已公证发行或已完成用户验收")
    }
    public func install(package:URL,slot:URL,data sourceData:URL?=nil)throws->ManagedInstallResult {
        let verified=try packageManifest(package)
        try separated(slot,from:package)
        if let sourceData{try separated(slot,from:sourceData)}
        try initializeSlot(slot,product:verified.product)
        return try locked(slot){
            let marker=try String(contentsOf:slot.appendingPathComponent(ManagedInstallRules.slotMarker),encoding:.utf8)
            guard marker.split(separator:"\n").last==Substring(verified.product.rawValue) else{throw VideoError.permission("此slot已登记给其他产品")}
            guard !fm.fileExists(atPath:slot.appendingPathComponent("current").path),!isLink(slot.appendingPathComponent("current")) else{throw VideoError.conflict("受管slot已有当前安装，请使用update；未覆盖")}
            return try prepareAndActivate(operation:"install",manifest:verified,document:try document(at:package),sourceProgram:package.appendingPathComponent("payload"),sourceData:sourceData,slot:slot,previous:nil,rollbackFloor:verified.minimumRollbackBuild,mergePolicyFrom:nil)
        }
    }
    public func update(package:URL,slot:URL)throws->ManagedInstallResult {
        let verified=try packageManifest(package);try separated(slot,from:package);try validateSlot(slot)
        return try locked(slot){
            let current=try active(slot),old=try manifest(at:current.url)
            try ManagedReleaseRules.validateUpgrade(from:old,to:verified)
            guard current.state.product==verified.product else{throw VideoError.permission("更新产品与受管slot不符")}
            try ManagedReleaseRules.verifyFiles(old,root:current.url.appendingPathComponent("program"))
            return try prepareAndActivate(operation:"update",manifest:verified,document:try document(at:package),sourceProgram:package.appendingPathComponent("payload"),sourceData:current.url.appendingPathComponent("data"),slot:slot,previous:current.state.id,rollbackFloor:max(current.state.rollbackFloor,verified.minimumRollbackBuild),mergePolicyFrom:nil)
        }
    }
    public func rollback(slot:URL)throws->ManagedInstallResult {
        try validateSlot(slot)
        return try locked(slot){
            let current=try active(slot),latest=try manifest(at:current.url)
            guard let prior=current.state.previousGeneration,ManagedInstallRules.validID(prior) else{throw VideoError.notFound("没有可回滚的已保留安装代，未改当前程序或数据")}
            let oldURL=slot.appendingPathComponent("generations/"+prior),oldState=try state(at:oldURL),old=try manifest(at:oldURL)
            guard oldState.id==prior,old.product==latest.product,old.architecture==latest.architecture,old.build>=current.state.rollbackFloor else{throw VideoError.permission("旧版本不属于本产品或低于签名发行允许的回滚下限")}
            try ManagedReleaseRules.verifyFiles(old,root:oldURL.appendingPathComponent("program"))
            // Both snapshots are immutable from the installer perspective; create a new rollback generation.
            // Newer business data remains in the previous active generation and is never deleted.
            return try withDataLock(current.url.appendingPathComponent("data")){
                _=try checkedBackup(current.url.appendingPathComponent("data"))
                return try prepareAndActivate(operation:"rollback",manifest:old,document:try document(at:oldURL),sourceProgram:oldURL.appendingPathComponent("program"),sourceData:oldURL.appendingPathComponent("data"),slot:slot,previous:current.state.id,rollbackFloor:current.state.rollbackFloor,mergePolicyFrom:current.url.appendingPathComponent("data"))
            }
        }
    }
    private func prepareAndActivate(operation:String,manifest:ManagedReleaseManifest,document:SignedDocument,sourceProgram:URL,sourceData:URL?,slot:URL,previous:String?,rollbackFloor:Int,mergePolicyFrom:URL?)throws->ManagedInstallResult {
        if let sourceData{return try withDataLock(sourceData){try prepareLocked(operation:operation,manifest:manifest,document:document,sourceProgram:sourceProgram,sourceData:sourceData,slot:slot,previous:previous,rollbackFloor:rollbackFloor,mergePolicyFrom:mergePolicyFrom)}}
        return try prepareLocked(operation:operation,manifest:manifest,document:document,sourceProgram:sourceProgram,sourceData:nil,slot:slot,previous:previous,rollbackFloor:rollbackFloor,mergePolicyFrom:mergePolicyFrom)
    }
    private func prepareLocked(operation:String,manifest:ManagedReleaseManifest,document:SignedDocument,sourceProgram:URL,sourceData:URL?,slot:URL,previous:String?,rollbackFloor:Int,mergePolicyFrom:URL?)throws->ManagedInstallResult {
        let id="gen-"+Codec.id(),temporary=slot.appendingPathComponent("generations/staging-"+Codec.id()),generation=slot.appendingPathComponent("generations/"+id)
        var switched=false,finished=false
        defer {
            try? fm.removeItem(at:temporary)
            if !finished && !switched{try? fm.removeItem(at:generation)}
        }
        try fm.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let program=temporary.appendingPathComponent("program");try fm.createDirectory(at:program,withIntermediateDirectories:false)
        for file in manifest.files {
            let source=sourceProgram.appendingPathComponent(file.path),target=program.appendingPathComponent(file.path)
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try fm.copyItem(at:source,to:target);try fm.setAttributes([.posixPermissions:file.executable ? 0o700:0o600],ofItemAtPath:target.path)
        }
        try ManagedReleaseRules.verifyFiles(manifest,root:program)
        try write(document,to:temporary.appendingPathComponent(ManagedReleaseRules.documentName))
        // Move the unpublished staging pair to its final real path before restoring absolute artifact URLs.
        try fm.moveItem(at:temporary,to:generation)
        let dataRoot=generation.appendingPathComponent("data")
        let before:Data,providers:[ProviderProfile]
        if let sourceData {
            let source=try Repository(root:sourceData,readOnly:true);providers=try source.read().providers;before=try checkedBackup(sourceData)
        }else{providers=[];let empty=try Repository(root:dataRoot);before=try empty.backup();try fm.removeItem(at:dataRoot)}
        try before.write(to:generation.appendingPathComponent("before.videobackup"),options:.atomic)
        let restored=try Repository.restore(before,to:dataRoot)
        if !providers.isEmpty{try restored.transaction{$0.providers=providers}}
        try mergePolicies(from:sourceData,additional:mergePolicyFrom,to:dataRoot)
        // Rollback restores the old business snapshot, but never resurrects a superseded or
        // removed licence. Preserve the latest signed licence verbatim, including revocation
        // and expiry; the runtime must revalidate it and this operation grants no entitlement.
        let licence=try independentLicense(at:mergePolicyFrom ?? sourceData)
        if let licence{try licence.write(to:dataRoot.appendingPathComponent("independent.videolicense"),options:.atomic)}
        let highestPolicies=try policies(dataRoot)
        let after=try restored.backup()
        guard try semanticDigest(before)==semanticDigest(after) else{throw VideoError.conflict("备份恢复后的工程/许可/版本/账本不一致，未切换安装")}
        try probe(generation.appendingPathComponent("program"),dataRoot,manifest)
        // Candidate self-check must not silently edit the data it was asked to inspect.
        guard try semanticDigest(after)==semanticDigest(restored.backup()) else{throw VideoError.conflict("候选程序自检意外改写数据，未切换安装")}
        guard try independentLicense(at:dataRoot)==licence else{throw VideoError.conflict("候选程序自检改写独立许可，未切换安装")}
        guard try policies(dataRoot)==highestPolicies else{throw VideoError.conflict("候选程序自检改写策略最高版本，未切换安装")}
        try ManagedReleaseRules.verifyFiles(manifest,root:generation.appendingPathComponent("program"))
        let state=ManagedInstallGeneration(id:id,product:manifest.product,previousGeneration:previous,manifestDigest:try Codec.digest(manifest),rollbackFloor:rollbackFloor,dataDigest:try semanticDigest(after))
        try write(state,to:generation.appendingPathComponent(ManagedInstallRules.markerName))
        return try withDataLock(dataRoot){
            try switchPointer(slot,to:id);switched=true
            do {
                let checked=try active(slot);guard checked.state.id==id else{throw VideoError.conflict("切换后当前安装代不符")}
                try probe(generation.appendingPathComponent("program"),dataRoot,manifest)
                guard try semanticDigest(after)==semanticDigest(Repository(root:dataRoot,readOnly:true).backup()) else{throw VideoError.conflict("切换后自检改写数据，正在回退程序与数据")}
                guard try independentLicense(at:dataRoot)==licence else{throw VideoError.conflict("切换后独立许可不一致，正在回退程序与数据")}
                guard try policies(dataRoot)==highestPolicies else{throw VideoError.conflict("切换后策略最高版本不一致，正在回退程序与数据")}
                try ManagedReleaseRules.verifyFiles(manifest,root:generation.appendingPathComponent("program"))
                finished=true
                return result(operation,state,manifest,slot:slot,note:operation=="rollback" ? "程序与数据已同时回到先前兼容快照；更新后的数据完整保留在上一安装代，安全策略最高版本未回退":"程序与数据已作为同一代原子切换；原数据/备份/上一程序均保留。签名校验不是付款或上架证明")
            }catch {
                if let previous{try switchPointer(slot,to:previous)}else{try fm.removeItem(at:slot.appendingPathComponent("current"))}
                switched=false
                throw VideoError.unavailable("新版本切换后自检失败，已同时恢复原程序和原数据；原始错误未当作成功")
            }
        }
    }
    private func checkedBackup(_ root:URL)throws->Data {
        try rejectLinks(root)
        let repository=try Repository(root:root,readOnly:true),database=try repository.read();try database.validate()
        guard !database.jobs.contains(where:{$0.state == .running || ($0.lease?.expiresAt ?? .distantPast)>Date()}) else{throw VideoError.unavailable("存在运行中或持有租约的制作任务，请先完成/停止原任务；未开始更新")}
        return try repository.backup()
    }
    private func semanticDigest(_ backup:Data)throws->String {
        let value=try PropertyListDecoder().decode(Repository.Backup.self,from:backup)
        guard value.version==2,Codec.hash(value.snapshot)==value.digest else{throw VideoError.invalid("更新备份封套或摘要不符")}
        var snapshot=try Codec.decoder().decode(Database.self,from:value.snapshot);snapshot.generation=0;snapshot.providers=[]
        struct Fingerprint:Encodable{var snapshot:Database;var assets:[String:String];var exports:[String:String]}
        return try Codec.digest(Fingerprint(snapshot:snapshot,assets:value.assets.mapValues(Codec.hash),exports:(value.exports ?? [:]).mapValues(Codec.hash)))
    }
    private func policies(_ root:URL?)throws->[String:Int] {
        guard let root else{return[:]};let file=root.appendingPathComponent(".video-advanced-policy.plist")
        guard fm.fileExists(atPath:file.path) else{return[:]}
        try regular(file,limit:65536)
        let value=try PropertyListDecoder().decode([String:Int].self,from:Data(contentsOf:file))
        guard value.count<=128,value.allSatisfy({$0.key.range(of:"^[a-z0-9][a-z0-9.-]{1,95}$",options:.regularExpression) != nil && $0.value>0}) else{throw VideoError.permission("已有高级策略最高版本损坏，未清空防回退记录")};return value
    }
    private func mergePolicies(from source:URL?,additional:URL?,to target:URL)throws {
        var value=try policies(source)
        for (id,version) in try policies(additional){value[id]=max(value[id] ?? 0,version)}
        if !value.isEmpty{try write(value,to:target.appendingPathComponent(".video-advanced-policy.plist"))}
    }
    private struct PreservedLicense:Decodable {
        var id:String;var subject:String;var pluginIDs:Set<String>;var issuedAt:Date;var expiresAt:Date?;var revoked:Bool
    }
    private func independentLicense(at root:URL?)throws->Data? {
        guard let root else{return nil};let file=root.appendingPathComponent("independent.videolicense")
        guard fm.fileExists(atPath:file.path) else{return nil}
        try regular(file,limit:2*1024*1024)
        let bytes=try Data(contentsOf:file)
        guard bytes.starts(with:Data("bplist00".utf8)) else{throw VideoError.permission("已有独立许可封套损坏；未删除或换发许可")}
        let signed=try PropertyListDecoder().decode(SignedDocument.self,from:bytes)
        let value=try signed.verified(as:PreservedLicense.self,publicKey:publicKey)
        guard !value.id.isEmpty,value.id.utf8.count<=200,!value.subject.isEmpty,value.subject.utf8.count<=200,!value.pluginIDs.isEmpty,value.pluginIDs.isSubset(of:["video.game","video.cartoon"]),value.issuedAt<=Date().addingTimeInterval(300),value.expiresAt == nil || value.expiresAt!>value.issuedAt else{throw VideoError.permission("已有独立许可结构不合法；未删除或改写原件")}
        // Do not turn an expired or revoked signed record into a fresh valid licence.
        return bytes
    }
    private func packageManifest(_ package:URL)throws->ManagedReleaseManifest {
        try ManagedReleaseRules.safeDirectory(package)
        let value=try manifest(at:package);try ManagedReleaseRules.verifyFiles(value,root:package.appendingPathComponent("payload"));return value
    }
    private func document(at directory:URL)throws->SignedDocument {
        let url=directory.appendingPathComponent(ManagedReleaseRules.documentName);try regular(url,limit:4*1024*1024)
        let data=try Data(contentsOf:url);guard data.starts(with:Data("bplist00".utf8)) else{throw VideoError.permission("发行材料须为已签名的二进制封套")};return try PropertyListDecoder().decode(SignedDocument.self,from:data)
    }
    private func manifest(at directory:URL)throws->ManagedReleaseManifest {try ManagedReleaseRules.verified(document(at:directory),publicKey:publicKey,architecture:architecture,osMajor:osMajor,teamID:teamID)}
    private func state(at directory:URL)throws->ManagedInstallGeneration {let url=directory.appendingPathComponent(ManagedInstallRules.markerName);try regular(url,limit:65536);let value=try PropertyListDecoder().decode(ManagedInstallGeneration.self,from:Data(contentsOf:url));guard value.format==1,ManagedInstallRules.validID(value.id),value.id==directory.lastPathComponent else{throw VideoError.permission("受管安装代记录损坏")};return value}
    private func active(_ slot:URL)throws->(state:ManagedInstallGeneration,url:URL) {
        let target=try fm.destinationOfSymbolicLink(atPath:slot.appendingPathComponent("current").path),parts=target.split(separator:"/")
        guard parts.count==2,parts[0]=="generations",ManagedInstallRules.validID(String(parts[1])) else{throw VideoError.permission("current不是受管相对指针，拒绝跟随其他位置")}
        let directory=slot.appendingPathComponent(target);try ManagedReleaseRules.safeDirectory(directory)
        let state=try state(at:directory),release=try manifest(at:directory)
        guard state.product==release.product,state.manifestDigest==(try Codec.digest(release)),state.rollbackFloor>=release.minimumRollbackBuild else{throw VideoError.permission("受管代与发行签名不一致")}
        return(state,directory)
    }
    private func initializeSlot(_ slot:URL,product:ManagedReleaseProduct)throws {
        try ManagedReleaseRules.safeDirectory(slot)
        if fm.fileExists(atPath:slot.path){guard (try fm.contentsOfDirectory(atPath:slot.path)).isEmpty else{try validateSlot(slot);return}}
        else{try fm.createDirectory(at:slot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        try fm.createDirectory(at:slot.appendingPathComponent("generations"),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try Data(("VideoManagedSlot-v1\n"+product.rawValue+"\n").utf8).write(to:slot.appendingPathComponent(ManagedInstallRules.slotMarker),options:.atomic)
    }
    private func validateSlot(_ slot:URL)throws {
        try ManagedReleaseRules.safeDirectory(slot);let marker=slot.appendingPathComponent(ManagedInstallRules.slotMarker);try regular(marker,limit:256)
        guard let text=String(data:try Data(contentsOf:marker),encoding:.utf8),text.hasPrefix("VideoManagedSlot-v1\n"),ManagedReleaseProduct(rawValue:text.split(separator:"\n").last.map(String.init) ?? "") != nil else{throw VideoError.permission("目录不是本安装器登记的slot；不接管或清理现有文件")}
        try ManagedReleaseRules.safeDirectory(slot.appendingPathComponent("generations"))
    }
    private func switchPointer(_ slot:URL,to id:String)throws {
        guard ManagedInstallRules.validID(id) else{throw VideoError.invalid("安装代ID不合法")}
        let next=slot.appendingPathComponent("next-"+Codec.id());defer{try? fm.removeItem(at:next)}
        try fm.createSymbolicLink(atPath:next.path,withDestinationPath:"generations/"+id)
        guard rename(next.path,slot.appendingPathComponent("current").path)==0 else{throw VideoError.unavailable("受管程序/数据指针原子切换失败，旧安装保留")}
    }
    private func locked<T>(_ slot:URL,_ action:()throws->T)throws->T {
        let descriptor=open(slot.appendingPathComponent("install.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard descriptor>=0 else{throw VideoError.unavailable("无法锁定受管安装slot")};defer{close(descriptor)}
        guard flock(descriptor,LOCK_EX|LOCK_NB)==0 else{throw VideoError.unavailable("另一安装操作尚在进行，请等待原操作")};defer{flock(descriptor,LOCK_UN)}
        return try action()
    }
    private func withDataLock<T>(_ root:URL,_ action:()throws->T)throws->T {
        try ManagedReleaseRules.safeDirectory(root)
        let file=root.appendingPathComponent("workspace.sqlite");try regular(file,limit:512*1024*1024)
        var database:OpaquePointer?
        guard sqlite3_open_v2(file.path,&database,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,let database else{if database != nil{sqlite3_close(database)};throw VideoError.unavailable("无法锁定原数据；原安装未变")}
        defer{sqlite3_close(database)};sqlite3_busy_timeout(database,1000)
        guard sqlite3_exec(database,"BEGIN IMMEDIATE",nil,nil,nil)==SQLITE_OK else{throw VideoError.unavailable("原数据正在写入，未开始更新；请沿原工作区稍后重试")}
        defer{sqlite3_exec(database,"ROLLBACK",nil,nil,nil)}
        return try action()
    }
    private func regular(_ file:URL,limit:Int)throws {
        let value=try fm.attributesOfItem(atPath:file.path)
        guard value[.type] as? FileAttributeType == .typeRegular,((value[.referenceCount] as? NSNumber)?.intValue ?? 0)==1,let bytes=(value[.size] as? NSNumber)?.intValue,bytes>0,bytes<=limit else{throw VideoError.permission("受管文件不是体积受限的普通单链接文件")}
    }
    private func rejectLinks(_ root:URL)throws {
        try ManagedReleaseRules.safeDirectory(root)
        guard let items=fm.enumerator(at:root,includingPropertiesForKeys:nil) else{throw VideoError.invalid("无法检查源数据目录")}
        while let item=items.nextObject() as? URL {let value=try fm.attributesOfItem(atPath:item.path);let type=value[.type] as? FileAttributeType;guard type == .typeDirectory || (type == .typeRegular && ((value[.referenceCount] as? NSNumber)?.intValue ?? 0)==1) else{throw VideoError.permission("源数据包含软链接、硬链接或设备节点；未复制外部内容")}}
    }
    private func separated(_ slot:URL,from other:URL)throws {let a=slot.standardizedFileURL.path,b=other.standardizedFileURL.path;guard a != b,!a.hasPrefix(b+"/"),!b.hasPrefix(a+"/") else{throw VideoError.invalid("安装slot必须与发行payload/原数据分开，避免递归复制或覆盖")}}
    private func isLink(_ url:URL)->Bool {((try? fm.attributesOfItem(atPath:url.path)[.type]) as? FileAttributeType) == .typeSymbolicLink}
    private func write<T:Encodable>(_ value:T,to url:URL)throws {let encoder=PropertyListEncoder();encoder.outputFormat = .binary;try encoder.encode(value).write(to:url,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    private func result(_ operation:String,_ state:ManagedInstallGeneration,_ manifest:ManagedReleaseManifest,slot:URL,note:String)->ManagedInstallResult {ManagedInstallResult(operation:operation,generation:state.id,version:manifest.version,build:manifest.build,program:slot.appendingPathComponent("current/program/"+manifest.product.entrypoint).path,data:slot.appendingPathComponent("current/data").path,previousGeneration:state.previousGeneration,note:note)}
}
#endif
