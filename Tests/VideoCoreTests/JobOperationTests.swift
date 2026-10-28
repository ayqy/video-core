import XCTest
import VideoCore

final class JobOperationTests: XCTestCase {
    func project() -> Project {
        let p=Product(workspaceID:"w",sku:"s",name:"课程",checkout:"https://example.com",audience:"初学者",task:"复现",outcome:"能操作",prerequisite:"自备工具",scope:"边界",prices:[Price(money:Money(99),source:"原页",verified:true)])
        return Project(workspaceID:"w",name:"演示",revision:Revision(product:p,purpose:.course,aspect:.portrait,scenes:[Scene(title:"完整",body:"内容")],cta:"了解已有课程"))
    }
    func job(provider: String = "native") throws -> Job { let p=project(); return Job(workspaceID:"w",projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),requestKey:"once",quote:Quote(projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),upper:Money(90),unit:"CNY",provider:provider,expiresAt:Date().addingTimeInterval(1000),confirmed:true)) }
    private func localResumeFixture() throws -> (Database, Project, Job) {
        var database = Database(), workspace = Workspace(name: "本机", owner: "owner")
        workspace.id = "w"
        let project = project(), digest = try project.current.contentDigest()
        let quote = Quote(projectID: project.id, revisionID: project.current.id, digest: digest,
                          upper: Money(0), unit: "CNY", provider: "native",
                          expiresAt: Date().addingTimeInterval(-100), confirmed: true)
        let job = Job(workspaceID: "w", projectID: project.id, revisionID: project.current.id,
                      digest: digest, requestKey: "original-local-key", quote: quote)
        database.workspaces = [workspace]; database.projects = [project]; database.jobs = [job]
        return (database, project, job)
    }
    func testLocalQueuedResumePreservesOriginalJobAndExpiredFrozenQuote() throws {
        var (database, project, original) = try localResumeFixture()
        let before = try Codec.data(database.jobs)
        let resumed = try JobRules.resumeLocal(observing: original, in: &database, workspaceID: "w",
                                              projectID: project.id, revisionID: project.current.id, principal: "owner")
        XCTAssertEqual(try Codec.data(resumed), try Codec.data(original))
        XCTAssertEqual(try Codec.data(database.jobs), before)
        XCTAssertEqual(resumed.id, original.id); XCTAssertEqual(resumed.requestKey, original.requestKey)
    }
    func testLocalFailedAndInterruptedResumeUsesFreshOriginalWithoutNewSubmission() throws {
        for state in [JobState.failed, .interrupted] {
            var (database, project, original) = try localResumeFixture()
            original.state = state; original.attempt = 2; original.progress = 0.4
            database.jobs = [original]
            let resumed = try JobRules.resumeLocal(observing: original, in: &database, workspaceID: "w",
                                                  projectID: project.id, revisionID: project.current.id, principal: "owner")
            XCTAssertEqual(resumed.state, .queued); XCTAssertNil(resumed.lease)
            XCTAssertEqual(resumed.id, original.id); XCTAssertEqual(resumed.attempt, 2)
            XCTAssertEqual(resumed.requestKey, original.requestKey)
            XCTAssertEqual(try Codec.data(resumed.quote), try Codec.data(original.quote))
            XCTAssertEqual(database.jobs.count, 1); XCTAssertEqual(database.projects[0].current.id, project.current.id)
        }
    }
    func testLocalResumeRejectsLateLifecycleAndEveryFrozenQuoteChange() throws {
        let (base, project, original) = try localResumeFixture()
        let newLease = try observedLease(now: Date(), owner: "new-worker")
        let mutations: [(inout Job) -> Void] = [
            { $0.id = Codec.id() }, { $0.workspaceID = "other" }, { $0.projectID = "other" },
            { $0.revisionID = "other" }, { $0.digest = "other" }, { $0.requestKey = "other" },
            { $0.createdAt = $0.createdAt.addingTimeInterval(1) },
            { $0.quote.id = Codec.id() }, { $0.quote.projectID = "other" }, { $0.quote.revisionID = "other" },
            { $0.quote.digest = "other" }, { $0.quote.provider = "remote" }, { $0.quote.upper = Money(1) },
            { $0.quote.unit = "USD" }, { $0.quote.expiresAt = $0.quote.expiresAt.addingTimeInterval(1) },
            { $0.quote.attempts += 1 }, { $0.quote.confirmed = false },
            { $0.quote.createdAt = $0.quote.createdAt.addingTimeInterval(1) },
            { $0.quote.breakdown = EstimateBreakdown(version: "changed", specification: "changed", source: "原价表", validFrom: Date(), expiresAt: Date(), lines: [], excluded: []) },
            { $0.state = .cancelled }, { $0.state = .needsReview }, { $0.state = .succeeded },
            { $0.state = .running }, { $0.attempt += 1 }, { $0.progress = 0.5 },
            { $0.updatedAt = $0.updatedAt.addingTimeInterval(1) },
            { $0.lease = newLease },
            { $0.outputAssetIDs = ["new-output"] }
        ]
        for (index, mutation) in mutations.enumerated() {
            var database = base; mutation(&database.jobs[0])
            let before = try Codec.data(database)
            XCTAssertThrowsError(try JobRules.resumeLocal(observing: original, in: &database, workspaceID: "w",
                projectID: project.id, revisionID: project.current.id, principal: "owner"), "mutation \(index)")
            XCTAssertEqual(try Codec.data(database), before, "mutation \(index)")
        }
    }
    func testLocalResumeRechecksCurrentOwnerAndCurrentProjectDigest() throws {
        let (base, project, original) = try localResumeFixture()
        var otherOwner = base; otherOwner.workspaces[0].owner = "new-owner"
        XCTAssertThrowsError(try JobRules.resumeLocal(observing: original, in: &otherOwner, workspaceID: "w",
            projectID: project.id, revisionID: project.current.id, principal: "owner"))
        var edited = base; edited.projects[0].revisions[0].scenes[0].body = "已变化"
        XCTAssertThrowsError(try JobRules.resumeLocal(observing: original, in: &edited, workspaceID: "w",
            projectID: project.id, revisionID: project.current.id, principal: "owner"))
        var missing = base; missing.projects = []
        XCTAssertThrowsError(try JobRules.resumeLocal(observing: original, in: &missing, workspaceID: "w",
            projectID: project.id, revisionID: project.current.id, principal: "owner"))
    }
    private func partialRefundJob()throws->Job {
        var j=try job(provider:"remote");j.remoteID="original";j.state = .cancelled
        j.createdAt=Date(timeIntervalSince1970:1_700_000_000);j.updatedAt=j.createdAt
        let events:[(String,BillingRecord.Kind,Decimal,String)]=[("charge",.charge,12,"消耗凭据"),("requested",.refundRequested,5,"退款申请凭据"),("received",.refundReceived,3,"退款到账凭据")]
        for (index,event) in events.enumerated(){j=try JobOperations.reconcile(j,record:BillingRecord(id:event.0,kind:event.1,money:Money(event.2),source:event.3,at:j.createdAt.addingTimeInterval(Double(index+1))))}
        return j
    }
    private func report(_ amount:Money?,to job:Job,state:RemoteSnapshot.State = .cancelled)throws->Job {
        let checkedAt=(job.remoteCheckedAt ?? job.updatedAt).addingTimeInterval(1)
        return try JobOperations.applyRemote(RemoteSnapshot(remoteID:"original",requestKey:job.requestKey,state:state,progress:0.5,actual:amount,checkedAt:checkedAt),to:job,now:checkedAt)
    }
    private func observedRemoteFixture()throws->(Job,Date) {
        let now=Date(timeIntervalSince1970:Date().timeIntervalSince1970.rounded(.down))
        var j=try job(provider:"remote");j.remoteID="original";j.state = .running;j.progress=0.7
        j.createdAt=now.addingTimeInterval(-10);j.updatedAt=now;j.quote.upper=Money(9)
        return(j,now)
    }
    private func observedLease(now:Date,owner:String)throws->WorkerLease {
        let local=try JobOperations.claim(job(),owner:owner,now:now,ttl:100)
        return try XCTUnwrap(local.lease)
    }
    func testObservedRemoteSequenceSupportsLegacyJobsAndRejectsSameSecondStaleReply()throws {
        let(original,now)=try observedRemoteFixture()
        let data=try Codec.data(original),decoded=try Codec.decoder().decode(Job.self,from:data)
        XCTAssertNil((try JSONSerialization.jsonObject(with:data) as? [String:Any])?["remoteObservationSequence"])
        XCTAssertNil(decoded.remoteObservationSequence)
        let intent=try JobOperations.requestRemoteCancellation(decoded,observing:decoded)
        XCTAssertEqual(intent.state,.cancelRequested);XCTAssertNil(intent.remoteObservationSequence)
        let response=RemoteSnapshot(remoteID:"original",requestKey:original.requestKey,state:.cancelled,progress:0.7,actual:Money(7),checkedAt:now)
        XCTAssertThrowsError(try JobOperations.applyRemote(response,to:intent,observing:decoded,now:now))
        let first=try JobOperations.applyRemote(response,to:decoded,observing:decoded,now:now)
        XCTAssertEqual(first.remoteObservationSequence,1)
        let old=RemoteSnapshot(remoteID:"original",requestKey:original.requestKey,state:.failed,progress:0,actual:Money(0),checkedAt:now)
        XCTAssertThrowsError(try JobOperations.applyRemote(old,to:first,observing:decoded,now:now))
        let next=try JobOperations.applyRemote(response,to:first,observing:first,now:now)
        XCTAssertEqual(next.remoteObservationSequence,2);XCTAssertEqual(next.remoteID,original.remoteID)
        XCTAssertEqual(next.actual,Money(7));XCTAssertEqual(next.state,.cancelled)
        XCTAssertEqual(try Codec.decoder().decode(Job.self,from:Codec.data(next)).remoteObservationSequence,2)
    }
    func testObservedRemoteResponseBindsOriginalJobAndEveryFrozenQuoteField()throws {
        let(current,now)=try observedRemoteFixture()
        let response=RemoteSnapshot(remoteID:"original",requestKey:current.requestKey,state:.running,progress:0.8,checkedAt:now)
        let mutations:[(inout Job)->Void]=[
            {$0.id=Codec.id()},{$0.workspaceID="other"},{$0.projectID="other"},{$0.revisionID="other"},
            {$0.digest="other"},{$0.requestKey="other"},{$0.remoteID="other"},{$0.remoteID=nil},
            {$0.createdAt=$0.createdAt.addingTimeInterval(1)},{$0.quote.id=Codec.id()},
            {$0.quote.projectID="other"},{$0.quote.revisionID="other"},{$0.quote.digest="other"},
            {$0.quote.provider="other"},{$0.quote.upper=Money(88,"USD")},{$0.quote.unit="points"},
            {$0.quote.expiresAt=$0.quote.expiresAt.addingTimeInterval(1)},{$0.quote.attempts += 1},
            {$0.quote.confirmed.toggle()},{$0.quote.createdAt=$0.quote.createdAt.addingTimeInterval(1)},
            {$0.quote.breakdown=EstimateBreakdown(version:"changed",specification:"changed",source:"本地规则",validFrom:now,expiresAt:now.addingTimeInterval(100),lines:[],excluded:[])},
            {$0.videoGeneration=VideoGenerationReceipt(inputDigest:String(repeating:"a",count:64))}
        ]
        for (index,mutation) in mutations.enumerated() {
            var unrelated=current;mutation(&unrelated)
            XCTAssertThrowsError(try JobOperations.applyRemote(response,to:current,observing:unrelated,now:now),"identity \(index)")
        }
    }
    func testObservedRemoteRejectsInvalidVersionOrChangedLifecycleLeaseAndOutputs()throws {
        let(original,now)=try observedRemoteFixture()
        let otherLease=try observedLease(now:now,owner:"other")
        let response=RemoteSnapshot(remoteID:"original",requestKey:original.requestKey,state:.unknown,progress:0.4,checkedAt:now)
        let mutations:[(inout Job)->Void]=[
            {$0.remoteObservationSequence=1},{$0.state = .cancelRequested},{$0.progress=0.8},
            {$0.remoteCheckedAt=now},{$0.remoteReportedActual=Money(1)},
            {$0.lease=otherLease},
            {$0.artifacts=[Artifact(path:"local.txt",mime:"text/plain",bytes:1,sha256:String(repeating:"a",count:64),revision:$0.revisionID)]},
            {$0.outputAssetIDs=["new-local-output"]}
        ]
        for (index,mutation) in mutations.enumerated() {
            var live=original;mutation(&live)
            XCTAssertThrowsError(try JobOperations.applyRemote(response,to:live,observing:original,now:now),"observation \(index)")
        }
        for invalid in [-1,Int.max] {
            var live=original;live.remoteObservationSequence=invalid
            XCTAssertThrowsError(try JobOperations.applyRemote(response,to:live,observing:live,now:now))
            XCTAssertThrowsError(try JobOperations.applyRemote(response,to:original,observing:live,now:now))
            XCTAssertThrowsError(try JobOperations.requestRemoteCancellation(live,observing:live))
        }
        var native=original;native.quote.provider="native"
        XCTAssertThrowsError(try JobOperations.requestRemoteCancellation(native,observing:native))
        var baidu=original;baidu.videoGeneration=VideoGenerationReceipt(inputDigest:String(repeating:"a",count:64))
        XCTAssertThrowsError(try JobOperations.requestRemoteCancellation(baidu,observing:baidu))
    }
    func testFreshNonterminalObservationKeepsCancellationAndUnreceiptedOverrun()throws {
        for local in [JobState.running,.cancelRequested,.cancelled] {
            for remote in [RemoteSnapshot.State.queued,.running,.unknown] {
                for reported in [nil,Money(0),Money(5)] as [Money?] {
                    var(original,now)=try observedRemoteFixture()
                    original.state=local;original.actual=Money(20);original.remoteReportedActual=Money(20)
                    original.remoteCheckedAt=now.addingTimeInterval(-1)
                    let response=RemoteSnapshot(remoteID:"original",requestKey:original.requestKey,state:remote,progress:0.1,actual:reported,checkedAt:now)
                    let updated=try JobOperations.applyRemote(response,to:original,observing:original,now:now)
                    XCTAssertEqual(updated.actual,Money(20));XCTAssertEqual(updated.remoteReportedActual,Money(20))
                    XCTAssertEqual(updated.exposure,Money(20));XCTAssertTrue(updated.billingUnknown)
                    XCTAssertTrue((updated.billing ?? []).isEmpty);XCTAssertNil(updated.refundPending)
                    XCTAssertEqual(updated.remoteObservationSequence,1)
                    if local == .cancelled {XCTAssertEqual(updated.state,.cancelled);XCTAssertEqual(updated.progress,original.progress)}
                    if local == .cancelRequested {XCTAssertEqual(updated.state,.cancelRequested)}
                }
            }
        }
        var(original,now)=try observedRemoteFixture();original.actual=Money(20);original.remoteReportedActual=Money(20)
        let final=try JobOperations.applyRemote(RemoteSnapshot(remoteID:"original",requestKey:original.requestKey,state:.cancelled,progress:0.7,actual:Money(7),checkedAt:now),to:original,observing:original,now:now)
        XCTAssertEqual(final.actual,Money(7));XCTAssertEqual(final.exposure,Money(7));XCTAssertFalse(final.billingUnknown)
    }
    func testObservedRemoteAllowsConcurrentLedgerWithoutLosingLeaseOrRefund()throws {
        var(original,now)=try observedRemoteFixture();original.state = .cancelRequested
        original.actual=Money(20);original.remoteReportedActual=Money(20)
        original.lease=try observedLease(now:now,owner:"original-worker")
        var live=original
        for event in [BillingRecord(id:"charge",kind:.charge,money:Money(12),source:"本地规则费用凭据",at:now),BillingRecord(id:"request",kind:.refundRequested,money:Money(5),source:"本地规则申请凭据",at:now.addingTimeInterval(1)),BillingRecord(id:"refund",kind:.refundReceived,money:Money(3),source:"本地规则到账凭据",at:now.addingTimeInterval(2))] {
            live=try JobOperations.reconcile(live,record:event)
        }
        let ledger=try Codec.data(live.billing),lease=try Codec.data(live.lease)
        let unknown=try JobOperations.applyRemote(RemoteSnapshot(remoteID:"original",requestKey:original.requestKey,state:.unknown,progress:0.3,actual:Money(0),checkedAt:now),to:live,observing:original,now:now)
        XCTAssertEqual(unknown.state,.cancelRequested);XCTAssertEqual(unknown.actual,Money(9));XCTAssertEqual(unknown.refundPending,Money(2))
        XCTAssertEqual(try Codec.data(unknown.billing),ledger);XCTAssertEqual(try Codec.data(unknown.lease),lease)
        XCTAssertEqual(unknown.remoteReportedActual,Money(20));XCTAssertEqual(unknown.exposure,Money(20));XCTAssertTrue(unknown.billingUnknown)
        let final=try JobOperations.applyRemote(RemoteSnapshot(remoteID:"original",requestKey:original.requestKey,state:.cancelled,progress:0.7,actual:Money(9),checkedAt:now),to:unknown,observing:unknown,now:now)
        XCTAssertEqual(final.remoteObservationSequence,2);XCTAssertEqual(final.state,.cancelled)
        XCTAssertEqual(final.actual,Money(9));XCTAssertEqual(final.refundPending,Money(2));XCTAssertFalse(final.billingUnknown)
        XCTAssertEqual(try Codec.data(final.billing),ledger);XCTAssertEqual(try Codec.data(final.lease),lease)
    }
    func testOriginalUnitDecimalEstimateAndExpiry() throws {
        let now=Date(); let d=EstimateBreakdown(version:"official-2026",specification:"720p 12段 每段一次+两次重试",source:"管理员核对的官方单价",validFrom:now.addingTimeInterval(-10),expiresAt:now.addingTimeInterval(100),lines:[RateLine(label:"镜头",quantity:1,unit:"段",price:Money(Decimal(string:"2.48")!),count:12,attempts:3)],excluded:["配音与人工不包含"])
        XCTAssertEqual(try d.total().amount,Decimal(string:"89.28")); let p=project();let q=try d.quote(project:p,provider:"supplier",confirmed:true,now:now); XCTAssertEqual(q.attempts,3)
        XCTAssertThrowsError(try d.validate(now:now.addingTimeInterval(101)))
        var mixed=d; mixed.lines.append(RateLine(label:"声音",quantity:1,unit:"秒",price:Money(1,"USD"))); XCTAssertThrowsError(try mixed.total())
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:q,requestKey:"x",existing:[],budget:BudgetPolicy(project:Money(20),month:Money(200)),now:now))
    }
    func testExpiredWorkerAndLateCompletionCannotOverwriteCancel() throws {
        let now=Date(); let j=try JobOperations.claim(job(),owner:"ui",now:now); let token=j.lease!.token
        XCTAssertThrowsError(try JobOperations.claim(j,owner:"cli",now:now))
        XCTAssertThrowsError(try JobOperations.heartbeat(j,token:"another",progress:0.5,now:now))
        let recovered=JobOperations.recoverExpired(j,now:now.addingTimeInterval(121)); XCTAssertEqual(recovered.state,.interrupted); XCTAssertEqual(recovered.id,j.id)
        let cancelled=JobRules.cancel(j)
        let artifact=Artifact(path:"/test",mime:"video/mp4",bytes:10,sha256:String(repeating:"a",count:64),revision:j.revisionID)
        XCTAssertThrowsError(try JobOperations.finish(cancelled,token:token,artifacts:[artifact],now:now))
    }
    func testSilentLessonCanKeepEmptySubtitleButNotAnEmptyVideo()throws {
        let now=Date(),j=try JobOperations.claim(job(),owner:"cli",now:Date())
        let subtitle=Artifact(path:"/captions.srt",mime:"application/x-subrip",bytes:0,sha256:Codec.hash(Data()),revision:j.revisionID)
        XCTAssertEqual(try JobOperations.finish(j,token:j.lease!.token,artifacts:[subtitle],now:now).state,.needsReview)
        var bad=subtitle;bad.mime="video/mp4";XCTAssertThrowsError(try JobOperations.finish(j,token:j.lease!.token,artifacts:[bad],now:now))
    }
    func testUnknownRemoteQueryUsesOriginalKeyAndDoesNotClaimSuccess() throws {
        var j=try job(provider:"remote"); j.state = .unknownRemote
        XCTAssertThrowsError(try JobOperations.claim(j,owner:"x"))
        let snapshot=RemoteSnapshot(remoteID:"r1",requestKey:j.requestKey,state:.succeeded,progress:1)
        j=try JobOperations.applyRemote(snapshot,to:j); XCTAssertEqual(j.state,.billingPending); XCTAssertTrue(j.billingUnknown); XCTAssertNil(j.actual)
        XCTAssertThrowsError(try JobOperations.applyRemote(RemoteSnapshot(remoteID:"r2",requestKey:j.requestKey,state:.running,progress:0.5),to:j))
        j=JobRules.cancel(j); XCTAssertEqual(j.state,.cancelRequested); XCTAssertTrue(j.billingUnknown)
    }
    func testLedgerIdempotencyAndRefundNeverErasesUnconfirmedCharge() throws {
        var j=try job(provider:"remote"); let charge=BillingRecord(id:"bill-1",kind:.charge,money:Money(12),source:"真实账单引用")
        j=try JobOperations.reconcile(j,record:charge); j=try JobOperations.reconcile(j,record:charge); XCTAssertEqual(j.billing?.count,1); XCTAssertEqual(j.actual?.amount,12)
        j=try JobOperations.reconcile(j,record:BillingRecord(id:"refund-request",kind:.refundRequested,money:Money(5),source:"申请回执")); XCTAssertEqual(j.actual?.amount,12); XCTAssertEqual(j.refundPending?.amount,5)
        j=try JobOperations.reconcile(j,record:BillingRecord(id:"refund-paid",kind:.refundReceived,money:Money(3),source:"到账凭据")); XCTAssertEqual(j.actual?.amount,9); XCTAssertEqual(j.refundPending?.amount,2)
        XCTAssertThrowsError(try JobOperations.reconcile(j,record:BillingRecord(id:"bill-1",kind:.charge,money:Money(11),source:"另一笔")))
        XCTAssertThrowsError(try JobOperations.reconcile(j,record:BillingRecord(id:"currency",kind:.charge,money:Money(1,"USD"),source:"币种不同")))
    }
    func testPartialRunningBillKeepsProjectAndMonthCommitmentReserved() throws {
        let p=project(),now=Date(),digest=try p.current.contentDigest()
        let frozen=Quote(projectID:p.id,revisionID:p.current.id,digest:digest,upper:Money(90),unit:"CNY",provider:"remote",expiresAt:now.addingTimeInterval(600),confirmed:true)
        let initial=Job(workspaceID:"w",projectID:p.id,revisionID:p.current.id,digest:digest,requestKey:"original",quote:frozen)
        let running=try JobOperations.applyRemote(RemoteSnapshot(remoteID:"supplier-original",requestKey:"original",state:.running,progress:0.5,actual:Money(12)),to:initial)
        XCTAssertEqual(running.actual?.amount,12)
        XCTAssertTrue(running.billingUnknown)
        XCTAssertEqual(running.exposure.amount,90)
        var next=frozen;next.id=Codec.id();next.upper=Money(20)
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:next,requestKey:"next",existing:[running],budget:BudgetPolicy(project:Money(100),month:Money(500))))
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:next,requestKey:"next",existing:[running],budget:BudgetPolicy(project:Money(500),month:Money(100))))
        let cancelled=JobRules.cancel(running)
        XCTAssertEqual(cancelled.state,.cancelRequested)
        XCTAssertEqual(cancelled.exposure.amount,90)
        let unknown=try JobOperations.applyRemote(RemoteSnapshot(remoteID:"supplier-original",requestKey:"original",state:.unknown,progress:0.5,actual:Money(15)),to:cancelled)
        XCTAssertEqual(unknown.actual?.amount,15)
        XCTAssertTrue(unknown.billingUnknown)
        XCTAssertEqual(unknown.exposure.amount,90)
    }
    func testFinalBillCanReleaseDifferenceButLiveRefundCannotReleaseCommitment() throws {
        var j=try job(provider:"remote")
        j.state = .running
        j=try JobOperations.reconcile(j,record:BillingRecord(id:"bill",kind:.charge,money:Money(12),source:"已核实消耗"))
        j=try JobOperations.reconcile(j,record:BillingRecord(id:"request",kind:.refundRequested,money:Money(5),source:"退款申请"))
        j=try JobOperations.reconcile(j,record:BillingRecord(id:"received",kind:.refundReceived,money:Money(3),source:"退款到账"))
        XCTAssertEqual(j.actual?.amount,9)
        XCTAssertEqual(j.refundPending?.amount,2)
        XCTAssertEqual(j.exposure.amount,90)
        let final=try JobOperations.applyRemote(RemoteSnapshot(remoteID:"original",requestKey:j.requestKey,state:.cancelled,progress:0.5,actual:Money(9)),to:j)
        XCTAssertEqual(final.state,.cancelled)
        XCTAssertFalse(final.billingUnknown)
        XCTAssertEqual(final.actual?.amount,9)
        XCTAssertEqual(final.refundPending?.amount,2)
        XCTAssertEqual(final.exposure.amount,9)
        var overrun=j;overrun.actual=Money(100)
        XCTAssertEqual(overrun.exposure.amount,100)
        let unfinished=try JobOperations.applyRemote(RemoteSnapshot(remoteID:"original",requestKey:j.requestKey,state:.running,progress:0.6),to:final)
        XCTAssertTrue(unfinished.billingUnknown)
        XCTAssertEqual(unfinished.exposure.amount,90)
    }
    func testLateZeroGrossOrOverrunReportNeverReplacesReceiptNetOrPartialRefund()throws {
        let original=try partialRefundJob(),ledger=try Codec.data(original.billing)
        for amount in [Decimal(0),Decimal(12),Decimal(100)] {
            let updated=try report(Money(amount),to:original)
            XCTAssertEqual(updated.state,.cancelled)
            XCTAssertEqual(updated.actual,Money(9));XCTAssertEqual(updated.refundPending,Money(2))
            XCTAssertEqual(try Codec.data(updated.billing),ledger)
            XCTAssertEqual(updated.remoteReportedActual,Money(amount));XCTAssertTrue(updated.billingUnknown)
            XCTAssertEqual(updated.exposure,Money(max(90,amount)))
            XCTAssertEqual(updated.id,original.id);XCTAssertEqual(updated.requestKey,original.requestKey)
            XCTAssertEqual(try Codec.data(updated.quote),try Codec.data(original.quote))
            XCTAssertTrue(updated.artifacts.isEmpty)
        }
    }
    func testLowerReportsRetainUnresolvedUpperUntilOriginalTerminalConfirmsNet()throws {
        let original=try partialRefundJob(),ledger=try Codec.data(original.billing)
        var updated=try report(Money(100),to:original)
        updated=try report(Money(12),to:updated,state:.running)
        updated=try report(Money(0),to:updated)
        XCTAssertEqual(updated.remoteReportedActual,Money(100));XCTAssertEqual(updated.exposure,Money(100));XCTAssertTrue(updated.billingUnknown)
        let checked=try XCTUnwrap(updated.remoteCheckedAt).addingTimeInterval(1)
        XCTAssertThrowsError(try JobOperations.applyRemote(RemoteSnapshot(remoteID:"different",requestKey:updated.requestKey,state:.cancelled,progress:1,actual:Money(9),checkedAt:checked),to:updated,now:checked))
        updated=try report(Money(9),to:updated)
        XCTAssertEqual(updated.remoteID,"original");XCTAssertEqual(updated.remoteReportedActual,Money(9))
        XCTAssertEqual(updated.actual,Money(9));XCTAssertEqual(updated.refundPending,Money(2))
        XCTAssertFalse(updated.billingUnknown);XCTAssertEqual(updated.exposure,Money(9))
        XCTAssertFalse(updated.message.contains("不一致"));XCTAssertTrue(updated.message.contains("仍须审核"))
        XCTAssertEqual(try Codec.data(updated.billing),ledger)
    }
    func testMissingOrLiveNetReportCannotResolveExistingRemoteDifference()throws {
        var updated=try report(Money(100),to:partialRefundJob(),state:.unknown)
        updated=try report(nil,to:updated)
        XCTAssertEqual(updated.state,.cancelled);XCTAssertTrue(updated.billingUnknown)
        XCTAssertEqual(updated.remoteReportedActual,Money(100));XCTAssertEqual(updated.exposure,Money(100))
        updated=try report(Money(9),to:updated,state:.running)
        XCTAssertTrue(updated.billingUnknown);XCTAssertEqual(updated.remoteReportedActual,Money(100));XCTAssertEqual(updated.exposure,Money(100))
        let before=try Codec.data(updated),checked=try XCTUnwrap(updated.remoteCheckedAt)
        XCTAssertThrowsError(try JobOperations.applyRemote(RemoteSnapshot(remoteID:"original",requestKey:updated.requestKey,state:.cancelled,progress:1,actual:Money(9),checkedAt:checked.addingTimeInterval(-1)),to:updated,now:checked))
        XCTAssertEqual(try Codec.data(updated),before)
    }
    func testNewRefundApplicationKeepsObservedOverrunAndBlocksMoreBudget()throws {
        var updated=try report(Money(100),to:partialRefundJob(),state:.failed)
        let application=BillingRecord(id:"second-request",kind:.refundRequested,money:Money(2),source:"追加退款申请凭据",at:updated.updatedAt.addingTimeInterval(1))
        updated=try JobOperations.reconcile(updated,record:application)
        XCTAssertEqual(updated.actual,Money(9));XCTAssertEqual(updated.refundPending,Money(4))
        XCTAssertEqual(updated.remoteReportedActual,Money(100));XCTAssertTrue(updated.billingUnknown);XCTAssertEqual(updated.exposure,Money(100))
        XCTAssertEqual(updated.billing?.count,4)
        let p=project();updated.projectID=p.id
        let q=Quote(projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),upper:Money(1),unit:"CNY",provider:"remote",expiresAt:Date().addingTimeInterval(600),confirmed:true)
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:q,requestKey:"extra",existing:[updated],budget:BudgetPolicy(project:Money(100),month:Money(1000))))
    }
    func testOnlyNewReceiptNetMatchingReportedAmountResolvesDifference()throws {
        var charge=try report(Money(12),to:partialRefundJob())
        charge=try JobOperations.reconcile(charge,record:BillingRecord(id:"additional-charge",kind:.charge,money:Money(3),source:"新增消耗凭据",at:charge.updatedAt.addingTimeInterval(1)))
        XCTAssertEqual(charge.actual,Money(12));XCTAssertEqual(charge.refundPending,Money(2));XCTAssertFalse(charge.billingUnknown);XCTAssertEqual(charge.exposure,Money(12))
        var refund=try report(Money(6),to:partialRefundJob())
        refund=try JobOperations.reconcile(refund,record:BillingRecord(id:"additional-request",kind:.refundRequested,money:Money(1),source:"新增退款申请",at:refund.updatedAt.addingTimeInterval(1)))
        XCTAssertTrue(refund.billingUnknown);XCTAssertEqual(refund.actual,Money(9));XCTAssertEqual(refund.refundPending,Money(3))
        refund=try JobOperations.reconcile(refund,record:BillingRecord(id:"additional-received",kind:.refundReceived,money:Money(3),source:"新增到账凭据",at:refund.updatedAt.addingTimeInterval(1)))
        XCTAssertEqual(refund.actual,Money(6));XCTAssertNil(refund.refundPending);XCTAssertFalse(refund.billingUnknown);XCTAssertEqual(refund.exposure,Money(6))
        var zero=try report(Money(9),to:partialRefundJob(),state:.running)
        XCTAssertTrue(zero.billingUnknown)
        zero=try JobOperations.reconcile(zero,record:BillingRecord(id:"zero-charge",kind:.charge,money:Money(0),source:"零金额凭据",at:zero.updatedAt.addingTimeInterval(1)))
        XCTAssertTrue(zero.billingUnknown)
    }
    func testBillingReplayPreservesWholeConflictingJobIncludingObservationAndTimestamps()throws {
        let updated=try report(Money(100),to:partialRefundJob()),before=try Codec.data(updated)
        for event in try XCTUnwrap(updated.billing) {
            XCTAssertEqual(try Codec.data(JobOperations.reconcile(updated,record:event)),before)
            var changed=event;changed.source += "不同"
            XCTAssertThrowsError(try JobOperations.reconcile(updated,record:changed))
        }
        XCTAssertEqual(try Codec.data(updated),before)
    }
    func testLegacyJobWithoutReportedAmountDecodesAndWrongCurrencyCannotMutateLedger()throws {
        let original=try partialRefundJob(),data=try Codec.data(original)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertNil(object["remoteReportedActual"])
        let decoded=try Codec.decoder().decode(Job.self,from:data)
        XCTAssertNil(decoded.remoteReportedActual);XCTAssertEqual(decoded.actual,Money(9));XCTAssertEqual(decoded.refundPending,Money(2));XCTAssertEqual(decoded.exposure,Money(9))
        XCTAssertThrowsError(try report(Money(100,"USD"),to:decoded))
        XCTAssertThrowsError(try report(Money(-1),to:decoded))
        XCTAssertEqual(try Codec.data(decoded),data)
        let statusOnly=try report(Money(12),to:job(provider:"remote"))
        XCTAssertNil(statusOnly.billing);XCTAssertEqual(statusOnly.actual,Money(12));XCTAssertFalse(statusOnly.billingUnknown)
    }
    func testFreeNativeRenderIgnoresOnlyExternalCashBudget() throws {
        let revision=try Planner.create(workspaceID:"w",name:"普通免费剪辑",aspect:.landscape,scenes:[Scene(title:"解释",body:"实际本机内容")])
        let p=Project(workspaceID:"w",name:"普通免费剪辑",revision:revision),now=Date()
        let q=Quote(projectID:p.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:now.addingTimeInterval(600),confirmed:true)
        let external=try job(provider:"paid-provider")
        let local=try JobRules.submit(workspaceID:"w",project:p,quote:q,requestKey:"local",existing:[external],budget:BudgetPolicy(project:Money(0,"USD"),month:Money(0,"USD")),now:now)
        XCTAssertNil(p.current.product)
        XCTAssertEqual(local.quote.provider,"native")
        XCTAssertEqual(local.exposure.amount,0)
        XCTAssertFalse(local.billingUnknown)
        var remote=q;remote.provider="remote"
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:remote,requestKey:"remote",existing:[],budget:BudgetPolicy(project:Money(0,"USD"),month:Money(0,"USD")),now:now))
        var paid=q;paid.upper=Money(1)
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:paid,requestKey:"paid-local",existing:[],budget:BudgetPolicy(project:Money(0),month:Money(0)),now:now))
    }
    func testFreeNativeQuoteStillRequiresValidBindingExpiryAndUnits() throws {
        let p=project(),now=Date()
        let q=Quote(projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:now.addingTimeInterval(600),confirmed:true)
        let budget=BudgetPolicy(project:Money(0,"USD"),month:Money(0,"USD"))
        let mutations:[(inout Quote)->Void]=[{$0.digest="wrong"},{$0.revisionID="wrong"},{$0.projectID="wrong"},{$0.confirmed=false},{$0.expiresAt=now},{$0.unit="credits"},{$0.upper=Money(0,"invalid")},{$0.attempts=0}]
        for mutation in mutations {
            var invalid=q;mutation(&invalid)
            XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:invalid,requestKey:Codec.id(),existing:[],budget:budget,now:now))
        }
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"other",project:p,quote:q,requestKey:"wrong-workspace",existing:[],budget:budget,now:now))
        var mismatch=q
        mismatch.breakdown=EstimateBreakdown(version:"verified",specification:"local",source:"actual",validFrom:now.addingTimeInterval(-1),expiresAt:now.addingTimeInterval(600),lines:[RateLine(label:"cash",quantity:1,unit:"job",price:Money(1))],excluded:[])
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:mismatch,requestKey:"wrong-breakdown",existing:[],budget:budget,now:now))
    }
    func testImportedRemoteProfileCannotClaimNativeFreeBudgetException() throws {
        let p=project()
        var profile=ProviderProfile(name:"实际远端服务",endpoint:"https://api.example.com/chat/completions",model:"known-model",supportedParameters:[],allowsUpload:true,keyReference:"local-reference-only")
        try profile.validate()
        for reserved in ["native","unbound","NATIVE"] {
            profile.id=reserved
            XCTAssertThrowsError(try profile.validate())
            XCTAssertThrowsError(try ScriptJobRules.specification(profile:profile,revision:p.current,evidence:[],brief:"真实资料解释"))
        }
    }
}
