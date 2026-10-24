import XCTest
import VideoCore
@testable import VideoMedia

final class LocalJobKeepaliveTests: XCTestCase {
    private struct Fixture {
        let repository: Repository
        let job: Job
        let invocation: RenderInvocation
        let generation: Int
        var token: String { job.lease!.token }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-keepalive-" + Codec.id())
        let repository = try Repository(root: root)
        let workspace = Workspace(name: "本地续租", owner: "owner")
        let revision = try Planner.create(workspaceID: workspace.id, name: "冻结工程", scenes: [Scene(title: "比较", body: "比较决策前后的结果", durationFrames: 30)])
        let project = Project(workspaceID: workspace.id, name: "冻结工程", revision: revision)
        let quote = Quote(projectID: project.id, revisionID: revision.id, digest: try revision.contentDigest(), upper: Money(0), unit: "CNY", provider: "native", expiresAt: Date().addingTimeInterval(300), confirmed: true)
        let queued = try JobRules.submit(workspaceID: workspace.id, project: project, quote: quote, requestKey: "same-original-job", existing: [], budget: BudgetPolicy())
        var job = try JobOperations.claim(queued, owner: "local-worker")
        job.progress = 0.9887
        try repository.transaction { $0.workspaces = [workspace]; $0.projects = [project]; $0.jobs = [job] }
        let invocation = try RenderInvocation.job(repository: repository, claimed: job, revision: revision, token: job.lease!.token, cancellation: RenderCancellation())
        return Fixture(repository: repository, job: job, invocation: invocation, generation: try repository.read().generation)
    }

    private func waitUntil(_ predicate: () throws -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !predicate() {
            guard Date() < deadline else { throw VideoError.unavailable("有界续租测试等待超时") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func assertRevocationStops(_ mutate: (inout Job) throws -> Void, file: StaticString = #filePath, line: UInt = #line) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.repository.root) }
        let keepalive = try LocalJobKeepalive(repository: f.repository, invocation: f.invocation, token: f.token, interval: 0.01)
        do {
            try await waitUntil { try f.repository.read().generation > f.generation }
            try f.repository.transaction { try mutate(&$0.jobs[0]) }
            let changed = try f.repository.read()
            let changedDigest = try Codec.digest(changed.jobs[0])
            try await waitUntil { keepalive.failure != nil }
            let failure = await keepalive.stop()
            XCTAssertNotNil(failure, file: file, line: line)
            XCTAssertTrue(f.invocation.cancellation.isCancelled, file: file, line: line)
            let after = try f.repository.read()
            XCTAssertEqual(try Codec.digest(after.jobs[0]), changedDigest, "撤销后旧续租不得覆盖原任务", file: file, line: line)
            XCTAssertEqual(after.generation, changed.generation, "拒绝续租事务应回滚", file: file, line: line)
            try await Task.sleep(nanoseconds: 35_000_000)
            XCTAssertEqual(try f.repository.read().generation, changed.generation, "stop 返回后无后台写入", file: file, line: line)
        } catch {
            _ = await keepalive.stop()
            throw error
        }
    }

    func testSilentProgressRenewsNearExpiryWithoutChangingJobOrBudget() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.repository.root) }
        // ISO-8601 snapshots persist seconds; retain a real positive margin after serialization.
        try f.repository.transaction { $0.jobs[0].lease?.expiresAt = Date().addingTimeInterval(3) }
        let beforeRenewal = try f.repository.read()
        XCTAssertGreaterThan(beforeRenewal.jobs[0].lease!.expiresAt.timeIntervalSinceNow, 0)
        XCTAssertLessThanOrEqual(beforeRenewal.jobs[0].lease!.expiresAt.timeIntervalSinceNow, 3)
        let keepalive = try LocalJobKeepalive(repository: f.repository, invocation: f.invocation, token: f.token, interval: 0.01)
        do {
            try await waitUntil { try f.repository.read().generation > beforeRenewal.generation }
            let renewed = try f.repository.read().jobs[0]
            XCTAssertEqual(renewed.id, f.job.id)
            XCTAssertEqual(renewed.attempt, f.job.attempt)
            XCTAssertEqual(renewed.progress, f.job.progress)
            XCTAssertEqual(renewed.lease?.token, f.token)
            XCTAssertEqual(renewed.quote.id, f.job.quote.id)
            XCTAssertEqual(renewed.quote.upper, f.job.quote.upper)
            XCTAssertEqual(renewed.lease!.expiresAt.timeIntervalSince(renewed.lease!.heartbeat), 120, accuracy: 0.001)
            try f.invocation.check()
            let stopFailure = await keepalive.stop(); XCTAssertNil(stopFailure)
        } catch { _ = await keepalive.stop(); throw error }
    }

