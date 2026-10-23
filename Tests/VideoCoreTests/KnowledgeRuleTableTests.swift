import XCTest
@testable import VideoCore

final class KnowledgeRuleTableTests: XCTestCase {
    private func model(rounds: Int = 1) -> KnowledgeSimulation {
        let actions = [KnowledgeRuleAction(id: "offer", label: "提交交换", cost: 1, pose: .act),
                       KnowledgeRuleAction(id: "wait", label: "等待", pose: .idle)]
        let states = [KnowledgeRuleState(id: "open", label: "待协商"),
                      KnowledgeRuleState(id: "agreed", label: "已达成", pose: .celebrate)]
        let plans = ["a", "b"].map { id in
            KnowledgeRuleActorPlan(actorID: id, initialStateID: "open", defaultActionID: "offer", decisions: [
                KnowledgeRuleDecision(id: "after-agreement", priority: 0,
                    conditions: [KnowledgeRuleCondition(kind: .state, actorID: id, stateID: "agreed")], actionID: "wait")
            ])
        }
        let rules = [KnowledgeRule(id: "exchange", label: "双方提交后实际交换", conditions: [
            KnowledgeRuleCondition(kind: .actionCount, actionID: "offer", minimum: 2, maximum: 2),
            KnowledgeRuleCondition(kind: .state, actorID: "a", stateID: "open")
        ], effects: [
            .transfer(from: nil, to: "a", amount: 2), .transfer(from: nil, to: "b", amount: 2),
            .setState(actorID: "a", stateID: "agreed"), .setState(actorID: "b", stateID: "agreed")
        ])]
        return KnowledgeSimulation(knowledgeLabel: "交易条件与双方选择", resourceLabel: "筹码",
            participants: [KnowledgeParticipant(id: "a", name: "甲", strategy: .contribute, initialResources: 10),
                           KnowledgeParticipant(id: "b", name: "乙", strategy: .contribute, initialResources: 10)], rounds: rounds,
            ruleTable: KnowledgeRuleTable(actions: actions, states: states, plans: plans, rules: rules, initialPool: 5, externalBudgetPerRound: 2))
    }
    private func full(_ model: KnowledgeSimulation, seed: UInt64 = 12) throws -> KnowledgeTrace {
        try KnowledgeSimulationEngine.record(model: model, seed: seed, throughTick: model.lastSettlementTick())
    }
    private func changing(_ model: KnowledgeSimulation, _ change: (inout KnowledgeRuleTable) -> Void) throws -> KnowledgeSimulation {
        var result = model, table = try XCTUnwrap(model.ruleTable); change(&table); result.ruleTable = table; return result
    }

    func testUserActionsConditionsTransfersAndStatesProduceOneCausalLedger() throws {
        let input = model(), trace = try full(input), result = try XCTUnwrap(trace.rounds.first)
        XCTAssertEqual(trace.version, 3); XCTAssertEqual(trace.events.map(\.phase), KnowledgePhase.allCases)
        XCTAssertEqual(result.actors.map(\.resources), [11, 11]); XCTAssertEqual(result.actors.map(\.cost), [1, 1])
        XCTAssertEqual(result.actors.map(\.benefit), [2, 2]); XCTAssertEqual(result.actors.map(\.ruleStateID), ["agreed", "agreed"])
        XCTAssertEqual(result.actors.map(\.requestedActionID), ["offer", "offer"])
        XCTAssertEqual(result.actors.map(\.executedActionID), ["offer", "offer"])
        let execution = try XCTUnwrap(result.ruleExecution)
        XCTAssertEqual(execution.poolBefore, 5); XCTAssertEqual(execution.poolAfter, 5)
        XCTAssertEqual(execution.externalFunding, 2); XCTAssertEqual(execution.deposits, 2)
        XCTAssertEqual(execution.matches.map(\.ruleID), ["exchange"])
        XCTAssertEqual(execution.matches[0].facts[0].actualNumber, 2)
        XCTAssertEqual(execution.matches[0].facts[1].actualID, "open")
        XCTAssertEqual(execution.transfers.map(\.amount), [2, 2]); XCTAssertEqual(execution.stateChanges.count, 2)
        XCTAssertTrue(result.actors.allSatisfy { !$0.passed && $0.contribution == 0 })
        XCTAssertFalse(result.obstacleCleared); XCTAssertNil(result.matrixPool)
        try KnowledgeSimulationEngine.verify(trace, model: input, seed: 12)
        XCTAssertEqual(try Codec.decoder().decode(KnowledgeTrace.self, from: Codec.data(trace)), trace)
    }

