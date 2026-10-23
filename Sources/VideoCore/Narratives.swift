import Foundation

public enum NarrativeGrammar: String, Codable, CaseIterable, Sendable {
    case misconception = "误区纠正", analogy = "类比说明", practice = "实操演示", simulation = "规则模拟"
    case debate = "角色争论", beforeAfter = "前后对比", costs = "成本拆解", productComparison = "产品对比", series = "连续栏目"
}
public enum NarrativeBeatRole: String, Codable, CaseIterable, Sendable {
    case hook = "开场问题", knowledge = "知识点", example = "示例或类比", claim = "事实主张", entertainment = "娱乐桥段", demonstration = "真实演示", boundary = "适用边界", action = "唯一行动"
}
public struct NarrativeSource: Codable, Equatable, Identifiable, Sendable {
    public var id = Codec.id(); public var assetID: String; public var pages: [Int]; public var startFrame: Int?; public var endFrame: Int?; public var excerpt: String; public var confirmed: Bool
    public init(assetID: String, pages: [Int] = [], startFrame: Int? = nil, endFrame: Int? = nil, excerpt: String, confirmed: Bool = false) {
        self.assetID = assetID; self.pages = pages; self.startFrame = startFrame; self.endFrame = endFrame; self.excerpt = excerpt; self.confirmed = confirmed
    }
    public func validate(workspaceID: String, assets: [Asset]) throws {
        guard let asset = assets.first(where: { $0.id == assetID && $0.workspaceID == workspaceID }), confirmed, !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VideoError.review("知识点须关联本工作区的真实材料并人工确认摘录") }
        guard Set(pages).count == pages.count, pages.allSatisfy({ n in asset.pages.contains(where: { $0.number == n && $0.confirmed && !$0.requiresOCR }) }) else { throw VideoError.review("课程页未校对、仍需OCR或页码不存在") }
        if !asset.pages.isEmpty { guard !pages.isEmpty else { throw VideoError.invalid("分页课程材料须选择具体页码") } }
        if let total = asset.durationFrames {
            guard let start = startFrame, let end = endFrame, start >= 0, end > start, end <= total else { throw VideoError.invalid("音视频知识点须指定实际时长内的片段") }
        } else { guard startFrame == nil, endFrame == nil else { throw VideoError.invalid("静态材料不能使用媒体裁切范围") } }
    }
}
public struct NarrativeInput: Codable, Sendable {
    public var topic: Topic; public var targetLearner: String; public var casualViewer: String; public var promiseScope: String; public var boundary: String
    public var grammar: NarrativeGrammar; public var sources: [NarrativeSource]; public var feedbackSummary = ""; public var steps: [String] = []; public var startingPoint = ""; public var result = ""; public var analogy = ""; public var counterargument = ""; public var response = ""; public var humour = ""; public var costItems: [NarrativeCostItem] = []; public var comparedProduct = ""; public var comparisonBasis = ""; public var simulation: Simulation?; public var purpose: Purpose; public var aspect: Aspect
    public init(topic: Topic, targetLearner: String, casualViewer: String, promiseScope: String, boundary: String, grammar: NarrativeGrammar, sources: [NarrativeSource], purpose: Purpose, aspect: Aspect) {
        self.topic = topic; self.targetLearner = targetLearner; self.casualViewer = casualViewer; self.promiseScope = promiseScope; self.boundary = boundary; self.grammar = grammar; self.sources = sources; self.purpose = purpose; self.aspect = aspect
    }
}
public struct NarrativeCostItem: Codable, Equatable, Sendable {
    public var label: String; public var money: Money; public var evidenceID: String
    public init(label: String, money: Money, evidenceID: String) { self.label = label; self.money = money; self.evidenceID = evidenceID }
}
public enum CharacterSilhouette: String, Codable, CaseIterable, Sendable { case circle = "圆形", square = "方形", diamond = "菱形" }
public struct CharacterProfile: Codable, Equatable, Identifiable, Sendable {
    public var id = Codec.id(); public var name: String; public var silhouette: CharacterSilhouette; public var color: String; public var expressions: [String]; public var actions: [String]; public var evidenceIDs: [String]; public var voiceAssetID: String?; public var original: Bool
    public init(name: String, silhouette: CharacterSilhouette = .circle, color: String = "6366F1", expressions: [String] = ["好奇", "思考", "开心"], actions: [String] = ["讲解", "指向", "点头"], evidenceIDs: [String] = [], voiceAssetID: String? = nil, original: Bool = true) {
        self.name = name; self.silhouette = silhouette; self.color = color; self.expressions = expressions; self.actions = actions; self.evidenceIDs = evidenceIDs; self.voiceAssetID = voiceAssetID; self.original = original
    }
}
/// Font availability and glyph coverage are checked by the media renderer.
/// This shared rule checks the selected, workspace-scoped rights evidence only.
public enum FontRightsRules {
    public static let systemFontNames:Set<String>=["PingFangSC-Regular","PingFangSC-Medium"]
    public static func validate(fontName:String,workspaceID:String,evidenceIDs:[String],evidence:[Evidence],commercial:Bool,now:Date=Date())throws {
        guard !fontName.isEmpty,fontName==fontName.trimmingCharacters(in:.whitespacesAndNewlines),fontName.utf8.count<=256 else{throw VideoError.invalid("请填写明确的字体PostScript名称")}
        if systemFontNames.contains(fontName){return}
        let selected=Set(evidenceIDs)
        guard evidence.contains(where:{selected.contains($0.id) && $0.workspaceID==workspaceID && $0.usable(commercial:commercial,now:now) && $0.claim.contains(fontName)}) else{throw VideoError.review("自定义字体须关联本工作区已核实且包含该PostScript名称的有效授权凭据："+fontName)}
    }
}
public struct StyleKit: Codable, Identifiable, Sendable {
    public var tags:[String]?
    public var createdAt:Date?
    public var id = Codec.id(); public var workspaceID: String; public var name: String; public var version: Int = 1; public var palette: [String]; public var fontName: String; public var musicAssetID: String?; public var evidenceIDs: [String]; public var characters: [CharacterProfile]; public var negativeConstraints: [String]
    public init(workspaceID: String, name: String, palette: [String] = ["6366F1", "0EA5E9"], fontName: String = "PingFangSC-Regular", musicAssetID: String? = nil, evidenceIDs: [String] = [], characters: [CharacterProfile] = [], negativeConstraints: [String] = ["不虚构成果", "不重画真实价格和UI", "类比和模拟不冒充现实规律"]) {
        self.createdAt=Date(); self.workspaceID = workspaceID; self.name = name; self.palette = palette; self.fontName = fontName; self.musicAssetID = musicAssetID; self.evidenceIDs = evidenceIDs; self.characters = characters; self.negativeConstraints = negativeConstraints
    }
    public func validate(assets: [Asset], evidence: [Evidence], commercial: Bool, now: Date) throws {
        guard version > 0, !name.isEmpty, !palette.isEmpty, palette.allSatisfy({ $0.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil }), !fontName.isEmpty else { throw VideoError.invalid("风格版本、名称、字体或配色无效") }
        try FontRightsRules.validate(fontName:fontName,workspaceID:workspaceID,evidenceIDs:evidenceIDs,evidence:evidence,commercial:commercial,now:now)
        var required = evidenceIDs
        for character in characters {
            guard !character.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !character.expressions.isEmpty, !character.actions.isEmpty, (character.expressions+character.actions).allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}), character.color.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw VideoError.invalid("角色名称、配色、表情或动作未完整定义") }
            guard character.original || !character.evidenceIDs.isEmpty else { throw VideoError.review("非原创角色须提供明确使用授权") }
            required += character.evidenceIDs
            if let voice = character.voiceAssetID { guard let asset = assets.first(where: { $0.id == voice && $0.workspaceID == workspaceID && $0.mediaType == "audio" }), let rights = asset.evidenceID else { throw VideoError.review("角色声音缺少音频或授权关联") }; required.append(rights) }
        }
        if let music = musicAssetID { guard let asset = assets.first(where: { $0.id == music && $0.workspaceID == workspaceID && $0.mediaType == "audio" }), let rights = asset.evidenceID else { throw VideoError.review("栏目音乐缺少音频或授权关联") }; required.append(rights) }
        for id in Set(required) { guard evidence.contains(where: { $0.id == id && $0.workspaceID == workspaceID && $0.usable(commercial: commercial, now: now) }) else { throw VideoError.review("样式、角色、音色或音乐授权缺失/过期") } }
    }
    /// Derives a new value; callers validate its selected rights/assets in their
    /// actual workspace before saving or composing. The old version is untouched.
    public func derived(name:String,palette:[String],fontName:String,fontEvidenceIDs:[String],characters:[CharacterProfile])throws->StyleKit {
        guard version>0,version<Int.max,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!palette.isEmpty,palette.allSatisfy({$0.range(of:"^[0-9A-Fa-f]{6}$",options:.regularExpression) != nil}),!fontName.isEmpty,fontName==fontName.trimmingCharacters(in:.whitespacesAndNewlines),fontName.utf8.count<=256 else{throw VideoError.invalid("新风格名称、配色或字体无效，或旧版本已不能继续递增")}
        guard characters.allSatisfy({!$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !$0.actions.isEmpty && !$0.expressions.isEmpty && ($0.actions+$0.expressions).allSatisfy{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty} && $0.color.range(of:"^[0-9A-Fa-f]{6}$",options:.regularExpression) != nil}) else{throw VideoError.invalid("角色名称、配色、表情与有序动作列表须完整填写")}
        var next=self;next.id=Codec.id();next.createdAt=Date();next.version=version+1;next.name=name;next.palette=palette;next.fontName=fontName;next.evidenceIDs=fontEvidenceIDs;next.characters=characters;return next
    }
}
public struct TemplateBeat: Codable, Equatable, Sendable {
    public var role: NarrativeBeatRole; public var frames: Int; public var kind: SceneKind; public var motion: Bool
    public init(role: NarrativeBeatRole, frames: Int, kind: SceneKind = .explanation, motion: Bool = false) { self.role = role; self.frames = frames; self.kind = kind; self.motion = motion }
}
public struct NarrativeTemplate: Codable, Identifiable, Sendable {
    public var tags:[String]?
    public var createdAt:Date?
    public var id = Codec.id(); public var workspaceID: String; public var name: String; public var version = 2; public var compatibleIR = 1; public var grammars: [NarrativeGrammar]; public var beats: [TemplateBeat]; public var parentVersion: Int?; public var migrationNotes: [String] = []
    public init(workspaceID: String, name: String, grammars: [NarrativeGrammar] = NarrativeGrammar.allCases, beats: [TemplateBeat] = []) { self.createdAt=Date(); self.workspaceID = workspaceID; self.name = name; self.grammars = grammars; self.beats = beats }
    public func validate() throws {
        guard (1...2).contains(version), compatibleIR == 1, !name.isEmpty, !grammars.isEmpty, Set(grammars).count == grammars.count, Set(beats.map(\.role)).count == beats.count, beats.allSatisfy({ (30...1800).contains($0.frames) && [.explanation, .cartoon, .simulation].contains($0.kind) }) else { throw VideoError.invalid("模板版本不兼容、节拍重复、时长越界或引用未支持的原语") }
    }
    public func migrated() throws -> NarrativeTemplate {
        try validate(); var next = self
        if version == 1 { next.parentVersion = 1; next.version = 2; next.migrationNotes.append("v1→v2：保留全部场景参数，补充显式知识/边界/唯一CTA节拍约束，重新人工确认") }
        return next
    }
}
public struct SeriesProfile: Codable, Identifiable, Sendable {
    public var tags:[String]?
    public var createdAt:Date?
    public var id = Codec.id(); public var workspaceID: String; public var name: String; public var styleID: String; public var styleVersion: Int; public var templateID: String; public var templateVersion: Int; public var episodePrefix: String; public var recurringQuestion: String; public var episodeNumber: Int
    public init(workspaceID: String, name: String, style: StyleKit, template: NarrativeTemplate, episodePrefix: String, recurringQuestion: String, episodeNumber: Int = 1) {
        self.createdAt=Date(); self.workspaceID = workspaceID; self.name = name; self.styleID = style.id; self.styleVersion = style.version; self.templateID = template.id; self.templateVersion = template.version; self.episodePrefix = episodePrefix; self.recurringQuestion = recurringQuestion; self.episodeNumber = episodeNumber
    }
}
public struct NarrativeBeat: Codable, Equatable, Identifiable, Sendable {
    public var id = Codec.id(); public var role: NarrativeBeatRole; public var sceneID: String; public var text: String; public var sourceIDs: [String]; public var evidenceIDs: [String]; public var characterID: String?
}
public struct ScriptRewrite: Codable, Sendable {
    public var sceneID: String; public var before: String; public var after: String; public var author: String; public var reason: String; public var at: Date
}
public struct NarrativeDocument: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var workspaceID: String; public var input: NarrativeInput; public var revision: Revision; public var beats: [NarrativeBeat]; public var style: StyleKit; public var template: NarrativeTemplate; public var series: SeriesProfile?; public var rewrites: [ScriptRewrite] = []; public var confirmedDigest: String?; public var confirmedBy: String?; public var confirmedAt: Date?
    public var confirmed: Bool { (try? revision.contentDigest()) == confirmedDigest && confirmedDigest != nil }
    public mutating func confirm(reviewer: String, now: Date = Date()) throws {
        guard !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VideoError.invalid("人工确认须填写审核者") }
        confirmedDigest = try revision.contentDigest(); confirmedBy = reviewer; confirmedAt = now
    }
    public mutating func rewrite(sceneID: String, text: String, author: String, reason: String, assets: [Asset], now: Date = Date()) throws {
        guard !author.isEmpty, !reason.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let index = revision.scenes.firstIndex(where: { $0.id == sceneID }), let beat = beats.firstIndex(where: { $0.sceneID == sceneID }) else { throw VideoError.invalid("改写须指定场景、完整文案、作者和理由") }
        let before = revision.scenes[index].body; var scene = revision.scenes[index]; scene.body = text; scene.narration = text
        let p = Project(workspaceID: workspaceID, name: input.topic.hook, revision: revision)
        revision = try Editor.apply([.replaceScene(sceneID, scene)], to: p, baseRevision: revision.id, assets: assets, message: "人工改写：\(reason)").current
        beats[beat].text = text; rewrites.append(ScriptRewrite(sceneID: sceneID, before: before, after: text, author: author, reason: reason, at: now)); confirmedDigest = nil; confirmedBy = nil; confirmedAt = nil
    }
}

