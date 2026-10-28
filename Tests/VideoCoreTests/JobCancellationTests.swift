import XCTest
import VideoCore

final class JobCancellationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func job(provider: String = "native") throws -> Job {
        let product = Product(workspaceID: "w", sku: "s", name: "规则测试", checkout: "https://example.com", audience: "初学者", task: "复现", outcome: "能操作", prerequisite: "自备工具", scope: "规则测试", prices: [Price(money: Money(99), source: "规则测试", verified: true)])
        let project = Project(workspaceID: "w", name: "取消规则", revision: Revision(product: product, purpose: .education, aspect: .portrait, scenes: [Scene(title: "完整", body: "内容")], cta: ""))
        let digest = try project.current.contentDigest()
        let quote = Quote(projectID: project.id, revisionID: project.current.id, digest: digest, upper: Money(90), unit: "CNY", provider: provider, expiresAt: now.addingTimeInterval(1000), confirmed: true)
        var result = Job(workspaceID: "w", projectID: project.id, revisionID: project.current.id, digest: digest, requestKey: "cancel-original", quote: quote)
        result.createdAt = now
        result.updatedAt = now
        return result
    }

    private func artifacts(for job: Job) -> [Artifact] {
        [("video.mp4", "video/mp4"), ("cover.png", "image/png"), ("subtitles.srt", "application/x-subrip"), ("source.txt", "text/plain")].map {
            Artifact(path: $0.0, mime: $0.1, bytes: 8, sha256: Codec.hash(Data($0.0.utf8)), revision: job.revisionID)
        }
    }

    private func completedRemote(state:JobState)throws->Job {
        var completed=try job(provider:"remote")
        completed.state=state;completed.progress=1;completed.remoteID="original-service-id"
        completed.remoteCheckedAt=now;completed.remoteObservationSequence=3
        completed.artifacts=artifacts(for:completed);completed.outputAssetIDs=["original-output"]
        for record in [
            BillingRecord(id:"charge",kind:.charge,money:Money(12),source:"隔离规则消耗凭据",at:now),
            BillingRecord(id:"refund-request",kind:.refundRequested,money:Money(5),source:"隔离规则申请凭据",at:now),
            BillingRecord(id:"refund-received",kind:.refundReceived,money:Money(3),source:"隔离规则到账凭据",at:now)
        ] {completed=try JobOperations.reconcile(completed,record:record)}
        completed.remoteReportedActual=Money(12);completed.billingUnknown=true
        return completed
    }

    func testCancellationFinalStateUsesTheExistingCompletedAndCancelledBoundary() {
        for state in [JobState.queued,.running,.needsReview,.succeeded,.failed,.interrupted,.cancelRequested,.cancelled,.unknownRemote,.billingPending] {
            XCTAssertEqual(state.isCancellationFinal,[JobState.needsReview,.succeeded,.cancelled].contains(state),state.rawValue)
        }
    }

    func testNewRemoteObservationsKeepCompletedOutputFactsAndPartialRefundLedger()throws {
        for state in [JobState.needsReview,.succeeded] {
            let original=try completedRemote(state:state)
            for observed in [RemoteSnapshot.State.queued,.running,.unknown,.succeeded,.failed,.cancelled] {
                let checked=now.addingTimeInterval(2)
                let snapshot=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:observed,progress:0.2,actual:Money(7),checkedAt:checked)
                let serial=try JobOperations.applyRemote(snapshot,to:original,now:checked)
                let updated=try JobOperations.applyRemote(snapshot,to:original,observing:original,now:checked)
                XCTAssertEqual(serial.state,state);XCTAssertEqual(serial.progress,1)
                XCTAssertEqual(try Codec.data(serial.artifacts),try Codec.data(original.artifacts))
                XCTAssertEqual(try Codec.data(serial.billing),try Codec.data(original.billing))
                XCTAssertEqual(serial.actual,Money(9));XCTAssertEqual(serial.refundPending,Money(2))
                XCTAssertEqual(serial.remoteReportedActual,Money(12));XCTAssertTrue(serial.billingUnknown)
                XCTAssertEqual(serial.remoteCheckedAt,checked)
                XCTAssertEqual(serial.remoteObservationSequence,original.remoteObservationSequence)
                XCTAssertEqual(updated.state,state);XCTAssertEqual(updated.progress,1)
                XCTAssertEqual(updated.remoteID,original.remoteID);XCTAssertEqual(updated.requestKey,original.requestKey)
                XCTAssertEqual(updated.revisionID,original.revisionID);XCTAssertEqual(updated.digest,original.digest)
                XCTAssertEqual(updated.remoteCheckedAt,checked);XCTAssertEqual(updated.remoteObservationSequence,4)
                XCTAssertEqual(try Codec.data(updated.artifacts),try Codec.data(original.artifacts))
                XCTAssertEqual(updated.outputAssetIDs,original.outputAssetIDs)
                XCTAssertEqual(try Codec.data(updated.quote),try Codec.data(original.quote))
                XCTAssertEqual(try Codec.data(updated.billing),try Codec.data(original.billing))
                XCTAssertEqual(updated.actual,Money(9));XCTAssertEqual(updated.refundPending,Money(2))
                XCTAssertEqual(updated.remoteReportedActual,Money(12));XCTAssertTrue(updated.billingUnknown)
                XCTAssertEqual(updated.exposure,original.exposure)
                XCTAssertTrue(updated.message.contains("原产物及审核状态保持"))
            }
        }
    }

    func testCompletedRemoteTerminalNetConfirmationSettlesAccountingWithoutUndoingReview()throws {
        let original=try completedRemote(state:.succeeded),checked=now.addingTimeInterval(2)
        let snapshot=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.succeeded,progress:1,actual:Money(9),checkedAt:checked)
        let serial=try JobOperations.applyRemote(snapshot,to:original,now:checked)
        let updated=try JobOperations.applyRemote(snapshot,to:original,observing:original,now:checked)
        XCTAssertEqual(serial.state,.succeeded);XCTAssertEqual(serial.progress,1)
        XCTAssertFalse(serial.billingUnknown);XCTAssertEqual(serial.actual,Money(9));XCTAssertEqual(serial.refundPending,Money(2))
        XCTAssertEqual(try Codec.data(serial.billing),try Codec.data(original.billing))
        XCTAssertEqual(updated.state,.succeeded);XCTAssertEqual(updated.remoteReportedActual,Money(9))
        XCTAssertFalse(updated.billingUnknown);XCTAssertEqual(updated.actual,Money(9));XCTAssertEqual(updated.refundPending,Money(2))
        XCTAssertEqual(try Codec.data(updated.billing),try Codec.data(original.billing))
        XCTAssertEqual(try Codec.data(updated.artifacts),try Codec.data(original.artifacts))
        XCTAssertEqual(updated.remoteObservationSequence,4);XCTAssertEqual(updated.remoteCheckedAt,checked)
    }

    func testCompletedRemoteUnknownCostRemainsUnknownInsteadOfInventingZero()throws {
        var original=try completedRemote(state:.needsReview)
        original.billing=nil;original.actual=nil;original.refundPending=nil
        let checked=now.addingTimeInterval(2)
        let snapshot=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.unknown,progress:0,checkedAt:checked)
        let serial=try JobOperations.applyRemote(snapshot,to:original,now:checked)
        let updated=try JobOperations.applyRemote(snapshot,to:original,observing:original,now:checked)
        XCTAssertEqual(serial.state,.needsReview);XCTAssertEqual(serial.progress,1)
        XCTAssertNil(serial.actual);XCTAssertTrue(serial.billingUnknown);XCTAssertEqual(serial.remoteReportedActual,Money(12))
        XCTAssertEqual(updated.state,.needsReview);XCTAssertEqual(updated.progress,1)
        XCTAssertNil(updated.actual);XCTAssertNil(updated.refundPending);XCTAssertTrue(updated.billingUnknown)
        XCTAssertEqual(updated.remoteReportedActual,Money(12));XCTAssertEqual(updated.exposure,original.exposure)
        XCTAssertEqual(try Codec.data(updated.artifacts),try Codec.data(original.artifacts))
    }

    func testCompletedRemoteLowerNonterminalReportsCannotEraseSeenSpendWithoutARefundReceipt()throws {
        for state in [JobState.needsReview,.succeeded] {
            var original=try completedRemote(state:state)
            original.billing=nil;original.actual=Money(20);original.remoteReportedActual=Money(20);original.refundPending=nil
            for observed in [RemoteSnapshot.State.queued,.running,.unknown] {
                let checked=now.addingTimeInterval(2)
                let snapshot=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:observed,progress:0,actual:Money(0),checkedAt:checked)
                let serial=try JobOperations.applyRemote(snapshot,to:original,now:checked)
                let asynchronous=try JobOperations.applyRemote(snapshot,to:original,observing:original,now:checked)
                for updated in [serial,asynchronous] {
                    XCTAssertEqual(updated.state,state);XCTAssertEqual(updated.progress,1)
                    XCTAssertEqual(updated.actual,Money(20));XCTAssertEqual(updated.remoteReportedActual,Money(20))
                    XCTAssertTrue(updated.billingUnknown);XCTAssertNil(updated.refundPending)
                    XCTAssertTrue((updated.billing ?? []).isEmpty)
                    XCTAssertEqual(updated.exposure,original.exposure)
                    XCTAssertEqual(try Codec.data(updated.artifacts),try Codec.data(original.artifacts))
                }
            }
        }
    }

    func testCompletedNeedsReviewCancellationPreservesOriginalJobBytes() throws {
        let running = try JobOperations.claim(job(), owner: "normal-worker", now: now)
        let completed = try JobOperations.finish(running, token: XCTUnwrap(running.lease).token, artifacts: artifacts(for: running), now: now.addingTimeInterval(1))
        XCTAssertEqual(completed.state, .needsReview)
        XCTAssertEqual(completed.artifacts.count, 4)
        XCTAssertEqual(try Codec.data(JobRules.cancel(completed)), try Codec.data(completed))
    }

    func testSucceededCancellationPreservesArtifactsCashRefundAndLease() throws {
        var completed = try job(provider: "remote")
        // Isolated domain input; this does not grant any runtime media approval.
        completed.state = .succeeded
        completed.progress = 1
        completed.remoteID = "original-service-id"
        completed.remoteCheckedAt = now
        completed.remoteObservationSequence = 3
        completed.artifacts = artifacts(for: completed)
        completed.outputAssetIDs = ["original-output"]
        completed.actual = Money(9)
        completed.remoteReportedActual = Money(12)
        completed.refundPending = Money(2)
        completed.billingUnknown = true
        completed.billing = [BillingRecord(id: "original-charge", kind: .charge, money: Money(12), source: "隔离账单规则输入", at: now)]
        completed.lease = try JobOperations.claim(job(), owner: "original-worker", now: now).lease
        completed.message = "原成片与待核费用分别保留"
        XCTAssertEqual(try Codec.data(JobRules.cancel(completed)), try Codec.data(completed))
    }

    func testConfirmedCancellationIsByteIdempotentForLocalAndRemoteJobs() throws {
        for provider in ["native", "remote"] {
            var cancelled = try job(provider: provider)
            cancelled.state = .cancelled
            cancelled.remoteID = provider == "native" ? nil : "confirmed-cancelled-id"
            cancelled.actual = Money(provider == "native" ? 0 : 12)
            cancelled.refundPending = provider == "native" ? nil : Money(3)
            cancelled.message = "原取消结果；费用独立核对"
            let bytes = try Codec.data(cancelled)
            let first = JobRules.cancel(cancelled)
            XCTAssertEqual(try Codec.data(first), bytes, provider)
            XCTAssertEqual(try Codec.data(JobRules.cancel(first)), bytes, provider)
        }
    }

    func testActiveLocalCancellationStillStopsOriginalWorkerWithPartialArtifacts() throws {
        let running = try JobOperations.claim(job(), owner: "original-worker", now: now)
        for state in [JobState.queued, .running, .interrupted] {
            var active = running
            active.state = state
            active.artifacts = [artifacts(for: active)[0]]
            let cancelled = JobRules.cancel(active)
            XCTAssertEqual(cancelled.state, .cancelled)
            XCTAssertEqual(cancelled.id, active.id)
            XCTAssertEqual(cancelled.actual, Money(0))
            XCTAssertFalse(cancelled.billingUnknown)
            XCTAssertEqual(try Codec.data(cancelled.artifacts), try Codec.data(active.artifacts))
            XCTAssertThrowsError(try JobOperations.finish(cancelled, token: XCTUnwrap(running.lease).token, artifacts: artifacts(for: active), now: now.addingTimeInterval(1)))
        }
    }

    func testUnresolvedRemoteCancellationWithPartialArtifactsStillRequestsConfirmation() throws {
        for state in [JobState.queued, .running, .interrupted, .unknownRemote, .failed, .billingPending] {
            var active = try job(provider: "remote")
            active.state = state
            active.remoteID = "original-service-id"
            active.artifacts = [artifacts(for: active)[0]]
            active.actual = Money(12)
            active.refundPending = Money(3)
            active.billingUnknown = true
            active.billing = [BillingRecord(id: "charge", kind: .charge, money: Money(12), source: "隔离账单规则输入", at: now)]
            let cancelled = JobRules.cancel(active)
            XCTAssertEqual(cancelled.state, .cancelRequested, state.rawValue)
            XCTAssertEqual(cancelled.id, active.id)
            XCTAssertEqual(cancelled.remoteID, active.remoteID)
            XCTAssertEqual(cancelled.actual, active.actual)
            XCTAssertEqual(cancelled.refundPending, active.refundPending)
            XCTAssertTrue(cancelled.billingUnknown)
            XCTAssertEqual(try Codec.data(cancelled.artifacts), try Codec.data(active.artifacts))
            XCTAssertEqual(try Codec.data(cancelled.billing), try Codec.data(active.billing))
        }
    }

    func testUnknownRemoteWithoutReturnedIDStillRequestsCancellation() throws {
        var active = try job(provider: "remote")
        active.state = .unknownRemote
        active.attempt = 1
        XCTAssertNil(active.remoteID)
        let cancelled = JobRules.cancel(active)
        XCTAssertEqual(cancelled.state, .cancelRequested)
        XCTAssertNil(cancelled.actual)
        XCTAssertTrue(cancelled.billingUnknown)
        XCTAssertEqual(cancelled.requestKey, active.requestKey)
    }

    func testActiveBaiduCancellationRemainsUnsupportedAndKeepsCost() throws {
        var active = try job(provider: "baidu-service")
        active.state = .running
        active.videoGeneration = VideoGenerationReceipt(inputDigest: String(repeating: "a", count: 64), now: now)
        active.remoteID = "1234567890"
        active.actual = Money(12)
        active.refundPending = Money(3)
        let cancelled = JobRules.cancel(active)
        XCTAssertEqual(cancelled.state, active.state)
        XCTAssertEqual(cancelled.remoteID, active.remoteID)
        XCTAssertEqual(cancelled.videoGeneration, active.videoGeneration)
        XCTAssertEqual(cancelled.actual, active.actual)
        XCTAssertEqual(cancelled.refundPending, active.refundPending)
        XCTAssertTrue(cancelled.billingUnknown)
        XCTAssertTrue(cancelled.message.contains("无取消接口"))
    }
}