    func testPartialReplayPublishesRequestsCostsRulesAndAppliedEffectsAtTheirActualPhases() throws {
        for tick in 0...4 {
            let trace = try KnowledgeSimulationEngine.record(model: model(), seed: 12, throughTick: tick)
            let event = try XCTUnwrap(trace.events.last), execution = try XCTUnwrap(event.ruleExecution)
            XCTAssertTrue(trace.rounds.isEmpty); XCTAssertTrue(execution.transfers.isEmpty); XCTAssertTrue(execution.stateChanges.isEmpty)
            XCTAssertEqual(event.actors.map(\.ruleStateID), ["open", "open"])
            XCTAssertTrue(event.actors.allSatisfy { $0.benefit == 0 })
            if tick == 0 { XCTAssertTrue(event.actors.allSatisfy { $0.requestedActionID == nil }) }
            if tick < 2 {
                XCTAssertTrue(event.actors.allSatisfy { $0.executedActionID == nil && $0.cost == 0 })
                XCTAssertEqual(event.actors.map(\.resources), [10, 10]); XCTAssertEqual(execution.poolAfter, 5)
                XCTAssertEqual(execution.externalFunding, 0)
            } else {
                XCTAssertEqual(event.actors.map(\.resources), [9, 9]); XCTAssertEqual(execution.poolAfter, 9)
                XCTAssertEqual(execution.deposits, 2); XCTAssertEqual(execution.externalFunding, 2)
            }
            XCTAssertEqual(execution.matches.isEmpty, tick < 3)
        }
    }

    func testDecisionsReadPreviousSettledStateAndResourcesAcrossRounds() throws {
        let trace = try full(model(rounds: 3))
        XCTAssertEqual(trace.rounds.map { $0.actors.map(\.executedActionID) }, [["offer", "offer"], ["wait", "wait"], ["wait", "wait"]])
        XCTAssertEqual(trace.rounds.map { $0.ruleExecution?.deposits }, [2, 0, 0])
        XCTAssertEqual(trace.rounds.map { $0.ruleExecution?.poolAfter }, [5, 7, 9])
        XCTAssertEqual(trace.rounds.map { $0.ruleExecution?.matches.count }, [1, 0, 0])
        XCTAssertEqual(trace.finalResources.map(\.resources), [11, 11])
    }

    func testAllStrategiesObserveSameHistoryAndNeverAnotherCurrentDecision() throws {
        let input = try changing(model(rounds: 2)) { table in
            table.plans[0].defaultActionID = "wait"
            table.plans[0].decisions = [KnowledgeRuleDecision(id: "follow-b", priority: 1,
                conditions: [.init(kind: .action, actorID: "b", actionID: "offer")], actionID: "offer")]
            table.plans[1].decisions = [KnowledgeRuleDecision(id: "follow-a", priority: 1,
                conditions: [.init(kind: .action, actorID: "a", actionID: "offer")], actionID: "wait")]
        }
        let trace = try full(input)
        XCTAssertEqual(trace.rounds[0].actors.map(\.executedActionID), ["wait", "offer"])
        XCTAssertEqual(trace.rounds[1].actors.map(\.executedActionID), ["offer", "offer"])
    }

    func testUnfundedRequestedActionDoesNotCountAsExecutedOrTriggerItsRule() throws {
        var input = model(); input.participants[0].initialResources = 0
        let result = try XCTUnwrap(full(input).rounds.first)
        XCTAssertEqual(result.actors[0].requestedActionID, "offer"); XCTAssertNil(result.actors[0].executedActionID)
        XCTAssertEqual(result.actors[0].choice, .constrained); XCTAssertEqual(result.actors[0].cost, 0)
        XCTAssertEqual(result.actors[0].resources, 0); XCTAssertEqual(result.ruleExecution?.deposits, 1)
        XCTAssertTrue(result.ruleExecution?.matches.isEmpty == true); XCTAssertTrue(result.ruleExecution?.transfers.isEmpty == true)
    }