public enum NarrativePlanner {
    public static func compose(input: NarrativeInput, product: Product, assets: [Asset], evidence: [Evidence], template: NarrativeTemplate, style: StyleKit, series: SeriesProfile? = nil, now: Date = Date()) throws -> NarrativeDocument {
        try product.validate(); let topic = input.topic; let t = try template.migrated()
        guard topic.workspaceID == product.workspaceID, topic.productID == product.id, style.workspaceID == product.workspaceID, t.workspaceID == product.workspaceID, t.grammars.contains(input.grammar) else { throw VideoError.permission("选题、产品、模板和风格须属于同一工作区且语法兼容") }
        let required = [topic.audience, topic.task, topic.knowledge, topic.hook, topic.outcome, topic.proof, topic.cta, topic.channel, input.targetLearner, input.casualViewer, input.promiseScope, input.boundary]
        guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), input.targetLearner != input.casualViewer, topic.budget.amount >= 0 else { throw VideoError.invalid("选题须完整填写学习者/围观者、任务、知识点、小成果、证明方式、边界、渠道和唯一CTA") }
        guard !input.sources.isEmpty else { throw VideoError.review("请从真实课程材料中选择知识点来源") }
        for source in input.sources { try source.validate(workspaceID: product.workspaceID, assets: assets) }
        for id in topic.evidenceIDs { guard evidence.contains(where: { $0.id == id && $0.workspaceID == product.workspaceID && $0.usable(commercial: input.purpose != .education, now: now) }) else { throw VideoError.review("选题的事实或权利证据缺失、未核验或已过期") } }
        try style.validate(assets: assets, evidence: evidence, commercial: input.purpose != .education, now: now)
        if let s = series { guard s.workspaceID == product.workspaceID, !s.name.isEmpty, s.episodeNumber > 0, s.styleID == style.id, s.styleVersion == style.version, s.templateID == t.id, s.templateVersion == t.version else { throw VideoError.conflict("栏目绑定的样式/模板版本已变，请迁移栏目并重新确认") } }
        // One action slot accepts one destination. The renderer does not inject other product CTAs.
        let urls = topic.cta.components(separatedBy: .whitespacesAndNewlines).filter { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
        guard urls.count <= 1, !topic.cta.contains("；"), !topic.cta.contains(";"), !topic.cta.contains("\n") else { throw VideoError.invalid("CTA须只有一个动作和最多一个链接") }
        var contents: [(NarrativeBeatRole, String, String)] = [(.hook, "给目标学习者的问题", topic.hook), (.knowledge, "这次学会什么", topic.knowledge)]
        func require(_ values: String...) throws { guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw VideoError.invalid("请补齐\(input.grammar.rawValue)所需的真实内容") } }
        switch input.grammar {
        case .misconception:
            try require(input.startingPoint, input.response); contents.append((.example, "常见误解（待纠正）", input.startingPoint)); contents.append((.claim, "根据材料纠正", input.response))
        case .analogy:
            try require(input.analogy); contents.append((.example, "帮助理解的类比", input.analogy))
        case .practice:
            guard !input.steps.isEmpty, input.steps.count <= 12, input.steps.allSatisfy({ !$0.isEmpty }) else { throw VideoError.invalid("实操须填写1至12个可复现步骤") }; for (n, step) in input.steps.enumerated() { contents.append((.demonstration, "操作 \(n + 1)", step)) }
        case .simulation:
            guard let simulation = input.simulation else { throw VideoError.invalid("规则模拟须定义单位、容量、事件与种子") }; _ = try SimulationReplay.record(simulation: simulation, throughTick: 0); contents.append((.example, "规则假设，不代表现实定律", "单位：\(simulation.unit)；初值：\(simulation.initial)；容量：\(simulation.capacity)；事件数：\(simulation.events.count)"))
        case .debate:
            try require(input.counterargument, input.response); guard style.characters.count >= 2 else { throw VideoError.invalid("角色争论至少需要两名已定义角色") }; contents.append((.example, "\(style.characters[0].name)的疑问", input.counterargument)); contents.append((.claim, "\(style.characters[1].name)用材料回应", input.response))
        case .beforeAfter:
            try require(input.startingPoint, input.result); contents.append((.example, "相同条件下的起点", input.startingPoint)); contents.append((.claim, "真实演示后的观察", input.result)); guard !topic.evidenceIDs.isEmpty else { throw VideoError.review("前后结果对比须引用真实证明材料") }
        case .costs:
            guard !input.costItems.isEmpty, input.costItems.count <= 12 else { throw VideoError.invalid("成本拆解须填写逐项金额与来源") }
            let currency = input.costItems[0].money.currency; var total = Money(0, currency)
            for item in input.costItems { try require(item.label, item.evidenceID); guard topic.evidenceIDs.contains(item.evidenceID), item.money.amount >= 0 else { throw VideoError.review("每项成本须引用本选题已核实证据") }; total = try total.adding(item.money); contents.append((.claim, item.label, "\(item.money.display)；来源见该镜头证据")) }; contents.append((.example, "同币种项目合计", total.display))
        case .productComparison:
            try require(input.comparedProduct, input.comparisonBasis, input.startingPoint, input.result); guard !topic.evidenceIDs.isEmpty else { throw VideoError.review("产品对比须有真实参数与同条件证据") }; contents.append((.example, "同条件比较：\(input.comparisonBasis)", "\(product.name)：\(input.startingPoint)")); contents.append((.claim, input.comparedProduct, input.result))
        case .series:
            guard let s = series, !s.recurringQuestion.isEmpty else { throw VideoError.invalid("连续栏目须保存栏目问题、样式及模板版本") }; contents[0] = (.hook, "\(s.episodePrefix) \(s.episodeNumber)", topic.hook)
        }
        if !input.humour.isEmpty { contents.append((.entertainment, "娱乐桥段（不作为事实证据）", input.humour)) }
        contents.append((.demonstration, "用真实过程验证", topic.proof)); contents.append((.boundary, "本次承诺和适用边界", "\(input.promiseScope)\n\(input.boundary)")); contents.append((.action, "下一步，只做一件事", topic.cta))
        var scenes: [Scene] = []; var beats: [NarrativeBeat] = []
        for (index, item) in contents.enumerated() {
            let parameter = t.beats.first(where: { $0.role == item.0 }); let kind: SceneKind = (input.grammar == .simulation && item.0 == .example) ? .simulation : (input.grammar == .debate && [.example, .claim].contains(item.0)) ? .cartoon : (parameter?.kind ?? .explanation)
            guard item.2.count <= 180, item.1.count <= 80 else { throw VideoError.invalid("单个节拍文字过长，请拆分或精简，不能默默裁掉知识内容") }
            var scene = Scene(kind: kind, title: item.1, body: item.2, narration: item.2, durationFrames: parameter?.frames ?? (item.0 == .hook ? 120 : item.0 == .action ? 150 : 240)); scene.fontName=style.fontName;scene.color = style.palette[index % style.palette.count]; scene.evidenceIDs = Array(Set(topic.evidenceIDs + style.evidenceIDs)).sorted(); scene.narrativeSources = input.sources
            let character = style.characters.isEmpty ? nil : style.characters[index % style.characters.count]
            if let character { scene.character = character.name; scene.characterProfile = character; scene.emotion = character.expressions[index % character.expressions.count]; scene.color = character.color; scene.evidenceIDs = Array(Set(scene.evidenceIDs + character.evidenceIDs)).sorted() }
            if let simulation = input.simulation, kind == .simulation { scene.simulation = simulation }
            if parameter?.motion == true { scene.keyframes = [Keyframe(frame: 0, x: 0.46, y: 0.5, scale: 0.95), Keyframe(frame: scene.durationFrames - 1, x: 0.54, y: 0.5, scale: 1.05)] }
            let source = input.sources[index % input.sources.count]
            if item.0 == .demonstration, let asset = assets.first(where: { $0.id == source.assetID }), asset.mediaType == "video", let start = source.startFrame, let end = source.endFrame { scene.kind = .video; scene.assetID = asset.id; scene.sourceStartFrame = start; scene.sourceEndFrame = end; scene.durationFrames = min(scene.durationFrames, end - start) }
            try scene.validate(assets: assets); scenes.append(scene); beats.append(NarrativeBeat(role: item.0, sceneID: scene.id, text: item.2, sourceIDs: input.sources.map(\.id), evidenceIDs: scene.evidenceIDs, characterID: character?.id))
        }
        var revision = Revision(product: product, purpose: input.purpose, aspect: input.aspect, scenes: scenes, cta: topic.cta, change: "\(input.grammar.rawValue)·模板\(t.name) v\(t.version)（待人工确认）"); revision.musicAssetID = style.musicAssetID; revision.dependencies = try DependencyRules.freeze(revision: revision, assets: assets, evidence: evidence, now: now)
        return NarrativeDocument(workspaceID: product.workspaceID, input: input, revision: revision, beats: beats, style: style, template: t, series: series)
    }
}

