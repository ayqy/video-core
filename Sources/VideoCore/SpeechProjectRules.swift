import Foundation

/// A confirmed local speech operation binds one exact source scene and revision.
public struct SpeechProjectRequest: Codable, Sendable {
    public var workspaceID: String
    public var projectID: String
    public var sceneID: String
    public var baseRevision: String
    public var assetID: String?
    public var command: String {assetID == nil ? "speech synthesize":"speech attach"}
    public var plan: SpeechPlan
    public var extendScene: Bool
    public var timeoutSeconds: Int
    public var requestID: String
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id", projectID = "project_id", sceneID = "scene_id", baseRevision = "base_revision", plan = "speech_plan", extendScene = "extend_scene", timeoutSeconds = "timeout_seconds", requestID = "request_id", assetID = "asset_id" }
    public init(workspaceID: String, projectID: String, sceneID: String, baseRevision: String, plan: SpeechPlan, extendScene: Bool = false, timeoutSeconds: Int = 180, requestID: String = Codec.id(), assetID: String? = nil) {
        self.workspaceID=workspaceID; self.projectID=projectID; self.sceneID=sceneID; self.baseRevision=baseRevision; self.plan=plan; self.extendScene=extendScene; self.timeoutSeconds=timeoutSeconds; self.requestID=requestID;self.assetID=assetID
    }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        workspaceID=try c.decode(String.self,forKey:.workspaceID);projectID=try c.decode(String.self,forKey:.projectID);sceneID=try c.decode(String.self,forKey:.sceneID);baseRevision=try c.decode(String.self,forKey:.baseRevision);plan=try c.decode(SpeechPlan.self,forKey:.plan);requestID=try c.decode(String.self,forKey:.requestID)
        assetID=try c.decodeIfPresent(String.self,forKey:.assetID)
        extendScene=try c.decodeIfPresent(Bool.self,forKey:.extendScene) ?? false;timeoutSeconds=try c.decodeIfPresent(Int.self,forKey:.timeoutSeconds) ?? 180
    }
    public func validate() throws {
        guard [workspaceID,projectID,sceneID,baseRevision,requestID].allSatisfy({ !$0.isEmpty && $0.utf8.count<=200 }), (5...900).contains(timeoutSeconds) else { throw VideoError.invalid("配音标识或有限超时无效（5至900秒）") }
        try plan.validate()
        guard plan.confirmed else { throw VideoError.review("请明确确认完整原文、规范稿、术语读法和所选声音后生成") }
        if assetID == nil {guard let voice=plan.voiceIdentifier,!voice.isEmpty else { throw VideoError.invalid("请明确选择本机中文声音标识，不会自动替代") }}
        else {guard let assetID,!assetID.isEmpty,assetID.utf8.count<=200 else {throw VideoError.invalid("导入声音标识无效")}}
    }
}