    func testStopJoinsBackgroundTaskAndDoesNotRenewAgain() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.repository.root) }
        let keepalive = try LocalJobKeepalive(repository: f.repository, invocation: f.invocation, token: f.token, interval: 0.01)
        do {
            try await waitUntil { try f.repository.read().generation > f.generation }
            let stopFailure = await keepalive.stop(); XCTAssertNil(stopFailure)
            let stopped = try f.repository.read()
            try await Task.sleep(nanoseconds: 60_000_000)
            let after = try f.repository.read()
            XCTAssertEqual(after.generation, stopped.generation)
            XCTAssertEqual(try Codec.digest(after.jobs[0]), try Codec.digest(stopped.jobs[0]))
            XCTAssertFalse(f.invocation.cancellation.isCancelled, "正常 join 不能撤销仍可完成的渲染范围")
            try f.invocation.check()
        } catch { _ = await keepalive.stop(); throw error }
    }

    func testCompletedJobCannotBeRenewedOrReopened() async throws {
        try await assertRevocationStops { job in
            job = try JobOperations.finish(job, token: job.lease!.token, artifacts: [Artifact(path: "exports/result.png", mime: "image/png", bytes: 1, sha256: String(repeating: "a", count: 64), revision: job.revisionID)])
        }
    }

    func testCancelledJobCannotBeRenewedOrReopened() async throws {
        try await assertRevocationStops { $0 = JobRules.cancel($0) }
    }

    func testFailedJobCannotBeRenewedOrReopened() async throws {
        try await assertRevocationStops { $0.state = .failed; $0.lease = nil }
    }

    func testReclaimedJobKeepsNewTokenAndAttempt() async throws {
        try await assertRevocationStops { job in
            job.lease?.expiresAt = Date().addingTimeInterval(-1)
            job = JobOperations.recoverExpired(job)
            job = try JobRules.recover(job)
            job = try JobOperations.claim(job, owner: "replacement-worker")
        }
    }

    func testExpiredLeaseCannotBeRevived() async throws {
        try await assertRevocationStops { $0.lease?.expiresAt = Date().addingTimeInterval(-1) }
    }

    func testChangedBudgetCannotBeRenewed() async throws {
        try await assertRevocationStops { $0.quote.upper = Money(1) }
    }

    func testChangedBudgetReferenceCannotBeRenewed() async throws {
        try await assertRevocationStops { $0.quote.id = Codec.id() }
    }

    func testCancelledInvocationStopsRenewalWithoutChangingJob() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.repository.root) }
        let keepalive = try LocalJobKeepalive(repository: f.repository, invocation: f.invocation, token: f.token, interval: 0.01)
        do {
            try await waitUntil { try f.repository.read().generation > f.generation }
            // Synchronize cancellation with the same database lock as renewal.
            try f.repository.transaction { _ in f.invocation.cancellation.cancel() }
            let cancelled = try f.repository.read()
            try await waitUntil { keepalive.failure != nil }
            let stopFailure = await keepalive.stop(); XCTAssertNotNil(stopFailure)
            let after = try f.repository.read()
            XCTAssertEqual(after.generation, cancelled.generation)
            XCTAssertEqual(try Codec.digest(after.jobs[0]), try Codec.digest(cancelled.jobs[0]))
        } catch { _ = await keepalive.stop(); throw error }
    }

    func testMismatchedTokenFailsClosedWithoutWriting() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.repository.root) }
        let before = try f.repository.read()
        let keepalive = try LocalJobKeepalive(repository: f.repository, invocation: f.invocation, token: "different-token", interval: 0.01)
        do {
            try await waitUntil { keepalive.failure != nil }
            let stopFailure = await keepalive.stop(); XCTAssertNotNil(stopFailure)
            XCTAssertTrue(f.invocation.cancellation.isCancelled)
            XCTAssertEqual(try f.repository.read().generation, before.generation)
            XCTAssertEqual(try Codec.digest(f.repository.read().jobs[0]), try Codec.digest(before.jobs[0]))
        } catch { _ = await keepalive.stop(); throw error }
    }
}