    func testSeededCyclesAreBoundedAndDeterministic() throws {
        let input = try changing(model(rounds: 2)) { table in
            for index in table.plans.indices { table.plans[index].cycleActionIDs = ["offer", "wait"]; table.plans[index].decisions = [] }
        }
        let zero = try full(input, seed: 0), one = try full(input, seed: 1)
        XCTAssertEqual(zero, try full(input, seed: 0))
        XCTAssertEqual(zero.rounds.map { $0.actors.map(\.executedActionID) }, [["offer", "wait"], ["wait", "offer"]])
        XCTAssertEqual(one.rounds.map { $0.actors.map(\.executedActionID) }, [["wait", "offer"], ["offer", "wait"]])
        XCTAssertNotEqual(zero.events, one.events)
        XCTAssertThrowsError(try KnowledgeSimulationEngine.verify(zero, model: input, seed: 1))
    }

    func testActorActionStateRuleAndDecisionArrayReorderingKeepsEventsIdentical() throws {
        let input = try changing(model(rounds: 2)) { table in
            table.rules.append(KnowledgeRule(id: "not-yet", label: "第三轮才发生", conditions: [.init(kind: .round, minimum: 3, maximum: 3)], effects: [.transfer(from: "a", to: "b", amount: 1)]))
            table.plans[0].decisions.append(KnowledgeRuleDecision(id: "priority-later", priority: 10, conditions: [], actionID: "offer"))
        }
        var reordered = try changing(input) { table in
            table.actions.reverse(); table.states.reverse(); table.plans.reverse(); table.rules.reverse()
            for index in table.plans.indices { table.plans[index].decisions.reverse() }
        }
        reordered.participants.reverse()
        XCTAssertEqual(try full(input).events, try full(reordered).events)
        XCTAssertEqual(try full(input).finalResources, try full(reordered).finalResources)
    }

    func testCounterfactualRecomputesEditedRuleAndOldRecordingIsRejected() throws {
        let input = model(), alternative = try changing(input) { $0.rules[0].effects[0].amount = 3 }
        let comparison = try KnowledgeSimulationEngine.compare(baseline: input, alternative: alternative, seed: 12)
        XCTAssertEqual(comparison.balances.map(\.difference), [1, 0])
        XCTAssertEqual(comparison.baseline.rounds[0].ruleExecution?.poolAfter, 5)
        XCTAssertEqual(comparison.alternative.rounds[0].ruleExecution?.poolAfter, 4)
        XCTAssertNotEqual(comparison.baseline.inputDigest, comparison.alternative.inputDigest)
        XCTAssertThrowsError(try KnowledgeSimulationEngine.verify(comparison.baseline, model: alternative, seed: 12))
        XCTAssertEqual(comparison.clearedRoundDifference, 0)
    }

    func testMultipleMatchingRowsSettleAtomicallyAndRuleOrderCannotGrantCredit() throws {
        let input = try changing(model()) { table in
            table.rules = [
                KnowledgeRule(id: "first", label: "先看见的入账不能借给同轮扣款", conditions: [], effects: [.transfer(from: "a", to: "b", amount: 5)]),
                KnowledgeRule(id: "second", label: "同快照扣款", conditions: [], effects: [.transfer(from: "b", to: "a", amount: 5)])
            ]
            table.actions[0].cost = 0
        }
        var insolvent = input; insolvent.participants[1].initialResources = 0
        XCTAssertThrowsError(try full(insolvent))
        let reordered = try changing(insolvent) { $0.rules.reverse() }
        XCTAssertThrowsError(try full(reordered))
        let solvent = try full(input)
        XCTAssertEqual(solvent.finalResources.map(\.resources), [10, 10])
        XCTAssertEqual(solvent.rounds[0].actors.map(\.cost), [5, 5]); XCTAssertEqual(solvent.rounds[0].actors.map(\.benefit), [5, 5])
    }

    func testConcurrentPoolOverdraftRejectsWholeResultRatherThanClippingOrChoosingFirst() throws {
        let input = try changing(model()) { table in
            table.rules = [KnowledgeRule(id: "a", label: "甲请求", conditions: [], effects: [.transfer(from: nil, to: "a", amount: 6)]),
                           KnowledgeRule(id: "b", label: "乙请求", conditions: [], effects: [.transfer(from: nil, to: "b", amount: 6)])]
        }
        XCTAssertThrowsError(try full(input))
        XCTAssertThrowsError(try full(changing(input) { $0.rules.reverse() }))
        let throughResolution = try KnowledgeSimulationEngine.record(model: input, seed: 12, throughTick: 3)
        XCTAssertEqual(throughResolution.events.last?.ruleExecution?.matches.count, 2)
        XCTAssertEqual(throughResolution.finalResources.map(\.resources), [9, 9])
        XCTAssertTrue(throughResolution.events.last?.ruleExecution?.transfers.isEmpty == true)
    }

