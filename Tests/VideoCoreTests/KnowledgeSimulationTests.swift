import XCTest
@testable import VideoCore

final class KnowledgeSimulationTests: XCTestCase {
    private func model(rounds: Int = 1) -> KnowledgeSimulation {
        KnowledgeSimulation(knowledgeLabel: "公共品为何会出现搭便车", resourceLabel: "精力",
                            participants: [KnowledgeParticipant(id: "a", name: "小恐龙甲", strategy: .contribute),
                                           KnowledgeParticipant(id: "b", name: "小恐龙乙", strategy: .freeRide)], rounds: rounds)
    }
    private func full(_ model: KnowledgeSimulation, seed: UInt64 = 42) throws -> KnowledgeTrace {
        try KnowledgeSimulationEngine.record(model: model, seed: seed, throughTick: model.lastSettlementTick())
    }

    func testContributionCausesSharedPassageButContributorPaysRealCost() throws {
        let trace = try full(model())
        XCTAssertEqual(trace.events.map(\.phase), KnowledgePhase.allCases)
        let decision = trace.events[1], paid = trace.events[2], resolved = trace.events[3], passage = trace.events[4]
        XCTAssertEqual(decision.actors.map(\.resources), [3, 3], "同时选择时尚未扣费")
        XCTAssertEqual(decision.actors.map(\.choice), [.contribute, .wait])
        XCTAssertEqual(paid.actors.map(\.resources), [2, 3]); XCTAssertEqual(paid.totalContribution, 1)
        XCTAssertFalse(paid.obstacleCleared); XCTAssertTrue(resolved.obstacleCleared)
        XCTAssertFalse(resolved.actors.contains(where: \.passed), "清障判定不能提前伪造已通行")
        XCTAssertFalse(passage.actors.contains(where: \.passed)); XCTAssertEqual(passage.actors.map(\.resources), [2, 3])
        XCTAssertEqual(trace.finalResources.map(\.resources), [5, 6], "收益来自同一轮的实际清障，搭便车者仍获得公共利益")
        XCTAssertEqual(trace.rounds.count, 1); XCTAssertEqual(trace.rounds[0].actors.map(\.cost), [1, 0])
    }

    func testNobodyContributesMeansObstacleStaysAndNoOneReceivesBenefit() throws {
        var input = model(); input.participants[0].strategy = .freeRide
        let trace = try full(input)
        XCTAssertEqual(trace.finalResources.map(\.resources), [3, 3])
        XCTAssertFalse(try XCTUnwrap(trace.rounds.first).obstacleCleared)
        XCTAssertTrue(trace.rounds[0].actors.allSatisfy { !$0.passed && $0.cost == 0 && $0.benefit == 0 })
    }

    func testThresholdCounterfactualChangesActualObstaclePassageAndBalances() throws {
        let input = model(); var alternative = input; alternative.threshold = 2
        let result = try KnowledgeSimulationEngine.compare(baseline: input, alternative: alternative, seed: 42)
        XCTAssertEqual(result.baseline.finalResources.map(\.resources), [5, 6])
        XCTAssertEqual(result.alternative.finalResources.map(\.resources), [2, 3])
        XCTAssertTrue(result.baseline.rounds[0].actors.allSatisfy(\.passed))
        XCTAssertFalse(result.alternative.rounds[0].actors.contains(where: \.passed))
        XCTAssertEqual(result.balances.map(\.difference), [-3, -3]); XCTAssertEqual(result.clearedRoundDifference, -1)
        XCTAssertNotEqual(result.baseline.inputDigest, result.alternative.inputDigest)
    }

    func testReciprocityOnlyReadsPreviousCompletedRoundAndNotCurrentOtherChoice() throws {
        var input = model(rounds: 2)
        input.participants[0].strategy = .freeRide; input.participants[1].strategy = .reciprocate
        let trace = try full(input)
        XCTAssertEqual(trace.rounds[0].actors.map(\.contribution), [0, 1], "首轮互惠策略显式从出力开始")
        XCTAssertEqual(trace.rounds[1].actors.map(\.contribution), [0, 0], "次轮只观察到此前他人未出力")
        var reordered = input; reordered.participants.reverse()
        let reversed = try full(reordered)
        XCTAssertEqual(trace.events, reversed.events, "输入数组顺序不能改变同时决策或暗中让一方先行动")
        XCTAssertEqual(trace.finalResources, reversed.finalResources)
    }