public enum SpeechProjectRules {
    public static let command = "speech synthesize"
    /// A take always refers to the complete registered recording. Playback speed
    /// changes its presentation length, never the number of selected source frames.
    /// Historical snapshots remain decodable; editing a new take and producing a
    /// new artifact must both enforce this boundary.
    public static func validateCompleteTake(_ take: VoiceTake, workspaceID: String, assets: [Asset]) throws {
        guard let asset=assets.first(where:{$0.id==take.assetID && $0.workspaceID==workspaceID}),
              asset.mediaType=="audio",let frames=asset.durationFrames,frames>0,
              take.durationFrames==frames else {
            throw VideoError.review("配音须引用同工作区已登记时长的完整音频原件；请重新绑定完整配音，禁止截短句尾")
        }
    }
    /// Replay checks authorization too, but permits the original revision after success.
    public static func authorize(_ request: SpeechProjectRequest, database: Database, principal: String) throws -> Project {
        try request.validate()
        return try WorkspaceAccessRules.editingProject(projectID:request.projectID,baseRevision:request.baseRevision,operations:[],access:.init(workspaceID:request.workspaceID,principal:principal),in:database)
    }
    /// No synthesis, repository writes, CAS writes or entitlement changes.
    public static func prepare(_ request: SpeechProjectRequest, database: Database, principal: String) throws -> Scene {
        let project=try authorize(request,database:database,principal:principal)
        guard !project.archived, project.current.id==request.baseRevision else { throw VideoError.conflict("配音基准版本已变化或项目已归档；不会覆盖新版本") }
        guard project.current.fps==30, let scene=project.current.scenes.first(where:{$0.id==request.sceneID}) else { throw VideoError.invalid("配音镜头不存在或工程帧率不受支持") }
        guard request.plan.source==scene.narration else { throw VideoError.conflict("配音确认稿不属于当前镜头原文，请重新规范并确认") }
        var draft=scene;draft.speechPlan=request.plan;draft.voice=nil;draft.captions=[]
        _=try Editor.apply([.replaceScene(scene.id,draft)],to:project,baseRevision:request.baseRevision,assets:database.assets,message:"配音只读预检")
        return scene
    }
    /// Caller must verify the actual CAS bytes before this atomic metadata commit.
    @discardableResult public static func apply(_ request: SpeechProjectRequest, asset: Asset, evidence: Evidence, take: VoiceTake, captions: [Caption], database: inout Database, principal: String) throws -> Project {
        let scene=try prepare(request,database:database,principal:principal)
        try validateCompleteTake(take,workspaceID:request.workspaceID,assets:[asset])
        guard asset.workspaceID==request.workspaceID,asset.mediaType=="audio",asset.bytes>0,asset.hash.count==64,asset.evidenceID==evidence.id,evidence.assetID==asset.id,evidence.workspaceID==request.workspaceID,
              !take.listened,captions.allSatisfy({!$0.confirmed && $0.alignment=="estimated_sentence_no_word_timestamps"}) else { throw VideoError.invalid("真实配音、源凭据、未听审或估计字幕状态不一致") }
        if let importedID=request.assetID {
            guard importedID==asset.id,take.method=="imported-recording",let stored=database.assets.first(where:{$0.id==asset.id}),try Codec.digest(stored)==Codec.digest(asset),let rights=database.evidence.first(where:{$0.id==evidence.id}),try Codec.digest(rights)==Codec.digest(evidence),evidence.usable(commercial:database.projects.first(where:{$0.id==request.projectID})!.current.purpose != .education) else {throw VideoError.permission("导入配音源、工作区许可或适用使用范围已变化或未核对")}
        } else {
            guard !evidence.verified,!evidence.commercialAllowed,!evidence.uploadConsent,take.method=="local_system_speech:"+(request.plan.voiceIdentifier ?? "") else {throw VideoError.invalid("系统声音生成不能声明已听审或商用授权")}
        }
        guard take.durationFrames<=scene.durationFrames || request.extendScene else { throw VideoError.review("实际配音较长；请明确延长镜头后生成，禁止截断句尾") }
        var updated=try StoryboardTiming.extending(scene:scene,to:max(scene.durationFrames,take.durationFrames))
        updated.speechPlan=request.plan
        guard take.textDigest == (try SpeechRules.digest(updated)) else { throw VideoError.conflict("配音实际稿摘要不一致") }
        try SpeechRules.validateCaptions(captions,durationFrames:take.durationFrames)
        let expected=try SpeechRules.captions(request.plan,durationFrames:take.durationFrames)
        guard captions.count==expected.count,zip(captions,expected).allSatisfy({$0.text==$1.text && $0.startFrame==$1.startFrame && $0.endFrame==$1.endFrame}) else {throw VideoError.conflict("新配音字幕须保留完整确认原文的估计句段，不能替换内容") }
        updated.voice=take;updated.captions=captions
        var staged=database
        guard let index=staged.projects.firstIndex(where:{$0.id==request.projectID && $0.workspaceID==request.workspaceID}) else { throw VideoError.conflict("配音标识已存在或工程已变化") }
        if request.assetID == nil {
            guard !staged.assets.contains(where:{$0.id==asset.id}),!staged.evidence.contains(where:{$0.id==evidence.id}) else {throw VideoError.conflict("新配音源或凭据标识已存在")}
            staged.assets.append(asset);staged.evidence.append(evidence)
        }
        var project=try Editor.apply([.replaceScene(scene.id,updated)],to:staged.projects[index],baseRevision:request.baseRevision,assets:staged.assets,message:"生成本机真实中文配音；听审、字幕及声音权利待核")
        project.revisions[project.revisions.count-1].dependencies=try DependencyRules.freeze(revision:project.current,assets:staged.assets,evidence:staged.evidence)
        staged.projects[index]=project
        for i in staged.publications.indices where staged.publications[i].projectID==project.id {staged.publications[i].stale=true}
        try staged.validate();database=staged
        return project
    }
}
