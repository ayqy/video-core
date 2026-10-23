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
    private func matrix(rounds: Int = 1, row: KnowledgeMatrixStrategy = .alwaysFirst,
                        column: KnowledgeMatrixStrategy = .alwaysFirst) -> KnowledgeSimulation {
        KnowledgeSimulation(knowledgeLabel: "双人可编辑博弈", resourceLabel: "筹码", participants: [
            KnowledgeParticipant(id: "a", name: "甲", strategy: .contribute, initialResources: 20, matrixStrategy: row),
            KnowledgeParticipant(id: "b", name: "乙", strategy: .contribute, initialResources: 20, matrixStrategy: column)
        ], rounds: rounds, payoffMatrix: .prisonersDilemma())
    }

    func testMatrixAllFourChoicesPayExactlyConfiguredAllocationsFromFundedPool() throws {
        let cases: [(KnowledgeMatrixStrategy, KnowledgeMatrixStrategy, [Int])] = [
            (.alwaysFirst, .alwaysFirst, [5, 5]), (.alwaysFirst, .alwaysSecond, [0, 7]),
            (.alwaysSecond, .alwaysFirst, [7, 0]), (.alwaysSecond, .alwaysSecond, [3, 3])
        ]
        for (row, column, expected) in cases {
            let trace = try full(matrix(row: row, column: column)), round = try XCTUnwrap(trace.rounds.first)
            XCTAssertEqual(trace.version, 2); XCTAssertEqual(round.actors.map(\.benefit), expected)
            XCTAssertEqual(round.actors.map(\.cost), [2, 2])
            XCTAssertEqual(round.actors.map(\.resources), expected.map { 18 + $0 })
            let pool = try XCTUnwrap(round.matrixPool)
            XCTAssertEqual(pool.available, 10); XCTAssertEqual(pool.distributed, expected.reduce(0, +))
            XCTAssertEqual(pool.remainder, 10 - expected.reduce(0, +))
            XCTAssertEqual(round.actors.reduce(0) { $0 + $1.resources } + pool.remainder, 40 + 6)
            XCTAssertFalse(round.obstacleCleared); XCTAssertTrue(round.actors.allSatisfy { !$0.passed && $0.contribution == 0 })
        }
    }

    func testEditableMatrixChangesCoordinationIncentivesAndAllocationsNotOnlyLabels() throws {
        var input = matrix(row: .alwaysFirst, column: .alwaysSecond)
        input.payoffMatrix = KnowledgePayoffMatrix(firstActionLabel: "靠左", secondActionLabel: "靠右", stake: 1, externalBudget: 8, cells: [
            KnowledgePayoffCell(rowAction: .first, columnAction: .first, rowPayout: 5, columnPayout: 5),
            KnowledgePayoffCell(rowAction: .first, columnAction: .second, rowPayout: 0, columnPayout: 0),
            KnowledgePayoffCell(rowAction: .second, columnAction: .first, rowPayout: 0, columnPayout: 0),
            KnowledgePayoffCell(rowAction: .second, columnAction: .second, rowPayout: 5, columnPayout: 5)
        ])
        let uncoordinated = try full(input)
        XCTAssertEqual(uncoordinated.finalResources.map(\.resources), [19, 19])
        XCTAssertEqual(uncoordinated.rounds[0].matrixPool?.remainder, 10)
        var coordinated = input; coordinated.participants[1].matrixStrategy = .alwaysFirst
        let compare = try KnowledgeSimulationEngine.compare(baseline: input, alternative: coordinated, seed: 42)
        XCTAssertEqual(compare.alternative.finalResources.map(\.resources), [24, 24])
        XCTAssertEqual(compare.balances.map(\.difference), [5, 5])
        var changedPayoffs = input
        changedPayoffs.payoffMatrix?.cells[1].rowPayout = 1
        changedPayoffs.payoffMatrix?.cells[1].columnPayout = 2
        let changed = try full(changedPayoffs)
        XCTAssertEqual(changed.finalResources.map(\.resources), [20, 21])
        XCTAssertNotEqual(changed.inputDigest, uncoordinated.inputDigest)
        changedPayoffs.payoffMatrix?.cells.reverse()
        XCTAssertEqual(try full(changedPayoffs).events, changed.events, "行/列行动标识决定收益，数组重排不能暗改格含义")
    }

    func testMatrixStrategyCounterfactualActuallyChangesPayoffForSameIdentitiesAndSeed() throws {
        let input = matrix(); var alternative = input; alternative.participants[1].matrixStrategy = .alwaysSecond
        let result = try KnowledgeSimulationEngine.compare(baseline: input, alternative: alternative, seed: 13)
        XCTAssertEqual(result.baseline.finalResources.map(\.resources), [23, 23])
        XCTAssertEqual(result.alternative.finalResources.map(\.resources), [18, 25])
        XCTAssertEqual(result.balances.map(\.difference), [-5, 2]); XCTAssertEqual(result.clearedRoundDifference, 0)
        XCTAssertNotEqual(result.baseline.inputDigest, result.alternative.inputDigest)
        XCTAssertEqual(result.baseline.seed, result.alternative.seed)
        var differentMechanism = model(); differentMechanism.participants = input.participants.map {
            KnowledgeParticipant(id: $0.id, name: $0.name, strategy: .contribute, initialResources: $0.initialResources)
        }
        XCTAssertThrowsError(try KnowledgeSimulationEngine.compare(baseline: input, alternative: differentMechanism, seed: 13))
    }

    func testMatrixReciprocityAndLossSwitchOnlyReadThePreviousCompletedRound() throws {
        let reciprocal = try full(matrix(rounds: 3, row: .alwaysSecond, column: .reciprocate))
        XCTAssertEqual(reciprocal.rounds.map { $0.actors.map(\.choice) }, [
            [.actionSecond, .actionFirst], [.actionSecond, .actionSecond], [.actionSecond, .actionSecond]
        ])
        let lossSwitch = try full(matrix(rounds: 3, row: .alwaysSecond, column: .winStayLoseShift))
        XCTAssertEqual(lossSwitch.rounds.map { $0.actors[1].choice }, [.actionFirst, .actionSecond, .actionSecond])
        XCTAssertEqual(lossSwitch.rounds.map { $0.actors[1].benefit - $0.actors[1].cost }, [-2, 1, 1])
        var reordered = matrix(rounds: 3, row: .alwaysSecond, column: .reciprocate); reordered.participants.reverse()
        XCTAssertEqual(try full(reordered).events, reciprocal.events, "稳定身份排序避免当前轮先后读取")
    }

    func testMatrixSeededAlternationReplaysExactlyAndSeedCanChangeTheTrajectory() throws {
        let input = matrix(rounds: 2, row: .alternate, column: .alternate)
        let zero = try full(input, seed: 0), one = try full(input, seed: 1)
        XCTAssertEqual(zero.rounds.map { $0.actors.map(\.choice) }, [[.actionFirst, .actionSecond], [.actionSecond, .actionFirst]])
        XCTAssertEqual(one.rounds.map { $0.actors.map(\.choice) }, [[.actionSecond, .actionFirst], [.actionFirst, .actionSecond]])
        XCTAssertNotEqual(zero.events, one.events); XCTAssertEqual(zero, try full(input, seed: 0))
        try KnowledgeSimulationEngine.verify(zero, model: input, seed: 0)
        XCTAssertThrowsError(try KnowledgeSimulationEngine.verify(zero, model: input, seed: 1))
        XCTAssertEqual(try Codec.decoder().decode(KnowledgeTrace.self, from: Codec.data(zero)), zero)
    }

    func testMatrixPartialReplayDoesNotLeakPayoutAndPoolAccountingStartsAfterActualStake() throws {
        let input = matrix()
        for tick in 0...4 {
            let trace = try KnowledgeSimulationEngine.record(model: input, seed: 0, throughTick: tick)
            XCTAssertTrue(trace.rounds.isEmpty); XCTAssertTrue(trace.events.allSatisfy { $0.actors.allSatisfy { $0.benefit == 0 } })
            if tick < 2 {
                XCTAssertNil(trace.events.last?.matrixPool); XCTAssertEqual(trace.finalResources.map(\.resources), [20, 20])
            } else {
                XCTAssertEqual(trace.events.last?.matrixPool?.available, 10)
                XCTAssertEqual(trace.events.last?.matrixPool?.distributed, 0)
                XCTAssertEqual(trace.finalResources.map(\.resources), [18, 18])
            }
        }
        let deciding = try KnowledgeSimulationEngine.frameState(model: input, seed: 0, frame: 45)
        XCTAssertEqual(deciding.phase, .decision); XCTAssertEqual(deciding.phaseProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(deciding.actors.map(\.choice), [.actionFirst, .actionFirst]); XCTAssertNil(deciding.matrixPool)
        let settled = try KnowledgeSimulationEngine.frameState(model: input, seed: 0, frame: 150)
        XCTAssertEqual(settled.actors.map(\.benefit), [5, 5]); XCTAssertEqual(settled.matrixPool?.distributed, 10)
    }

    func testMatrixLedgerConservesAllResourcesAcrossRoundsIncludingUnusedPools() throws {
        let input = matrix(rounds: 4, row: .alwaysSecond, column: .alwaysSecond), trace = try full(input)
        let remainders = trace.rounds.compactMap(\.matrixPool).reduce(0) { $0 + $1.remainder }
        XCTAssertEqual(remainders, 16)
        XCTAssertEqual(trace.finalResources.reduce(0) { $0 + $1.resources } + remainders, 40 + 4 * 6)
        for round in trace.rounds {
            let pool = try XCTUnwrap(round.matrixPool)
            XCTAssertEqual(pool.available, pool.distributed + pool.remainder)
            XCTAssertEqual(round.actors.reduce(0) { $0 + $1.benefit }, pool.distributed)
        }
    }

    func testMatrixMalformedIncompleteUnfundedAndUnboundedRulesAreRejected() throws {
        for change in 0..<16 {
            var input = matrix()
            switch change {
            case 0: input.payoffMatrix = nil
            case 1: input.payoffMatrix?.cells.removeLast()
            case 2:
                var rules = try XCTUnwrap(input.payoffMatrix)
                let repeated = rules.cells[0]; rules.cells[3] = repeated
                input.payoffMatrix = rules
            case 3: input.payoffMatrix?.cells[0].rowPayout = -1
            case 4: input.payoffMatrix?.cells[0].columnPayout = 6
            case 5: input.payoffMatrix?.stake = Int.max
            case 6: input.payoffMatrix?.externalBudget = Int.max
            case 7:
                var rules = try XCTUnwrap(input.payoffMatrix)
                let repeated = rules.firstActionLabel; rules.secondActionLabel = repeated
                input.payoffMatrix = rules
            case 8: input.payoffMatrix?.firstActionLabel = "行动\n注入"
            case 9: input.participants[0].matrixStrategy = nil
            case 10: input.participants[0].strategy = .freeRide
            case 11: input.participants[0].initialResources = 1
            case 12: input.participants[0].initialResources = 1_000_000
            case 13: input.version = 3
            case 14: input.participants.append(KnowledgeParticipant(id: "c", name: "丙", strategy: .contribute, matrixStrategy: .alwaysFirst))
            default: input.version = 1
            }
            XCTAssertThrowsError(try full(input), "严格拒绝矩阵规则变化\(change)")
        }
        var multiRound = matrix(rounds: 11)
        XCTAssertThrowsError(try full(multiRound), "20资源不能承诺11轮各2押金")
        multiRound.participants = multiRound.participants.map { person in var p = person; p.initialResources = 22; return p }
        XCTAssertNoThrow(try full(multiRound))
    }

    func testMatrixDecodingRejectsUnknownRuleKeysUnknownActionsAndMissingPayouts() throws {
        let original = try Codec.data(KnowledgePayoffMatrix.prisonersDilemma())
        for mutation in 0..<6 {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            switch mutation {
            case 0: object["unfundedMagicReward"] = 100
            case 1: object.removeValue(forKey: "externalBudget")
            default:
                var cells = try XCTUnwrap(object["cells"] as? [[String: Any]])
                switch mutation {
                case 2: cells[0]["rowAction"] = "unknown"
                case 3: cells[0].removeValue(forKey: "columnPayout")
                case 4: cells[0]["conditionalRule"] = "unimplemented"
                default: cells[0]["rowPayout"] = 1.5
                }
                object["cells"] = cells
            }
            XCTAssertThrowsError(try Codec.decoder().decode(KnowledgePayoffMatrix.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testVersionOnePublicGoodEncodingRemainsExactAndDoesNotGainMatrixKeys() throws {
        let historical = Data(#"{"benefit":3,"contributionCost":1,"contributionUnits":1,"knowledgeLabel":"旧模型","participants":[{"id":"a","initialResources":3,"name":"甲","strategy":"每轮出力"},{"id":"b","initialResources":3,"name":"乙","strategy":"等待他人出力"}],"resourceLabel":"资源","roundTicks":6,"rounds":1,"startTick":0,"threshold":1,"version":1}"#.utf8)
        let input = try Codec.decoder().decode(KnowledgeSimulation.self, from: historical)
        XCTAssertEqual(try Codec.data(input), historical)
        XCTAssertNil(input.payoffMatrix); XCTAssertTrue(input.participants.allSatisfy { $0.matrixStrategy == nil })
        let trace = try full(input)
        XCTAssertEqual(trace.version, 1); XCTAssertEqual(trace.finalResources.map(\.resources), [5, 6])
        let text = String(decoding: try Codec.data(trace), as: UTF8.self)
        XCTAssertFalse(text.contains("matrixPool")); XCTAssertFalse(text.contains("payoffMatrix")); XCTAssertFalse(text.contains("matrixStrategy"))
    }

    func testMatrixNormalRevisionRecordingBindsRuleInputsAndUsesRealCapacityWithoutOldPhaseLabels() throws {
        var scene = Scene(kind: .simulation, title: "矩阵", body: "观察实际收益", durationFrames: 600)
        scene.simulation.knowledge = matrix(rounds: 3)
        scene.captions = [Caption(text: "旧解释", startFrame: 0, endFrame: 120, confirmed: true)]
        scene.voice = VoiceTake(assetID: "old-voice", textDigest: "before", durationFrames: 120, method: "录音", listened: true)
        let revision = Revision(contentContext: ContentContext(workspaceID: "matrix", name: "矩阵工程"), aspect: .landscape, scenes: [scene])
        let original = Project(workspaceID: "matrix", name: "矩阵", revision: revision)
        let recorded = try Editor.apply([.recordSimulation(scene.id), .confirmSimulationRecording(scene.id)], to: original, baseRevision: revision.id, assets: [], message: "实际矩阵运行")
        let trace = try XCTUnwrap(recorded.current.scenes[0].simulationRecording)
        XCTAssertEqual(trace.ruleVersion, 2); XCTAssertEqual(trace.knowledgeTrace?.version, 2)
        XCTAssertEqual(trace.capacity, 70, "上界为两人各20初始+三轮最大净增5；不能沿用公共品benefit")
        XCTAssertFalse(trace.transitions.contains { $0.label.contains("清障") || $0.label.contains("通行") })
        try SimulationReplay.verify(scene: recorded.current.scenes[0])
        var changed = recorded.current.scenes[0]; changed.simulation.knowledge?.payoffMatrix?.cells[0].rowPayout = 4
        let edited = try Editor.apply([.replaceScene(scene.id, changed)], to: recorded, baseRevision: recorded.current.id, assets: [], message: "改变一格收益")
        XCTAssertNil(edited.current.scenes[0].voice); XCTAssertFalse(edited.current.scenes[0].captions[0].confirmed)
        XCTAssertFalse(edited.current.scenes[0].simulationRecordingConfirmed == true)
        XCTAssertThrowsError(try SimulationReplay.verify(scene: edited.current.scenes[0]))
        try SimulationReplay.verify(scene: edited.revisions[1].scenes[0])
        let reopened = try Codec.decoder().decode(Project.self, from: Codec.data(edited))
        XCTAssertEqual(reopened.current.scenes[0].simulation.knowledge, edited.current.scenes[0].simulation.knowledge)
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