    func testSeededRotationChangesContributorWhilePreservingSharedRule() throws {
        var input = model(rounds: 2)
        for index in input.participants.indices { input.participants[index].strategy = .rotate }
        let a = try full(input, seed: 0), b = try full(input, seed: 1)
        XCTAssertEqual(a.rounds[0].actors.map(\.contribution), [1, 0])
        XCTAssertEqual(a.rounds[1].actors.map(\.contribution), [0, 1])
        XCTAssertEqual(b.rounds[0].actors.map(\.contribution), [0, 1])
        XCTAssertEqual(a.finalResources.map(\.resources), [8, 8])
        XCTAssertEqual(a.finalResources, b.finalResources)
        XCTAssertEqual(a, try full(input, seed: 0))
    }

    func testResourceConstraintPreventsSpendingOrContributingWhatActorDoesNotHave() throws {
        var input = model(); input.contributionCost = 2; input.participants[0].initialResources = 1
        let trace = try full(input)
        XCTAssertEqual(trace.events[1].actors[0].choice, .constrained)
        XCTAssertEqual(trace.rounds[0].totalContribution, 0)
        XCTAssertEqual(trace.rounds[0].actors[0].cost, 0)
        XCTAssertEqual(trace.finalResources.map(\.resources), [1, 3])
    }

    func testPartialRecordingDoesNotPublishFutureCostsPassageOrSettlement() throws {
        let input = model()
        let choice = try KnowledgeSimulationEngine.record(model: input, seed: 42, throughTick: 1)
        XCTAssertEqual(choice.events.count, 2); XCTAssertTrue(choice.rounds.isEmpty)
        XCTAssertEqual(choice.finalResources.map(\.resources), [3, 3])
        let moving = try KnowledgeSimulationEngine.record(model: input, seed: 42, throughTick: 4)
        XCTAssertTrue(moving.rounds.isEmpty); XCTAssertEqual(moving.finalResources.map(\.resources), [2, 3])
        XCTAssertTrue(try XCTUnwrap(moving.events.last).obstacleCleared)
        XCTAssertFalse(try XCTUnwrap(moving.events.last).actors.contains(where: \.passed))
        XCTAssertEqual(try full(input).finalResources.map(\.resources), [5, 6])
    }

    func testFrameStateUsesOnlyVisibleEventsAndActualPhaseProgress() throws {
        var input = model(); input.startTick = 2
        let before = try KnowledgeSimulationEngine.frameState(model: input, seed: 42, frame: 59)
        XCTAssertNil(before.phase); XCTAssertEqual(before.actors.map(\.resources), [3, 3])
        let atCost = try KnowledgeSimulationEngine.frameState(model: input, seed: 42, frame: 120)
        XCTAssertEqual(atCost.phase, .contribution); XCTAssertEqual(atCost.actors.map(\.resources), [2, 3])
        let movement = try KnowledgeSimulationEngine.frameState(model: input, seed: 42, frame: 195)
        XCTAssertEqual(movement.phase, .passage); XCTAssertEqual(movement.phaseProgress, 0.5, accuracy: 0.0001)
        XCTAssertTrue(movement.obstacleCleared)
        let settled = try KnowledgeSimulationEngine.frameState(model: input, seed: 42, frame: 210)
        XCTAssertEqual(settled.phase, .settlement); XCTAssertEqual(settled.actors.map(\.resources), [5, 6])
    }

