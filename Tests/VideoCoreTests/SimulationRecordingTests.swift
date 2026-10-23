import XCTest
@testable import VideoCore

final class SimulationRecordingTests: XCTestCase {
    private func revision(scene: Scene) -> Revision {
        let product = Product(workspaceID: "recording-tests", sku: "isolated", name: "规则练习", checkout: "https://example.org/course", audience: "学习者", task: "核对规则", outcome: "复现事件", prerequisite: "无", scope: "规则演示", prices: [Price(money: Money(1), from: .distantPast, source: "isolated-test", verified: true)])
        return Revision(product: product, purpose: .education, aspect: .landscape, scenes: [scene], cta: "亲手复现规则")
    }
    private func issues(_ revision: Revision, requireReview: Bool = false) throws -> [QualityIssue] {
        var database = Database(); database.products = [revision.product!]
        return try Quality.inspect(revision, database: database, requireReview: requireReview)
    }
    private func recordedScene(confirmed: Bool = true) throws -> Scene {
        var scene = Scene(kind: .simulation, title: "规则", body: "依输入顺序记录同秒事件", durationFrames: 180)
        scene.simulation.initial = 5; scene.simulation.capacity = 10; scene.simulation.unit = "件"
        scene.simulation.events = [RuleEvent(tick: 1, delta: 20, label: "加入"), RuleEvent(tick: 1, delta: -3, label: "移除"), RuleEvent(tick: 5, delta: 2, label: "最后可见秒")]
        scene.simulationRecording = try SimulationReplay.record(scene: scene)
        scene.simulationRecordingConfirmed = confirmed
        return scene
    }
    private func apply(_ operations: [Edit], scene: Scene) throws -> Project {
        let before = revision(scene: scene)
        return try Editor.apply(operations, to: Project(workspaceID: before.product!.workspaceID, name: "规则项目", revision: before), baseRevision: before.id, assets: [], message: "显式规则编辑")
    }
    func testLegacyUnrecordedSimulationRemainsEditableButNeedsRecordingBeforeProduction() throws {
        let original = Scene(kind: .simulation, title: "规则", body: "事件依次改变状态")
        let decoded = try Codec.decoder().decode(Scene.self, from: Codec.data(original))
        XCTAssertNil(decoded.simulationRecording); XCTAssertNil(decoded.simulationRecordingConfirmed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Codec.data(original)) as? [String: Any])
        XCTAssertNil(object["simulationRecording"]); XCTAssertNil(object["simulationRecordingConfirmed"])
        let before = revision(scene: decoded)
        let project = Project(workspaceID: before.product!.workspaceID, name: "旧工程", revision: before)
        var changed = decoded; changed.simulation.unit = "件"
        let edited = try Editor.apply([.replaceScene(decoded.id, changed)], to: project, baseRevision: before.id, assets: [], message: "修改规则单位")
        XCTAssertTrue(try issues(edited.current).contains { $0.id == decoded.id + "simulation_recording" })
    }
    func testWholeVideoApprovalDoesNotSubstituteForExplicitRuleRecordingReview() throws {
        var value = revision(scene: Scene(kind: .simulation, title: "规则", body: "规则并非现实保证"))
        value.review.text = true; value.review.rights = true; value.review.fullPreview = true
        value.review.sound = true; value.review.captions = true; value.review.digest = try value.contentDigest()
        XCTAssertTrue(try issues(value, requireReview: true).contains { $0.id == value.scenes[0].id + "simulation_recording" })
    }
    func testRecordingPersistsExactFullTraceAndStillRequiresSeparateConfirmation() throws {
        let scene = try recordedScene(confirmed: false), trace = try XCTUnwrap(scene.simulationRecording)
        XCTAssertEqual(trace, try SimulationReplay.record(scene: scene))
        XCTAssertEqual(trace.recordedFPS, 30); XCTAssertEqual(trace.recordedDurationFrames, 180); XCTAssertEqual(trace.throughTick, 5)
        XCTAssertEqual(trace.transitions.map(\.before), [5, 10, 7]); XCTAssertEqual(trace.transitions.map(\.after), [10, 7, 9])
        XCTAssertEqual(trace.transitions.map(\.clippedDelta), [15, 0, 0])
        XCTAssertThrowsError(try SimulationReplay.verify(scene: scene))
        let edited = try apply([.confirmSimulationRecording(scene.id)], scene: scene)
        let reopened = try Codec.decoder().decode(Project.self, from: Codec.data(edited))
        XCTAssertEqual(reopened.current.scenes[0].simulationRecording, trace)
        XCTAssertNoThrow(try SimulationReplay.verify(scene: reopened.current.scenes[0]))
        XCTAssertFalse(try issues(reopened.current).contains { $0.id.hasSuffix("simulation_recording") })
        XCTAssertFalse(reopened.current.review.complete, "规则复核不能授予整片看听审批")
    }
    func testSharedWireEditsRecordThenExplicitlyConfirmWithoutCopyingRuleLogic() throws {
        var scene = try recordedScene(); scene.simulationRecording = nil; scene.simulationRecordingConfirmed = nil
        let encoded = try Codec.data([Edit.recordSimulation(scene.id), Edit.confirmSimulationRecording(scene.id)])
        let edits = try Codec.decoder().decode([Edit].self, from: encoded)
        let updated = try apply(edits, scene: scene)
        XCTAssertNoThrow(try SimulationReplay.verify(scene: updated.current.scenes[0]))
        let unreviewed = try apply([.recordSimulation(scene.id)], scene: scene)
        XCTAssertEqual(unreviewed.current.scenes[0].simulationRecordingConfirmed, false)
        XCTAssertThrowsError(try SimulationReplay.verify(scene: unreviewed.current.scenes[0]))
    }
    func testEveryRuleInputChangeInvalidatesOldRecordingAndCannotReuseOldTrueFlag() throws {
        let original = try recordedScene()
        for index in 0..<7 {
            var changed = original
            switch index {
            case 0: changed.simulation.seed += 1
            case 1: changed.simulation.unit = "人"
            case 2: changed.simulation.initial = 4
            case 3: changed.simulation.capacity = 11
            case 4: changed.simulation.events[0].delta = 1
            case 5: changed.simulation.events[0].label = "改名"
            default: changed.simulation.events.swapAt(0, 1)
            }
            let edited = try apply([.replaceScene(changed.id, changed)], scene: original)
            let saved = edited.current.scenes[0]
            XCTAssertEqual(saved.simulationRecording, original.simulationRecording, "保留旧轨迹供对照")
            XCTAssertEqual(saved.simulationRecordingConfirmed, false)
            XCTAssertThrowsError(try SimulationReplay.verify(scene: saved))
            XCTAssertTrue(try issues(edited.current).contains { $0.id.hasSuffix("simulation_recording") })
            XCTAssertThrowsError(try apply([.confirmSimulationRecording(saved.id)], scene: saved))
            let rerecorded = try apply([.recordSimulation(saved.id), .confirmSimulationRecording(saved.id)], scene: saved)
            XCTAssertNoThrow(try SimulationReplay.verify(scene: rerecorded.current.scenes[0]))
        }
    }
    func testExactFrameRateAndDurationAreBoundEvenWhenLastTickDoesNotChange() throws {
        let original = try recordedScene()
        var duration = original; duration.durationFrames -= 1
        XCTAssertEqual((duration.durationFrames - 1) / 30, original.simulationRecording?.throughTick)
        XCTAssertThrowsError(try SimulationReplay.verify(scene: duration))
        XCTAssertThrowsError(try SimulationReplay.verify(scene: original, fps: 31))
        let edited = try apply([.replaceScene(duration.id, duration)], scene: original)
        XCTAssertEqual(edited.current.scenes[0].simulationRecordingConfirmed, false)
    }
    func testFastShortClipCannotRecordEventItsActualOutputNeverShows() throws {
        var scene = Scene(kind: .simulation, title: "快速规则", body: "最后一个事件必须真实出现在画面中", durationFrames: 31)
        scene.speed = 4; scene.simulation.events = [RuleEvent(tick: 1, delta: 5, label: "不可见的尾部事件")]
        XCTAssertEqual(scene.timelineFrames, 8)
        XCTAssertEqual(Int(Double(scene.timelineFrames - 1) * scene.speed), 28)
        XCTAssertThrowsError(try SimulationReplay.record(scene: scene))
        scene.pauseFrames = 1
        let paused = try SimulationReplay.record(scene: scene)
        XCTAssertEqual(scene.timelineFrames, 9); XCTAssertEqual(paused.recordedLastSourceFrame, 32)
        XCTAssertEqual(paused.throughTick, 1); XCTAssertEqual(paused.transitions.count, 1)
        scene.simulationRecording = paused; scene.simulationRecordingConfirmed = true
        XCTAssertNoThrow(try SimulationReplay.verify(scene: scene))
        scene.durationFrames = 1; scene.pauseFrames = 0
        XCTAssertThrowsError(try SimulationReplay.record(scene: scene), "没有可见帧的规则片段不能录制")
    }
    func testSpeedAndPauseChangesCannotReuseReviewedRecording() throws {
        let original = try recordedScene()
        for index in 0..<2 {
            var changed = original
            if index == 0 {changed.speed = 0.5} else {changed.pauseFrames = 30}
            XCTAssertThrowsError(try SimulationReplay.verify(scene: changed))
            let saved = try apply([.replaceScene(changed.id, changed)], scene: original).current.scenes[0]
            XCTAssertEqual(saved.simulationRecordingConfirmed, false)
        }
    }
    func testLateEventsAndPartialOrTamperedRecordingsCannotBeAccepted() throws {
        var scene = try recordedScene(); scene.simulation.events.append(RuleEvent(tick: 6, delta: 1, label: "镜头外"))
        XCTAssertThrowsError(try SimulationReplay.record(scene: scene))
        scene.durationFrames = 181
        XCTAssertEqual(try SimulationReplay.record(scene: scene).transitions.count, 4)
        scene = try recordedScene()
        scene.simulationRecording = try SimulationReplay.record(simulation: scene.simulation, throughTick: 1)
        XCTAssertThrowsError(try SimulationReplay.verify(scene: scene))
        scene = try recordedScene(); scene.simulationRecording?.transitions[0].after = 1
        XCTAssertThrowsError(try SimulationReplay.verify(scene: scene))
        scene = try recordedScene(); scene.simulationRecording?.recordedFPS = 31
        XCTAssertThrowsError(try SimulationReplay.verify(scene: scene))
    }
    func testUnrelatedTextAndArtworkIdentityChangesPreserveReviewedRuleTrace() throws {
        let original = try recordedScene(); var changed = original
        changed.body = "修正讲解文字"; changed.character = "选择另一个有来源角色"
        let saved = try apply([.replaceScene(changed.id, changed)], scene: original).current.scenes[0]
        XCTAssertEqual(saved.simulationRecording, original.simulationRecording)
        XCTAssertEqual(saved.simulationRecordingConfirmed, true)
        XCTAssertNoThrow(try SimulationReplay.verify(scene: saved))
    }
    func testSplitAndLockedScenesCannotKeepOrRewriteReviewedRecording() throws {
        var scene = try recordedScene()
        let split = try apply([.splitScene(scene.id, 90)], scene: scene)
        XCTAssertEqual(split.current.scenes.count, 2)
        for piece in split.current.scenes {
            XCTAssertEqual(piece.simulationRecordingConfirmed, false)
            XCTAssertThrowsError(try SimulationReplay.verify(scene: piece))
        }
        scene.locked = true
        XCTAssertThrowsError(try apply([.recordSimulation(scene.id)], scene: scene))
        XCTAssertThrowsError(try apply([.confirmSimulationRecording(scene.id)], scene: scene))
    }
}
