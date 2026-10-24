import Foundation

public struct Price: Codable, Equatable, Identifiable, Sendable {
    public var id = Codec.id(); public var money: Money; public var from: Date; public var until: Date?; public var source: String; public var verified: Bool
    public init(money: Money, from: Date = Date(), until: Date? = nil, source: String, verified: Bool = false) { self.money = money; self.from = from; self.until = until; self.source = source; self.verified = verified }
}
public struct Product: Codable, Identifiable, Equatable, Sendable {
    public var isExample:Bool?
    public var id = Codec.id(); public var workspaceID: String; public var sku: String; public var name: String; public var checkout: String
    public var audience: String; public var task: String; public var outcome: String; public var prerequisite: String; public var scope: String
    public var prices: [Price]; public var assetIDs: [String] = []; public var tags: [String] = []; public var archived = false
    public var courseMappings: [CourseMapping]?
    public func hasSameFacts(as other:Product)->Bool {var left=self,right=other;left.tags=[];right.tags=[];return left==right}
    public init(workspaceID: String, sku: String, name: String, checkout: String, audience: String, task: String, outcome: String, prerequisite: String, scope: String, prices: [Price]) { self.workspaceID = workspaceID; self.sku = sku; self.name = name; self.checkout = checkout; self.audience = audience; self.task = task; self.outcome = outcome; self.prerequisite = prerequisite; self.scope = scope; self.prices = prices }
    public func price(at date: Date = Date()) throws -> Price {
        let active = prices.filter { $0.from <= date && ($0.until == nil || $0.until! > date) }
        guard active.count == 1 else { throw VideoError.invalid("当前时间必须恰有一条有效价格，检查生效期是否重叠或缺失") }; return active[0]
    }
    public func validate() throws {
        guard !sku.trimmingCharacters(in: .whitespaces).isEmpty, !name.isEmpty, !audience.isEmpty, !task.isEmpty, !outcome.isEmpty, !scope.isEmpty else { throw VideoError.invalid("请填写SKU、产品名、人群、学习任务、成果与内容范围") }
        guard let url = URL(string: checkout), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw VideoError.invalid("购买页须为已有的有效HTTP(S)链接") }
        guard !prices.isEmpty else { throw VideoError.invalid("至少需要一条价格") }
        for p in prices { guard p.money.amount >= 0, p.until == nil || p.until! > p.from, !p.source.isEmpty else { throw VideoError.invalid("价格/生效期/来源不合法") } }
        for (i,p) in prices.enumerated() { for q in prices.dropFirst(i+1) { if p.from < (q.until ?? .distantFuture) && q.from < (p.until ?? .distantFuture) { throw VideoError.invalid("同一SKU的价格生效期重叠") } } }
    }
}
public struct Evidence: Codable, Identifiable, Sendable {
    public var tags: [String]?
    public func contentDigest() throws -> String {var value=self;value.tags=nil;return try Codec.digest(value)}
    public var id = Codec.id(); public var workspaceID: String; public var title: String; public var source: String; public var claim: String; public var owner: String
    public var commercialAllowed: Bool; public var uploadConsent: Bool; public var verified: Bool; public var checkedAt: Date; public var expiresAt: Date?; public var assetID: String?
    public init(workspaceID: String, title: String, source: String, claim: String, owner: String, commercialAllowed: Bool, uploadConsent: Bool = false, verified: Bool = false, expiresAt: Date? = nil, assetID: String? = nil) { self.workspaceID = workspaceID; self.title = title; self.source = source; self.claim = claim; self.owner = owner; self.commercialAllowed = commercialAllowed; self.uploadConsent = uploadConsent; self.verified = verified; self.checkedAt = Date(); self.expiresAt = expiresAt; self.assetID = assetID }
    public func usable(commercial: Bool, now: Date = Date()) -> Bool { verified && !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !owner.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && checkedAt<=now.addingTimeInterval(60) && (expiresAt == nil || expiresAt! > now) && (!commercial || commercialAllowed) }
}
public struct CoursePage: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var number: Int; public var text: String; public var notes: String; public var requiresOCR: Bool; public var confirmed = false
    public init(number: Int, text: String, notes: String = "", requiresOCR: Bool = false) { self.number = number; self.text = text; self.notes = notes; self.requiresOCR = requiresOCR }
}
public struct Asset: Codable, Identifiable, Sendable {
    public var generatedSource:GeneratedAssetSource?
    public var importedAt: Date?
    public var id = Codec.id(); public var workspaceID: String; public var name: String; public var hash: String; public var ext: String; public var bytes: Int; public var mediaType: String; public var durationFrames: Int?; public var pages: [CoursePage] = []; public var warnings: [String] = []; public var evidenceID: String?; public var tags: [String] = []
    public init(workspaceID: String, name: String, hash: String, ext: String, bytes: Int, mediaType: String, durationFrames: Int? = nil) { self.workspaceID = workspaceID; self.name = name; self.hash = hash; self.ext = ext; self.bytes = bytes; self.mediaType = mediaType; self.durationFrames = durationFrames }
    public var relativePath: String { "assets/\(hash).\(ext)" }
}
public struct Caption: Codable, Identifiable, Equatable, Sendable {
    public var id = Codec.id(); public var text: String; public var startFrame: Int; public var endFrame: Int; public var alignment: String; public var confirmed: Bool
    public init(text: String, startFrame: Int, endFrame: Int, alignment: String = "manual", confirmed: Bool = false) { self.text = text; self.startFrame = startFrame; self.endFrame = endFrame; self.alignment = alignment; self.confirmed = confirmed }
}
public struct VoiceTake: Codable, Equatable, Sendable {
    public var assetID: String; public var textDigest: String; public var durationFrames: Int; public var method: String; public var listened: Bool
    public init(assetID: String, textDigest: String, durationFrames: Int, method: String, listened: Bool = false) { self.assetID = assetID; self.textDigest = textDigest; self.durationFrames = durationFrames; self.method = method; self.listened = listened }
}
public struct RuleEvent: Codable, Equatable, Identifiable, Sendable {
    public var id = Codec.id(); public var tick: Int; public var delta: Int; public var label: String
    public init(tick: Int, delta: Int, label: String) { self.tick = tick; self.delta = delta; self.label = label }
}
public struct Simulation: Codable, Equatable, Sendable {
    public var seed: UInt64 = 42; public var initial: Int = 100; public var capacity: Int = 200; public var unit: String = "上下文单位"; public var events: [RuleEvent] = []
    /// Nil preserves the original scalar-event contract and its recordings.
    public var knowledge: KnowledgeSimulation?
    public init() {}
    public func state(at tick: Int) throws -> Int {
        // Input order is causal for events at the same tick (clamping is not commutative).
        // Recording, labels, SDK queries and rendered frames must use one rule implementation.
        return try SimulationReplay.record(simulation:self,throughTick:tick).finalState
    }
}
public struct Keyframe: Codable, Equatable, Identifiable, Sendable {
    public var id = Codec.id(); public var frame:Int; public var x:Double; public var y:Double; public var scale:Double
    public init(frame:Int,x:Double,y:Double,scale:Double){self.frame=frame;self.x=x;self.y=y;self.scale=scale}
}
public struct Scene: Codable, Equatable, Identifiable, Sendable {
    public var id = Codec.id(); public var kind: SceneKind; public var title: String; public var body: String; public var narration: String; public var durationFrames: Int; public var assetID: String?; public var evidenceIDs: [String] = []
    public var sourceStartFrame = 0; public var sourceEndFrame: Int?; public var speed: Double = 1; public var preservePitch = true; public var locked = false
    public var x: Double = 0.5; public var y: Double = 0.5; public var scale: Double = 1; public var voiceGain: Double = 1; public var sourceGain: Double = 0; public var musicGain: Double = 0.15; public var muted = false; public var pauseFrames = 0
    public var captions: [Caption] = []; public var voice: VoiceTake?; public var simulation: Simulation = .init(); public var character = "圆仔"; public var emotion = "好奇"; public var color = "6366F1"; public var showPrice = false
    public var keyframes: [Keyframe] = []
    public var courseMappingIDs: [String]?
    public var speechPlan: SpeechPlan?
    public var layers: [SceneLayer]?
    public var characterProfile: CharacterProfile?
    public var cartoonPerformance: CartoonPerformance?
    public var narrativeSources: [NarrativeSource]?
    public var classicArtwork: ClassicArtwork?
    public var classicArtworkRequired: Bool?
    public var fontName:String?
    public var mediaFraming:MediaFraming?
    /// Optional for old projects. The full deterministic trace is kept even when stale,
    /// so editing never mistakes a newly calculated result for an already reviewed recording.
    public var simulationRecording: RuleTrace?
    public var simulationRecordingConfirmed: Bool?
    /// Optional Host-only source window; old scenes keep their original mapping.
    public var simulationPresentation: SimulationPresentation?
    public init(kind: SceneKind = .explanation, title: String, body: String, narration: String = "", durationFrames: Int = 180) { self.kind = kind; self.title = title; self.body = body; self.narration = narration; self.durationFrames = durationFrames; self.classicArtworkRequired = true }
    public var timelineFrames: Int { max(1, Int((Double(durationFrames) / speed).rounded())) + pauseFrames }
    /// Shared by the painter and rule recording. This preserves the shipped timeline mapping,
    /// including additional pause frames, rather than assuming all source frames are displayed.
    public func renderSourceFrame(atTimelineFrame frame: Int) -> Int { Int(Double(max(0, frame)) * speed) }
    public func speechDigest() throws -> String { try SpeechRules.digest(self) }
    public func layout(at frame:Int)->(x:Double,y:Double,scale:Double){
        let keys=keyframes.sorted{$0.frame<$1.frame};guard let first=keys.first else{return(x,y,scale)};if frame<=first.frame{return(first.x,first.y,first.scale)};guard let next=keys.firstIndex(where:{$0.frame>=frame})else{let k=keys.last!;return(k.x,k.y,k.scale)};let a=keys[next-1],b=keys[next];let p=Double(frame-a.frame)/Double(b.frame-a.frame);return(a.x+(b.x-a.x)*p,a.y+(b.y-a.y)*p,a.scale+(b.scale-a.scale)*p)
    }
    public func validate(assets: [Asset]) throws {
        try LayerRules.validate(scene:self,assets:assets)
        try ClassicArtworkRules.validate(scene:self,assets:assets)
        if let framing=mediaFraming {
            try framing.validate()
            guard kind == .image || kind == .video,
                  let aid=assetID, let asset=assets.first(where:{$0.id==aid}),
                  (kind == .image && (asset.mediaType == "image" || asset.mediaType.hasPrefix("image/"))) ||
                  (kind == .video && (asset.mediaType == "video" || asset.mediaType.hasPrefix("video/"))) else {
                throw VideoError.invalid("局部取景只能绑定实际图片或录屏源素材")
            }
        }
        if let presentation=simulationPresentation {
            guard kind == .simulation else { throw VideoError.invalid("只有仿真镜头可绑定规则展示窗口") }
            try presentation.validate(durationFrames:durationFrames)
        }
        if let performance=cartoonPerformance {
            guard kind == .cartoon, let artwork=classicArtwork else { throw VideoError.invalid("多角色表演只能绑定实际角色图集的卡通镜头") }
            try performance.validate(durationFrames:durationFrames, sprites:artwork.sprites)
        }
        guard durationFrames > 0 && durationFrames <= 54000, (0.25...4).contains(speed), (0...54000).contains(pauseFrames), x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y), (0.1...4).contains(scale), (0...2).contains(voiceGain), (0...2).contains(sourceGain), (0...2).contains(musicGain) else { throw VideoError.invalid("片段时长、速度、位置或音量超出范围；单镜头停顿最多30分钟") }
        if let aid = assetID { guard let a = assets.first(where: { $0.id == aid }) else { throw VideoError.notFound("片段源素材缺失") }; if let n = a.durationFrames { guard sourceStartFrame >= 0, sourceStartFrame <= n, durationFrames <= n - sourceStartFrame else { throw VideoError.invalid("裁切超出源媒体实际时长") } } }
        for c in captions { guard c.startFrame >= 0, c.endFrame > c.startFrame, c.endFrame <= durationFrames else { throw VideoError.invalid("字幕超出片段或时长为零") } }
        guard Set(keyframes.map(\.frame)).count==keyframes.count,keyframes.allSatisfy({$0.frame>=0 && $0.frame<durationFrames && (0...1).contains($0.x) && (0...1).contains($0.y) && (0.1...4).contains($0.scale)})else{throw VideoError.invalid("关键帧超出片段或参数范围")}
        if kind == .simulation { _ = try simulation.state(at: 0) }
    }
}
public struct Review: Codable, Sendable {
    public var text = false; public var rights = false; public var fullPreview = false; public var sound = false; public var captions = false
    public var digest: String?; public var reviewer: String?; public var at: Date?
    public init() {}
    public var complete: Bool { text && rights && fullPreview && sound && captions && digest != nil }
}
public struct Comment: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var revisionID: String; public var sceneID: String?; public var frame: Int; public var element: String; public var text: String; public var author: String; public var resolved = false
    public init(revisionID: String, sceneID: String?, frame: Int, element: String, text: String, author: String) { self.revisionID = revisionID; self.sceneID = sceneID; self.frame = frame; self.element = element; self.text = text; self.author = author }
}
/// A real video project can exist without a product, price or purchase destination.
/// This context owns source references independently of optional legacy commerce facts.
public struct ContentContext: Codable, Identifiable, Equatable, Sendable {
    public var id = Codec.id()
    public var workspaceID: String
    public var name: String
    public var assetIDs: [String] = []
    public var courseMappings: [CourseMapping]?
    public init(workspaceID: String, name: String) { self.workspaceID=workspaceID;self.name=name }
    public func validate() throws {
        guard !id.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !workspaceID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw VideoError.invalid("视频工程名称和工作区不能为空")}
        guard Set(assetIDs).count==assetIDs.count else{throw VideoError.invalid("工程素材引用重复")}
    }
}
public struct Revision: Codable, Identifiable, Sendable {
    public var dependencies: DependencySnapshot?
    public var audioQuality:AudioQualityPolicy?
    public var productionBrief:ProductionBrief?
    public var id = Codec.id(); public var parentID: String?; public var number: Int; public var schemaVersion = 1; public var toolchain = "video-native-1"; public var product: Product?; public var contentContext: ContentContext?; public var purpose: Purpose; public var aspect: Aspect; public var fps = 30; public var scenes: [Scene]; public var cta: String; public var musicAssetID: String?; public var review = Review(); public var createdAt = Date(); public var change: String; public var invalidated: [String] = []
    public init(number: Int = 1, product: Product, purpose: Purpose, aspect: Aspect, scenes: [Scene], cta: String, change: String = "创建") { self.number = number; self.product = product; self.purpose = purpose; self.aspect = aspect; self.scenes = scenes; self.cta = cta; self.change = change }
    public init(number:Int = 1,contentContext:ContentContext,purpose:Purpose = .education,aspect:Aspect,scenes:[Scene],cta:String = "",change:String = "创建") {self.number=number;self.schemaVersion=2;self.contentContext=contentContext;self.purpose=purpose;self.aspect=aspect;self.scenes=scenes;self.cta=cta;self.change=change}
    public var workspaceID:String {contentContext?.workspaceID ?? product?.workspaceID ?? ""}
    public var contentName:String {contentContext?.name ?? product?.name ?? ""}
    public var courseMappings:[CourseMapping] {contentContext?.courseMappings ?? product?.courseMappings ?? []}
    public var sourceAssetIDs:[String] {contentContext?.assetIDs ?? product?.assetIDs ?? []}
    public func validateContext() throws {
        guard (product == nil) != (contentContext == nil) else{throw VideoError.invalid("工程须且仅须有独立内容上下文或既有产品事实")}
        guard (product != nil && schemaVersion==1) || (contentContext != nil && schemaVersion==2) else{throw VideoError.unavailable("工程IR版本与内容上下文不兼容，请使用支持该版本的工具")}
        if let context=contentContext {try context.validate()}
        if let product {try product.validate()}
    }
    private enum CodingKeys:String,CodingKey {case dependencies,audioQuality,productionBrief,id,parentID,number,schemaVersion,toolchain,product,contentContext,purpose,aspect,fps,scenes,cta,musicAssetID,review,createdAt,change,invalidated}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        dependencies=try c.decodeIfPresent(DependencySnapshot.self,forKey:.dependencies);audioQuality=try c.decodeIfPresent(AudioQualityPolicy.self,forKey:.audioQuality);productionBrief=try c.decodeIfPresent(ProductionBrief.self,forKey:.productionBrief)
        id=try c.decode(String.self,forKey:.id);parentID=try c.decodeIfPresent(String.self,forKey:.parentID);number=try c.decode(Int.self,forKey:.number);schemaVersion=try c.decode(Int.self,forKey:.schemaVersion);toolchain=try c.decode(String.self,forKey:.toolchain)
        product=try c.decodeIfPresent(Product.self,forKey:.product);contentContext=try c.decodeIfPresent(ContentContext.self,forKey:.contentContext);purpose=try c.decode(Purpose.self,forKey:.purpose);aspect=try c.decode(Aspect.self,forKey:.aspect);fps=try c.decode(Int.self,forKey:.fps);scenes=try c.decode([Scene].self,forKey:.scenes);cta=try c.decode(String.self,forKey:.cta);musicAssetID=try c.decodeIfPresent(String.self,forKey:.musicAssetID);review=try c.decode(Review.self,forKey:.review);createdAt=try c.decode(Date.self,forKey:.createdAt);change=try c.decode(String.self,forKey:.change);invalidated=try c.decode([String].self,forKey:.invalidated)
        try validateContext()
    }
    public var frames: Int { scenes.reduce(0) { $0 + $1.timelineFrames } }
    public func contentDigest() throws -> String { var r = self; r.review = Review(); return try Codec.digest(r) }
}
public struct Project: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var workspaceID: String; public var name: String; public var revisions: [Revision]; public var comments: [Comment] = []; public var tags: [String] = []; public var series = ""; public var batchID: String?; public var archived = false
    public init(workspaceID: String, name: String, revision: Revision) { self.workspaceID = workspaceID; self.name = name; self.revisions = [revision] }
    public var productionApprovals:[ProductionApproval]?
    public var deliveryRecords:[ProductionDeliveryRecord]?
    public var current: Revision { revisions[revisions.count - 1] }
    private enum CodingKeys:String,CodingKey {case id,workspaceID,name,revisions,comments,tags,series,batchID,archived,productionApprovals,deliveryRecords}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);workspaceID=try c.decode(String.self,forKey:.workspaceID);name=try c.decode(String.self,forKey:.name);revisions=try c.decode([Revision].self,forKey:.revisions);comments=try c.decode([Comment].self,forKey:.comments);tags=try c.decode([String].self,forKey:.tags);series=try c.decode(String.self,forKey:.series);batchID=try c.decodeIfPresent(String.self,forKey:.batchID);archived=try c.decode(Bool.self,forKey:.archived);productionApprovals=try c.decodeIfPresent([ProductionApproval].self,forKey:.productionApprovals);deliveryRecords=try c.decodeIfPresent([ProductionDeliveryRecord].self,forKey:.deliveryRecords)
        guard !workspaceID.isEmpty,!revisions.isEmpty,revisions.allSatisfy({$0.workspaceID==workspaceID}) else{throw VideoError.permission("工程版本不属于同一真实工作区")}
    }
}
public struct Topic: Codable, Identifiable, Sendable {
    public var batchID:String?
    public var id = Codec.id(); public var workspaceID: String; public var productID: String; public var audience: String; public var task: String; public var knowledge: String; public var hook: String; public var outcome: String; public var proof: String; public var grammar: String; public var cta: String; public var channel: String; public var evidenceIDs: [String]; public var series: String; public var budget: Money
    public init(workspaceID: String, productID: String, audience: String, task: String, knowledge: String, hook: String, outcome: String, proof: String, grammar: String, cta: String, channel: String, evidenceIDs: [String], series: String, budget: Money) { self.workspaceID = workspaceID; self.productID = productID; self.audience = audience; self.task = task; self.knowledge = knowledge; self.hook = hook; self.outcome = outcome; self.proof = proof; self.grammar = grammar; self.cta = cta; self.channel = channel; self.evidenceIDs = evidenceIDs; self.series = series; self.budget = budget }
}
