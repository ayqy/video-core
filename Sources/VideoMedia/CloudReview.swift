import Foundation
#if (os(iOS) || os(macOS)) && canImport(CloudKit)
import CloudKit
import Combine
import VideoCore
#endif

/// Addresses only: no preview, payload, token, contact handle or user-entered identity is persisted.
public struct CloudReviewLocation: Codable, Identifiable, Sendable {
    public var id:String
    public var accountKey:String
    public var containerIdentifier:String
    public var zoneName:String
    public var zoneOwner:String
    public var rootName:String
    public var shareName:String
    public var owned:Bool
    /// Pin the first authenticated version; a later owner edit cannot silently replace an already accepted draft.
    public var revisionID:String?
    public var revisionDigest:String?
    public var payloadDigest:String?
    #if (os(iOS) || os(macOS)) && canImport(CloudKit)
    public var recordID:CKRecord.ID {CKRecord.ID(recordName:rootName,zoneID:CKRecordZone.ID(zoneName:zoneName,ownerName:zoneOwner))}
    public var shareID:CKRecord.ID {CKRecord.ID(recordName:shareName,zoneID:recordID.zoneID)}
    #endif
}

/// Replacing the active view must not erase another iCloud account's private addresses.
/// This contains only local address values; it never grants server access or changes a share.
enum CloudReviewLocationPersistence {
    static func replacingPartition(stored:[CloudReviewLocation],current:[CloudReviewLocation],accountKey:String,containerIdentifier:String)->[CloudReviewLocation] {
        func active(_ value:CloudReviewLocation)->Bool {value.accountKey==accountKey && value.containerIdentifier==containerIdentifier}
        return stored.filter{!active($0)}+current.filter(active)
    }
}

#if (os(iOS) || os(macOS)) && canImport(CloudKit)
public struct CloudReviewSession {
    public var envelope:CloudReviewEnvelope
    public var annotations:[CloudReviewAnnotation]
    public var proposals:[CloudStoryboardProposal]
    public var proposalReceipts:[CloudProposalReceipt]
    public var previewURL:URL
    public var canComment:Bool
    public var authorizedUntil:Date
    public var share:CKShare
}

public struct CloudReviewInvitation:Identifiable {
    public var id:String
    public var share:CKShare
    public var container:CKContainer
    public var location:CloudReviewLocation
}

/// Only these direct children belong to a managed review. A single matching
/// pointer is insufficient: never delete a record attached to another root.
enum CloudReviewDeletionRules {
    static func childIDs(_ records:[CKRecord],rootID:CKRecord.ID,types:Set<String>) throws -> [CKRecord.ID] {
        var result:Set<CKRecord.ID>=[]
        for record in records {
            let parent=record.parent?.recordID,reference=(record["root"] as? CKRecord.Reference)?.recordID
            guard parent==rootID || reference==rootID else{continue}
            guard record.recordID != rootID,record.recordID.zoneID==rootID.zoneID,parent==rootID,reference==rootID,types.contains(record.recordType) else{throw VideoError.permission("此份审稿存在结构不符的云记录；未扩大删除范围，入口保留以便重试")}
            result.insert(record.recordID)
        }
        return result.sorted{$0.recordName<$1.recordName}
    }
}

