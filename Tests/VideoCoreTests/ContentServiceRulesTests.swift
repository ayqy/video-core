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
        let unknown=ScriptJobRules.interrupted(first)
        XCTAssertEqual(unknown.state,.unknownRemote);XCTAssertEqual(unknown.exposure.amount,3);XCTAssertTrue(unknown.billingUnknown)
        let cancelled=JobRules.cancel(first)
        XCTAssertEqual(cancelled.state,.cancelRequested);XCTAssertEqual(cancelled.exposure.amount,3);XCTAssertTrue(cancelled.billingUnknown)
        XCTAssertThrowsError(try ScriptJobRules.record(first.providerAttempts![0],in:cancelled))
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