    func testRecordingVerifiesExactInputsAndRejectsTamperedOrRelabeledResults() throws {
        let input = model(), trace = try full(model())
        XCTAssertNoThrow(try KnowledgeSimulationEngine.verify(trace, model: input, seed: 42))
        var changed = input; changed.knowledgeLabel = "已修改知识解释"
        XCTAssertThrowsError(try KnowledgeSimulationEngine.verify(trace, model: changed, seed: 42))
        XCTAssertThrowsError(try KnowledgeSimulationEngine.verify(trace, model: input, seed: 43))
        var tampered = trace; tampered.events[2].actors[0].resources = 100
        XCTAssertThrowsError(try KnowledgeSimulationEngine.verify(tampered, model: input, seed: 42))
        let reopened = try Codec.decoder().decode(KnowledgeTrace.self, from: Codec.data(trace))
        XCTAssertEqual(reopened, trace)
        XCTAssertEqual(try Codec.data(try full(input)), try Codec.data(trace))
    }

    func testMalformedAndUnboundedInputsFailWithoutOverflowOrPartialResult() throws {
        for change in 0..<12 {
            var input = model()
            switch change {
            case 0: input.version = 2
            case 1: input.rounds = Int.max
            case 2: input.roundTicks = Int.max
            case 3: input.startTick = Int.max
            case 4: input.benefit = Int.max
            case 5: input.contributionCost = -1
            case 6: input.threshold = 0
            case 7: input.participants[1].id = input.participants[0].id
            case 8: input.participants[0].initialResources = Int.max
            case 9: input.participants[0].initialResources = 1_000_000
            case 10: input.knowledgeLabel = "注入\n控制字符"
            default: input.rounds = 64; input.roundTicks = 30
            }
            XCTAssertThrowsError(try full(input), "拒绝越界输入 \(change)")
        }
        XCTAssertThrowsError(try KnowledgeSimulationEngine.record(model: model(), seed: 42, throughTick: -1))
        XCTAssertThrowsError(try KnowledgeSimulationEngine.frameState(model: model(), seed: 42, frame: Int.max, fps: 1))
    }

    func testCounterfactualCannotCompareDifferentPeopleOrDifferentRoundCounts() throws {
        let input = model(); var changed = input; changed.participants[1].id = "third"
        XCTAssertThrowsError(try KnowledgeSimulationEngine.compare(baseline: input, alternative: changed, seed: 42))
        changed = input; changed.rounds = 2
        XCTAssertThrowsError(try KnowledgeSimulationEngine.compare(baseline: input, alternative: changed, seed: 42))
    }

    func testNormalSceneRevisionRecordingAndEditsPreserveHistoryButInvalidateCausalAudio() throws {
        var scene = Scene(kind: .simulation, title: "公共品与搭便车", body: "共享收益不代表共享成本", durationFrames: 180)
        scene.simulation.knowledge = model()
        scene.captions = [Caption(text: "需要重新核对的结论", startFrame: 0, endFrame: 100, confirmed: true)]
        scene.voice = VoiceTake(assetID: "old-voice", textDigest: "previous", durationFrames: 100, method: "原录音", listened: true)
        let revision = Revision(contentContext: ContentContext(workspaceID: "knowledge", name: "普通知识工程"), aspect: .landscape, scenes: [scene])
        let original = Project(workspaceID: "knowledge", name: "知识工程", revision: revision)
        let recorded = try Editor.apply([.recordSimulation(scene.id), .confirmSimulationRecording(scene.id)], to: original, baseRevision: revision.id, assets: [], message: "运行并人工复核规则")
        let saved = recorded.current.scenes[0], trace = try XCTUnwrap(saved.simulationRecording)
        XCTAssertEqual(trace.ruleVersion, 2); XCTAssertEqual(trace.knowledgeTrace?.rounds.count, 1)
        XCTAssertEqual(trace.unit, "精力"); XCTAssertEqual(trace.finalState, 11)
        let visible = try SimulationReplay.frameState(simulation: saved.simulation, frame: 150)
        XCTAssertEqual(visible.unit, trace.unit); XCTAssertEqual(visible.capacity, trace.capacity); XCTAssertTrue(visible.particles.isEmpty)
        XCTAssertFalse(recorded.current.review.complete, "规则复核不能代替实际成片和声音审核")
        let reopened = try Codec.decoder().decode(Project.self, from: Codec.data(recorded))
        XCTAssertNoThrow(try SimulationReplay.verify(scene: reopened.current.scenes[0]))
        var changed = saved; changed.simulation.knowledge?.threshold = 2
        let edited = try Editor.apply([.replaceScene(saved.id, changed)], to: reopened, baseRevision: reopened.current.id, assets: [], message: "改变共享清障门槛")
        XCTAssertEqual(edited.current.scenes[0].simulationRecording, trace)
        XCTAssertEqual(edited.current.scenes[0].simulationRecordingConfirmed, false)
        XCTAssertNil(edited.current.scenes[0].voice); XCTAssertFalse(edited.current.scenes[0].captions[0].confirmed)
        XCTAssertThrowsError(try SimulationReplay.verify(scene: edited.current.scenes[0]))
        XCTAssertNoThrow(try SimulationReplay.verify(scene: edited.revisions[1].scenes[0]), "旧版本的真实输入与录制继续可查")
        XCTAssertNotEqual(try edited.current.contentDigest(), try recorded.current.contentDigest())
    }

