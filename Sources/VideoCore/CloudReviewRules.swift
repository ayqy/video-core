import Foundation

public enum CloudReviewRole: String, Codable, CaseIterable, Sendable {
    case collaborator = "协作者"
    case brandReviewer = "品牌审核者"
}

/// One explicitly selected immutable revision and one preview. This is never a Database export.
public struct CloudReviewEnvelope: Codable, Sendable {
    public var schemaVersion = 1
    public var id = Codec.id()
    public var scope: ScopedRevision
    public var revisionDigest: String
    public var preview: ScopedArtifact
    public var role: CloudReviewRole
    public var createdAt: Date
    public var expiresAt: Date
    public init(scope: ScopedRevision, revisionDigest: String, preview: ScopedArtifact, role: CloudReviewRole, createdAt: Date, expiresAt: Date) {
        self.scope=scope;self.revisionDigest=revisionDigest;self.preview=preview;self.role=role;self.createdAt=createdAt;self.expiresAt=expiresAt
    }
}

/// Values in this proof must come from CloudKit system fields, never editable payload fields.
public struct CloudReviewServerProof: Sendable {
    public var ownerID: String
    public var creatorID: String
    public var modifierID: String
    public var privateShare: Bool
    public var accepted: Bool
    public var canRead: Bool
    public init(ownerID:String,creatorID:String,modifierID:String,privateShare:Bool,accepted:Bool,canRead:Bool) {
        self.ownerID=ownerID;self.creatorID=creatorID;self.modifierID=modifierID;self.privateShare=privateShare;self.accepted=accepted;self.canRead=canRead
    }
}

public struct CloudReviewAnnotation: Codable, Identifiable, Sendable {
    public var id:String
    public var revisionID:String
    public var revisionDigest:String
    public var sceneID:String?
    public var frame:Int
    public var element:String
    public var text:String
    /// A container-scoped hash of the server creator record ID, not a caller-supplied name.
    public var authorID:String
    public var createdAt:Date
    public init(id:String,revisionID:String,revisionDigest:String,sceneID:String?,frame:Int,element:String,text:String,authorID:String,createdAt:Date) {
        self.id=id;self.revisionID=revisionID;self.revisionDigest=revisionDigest;self.sceneID=sceneID;self.frame=frame;self.element=element;self.text=text;self.authorID=authorID;self.createdAt=createdAt
    }
}

public enum CloudReviewRules {
    public static func prepare(scope:ScopedRevision,preview:ScopedArtifact,role:CloudReviewRole,expiresAt:Date,now:Date=Date()) throws -> CloudReviewEnvelope {
        guard scope.artifacts.contains(where:{$0.id==preview.id && $0.jobID==preview.jobID && $0.sha256==preview.sha256 && $0.bytes==preview.bytes && $0.mime==preview.mime}) else {throw VideoError.permission("所选预览不属于指定版本")}
        var value=scope
        // Local author names and historical local comments are not remote authenticated identities.
        value.comments=[];value.revision.review=Review();value.artifacts=[preview]
        let result=CloudReviewEnvelope(scope:value,revisionDigest:try value.revision.contentDigest(),preview:preview,role:role,createdAt:now,expiresAt:expiresAt)
        try validate(result,now:now);return result
    }
    public static func validate(_ value:CloudReviewEnvelope,now:Date=Date()) throws {
        guard value.schemaVersion==1,!value.id.isEmpty,!value.scope.projectID.isEmpty,!value.scope.legacyMaterialsUnfrozen,value.scope.revision.dependencies != nil else {throw VideoError.permission("审稿只接受已冻结来源的明确版本，旧版须由作者核对来源后另存新版")}
        guard value.createdAt<=now.addingTimeInterval(60),value.expiresAt>now,value.expiresAt>value.createdAt else {throw VideoError.permission("此审稿授权已到期或时间无效，请作者重新授权")}
        guard value.scope.comments.isEmpty,try Codec.digest(value.scope.revision.review)==Codec.digest(Review()),value.revisionDigest == (try value.scope.revision.contentDigest()) else {throw VideoError.conflict("共享版本摘要变化，或混入未认证的本机审核/批注")}
        guard value.scope.artifacts.count==1,let artifact=value.scope.artifacts.first,artifact.id==value.preview.id,artifact.sha256==value.preview.sha256,artifact.bytes==value.preview.bytes,artifact.jobID==value.preview.jobID,value.preview.mime=="video/mp4",value.preview.bytes>0,value.preview.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {throw VideoError.invalid("只允许分享明确选择且摘要完整的一份MP4预览")}
        guard let snapshot=value.scope.revision.dependencies,snapshot.workspaceID==value.scope.revision.product.workspaceID else {throw VideoError.permission("来源快照的工作区不符")}
        let rebuilt=try DependencyRules.freeze(revision:value.scope.revision,assets:value.scope.assets,evidence:value.scope.evidence,now:snapshot.capturedAt)
        guard try Codec.digest(snapshot)==Codec.digest(rebuilt),Set(value.scope.assets.map(\.id))==Set(rebuilt.records.compactMap{$0.asset?.id}),Set(value.scope.evidence.map(\.id))==Set(rebuilt.records.compactMap{$0.evidence?.id}),Set(value.scope.revision.product.assetIDs)==Set(value.scope.assets.map(\.id)) else {throw VideoError.permission("共享包含未引用材料或来源快照不一致，拒绝上传")}
        let mappings=Set(value.scope.revision.scenes.flatMap{$0.courseMappingIDs ?? []})
        guard Set((value.scope.revision.product.courseMappings ?? []).map(\.id))==mappings else {throw VideoError.permission("共享包包含其他课程映射")}
        for evidence in value.scope.evidence {
            guard evidence.uploadConsent,evidence.usable(commercial:value.scope.revision.purpose != .education,now:now) else {throw VideoError.permission("所引用的许可/证据未核实、已到期，或未允许上传私有云审稿："+evidence.title)}
        }
        for asset in value.scope.assets {
            guard let id=asset.evidenceID,value.scope.evidence.contains(where:{$0.id==id && $0.uploadConsent}) else {throw VideoError.permission("所引用素材缺少可上传云端的授权记录："+asset.name)}
        }
    }
    public static func authorize(_ proof:CloudReviewServerProof) throws {
        guard proof.privateShare,proof.accepted,proof.canRead,!proof.ownerID.isEmpty,proof.creatorID==proof.ownerID,proof.modifierID==proof.ownerID else {throw VideoError.permission("共享已撤销、并非私有授权，或送审版本曾被非作者改写；停止预览")}
    }
    public static func validateAnnotation(_ value:CloudReviewAnnotation,envelope:CloudReviewEnvelope,now:Date=Date()) throws {
        try validate(envelope,now:now)
        guard value.revisionID==envelope.scope.revision.id,value.revisionDigest==envelope.revisionDigest,!value.authorID.isEmpty,value.createdAt<=now.addingTimeInterval(60) else {throw VideoError.permission("批注未绑定所审版本或缺少服务器身份")}
        let comment=Comment(revisionID:value.revisionID,sceneID:value.sceneID,frame:value.frame,element:value.element,text:value.text,author:value.authorID)
        let project=Project(workspaceID:envelope.scope.revision.product.workspaceID,name:envelope.scope.projectName,revision:envelope.scope.revision)
        try CommentRules.validate(comment,project:project)
    }
}