    func testConcurrentStateWritesRejectEvenWhenTheyNameTheSameTargetState() throws {
        for duplicateInSameRule in [false, true] {
            let input = try changing(model()) { table in
                if duplicateInSameRule { table.rules[0].effects.append(.setState(actorID: "a", stateID: "agreed")) }
                else { table.rules.append(KnowledgeRule(id: "other", label: "重复写入", conditions: [], effects: [.setState(actorID: "a", stateID: "agreed")])) }
            }
            XCTAssertThrowsError(try full(input))
        }
    }

    func testRuleConditionsSharePreEffectStateAndResourceSnapshot() throws {
        let input = try changing(model()) { table in
            table.rules.append(KnowledgeRule(id: "after", label: "不能读取同轮刚转换的状态", conditions: [.init(kind: .state, actorID: "a", stateID: "agreed")], effects: [.transfer(from: nil, to: "a", amount: 1)]))
        }
        let result = try XCTUnwrap(full(input).rounds.first)
        XCTAssertEqual(result.ruleExecution?.matches.map(\.ruleID), ["exchange"])
        XCTAssertEqual(result.actors[0].resources, 11)
    }

    func testResourceRangesUseActualPostCostSnapshotAndRoundConditionsUseCurrentRound() throws {
        let input = try changing(model(rounds: 2)) { table in
            table.rules[0].conditions = [.init(kind: .resources, actorID: "a", minimum: 9, maximum: 9), .init(kind: .round, minimum: 1, maximum: 1)]
        }
        let trace = try full(input)
        XCTAssertEqual(trace.rounds[0].ruleExecution?.matches[0].facts.map(\.actualNumber), [9, 1])
        XCTAssertTrue(trace.rounds[1].ruleExecution?.matches.isEmpty == true)
    }

    func testPoolCarryAndEveryExternalUnitRemainAccountedAcrossRounds() throws {
        let input = model(rounds: 8), trace = try full(input)
        var expected = 25
        for round in trace.rounds {
            let execution = try XCTUnwrap(round.ruleExecution)
            expected += execution.externalFunding
            XCTAssertEqual(round.actors.reduce(execution.poolAfter) { $0 + $1.resources }, expected)
            XCTAssertEqual(execution.externalFunding, 2)
        }
        XCTAssertEqual(try input.maximumTotalResources(), 41)
        XCTAssertEqual(trace.rounds.last?.ruleExecution?.poolAfter, 19)
    }

    func testTableDataCanExpressDifferentMechanismsWithoutKnowledgeNameBranches() throws {
        var transition = try changing(model(rounds: 2)) { table in
            table.states = [.init(id: "open", label: "易感"), .init(id: "agreed", label: "已隔离", pose: .object)]
            table.rules[0].label = "观察到接触后转入隔离状态"
            table.rules[0].effects = [.setState(actorID: "a", stateID: "agreed")]
        }
        transition.knowledgeLabel = "有限状态传播条件"
        let states = try full(transition)
        XCTAssertEqual(states.rounds[0].actors.map(\.resources), [9, 9])
        XCTAssertEqual(states.rounds[0].actors.map(\.ruleStateID), ["agreed", "open"])
        var allocation = try changing(model()) { table in
            table.rules[0].label = "共同基金按已执行请求分配"
            table.rules[0].effects = [.transfer(from: nil, to: "a", amount: 4), .transfer(from: nil, to: "b", amount: 1)]
        }
        allocation.knowledgeLabel = "有限公共基金分配"
        XCTAssertEqual(try full(allocation).finalResources.map(\.resources), [13, 10])
        let renamed = allocation; allocation.knowledgeLabel = "同一规则另一知识标题"
        XCTAssertEqual(try full(renamed).events, try full(allocation).events)
    }

