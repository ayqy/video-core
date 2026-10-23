import XCTest
@testable import VideoCore

final class NarrativeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func product() -> Product {
        Product(workspaceID: "w", sku: "course", name: "写作课", checkout: "https://example.org/course", audience: "需要整理读书笔记的学习者", task: "把长文整理成三条笔记", outcome: "完成一份结构清楚的笔记", prerequisite: "能阅读中文", scope: "材料整理方法", prices: [Price(money: Money(99), from: .distantPast, source: "测试中独立的合成凭证", verified: true)])
    }
    private func fixture(_ grammar: NarrativeGrammar = .misconception) -> (NarrativeInput, Product, [Asset], [Evidence], NarrativeTemplate, StyleKit) {
        let p = product(); var asset = Asset(workspaceID: "w", name: "课程讲稿", hash: "source", ext: "txt", bytes: 20, mediaType: "text")
        var page = CoursePage(number: 1, text: "先提出一个问题，再用材料回答。"); page.confirmed = true; asset.pages = [page]
        var evidence = Evidence(workspaceID: "w", title: "合成规则验收凭证", source: "isolated-test", claim: "测试材料说明", owner: "test", commercialAllowed: true, verified: true); evidence.checkedAt=now.addingTimeInterval(-60)
        let topic = Topic(workspaceID: "w", productID: p.id, audience: p.audience, task: p.task, knowledge: "先提出一个问题，再用材料回答。", hook: "为什么笔记越长越难用？", outcome: "写下一条有材料依据的结论", proof: "打开讲稿第一页，标出问题和原文依据。", grammar: grammar.rawValue, cta: "打开讲稿亲手练习一次", channel: "测试渠道", evidenceIDs: [evidence.id], series: "", budget: Money(0))
        let source = NarrativeSource(assetID: asset.id, pages: [1], excerpt: page.text, confirmed: true)
        var input = NarrativeInput(topic: topic, targetLearner: p.audience, casualViewer: "只看趣味桥段的围观者", promiseScope: "学会一次材料标注", boundary: "不承诺成绩提升；类比不替代真实测量", grammar: grammar, sources: [source], purpose: .education, aspect: .portrait)
        input.startingPoint = "未经核对的长段摘抄"; input.response = "每条结论应能回到原文依据"; input.result = "本例留下三条带来源的笔记"; input.analogy = "像给抽屉加标签，但人的记忆并非抽屉"; input.counterargument = "摘抄越多是否越可靠？"; input.steps = ["打开原文", "提出问题", "标注依据"]; input.comparedProduct = "另一种整理方法"; input.comparisonBasis = "同一篇原文和同一问题"; input.costItems = [NarrativeCostItem(label: "材料费", money: Money(2), evidenceID: evidence.id)]; input.simulation = Simulation()
        let template = NarrativeTemplate(workspaceID: "w", name: "测试节拍", beats: [TemplateBeat(role: .knowledge, frames: 300, kind: .cartoon, motion: true)])
        let style = StyleKit(workspaceID: "w", name: "原创几何", characters: [CharacterProfile(name: "圆仔", color: "AABBCC"), CharacterProfile(name: "方仔", silhouette: .square)])
        return (input, p, [asset], [evidence], template, style)
    }
    private func compose(_ grammar: NarrativeGrammar = .misconception) throws -> NarrativeDocument {
        let (input, p, assets, evidence, template, style) = fixture(grammar)
        let series = grammar == .series ? SeriesProfile(workspaceID: "w", name: "材料小课", style: style, template: template, episodePrefix: "材料小课", recurringQuestion: "如何回到材料？") : nil
        return try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: style, series: series, now: now)
    }
    func testAllGrammarsUseActualInputsAndHaveKnowledgeProofBoundaryAndSingleAction() throws {
        for grammar in NarrativeGrammar.allCases {
            let document = try compose(grammar)
            XCTAssertTrue(document.beats.contains { $0.role == .knowledge && $0.text == document.input.topic.knowledge })
            XCTAssertTrue(document.beats.contains { $0.role == .demonstration && $0.text == document.input.topic.proof })
            XCTAssertTrue(document.beats.contains { $0.role == .boundary && $0.text.contains(document.input.boundary) })
            XCTAssertEqual(document.beats.filter { $0.role == .action }.count, 1)
            XCTAssertEqual(document.revision.cta, document.input.topic.cta)
            XCTAssertFalse(document.confirmed)
            XCTAssertEqual(Set(document.beats.flatMap(\.sourceIDs)), Set(document.input.sources.map(\.id)))
        }
        let practice = try compose(.practice); XCTAssertEqual(practice.beats.filter { $0.role == .demonstration }.count, 4)
        let debate = try compose(.debate); XCTAssertTrue(debate.revision.scenes.contains { $0.kind == .cartoon && $0.body == debate.input.counterargument })
        let costs = try compose(.costs); XCTAssertTrue(costs.revision.scenes.contains { $0.title == "同币种项目合计" && $0.body == Money(2).display })
    }
    func testTemplateParametersChangeActualSceneAndStyleIsInherited() throws {
        let document = try compose(); let beat = try XCTUnwrap(document.beats.first { $0.role == .knowledge }); let scene = try XCTUnwrap(document.revision.scenes.first { $0.id == beat.sceneID })
        XCTAssertEqual(scene.durationFrames, 300); XCTAssertEqual(scene.kind, .cartoon); XCTAssertEqual(scene.keyframes.count, 2); XCTAssertNotEqual(scene.layout(at: 0).x, scene.layout(at: 299).x)
        XCTAssertTrue(document.style.characters.contains { $0.name == scene.character && $0.color == scene.color })
    }
    func testUnconfirmedSourceAndWrongWorkspaceAreRejected() throws {
        var (input, p, assets, evidence, template, style) = fixture(); input.sources[0].confirmed = false
        XCTAssertThrowsError(try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: style, now: now))
        input.sources[0].confirmed = true; assets[0].workspaceID = "other"
        XCTAssertThrowsError(try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: style, now: now))
    }
    func testComparisonCannotSubstituteGeneratedResultForMissingProof() throws {
        var (input, p, assets, evidence, template, style) = fixture(.beforeAfter); input.topic.evidenceIDs = []
        XCTAssertThrowsError(try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: style, now: now))
    }
    func testSingleActionRejectsMultipleLinksAndActions() throws {
        var (input, p, assets, evidence, template, style) = fixture(); input.topic.cta = "买课 https://example.org/course；加入群聊 https://example.org/group"
        XCTAssertThrowsError(try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: style, now: now))
    }
    func testUnlicensedCharacterAndExpiredStyleEvidenceAreRejected() throws {
        var (input, p, assets, evidence, template, style) = fixture(.debate); style.characters[0].original = false
        XCTAssertThrowsError(try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: style, now: now))
        style.characters[0].evidenceIDs = [evidence[0].id]; evidence[0].expiresAt = now.addingTimeInterval(-1)
        XCTAssertThrowsError(try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: style, now: now))
    }
    func testManualRewritePreservesBeforeAfterAndInvalidatesConfirmationAndVoice() throws {
        let (input, p, assets, evidence, template, style) = fixture(); var document = try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: style, now: now)
        let sceneID = document.revision.scenes[1].id; let original = document.revision.scenes[1].body
        document.revision.scenes[1].voice = VoiceTake(assetID: "voice", textDigest: try document.revision.scenes[1].speechDigest(), durationFrames: 30, method: "import", listened: true)
        try document.confirm(reviewer: "作者", now: now); XCTAssertTrue(document.confirmed)
        try document.rewrite(sceneID: sceneID, text: "先写问题，再核对原文依据。", author: "作者", reason: "减少歧义", assets: assets, now: now)
        XCTAssertFalse(document.confirmed); XCTAssertEqual(document.rewrites.first?.before, original); XCTAssertEqual(document.rewrites.first?.after, "先写问题，再核对原文依据。"); XCTAssertNil(document.revision.scenes[1].voice)
    }
    func testSeriesDoesNotSilentlyAdoptDifferentStyleVersion() throws {
        let (input, p, assets, evidence, template, style) = fixture(.series); let series = SeriesProfile(workspaceID: "w", name: "栏目", style: style, template: template, episodePrefix: "栏目", recurringQuestion: "如何整理材料？")
        var next = style; next.version += 1
        XCTAssertThrowsError(try NarrativePlanner.compose(input: input, product: p, assets: assets, evidence: evidence, template: template, style: next, series: series, now: now))
    }
    func testTemplateMigrationPreservesParametersAndRejectsUnknownSchema() throws {
        var template = NarrativeTemplate(workspaceID: "w", name: "旧模板", beats: [TemplateBeat(role: .knowledge, frames: 120, motion: true)]); template.version = 1
        let next = try template.migrated(); XCTAssertEqual(next.version, 2); XCTAssertEqual(next.parentVersion, 1); XCTAssertEqual(next.beats, template.beats); XCTAssertFalse(next.migrationNotes.isEmpty)
        template.version = 3; XCTAssertThrowsError(try template.migrated())
    }
    func testReplayIsDeterministicAndCausalAtSameTick() throws {
        var simulation = Simulation(); simulation.initial = 5; simulation.capacity = 10; simulation.events = [RuleEvent(tick: 1, delta: 20, label: "加入"), RuleEvent(tick: 1, delta: -3, label: "移除")]
        let trace = try SimulationReplay.record(simulation: simulation, throughTick: 2); XCTAssertEqual(trace, try SimulationReplay.record(simulation: simulation, throughTick: 2)); XCTAssertEqual(trace.finalState, 7); XCTAssertEqual(trace.transitions.map(\.before), [5, 10]); XCTAssertEqual(trace.transitions.map(\.appliedDelta), [5, -3]); XCTAssertEqual(trace.transitions.first?.clippedDelta, 15)
        try SimulationReplay.verify(recording: trace, simulation: simulation)
        simulation.capacity = 20; XCTAssertThrowsError(try SimulationReplay.verify(recording: trace, simulation: simulation))
    }
    func testSeedChangesOnlyDeterministicVisualLayoutAndInvalidatesRecording() throws {
        var simulation = Simulation(); simulation.initial = 4; let before = try SimulationReplay.frameState(simulation: simulation, frame: 0); let trace = try SimulationReplay.record(simulation: simulation, throughTick: 0)
        XCTAssertEqual(before, try SimulationReplay.frameState(simulation: simulation, frame: 0)); simulation.seed += 1; let after = try SimulationReplay.frameState(simulation: simulation, frame: 0); XCTAssertEqual(before.value, after.value); XCTAssertNotEqual(before.particles, after.particles)
        XCTAssertThrowsError(try SimulationReplay.verify(recording: trace, simulation: simulation))
    }
    func testInvalidAndTamperedRecordingsAreRejectedWithoutOverflow() throws {
        var simulation = Simulation(); simulation.events = [RuleEvent(tick: 0, delta: Int.min, label: "非法输入")]
        XCTAssertThrowsError(try SimulationReplay.record(simulation: simulation, throughTick: 0)); simulation.events = []; var trace = try SimulationReplay.record(simulation: simulation, throughTick: 0); trace.finalState = 0
        XCTAssertThrowsError(try SimulationReplay.verify(recording: trace, simulation: simulation))
        XCTAssertThrowsError(try SimulationReplay.frameState(simulation: simulation, frame: -1))
    }
}