public struct RuleTransition: Codable, Equatable, Sendable {
    public var tick: Int; public var eventID: String; public var label: String; public var requestedDelta: Int; public var before: Int; public var after: Int; public var appliedDelta: Int; public var clippedDelta: Int
}
public struct RuleTrace: Codable, Equatable, Sendable {
    public var ruleVersion: Int; public var inputDigest: String; public var seed: UInt64; public var unit: String; public var initial: Int; public var capacity: Int; public var throughTick: Int; public var frameStep: Int; public var transitions: [RuleTransition]; public var finalState: Int
    public var recordedFPS: Int?
    public var recordedDurationFrames: Int?
    public var recordedSpeed: Double?
    public var recordedPauseFrames: Int?
    public var recordedLastSourceFrame: Int?
}
public struct RuleParticle: Codable, Equatable, Sendable { public var x: Double; public var y: Double; public var phase: Double }
public struct RuleFrameState: Codable, Equatable, Sendable { public var value: Int; public var capacity: Int; public var unit: String; public var tick: Int; public var activeEvents: [String]; public var particles: [RuleParticle] }
public enum SimulationReplay {
    /// A scene recording includes every visible tick. Events after the last visible tick
    /// must be moved or the scene extended; they are never silently dropped from a recording.
    public static func record(scene: Scene, fps: Int = 30) throws -> RuleTrace {
        guard scene.kind == .simulation, (1...120).contains(fps), (1...54000).contains(scene.durationFrames), (0.25...4).contains(scene.speed), (0...54000).contains(scene.pauseFrames), scene.timelineFrames > 0 else {
            throw VideoError.invalid("请选择有效规则镜头、帧率与时长后录制")
        }
        let lastSourceFrame = scene.renderSourceFrame(atTimelineFrame: scene.timelineFrames - 1)
        let lastTick = lastSourceFrame / fps
        guard scene.simulation.events.allSatisfy({ $0.tick <= lastTick }) else {
            throw VideoError.review("规则事件超出镜头可见时长；请延长镜头或调整事件，再重新录制和复核")
        }
        var trace = try record(simulation: scene.simulation, throughTick: lastTick)
        trace.recordedFPS = fps; trace.recordedDurationFrames = scene.durationFrames
        trace.recordedSpeed = scene.speed; trace.recordedPauseFrames = scene.pauseFrames; trace.recordedLastSourceFrame = lastSourceFrame
        return trace
    }
    /// Called by production quality checks as well as explicit editor/SDK confirmation.
    /// Generic whole-video approval never substitutes for this rule-specific review.
    public static func verify(scene: Scene, fps: Int = 30, requireConfirmation: Bool = true) throws {
        guard let recording = scene.simulationRecording else {
            throw VideoError.review("此规则镜头尚未录制轨迹；请录制并逐项复核单位、种子与事件后制作")
        }
        let current = try record(scene: scene, fps: fps)
        try verify(recording: recording, simulation: scene.simulation)
        guard recording == current else {
            throw VideoError.review("镜头时长、帧率、变速或停顿已变，旧规则录制不覆盖当前镜头；请重新录制和复核")
        }
        guard !requireConfirmation || scene.simulationRecordingConfirmed == true else {
            throw VideoError.review("规则轨迹尚未明确复核；请核对初值、单位、种子、逐事件结果及截断量后确认")
        }
    }
    public static func record(simulation s: Simulation, throughTick: Int, frameStep: Int = 1) throws -> RuleTrace {
        guard throughTick >= 0, throughTick <= 1800, frameStep > 0, frameStep <= 60, s.capacity > 0, s.capacity <= 10000, s.initial >= 0, s.initial <= s.capacity, !s.unit.isEmpty, s.unit.count <= 40, s.events.count <= 2000, Set(s.events.map(\.id)).count == s.events.count, s.events.allSatisfy({ $0.tick >= 0 && $0.tick <= 1800 && (-10000...10000).contains($0.delta) && !$0.label.isEmpty }) else { throw VideoError.invalid("规则初值/容量/单位/事件/录制区间无效") }
        var value = s.initial; var trace: [RuleTransition] = []
        for (_, event) in s.events.enumerated().sorted(by: { $0.element.tick == $1.element.tick ? $0.offset < $1.offset : $0.element.tick < $1.element.tick }) where event.tick <= throughTick {
            let before = value; value = max(0, min(s.capacity, before + event.delta)); let applied = value - before
            trace.append(RuleTransition(tick: event.tick, eventID: event.id, label: event.label, requestedDelta: event.delta, before: before, after: value, appliedDelta: applied, clippedDelta: event.delta - applied))
        }
        return RuleTrace(ruleVersion: 1, inputDigest: try Codec.digest(s), seed: s.seed, unit: s.unit, initial: s.initial, capacity: s.capacity, throughTick: throughTick, frameStep: frameStep, transitions: trace, finalState: value)
    }
    public static func verify(recording: RuleTrace, simulation: Simulation) throws {
        var causalTrace = recording
        causalTrace.recordedFPS = nil; causalTrace.recordedDurationFrames = nil
        causalTrace.recordedSpeed = nil; causalTrace.recordedPauseFrames = nil; causalTrace.recordedLastSourceFrame = nil
        guard causalTrace.ruleVersion == 1, causalTrace.inputDigest == (try Codec.digest(simulation)), causalTrace == (try record(simulation: simulation, throughTick: causalTrace.throughTick, frameStep: causalTrace.frameStep)) else { throw VideoError.review("规则、单位、参数、种子或事件已变，旧录制失效，请重新录制和复核") }
    }
    public static func frameState(simulation: Simulation, frame: Int, fps: Int = 30) throws -> RuleFrameState {
        guard frame >= 0, (1...120).contains(fps), frame / fps <= 1800 else { throw VideoError.invalid("模拟帧或帧率超界") }
        let tick = frame / fps; let trace = try record(simulation: simulation, throughTick: tick); var random = simulation.seed
        func unit() -> Double { random &+= 0x9e3779b97f4a7c15; var z = random; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9; z = (z ^ (z >> 27)) &* 0x94d049bb133111eb; return Double(z ^ (z >> 31)) / Double(UInt64.max) }
        let particles = (0..<min(100, trace.finalState)).map { _ in RuleParticle(x: unit(), y: unit(), phase: unit()) }
        return RuleFrameState(value: trace.finalState, capacity: simulation.capacity, unit: simulation.unit, tick: tick, activeEvents: trace.transitions.filter { $0.tick == tick }.map { "\($0.label)：\($0.before)→\($0.after) \(simulation.unit)（请求\($0.requestedDelta)，实际\($0.appliedDelta)）" }, particles: particles)
    }
}
