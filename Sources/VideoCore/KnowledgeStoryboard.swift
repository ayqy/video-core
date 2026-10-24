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

public enum CartoonTeachingRole: String, Codable, Sendable {
    case question, response
}

/// An author-selected shot retains the complete visual performance. Spoken
/// text belongs to the Host and is bound to the corresponding teaching input.
public struct CartoonTeachingShot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: CartoonTeachingRole
    public var title: String
    public var visualSummary: String
    public var narration: String
    public var durationFrames: Int
    public var performance: CartoonPerformance
    public init(id: String = Codec.id(), role: CartoonTeachingRole, title: String, visualSummary: String, narration: String, durationFrames: Int, performance: CartoonPerformance) {
        self.id=id;self.role=role;self.title=title;self.visualSummary=visualSummary;self.narration=narration;self.durationFrames=durationFrames;self.performance=performance
    }
}

/// Version 1 preserves the existing cast-only dialogue. Version 2 is an
/// explicit sequence of complete shots; it never infers a speaker, copies old
/// audio or grants rights to the selected artwork.
public struct CartoonTeachingPlan: Codable, Sendable {
    public var version: Int = 1
    public var artwork: ClassicArtwork
    public var actors: [CartoonActor]
    public var shots: [CartoonTeachingShot]?
    public init(artwork: ClassicArtwork, actors: [CartoonActor]) { self.artwork=artwork;self.actors=actors }
    public init(artwork: ClassicArtwork, shots: [CartoonTeachingShot]) {
        self.version=2;self.artwork=artwork;self.actors=shots.first?.performance.actors ?? [];self.shots=shots
    }
    public func validate(counterargument: String, response: String) throws {
        guard artwork.derivation == .qStyle,artwork.audioCues.isEmpty else { throw VideoError.invalid("角色争论须明确选择实际Q版图集；原音效须在新分镜重新绑定") }
        if version==1 {
            guard shots==nil else { throw VideoError.invalid("完整角色分镜须显式使用第二版计划，不能按旧演员名单忽略表演") }
            _=try performance(speakerIndex:0,durationFrames:1)
            _=try performance(speakerIndex:1,durationFrames:1)
            return
        }
        guard version==2,let shots,(2...96).contains(shots.count),Set(shots.map(\.id)).count==shots.count,
              shots.first?.role == .question,shots.last?.role == .response else { throw VideoError.invalid("完整角色争论须按提问、回应顺序明确填写两种观点及独立分镜标识") }
        var reachedResponse=false
        for shot in shots {
            func valid(_ value:String,_ limit:Int)->Bool { !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.count<=limit }
            guard valid(shot.id,80),valid(shot.title,80),valid(shot.visualSummary,180),valid(shot.narration,160),
                  shot.performance.actors==actors else { throw VideoError.invalid("角色分镜须有完整标题、画面说明、1—160字原讲稿及相同的实际角色名单") }
            if shot.role == .response { reachedResponse=true }
            else if reachedResponse { throw VideoError.invalid("角色分镜须先完整提问再回应，不能重排已写表演") }
            try shot.performance.validate(durationFrames:shot.durationFrames,sprites:artwork.sprites)
        }
        guard shots.filter({$0.role == .question}).map(\.narration).joined().utf8.elementsEqual(counterargument.utf8),
              shots.filter({$0.role == .response}).map(\.narration).joined().utf8.elementsEqual(response.utf8) else { throw VideoError.conflict("角色分镜原讲稿与本次质疑、回应不一致；请明确采用原稿，或先编辑对应讲稿与表演，不能把旧表演套到新稿") }
    }
    public func performance(speakerIndex: Int, durationFrames: Int) throws -> CartoonPerformance {
        guard version==1,shots==nil,artwork.derivation == .qStyle,artwork.audioCues.isEmpty,(2...4).contains(actors.count),actors.indices.contains(speakerIndex) else { throw VideoError.invalid("旧角色争论须明确选择实际Q版图集和2—4名角色；完整分镜不能降为单发言者") }
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