final class FontRightsTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_780_000_000)
    private let font="ExampleLicensedFont-Regular"
    private func rights()->Evidence {var evidence=Evidence(workspaceID:"w",title:"字体使用授权",source:"font-license-record",claim:"允许使用字体 "+font,owner:"rights-holder",commercialAllowed:true,verified:true);evidence.checkedAt=now.addingTimeInterval(-60);return evidence}
    private func revision()->Revision {let product=Product(workspaceID:"w",sku:"font-course",name:"示例课程",checkout:"https://example.org/course",audience:"学习者",task:"理解",outcome:"复现",prerequisite:"无",scope:"一个例子",prices:[Price(money:Money(1),from:Date(timeIntervalSince1970:0),source:"合成核验",verified:true)]);return Revision(product:product,purpose:.course,aspect:.portrait,scenes:[Scene(title:"标题",body:"有实际依据的说明")],cta:"查看课程",change:"字体检查")}
    func testStableSystemFontsDoNotRequireInventedSeparateLicense()throws {
        for name in ["PingFangSC-Regular","PingFangSC-Medium"] {for commercial in [false,true] {try FontRightsRules.validate(fontName:name,workspaceID:"w",evidenceIDs:[],evidence:[],commercial:commercial,now:now);try StyleKit(workspaceID:"w",name:"系统样式",fontName:name).validate(assets:[],evidence:[],commercial:commercial,now:now)}}
    }
    func testCustomFontRequiresSelectedMatchingCurrentRightsInSameWorkspace()throws {
        let original=rights()
        XCTAssertThrowsError(try FontRightsRules.validate(fontName:font,workspaceID:"w",evidenceIDs:[],evidence:[original],commercial:true,now:now))
        for mutation in 0..<6 {var evidence=original;switch mutation {case 0:evidence.claim="另一项材料授权";case 1:evidence.workspaceID="other-client";case 2:evidence.expiresAt=now.addingTimeInterval(-1);case 3:evidence.verified=false;case 4:evidence.commercialAllowed=false;default:evidence.checkedAt=now.addingTimeInterval(500)}
            XCTAssertThrowsError(try FontRightsRules.validate(fontName:font,workspaceID:"w",evidenceIDs:[evidence.id],evidence:[evidence],commercial:true,now:now))
            XCTAssertThrowsError(try StyleKit(workspaceID:"w",name:"字体样式",fontName:font,evidenceIDs:[evidence.id]).validate(assets:[],evidence:[evidence],commercial:true,now:now))
        }
    }
    func testActualFontRightsAllowStyleAndQualityWithoutClaimingInstallation()throws {
        let evidence=rights();try StyleKit(workspaceID:"w",name:"已核授权",fontName:font,evidenceIDs:[evidence.id]).validate(assets:[],evidence:[evidence],commercial:true,now:now)
        var revision=revision();revision.scenes[0].fontName=font;revision.scenes[0].evidenceIDs=[evidence.id];var database=Database();database.evidence=[evidence];database.products=[revision.product!]
        XCTAssertFalse(try Quality.inspect(revision,database:database,requireReview:false,now:now).contains{$0.id.hasSuffix("font_rights")})
    }
    func testDirectSceneFontCannotBypassStyleRightsAndNilUsesStableMedium()throws {
        var revision=revision();var database=Database();let evidence=rights();database.evidence=[evidence];database.products=[revision.product!]
        XCTAssertFalse(try Quality.inspect(revision,database:database,requireReview:false,now:now).contains{$0.id.hasSuffix("font_rights")})
        revision.scenes[0].fontName=font
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false,now:now).contains{$0.id==revision.scenes[0].id+"font_rights"})
        revision.scenes[0].evidenceIDs=[evidence.id];database.evidence[0].claim="不相关材料授权"
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false,now:now).contains{$0.id==revision.scenes[0].id+"font_rights"})
    }
    func testDerivingStylePreservesOldVersionAndUnchangedMusicAndConstraints()throws {
        var old=StyleKit(workspaceID:"w",name:"原栏目",musicAssetID:"music",evidenceIDs:["old-font"],characters:[CharacterProfile(name:"原角色")]);old.version=5
        let before=try Codec.data(old);let character=CharacterProfile(name:"原有角色",expressions:["思考","开心"],actions:["点头","讲解"])
        let next=try old.derived(name:"新版栏目",palette:["AABBCC","112233"],fontName:font,fontEvidenceIDs:["new-font"],characters:[character])
        XCTAssertEqual(try Codec.data(old),before);XCTAssertNotEqual(next.id,old.id);XCTAssertEqual(next.version,6);XCTAssertEqual(next.workspaceID,old.workspaceID);XCTAssertEqual(next.musicAssetID,old.musicAssetID);XCTAssertEqual(next.negativeConstraints,old.negativeConstraints)
        XCTAssertEqual(next.name,"新版栏目");XCTAssertEqual(next.palette,["AABBCC","112233"]);XCTAssertEqual(next.fontName,font);XCTAssertEqual(next.evidenceIDs,["new-font"]);XCTAssertEqual(next.characters,[character]);XCTAssertEqual(next.characters[0].actions,["点头","讲解"])
    }
    func testDerivationRejectsVersionOverflowAndBlankOrderedCharacterEntries()throws {
        var old=StyleKit(workspaceID:"w",name:"原栏目");old.version=Int.max
        XCTAssertThrowsError(try old.derived(name:"新栏目",palette:["AABBCC"],fontName:"PingFangSC-Medium",fontEvidenceIDs:[],characters:[]))
        old.version=1;let character=CharacterProfile(name:"角色",expressions:["好奇"],actions:[" "])
        XCTAssertThrowsError(try old.derived(name:"新栏目",palette:["AABBCC"],fontName:"PingFangSC-Medium",fontEvidenceIDs:[],characters:[character]))
        XCTAssertThrowsError(try StyleKit(workspaceID:"w",name:"无效角色",characters:[character]).validate(assets:[],evidence:[],commercial:false,now:now))
    }
}
