import XCTest
import VideoCore

final class JobOperationTests: XCTestCase {
    func project() -> Project {
        let p=Product(workspaceID:"w",sku:"s",name:"课程",checkout:"https://example.com",audience:"初学者",task:"复现",outcome:"能操作",prerequisite:"自备工具",scope:"边界",prices:[Price(money:Money(99),source:"原页",verified:true)])
        return Project(workspaceID:"w",name:"演示",revision:Revision(product:p,purpose:.course,aspect:.portrait,scenes:[Scene(title:"完整",body:"内容")],cta:"了解已有课程"))
    }
    func job(provider: String = "native") throws -> Job { let p=project(); return Job(workspaceID:"w",projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),requestKey:"once",quote:Quote(projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),upper:Money(90),unit:"CNY",provider:provider,expiresAt:Date().addingTimeInterval(1000),confirmed:true)) }
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
