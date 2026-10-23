import Foundation

public enum ClassicSceneEditing {
    /// Binds an existing, actually derived image region to a named expression.
    /// Source records and current rights are rechecked; this does not create artwork or grant rights.
    public static func settingExpressionSprite(_ sprite:ClassicSprite,to original:Scene,assets:[Asset],evidence:[Evidence],workspaceID:String,commercial:Bool,now:Date=Date())throws->Scene {
        let reserved:Set<String>=["hero","crate","wall","floor","backdrop","coin"]
        guard !original.locked,[SceneKind.simulation,.cartoon].contains(original.kind),
              var artwork=original.classicArtwork,artwork.derivation == .qStyle,
              var profile=original.characterProfile,!profile.original else{throw VideoError.permission("请先选择未锁定且绑定真实Q版来源的角色镜头")}
        let role=sprite.role.trimmingCharacters(in:.whitespacesAndNewlines)
        guard role==sprite.role,!role.isEmpty,role.count<=40,!role.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),!reserved.contains(role),
              artwork.sprites.contains(where:{$0.assetID==sprite.assetID}),
              let image=assets.first(where:{$0.id==sprite.assetID && $0.workspaceID==workspaceID && $0.mediaType.hasPrefix("image")}),
              !assets.contains(where:{artwork.originalAssetIDs.contains($0.id) && $0.hash==image.hash}) else{throw VideoError.review("表情须使用已有实际Q版派生图块和明确名称，不能覆盖基础图块或把下载原件改标签当作派生")}
        let source=try self.source(assetID:image.id,assets:assets,evidence:evidence,workspaceID:workspaceID)
        if let previous=artwork.sources.first(where:{$0.assetID==image.id}) {
            guard previous.hash==source.hash,previous.evidenceID==source.evidenceID,previous.source==source.source,previous.owner==source.owner else{throw VideoError.conflict("此图集的来源关联已变化，请核对后重新绑定")}
        }else{artwork.sources.append(source)}
        artwork.sprites.removeAll{$0.role==role};artwork.sprites.append(sprite)
        if !profile.expressions.contains(role){profile.expressions.append(role)}
        guard !profile.expressions.isEmpty,profile.expressions.count<=20 else{throw VideoError.invalid("角色表情须保留1至20项")}
        profile.evidenceIDs=Array(Set(profile.evidenceIDs+[source.evidenceID])).sorted()
        var scene=try binding(artwork,character:original.character,to:original,assets:assets,evidence:evidence,workspaceID:workspaceID,requireQStyle:true)
        scene.characterProfile=profile;scene.emotion=role
        try ClassicArtworkRules.validateRights(scene:scene,workspaceID:workspaceID,assets:assets,evidence:evidence,commercial:commercial,now:now)
        return scene
    }
    /// Existing project/revision/scene identities are the versioned character store.
    /// Read authorization is checked before looking up the source; no source approvals or audio are copied.
    public static func reusingVisualCharacter(projectID:String,revisionID:String,sceneID:String,to original:Scene,access:WorkspaceAccessContext,database:Database,commercial:Bool,now:Date=Date())throws->Scene {
        let (project,revision)=try WorkspaceAccessRules.revision(projectID:projectID,revisionID:revisionID,access:access,in:database,now:now)
        guard let source=revision.scenes.first(where:{$0.id==sceneID}),[SceneKind.simulation,.cartoon].contains(source.kind),
              var artwork=source.classicArtwork,artwork.derivation == .qStyle,
              var profile=source.characterProfile,!profile.original,
              !profile.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !profile.actions.isEmpty,!profile.expressions.isEmpty,profile.actions.count<=20,profile.expressions.count<=20,
              (profile.actions+profile.expressions).allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else{throw VideoError.review("所选历史镜头没有完整的实际Q版角色图块、动作和表情")}
        // Carry only visual source records. Target audio retains its own exact source and listening state.
        let visualIDs=Set(artwork.sprites.map(\.assetID)+artwork.originalAssetIDs)
        artwork.sources=artwork.sources.filter{visualIDs.contains($0.assetID)}
        artwork.audioCues=original.classicArtwork?.audioCues ?? []
        for cue in artwork.audioCues {
            guard let record=original.classicArtwork?.sources.first(where:{$0.assetID==cue.assetID}) else{throw VideoError.permission("目标声音的具体来源缺失，未替换角色")}
            if let other=artwork.sources.first(where:{$0.assetID==record.assetID}){guard other==record else{throw VideoError.conflict("复用角色与目标声音的来源记录冲突")}}
            else{artwork.sources.append(record)}
        }
        artwork.transformation += "\n角色快照复用自项目 "+project.id+" / revision "+revision.id+" / scene "+source.id+"；仅复制图块、表情与动作，不转移原镜头录音或审核。"
        profile.voiceAssetID=original.characterProfile?.voiceAssetID;profile.evidenceIDs=artwork.evidenceIDs.sorted()
        if let voiceID=profile.voiceAssetID {
            guard let voice=database.assets.first(where:{$0.id==voiceID && $0.workspaceID==access.workspaceID && $0.mediaType=="audio"}),
                  let proof=database.evidence.first(where:{$0.id==voice.evidenceID && $0.workspaceID==access.workspaceID}),proof.usable(commercial:commercial,now:now) else{throw VideoError.permission("目标原有角色声音缺少当前用途的有效来源授权")}
            profile.evidenceIDs=Array(Set(profile.evidenceIDs+[proof.id])).sorted()
        }
        var scene=try binding(artwork,character:source.character,to:original,assets:database.assets,evidence:database.evidence,workspaceID:access.workspaceID,requireQStyle:true)
        scene.characterProfile=profile;scene.emotion=source.emotion
        try ClassicArtworkRules.validateRights(scene:scene,workspaceID:access.workspaceID,assets:database.assets,evidence:database.evidence,commercial:commercial,now:now)
        return scene
    }
    public static func binding(_ artwork:ClassicArtwork,character:String,to original:Scene,assets:[Asset],evidence:[Evidence],workspaceID:String,requireQStyle:Bool=false)throws->Scene {
        guard !original.locked,[SceneKind.simulation,.cartoon].contains(original.kind),!character.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw VideoError.permission("请先解锁实际规则/角色镜头并选择已知角色")}
        guard !requireQStyle || artwork.derivation == .qStyle else{throw VideoError.review("下载原件尚未完成实际Q版派生，不能用于新高级成片；请保留原件并绑定真实处理产物")}
        var scene=original;scene.classicArtwork=artwork;scene.classicArtworkRequired=true;scene.character=character
        scene.characterProfile=CharacterProfile(name:character,expressions:scene.characterProfile?.expressions ?? ["好奇","思考","开心"],actions:scene.characterProfile?.actions ?? ["讲解","指向","点头"],evidenceIDs:artwork.evidenceIDs.sorted(),original:false)
        try ClassicArtworkRules.validate(scene:scene,assets:assets.filter{$0.workspaceID==workspaceID})
        for source in artwork.sources {
            guard evidence.contains(where:{$0.id==source.evidenceID && $0.workspaceID==workspaceID && $0.source==source.source && $0.owner==source.owner})else{throw VideoError.permission("绑定图集的来源证据缺失或越出工作区")}
        }
        return scene
    }
    public static func source(assetID:String,assets:[Asset],evidence:[Evidence],workspaceID:String)throws->ClassicSource {
        guard let asset=assets.first(where:{$0.id==assetID && $0.workspaceID==workspaceID}),
              let e=evidence.first(where:{$0.id==asset.evidenceID && $0.workspaceID==workspaceID}),
              !e.source.isEmpty,!e.owner.isEmpty else{throw VideoError.review("请先为此具体原件保存来源、权利人和适用授权；不会由公开下载推断商用许可")}
        return ClassicSource(assetID:asset.id,hash:asset.hash,source:e.source,owner:e.owner,license:"以关联来源原件与权利凭据为准；使用范围、期限和商用需逐项核对",evidenceID:e.id)
    }
    /// The caller must supply an actual edited atlas and different original bytes.
    /// This binds existing files; it does not relabel an unedited image as a generated output.
    public static func derivedAtlas(assetID:String,originalAssetIDs:[String],gameplay:ClassicGameplay,transformation:String,assets:[Asset],evidence:[Evidence],workspaceID:String)throws->ClassicArtwork {
        guard !originalAssetIDs.isEmpty,Set(originalAssetIDs).count==originalAssetIDs.count,
              let image=assets.first(where:{$0.id==assetID && $0.workspaceID==workspaceID && $0.mediaType.hasPrefix("image")}),
              originalAssetIDs.allSatisfy({id in assets.contains{$0.id==id && $0.workspaceID==workspaceID && $0.mediaType.hasPrefix("image") && $0.hash != image.hash}}),
              !transformation.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw VideoError.review("须选择实际编辑后的Q版图集、不同原件和明确处理过程；不能仅给原件改标签")}
        let sources=try ([assetID]+originalAssetIDs).map{try source(assetID:$0,assets:assets,evidence:evidence,workspaceID:workspaceID)}
        return .quadrants(assetID:assetID,gameplay:gameplay,sources:sources,derivation:.qStyle,transformation:transformation,originalAssetIDs:originalAssetIDs)
    }
    public static func addingCue(assetID:String,startFrame:Int,gain:Double,use:ClassicAudioCue.Use,extendScene:Bool,to original:Scene,assets:[Asset],evidence:[Evidence],workspaceID:String)throws->Scene {
        guard !original.locked,original.classicArtwork != nil,
              let asset=assets.first(where:{$0.id==assetID && $0.workspaceID==workspaceID && $0.mediaType=="audio"}),
              let frames=asset.durationFrames,frames>0,startFrame>=0,startFrame<=54000-frames else{throw VideoError.invalid("请选择真实录音、非负起点和有效时长")}
        let record=try source(assetID:assetID,assets:assets,evidence:evidence,workspaceID:workspaceID)
        let end=startFrame+frames
        guard end<=original.durationFrames || extendScene else{throw VideoError.review("下载录音超出镜头，请明确延长后再绑定；不会截断原音句尾")}
        var scene=original
        if end>scene.durationFrames {scene=try StoryboardTiming.extending(scene:scene,to:end);scene.simulationRecordingConfirmed=false}
        guard var artwork=scene.classicArtwork else {throw VideoError.invalid("延长后的镜头缺少原素材绑定")}
        artwork.sources.removeAll{$0.assetID==assetID};artwork.sources.append(record)
        artwork.audioCues.append(ClassicAudioCue(assetID:assetID,startFrame:startFrame,durationFrames:frames,gain:gain,use:use,listened:false))
        scene.classicArtwork=artwork
        try ClassicArtworkRules.validate(scene:scene,assets:assets.filter{$0.workspaceID==workspaceID})
        return scene
    }
}

