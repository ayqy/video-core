import Foundation

/// Only these storyboard values can cross the collaboration boundary. Product facts,
/// references, rights, approvals and workspace data are deliberately absent.
public struct CloudSceneChange: Codable, Equatable, Sendable {
    public var title:String
    public var body:String
    public var narration:String
    public var durationFrames:Int
    public var targetIndex:Int
    public init(scene:Scene,index:Int) {title=scene.title;body=scene.body;narration=scene.narration;durationFrames=scene.durationFrames;targetIndex=index}
    private enum CodingKeys:String,CodingKey {case title,body,narration,durationFrames,targetIndex}
    private struct Key:CodingKey {var stringValue:String;var intValue:Int?{nil};init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}}
    public init(from decoder:Decoder)throws {
        let all=try decoder.container(keyedBy:Key.self)
        let allowed=Set(["title","body","narration","durationFrames","targetIndex"])
        guard Set(all.allKeys.map(\.stringValue))==allowed else{throw VideoError.permission("分镜提案只能修改标题、正文、旁白、时长和顺序，不能附带产品或素材字段")}
        let values=try decoder.container(keyedBy:CodingKeys.self)
        title=try values.decode(String.self,forKey:.title);body=try values.decode(String.self,forKey:.body);narration=try values.decode(String.self,forKey:.narration);durationFrames=try values.decode(Int.self,forKey:.durationFrames);targetIndex=try values.decode(Int.self,forKey:.targetIndex)
    }
}

public struct CloudStoryboardProposal:Codable,Identifiable,Sendable {
    public var id:String
    public var revisionID:String
    public var revisionDigest:String
    public var sceneID:String
    public var sceneDigest:String
    public var change:CloudSceneChange
    public var reason:String
    /// Constructed from the CloudKit creator, never from a client-supplied name.
    public var authorID:String
    public var createdAt:Date
    public init(id:String,revisionID:String,revisionDigest:String,sceneID:String,sceneDigest:String,change:CloudSceneChange,reason:String,authorID:String,createdAt:Date) {
        self.id=id;self.revisionID=revisionID;self.revisionDigest=revisionDigest;self.sceneID=sceneID;self.sceneDigest=sceneDigest;self.change=change;self.reason=reason;self.authorID=authorID;self.createdAt=createdAt
    }
}

public struct CloudProposalDiff:Identifiable,Sendable {
    public var field:String;public var before:String;public var after:String
    public var id:String{field}
}
public struct CloudProposalAppliedRevision:Codable,Sendable {
    public var revisionID:String;public var revisionDigest:String
    public init(revisionID:String,revisionDigest:String){self.revisionID=revisionID;self.revisionDigest=revisionDigest}
}
public struct CloudProposalReceipt:Codable,Identifiable,Sendable {
    public var id:String;public var proposalID:String;public var proposalDigest:String
    public var applied:CloudProposalAppliedRevision;public var authorID:String;public var createdAt:Date
    public init(id:String,proposalID:String,proposalDigest:String,applied:CloudProposalAppliedRevision,authorID:String,createdAt:Date){self.id=id;self.proposalID=proposalID;self.proposalDigest=proposalDigest;self.applied=applied;self.authorID=authorID;self.createdAt=createdAt}
}
/// All IDs and permission facts must originate in CloudKit system records/share membership.
public struct CloudProposalServerProof:Sendable {
    public var ownerID:String;public var creatorID:String;public var modifierID:String;public var activeWriter:Bool
    public init(ownerID:String,creatorID:String,modifierID:String,activeWriter:Bool){self.ownerID=ownerID;self.creatorID=creatorID;self.modifierID=modifierID;self.activeWriter=activeWriter}
}

