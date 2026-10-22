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
}