/// A transient observation of the current recording, never an approval or an
/// instruction to synthesize a sound. Existing source/listening checks still apply.
public struct KnowledgeSoundMoment: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case constrained = "行动受限", action = "实际行动", outcome = "实际后果" }
    public let id: String
    public let kind: Kind
    public let round: Int
    public let sourceTick: Int
    public let sceneFrame: Int
    public let summary: String
    public let recordingDigest: String
}

public extension ClassicSceneEditing {
    /// Observe actual decisions, debits and settled effects; do not predict from
    /// rule declarations, balance sign, sprite pose or the knowledge's name.
    static func knowledgeSoundMoments(scene: Scene, fps: Int = 30) throws -> [KnowledgeSoundMoment] {
        guard scene.kind == .simulation, let model=scene.simulation.knowledge, scene.speed == 1 else {
            throw VideoError.review("轨迹音效定位需要1倍速的知识仿真镜头；其他镜头可手动加入原音")
        }
        guard scene.pauseFrames == 0 || scene.simulationPresentation != nil else {
            throw VideoError.review("旧式停顿可能继续推进仿真，请先设置明确源窗口并重新录制，再定位声音事件")
        }
        try SimulationReplay.verify(scene:scene,fps:fps,requireConfirmation:false)
        guard let recording=scene.simulationRecording, let trace=recording.knowledgeTrace else {
            throw VideoError.review("请先按当前模型和时轴实际录制知识轨迹")
        }
        let digest=try Codec.digest(recording)
        let first=try scene.renderSimulationSourceFrame(atTimelineFrame:0)
        let last=try scene.renderSimulationSourceFrame(atTimelineFrame:scene.durationFrames-1)
        let names=Dictionary(uniqueKeysWithValues:model.participants.map{($0.id,$0.name)})
        var moments:[KnowledgeSoundMoment]=[]
        for event in trace.events {
            let target=event.tick*fps
            // A cut that begins inside a phase does not replay its earlier onset.
            guard target >= first, target <= last else { continue }
            let kind:KnowledgeSoundMoment.Kind, summary:String
            switch event.phase {
            case .decision:
                let constrained=event.actors.filter{$0.choice == .constrained}
                guard !constrained.isEmpty else { continue }
                kind = .constrained
                summary=constrained.map{names[$0.id] ?? $0.id}.joined(separator:"、")+"：资源不足，未执行"
            case .contribution:
                let active=event.actors.filter{actor in
                    if model.isRuleTable { return actor.executedActionID != nil }
                    return actor.cost>0 || actor.contribution>0
                }
                guard !active.isEmpty else { continue }
                kind = .action
                summary=active.map{actor in
                    let action=actor.executedActionID.flatMap{id in model.ruleTable?.actions.first{$0.id==id}?.label}
                    return (names[actor.id] ?? actor.id)+"："+(action ?? "实际行动")+"，扣费\(actor.cost)"
                }.joined(separator:"；")
            case .settlement:
                if model.isRuleTable {
                    guard let result=event.ruleExecution,
                          result.transfers.contains(where:{$0.amount>0}) || result.stateChanges.contains(where:{$0.beforeStateID != $0.afterStateID}) else { continue }
                    summary="实际转移\(result.transfers.filter{$0.amount>0}.count)项；状态改变\(result.stateChanges.filter{$0.beforeStateID != $0.afterStateID}.count)项"
                } else {
                    guard event.actors.contains(where:{$0.benefit>0 || $0.passed}) else { continue }
                    summary=event.actors.map{(names[$0.id] ?? $0.id)+"：实际收益\($0.benefit)"}.joined(separator:"；")
                }
                kind = .outcome
            default: continue
            }
            var lower=0,upper=scene.durationFrames-1
            while lower<upper {
                let middle=lower+(upper-lower)/2
                if try scene.renderSimulationSourceFrame(atTimelineFrame:middle)<target {lower=middle+1}else{upper=middle}
            }
            guard try scene.renderSimulationSourceFrame(atTimelineFrame:lower)/fps == event.tick else {
                throw VideoError.review("展示窗口跳过了真实声音事件，请延长展示并重新录制，不会把声音移到另一个阶段")
            }
            moments.append(KnowledgeSoundMoment(id:"\(event.round):\(event.tick):\(kind.rawValue)",kind:kind,round:event.round,sourceTick:event.tick,sceneFrame:lower,summary:summary,recordingDigest:digest))
        }
        return moments
    }

    /// Re-read the current recording before applying a UI selection. Extending a
    /// shot changes the source mapping, so alignment never silently retimes it.
    static func addingKnowledgeCue(_ moment:KnowledgeSoundMoment,assetID:String,gain:Double,to scene:Scene,
                                   assets:[Asset],evidence:[Evidence],workspaceID:String,fps:Int=30)throws->Scene {
        guard try knowledgeSoundMoments(scene:scene,fps:fps).contains(moment) else {
            throw VideoError.conflict("所选声音事件已变化，请按当前模型重新录制并选择")
        }
        guard let frames=assets.first(where:{$0.id==assetID && $0.workspaceID==workspaceID && $0.mediaType=="audio"})?.durationFrames,
              frames>0,frames<=scene.durationFrames-moment.sceneFrame else {
            throw VideoError.review("完整原音超出此事件后的镜头时长；请先延长展示、重新录制再定位，不会截断或移动事件")
        }
        return try addingCue(assetID:assetID,startFrame:moment.sceneFrame,gain:gain,use:.effect,extendScene:false,to:scene,assets:assets,evidence:evidence,workspaceID:workspaceID)
    }
}
