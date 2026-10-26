import Foundation
import VideoCore

/// Shared foreground local speech path for the normal CLI and Mac editor.
/// The source audio completes before one optimistic, authorized revision commit.
@MainActor public final class SpeechProjectProduction {
    private let speech=SpeechService()
    private var active:Task<AgentValue,Error>?
    public init() {}
    public func cancel() {active?.cancel();speech.cancel()}
    public func perform(_ request: SpeechProjectRequest, repository: Repository, principal: String, authorizeChanges: (([Project],[Project],[Asset]) throws -> Void)? = nil) async throws -> AgentValue {
        try request.validate()
        guard active == nil else {throw VideoError.conflict("已有前台配音操作，请等待完成或取消")}
        let deadline=Date().addingTimeInterval(Double(request.timeoutSeconds))
        let operation=Task { @MainActor in try await self.execute(request,repository:repository,principal:principal,deadline:deadline,authorizeChanges:authorizeChanges) }
        active=operation
        let timer=Task { @MainActor in
            do {try await Task.sleep(nanoseconds:UInt64(request.timeoutSeconds)*1_000_000_000)} catch {return}
            operation.cancel()
        }
        defer {timer.cancel();active=nil}
        return try await withTaskCancellationHandler(operation:{try await operation.value},onCancel:{operation.cancel()})
    }
    private func execute(_ request:SpeechProjectRequest,repository:Repository,principal:String,deadline:Date,authorizeChanges:(([Project],[Project],[Asset]) throws -> Void)?) async throws -> AgentValue {
        func checkDeadline() throws {
            guard Date()<deadline else {throw VideoError.unavailable("本机配音操作超过明确期限；未写成功回执，原版本保留")}
            try Task.checkCancellation()
        }
        try checkDeadline()
        let data=try AgentMutationExecutor.canonicalInput(command:request.command,data:Codec.data(request),principal:principal,requestID:request.requestID)
        let snapshot=try repository.read()
        _=try SpeechProjectRules.authorize(request,database:snapshot,principal:principal)
        if case .replay(let response)=try AgentContract.replay(command:request.command,data:data,records:snapshot.agentReplayRecords ?? []) {try checkDeadline();return response}
        let scene=try SpeechProjectRules.prepare(request,database:snapshot,principal:principal)
        let production:SpeechProduction
        if let id=request.assetID {
            guard let asset=snapshot.assets.first(where:{$0.id==id && $0.workspaceID==request.workspaceID && $0.mediaType=="audio"}),let evidence=snapshot.evidence.first(where:{$0.id==asset.evidenceID && $0.workspaceID==request.workspaceID && $0.assetID==asset.id}),evidence.usable(commercial:snapshot.projects.first(where:{$0.id==request.projectID})!.current.purpose != .education) else {throw VideoError.permission("请先正常导入真实音轨并核对该源的适用权利")}
            let bytes=try Data(contentsOf:repository.assetURL(asset))
            guard bytes.count==asset.bytes,Codec.hash(bytes)==asset.hash else {throw VideoError.conflict("导入配音真实源已变化，禁止绑定")}
            try checkDeadline()
            let diagnostics=try await AudioInspection.inspect(repository.assetURL(asset))
            guard diagnostics.peakDBFS > -70 else {throw VideoError.review("导入音轨近乎静音，禁止绑定或伪造声音")}
            guard let containerDuration=diagnostics.containerDuration,let registeredFrames=asset.durationFrames else {throw VideoError.review("导入音轨缺少原容器时长或登记帧长，禁止绑定")}
            let frames=try SpeechRules.importedDurationFrames(registeredFrames:registeredFrames,containerDuration:containerDuration,decodedDuration:diagnostics.duration)
            var bound=scene;bound.speechPlan=request.plan
            production=SpeechProduction(asset:asset,evidence:evidence,diagnostics:diagnostics,plan:request.plan,captions:try SpeechRules.captions(request.plan,durationFrames:frames),take:VoiceTake(assetID:id,textDigest:try SpeechRules.digest(bound),durationFrames:frames,method:"imported-recording",listened:false))
        } else {
            _=try SpeechService.validateVoice(plan:request.plan)
            try checkDeadline()
            production=try await speech.synthesize(plan:request.plan,scene:scene,repository:repository,workspaceID:request.workspaceID,timeoutSeconds:request.timeoutSeconds)
        }
        try checkDeadline()
        let bytes=try Data(contentsOf:repository.assetURL(production.asset))
        guard bytes.count==production.asset.bytes,Codec.hash(bytes)==production.asset.hash else {throw VideoError.conflict("新配音源文件与真实CAS摘要不一致，未绑定到工程")}
        return try repository.transaction { database in
            try checkDeadline()
            _=try SpeechProjectRules.authorize(request,database:database,principal:principal)
            if case .replay(let response)=try AgentContract.replay(command:request.command,data:data,records:database.agentReplayRecords ?? []) {return response}
            let before=database.projects
            let project=try SpeechProjectRules.apply(request,asset:production.asset,evidence:production.evidence,take:production.take,captions:production.captions,database:&database,principal:principal)
            try authorizeChanges?(before,database.projects,database.assets)
            try checkDeadline()
            let result:AgentValue = .object(["asset_id":.string(production.asset.id),"scene_id":.string(request.sceneID),"source_sha256":.string(production.asset.hash),"source_bytes":.number(Decimal(production.asset.bytes)),"duration_frames":.number(Decimal(production.take.durationFrames)),"scene_duration_frames":.number(Decimal(project.current.scenes.first(where:{$0.id==request.sceneID})!.durationFrames)),"voice_identifier":request.plan.voiceIdentifier.map(AgentValue.string) ?? .null,"listened":.boolean(false),"captions_confirmed":.boolean(false),"rights_verified":.boolean(production.evidence.verified),"commercial_allowed":.boolean(production.evidence.commercialAllowed),"external_request_cost":.number(0),"notes":.string("完整真实配音已绑定新版本；字幕为估计句段；延长镜头后须复核各分层覆盖区间。声音权利、字幕和完整看听仍待人工核对。无外部API请求不代表系统声音商用授权。")])
            let response=AgentMutationExecutor.envelope(requestID:request.requestID,state:"needs_review",projectID:project.id,revisionID:project.current.id,result:result)
            database.agentReplayRecords=(database.agentReplayRecords ?? [])+[AgentReplayRecord(requestID:request.requestID,command:request.command,fingerprint:try AgentContract.fingerprint(command:request.command,data:data),response:response)]
            return response
        }
    }
}
