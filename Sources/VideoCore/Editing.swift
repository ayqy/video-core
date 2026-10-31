import Foundation

public enum Edit: Codable, Sendable {
    case insertScene(Scene, Int)
    case replaceScene(String, Scene)
    case removeScene(String)
    case moveScene(String, Int)
    case splitScene(String, Int)
    case lockScene(String, Bool)
    case aspect(Aspect)
    case cta(String)
    case music(String?)
    case audioQuality(AudioQualityPolicy?)
    case productionBrief(ProductionBrief?)
    case purpose(Purpose)
    case restore(String)
    case lockLayer(String, String, Bool)
    case recordSimulation(String)
    case confirmSimulationRecording(String)
}
public enum Editor {
    public static func apply(_ operations: [Edit], to project: Project, baseRevision: String, assets: [Asset], message: String) throws -> Project {
        guard project.current.id == baseRevision else { throw VideoError.conflict("基准版本已过时：当前为v\(project.current.number)，请比较后重试") }
        guard !operations.isEmpty else { throw VideoError.invalid("没有编辑操作") }
        var p = project; var revision = project.current; let previous = revision
        revision.id = Codec.id(); revision.parentID = previous.id; revision.number += 1; revision.createdAt = Date(); revision.change = message; revision.review = Review(); revision.invalidated = ["最终导出", "完整预览", "声音确认"]
        for operation in operations {
            switch operation {
            case .insertScene(let scene, let target):
                guard (0...revision.scenes.count).contains(target) else { throw VideoError.invalid("插入位置无效") }
                if let take=scene.voice {try SpeechProjectRules.validateCompleteTake(take,workspaceID:project.workspaceID,assets:assets)}
                try scene.validate(assets: assets); revision.scenes.insert(scene, at: target)
            case .replaceScene(let id, var scene):
                guard let i = revision.scenes.firstIndex(where: { $0.id == id }) else { throw VideoError.notFound("片段不存在") }; let old = revision.scenes[i]; guard !old.locked else { throw VideoError.permission("镜头已锁定，请先解锁再编辑") }; scene.id = id
                try LayerRules.protectLocked(old:old,new:scene)
                if old.storyActions != scene.storyActions || old.storyCausality != scene.storyCausality || old.gameWorld != scene.gameWorld || old.cartoonRig != scene.cartoonRig || old.cartoonPresenter != scene.cartoonPresenter ||
                    ((old.storyActions != nil || old.storyCausality != nil || old.gameWorld != nil || old.cartoonRig != nil || old.cartoonPresenter != nil) && (old.durationFrames != scene.durationFrames || old.kind != scene.kind)) ||
                    ((old.storyCausality != nil || scene.storyCausality != nil) && (old.speed != scene.speed || old.pauseFrames != scene.pauseFrames)) {
                    scene.voice?.listened=false
                    for j in scene.captions.indices {scene.captions[j].confirmed=false}
                    revision.invalidated += ["故事过程、地图状态、原音能量口型与声音字幕重新复核"]
                }
                let oldEntrances=(old.layers ?? []).filter{$0.entrance != nil}
                let newEntrances=(scene.layers ?? []).filter{$0.entrance != nil}
                let paperOrEntranceTiming=(old.paperPresentation != nil || scene.paperPresentation != nil || !oldEntrances.isEmpty || !newEntrances.isEmpty) && (old.durationFrames != scene.durationFrames || old.speed != scene.speed || old.pauseFrames != scene.pauseFrames)
                if old.paperPresentation != scene.paperPresentation || oldEntrances != newEntrances || paperOrEntranceTiming {
                    scene.voice?.listened=false
                    for index in scene.captions.indices {scene.captions[index].confirmed=false}
                    revision.invalidated += ["纸面呈现、图形入场与声音字幕重新复核"]
                }
                if old.mediaFraming != scene.mediaFraming {
                    scene.voice?.listened=false
                    for index in scene.captions.indices {scene.captions[index].confirmed=false}
                    revision.invalidated += ["录屏/图片取景与声音字幕重新复核"]
                }
                let oldSequences=(old.layers ?? []).filter{$0.imageSequence != nil || $0.sourceRect != nil || $0.imageFlipHorizontal != nil}
                let newSequences=(scene.layers ?? []).filter{$0.imageSequence != nil || $0.sourceRect != nil || $0.imageFlipHorizontal != nil}
                if oldSequences != newSequences || ((!oldSequences.isEmpty || !newSequences.isEmpty) && (old.durationFrames != scene.durationFrames || old.speed != scene.speed || old.pauseFrames != scene.pauseFrames)) {
                    scene.voice?.listened=false
                    for index in scene.captions.indices {scene.captions[index].confirmed=false}
                    revision.invalidated += ["图片取景、序列、源窗口与声音字幕重新复核"]
                }
                let oldData=(old.layers ?? []).filter{$0.dataPresentation != nil}
                let newData=(scene.layers ?? []).filter{$0.dataPresentation != nil}
                if oldData != newData || (!newData.isEmpty && (old.durationFrames != scene.durationFrames || old.speed != scene.speed || old.pauseFrames != scene.pauseFrames)) {
                    scene.voice?.listened=false
                    for index in scene.captions.indices { scene.captions[index].confirmed=false }
                    revision.invalidated += ["数据、代码步骤、时间轴与声音字幕重新复核"]
                }
                if (old.kind == .simulation || scene.kind == .simulation) && (old.simulation != scene.simulation || old.simulationPresentation != scene.simulationPresentation || old.durationFrames != scene.durationFrames || old.kind != scene.kind || old.speed != scene.speed || old.pauseFrames != scene.pauseFrames) {
                    if scene.simulationRecording == old.simulationRecording || (try? SimulationReplay.verify(scene:scene,fps:revision.fps,requireConfirmation:false)) == nil {
                        scene.simulationRecordingConfirmed = false
                    }
                    revision.invalidated += ["规则录制与复核"]
                    if old.simulation.knowledge != nil || scene.simulation.knowledge != nil {
                        if scene.voice?.assetID == old.voice?.assetID { scene.voice = nil }
                        for index in scene.captions.indices { scene.captions[index].confirmed = false }
                        if var artwork = scene.classicArtwork {
                            for index in artwork.audioCues.indices { artwork.audioCues[index].listened = false }
                            scene.classicArtwork = artwork
                        }
                        revision.invalidated += ["知识因果、结论、声音与字幕重新复核"]
                    }
                }
                if old.cartoonPerformance != scene.cartoonPerformance ||
                    ((old.cartoonPerformance != nil || scene.cartoonPerformance != nil) && (old.durationFrames != scene.durationFrames || old.speed != scene.speed || old.kind != scene.kind)) {
                    if scene.voice?.assetID == old.voice?.assetID { scene.voice?.listened = false }
                    for index in scene.captions.indices { scene.captions[index].confirmed=false }
                    if var artwork=scene.classicArtwork {
                        for index in artwork.audioCues.indices { artwork.audioCues[index].listened=false }
                        scene.classicArtwork=artwork
                    }
                    revision.invalidated += ["多角色表演、发言时点、镜头与声音字幕重新复核"]
                }
                if old.narration != scene.narration, scene.speechPlan?.source != scene.narration { scene.speechPlan=nil }
                let oldSpeechDigest=try? old.speechDigest(), newSpeechDigest=try? scene.speechDigest()
                if old.narration != scene.narration || oldSpeechDigest == nil || newSpeechDigest == nil || oldSpeechDigest != newSpeechDigest {
                    if scene.voice?.assetID == old.voice?.assetID || scene.voice?.textDigest != (try? scene.speechDigest()) { scene.voice = nil }
                    for j in scene.captions.indices { scene.captions[j].confirmed = false }; revision.invalidated += ["该镜头配音", "字幕对齐", "口型与节奏"]
                }
                // The speech digest describes the source recording inputs. It does
                // not describe the speed/pitch transformation used by the renderer,
                // or identify a replacement recording of the same words. Approval
                // flags alone remain independent editorial changes; adding music
                // does not revoke an unchanged source voice's listening approval.
                var oldVoiceIdentity = old.voice, newVoiceIdentity = scene.voice
                oldVoiceIdentity?.listened = false
                newVoiceIdentity?.listened = false
                if oldVoiceIdentity != newVoiceIdentity,let take=scene.voice {
                    try SpeechProjectRules.validateCompleteTake(take,workspaceID:project.workspaceID,assets:assets)
                }
                if old.speed != scene.speed || old.preservePitch != scene.preservePitch || oldVoiceIdentity != newVoiceIdentity {
                    scene.voice?.listened = false
                    for j in scene.captions.indices { scene.captions[j].confirmed = false }
                    revision.invalidated += ["实际配音、成片变速或变调与声音字幕重新复核"]
                }
                let sourceWindowChanged=old.kind != scene.kind || old.assetID != scene.assetID || old.sourceStartFrame != scene.sourceStartFrame || old.durationFrames != scene.durationFrames
                let hadSourceAudio=old.kind == .video && old.assetID != nil && !old.muted && old.sourceGain>0
                let hasSourceAudio=scene.kind == .video && scene.assetID != nil && !scene.muted && scene.sourceGain>0
                if sourceWindowChanged && (hadSourceAudio || hasSourceAudio) {
                    for j in scene.captions.indices {scene.captions[j].confirmed=false}
                    revision.invalidated += ["原片音轨或源窗口已变化，字幕须重新核对"]
                }
                if try SpeechRules.captionContentDigest(old.captions) != SpeechRules.captionContentDigest(scene.captions) {
                    scene.voice?.listened = false
                    for j in scene.captions.indices { scene.captions[j].confirmed = false }
                    revision.invalidated += ["字幕内容、时轴与声音重新复核"]
                }
                try scene.validate(assets: assets); revision.scenes[i] = scene
            case .removeScene(let id): guard let s = revision.scenes.first(where: { $0.id == id }), !s.locked, (revision.scenes.count > 1 || revision.contentContext != nil) else { throw VideoError.permission("不能删除锁定镜头；旧产品工程须保留至少一个镜头") }; revision.scenes.removeAll { $0.id == id }
            case .moveScene(let id, let target): guard let i = revision.scenes.firstIndex(where: { $0.id == id }), (0..<revision.scenes.count).contains(target), !revision.scenes[i].locked else { throw VideoError.invalid("重排目标无效或片段已锁定") }; let s = revision.scenes.remove(at: i); revision.scenes.insert(s, at: target)
            case .splitScene(let id, let frame):
                guard let i = revision.scenes.firstIndex(where: { $0.id == id }), !revision.scenes[i].locked else { throw VideoError.permission("片段不存在或已锁定") }; let original = revision.scenes[i]
                guard frame > 0, frame < original.durationFrames else { throw VideoError.invalid("拆分点必须位于片段内部") }
                guard original.voice == nil else { throw VideoError.review("有配音的片段请先解除配音并重新录制两段，避免截断句子") }
                guard original.storyActions==nil,original.storyCausality==nil,original.gameWorld==nil,original.cartoonRig==nil,original.cartoonPresenter==nil else {throw VideoError.review("动态世界、因果来源、过程动作与原音口型须按新镜头重新编排后拆分；不会复制旧源帧或旧声音cue")}
                guard !(original.layers ?? []).contains(where:{$0.locked}) else { throw VideoError.permission("请先解锁元素，再拆分场景") }
                let hasEntrances=(original.layers ?? []).contains{$0.entrance != nil || $0.imageSequence != nil}
                if original.speed != 1 || hasEntrances {
                    try original.validate(assets:assets)
                    let leftFrames=max(1,Int((Double(frame)/original.speed).rounded()))
                    let rightFrames=max(1,Int((Double(original.durationFrames-frame)/original.speed).rounded()))
                    let sourceFrames=original.timelineFrames-original.pauseFrames
                    // A source split can fall between actual output samples at
                    // non-integral speeds. Reject unrepresentable phase shifts
                    // instead of adding output frames or resampling the right side.
                    let leftMatches=(0..<leftFrames).allSatisfy { local in
                        min(frame-1,original.renderSourceFrame(atTimelineFrame:local)) == min(original.durationFrames-1,original.renderSourceFrame(atTimelineFrame:local))
                    }
                    let rightMatches=(0..<rightFrames).allSatisfy { local in
                        min(original.durationFrames-1,frame+original.renderSourceFrame(atTimelineFrame:local)) == min(original.durationFrames-1,original.renderSourceFrame(atTimelineFrame:leftFrames+local))
                    }
                    guard leftFrames+rightFrames == sourceFrames,leftMatches,rightMatches else {
                        throw VideoError.review("此变速拆分不能保留连续的逐帧源映射，请先恢复1×速度后拆分，再分别调整速度")
                    }
                }
                try ClassicArtworkRules.validate(scene:original,assets:assets)
                let audioCues=original.classicArtwork?.audioCues ?? []
                guard !audioCues.contains(where:{$0.startFrame<frame && $0.durationFrames>frame-$0.startFrame}) else { throw VideoError.review("拆分点穿过游戏音效或原录音提示，请调整拆分点或先移除该声音；不会自动截断原音") }
                var a = original, b = original; a.durationFrames = frame; b.id = Codec.id(); b.durationFrames = original.durationFrames - frame; b.sourceStartFrame += frame; a.sourceEndFrame = original.sourceStartFrame + frame
                // A trailing hold belongs to the end of the original scene, not
                // to every piece created by splitting its source interval.
                a.pauseFrames=0
                if original.paperPresentation != nil || hasEntrances {
                    revision.invalidated += ["拆分后的纸面呈现、图形入场与声音字幕重新复核"]
                }
                a.classicArtwork?.audioCues=audioCues.filter{$0.startFrame<frame}.map { cue in var copy=cue;copy.listened=false;return copy }
                b.classicArtwork?.audioCues=audioCues.filter{$0.startFrame>=frame}.map { cue in var copy=cue;copy.startFrame-=frame;copy.listened=false;return copy }
                if let acting=original.cartoonPerformance {
                    a.cartoonPerformance=try acting.trimmed(from:0,to:frame,durationFrames:original.durationFrames)
                    b.cartoonPerformance=try acting.trimmed(from:frame,to:original.durationFrames,durationFrames:original.durationFrames)
                    revision.invalidated += ["拆分后的多角色表演与声音字幕复核"]
                }
                if original.kind == .simulation {
                    if original.speed != 1 || (original.simulationPresentation == nil && original.pauseFrames != 0) {
                        throw VideoError.review("仿真拆分须先恢复1×播放；旧停顿镜头还须明确源展示窗口。请用源窗口展示时长调整节奏，以保留全部因果与可见帧")
                    }
                    let presentation=original.simulationPresentation ?? SimulationPresentation(sourceStartFrame:0,sourceEndFrame:original.durationFrames,presentationFrames:original.durationFrames)
                    a.simulationPresentation=try presentation.sliced(from:0,to:frame,durationFrames:original.durationFrames)
                    b.simulationPresentation=try presentation.sliced(from:frame,to:original.durationFrames,durationFrames:original.durationFrames)
                    a.pauseFrames=0
                    a.simulationRecordingConfirmed=false; b.simulationRecordingConfirmed=false
                    revision.invalidated += ["拆分后的仿真源窗口、规则录制与复核"]
                }
                a.layers=try (original.layers ?? []).filter{$0.startFrame<frame}.map { layer in var x=layer;x.endFrame=min(x.endFrame,frame);if let sequence=layer.imageSequence{x.imageSequence=try sequence.advancingSource(by:0)};x.keyframes=x.keyframes.filter{$0.frame<x.endFrame};if !layer.keyframes.isEmpty{let point=layer.layout(at:x.endFrame-1);x.keyframes.removeAll{$0.frame==x.endFrame-1};x.keyframes.append(Keyframe(frame:x.endFrame-1,x:point.x,y:point.y,scale:point.scale))};return x }
                b.layers=try (original.layers ?? []).filter{$0.endFrame>frame}.map { layer in var x=layer;x.id=Codec.id();x.startFrame=max(0,x.startFrame-frame);x.endFrame-=frame;x.keyframes=x.keyframes.filter{$0.frame>=frame}.map{key in var k=key;k.id=Codec.id();k.frame-=frame;return k};let point=layer.layout(at:frame+x.startFrame);x.x=point.x;x.y=point.y;if !layer.keyframes.isEmpty && !x.keyframes.contains(where:{$0.frame==x.startFrame}){x.keyframes.append(Keyframe(frame:x.startFrame,x:point.x,y:point.y,scale:point.scale))};if let data=layer.dataPresentation{x.dataPresentation=try data.advancingSource(by:frame)};if let entrance=layer.entrance{x.entrance=try entrance.advancingSource(by:frame)};if let sequence=layer.imageSequence{x.imageSequence=try sequence.advancingSource(by:frame)};return x }
                a.captions = original.captions.filter { $0.startFrame < frame }.map { c in var x = c; x.endFrame = min(frame, c.endFrame); x.confirmed = false; return x }
                b.captions = original.captions.filter { $0.endFrame > frame }.map { c in var x = c; x.id = Codec.id(); x.startFrame = max(0,c.startFrame-frame); x.endFrame -= frame; x.confirmed = false; return x }
                a.keyframes=original.keyframes.filter{$0.frame<frame}
                b.keyframes=original.keyframes.filter{$0.frame>=frame}.map{k in var x=k;x.id=Codec.id();x.frame-=frame;return x}
                let boundary=original.layout(at:frame);b.x=boundary.x;b.y=boundary.y;b.scale=boundary.scale
                if !original.keyframes.isEmpty{let end=original.layout(at:frame-1);a.keyframes.removeAll{$0.frame==frame-1};a.keyframes.append(Keyframe(frame:frame-1,x:end.x,y:end.y,scale:end.scale))}
                if !original.keyframes.isEmpty && !b.keyframes.contains(where:{$0.frame==0}){b.keyframes.append(Keyframe(frame:0,x:boundary.x,y:boundary.y,scale:boundary.scale))}
                revision.scenes.replaceSubrange(i...i, with: [a,b])
            case .lockScene(let id, let locked): guard let i = revision.scenes.firstIndex(where: { $0.id == id }) else { throw VideoError.notFound("片段不存在") }; revision.scenes[i].locked = locked
            case .lockLayer(let id,let layerID,let locked): guard let i=revision.scenes.firstIndex(where:{$0.id==id}),!revision.scenes[i].locked,let j=revision.scenes[i].layers?.firstIndex(where:{$0.id==layerID}) else { throw VideoError.permission("镜头已锁定或元素不存在") };revision.scenes[i].layers?[j].locked=locked
            case .recordSimulation(let id):
                guard let i=revision.scenes.firstIndex(where:{$0.id==id}),!revision.scenes[i].locked else {throw VideoError.permission("规则镜头不存在或已锁定")}
                revision.scenes[i].simulationRecording = try SimulationReplay.record(scene:revision.scenes[i],fps:revision.fps)
                revision.scenes[i].simulationRecordingConfirmed = false
                revision.invalidated += ["新规则录制待复核"]
            case .confirmSimulationRecording(let id):
                guard let i=revision.scenes.firstIndex(where:{$0.id==id}),!revision.scenes[i].locked else {throw VideoError.permission("规则镜头不存在或已锁定")}
                try SimulationReplay.verify(scene:revision.scenes[i],fps:revision.fps,requireConfirmation:false)
                revision.scenes[i].simulationRecordingConfirmed = true
            case .aspect(let aspect): revision.aspect = aspect
            case .cta(let text): revision.cta = text
            case .music(let id): revision.musicAssetID = id; revision.invalidated += ["混音"]
            case .audioQuality(let policy): try policy?.validate();revision.audioQuality=policy;revision.invalidated += ["混音测量策略","声音审核"]
            case .productionBrief(let brief): try brief?.validate();revision.productionBrief=brief;revision.invalidated += ["制作Brief与指定版本审稿","用途/权利交付核对"]
            case .purpose(let purpose): revision.purpose=purpose;revision.invalidated += ["交付用途与权利审核"]
            case .restore(let id): guard let r = p.revisions.first(where: { $0.id == id }) else { throw VideoError.notFound("历史版本不存在") }; revision.schemaVersion=r.schemaVersion; revision.scenes = r.scenes; revision.product = r.product; revision.contentContext=r.contentContext; revision.cta = r.cta; revision.aspect = r.aspect; revision.musicAssetID = r.musicAssetID; revision.dependencies=r.dependencies;revision.audioQuality=r.audioQuality;revision.productionBrief=r.productionBrief;revision.purpose=r.purpose
            }
        }
        for s in revision.scenes {
            try s.validate(assets: assets)
            try ClassicArtworkRules.validateWalkingSources(scene:s,assets:assets.filter{$0.workspaceID==project.workspaceID})
            try ClassicArtworkRules.validateGateSources(scene:s,assets:assets.filter{$0.workspaceID==project.workspaceID})
        }
        p.revisions.append(revision); return p
    }
    public static func updateFacts(_ product: Product, project: Project) -> Project {
        guard project.current.product?.id==product.id,project.workspaceID==product.workspaceID else{return project}
        var p = project; let old = p.current; var r = old; r.id = Codec.id(); r.parentID = old.id; r.number += 1; r.product = product; r.createdAt = Date(); r.change = "产品事实更新"; r.review = Review(); r.invalidated = ["价格/主张", "配音", "字幕", "审批", "导出"]
        for i in r.scenes.indices { if r.scenes[i].showPrice { r.scenes[i].voice = nil; for c in r.scenes[i].captions.indices { r.scenes[i].captions[c].confirmed = false } } }
        p.revisions.append(r); return p
    }
}
public struct QualityIssue: Codable, Identifiable, Sendable {
    public var id: String; public var message: String; public var blocking: Bool
    public init(_ id: String, _ message: String, blocking: Bool = true) { self.id = id; self.message = message; self.blocking = blocking }
}
/// Conservative source matching: it never infers that an unrelated verified document proves a claim.
public enum ClaimRules {
    private static let markers=["保证","销量","收益","治愈","录取率","有效率","提升","收入","第一","最佳","学员","客户","成交","回报","获利","赚"]
    private static func key(_ text:String)->String {text.lowercased().filter{!$0.isWhitespace && !"，,：:、\"“”‘’（）()".contains($0)}}
    public static func sentences(_ text:String)->[String] {
        // URLs are destinations, not evidence of numeric performance.
        let stripped=text.replacingOccurrences(of:"https?://[^\\s]+",with:"",options:.regularExpression)
        return stripped.components(separatedBy:CharacterSet(charactersIn:"。；;！!？?\n\r")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
    }
    public static func candidates(_ text:String)->[String] {
        Array(Set(sentences(text).filter { statement in
            if ["结果不保证","不保证收益","不保证收入","不承诺收益","不代表实际收益"].contains(statement) {return false}
            return statement.range(of:"[0-9]|[零〇一二两三四五六七八九十百千万亿]+(?:元|人|倍|%|％|成|万|亿)",options:.regularExpression) != nil || markers.contains(where:statement.contains)
        })).sorted()
    }
    public static func hasProof(_ statement:String,evidence:[Evidence],workspaceID:String,now:Date=Date())->Bool {
        let exact=key(statement)
        return evidence.contains {item in item.workspaceID==workspaceID && item.usable(commercial:true,now:now) && sentences(item.claim).contains{key($0)==exact}}
    }
    public static func isCurrentPrice(_ statement:String,product:Product,now:Date=Date())->Bool {
        guard let price=try? product.price(at:now),price.verified else{return false}
        let amount=NSDecimalNumber(decimal:price.money.amount).stringValue
        let suffix=price.money.currency=="CNY" ? "元":price.money.currency
        return [amount+suffix,"价格"+amount+suffix,"课程价格"+amount+suffix].map(key).contains(key(statement))
    }
}
public enum Quality {
    public static func inspect(_ revision: Revision, database: Database, requireReview: Bool, now: Date = Date(), enforceBrandDelivery: Bool = true) throws -> [QualityIssue] {
        try revision.validateContext()
        try revision.audioQuality?.validate()
        var issues: [QualityIssue] = []
        let commercial = revision.purpose != .education
        if requireReview && enforceBrandDelivery {
            // Legacy product projects keep their original brand guard. Any actual
            // production brief additionally binds delivery terms in either schema.
            if revision.contentContext == nil { issues += BrandDeliveryRules.inspect(revision:revision,database:database,now:now) }
            if revision.contentContext != nil || revision.productionBrief != nil { issues += ProductionDeliveryRules.inspect(revision:revision,database:database,now:now) }
        }
        if let product=revision.product {
            if commercial && product.isExample==true {issues.append(QualityIssue("example","练习示例不是实际商品，不能用于商业发布；请在真实工作区选择已有产品与资料"))}
            try product.validate()
            let currentPrice=try product.price(at:now)
            if !currentPrice.verified {issues.append(QualityIssue("price","产品价格尚未按来源核实"))}
            let frozenPrice=try? product.price(at:revision.createdAt)
            let priceCTA=ClaimRules.sentences(revision.cta).contains{ClaimRules.isCurrentPrice($0,product:product,now:now) || ClaimRules.isCurrentPrice($0,product:product,now:revision.createdAt)}
            if (revision.scenes.contains(where:{$0.showPrice}) || priceCTA),frozenPrice?.money != currentPrice.money {issues.append(QualityIssue("stale_rendered_price","当前生效价格已不同于本版本成片冻结价格；请创建新版本并重新制作、完整看听审核，历史版本保留"))}
            if let currentProduct=database.products.first(where:{$0.id==product.id}),!currentProduct.hasSameFacts(as:product) {issues.append(QualityIssue("stale_facts","产品事实已变化，需更新项目快照"))}
        } else if revision.scenes.contains(where:{$0.showPrice}) {
            issues.append(QualityIssue("price_without_product","当前工程未关联产品事实，不能显示未经来源核实的产品价格"))
        }
        func isCurrentPrice(_ text:String)->Bool {revision.product.map{ClaimRules.isCurrentPrice(text,product:$0,now:now)} ?? false}
        if requireReview || revision.dependencies != nil { for (index,message) in DependencyRules.reviewIssues(revision:revision,assets:database.assets,evidence:database.evidence,currentProduct:database.products.first{$0.id==revision.product?.id},now:now).enumerated() { issues.append(QualityIssue("dependency-\(index)",message)) } }
        if revision.frames <= 0 || revision.frames > 54000 { issues.append(QualityIssue("duration", "总片长须在0—30分钟范围内")) }
        if revision.cta.contains("\n") || revision.cta.components(separatedBy:"https://").count>2 || revision.cta.components(separatedBy:"http://").count>2 { issues.append(QualityIssue("cta","请保留一个明确行动和一个目的地")) }
        if commercial {
            let linkedIDs=Set(revision.scenes.flatMap(\.evidenceIDs))
            let linked=database.evidence.filter{linkedIDs.contains($0.id)}
            for (index,text) in ClaimRules.candidates(revision.cta).enumerated() where !isCurrentPrice(text) && !ClaimRules.hasProof(text,evidence:linked,workspaceID:revision.workspaceID,now:now) {issues.append(QualityIssue("cta-claims-\(index)","行动提示中的主张须关联该原句的有效证据："+String(text.prefix(100))))}
        }
        for s in revision.scenes {
            try s.validate(assets: database.assets.filter{$0.workspaceID==revision.workspaceID})
            if let take=s.voice {
                do {try SpeechProjectRules.validateCompleteTake(take,workspaceID:revision.workspaceID,assets:database.assets)}
                catch {issues.append(QualityIssue(s.id+"voice_source",(error as? VideoError)?.localizedDescription ?? "配音未绑定完整音频原件"))}
            }
            do {try FontRightsRules.validate(fontName:s.fontName ?? "PingFangSC-Medium",workspaceID:revision.workspaceID,evidenceIDs:s.evidenceIDs,evidence:database.evidence,commercial:commercial,now:now)}
            catch{issues.append(QualityIssue(s.id+"font_rights",(error as? VideoError)?.localizedDescription ?? "镜头字体授权尚未核对"))}
            if s.kind == .simulation || s.kind == .cartoon {
                if s.kind == .simulation && !(s.gameWorld != nil && s.storyCausality != nil && s.simulation.knowledge == nil && s.simulationRecording == nil) {
                    do {try SimulationReplay.verify(scene:s,fps:revision.fps)}
                    catch {issues.append(QualityIssue(s.id+"simulation_recording",(error as? VideoError)?.localizedDescription ?? "规则录制尚未核对"))}
                }
                // scene.validate above has already checked a native rig's real
                // voice/source binding and its explicit independence from classic
                // artwork. An ordinary cartoon without that rig keeps the old gate.
                let nativeRig = s.kind == .cartoon && s.cartoonRig != nil
                if !nativeRig {
                    if s.classicArtwork == nil {issues.append(QualityIssue(s.id+"classic_artwork","请绑定有来源的Q版角色与场景；旧几何预览不代表已满足当前素材要求"))}
                    else if s.gameWorld == nil && s.cartoonPresenter == nil && s.classicArtwork?.derivation != .qStyle {issues.append(QualityIssue(s.id+"classic_qstyle","下载原件须绑定实际Q版处理产物及来源后再制作新成片"))}
                    // A full original game map is explicitly authored through
                    // GameWorld; its real roles, source identity and rights still
                    // pass the same validation instead of receiving a Q-style tag.
                    else {do {try ClassicArtworkRules.validateRights(scene:s,workspaceID:revision.workspaceID,assets:database.assets,evidence:database.evidence,commercial:commercial,requireListening:requireReview,now:now)} catch {issues.append(QualityIssue(s.id+"classic_rights",(error as? VideoError)?.localizedDescription ?? "外部游戏素材、处理来源或音轨许可尚未核对"))}}
                }
            }
            let title=s.title.trimmingCharacters(in:.whitespacesAndNewlines)
            let body=s.body.trimmingCharacters(in:.whitespacesAndNewlines)
            let narration=s.narration.trimmingCharacters(in:.whitespacesAndNewlines)
            // An ordinary narrated paper explanation can let its actual artwork
            // carry the screen without repeating a title. Scene validation above
            // still enforces the image layer's source, size and active frame range.
            let narratedPaperArtwork = s.kind == .explanation && s.paperPresentation?.layout == .explanation && !narration.isEmpty && (s.layers ?? []).contains { layer in
                guard layer.kind == .image,layer.opacity>0,let assetID=layer.assetID else {return false}
                return database.assets.contains { asset in
                    asset.id==assetID && asset.workspaceID==revision.workspaceID && asset.bytes>0 &&
                    (asset.mediaType == "image" || asset.mediaType.hasPrefix("image/"))
                }
            }
            if (title.isEmpty && !narratedPaperArtwork) || (body.isEmpty && narration.isEmpty) { issues.append(QualityIssue(s.id+"text", "镜头标题或知识内容为空；请填写标题，并在画面正文或独立旁白中保留知识内容")) }
            if s.kind == .image || s.kind == .video { if s.assetID == nil { issues.append(QualityIssue(s.id+"asset", "图片/录屏镜头缺少实际素材")) } }
            var refs = s.evidenceIDs
            let sourceIDs=Set([s.assetID,s.characterProfile?.voiceAssetID].compactMap{$0}+(s.layers ?? []).compactMap(\.assetID)+(s.narrativeSources ?? []).map(\.assetID))
            for aid in sourceIDs {
                guard let a=database.assets.first(where:{$0.id==aid && $0.workspaceID==revision.workspaceID}) else {issues.append(QualityIssue(aid+"source_missing","实际引用的素材缺失或跨工作区"));continue}
                if let e=a.evidenceID {refs.append(e)} else if commercial {issues.append(QualityIssue(aid+"rights","源素材或元素层尚未关联权利凭据"))}
            }
            for id in Set(refs) { guard let e = database.evidence.first(where: { $0.id == id && $0.workspaceID==revision.workspaceID }), e.usable(commercial: commercial, now: now) else { issues.append(QualityIssue(id+"rights", "素材/主张未核实、越出工作区、过期或不允许商用")); continue } }
            let claim=([s.title,s.body,s.narration]+s.captions.map(\.text)+(s.layers ?? []).map(\.text)).joined(separator:"\n")
            if commercial {
                let linked=database.evidence.filter{s.evidenceIDs.contains($0.id)}
                let unsupported=ClaimRules.candidates(claim).filter{!isCurrentPrice($0) && !ClaimRules.hasProof($0,evidence:linked,workspaceID:revision.workspaceID,now:now)}
                for (index,text) in unsupported.enumerated() {issues.append(QualityIssue(s.id+"claims-\(index)","主张须关联已核实、允许商用且逐句记录该原句的证据："+String(text.prefix(100))+"。自动检查不代替事实审核"))}
            }
            if !s.narration.isEmpty {
                if let plan=s.speechPlan,requireReview && !plan.confirmed {issues.append(QualityIssue(s.id+"tn_review","中文规范稿和词典读法尚未核对"))}
                if let voice = s.voice { if voice.textDigest != (try s.speechDigest()) { issues.append(QualityIssue(s.id+"voice", "旁白已修改，旧声音失效")) }; if voice.durationFrames > s.durationFrames { issues.append(QualityIssue(s.id+"voice_length", "配音超出镜头，请延长时长；禁止自动截断")) }; if requireReview && !voice.listened { issues.append(QualityIssue(s.id+"listened", "请试听真实配音后确认")) } }
                else { issues.append(QualityIssue(s.id+"voice_missing", "尚无真实配音；请录入/生成声音或明确改为无旁白镜头")) }
            }
            do {_ = try SpeechRules.captionTimelineRanges(for:s)} catch {issues.append(QualityIssue(s.id+"caption_ranges",(error as? VideoError)?.localizedDescription ?? "字幕区间或实际输出时间无效"))}
            if requireReview && s.captions.contains(where: { !$0.confirmed }) { issues.append(QualityIssue(s.id+"captions", "字幕时间尚未人工或可靠时间戳确认")) }
            if requireReview && !s.narration.isEmpty {
                if s.captions.isEmpty { issues.append(QualityIssue(s.id+"captions_missing","有旁白但尚无字幕，请按真实音轨校正")) }
                let pattern=try NSRegularExpression(pattern:"[0-9]+(?:\\.[0-9]+)?")
                func numbers(_ text:String)->Set<String> { let ns=text as NSString;return Set(pattern.matches(in:text,range:NSRange(location:0,length:ns.length)).map{ns.substring(with:$0.range)}) }
                if numbers(s.narration) != numbers(s.captions.map(\.text).joined(separator:" ")) { issues.append(QualityIssue(s.id+"numeric_captions","旁白原文与字幕关键数字不一致，请对照实际口播校正")) }
            }
            if s.showPrice,let product=revision.product,let price=try? product.price(at:now),price.money.currency=="CNY" {
                let text=s.body+" "+s.narration+" "+s.captions.map(\.text).joined(separator:" "),ns=(s.body+" "+s.narration+" "+s.captions.map(\.text).joined(separator:" ")) as NSString
                let pattern=try NSRegularExpression(pattern:"([0-9]+(?:\\.[0-9]+)?)\\s*元")
                if pattern.matches(in:text,range:NSRange(location:0,length:ns.length)).contains(where:{Decimal(string:ns.substring(with:$0.range(at:1))) != price.money.amount}) { issues.append(QualityIssue(s.id+"stale_price_text","产品价格镜头的文字/字幕/旁白含旧价或其他金额，请与当前SKU逐项核对；历史比较请使用独立且有证据的镜头")) }
            }
            if s.body.count > 180 { issues.append(QualityIssue(s.id+"density", "单镜头文字过密，请拆分以保证安全区可读")) }
        }
        for aid in Set(revision.scenes.compactMap{$0.voice?.assetID} + [revision.musicAssetID].compactMap{$0}) {
            guard let asset=database.assets.first(where:{$0.id==aid && $0.workspaceID==revision.workspaceID}) else { issues.append(QualityIssue(aid+"audio_missing","声音素材缺失或跨工作区"));continue }
            if commercial { guard let id=asset.evidenceID, let e=database.evidence.first(where:{$0.id==id && $0.workspaceID==revision.workspaceID}), e.usable(commercial:true,now:now) else { issues.append(QualityIssue(aid+"audio_rights","旁白/配乐尚未核实商业授权"));continue } }
        }
        let currentDigest = try revision.contentDigest()
        if requireReview && (!revision.review.complete || revision.review.digest != currentDigest) { issues.append(QualityIssue("review", "完整预览、声音、字幕、主张与权利需对当前版本逐项确认")) }
        return issues
    }
}
public enum Planner {
    /// Creates an ordinary editing draft from actual workspace/content, without commerce prerequisites.
    public static func create(workspaceID:String,name:String,aspect:Aspect = .landscape,scenes:[Scene] = [],assets:[Asset] = [])throws->Revision {
        let context=ContentContext(workspaceID:workspaceID,name:name)
        try context.validate()
        for scene in scenes {
            let scoped = assets.filter { $0.workspaceID == workspaceID }
            try ClassicArtworkRules.validateWalkingSources(scene:scene,assets:scoped)
            try ClassicArtworkRules.validateGateSources(scene:scene,assets:scoped)
        }
        return Revision(contentContext:context,aspect:aspect,scenes:scenes)
    }
    /// Plans a teaching video from user-supplied content without inventing a product or sales action.
    public static func create(workspaceID:String,name:String,knowledge:String,demonstration:String,hook:String,purpose:Purpose = .education,aspect:Aspect = .portrait,kind:SceneKind = .explanation,evidenceIDs:[String] = [])throws->Revision {
        guard [knowledge,demonstration,hook].allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else{throw VideoError.invalid("请填写完整知识点、真实演示和开场问题")}
        let context=ContentContext(workspaceID:workspaceID,name:name);try context.validate()
        var explanation=Scene(kind:kind,title:hook,body:knowledge,durationFrames:180)
        var demonstrationScene=Scene(kind:.explanation,title:"实际演示",body:demonstration,durationFrames:240)
        explanation.evidenceIDs=evidenceIDs;demonstrationScene.evidenceIDs=evidenceIDs
        return Revision(contentContext:context,purpose:purpose,aspect:aspect,scenes:[explanation,demonstrationScene])
    }
    public static let grammars = ["误区纠正", "前后对比", "实操演示", "规则模拟", "角色争论", "成本拆解"]
    public static func create(product: Product, knowledge: String, demonstration: String, hook: String, purpose: Purpose, aspect: Aspect, kind: SceneKind, evidenceIDs: [String]) throws -> Revision {
        try product.validate(); guard !knowledge.isEmpty, !demonstration.isEmpty, !hook.isEmpty else { throw VideoError.invalid("请填写完整知识点、真实演示和开场问题") }
        var intro = Scene(kind: kind, title: hook, body: "面向：\(product.audience)\n学习任务：\(product.task)", durationFrames: 150)
        var lesson = Scene(kind: kind, title: "先理解这个知识点", body: knowledge, durationFrames: 240)
        var proof = Scene(kind: .explanation, title: "用真实过程验证", body: demonstration, durationFrames: 240)
        var close = Scene(kind: kind, title: product.name, body: "学习成果：\(product.outcome)\n前置条件：\(product.prerequisite)", durationFrames: 150); close.showPrice = true
        intro.evidenceIDs = evidenceIDs; lesson.evidenceIDs = evidenceIDs; proof.evidenceIDs = evidenceIDs; close.evidenceIDs = evidenceIDs
        return Revision(product: product, purpose: purpose, aspect: aspect, scenes: [intro,lesson,proof,close], cta: purpose == .education ? "收藏并亲手复现这个知识点" : "了解课程内容与前置条件：\(product.checkout)")
    }
}