public enum CloudProposalRules {
    public static func authorizeRecord(_ proof:CloudProposalServerProof,envelope:CloudReviewEnvelope,now:Date=Date())throws->String {
        try CloudReviewRules.validate(envelope,now:now)
        guard envelope.role == .collaborator,!proof.ownerID.isEmpty,!proof.creatorID.isEmpty,proof.creatorID != proof.ownerID,proof.creatorID==proof.modifierID,proof.activeWriter else{throw VideoError.permission("提案作者不是当前可写协作者，或服务器记录曾被其他身份改写")}
        return Codec.hash(Data(proof.creatorID.utf8))
    }
    public static func requireViewedDigest(_ proposal:CloudStoryboardProposal,expected:String)throws {guard try Codec.digest(proposal)==expected else{throw VideoError.conflict("协作者提案在查看后已变化，请重新逐项核对差异；尚未改动本机工程")}}
    public static func authorizeSubmission(envelope:CloudReviewEnvelope,isOwner:Bool,canWrite:Bool,actorID:String,ownerID:String,now:Date=Date())throws {
        try CloudReviewRules.validate(envelope,now:now)
        guard envelope.role == .collaborator,!isOwner,canWrite,!actorID.isEmpty,!ownerID.isEmpty,actorID != ownerID else{throw VideoError.permission("仅当前已授权、可写的独立协作者能提交分镜提案；品牌审核者仅可批注")}
    }
    public static func validate(_ proposal:CloudStoryboardProposal,envelope:CloudReviewEnvelope,now:Date=Date())throws {
        try CloudReviewRules.validate(envelope,now:now)
        guard envelope.role == .collaborator,proposal.id.range(of:"^[A-Za-z0-9-]{1,80}$",options:.regularExpression) != nil,!proposal.authorID.isEmpty,proposal.revisionID==envelope.scope.revision.id,proposal.revisionDigest==envelope.revisionDigest,
              proposal.createdAt>=envelope.createdAt.addingTimeInterval(-60),proposal.createdAt<=now.addingTimeInterval(60),let scene=envelope.scope.revision.scenes.first(where:{$0.id==proposal.sceneID}),try Codec.digest(scene)==proposal.sceneDigest else{throw VideoError.permission("提案未绑定所授版本、场景或实际服务器身份")}
        guard !scene.locked else{throw VideoError.permission("锁定镜头不能提交修改提案，请作者先另存并重新授权")}
        let change=proposal.change
        guard change.title.count<=200,change.body.count<=8000,change.narration.count<=8000,(1...54000).contains(change.durationFrames),(0..<envelope.scope.revision.scenes.count).contains(change.targetIndex),!proposal.reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,proposal.reason.count<=1000 else{throw VideoError.invalid("提案文字、时长、顺序或修改理由超出范围")}
        guard !(try differences(proposal,envelope:envelope)).isEmpty else{throw VideoError.invalid("提案没有分镜改动")}
        var updated=scene;updated.title=change.title;updated.body=change.body;updated.narration=change.narration;updated.durationFrames=change.durationFrames
        // Validate timing against existing media/layers/captions. The author can make a
        // separate revision to resolve conflicts; a proposal never silently trims them.
        try updated.validate(assets:envelope.scope.assets)
    }
    public static func differences(_ proposal:CloudStoryboardProposal,envelope:CloudReviewEnvelope)throws->[CloudProposalDiff] {
        guard let index=envelope.scope.revision.scenes.firstIndex(where:{$0.id==proposal.sceneID}) else{throw VideoError.notFound("提案场景不在授权版本内")}
        let scene=envelope.scope.revision.scenes[index],change=proposal.change
        var values:[CloudProposalDiff]=[]
        func add(_ field:String,_ before:String,_ after:String){if before != after{values.append(CloudProposalDiff(field:field,before:before,after:after))}}
        add("标题",scene.title,change.title);add("正文",scene.body,change.body);add("旁白",scene.narration,change.narration)
        add("原始时长（帧）",String(scene.durationFrames),String(change.durationFrames));add("镜头顺序",String(index+1),String(change.targetIndex+1))
        return values
    }
    public static func changeMessage(_ proposal:CloudStoryboardProposal)throws->String {"接收 iCloud 协作者分镜提案 "+proposal.id+" / "+(try Codec.digest(proposal))}
    /// The local scope must be freshly reconstructed from the immutable base. Scoped
    /// products intentionally omit unrelated assets, so a full-project digest is different.
    public static func edits(_ proposal:CloudStoryboardProposal,envelope:CloudReviewEnvelope,localScope:ScopedRevision,project:Project,now:Date=Date())throws->[Edit] {
        try validate(proposal,envelope:envelope,now:now)
        guard project.id==envelope.scope.projectID,project.workspaceID==envelope.scope.revision.workspaceID,project.current.id==proposal.revisionID,localScope.projectID==project.id,localScope.revision.id==proposal.revisionID,try localScope.revision.contentDigest()==proposal.revisionDigest else{throw VideoError.conflict("本机工程已更新或不属于所审版本；请比较新旧版本并重新发起提案，未覆盖现有修改")}
        return try operations(proposal,envelope:envelope)
    }
    private static func operations(_ proposal:CloudStoryboardProposal,envelope:CloudReviewEnvelope)throws->[Edit] {
        guard let original=envelope.scope.revision.scenes.first(where:{$0.id==proposal.sceneID}) else{throw VideoError.notFound("提案场景缺失")}
        var scene=original;scene.title=proposal.change.title;scene.body=proposal.change.body;scene.narration=proposal.change.narration;scene.durationFrames=proposal.change.durationFrames
        var result:[Edit]=[]
        if scene != original{result.append(.replaceScene(scene.id,scene))}
        if envelope.scope.revision.scenes.firstIndex(where:{$0.id==scene.id}) != proposal.change.targetIndex{result.append(.moveScene(scene.id,proposal.change.targetIndex))}
        return result
    }
    /// Recover an already committed acceptance when the cloud receipt upload failed.
    /// This never applies the edit again and does not accept a coincidental current draft.
    public static func committedRevision(_ proposal:CloudStoryboardProposal,envelope:CloudReviewEnvelope,localScope:ScopedRevision,project:Project,now:Date=Date())throws->CloudProposalAppliedRevision? {
        try validate(proposal,envelope:envelope,now:now)
        guard project.id==envelope.scope.projectID,project.workspaceID==envelope.scope.revision.workspaceID,localScope.projectID==project.id,localScope.revision.id==proposal.revisionID,try localScope.revision.contentDigest()==proposal.revisionDigest,let base=project.revisions.first(where:{$0.id==proposal.revisionID}) else{throw VideoError.conflict("原始提案版本或本机工程不匹配，不能补记接收回执")}
        let marker=try changeMessage(proposal)
        guard let committed=project.revisions.first(where:{$0.parentID==base.id && $0.change==marker}) else{return nil}
        var original=project;original.revisions=[base]
        let expected=try Editor.apply(operations(proposal,envelope:envelope),to:original,baseRevision:base.id,assets:envelope.scope.assets,message:marker).current
        guard committed.scenes==expected.scenes,committed.schemaVersion==base.schemaVersion,try Codec.digest(committed.product)==Codec.digest(base.product),committed.contentContext==base.contentContext,committed.cta==base.cta,committed.aspect==base.aspect,committed.purpose==base.purpose,committed.musicAssetID==base.musicAssetID,try Codec.digest(committed.audioQuality)==Codec.digest(base.audioQuality) else{throw VideoError.conflict("本机接收记录与提案内容不符，未补记云端回执")}
        return CloudProposalAppliedRevision(revisionID:committed.id,revisionDigest:try committed.contentDigest())
    }
    public static func validateReceipt(_ receipt:CloudProposalReceipt,proposal:CloudStoryboardProposal,ownerID:String,now:Date=Date())throws {
        guard receipt.proposalID==proposal.id,receipt.proposalDigest == (try Codec.digest(proposal)),receipt.authorID==ownerID,!ownerID.isEmpty,receipt.createdAt>=proposal.createdAt,receipt.createdAt<=now.addingTimeInterval(60),!receipt.applied.revisionID.isEmpty,receipt.applied.revisionID != proposal.revisionID,receipt.applied.revisionDigest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw VideoError.permission("接收回执未由共享作者确认，或未对应提案的新版本")}
    }
}
