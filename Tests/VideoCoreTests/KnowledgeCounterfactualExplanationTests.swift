import XCTest
@testable import VideoCore

final class KnowledgeCounterfactualExplanationTests: XCTestCase {
    private func publicGood(rounds: Int = 1, threshold: Int = 1) -> KnowledgeSimulation {
        KnowledgeSimulation(knowledgeLabel: "共享通路", participants: [
            .init(id: "a", name: "甲", strategy: .contribute, initialResources: 10),
            .init(id: "b", name: "乙", strategy: .freeRide, initialResources: 10)
        ], rounds: rounds, threshold: threshold)
    }
    private func tableModel() -> KnowledgeSimulation {
        let people: [KnowledgeParticipant] = [
            .init(id: "a", name: "甲", strategy: .contribute, initialResources: 10),
            .init(id: "b", name: "乙", strategy: .contribute, initialResources: 10)
        ]
        return KnowledgeSimulation(knowledgeLabel: "交换与条件", participants: people, rounds: 1,
            ruleTable: KnowledgeRuleTable(actions: [.init(id: "act", label: "交付"), .init(id: "wait", label: "等待")],
                states: [.init(id: "open", label: "待交付"), .init(id: "received", label: "已收到", pose: .celebrate)],
                plans: people.map { .init(actorID: $0.id, initialStateID: "open", defaultActionID: "act") },
                rules: [.init(id: "exchange", label: "交付后交换", conditions: [.init(kind: .action, actorID: "a", actionID: "act")],
                    effects: [.transfer(from: "a", to: "b", amount: 2), .setState(actorID: "b", stateID: "received")])]))
    }
    func testIdenticalInputsHaveNoObservedOrTimingDifferenceAndReuseTheRealEngine() throws {
        let model = publicGood(rounds: 3)
        let explanation = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: model, seed: 13)
        XCTAssertTrue(explanation.changedEvents.isEmpty); XCTAssertTrue(explanation.timingChanges.isEmpty)
        XCTAssertNil(explanation.firstOutcomeDifference)
        XCTAssertEqual(explanation.comparison, try KnowledgeSimulationEngine.compare(baseline: model, alternative: model, seed: 13))
        XCTAssertEqual(explanation.comparison.baseline.events.count, 18)
    }
    func testCosmeticInputLabelsCannotManufactureAnOutcome() throws {
        let model = tableModel()
        var alternative = model
        alternative.knowledgeLabel = "另一个标题"; alternative.resourceLabel = "代币"
        alternative.participants[0].name = "新称呼"
        alternative.ruleTable?.actions[0].label = "请求交付"
        alternative.ruleTable?.states[0].label = "尚未交付"
        alternative.ruleTable?.rules[0].label = "交换条件说明"
        let result = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 0)
        XCTAssertNotEqual(result.comparison.baseline.inputDigest, result.comparison.alternative.inputDigest)
        XCTAssertTrue(result.changedEvents.isEmpty); XCTAssertNil(result.firstOutcomeDifference)
    }
    func testDifferentClocksAlignByRoundAndPhaseWithoutInventingOutcomes() throws {
        let model = publicGood(rounds: 3)
        var alternative = model; alternative.startTick = 9; alternative.roundTicks = 11
        let result = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 7)
        XCTAssertTrue(result.changedEvents.isEmpty); XCTAssertEqual(result.timingChanges.count, 18)
        XCTAssertEqual(result.timingChanges.first?.phase, .preparation)
        XCTAssertEqual(result.timingChanges.first?.baselineTick, 0); XCTAssertEqual(result.timingChanges.first?.alternativeTick, 9)
        XCTAssertEqual(result.timingChanges.last?.round, 3)
        XCTAssertEqual(result.timingChanges.last?.baselineTick, 17); XCTAssertEqual(result.timingChanges.last?.alternativeTick, 36)
    }
    func testThresholdInputIsNotAConsequenceBeforeTheResolutionActuallyChanges() throws {
        let model = publicGood(), alternative = publicGood(threshold: 2)
        let result = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 0)
        let first = try XCTUnwrap(result.firstOutcomeDifference)
        XCTAssertEqual(first.round, 1); XCTAssertEqual(first.phase, .resolution)
        XCTAssertEqual(first.observationFields, [.obstacleCleared])
        XCTAssertTrue(first.changedActorIDs.isEmpty)
        XCTAssertTrue(first.baseline.obstacleCleared); XCTAssertFalse(first.alternative.obstacleCleared)
        XCTAssertTrue(result.changedEvents.allSatisfy { [.resolution, .passage, .settlement].contains($0.phase) })
    }
    func testAnUnreachedThresholdChangeHasNoActualOutcomeDifference() throws {
        let result = try KnowledgeCounterfactualExplanation.build(baseline: publicGood(threshold: 2), alternative: publicGood(threshold: 3), seed: 0)
        XCTAssertTrue(result.changedEvents.isEmpty)
        XCTAssertEqual(result.comparison.balances.map(\.difference), [0, 0])
    }
    func testSameFinalBalancesStillExposeTheFirstDifferentRequestedAndExecutedActions() throws {
        var model = tableModel(); model.ruleTable?.rules[0].conditions = [.init(kind: .round, minimum: 2, maximum: 2)]
        var alternative = model; alternative.ruleTable?.plans[0].defaultActionID = "wait"
        let result = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 0)
        XCTAssertEqual(result.comparison.balances.map(\.difference), [0, 0])
        let decision = try XCTUnwrap(result.firstOutcomeDifference)
        XCTAssertEqual(decision.phase, .decision); XCTAssertEqual(decision.changedActorIDs, ["a"])
        XCTAssertEqual(decision.baseline.actors[0].requestedActionID, "act")
        XCTAssertEqual(decision.alternative.actors[0].requestedActionID, "wait")
        XCTAssertNil(decision.baseline.actors[0].executedActionID)
        let executed = try XCTUnwrap(result.changedEvents.first { $0.phase == .contribution })
        XCTAssertEqual(executed.baseline.actors[0].executedActionID, "act")
        XCTAssertEqual(executed.alternative.actors[0].executedActionID, "wait")
    }
    func testEqualRuleAndTransferCountsRetainDifferentAppliedAmountsAndTheirStableRuleID() throws {
        let model = tableModel(); var alternative = model
        alternative.ruleTable?.rules[0].effects[0].amount = 3
        let result = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 0)
        let first = try XCTUnwrap(result.firstOutcomeDifference)
        XCTAssertEqual(first.phase, .settlement); XCTAssertEqual(first.changedRuleIDs, ["exchange"])
        XCTAssertEqual(first.changedActorIDs, ["a", "b"])
        XCTAssertEqual(first.baseline.ruleExecution?.transfers.count, first.alternative.ruleExecution?.transfers.count)
        XCTAssertEqual(first.baseline.ruleExecution?.transfers.first?.amount, 2)
        XCTAssertEqual(first.alternative.ruleExecution?.transfers.first?.amount, 3)
        XCTAssertEqual(first.baseline.ruleExecution?.stateChanges, first.alternative.ruleExecution?.stateChanges)
    }
    func testMatchedFactsAreKeptAtResolutionButAppliedEffectsNeverAppearEarly() throws {
        let model = tableModel(); var alternative = model
        alternative.ruleTable?.plans[0].defaultActionID = "wait"
        let result = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 0)
        let resolved = try XCTUnwrap(result.changedEvents.first { $0.phase == .resolution })
        XCTAssertEqual(resolved.changedRuleIDs, ["exchange"])
        let fact = try XCTUnwrap(resolved.baseline.ruleExecution?.matches.first?.facts.first)
        XCTAssertEqual(fact.conditionIndex, 0); XCTAssertEqual(fact.actualID, "act")
        XCTAssertEqual(resolved.alternative.ruleExecution?.matches, [])
        XCTAssertTrue(resolved.baseline.ruleExecution?.transfers.isEmpty == true)
        XCTAssertTrue(resolved.alternative.ruleExecution?.stateChanges.isEmpty == true)
        let settled = try XCTUnwrap(result.changedEvents.first { $0.phase == .settlement })
        XCTAssertEqual(settled.baseline.ruleExecution?.stateChanges.first?.afterStateID, "received")
        XCTAssertEqual(settled.alternative.ruleExecution?.stateChanges, [])
    }
    func testConstrainedRequestIsVisibleWithoutAClaimThatItWasExecuted() throws {
        var model = tableModel(); model.ruleTable?.actions[0].cost = 10
        var alternative = model; alternative.ruleTable?.actions[0].cost = 11
        // Do not fund an additional exchange after the full cost is deposited.
        model.ruleTable?.rules[0].effects = [.setState(actorID: "b", stateID: "received")]
        alternative.ruleTable?.rules[0].effects = [.setState(actorID: "b", stateID: "received")]
        let result = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 0)
        let first = try XCTUnwrap(result.firstOutcomeDifference)
        XCTAssertEqual(first.phase, .decision)
        XCTAssertEqual(first.alternative.actors[0].choice, .constrained)
        XCTAssertEqual(first.alternative.actors[0].requestedActionID, "act")
        XCTAssertNil(first.alternative.actors[0].executedActionID)
        XCTAssertEqual(first.alternative.actors[0].cost, 0)
        XCTAssertTrue(first.alternative.ruleExecution?.transfers.isEmpty == true)
    }
    func testMaximumRoundBoundaryHasAtMost384SemanticallyAlignedEvents() throws {
        var model = publicGood(rounds: 64); model.participants[0].initialResources = 1000
        var alternative = model; alternative.threshold = 2
        let result = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 0)
        XCTAssertEqual(result.comparison.baseline.events.count, 384)
        XCTAssertEqual(result.comparison.alternative.events.count, 384)
        XCTAssertLessThanOrEqual(result.changedEvents.count, 384)
        XCTAssertEqual(result.changedEvents.last?.round, 64)
        XCTAssertEqual(Set(result.changedEvents.map(\.id)).count, result.changedEvents.count)
    }
    func testExplanationIsDeterministicReadOnlyAndDoesNotChangeTheOldWireValue() throws {
        let model = tableModel(); var alternative = model; alternative.ruleTable?.plans[0].defaultActionID = "wait"
        let before = try Codec.data(model), after = try Codec.data(alternative)
        let comparison = try KnowledgeSimulationEngine.compare(baseline: model, alternative: alternative, seed: 11)
        let oldWire = try Codec.data(comparison)
        let first = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 11)
        let second = try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 11)
        XCTAssertEqual(first, second); XCTAssertEqual(first.comparison, comparison)
        XCTAssertEqual(try Codec.data(model), before); XCTAssertEqual(try Codec.data(alternative), after)
        XCTAssertEqual(try Codec.data(first.comparison), oldWire)
        XCTAssertEqual(try Codec.decoder().decode(KnowledgeCounterfactualExplanation.self, from: Codec.data(first)), first)
    }
    func testIncompatibleIdentityOrMechanismIsRejectedByTheOriginalEngine() throws {
        let model = publicGood(); var alternative = model; alternative.participants[0].id = "renamed"
        XCTAssertThrowsError(try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: alternative, seed: 0))
        XCTAssertThrowsError(try KnowledgeCounterfactualExplanation.build(baseline: model, alternative: tableModel(), seed: 0))
    }
    private func readFixture() -> (Database, Workspace, Project) {
        let workspace = Workspace(name: "知识作者", owner: "owner")
        var left = Scene(kind: .simulation, title: "原参数", body: "实际规则")
        left.simulation.knowledge = publicGood(); left.simulation.seed = 31
        var right = Scene(kind: .simulation, title: "反事实", body: "同种子改门槛")
        right.simulation.knowledge = publicGood(threshold: 2); right.simulation.seed = 31
        let context = ContentContext(workspaceID: workspace.id, name: "知识对照工程")
        let revision = Revision(contentContext: context, aspect: .landscape, scenes: [left, right])
        let project = Project(workspaceID: workspace.id, name: "实际轨迹", revision: revision)
        var database = Database(); database.workspaces = [workspace]; database.projects = [project]
        return (database, workspace, project)
    }
    private func readInput(workspace: Workspace, project: Project) throws -> Data {
        try Codec.data(AgentValue.object(["workspace_id": .string(workspace.id), "project_id": .string(project.id),
            "base_revision": .string(project.current.id), "scene_id": .string(project.current.scenes[0].id),
            "comparison_scene_id": .string(project.current.scenes[1].id)]))
    }
    func testNormalReadEntryReturnsTheSameActualExplanationWithoutReviewOrRepositoryWrites() throws {
        let (database, workspace, project) = readFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-read-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root); try repository.transaction { $0 = database }
        let read = try Repository(root: root, readOnly: true), before = try Codec.data(read.read())
        let response = try AgentPreview.evaluate(command: "knowledge compare", data: readInput(workspace: workspace, project: project),
                                                 database: read.read(), principal: "owner")
        let observed = try Codec.decoder().decode(KnowledgeCounterfactualExplanation.self, from: Codec.data(response))
        XCTAssertEqual(observed, try KnowledgeCounterfactualExplanation.build(baseline: publicGood(), alternative: publicGood(threshold: 2), seed: 31))
        XCTAssertEqual(observed.firstOutcomeDifference?.phase, .resolution)
        XCTAssertEqual(try Codec.data(read.read()), before)
        XCTAssertEqual(try Codec.data(repository.read()), before)
        XCTAssertTrue(try read.read().jobs.isEmpty)
        XCTAssertTrue(try read.read().agentReplayRecords?.isEmpty ?? true)
        XCTAssertFalse(try read.read().projects[0].current.review.complete)
    }
    func testNormalReadEntryRejectsForeignWorkspaceStaleRevisionRevokedReaderAndUnequalSeeds() throws {
        let (database, workspace, project) = readFixture()
        let data = try readInput(workspace: workspace, project: project)
        for invalid in ["foreign-workspace", "stale-revision", "revoked-reader", "unequal-seeds"] {
            var snapshot = database
            var input = try AgentContract.validate(command: "knowledge compare", data: data)
            var principal = "owner"
            switch invalid {
            case "foreign-workspace":
                let foreign = Workspace(name: "另一客户", owner: "owner")
                snapshot.workspaces.append(foreign); input["workspace_id"] = .string(foreign.id)
            case "stale-revision": input["base_revision"] = .string("former-revision")
            case "revoked-reader":
                principal = "reader"
                var grant = Grant(principal: principal, role: .reviewer, projectIDs: [project.id],
                    revisionIDs: [project.current.id], expiresAt: Date().addingTimeInterval(600))
                grant.revoked = true; snapshot.workspaces[0].grants = [grant]
            default: snapshot.projects[0].revisions[0].scenes[1].simulation.seed = 32
            }
            let before = try Codec.data(snapshot)
            XCTAssertThrowsError(try AgentPreview.evaluate(command: "knowledge compare", data: Codec.data(AgentValue.object(input)),
                                                           database: snapshot, principal: principal), invalid) { error in
                let expected = invalid == "stale-revision" ? "revision_conflict" : invalid == "unequal-seeds" ? "invalid_input" : "permission_required"
                // The boundary, rather than a decoding or unsupported-command error, must reject the request.
                XCTAssertEqual((error as? VideoError)?.code, expected, invalid)
            }
            XCTAssertEqual(try Codec.data(snapshot), before, invalid)
        }
    }
}