    func testFullSceneRecordingCannotHideFinalSettlementAndLegacyScalarBytesStayCompatible() throws {
        var scene = Scene(kind: .simulation, title: "完整规则", body: "必须看到收益结算", durationFrames: 150)
        scene.simulation.knowledge = model()
        XCTAssertThrowsError(try SimulationReplay.record(scene: scene), "最后结算发生在第5秒，150帧尚未显示该刻度")
        scene.durationFrames = 151
        XCTAssertEqual(try SimulationReplay.record(scene: scene).knowledgeTrace?.rounds.count, 1)
        var legacy = Simulation(); legacy.initial = 3; legacy.capacity = 8; legacy.events = [RuleEvent(tick: 1, delta: 2, label: "原数值事件")]
        let data = try Codec.data(legacy), object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["knowledge"])
        let trace = try SimulationReplay.record(simulation: legacy, throughTick: 2)
        XCTAssertEqual(trace.ruleVersion, 1); XCTAssertNil(trace.knowledgeTrace); XCTAssertEqual(trace.finalState, 5)
        XCTAssertNoThrow(try SimulationReplay.verify(recording: trace, simulation: legacy))
        scene.simulation.events = legacy.events
        XCTAssertThrowsError(try SimulationReplay.record(scene: scene), "不能悄悄忽略与知识模型混用的旧增减事件")
    }

    func testProtocolNegotiationRejectsOldModuleForKnowledgeWithoutChangingLegacyAccess() throws {
        var simulation = Simulation(); simulation.knowledge = model()
        XCTAssertThrowsError(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.game", inputSchema: 1))
        XCTAssertNoThrow(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.game", inputSchema: 2))
        XCTAssertThrowsError(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.cartoon", inputSchema: 2))
        XCTAssertNoThrow(try PluginInputCompatibility.requireKnowledgeSupport(Simulation(), pluginID: "video.game", inputSchema: 1))
        let old = PluginRPCSchemas.definitions(inputSchemaVersion: 1), new = PluginRPCSchemas.definitions(inputSchemaVersion: 2)
        XCTAssertNil(old["Simulation"]?.object?["properties"]?.object?["knowledge"])
        XCTAssertNotNil(new["Simulation"]?.object?["properties"]?.object?["knowledge"])
        var scene = Scene(kind: .simulation, title: "private-source-title", body: "private-source-body", narration: "private-narration")
        scene.simulation = simulation; scene.evidenceIDs = ["private-proof"]
        let text = String(decoding: try Codec.data(PluginVisualProps(scene: scene)), as: UTF8.self)
        for marker in ["private-source-title", "private-source-body", "private-narration", "private-proof"] { XCTAssertFalse(text.contains(marker)) }
        XCTAssertEqual(PluginVisualProps(scene: scene).drawingScene().simulation.knowledge, model())
        let roles = ClassicArtworkRules.requiredRoles(knowledge: true, cartoon: false)
        XCTAssertFalse(roles.contains("crate")); XCTAssertFalse(roles.contains("wall")); XCTAssertTrue(roles.contains("obstacle"))
        XCTAssertTrue(ClassicArtworkRules.requiredRoles(knowledge: false, cartoon: false).isSuperset(of: ["crate", "wall"]))
    }
}