    func testFrameStateBeforeStartAndAfterSettlementUsesSameAbsoluteSourceHistory() throws {
        var input = model(); input.startTick = 4
        let before = try KnowledgeSimulationEngine.frameState(model: input, seed: 12, frame: 0)
        XCTAssertNil(before.phase); XCTAssertEqual(before.actors.map(\.ruleStateID), ["open", "open"])
        let partial = try KnowledgeSimulationEngine.frameState(model: input, seed: 12, frame: 225)
        XCTAssertEqual(partial.phase, .resolution); XCTAssertEqual(partial.phaseProgress, 0.5, accuracy: 0.001)
        XCTAssertTrue(partial.ruleExecution?.transfers.isEmpty == true)
        let settled = try KnowledgeSimulationEngine.frameState(model: input, seed: 12, frame: 285)
        XCTAssertEqual(settled.phase, .settlement); XCTAssertEqual(settled.actors.map(\.resources), [11, 11])
        XCTAssertEqual(settled.ruleExecution?.stateChanges.count, 2)
    }

    func testInvalidReferencesShapesAmountsAndLegacyMixturesAreRejected() throws {
        for mutation in 0..<24 {
            var input = model(), table = try XCTUnwrap(input.ruleTable)
            switch mutation {
            case 0: table.version = 2
            case 1: table.actions[0].id = "bad id"
            case 2: table.actions[1].id = table.actions[0].id
            case 3: table.actions[0].cost = -1
            case 4: table.states[0].label = "控制\n字符"
            case 5: table.plans.removeLast()
            case 6: table.plans[0].initialStateID = "missing"
            case 7: table.plans[0].defaultActionID = "missing"
            case 8: table.plans[0].cycleActionIDs = ["missing"]
            case 9: table.plans[0].decisions[0].priority = -1
            case 10: table.rules[0].conditions[0].maximum = 9
            case 11: table.rules[0].conditions[1].actorID = "missing"
            case 12: table.rules[0].conditions[1].minimum = 1
            case 13: table.rules[0].effects[0].amount = 0
            case 14: table.rules[0].effects[0].destinationActorID = nil
            case 15: table.rules[0].effects[0].sourceActorID = "a"
            case 16: table.rules[0].effects[2].stateID = "missing"
            case 17: table.rules[0].effects[2].amount = 1
            case 18: table.externalBudgetPerRound = Int.max
            case 19: input.payoffMatrix = .prisonersDilemma()
            case 20: input.participants[0].matrixStrategy = .alwaysFirst
            case 21: input.participants[0].strategy = .freeRide
            case 22: input.version = 2
            default: input.version = 1
            }
            input.ruleTable = table
            XCTAssertThrowsError(try full(input), "无效规则表\(mutation)")
        }
    }

    func testGlobalConditionEffectDecisionAndResourceBudgetsAreEnforced() throws {
        let original = model()
        for mutation in 0..<5 {
            let input = try changing(original) { table in
                switch mutation {
                case 0:
                    table.rules = (0..<17).map { .init(id: "r\($0)", label: "条件总量", conditions: Array(repeating: .init(kind: .round, minimum: 1, maximum: 64), count: 8), effects: [.transfer(from: nil, to: "a", amount: 1)]) }
                case 1:
                    table.rules = (0..<9).map { .init(id: "r\($0)", label: "效果总量", conditions: [], effects: Array(repeating: .transfer(from: nil, to: "a", amount: 1), count: 16)) }
                case 2: table.initialPool = 1_000_000
                case 3: table.actions = (0..<9).map { .init(id: "a\($0)", label: "越界动作") }
                default: table.plans[0].decisions = [table.plans[0].decisions[0], table.plans[0].decisions[0]]
                }
            }
            XCTAssertThrowsError(try full(input))
        }
        var many = original
        many.participants = (0..<5).map { .init(id: "p\($0)", name: "参与者\($0)", strategy: .contribute, initialResources: 1) }
        var table = try XCTUnwrap(many.ruleTable)
        table.rules = [.init(id: "r", label: "明示规则", conditions: [], effects: [.setState(actorID: "p0", stateID: "open")])]
        table.plans = many.participants.map { person in .init(actorID: person.id, initialStateID: "open", defaultActionID: "wait",
            decisions: (0..<13).map { .init(id: "d\($0)", priority: $0, conditions: [], actionID: "wait") }) }
        many.ruleTable = table
        XCTAssertThrowsError(try full(many), "65个决策超过整表64上界，即使每实体不足16")
    }

