import XCTest
@testable import VideoCore

final class ContentServiceRulesTests:XCTestCase {
    private func profile()->ProviderProfile {
        var p=ProviderProfile(name:"自带聊天",endpoint:"https://api.example.com/chat/completions",model:"reasoning-with-known-contract",supportedParameters:[],allowsUpload:true,keyReference:"opaque-local-reference")
        p.capabilities=ProviderCapabilities(version:"user-checked-v1",source:"https://api.example.com/docs",outputFormat:.text)
        return p
    }
    private func database()throws->Database {
        var db=Database(),w=Workspace(name:"本机空间",owner:"owner");w.id="w";db.workspaces=[w]
        var revision=try Planner.create(workspaceID:"w",name:"普通教学",aspect:.landscape,scenes:[Scene(title:"解释",body:"真实教学内容")])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[])
        db.projects=[Project(workspaceID:"w",name:"普通教学",revision:revision)];db.providers=[profile()]
        return db
    }
    private func quote(_ db:Database,brief:String="按真实材料解释")throws->Quote {
        let p=db.projects[0],profile=db.providers[0]
        return try EstimateBreakdown(version:"official",specification:ScriptJobRules.specification(profile:profile,revision:p.current,evidence:[],brief:brief),source:"已核实官方现金单价",validFrom:.distantPast,expiresAt:Date().addingTimeInterval(3600),lines:[RateLine(label:"本次最大输入输出",quantity:1,unit:"次",price:Money(3))],excluded:["授权和人工未包括"]).quote(project:p,provider:profile.id,confirmed:true)
    }
    func testOrdinaryPromptDoesNotCreateProductOrUploadWorkspaceInternals()throws {
        let db=try database()
        let body=try ProviderRules.body(profile:db.providers[0],revision:db.projects[0].current,evidence:[],brief:"说明时间轴，不需要促销")
        let text=String(decoding:body,as:UTF8.self)
        XCTAssertTrue(text.contains("普通内容工程"));XCTAssertFalse(text.contains("opaque-local-reference"));XCTAssertFalse(text.contains("\"sku\""));XCTAssertFalse(text.contains("\"checkout\""))
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any])
        XCTAssertNil(object["temperature"]);XCTAssertNil(object["max_tokens"]);XCTAssertNil(object["max_completion_tokens"])
        var denied=db.providers[0];denied.allowsUpload=false
        XCTAssertThrowsError(try ProviderRules.body(profile:denied,revision:db.projects[0].current,evidence:[],brief:"解释"))
        let foreign=Evidence(workspaceID:"other",title:"不能上传",source:"原件",claim:"其他项目私有主张",owner:"他人",commercialAllowed:false,uploadConsent:true,verified:true)
        XCTAssertThrowsError(try ProviderRules.body(profile:db.providers[0],revision:db.projects[0].current,evidence:[foreign],brief:"解释"))
    }
    func testContentJobBindsBodyAndReplaysBeforeAnyAdditionalPaidIntent()throws {
        var db=try database();let q=try quote(db),p=db.projects[0],profile=db.providers[0]
        let first=try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"stable-key",principal:"owner")
        XCTAssertTrue(first.shouldSubmit);XCTAssertEqual(db.jobs.count,1);XCTAssertNil(p.current.product)
        let replay=try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"stable-key",principal:"owner")
        XCTAssertFalse(replay.shouldSubmit);XCTAssertEqual(replay.job.id,first.job.id);XCTAssertEqual(db.jobs.count,1)
        XCTAssertThrowsError(try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"改变后的新指令",quote:q,requestKey:"stable-key",principal:"owner"))
        let otherQuote=try quote(db)
        XCTAssertThrowsError(try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:otherQuote,requestKey:"changed-key",principal:"owner"))
    }
    func testChangedBodyOrEvidenceCannotUseFrozenQuote()throws {
        var db=try database();let q=try quote(db),p=db.projects[0],profile=db.providers[0]
        XCTAssertThrowsError(try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"与已冻结报价不同",quote:q,requestKey:"new-key",principal:"owner"))
        var e=Evidence(workspaceID:"w",title:"证据",source:"原件",claim:"旧摘要",owner:"作者",commercialAllowed:false,uploadConsent:true,verified:true);db.evidence=[e]
        let eq=try EstimateBreakdown(version:"v1",specification:ScriptJobRules.specification(profile:profile,revision:p.current,evidence:[e],brief:"解释"),source:"官方",validFrom:.distantPast,expiresAt:Date().addingTimeInterval(60),lines:[RateLine(label:"生成",quantity:1,unit:"次",price:Money(1))],excluded:[]).quote(project:p,provider:profile.id,confirmed:true)
        db.evidence[0].claim="新摘要"
        XCTAssertThrowsError(try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[e],brief:"解释",quote:eq,requestKey:"e",principal:"owner"))
        e.workspaceID="foreign"
        XCTAssertThrowsError(try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[e],brief:"解释",quote:eq,requestKey:"f",principal:"owner"))
        XCTAssertTrue(db.jobs.isEmpty)
    }
    func testUnknownTransportAndCancelDoNotEraseSpendOrEnableRetry()throws {
        var db=try database();let p=db.projects[0],profile=db.providers[0],q=try quote(db)
        let first=try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"lost-response",principal:"owner").job
        let unknown=ScriptJobRules.interrupted(first,executionToken:first.lease?.token)
        XCTAssertEqual(unknown.state,.unknownRemote);XCTAssertEqual(unknown.exposure.amount,3);XCTAssertTrue(unknown.billingUnknown)
        let cancelled=JobRules.cancel(first)
        XCTAssertEqual(cancelled.state,.cancelRequested);XCTAssertEqual(cancelled.exposure.amount,3);XCTAssertTrue(cancelled.billingUnknown)
        XCTAssertThrowsError(try ScriptJobRules.record(first.providerAttempts![0],in:cancelled))
    }
    func testSecondRepositoryOpeningKeepsActiveScriptAndAcceptsOriginalResponse()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(Codec.id(),isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let first=try Repository(root:root),initial=try database(),now=Date(),p=initial.projects[0],profile=initial.providers[0],q=try quote(initial)
        try first.transaction{$0=initial}
        let prepared=try first.transaction{try ScriptJobRules.prepare(database:&$0,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"live-original",principal:"owner",now:now)}.job
        let second=try Repository(root:root)
        try second.transaction{db in for i in db.jobs.indices{db.jobs[i]=JobOperations.recoverExpired(db.jobs[i],now:now.addingTimeInterval(1))}}
        var receipt=try XCTUnwrap(prepared.providerAttempts?.first);receipt.respondedAt=now.addingTimeInterval(2)
        try first.transaction{db in db.jobs[0]=try ScriptJobRules.record(receipt,in:db.jobs[0],executionToken:try XCTUnwrap(prepared.lease).token,now:now.addingTimeInterval(2))}
        let actual=try second.read().jobs
        XCTAssertEqual(actual.count,1);XCTAssertEqual(actual[0].id,prepared.id);XCTAssertEqual(actual[0].requestKey,"live-original")
        XCTAssertEqual(actual[0].state,.running)
        // The repository's ISO-8601 codec persists whole seconds. Compare the
        // complete persisted representations, including the lease identity,
        // rather than comparing unpersisted subsecond Date values.
        XCTAssertEqual(try Codec.data(actual[0].providerAttempts?.first),try Codec.data(Optional(receipt)))
        XCTAssertEqual(try Codec.data(actual[0].lease),try Codec.data(prepared.lease));XCTAssertEqual(actual[0].exposure.amount,3)
    }
    func testScriptLeaseUsesSameFiniteRequestBudgetAndRepairDoesNotRenewIt()throws {
        var db=try database();db.providers[0].capabilities?.repairLimit=1
        let now=Date(timeIntervalSince1970:Date().timeIntervalSince1970.rounded(.down)),profile=db.providers[0],p=db.projects[0]
        func budgeted(_ attempts:Int)throws->Quote{
            try EstimateBreakdown(version:"official",specification:ScriptJobRules.specification(profile:profile,revision:p.current,evidence:[],brief:"按真实材料解释"),source:"已核实官方现金单价",validFrom:.distantPast,expiresAt:now.addingTimeInterval(3600),lines:[RateLine(label:"最大输入输出",quantity:1,unit:"次",price:Money(3),attempts:attempts)],excluded:[]).quote(project:p,provider:profile.id,confirmed:true,now:now)
        }
        XCTAssertEqual(ScriptJobRules.executionDeadline(profile:profile,quote:try budgeted(1),now:now).timeIntervalSince(now),60)
        let fractionalNow=now.addingTimeInterval(0.75)
        let singleDeadline=ScriptJobRules.executionDeadline(profile:profile,quote:try budgeted(1),now:fractionalNow)
        XCTAssertEqual(singleDeadline,now.addingTimeInterval(60))
        XCTAssertLessThanOrEqual(singleDeadline.timeIntervalSince(fractionalNow),60)
        let q=try budgeted(2),prepared=try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"one-repair",principal:"owner",now:fractionalNow).job
        let lease=try XCTUnwrap(prepared.lease)
        XCTAssertEqual(lease.expiresAt.timeIntervalSince(now),120)
        XCTAssertLessThanOrEqual(lease.expiresAt.timeIntervalSince(fractionalNow),120)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(Codec.id(),isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root)
        try repository.transaction{$0=db}
        XCTAssertEqual(try repository.read().jobs[0].lease?.expiresAt,lease.expiresAt)
        XCTAssertEqual(JobOperations.recoverExpired(prepared,now:lease.expiresAt.addingTimeInterval(-0.001)).state,.running)
        let second=ProviderAttempt(id:prepared.requestKey+"-attempt-2",number:2,inputDigest:String(repeating:"b",count:64),capabilityVersion:profile.capabilities?.version,startedAt:now.addingTimeInterval(61))
        let recorded=try ScriptJobRules.record(second,in:prepared,executionToken:lease.token,now:now.addingTimeInterval(61))
        XCTAssertEqual(recorded.lease?.expiresAt,lease.expiresAt)
        let expired=JobOperations.recoverExpired(recorded,now:lease.expiresAt)
        XCTAssertEqual(expired.state,.unknownRemote);XCTAssertNil(expired.lease);XCTAssertEqual(expired.id,prepared.id);XCTAssertEqual(expired.exposure.amount,6)
        XCTAssertThrowsError(try ScriptJobRules.record(second,in:recorded,executionToken:lease.token,now:lease.expiresAt))
        XCTAssertThrowsError(try ScriptJobRules.record(second,in:expired,executionToken:lease.token,now:lease.expiresAt))
    }
    func testScriptCallbackRejectsWrongExecutionOwnerTokenAndRemovedLease()throws {
        var db=try database();let profile=db.providers[0],p=db.projects[0],q=try quote(db)
        let job=try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"bound-owner",principal:"owner").job
        let receipt=try XCTUnwrap(job.providerAttempts?.first),token=try XCTUnwrap(job.lease).token
        XCTAssertThrowsError(try ScriptJobRules.record(receipt,in:job))
        XCTAssertThrowsError(try ScriptJobRules.record(receipt,in:job,executionToken:"another-token"))
        var other=job;other.lease?.owner="other-owner"
        XCTAssertThrowsError(try ScriptJobRules.record(receipt,in:other,executionToken:token))
        XCTAssertEqual(try Codec.digest(ScriptJobRules.interrupted(other,executionToken:token)),try Codec.digest(other))
        other=job;other.lease=nil
        XCTAssertThrowsError(try ScriptJobRules.record(receipt,in:other,executionToken:token))
        XCTAssertEqual(try Codec.digest(ScriptJobRules.interrupted(job,executionToken:"another-token")),try Codec.digest(job))
    }
    func testScriptInterruptionReleasesOnlyItsOwnLeaseAndKeepsOriginalSpend()throws {
        var db=try database();let profile=db.providers[0],p=db.projects[0],q=try quote(db)
        let job=try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"unknown-original",principal:"owner").job
        let token=try XCTUnwrap(job.lease).token
        let unknown=ScriptJobRules.interrupted(job,executionToken:token)
        XCTAssertEqual(unknown.state,.unknownRemote);XCTAssertNil(unknown.lease);XCTAssertEqual(unknown.exposure.amount,3)
        var receipt=try XCTUnwrap(job.providerAttempts?.first);receipt.respondedAt=Date()
        let responded=try ScriptJobRules.record(receipt,in:job,executionToken:token)
        let failedStructure=ScriptJobRules.interrupted(responded,executionToken:token)
        XCTAssertEqual(failedStructure.state,.billingPending);XCTAssertTrue(failedStructure.billingUnknown);XCTAssertNil(failedStructure.lease)
        XCTAssertEqual(failedStructure.id,job.id);XCTAssertEqual(failedStructure.quote.id,job.quote.id);XCTAssertTrue(failedStructure.artifacts.isEmpty)
    }
    func testCompletingCandidateRequiresOriginalLiveLeaseAndKeepsReviewPending()throws {
        var db=try database();let profile=db.providers[0],p=db.projects[0],q=try quote(db)
        let job=try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"candidate-original",principal:"owner").job
        let token=try XCTUnwrap(job.lease).token
        let artifact=Artifact(path:"/draft.txt",mime:"text/plain",bytes:9,sha256:String(repeating:"a",count:64),revision:job.revisionID)
        let result=try ScriptJobRules.completingDraft(job,artifact:artifact,executionToken:token)
        XCTAssertEqual(result.state,.billingPending);XCTAssertNil(result.lease);XCTAssertTrue(result.billingUnknown);XCTAssertNil(result.actual)
        XCTAssertEqual(result.id,job.id);XCTAssertEqual(result.requestKey,job.requestKey);XCTAssertEqual(result.artifacts.count,1)
        XCTAssertThrowsError(try ScriptJobRules.completingDraft(job,artifact:artifact,executionToken:"other"))
        XCTAssertThrowsError(try ScriptJobRules.completingDraft(JobRules.cancel(job),artifact:artifact,executionToken:token))
        XCTAssertThrowsError(try ScriptJobRules.completingDraft(result,artifact:artifact,executionToken:token))
        XCTAssertThrowsError(try ScriptJobRules.completingDraft(job,artifact:artifact,executionToken:token,now:try XCTUnwrap(job.lease).expiresAt))
        var bad=artifact;bad.revision="other";XCTAssertThrowsError(try ScriptJobRules.completingDraft(job,artifact:bad,executionToken:token))
        bad=artifact;bad.bytes=120001;XCTAssertThrowsError(try ScriptJobRules.completingDraft(job,artifact:bad,executionToken:token))
    }
    func testBudgetBoundBeforePaidIntentAndMonthlyUnknownReservation()throws {
        var db=try database();db.budget=BudgetPolicy(project:Money(2),month:Money(200))
        let p=db.projects[0],profile=db.providers[0],q=try quote(db)
        XCTAssertThrowsError(try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"over-limit",principal:"owner"));XCTAssertTrue(db.jobs.isEmpty)
        db.budget=BudgetPolicy(project:Money(100),month:Money(5))
        _=try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"按真实材料解释",quote:q,requestKey:"first",principal:"owner")
        let next=try quote(db,brief:"另一次不同教学目标")
        XCTAssertThrowsError(try ScriptJobRules.prepare(database:&db,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"另一次不同教学目标",quote:next,requestKey:"second",principal:"owner"))
        XCTAssertEqual(db.jobs.count,1)
    }
    func testRequired12By3And10VideoUpperBounds()throws {
        let rate=RateLine(label:"镜头",quantity:1,unit:"段",price:Money(Decimal(string:"2.48")!),count:12,attempts:3)
        XCTAssertEqual(try rate.total().amount,Decimal(string:"89.28"))
        var ten=rate;ten.count=120
        XCTAssertEqual(try ten.total().amount,Decimal(string:"892.80"))
    }
    func testIndependentOrdinaryBatchPreservesSourcesBudgetAndFailedSibling()throws {
        var db=try database();let source=db.projects[0]
        let variants=[TeachingVariant(name:"条件A",hook:"先看时间轴",aspect:.landscape,budget:Money(20)),TeachingVariant(name:"条件B",hook:"同帧如何排列",aspect:.portrait,budget:Money(30)),TeachingVariant(name:"缺失开场",hook:"",aspect:.landscape,budget:Money(10))]
        let batch=try TeachingBatchRules.create(database:&db,workspaceID:"w",title:"开场对照",sourceProjectID:source.id,variants:variants)
        XCTAssertEqual(batch.items.count,3);XCTAssertEqual(batch.items[2].state,.failed);XCTAssertNil(batch.items[2].projectID)
        XCTAssertEqual(db.projects.count,3);XCTAssertEqual(batch.maximumByCurrency["CNY"],60)
        XCTAssertNil(batch.items[0].frozen?.product);XCTAssertEqual(batch.items[0].frozen?.scenes.first?.body,"先看时间轴")
        XCTAssertEqual(batch.items[0].frozen?.contentContext,source.current.contentContext)
        XCTAssertNotEqual(batch.items[0].frozen?.id,batch.items[1].frozen?.id)
        XCTAssertFalse(try XCTUnwrap(batch.items[0].frozen).review.complete)
        try db.validate()
        let project=try db.project(XCTUnwrap(batch.items[0].projectID))
        let q=Quote(projectID:project.id,revisionID:project.current.id,digest:try project.current.contentDigest(),upper:Money(21),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(60),confirmed:true)
        XCTAssertThrowsError(try TeachingBatchRules.validateSubmission(project:project,quote:q,batches:[batch]))
        let oldID=try XCTUnwrap(batch.items[1].frozen).id
        let i=db.projects.firstIndex{$0.id==project.id}!
        db.projects[i]=try Editor.apply([.cta("有意修改")],to:db.projects[i],baseRevision:project.current.id,assets:[],message:"有意改变本项")
        let refreshed=TeachingBatchRules.refreshed(batch,database:db)
        XCTAssertEqual(refreshed.items[0].state,.invalidated);XCTAssertEqual(refreshed.items[1].frozen?.id,oldID)
        try TeachingBatchRules.acceptRevision(database:&db,batchID:batch.id,itemID:batch.items[0].id)
        XCTAssertEqual(db.teachingBatches?.first?.items[0].history.count,1)
        XCTAssertEqual(db.teachingBatches?.first?.items[0].variant.budget.amount,20)
    }
    func testFailedBatchPreparationCanBeCorrectedWithoutRebuildingSiblings()throws {
        var db=try database()
        let bad=TeachingVariant(name:"待修",hook:"",aspect:.portrait,budget:Money(2)),good=TeachingVariant(name:"保留",hook:"真实开场",aspect:.landscape,budget:Money(3))
        let batch=try TeachingBatchRules.create(database:&db,workspaceID:"w",title:"逐项",sourceProjectID:db.projects[0].id,variants:[bad,good])
        var corrected=bad;corrected.hook="已修正的真实开场"
        try TeachingBatchRules.retryPreparation(database:&db,batchID:batch.id,itemID:bad.id,variant:corrected)
        XCTAssertEqual(db.teachingBatches?.first?.items[0].state,.ready)
        XCTAssertEqual(db.teachingBatches?.first?.items[1].projectID,batch.items[1].projectID)
        XCTAssertEqual(db.projects.count,3)
        XCTAssertThrowsError(try TeachingBatchRules.retryPreparation(database:&db,batchID:batch.id,itemID:good.id,variant:good))
    }
}