/// Real private CKShare hierarchy. An account/network/configuration failure never produces a local substitute.
@MainActor public final class NativeCloudReview:ObservableObject {
    public static let shared=NativeCloudReview()
    @Published public private(set) var locations:[CloudReviewLocation]=[]
    @Published public private(set) var accountDescription="尚未检查 iCloud 账户"
    @Published public private(set) var lastError:String?
    @Published public private(set) var invalidation=0
    private let defaultsKey="VideoCloudReviewLocations-v1"
    private let zoneName="VideoScopedReviews-v1"
    private let rootType="VideoScopedReview"
    private let commentType="VideoReviewComment"
    private let proposalType="VideoStoryboardProposal"
    private let receiptType="VideoProposalReceipt"
    private var accountID:CKRecord.ID?
    private var observer:NSObjectProtocol?
    private var acceptedInFlight:Set<String>=[]
    private var deletingLocations:Set<String>=[]
    private struct CachedVersion {var changeTag:String?;var payloadDigest:String;var envelope:CloudReviewEnvelope;var previewURL:URL}
    private var versions:[String:CachedVersion]=[:]
    private var cacheRoot:URL {FileManager.default.temporaryDirectory.appendingPathComponent("VideoCloudReview",isDirectory:true)}
    private init() {
        purgeCache()
        observer=NotificationCenter.default.addObserver(forName:.CKAccountChanged,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.accountID=nil;self?.locations=[];self?.accountDescription="iCloud 账户已变化，请重新核验";self?.invalidate()}}
    }
    public func configuredContainer() throws -> CKContainer {
        guard Bundle.main.object(forInfoDictionaryKey:"CKSharingSupported") as? Bool == true,let identifier=Bundle.main.object(forInfoDictionaryKey:"VideoCloudContainerIdentifier") as? String,identifier.hasPrefix("iCloud."),!identifier.contains(" ") else {throw VideoError.unavailable("尚未配置 CloudKit 私有审稿能力：需要签名容器、iCloud entitlement 与共享接收配置")}
        return CKContainer(identifier:identifier)
    }
    @discardableResult public func connect() async throws -> CKContainer {
        let epoch=invalidation
        do {
            let container=try configuredContainer()
            let status=try await container.accountStatus()
            guard epoch==invalidation else{throw VideoError.permission("账户核验期间状态已变化，旧结果不能恢复身份或入口")}
            switch status {
            case .available:break
            case .noAccount:throw VideoError.permission("此设备尚未登录 iCloud，请在系统设置登录真实 Apple ID 后重试")
            case .restricted:throw VideoError.permission("此设备的 iCloud/CloudKit 访问受到系统或组织限制")
            case .couldNotDetermine,.temporarilyUnavailable:throw VideoError.unavailable("暂时不能核验 iCloud 账户；保持停止访问，请联网后重试")
            @unknown default:throw VideoError.unavailable("当前 iCloud 账户状态不支持审稿")
            }
            let user=try await container.userRecordID()
            guard epoch==invalidation else{throw VideoError.permission("账户核验期间状态已变化，旧结果不能恢复身份或入口")}
            if let previous=accountID,previous != user {invalidate()}
            accountID=user
            let key=Codec.hash(Data(user.recordName.utf8))
            locations=storedLocations().filter{$0.accountKey==key && $0.containerIdentifier==container.containerIdentifier}
            accountDescription="已由 iCloud 验证当前 Apple ID · "+String(key.prefix(10));lastError=nil
            return container
        } catch {
            // An older request must not clear a newly authenticated account's
            // description, addresses or cache after CKAccountChanged.
            guard epoch==invalidation else{throw VideoError.permission("账户核验已过期，当前账户状态与缓存保持不变")}
            accountDescription="iCloud 尚不可用";lastError=message(error);invalidate();throw VideoError.unavailable(message(error))
        }
    }
    public func create(envelope:CloudReviewEnvelope,previewURL:URL) async throws -> CloudReviewInvitation {
        try Task.checkCancellation()
        let container=try await connect()
        guard let actor=accountID else{throw VideoError.permission("发起创建时的实际 iCloud 身份未核验")}
        let epoch=invalidation
        func checkSession() throws {
            guard epoch==invalidation,accountID==actor else{throw VideoError.permission("创建期间 iCloud 账户或会话已变化，未保存本机地址或交付分享入口。云端可能已保存，请切回发起创建时的原 iCloud 账户核验；不会自动删除或重建云稿。")}
            try Task.checkCancellation()
        }
        do {
            try checkSession();try CloudReviewRules.validate(envelope)
            let preview=try Data(contentsOf:previewURL,options:.mappedIfSafe)
            guard previewURL.isFileURL,preview.count==envelope.preview.bytes,Codec.hash(preview)==envelope.preview.sha256 else {throw VideoError.conflict("所选预览文件与冻结版本摘要不符，未上传")}
            let database=container.privateCloudDatabase
            let zone=CKRecordZone(zoneName:zoneName)
            try checkSession()
            let zones=try await database.modifyRecordZones(saving:[zone],deleting:[])
            try checkSession()
            guard let zoneResult=zones.saveResults[zone.zoneID] else{throw VideoError.unavailable("CloudKit 未返回私有分区保存结果")};_=try zoneResult.get()
            // A new root and share for every request/version; there is intentionally no payload-update API.
            let record=CKRecord(recordType:rootType,recordID:CKRecord.ID(recordName:envelope.id,zoneID:zone.zoneID))
            let staging=cacheRoot.appendingPathComponent("upload-"+Codec.id(),isDirectory:true)
            try createPrivateDirectory(staging)
            defer{try? FileManager.default.removeItem(at:staging)}
            let payload=try Codec.data(envelope),payloadURL=staging.appendingPathComponent("version.reviewpayload"),videoURL=staging.appendingPathComponent("preview.mp4")
            try writePrivate(payload,to:payloadURL);try writePrivate(preview,to:videoURL)
            record["payload"]=CKAsset(fileURL:payloadURL);record["preview"]=CKAsset(fileURL:videoURL)
            record["payloadDigest"]=Codec.hash(payload) as CKRecordValue
            record["expiresAt"]=envelope.expiresAt as CKRecordValue
            let share=CKShare(rootRecord:record);share.publicPermission = .none
            share[CKShare.SystemFieldKey.title]="待审 · "+envelope.scope.projectName+" · v\(envelope.scope.revision.number)" as CKRecordValue
            try checkSession()
            let result=try await database.modifyRecords(saving:[record,share],deleting:[],savePolicy:.ifServerRecordUnchanged,atomically:true)
            try checkSession()
            guard let rootResult=result.saveResults[record.recordID],let shareResult=result.saveResults[share.recordID],let savedShare=try shareResult.get() as? CKShare else{throw VideoError.unavailable("CloudKit 未确认完整版本和私有共享保存")};_=try rootResult.get()
            guard savedShare.publicPermission == .none,savedShare.url != nil else{throw VideoError.permission("CloudKit 未返回私有邀请，未展示分享入口")}
            var location=try location(root:record.recordID,share:savedShare.recordID,container:container,owned:true)
            location.revisionID=envelope.scope.revision.id;location.revisionDigest=envelope.revisionDigest;location.payloadDigest=Codec.hash(payload)
            try checkSession()
            save(location);lastError=nil
            return CloudReviewInvitation(id:location.id,share:savedShare,container:container,location:location)
        } catch {
            // An in-flight save may already have reached CloudKit. Stop local
            // delivery without deleting/recreating a record under another account.
            try checkSession()
            throw error
        }
    }
    public func accept(_ metadata:CKShare.Metadata) async {
        let id=metadata.share.recordID.recordName
        guard !acceptedInFlight.contains(id) else{return};acceptedInFlight.insert(id);defer{acceptedInFlight.remove(id)}
        var epoch=invalidation,actor=accountID
        do {
            let container=try await connect()
            epoch=invalidation;actor=accountID
            try checkSession(epoch:epoch,actor:actor)
            guard metadata.containerIdentifier==container.containerIdentifier,let root=metadata.hierarchicalRootRecordID,metadata.share.recordID.recordName != CKRecordNameZoneWideShare,metadata.share.publicPermission == .none else {throw VideoError.permission("邀请不是此应用的指定版本私有共享，拒绝整库或公开共享")}
            let share:CKShare
            if metadata.participantStatus == .accepted || metadata.participantRole == .owner {share=metadata.share}
            else {let results=try await container.accept([metadata]);try checkSession(epoch:epoch,actor:actor);guard let result=results[metadata] else{throw VideoError.unavailable("CloudKit 未确认接受结果")};share=try result.get()}
            let acceptedRoot=CKRecord.ID(recordName:root.recordName,zoneID:share.recordID.zoneID)
            var location=try location(root:acceptedRoot,share:share.recordID,container:container,owned:metadata.participantRole == .owner)
            if let existing=locations.first(where:{$0.id==location.id}) {location=existing}
            // Fetch server-authorized records before persisting the address or showing any preview.
            let session=try await read(location)
            try checkSession(epoch:epoch,actor:actor)
            location.revisionID=session.envelope.scope.revision.id;location.revisionDigest=session.envelope.revisionDigest;location.payloadDigest=try Codec.digest(session.envelope)
            save(location);lastError=nil
        } catch {
            // An old invitation must not close or overwrite a newly connected account.
            guard epoch==invalidation,actor==accountID else{return}
            lastError=message(error);invalidate()
        }
    }
    public func accept(url:URL) async {
        var epoch=invalidation,actor=accountID
        do {
            guard url.scheme?.lowercased()=="https",["icloud.com","www.icloud.com"].contains(url.host?.lowercased() ?? ""),url.user==nil,url.password==nil,url.path.hasPrefix("/share/") else {throw VideoError.invalid("仅接受 Apple iCloud 的私有共享邀请链接")}
            let container=try await connect()
            epoch=invalidation;actor=accountID
            let metadata=try await container.shareMetadata(for:url)
            try checkSession(epoch:epoch,actor:actor)
            await accept(metadata)
        } catch {
            guard epoch==invalidation,actor==accountID else{return}
            lastError=message(error);invalidate()
        }
    }
    public func read(_ location:CloudReviewLocation) async throws -> CloudReviewSession {
        var epoch=invalidation,actor=accountID
        do {
            guard !deletingLocations.contains(location.id) else{throw VideoError.unavailable("此份云端审稿正在删除，已停止读取")}
            let container=try await connect()
            epoch=invalidation;actor=accountID
            try checkSession(epoch:epoch,actor:actor);try checkAddress(location,container:container)
            let database=location.owned ? container.privateCloudDatabase:container.sharedCloudDatabase
            let records=try await fetch([location.recordID,location.shareID],database:database,desiredKeys:["payloadDigest","expiresAt"])
            try checkSession(epoch:epoch,actor:actor)
            guard var root=records[location.recordID],let share=records[location.shareID] as? CKShare,root.recordType==rootType,root.parent==nil,root.share?.recordID==share.recordID,let payloadDigest=root["payloadDigest"] as? String else{throw VideoError.permission("指定共享版本缺失或结构不符，停止预览")}
            try authorize(root:root,share:share,owned:location.owned)
            let envelope:CloudReviewEnvelope,local:URL
            if let cached=versions[location.id],cached.changeTag==root.recordChangeTag,cached.payloadDigest==payloadDigest,FileManager.default.fileExists(atPath:cached.previewURL.path) {
                envelope=cached.envelope;local=cached.previewURL
            } else {
                let full=try await fetch([location.recordID],database:database)
                // Account invalidation purges the old cache. Never recreate it
                // from an in-flight download belonging to that old session.
                try checkSession(epoch:epoch,actor:actor)
                guard let complete=full[location.recordID],complete.recordChangeTag==root.recordChangeTag,let payloadAsset=complete["payload"] as? CKAsset,let payloadURL=payloadAsset.fileURL,let previewAsset=complete["preview"] as? CKAsset,let remoteURL=previewAsset.fileURL else{throw VideoError.permission("指定版本下载时发生变化或预览缺失")}
                root=complete;try authorize(root:root,share:share,owned:location.owned)
                let data=try Data(contentsOf:payloadURL,options:.mappedIfSafe)
                guard payloadDigest==Codec.hash(data) else{throw VideoError.conflict("送审版本数据摘要不符")}
                envelope=try Codec.decoder().decode(CloudReviewEnvelope.self,from:data);try CloudReviewRules.validate(envelope)
                let video=try Data(contentsOf:remoteURL,options:.mappedIfSafe)
                guard video.count==envelope.preview.bytes,Codec.hash(video)==envelope.preview.sha256 else{throw VideoError.conflict("云端预览不属于所审版本，停止播放")}
                let directory=cacheRoot.appendingPathComponent(location.id,isDirectory:true)
                try createPrivateDirectory(directory)
                local=directory.appendingPathComponent(envelope.preview.sha256+".mp4")
                try writePrivate(video,to:local)
            }
            try CloudReviewRules.validate(envelope)
            guard location.revisionID.map({$0==envelope.scope.revision.id}) ?? true,location.revisionDigest.map({$0==envelope.revisionDigest}) ?? true,location.payloadDigest.map({$0==payloadDigest}) ?? true else{throw VideoError.conflict("作者送审内容或授权已变化，旧邀请不能替换已接收版本；请要求新版本邀请")}
            guard envelope.id==root.recordID.recordName,let expiry=root["expiresAt"] as? Date,abs(expiry.timeIntervalSince(envelope.expiresAt))<1 else{throw VideoError.permission("送审版本标识或授权期限与云记录不符")}
            let annotations=try await comments(root:root,share:share,envelope:envelope,database:database,owned:location.owned)
            try checkSession(epoch:epoch,actor:actor)
            let proposals=try await storyboardProposals(root:root,share:share,envelope:envelope,database:database,owned:location.owned)
            try checkSession(epoch:epoch,actor:actor)
            let receipts=try await proposalReceipts(root:root,share:share,proposals:proposals,database:database,owned:location.owned)
            try checkSession(epoch:epoch,actor:actor)
            // A participant could revoke access while downloading. Check again before issuing a short playback lease.
            let latest=try await fetch([location.recordID,location.shareID],database:database,desiredKeys:["payloadDigest","expiresAt"])
            try checkSession(epoch:epoch,actor:actor)
            guard let checkedRoot=latest[location.recordID],let checkedShare=latest[location.shareID] as? CKShare,checkedRoot.recordChangeTag==root.recordChangeTag else{throw VideoError.permission("审稿读取期间版本或权限发生变化，请重试")}
            try authorize(root:checkedRoot,share:checkedShare,owned:location.owned)
            try CloudReviewRules.validate(envelope)
            try checkAddress(location,container:container)
            try checkSession(epoch:epoch,actor:actor)
            try Task.checkCancellation()
            versions[location.id]=CachedVersion(changeTag:root.recordChangeTag,payloadDigest:payloadDigest,envelope:envelope,previewURL:local)
            lastError=nil
            let activeProposals=proposals.filter{proposal in activeWriter(authorID:proposal.authorID,share:checkedShare,owned:location.owned)}
            let activeIDs=Set(activeProposals.map(\.id))
            return CloudReviewSession(envelope:envelope,annotations:annotations,proposals:activeProposals,proposalReceipts:receipts.filter{activeIDs.contains($0.proposalID)},previewURL:local,canComment:checkedShare.currentUserParticipant?.permission == .readWrite || checkedShare.currentUserParticipant?.role == .owner,authorizedUntil:min(envelope.expiresAt,Date().addingTimeInterval(10)),share:checkedShare)
        } catch {
            // A stale read may report its own failure, but cannot evict a cache
            // belonging to a later account or a fresh authorization generation.
            if epoch==invalidation,actor==accountID {lastError=message(error);clearCache(location)}
            throw VideoError.permission(message(error))
        }
    }
    public func append(location:CloudReviewLocation,sceneID:String?,frame:Int,element:String,text:String) async throws {
        let session=try await read(location)
        guard session.canComment,let accountID else{throw VideoError.permission("当前真实 iCloud 参与者没有批注写权限")}
        let author=opaque(accountID),envelope=session.envelope
        let annotation=CloudReviewAnnotation(id:Codec.id(),revisionID:envelope.scope.revision.id,revisionDigest:envelope.revisionDigest,sceneID:sceneID,frame:frame,element:element,text:text,authorID:author,createdAt:Date())
        try CloudReviewRules.validateAnnotation(annotation,envelope:envelope)
        let container=try configuredContainer(),database=location.owned ? container.privateCloudDatabase:container.sharedCloudDatabase
        let record=CKRecord(recordType:commentType,recordID:CKRecord.ID(recordName:annotation.id,zoneID:location.recordID.zoneID))
        record.parent=CKRecord.Reference(recordID:location.recordID,action:.none)
        record["root"]=CKRecord.Reference(recordID:location.recordID,action:.none)
        record["revisionID"]=annotation.revisionID as CKRecordValue;record["revisionDigest"]=annotation.revisionDigest as CKRecordValue
        record["sceneID"]=(sceneID ?? "") as CKRecordValue;record["frame"]=NSNumber(value:frame);record["element"]=element as CKRecordValue;record["text"]=text as CKRecordValue
        // No author, role, approval or client timestamp field is written; the server supplies identity and time.
        let results=try await database.modifyRecords(saving:[record],deleting:[],savePolicy:.ifServerRecordUnchanged,atomically:true)
        guard let result=results.saveResults[record.recordID] else{throw VideoError.unavailable("CloudKit 未确认批注保存")};let saved=try result.get()
        guard let creator=saved.creatorUserRecordID,canonical(creator,owned:location.owned)==canonical(accountID,owned:location.owned),saved.lastModifiedUserRecordID==saved.creatorUserRecordID else {throw VideoError.permission("批注服务器身份不符，未登记为当前参与者意见")}
        _=try await read(location)
    }
    public func propose(location:CloudReviewLocation,sceneID:String,change:CloudSceneChange,reason:String) async throws {
        let session=try await read(location)
        guard let accountID,let owner=session.share.owner.userIdentity.userRecordID else{throw VideoError.permission("缺少当前实际 iCloud 身份")}
        let actor=canonical(accountID,owned:location.owned),ownerID=canonical(owner,owned:location.owned)
        try CloudProposalRules.authorizeSubmission(envelope:session.envelope,isOwner:session.share.currentUserParticipant?.role == .owner,canWrite:session.canComment,actorID:actor,ownerID:ownerID)
        guard !location.owned,let scene=session.envelope.scope.revision.scenes.first(where:{$0.id==sceneID}) else{throw VideoError.permission("只能修改此份授权内的分镜")}
        let value=CloudStoryboardProposal(id:Codec.id(),revisionID:session.envelope.scope.revision.id,revisionDigest:session.envelope.revisionDigest,sceneID:sceneID,sceneDigest:try Codec.digest(scene),change:change,reason:reason,authorID:opaque(accountID),createdAt:Date())
        try CloudProposalRules.validate(value,envelope:session.envelope)
        let payload=try Codec.data(change)
        guard payload.count<=65536 else{throw VideoError.invalid("分镜提案超过64KiB，未上传")}
        let container=try configuredContainer(),database=container.sharedCloudDatabase
        let record=CKRecord(recordType:proposalType,recordID:CKRecord.ID(recordName:value.id,zoneID:location.recordID.zoneID))
        record.parent=CKRecord.Reference(recordID:location.recordID,action:.none);record["root"]=CKRecord.Reference(recordID:location.recordID,action:.none)
        record["revisionID"]=value.revisionID as CKRecordValue;record["revisionDigest"]=value.revisionDigest as CKRecordValue
        record["sceneID"]=value.sceneID as CKRecordValue;record["sceneDigest"]=value.sceneDigest as CKRecordValue
        record["change"]=payload as CKRecordValue;record["reason"]=reason as CKRecordValue
        // The server supplies creator/modifier/date; participants never edit the owner root.
        let results=try await database.modifyRecords(saving:[record],deleting:[],savePolicy:.ifServerRecordUnchanged,atomically:true)
        guard let result=results.saveResults[record.recordID] else{throw VideoError.unavailable("CloudKit 未确认提案保存；请查询原版本，不自动重复提交")}
        let saved=try result.get()
        guard let creator=saved.creatorUserRecordID,canonical(creator,owned:false)==actor,saved.lastModifiedUserRecordID==creator else{throw VideoError.permission("提案服务器身份与当前协作者不符")}
        let fresh=try await read(location)
        guard fresh.proposals.contains(where:{$0.id==value.id}) else{throw VideoError.permission("提案保存后授权发生变化，未登记为可接收意见")}
    }
    /// The closure must atomically commit through the ordinary owner editor, or return
    /// a previously committed matching revision. A receipt is written only afterwards.
    public func acceptProposal(location:CloudReviewLocation,proposalID:String,proposalDigest:String,apply:@MainActor (CloudStoryboardProposal,CloudReviewEnvelope)throws->CloudProposalAppliedRevision) async throws -> CloudProposalAppliedRevision {
        guard location.owned else{throw VideoError.permission("受邀参与者不能接收自己的提案")}
        let session=try await read(location)
        guard session.envelope.role == .collaborator,session.share.currentUserParticipant?.role == .owner,let accountID,let owner=session.share.owner.userIdentity.userRecordID,canonical(accountID,owned:true)==canonical(owner,owned:true),let proposal=session.proposals.first(where:{$0.id==proposalID}) else{throw VideoError.permission("当前真实作者无权接收此提案，或协作者授权已撤销")}
        try CloudProposalRules.requireViewedDigest(proposal,expected:proposalDigest)
        if let receipt=session.proposalReceipts.first(where:{$0.proposalID==proposal.id}) {return receipt.applied}
        try CloudProposalRules.validate(proposal,envelope:session.envelope)
        try Task.checkCancellation()
        // No await is permitted between this fresh authorization and the local transaction.
        let applied=try apply(proposal,session.envelope)
        guard applied.revisionID != proposal.revisionID,applied.revisionDigest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw VideoError.conflict("本机尚未提交提案对应的新版本，未记录云端接收")}
        // Recheck expiry/account/revocation after the transaction and before publishing a receipt.
        let checked=try await read(location)
        guard checked.share.currentUserParticipant?.role == .owner,let same=checked.proposals.first(where:{$0.id==proposal.id}),try Codec.digest(same)==Codec.digest(proposal) else{throw VideoError.permission("本机已保存新版本，但共享授权变化，未发送接收回执；原工程保留")}
        let receiptID="accepted-"+proposal.id,container=try configuredContainer()
        let receipt=CKRecord(recordType:receiptType,recordID:CKRecord.ID(recordName:receiptID,zoneID:location.recordID.zoneID))
        receipt.parent=CKRecord.Reference(recordID:location.recordID,action:.none);receipt["root"]=CKRecord.Reference(recordID:location.recordID,action:.none)
        receipt["proposalID"]=proposal.id as CKRecordValue;receipt["proposalDigest"]=(try Codec.digest(proposal)) as CKRecordValue
        receipt["revisionID"]=applied.revisionID as CKRecordValue;receipt["revisionDigest"]=applied.revisionDigest as CKRecordValue
        do {
            let results=try await container.privateCloudDatabase.modifyRecords(saving:[receipt],deleting:[],savePolicy:.ifServerRecordUnchanged,atomically:true)
            guard let result=results.saveResults[receipt.recordID] else{throw VideoError.unavailable("CloudKit 未返回接收回执")}
            let saved=try result.get()
            guard let creator=saved.creatorUserRecordID,canonical(creator,owned:true)==canonical(accountID,owned:true),saved.lastModifiedUserRecordID==creator else{throw VideoError.permission("接收回执服务器作者不符")}
            let verified=try await read(location)
            guard verified.proposalReceipts.contains(where:{$0.id==receiptID && $0.applied.revisionID==applied.revisionID}) else{throw VideoError.unavailable("云端接收回执尚未核验")}
        } catch {throw VideoError.unavailable("本机已保存提案的新版本；云端回执尚未确认。可重新核验并补记回执，不会再次应用提案。")}
        return applied
    }
    public func invitation(_ location:CloudReviewLocation) async throws -> CloudReviewInvitation {
        guard location.owned else{throw VideoError.permission("只有实际共享所有者可以管理邀请")}
        let session=try await read(location),container=try configuredContainer()
        guard session.share.currentUserParticipant?.role == .owner else{throw VideoError.permission("当前 Apple ID 不是共享所有者")}
        return CloudReviewInvitation(id:location.id,share:session.share,container:container,location:location)
    }
    public func revoke(_ location:CloudReviewLocation) async throws {
        guard location.owned else{throw VideoError.permission("审稿参与者不能撤销作者对所有人的共享，可在本机移除入口")}
        _=try await invitation(location)
        let container=try configuredContainer(),result=try await container.privateCloudDatabase.modifyRecords(saving:[],deleting:[location.shareID],atomically:true)
        guard let deleted=result.deleteResults[location.shareID] else{throw VideoError.unavailable("CloudKit 未确认撤销")};try deleted.get()
        // Revoking a share does not erase its author's private root or children.
        // Keep the address so the author can explicitly delete that cloud copy.
        clearCache(location);invalidate()
    }
    /// Deletes one authenticated author's hierarchy, never its shared record zone.
    /// The local address is retained until CloudKit confirms the entire post-state.
    public func deleteReview(_ location:CloudReviewLocation) async throws {
        guard location.owned else{throw VideoError.permission("只有此份云端审稿的实际作者可以删除；受邀者只能移除本机入口")}
        guard !deletingLocations.contains(location.id) else{throw VideoError.unavailable("此份云端审稿已在删除中，请等待当前结果")}
        deletingLocations.insert(location.id);clearCache(location);defer{deletingLocations.remove(location.id)}
        do {
            let container=try await connect();try checkAddress(location,container:container)
            guard let actor=accountID else{throw VideoError.permission("当前真实 iCloud 身份未核验")}
            try checkDeletionAddress(location,container:container,actor:actor)
            let database=container.privateCloudDatabase
            let root=try await existingRecord(location.recordID,database:database)
            let share=try await existingRecord(location.shareID,database:database)
            try checkDeletionAddress(location,container:container,actor:actor)
            if let root {try checkDeletionRoot(root,location:location,actor:actor)}
            if let record=share {
                guard root?.share?.recordID==location.shareID,let share=record as? CKShare,share.recordID==location.shareID,share.publicPermission == .none,share.currentUserParticipant?.role == .owner,let owner=share.owner.userIdentity.userRecordID,canonical(owner,owned:true)==actor.recordName else{throw VideoError.permission("当前 Apple ID 不是此份私有共享的实际作者，未执行删除")}
            }
            // Preflight every existing relationship before the first mutation.
            _=try await deletionChildren(location,database:database)
            try checkDeletionAddress(location,container:container,actor:actor)
            // Stop participant writes first. If a later operation fails, the
            // unchanged local address supports deleting the remaining private copy.
            if share != nil {try await deleteRecords([location.shareID],location:location,container:container,actor:actor)}
            let children=try await deletionChildren(location,database:database)
            try await deleteRecords(children,location:location,container:container,actor:actor)
            if let currentRoot=try await existingRecord(location.recordID,database:database) {try checkDeletionRoot(currentRoot,location:location,actor:actor);try await deleteRecords([location.recordID],location:location,container:container,actor:actor)}
            // A write already in flight can land between the scan and root
            // deletion. The parent no longer exists, so no new valid child can
            // now be created; remove that last bounded snapshot as well.
            let lateChildren=try await deletionChildren(location,database:database)
            try await deleteRecords(lateChildren,location:location,container:container,actor:actor)
            guard try await existingRecord(location.recordID,database:database)==nil,try await existingRecord(location.shareID,database:database)==nil,try await deletionChildren(location,database:database).isEmpty else{throw VideoError.unavailable("CloudKit 尚未确认此份审稿全部删除；入口保留，请重试")}
            try checkDeletionAddress(location,container:container,actor:actor)
            remove(location);invalidate();lastError=nil
        } catch {
            clearCache(location)
            let detail=message(error)
            let failure="此份云端审稿的删除尚未完整确认，入口保留以便重试；共享可能已停止。本地原素材、工程和备份保留。"+detail
            lastError=failure;throw VideoError.unavailable(failure)
        }
    }
    private func checkDeletionRoot(_ root:CKRecord,location:CloudReviewLocation,actor:CKRecord.ID) throws {
        guard root.recordType==rootType,root.recordID==location.recordID,root.parent==nil,let creator=root.creatorUserRecordID,canonical(creator,owned:true)==actor.recordName,root.share?.recordID==nil || root.share?.recordID==location.shareID else{throw VideoError.permission("云端根记录不属于此份作者审稿，未执行删除")}
    }
    private func checkDeletionAddress(_ location:CloudReviewLocation,container:CKContainer,actor:CKRecord.ID) throws {
        try checkAddress(location,container:container)
        let expected=Codec.hash(Data((location.containerIdentifier+location.zoneOwner+location.zoneName+location.rootName).utf8))
        guard accountID==actor,location.owned,location.id==expected,location.zoneOwner==CKCurrentUserDefaultName || location.zoneOwner==actor.recordName,storedLocations().contains(where:{$0.owned && $0.id==location.id && $0.accountKey==location.accountKey && $0.containerIdentifier==location.containerIdentifier && $0.zoneName==location.zoneName && $0.zoneOwner==location.zoneOwner && $0.rootName==location.rootName && $0.shareName==location.shareName}) else{throw VideoError.permission("删除地址、当前 iCloud 作者或本机已核验入口已变化，未扩大删除范围")}
    }
    private func existingRecord(_ id:CKRecord.ID,database:CKDatabase) async throws -> CKRecord? {
        do{return try await fetch([id],database:database,desiredKeys:[])[id]}
        catch let error as CKError where [.unknownItem,.zoneNotFound,.userDeletedZone].contains(error.code){return nil}
    }
    private func deleteRecords(_ ids:[CKRecord.ID],location:CloudReviewLocation,container:CKContainer,actor:CKRecord.ID) async throws {
        for offset in stride(from:0,to:ids.count,by:100) {
            try Task.checkCancellation();try checkDeletionAddress(location,container:container,actor:actor)
            let batch=Array(ids[offset..<min(offset+100,ids.count)])
            guard batch.allSatisfy({$0.zoneID==location.recordID.zoneID}) else{throw VideoError.permission("删除记录越过当前审稿分区")}
            let results=try await container.privateCloudDatabase.modifyRecords(saving:[],deleting:batch,atomically:true)
            for id in batch {guard let result=results.deleteResults[id] else{throw VideoError.unavailable("CloudKit 未返回每条审稿记录的删除确认")};try result.get()}
        }
    }
    private func deletionChildren(_ location:CloudReviewLocation,database:CKDatabase) async throws -> [CKRecord.ID] {
        // Query indexes are eventually consistent. Fetch only relationship and
        // system metadata through the authoritative zone change stream instead;
        // payloads/previews from other reviews are never downloaded here.
        var token:CKServerChangeToken?,records:[CKRecord.ID:CKRecord]=[:]
        for _ in 0..<200 {
            try Task.checkCancellation()
            let page:(modificationResultsByID:[CKRecord.ID:Result<CKDatabase.RecordZoneChange.Modification,Error>],deletions:[CKDatabase.RecordZoneChange.Deletion],changeToken:CKServerChangeToken,moreComing:Bool)
            do{page=try await database.recordZoneChanges(inZoneWith:location.recordID.zoneID,since:token,desiredKeys:["root"],resultsLimit:100)}
            catch let error as CKError where [.zoneNotFound,.userDeletedZone].contains(error.code){return []}
            for (id,result) in page.modificationResultsByID {records[id]=try result.get().record}
            for deletion in page.deletions {records.removeValue(forKey:deletion.recordID)}
            guard records.count<=20000 else{throw VideoError.unavailable("审稿分区记录超过安全核对上限，删除未标成功；入口保留")}
            token=page.changeToken
            if !page.moreComing {return try CloudReviewDeletionRules.childIDs(Array(records.values),rootID:location.recordID,types:[commentType,proposalType,receiptType])}
        }
        throw VideoError.unavailable("CloudKit 分区变更仍未读取完整，删除未标成功；入口保留以便重试")
    }
    public func remove(_ location:CloudReviewLocation) {clearCache(location);locations.removeAll{$0.id==location.id};persist()}
    public func clearCache(_ location:CloudReviewLocation) {versions.removeValue(forKey:location.id);try? FileManager.default.removeItem(at:cacheRoot.appendingPathComponent(location.id));invalidation += 1}
    public func invalidate() {purgeCache();invalidation += 1}
    private func purgeCache(){versions=[:];try? FileManager.default.removeItem(at:cacheRoot)}
    private func fetch(_ ids:[CKRecord.ID],database:CKDatabase,desiredKeys:[String]?=nil) async throws -> [CKRecord.ID:CKRecord] {
        let configuration=CKOperation.Configuration();configuration.timeoutIntervalForRequest=8;configuration.timeoutIntervalForResource=8
        return try await database.configuredWith(configuration:configuration){database in
            let results=try await database.records(for:ids,desiredKeys:desiredKeys)
            return try Dictionary(uniqueKeysWithValues:ids.map{id in guard let result=results[id] else{throw VideoError.unavailable("CloudKit 未确认访问结果")};return(id,try result.get())})
        }
    }
    private func authorize(root:CKRecord,share:CKShare,owned:Bool) throws {
        guard let owner=share.owner.userIdentity.userRecordID,let creator=root.creatorUserRecordID,let modifier=root.lastModifiedUserRecordID,let participant=share.currentUserParticipant else{throw VideoError.permission("CloudKit 未返回可核验的作者/参与者身份")}
        try CloudReviewRules.authorize(CloudReviewServerProof(ownerID:canonical(owner,owned:owned),creatorID:canonical(creator,owned:owned),modifierID:canonical(modifier,owned:owned),privateShare:share.publicPermission == .none,accepted:participant.role == .owner || participant.acceptanceStatus == .accepted,canRead:participant.role == .owner || participant.permission == .readOnly || participant.permission == .readWrite))
        guard !owned || participant.role == .owner else{throw VideoError.permission("此地址不属于当前真实共享所有者")}
    }
    private func comments(root:CKRecord,share:CKShare,envelope:CloudReviewEnvelope,database:CKDatabase,owned:Bool) async throws -> [CloudReviewAnnotation] {
        let query=CKQuery(recordType:commentType,predicate:NSPredicate(format:"root == %@",CKRecord.Reference(recordID:root.recordID,action:.none)))
        var page=try await database.records(matching:query,inZoneWith:root.recordID.zoneID,resultsLimit:100),records:[CKRecord]=[]
        while true {for (_,result) in page.matchResults {records.append(try result.get())};guard let cursor=page.queryCursor else{break};page=try await database.records(continuingMatchFrom:cursor,resultsLimit:100)}
        var output:[CloudReviewAnnotation]=[]
        for record in records {
            guard record.recordType==commentType,record.parent?.recordID==root.recordID,(record["root"] as? CKRecord.Reference)?.recordID==root.recordID,let creator=record.creatorUserRecordID,let modifier=record.lastModifiedUserRecordID,creator==modifier,let created=record.creationDate,let revision=record["revisionID"] as? String,let digest=record["revisionDigest"] as? String,let frame=record["frame"] as? NSNumber,let text=record["text"] as? String,let element=record["element"] as? String else{throw VideoError.permission("批注结构或服务器作者发生变化，拒绝显示被他人改写的意见")}
            let scene=record["sceneID"] as? String
            let annotation=CloudReviewAnnotation(id:record.recordID.recordName,revisionID:revision,revisionDigest:digest,sceneID:scene?.isEmpty == false ? scene:nil,frame:frame.intValue,element:element,text:text,authorID:Codec.hash(Data(canonical(creator,owned:owned).utf8)),createdAt:created)
            try CloudReviewRules.validateAnnotation(annotation,envelope:envelope);output.append(annotation)
        }
        return output.sorted{$0.createdAt<$1.createdAt}
    }
    private func childRecords(type:String,root:CKRecord,database:CKDatabase) async throws -> [CKRecord] {
        let query=CKQuery(recordType:type,predicate:NSPredicate(format:"root == %@",CKRecord.Reference(recordID:root.recordID,action:.none)))
        var page=try await database.records(matching:query,inZoneWith:root.recordID.zoneID,resultsLimit:100),records:[CKRecord]=[]
        while true {
            for (_,result) in page.matchResults {records.append(try result.get())}
            guard records.count<=500 else{throw VideoError.unavailable("此共享超过500条提案或接收记录，请作者另建版本共享，未扩大读取范围")}
            guard let cursor=page.queryCursor else{break}
            page=try await database.records(continuingMatchFrom:cursor,resultsLimit:100)
        }
        return records
    }
    private func activeWriter(authorID:String,share:CKShare,owned:Bool)->Bool {
        share.participants.contains {participant in
            guard participant.role != .owner,participant.acceptanceStatus == .accepted,participant.permission == .readWrite,let id=participant.userIdentity.userRecordID else{return false}
            return Codec.hash(Data(canonical(id,owned:owned).utf8))==authorID
        }
    }
    private func storyboardProposals(root:CKRecord,share:CKShare,envelope:CloudReviewEnvelope,database:CKDatabase,owned:Bool) async throws -> [CloudStoryboardProposal] {
        guard envelope.role == .collaborator else{return []}
        var output:[CloudStoryboardProposal]=[]
        let expected=Set(["root","revisionID","revisionDigest","sceneID","sceneDigest","change","reason"])
        for record in try await childRecords(type:proposalType,root:root,database:database) {
            guard record.recordType==proposalType,record.recordID.zoneID==root.recordID.zoneID,record.parent?.recordID==root.recordID,(record["root"] as? CKRecord.Reference)?.recordID==root.recordID,Set(record.allKeys())==expected,let creator=record.creatorUserRecordID,let modifier=record.lastModifiedUserRecordID,modifier==creator,let date=record.creationDate,let revision=record["revisionID"] as? String,let digest=record["revisionDigest"] as? String,let scene=record["sceneID"] as? String,let sceneDigest=record["sceneDigest"] as? String,let data=record["change"] as? Data,data.count<=65536,let reason=record["reason"] as? String else{throw VideoError.permission("分镜提案结构或服务器作者被改写，拒绝接收")}
            let authorID=Codec.hash(Data(canonical(creator,owned:owned).utf8))
            // Revoked or downgraded participants cannot leave an actionable proposal.
            guard activeWriter(authorID:authorID,share:share,owned:owned) else{continue}
            guard let owner=share.owner.userIdentity.userRecordID else{throw VideoError.permission("提案缺少可核验的共享作者")}
            _=try CloudProposalRules.authorizeRecord(CloudProposalServerProof(ownerID:canonical(owner,owned:owned),creatorID:canonical(creator,owned:owned),modifierID:canonical(modifier,owned:owned),activeWriter:true),envelope:envelope)
            let change=try Codec.decoder().decode(CloudSceneChange.self,from:data)
            let proposal=CloudStoryboardProposal(id:record.recordID.recordName,revisionID:revision,revisionDigest:digest,sceneID:scene,sceneDigest:sceneDigest,change:change,reason:reason,authorID:authorID,createdAt:date)
            try CloudProposalRules.validate(proposal,envelope:envelope);output.append(proposal)
        }
        return output.sorted{$0.createdAt<$1.createdAt}
    }
    private func proposalReceipts(root:CKRecord,share:CKShare,proposals:[CloudStoryboardProposal],database:CKDatabase,owned:Bool) async throws -> [CloudProposalReceipt] {
        guard !proposals.isEmpty else{return []}
        guard let owner=share.owner.userIdentity.userRecordID else{throw VideoError.permission("无法核对接收回执的共享所有者")}
        let ownerID=Codec.hash(Data(canonical(owner,owned:owned).utf8))
        let expected=Set(["root","proposalID","proposalDigest","revisionID","revisionDigest"])
        var output:[CloudProposalReceipt]=[]
        for record in try await childRecords(type:receiptType,root:root,database:database) {
            guard record.recordType==receiptType,record.recordID.zoneID==root.recordID.zoneID,record.parent?.recordID==root.recordID,(record["root"] as? CKRecord.Reference)?.recordID==root.recordID,Set(record.allKeys())==expected,let creator=record.creatorUserRecordID,record.lastModifiedUserRecordID==creator,Codec.hash(Data(canonical(creator,owned:owned).utf8))==ownerID,let date=record.creationDate,let proposalID=record["proposalID"] as? String,let proposalDigest=record["proposalDigest"] as? String,let revision=record["revisionID"] as? String,let revisionDigest=record["revisionDigest"] as? String else{throw VideoError.permission("接收回执未由真实共享作者创建，拒绝使用")}
            guard let proposal=proposals.first(where:{$0.id==proposalID}) else{continue}
            let receipt=CloudProposalReceipt(id:record.recordID.recordName,proposalID:proposalID,proposalDigest:proposalDigest,applied:CloudProposalAppliedRevision(revisionID:revision,revisionDigest:revisionDigest),authorID:ownerID,createdAt:date)
            try CloudProposalRules.validateReceipt(receipt,proposal:proposal,ownerID:ownerID);output.append(receipt)
        }
        return output
    }
    private func canonical(_ id:CKRecord.ID,owned:Bool)->String {if owned && id.recordName==CKCurrentUserDefaultName,let accountID{return accountID.recordName};return id.recordName}
    private func checkSession(epoch:Int,actor:CKRecord.ID?) throws {
        guard let actor,epoch==invalidation,accountID==actor else{throw VideoError.permission("读取期间账户、授权或缓存状态变化，停止预览并重新核验")}
        try Task.checkCancellation()
    }
    private func opaque(_ id:CKRecord.ID)->String {Codec.hash(Data(id.recordName.utf8))}
    private func location(root:CKRecord.ID,share:CKRecord.ID,container:CKContainer,owned:Bool) throws -> CloudReviewLocation {
        guard let accountID,let identifier=container.containerIdentifier else{throw VideoError.permission("实际 iCloud 身份未核验")}
        return CloudReviewLocation(id:Codec.hash(Data((identifier+root.zoneID.ownerName+root.zoneID.zoneName+root.recordName).utf8)),accountKey:opaque(accountID),containerIdentifier:identifier,zoneName:root.zoneID.zoneName,zoneOwner:root.zoneID.ownerName,rootName:root.recordName,shareName:share.recordName,owned:owned,revisionID:nil,revisionDigest:nil,payloadDigest:nil)
    }
    private func checkAddress(_ location:CloudReviewLocation,container:CKContainer) throws {guard let accountID,location.accountKey==opaque(accountID),location.containerIdentifier==container.containerIdentifier,location.zoneName==zoneName,!location.rootName.isEmpty,!location.shareName.isEmpty,location.shareName != CKRecordNameZoneWideShare else{throw VideoError.permission("该审稿入口不属于当前 iCloud 账户或指定版本分区")}}
    private func storedLocations()->[CloudReviewLocation] {guard let data=UserDefaults.standard.data(forKey:defaultsKey) else{return []};return (try? Codec.decoder().decode([CloudReviewLocation].self,from:data)) ?? []}
    private func save(_ location:CloudReviewLocation){locations.removeAll{$0.id==location.id};locations.append(location);persist()}
    private func persist(){
        // CKAccountChanged clears the active identity and view, never the stored partitions.
        guard let accountID,let container=try? configuredContainer(),let identifier=container.containerIdentifier else{return}
        let merged=CloudReviewLocationPersistence.replacingPartition(stored:storedLocations(),current:locations,accountKey:opaque(accountID),containerIdentifier:identifier)
        if let data=try? Codec.data(merged){UserDefaults.standard.set(data,forKey:defaultsKey)}
    }
    private func createPrivateDirectory(_ url:URL) throws {
        try FileManager.default.createDirectory(at:cacheRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cacheRoot.path)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
    }
    private func writePrivate(_ data:Data,to url:URL) throws {
        #if os(iOS)
        try data.write(to:url,options:[.atomic,.completeFileProtection])
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
        #else
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        #endif
    }
    private func message(_ error:Error)->String {
        if let error=error as? VideoError{return error.localizedDescription}
        if let error=error as? CKError {switch error.code {case .notAuthenticated:return "iCloud 身份已失效，请在系统设置核验账户";case .permissionFailure,.unknownItem,.zoneNotFound,.userDeletedZone:return "共享已撤销、账号无权访问或云记录已删除；预览已停止";case .badContainer,.missingEntitlement:return "此签名尚未配置对应 CloudKit 容器或权限，不能进行真实云端审稿";case .networkFailure,.networkUnavailable,.serviceUnavailable,.requestRateLimited:return "暂时不能从 CloudKit 重新核验权限；缓存已关闭，请联网后重试";case .invalidArguments,.serverRejectedRequest:return "CloudKit 容器记录类型/索引或分享配置尚未就绪，请联系应用维护者完成云端配置";default:return "CloudKit 审稿未完成（错误类别 \(error.code.rawValue)），不提供离线权限替代"}}
        return "审稿服务暂不可用，权限核验失败后已停止预览"
    }
}
#endif