    func testStrictDecodingRejectsUnknownKeysMissingFieldsUnknownKindsAndFractionalAmounts() throws {
        let data = try Codec.data(XCTUnwrap(model().ruleTable))
        for mutation in 0..<8 {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            switch mutation {
            case 0: object["runCode"] = "for(;;){}"
            case 1: object.removeValue(forKey: "initialPool")
            case 2:
                var actions = try XCTUnwrap(object["actions"] as? [[String: Any]])
                actions[0]["pose"] = "executeShell"; object["actions"] = actions
            case 3:
                var plans = try XCTUnwrap(object["plans"] as? [[String: Any]])
                plans[0]["script"] = "hidden"; object["plans"] = plans
            default:
                var rules = try XCTUnwrap(object["rules"] as? [[String: Any]])
                if mutation == 4 {
                    var conditions = try XCTUnwrap(rules[0]["conditions"] as? [[String: Any]])
                    conditions[0]["expression"] = "a > b"; rules[0]["conditions"] = conditions
                } else {
                    var effects = try XCTUnwrap(rules[0]["effects"] as? [[String: Any]])
                    if mutation == 5 { effects[0]["kind"] = "mint" }
                    if mutation == 6 { effects[0]["amount"] = 0.5 }
                    if mutation == 7 { effects[0]["callback"] = "hidden" }
                    rules[0]["effects"] = effects
                }
                object["rules"] = rules
            }
            XCTAssertThrowsError(try Codec.decoder().decode(KnowledgeRuleTable.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testVersionOneAndTwoNilEncodingAndTraceBehaviorRemainUnchanged() throws {
        let historical = Data(#"{"benefit":3,"contributionCost":1,"contributionUnits":1,"knowledgeLabel":"旧模型","participants":[{"id":"a","initialResources":3,"name":"甲","strategy":"每轮出力"},{"id":"b","initialResources":3,"name":"乙","strategy":"等待他人出力"}],"resourceLabel":"资源","roundTicks":6,"rounds":1,"startTick":0,"threshold":1,"version":1}"#.utf8)
        let old = try Codec.decoder().decode(KnowledgeSimulation.self, from: historical)
        XCTAssertEqual(try Codec.data(old), historical); XCTAssertEqual(try full(old).finalResources.map(\.resources), [5, 6])
        var matrix = old; matrix.version = 2; matrix.payoffMatrix = .prisonersDilemma()
        matrix.participants = matrix.participants.map { participant in var p = participant; p.strategy = .contribute; p.matrixStrategy = .alwaysFirst; return p }
        let data = try Codec.data(matrix), roundTrip = try Codec.decoder().decode(KnowledgeSimulation.self, from: data)
        XCTAssertEqual(try Codec.data(roundTrip), data); XCTAssertEqual(try full(matrix).version, 2)
        let oldTrace = String(decoding: try Codec.data(full(old)), as: UTF8.self)
        let matrixTrace = String(decoding: try Codec.data(full(matrix)), as: UTF8.self)
        for key in ["ruleTable", "ruleStateID", "requestedActionID", "executedActionID", "ruleExecution"] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(key)); XCTAssertFalse(oldTrace.contains(key)); XCTAssertFalse(matrixTrace.contains(key))
        }
    }

    func testSharedInputSchemasKeepLegacyDeclarationsFrozenAndExposeVersionFiveExplicitly() throws {
        let v2 = KnowledgeSimulationSchema.records(forInputSchemaVersion: 2)
        let v3 = KnowledgeSimulationSchema.records(forInputSchemaVersion: 3)
        let v4 = KnowledgeSimulationSchema.records(forInputSchemaVersion: 4)
        let v5 = KnowledgeSimulationSchema.records(forInputSchemaVersion: 5)
        XCTAssertEqual(v2["KnowledgeActorState"], "id:s resources:i choice?:KnowledgeChoice contribution:i cost:i benefit:i passed:b")
        XCTAssertEqual(v3, v4); XCTAssertNil(v4["KnowledgeRuleTable"])
        XCTAssertFalse(v4["KnowledgeSimulation"]!.contains("ruleTable")); XCTAssertTrue(v5["KnowledgeSimulation"]!.contains("ruleTable"))
        XCTAssertNotNil(v5["KnowledgeRuleExecution"]); XCTAssertNotNil(KnowledgeSimulationSchema.enums(forInputSchemaVersion: 5)["KnowledgeRulePose"])
        XCTAssertNil(KnowledgeSimulationSchema.enums(forInputSchemaVersion: 4)["KnowledgeRulePose"])
    }
}
