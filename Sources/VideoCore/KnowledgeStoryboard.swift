import Foundation

/// A source-backed explanatory shot over a contiguous part of an actual model.
/// Tick bounds select computed events; narration is retained by the Host.
public struct KnowledgeStoryboardShot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var narration: String
    public var visualSummary: String?
    public var startTick: Int
    public var endTickExclusive: Int
    public var durationFrames: Int
    public init(id: String = Codec.id(), title: String, narration: String, startTick: Int, endTickExclusive: Int, durationFrames: Int, visualSummary: String? = nil) {
        self.id=id;self.title=title;self.narration=narration;self.visualSummary=visualSummary;self.startTick=startTick;self.endTickExclusive=endTickExclusive;self.durationFrames=durationFrames
    }
}

/// An explicit teaching script, not generated conclusions or a new simulation
/// engine. Both scenarios run with the same seed and the selected actual atlas.
public struct KnowledgeStoryboardPlan: Codable, Sendable {
    public var version: Int = 1
    public var baseline: KnowledgeSimulation
    public var alternative: KnowledgeSimulation
    public var seed: UInt64
    public var artwork: ClassicArtwork
    public var ruleExplanation: String
    public var alternativeExplanation: String
    public var conclusion: String
    public var baselineShots: [KnowledgeStoryboardShot]
    public var alternativeShots: [KnowledgeStoryboardShot]
    public init(baseline: KnowledgeSimulation, alternative: KnowledgeSimulation, seed: UInt64, artwork: ClassicArtwork, ruleExplanation: String, alternativeExplanation: String, conclusion: String, baselineShots: [KnowledgeStoryboardShot], alternativeShots: [KnowledgeStoryboardShot]) {
        self.baseline=baseline;self.alternative=alternative;self.seed=seed;self.artwork=artwork;self.ruleExplanation=ruleExplanation;self.alternativeExplanation=alternativeExplanation;self.conclusion=conclusion;self.baselineShots=baselineShots;self.alternativeShots=alternativeShots
    }
    private static func text(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.count<=limit
    }
    public func validate() throws {
        guard version==1,Self.text(ruleExplanation,limit:6000),Self.text(alternativeExplanation,limit:6000),Self.text(conclusion,limit:6000),artwork.derivation == .qStyle,artwork.audioCues.isEmpty else {
            throw VideoError.invalid("知识分镜须有规则、反事实说明、结论及实际Q版图集；原镜头音效须在新分镜分别重绑，不能沿用旧时间")
        }
        let comparison=try KnowledgeSimulationEngine.compare(baseline:baseline,alternative:alternative,seed:seed)
        guard comparison.baseline.events != comparison.alternative.events else { throw VideoError.invalid("反事实须实际改变策略、约束或事件结果，不能只改标题或复制相同模型") }
        try validate(shots:baselineShots,model:baseline)
        try validate(shots:alternativeShots,model:alternative)
        guard Set((baselineShots+alternativeShots).map(\.id)).count==baselineShots.count+alternativeShots.count else { throw VideoError.invalid("知识分镜标识重复") }
    }
    private func validate(shots: [KnowledgeStoryboardShot], model: KnowledgeSimulation) throws {
        guard (1...48).contains(shots.count) else { throw VideoError.invalid("每份知识演示需1—48段完整分镜") }
        let end=try model.lastSettlementTick()+1
        var boundary=0
        for shot in shots {
            guard Self.text(shot.id,limit:80),Self.text(shot.title,limit:80),Self.text(shot.narration,limit:160),shot.visualSummary.map({Self.text($0,limit:60)}) ?? true,shot.startTick==boundary,shot.endTickExclusive>shot.startTick,shot.endTickExclusive<=end,(30...54000).contains(shot.durationFrames),shot.durationFrames>=shot.endTickExclusive-shot.startTick else {
                throw VideoError.invalid("分镜须按刻度连续覆盖真实演示，标题与1—160字旁白须完整，时长为30—54000帧")
            }
            boundary=shot.endTickExclusive
        }
        guard boundary==end else { throw VideoError.invalid("分镜未覆盖最后一次真实结算，不能提前给出完整结果") }
    }
}

/// The existing debate grammar can opt into an actual, previously bound cast.
/// It never invents a geometric character or grants rights to the selected art.
public struct CartoonTeachingPlan: Codable, Sendable {
    public var version: Int = 1
    public var artwork: ClassicArtwork
    public var actors: [CartoonActor]
    public init(artwork: ClassicArtwork, actors: [CartoonActor]) { self.artwork=artwork;self.actors=actors }
    public func performance(speakerIndex: Int, durationFrames: Int) throws -> CartoonPerformance {
        guard version==1,artwork.derivation == .qStyle,artwork.audioCues.isEmpty,(2...4).contains(actors.count),actors.indices.contains(speakerIndex) else { throw VideoError.invalid("角色争论须明确选择实际Q版图集和2—4名角色；原音效在新分镜重新绑定") }
        let value=try CartoonPerformance.dialogue(actors:actors,speakerID:actors[speakerIndex].id,durationFrames:durationFrames)
        try value.validate(durationFrames:durationFrames,sprites:artwork.sprites)
        return value
    }
}

/// Shared by local synthesis and authorised-audio import after an explicit
/// extend choice. The normal Editor then invalidates recording/listening review.
public enum StoryboardTiming {
    public static func extending(scene: Scene, to durationFrames: Int) throws -> Scene {
        guard (1...54000).contains(scene.durationFrames),durationFrames>=scene.durationFrames,durationFrames<=54000 else { throw VideoError.invalid("声音延长须保留完整有效原镜头，且不能超过54000帧") }
        guard durationFrames != scene.durationFrames else { return scene }
        var value=scene
        if let performance=scene.cartoonPerformance { value.cartoonPerformance=try performance.retimed(from:scene.durationFrames,to:durationFrames) }
        if let presentation=scene.simulationPresentation { value.simulationPresentation=try presentation.retimed(to:durationFrames,durationFrames:scene.durationFrames) }
        if var artwork=scene.classicArtwork {
            for index in artwork.audioCues.indices {
                let cue=artwork.audioCues[index]
                let at=Int((Double(cue.startFrame)*Double(durationFrames)/Double(scene.durationFrames)).rounded())
                guard cue.durationFrames>0,at>=0,at<=durationFrames-cue.durationFrames else { throw VideoError.review("延长后的原音触发位置容不下完整声音，请在新时序手动配置，不能截尾") }
                artwork.audioCues[index].startFrame=at
                artwork.audioCues[index].listened=false
                // Actual audio duration and gain are retained. Only the trigger
                // moves with the shot; narration never stretches source audio.
            }
            value.classicArtwork=artwork
        }
        value.durationFrames=durationFrames
        return value
    }
}
