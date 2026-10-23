import XCTest
import CryptoKit
import VideoCore

final class DomainTests:XCTestCase {
    func product(_ w:String="w") -> Product { Product(workspaceID:w,sku:"course-a",name:"上下文实验",checkout:"https://example.com/course",audience:"AI初学者",task:"理解上下文预算",outcome:"能复现预算变化",prerequisite:"会使用聊天工具",scope:"资源模拟",prices:[Price(money:Money(99),from:Date(timeIntervalSince1970:0),source:"原购买页",verified:true)]) }
    func project(_ w:String="w") throws -> Project { Project(workspaceID:w,name:"上下文",revision:try Planner.create(product:product(w),knowledge:"上下文有容量边界。",demonstration:"输入两段材料并比较剩余容量。",hook:"为什么会忘记前文？",purpose:.course,aspect:.landscape,kind:.explanation,evidenceIDs:[])) }
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("video-tests-\(UUID().uuidString)") }
    func testPriceIntervalsAndExactMoney() throws {
        var p=product(); p.prices.append(Price(money:Money(200),from:Date(timeIntervalSince1970:10),source:"新购买页")); XCTAssertThrowsError(try p.validate()); p.prices[0].until=Date(timeIntervalSince1970:10); try p.validate(); XCTAssertEqual(try p.price(at:Date(timeIntervalSince1970:10)).money.amount,200)
        XCTAssertEqual(try Money(text:"0.1").adding(Money(text:"0.2")).amount,Decimal(string:"0.3")); XCTAssertThrowsError(try Money(text:"1e999")); XCTAssertThrowsError(try Money(1,"USD").adding(Money(1)))
    }
    func testOrderIdentityRefundAndBatchRollback() throws {
        let order=try Order(workspaceID:"w",platform:"店铺",rawOrderID:"123",rawBuyerID:"13900000000",salt:"local-salt",sku:"sku",paidAt:Date(),paid:Money(99),fee:1,refunds:[Refund(id:"r1",amount:10,at:Date()),Refund(id:"r2",amount:20,at:Date())],importID:"a")
        XCTAssertEqual(order.net,68); XCTAssertFalse(order.id.contains("123")); XCTAssertFalse(order.buyer.contains("139")); XCTAssertFalse(String(decoding:try Codec.data(order),as:UTF8.self).contains("13900000000"))
        var invalid=order; invalid.refunds.append(Refund(id:"r1",amount:5,at:Date())); XCTAssertThrowsError(try invalid.validate()); invalid.refunds=[Refund(id:"r3",amount:100,at:Date())]; XCTAssertThrowsError(try invalid.validate())
        var db=Database(); try db.importOrders([order],batchID:"a"); try db.importOrders([order],batchID:"a"); XCTAssertEqual(db.orders.count,1)
        var updated=order; updated.importID="b"; updated.fee=2; try db.importOrders([updated],batchID:"b"); XCTAssertEqual(db.orders[0].net,67); XCTAssertThrowsError(try db.rollbackImport("a")); try db.rollbackImport("b"); XCTAssertEqual(db.orders[0].net,68); try db.rollbackImport("a"); XCTAssertTrue(db.orders.isEmpty)
    }
    func testMetricsCumulativeSnapshotsAreNotAddedOnReimport() throws {
        let t=Date(timeIntervalSince1970:100)
        let m=try Metric(workspaceID:"w",platform:"B站",contentID:"BV1",asOf:t,views:100,arrivals:5,definition:"平台累计播放",importID:"a"); var db=Database(); try db.importMetrics([m],batchID:"a"); var newer=m; newer.views=120; newer.importID="b"; try db.importMetrics([newer],batchID:"b"); XCTAssertEqual(db.metrics.count,1); XCTAssertEqual(db.metrics[0].views,120); try db.rollbackImport("b"); XCTAssertEqual(db.metrics[0].views,100)
    }
    func testIncrementUnknownNegativeAndSharedCostOnce() throws {
        let now=Date(timeIntervalSince1970:20000000); let order=try Order(workspaceID:"w",platform:"s",rawOrderID:"1",rawBuyerID:"x",salt:"s",sku:"sku",paidAt:now.addingTimeInterval(-10*86400),paid:Money(99),fee:1,kind:.new,importID:"a")
        let expense=Expense(workspaceID:"w",label:"共享制作费",money:Money(20),allocation:["课程":Decimal(string:"0.5")!,"工具":Decimal(string:"0.5")!],at:now)
        let baseline=Baseline(contribution:Money(150),days:30,comparable:true,description:"同SKU同退款窗口",from:now.addingTimeInterval(-60*86400))
        let r=try Finance.report(orders:[order],cash:[],expenses:[expense],baseline:baseline,now:now); XCTAssertEqual(r.sharedCashCost,20); XCTAssertEqual(r.incrementalEstimate,-72); XCTAssertEqual(r.netContribution,78); XCTAssertEqual(r.unknownSourceOrders,1)
        var unknown=order; unknown.fee=nil; let u=try Finance.report(orders:[unknown],cash:[],expenses:[expense],baseline:baseline,now:now); XCTAssertNil(u.incrementalEstimate); XCTAssertNil(u.netContribution); XCTAssertEqual(u.unknownFeeOrders,1)
        let n=try Finance.report(orders:[order],cash:[],expenses:[expense],baseline:nil,now:now); XCTAssertNil(n.incrementalEstimate)
    }
    func testImmutableRevisionConflictLockAndVoiceInvalidation() throws {
        let p=try project(); var s=p.current.scenes[0]; s.narration="AI预算99元"; s.voice=VoiceTake(assetID:"a",textDigest:try s.speechDigest(),durationFrames:20,method:"自备",listened:true)
        let a=try Editor.apply([.replaceScene(s.id,s)],to:p,baseRevision:p.current.id,assets:[],message:"配音"); var changed=a.current.scenes[0]; changed.narration="AI预算200元"
        let b=try Editor.apply([.replaceScene(changed.id,changed)],to:a,baseRevision:a.current.id,assets:[],message:"改价"); XCTAssertNil(b.current.scenes[0].voice); XCTAssertEqual(b.revisions[0].scenes[0].narration,""); XCTAssertThrowsError(try Editor.apply([.aspect(.portrait)],to:b,baseRevision:p.current.id,assets:[],message:"冲突"))
        let locked=try Editor.apply([.lockScene(changed.id,true)],to:b,baseRevision:b.current.id,assets:[],message:"锁定"); XCTAssertThrowsError(try Editor.apply([.replaceScene(changed.id,changed)],to:locked,baseRevision:locked.current.id,assets:[],message:"不应成功"))
    }
    func testTrimSplitAndSpeedReflow() throws {
        let p=try project(); let id=p.current.scenes[0].id; let split=try Editor.apply([.splitScene(id,60)],to:p,baseRevision:p.current.id,assets:[],message:"拆分"); XCTAssertEqual(split.current.frames,p.current.frames); XCTAssertEqual(split.current.scenes.count,p.current.scenes.count+1)
        var s=split.current.scenes[0]; s.speed=2; let faster=try Editor.apply([.replaceScene(s.id,s)],to:split,baseRevision:split.current.id,assets:[],message:"变速"); XCTAssertEqual(faster.current.frames,split.current.frames-30)
        s.speed=0; XCTAssertThrowsError(try s.validate(assets:[]))
    }
    func testExtremePauseAndTrimReturnStructuredErrorsBeforeTimelineArithmetic() throws {
        let p=try project();var scene=p.current.scenes[0];scene.pauseFrames=Int.max
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id,scene)],to:p,baseRevision:p.current.id,assets:[],message:"拒绝溢出停顿")) {error in XCTAssertEqual((error as? VideoError)?.code,"invalid_input")}
        scene.pauseFrames=0
        var asset=Asset(workspaceID:"w",name:"clip.mp4",hash:String(repeating:"a",count:64),ext:"mp4",bytes:1,mediaType:"video");asset.durationFrames=300
        scene.assetID=asset.id;scene.sourceStartFrame=Int.max
        XCTAssertThrowsError(try scene.validate(assets:[asset])) {error in XCTAssertEqual((error as? VideoError)?.code,"invalid_input")}
        scene.sourceStartFrame=300-scene.durationFrames;try scene.validate(assets:[asset])
    }
    func testApprovalBindsAllFrozenContentAndStalePrice() throws {
        var p=try project(); let digest=try p.current.contentDigest(); p.revisions[0].review.digest=digest; p.revisions[0].review.text=true; XCTAssertEqual(try p.current.contentDigest(),digest)
        var db=Database(); db.products=[p.current.product!]; var updated=p.current.product!; updated.name="内容范围已变化"; db.products=[updated]; let issues=try Quality.inspect(p.current,database:db,requireReview:false); XCTAssertTrue(issues.contains{$0.id=="stale_facts"})
    }
    func testIdempotentJobAndUnknownCostBudget() throws {
        let p=try project(); let q=Quote(projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),upper:Money(30),unit:"CNY",provider:"remote",expiresAt:Date().addingTimeInterval(1000),confirmed:true)
        let policy=BudgetPolicy(project:Money(50),month:Money(50)); let j=try JobRules.submit(workspaceID:"w",project:p,quote:q,requestKey:"same",existing:[],budget:policy); let repeated=try JobRules.submit(workspaceID:"w",project:p,quote:q,requestKey:"same",existing:[j],budget:policy); XCTAssertEqual(j.id,repeated.id)
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:q,requestKey:"new",existing:[j],budget:policy)); var old=j; old.remoteID="accepted"; old.state = .unknownRemote; let cancelled=JobRules.cancel(old); XCTAssertNil(cancelled.actual); XCTAssertEqual(cancelled.quote.upper.amount,30); XCTAssertEqual(cancelled.state,.cancelRequested)
        let recovered=try JobRules.recover(old); XCTAssertEqual(recovered.id,j.id); XCTAssertEqual(recovered.state,.unknownRemote)
        var expired=q; expired.expiresAt=Date(timeIntervalSince1970:1); XCTAssertThrowsError(try JobRules.submit(workspaceID:"w",project:p,quote:expired,requestKey:"expired",existing:[],budget:policy))
    }
    func testBrandMutuallyExclusiveAndActualReceipt() throws {
        var b=BrandDeal(workspaceID:"w",client:"客户",brief:"产品解说",vertical:"数码",checklist:[:],revisionsAllowed:2,usage:"自有账号",expiresAt:Date().addingTimeInterval(100),exclusivity:"非排他",settlements:[.fixedLicense,.adShare],quote:Money(1000)); XCTAssertThrowsError(try b.validate()); b.settlements=[.cps]; try b.validate(); b.received=Money(1000); XCTAssertThrowsError(try b.validate())
    }
    func testWorkspaceVersionScopeAndRevocation() throws {
        var w=Workspace(name:"客户A",owner:"owner"); w.grants=[Grant(principal:"reviewer",role:.reviewer,projectIDs:["p"],revisionIDs:["v1"],expiresAt:Date().addingTimeInterval(60))]; try w.authorize(principal:"reviewer",project:"p",revision:"v1"); XCTAssertThrowsError(try w.authorize(principal:"reviewer",project:"p",revision:"v2")); XCTAssertThrowsError(try w.authorize(principal:"reviewer",project:"p",financial:true)); XCTAssertThrowsError(try w.authorize(principal:"reviewer",project:"p",write:true)); w.grants[0].revoked=true; XCTAssertThrowsError(try w.authorize(principal:"reviewer",project:"p",revision:"v1"))
    }
    func testCSVQuotesNewlinesMalformedAndFormulaSafety() throws {
        let rows=try CSV.parse("sku,claim\r\nA,\"第一行\n第二行,仍在同格\"\r\n"); XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0]["claim"],"第一行\n第二行,仍在同格"); XCTAssertThrowsError(try CSV.parse("x,x\n1,2")); XCTAssertThrowsError(try CSV.parse("x\n\"broken")); XCTAssertTrue(CSV.safeCell("=WEBSERVICE()").contains("'=WEBSERVICE"))
    }
    func testAtomicStoreConflictRollbackAndVerifiedRestore() throws {
        let url=root(), restored=root(); defer {try? FileManager.default.removeItem(at:url);try? FileManager.default.removeItem(at:restored)}; let repo=try Repository(root:url); let w=Workspace(name:"测试",owner:"o"); try repo.transaction{$0.workspaces.append(w)}; let before=try repo.read()
        XCTAssertThrowsError(try repo.transaction { $0.products.append(self.product("missing-workspace")) }); XCTAssertEqual(try repo.read().generation,before.generation)
        let other=try Repository(root:url); try other.transaction{$0.workspaces[0].name="改名"}; XCTAssertThrowsError(try repo.transaction(expectedGeneration:before.generation){$0.workspaces[0].name="覆盖"})
        let asset=try repo.ingest(Data("真实源内容".utf8),name:"讲稿.txt",workspaceID:w.id,mediaType:"text"); try repo.transaction{$0.assets.append(asset)}; let backup=try repo.backup(); let copy=try Repository.restore(backup,to:restored); try copy.verifyAssets(copy.read()); XCTAssertEqual(try copy.read().assets.first?.hash,asset.hash); XCTAssertThrowsError(try Repository.restore(backup,to:restored)); try repo.clearCache(); XCTAssertTrue(FileManager.default.fileExists(atPath:repo.assetURL(asset).path))
    }
    func testPluginABISignaturePolicyAxesAndPermission() throws {
        let key=Curve25519.Signing.PrivateKey(); let policy=CommercialPolicy(pluginID:"game",version:1,access:"paid"); let payload=try Codec.data(policy); let signed=SignedDocument(payload:payload,signature:try key.signature(for:payload)); let decoded=try signed.verified(as:CommercialPolicy.self,publicKey:key.publicKey.rawRepresentation); XCTAssertEqual(decoded.access,"paid")
        let manifest=PluginManifest(id:"game",version:"1",capabilities:["game"],implementationDigest:"abc",permissions:["assets.read"]); XCTAssertThrowsError(try PluginHost.validate(manifest:manifest,policy:policy,installedDigest:"abc",entitlements:["ios.editor"],grantedPermissions:["assets.read"]))
        var free=policy; free.access="free"; try PluginHost.validate(manifest:manifest,policy:free,installedDigest:"abc",entitlements:[],grantedPermissions:["assets.read"]); XCTAssertEqual(free.sourceVisibility,"closed"); XCTAssertThrowsError(try PluginHost.validate(manifest:manifest,policy:free,installedDigest:"abc",entitlements:[],grantedPermissions:[]))
        var incompatible=manifest; incompatible.abi=2; XCTAssertThrowsError(try PluginHost.validate(manifest:incompatible,policy:free,installedDigest:"abc",entitlements:[],grantedPermissions:["assets.read"]))
        let bad=SignedDocument(payload:payload,signature:Data(repeating:0,count:64)); XCTAssertThrowsError(try bad.verified(as:CommercialPolicy.self,publicKey:key.publicKey.rawRepresentation)); XCTAssertThrowsError(try PluginHost.validateOutput(path:URL(fileURLWithPath:"/tmp/escape"),root:URL(fileURLWithPath:"/tmp/output")))
    }
    func testDeterministicSimulationAndCapacity() throws {
        var s=Simulation(); s.events=[RuleEvent(tick:1,delta:-30,label:"材料"),RuleEvent(tick:2,delta:10,label:"压缩")]; XCTAssertEqual(try s.state(at:0),100); XCTAssertEqual(try s.state(at:2),80); XCTAssertEqual(try s.state(at:2),try s.state(at:2)); s.capacity=0; XCTAssertThrowsError(try s.state(at:0))
        s.capacity=100;s.events=[RuleEvent(tick:0,delta:Int.min,label:"极端输入")]
        XCTAssertThrowsError(try s.state(at:0)) {error in XCTAssertEqual((error as? VideoError)?.code,"invalid_input")}
    }
    func testSplitPreservesKeyframeMotionOnBothSides()throws{
        var p=try project();var scene=p.current.scenes[0];scene.keyframes=[Keyframe(frame:0,x:0,y:0.5,scale:1),Keyframe(frame:100,x:1,y:0.5,scale:2)];p.revisions[0].scenes[0]=scene
        let changed=try Editor.apply([.splitScene(scene.id,60)],to:p,baseRevision:p.current.id,assets:[],message:"拆分动画")
        for frame in 0..<scene.durationFrames{let after=frame<60 ? changed.current.scenes[0].layout(at:frame):changed.current.scenes[1].layout(at:frame-60);let before=scene.layout(at:frame);XCTAssertEqual(after.x,before.x,accuracy:0.00001);XCTAssertEqual(after.scale,before.scale,accuracy:0.00001)}
    }
    func testCSVOrderPartialRefundMergeAndRepeatPreview()throws{
        let w=Workspace(name:"订单夹具",owner:"o")
        let header="platform,order_id,buyer_id,sku,paid_at,amount,currency,fee,customer_kind,refund_id,refund_amount,refund_at\r\n"
        let row="店铺,O1,买家甲,SKU,2026-10-01,100,CNY,1,新客,"
        let csv=header+row+"R1,20,2026-10-03\r\n"+row+"R2,10,2026-10-04\r\n"
        let first=try ImportRules.orders(csv,workspace:w,existing:[]);XCTAssertEqual(first.rows.count,1);XCTAssertEqual(first.rows[0].refunded,30);XCTAssertEqual(first.rows[0].net,69)
        let second=try ImportRules.orders(csv,workspace:w,existing:first.rows);XCTAssertEqual(second.batchID,first.batchID);XCTAssertEqual(second.rows[0].refunds.count,2)
        let third=try ImportRules.orders(header+row+"R3,5,2026-10-05\r\n",workspace:w,existing:second.rows);XCTAssertEqual(third.rows[0].refunded,35);XCTAssertEqual(third.rows[0].net,64)
    }
    func testBackupRestoresVerifiedHistoricalExportsUnderNewRoot()throws{
        let source=root(),destination=root(),badDestination=root();defer{try? FileManager.default.removeItem(at:source);try? FileManager.default.removeItem(at:destination);try? FileManager.default.removeItem(at:badDestination)}
        let repo=try Repository(root:source);let w=Workspace(name:"完整恢复",owner:"o");let p=try project(w.id);let q=Quote(projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(60),confirmed:true);var job=Job(workspaceID:w.id,projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),requestKey:"backup",quote:q)
        let original=Data((0..<65536).map{UInt8($0%256)}),path=source.appendingPathComponent("exports/\(job.id)/payload.bin");try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try original.write(to:path);job.artifacts=[Artifact(path:path.path,mime:"application/octet-stream",bytes:original.count,sha256:Codec.hash(original),revision:p.current.id)]
        try repo.transaction{$0.workspaces.append(w);$0.products.append(p.current.product!);$0.projects.append(p);$0.jobs.append(job)}
        let backup=try repo.backup();let restored=try Repository.restore(backup,to:destination);let artifact=try XCTUnwrap(restored.read().jobs.first?.artifacts.first);XCTAssertTrue(artifact.path.hasPrefix(destination.path+"/exports/"));XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:artifact.path)),original)
        var corrupt=try PropertyListDecoder().decode(Repository.Backup.self,from:backup);corrupt.exports=[:];XCTAssertThrowsError(try Repository.restore(PropertyListEncoder().encode(corrupt),to:badDestination));XCTAssertFalse(FileManager.default.fileExists(atPath:badDestination.path))
    }
    func testMetricValidationCannotBeBypassedByDecodedRecord()throws{
        var m=try Metric(workspaceID:"w",platform:"平台",contentID:"c",asOf:Date(),views:10,arrivals:nil,definition:"累计播放",importID:"b");m.views = -1
        var db=Database();db.metrics=[m];XCTAssertThrowsError(try db.validate())
        XCTAssertThrowsError(try ImportRules.metrics("platform,content_id,as_of,views,definition,cumulative\n平台,c,2026-10-01,10,累计播放,maybe\n",workspaceID:"w"))
    }
    func testMarketingClaimsNeedTheActualApprovedSentenceIncludingCaptions() throws {
        var p=try project();var db=Database();db.products=[p.current.product!]
        let claim="已帮助100位学员完成操作"
        p.revisions[0].scenes[0].captions=[Caption(text:claim,startFrame:0,endFrame:100,confirmed:true)]
        var proof=Evidence(workspaceID:"w",title:"真实记录",source:"客户核对表",claim:"已帮助1位学员完成操作",owner:"作者",commercialAllowed:true,verified:true)
        p.revisions[0].scenes[0].evidenceIDs=[proof.id];db.evidence=[proof]
        XCTAssertTrue(try Quality.inspect(p.current,database:db,requireReview:false).contains{$0.id.contains("claims-")})
        proof.claim=claim;db.evidence=[proof]
        XCTAssertFalse(try Quality.inspect(p.current,database:db,requireReview:false).contains{$0.id.contains("claims-")})
        p.revisions[0].cta="保证月入万元"
        XCTAssertTrue(try Quality.inspect(p.current,database:db,requireReview:false).contains{$0.id.hasPrefix("cta-claims-")})
        p.revisions[0].cta="查看课程内容"
        let picture=Asset(workspaceID:"w",name:"layer.png",hash:String(repeating:"a",count:64),ext:"png",bytes:100,mediaType:"image/png")
        db.assets=[picture];p.revisions[0].scenes[0].layers=[SceneLayer(kind:.image,assetID:picture.id,endFrame:100)]
        XCTAssertTrue(try Quality.inspect(p.current,database:db,requireReview:false).contains{$0.id==picture.id+"rights"})
        var licensed=picture;licensed.evidenceID=proof.id;db.assets=[licensed]
        XCTAssertFalse(try Quality.inspect(p.current,database:db,requireReview:false).contains{$0.id==picture.id+"rights"})
        proof.workspaceID="other";db.evidence=[proof]
        XCTAssertFalse(ClaimRules.hasProof(claim,evidence:[proof],workspaceID:"w"))
        XCTAssertTrue(ClaimRules.candidates("保证月入万元").contains("保证月入万元"))
        XCTAssertFalse(ClaimRules.hasProof("保证月入万元",evidence:[Evidence(workspaceID:"w",title:"告知",source:"原件",claim:"不保证月入万元",owner:"作者",commercialAllowed:true,verified:true)],workspaceID:"w"))
        XCTAssertTrue(ClaimRules.isCurrentPrice("99元",product:product()))
        XCTAssertFalse(ClaimRules.isCurrentPrice("100元",product:product()))
        XCTAssertTrue(ClaimRules.candidates("https://example.com/course/10001").isEmpty)
    }
}

/// These fixtures move the actual SQLite workspace and output files together;
/// they do not emulate relocation by editing a returned URL.
final class ArtifactRelocationTests:XCTestCase {
    private let fm=FileManager.default
    private var temporary:[URL]=[]
    private struct Fixture {var source:URL;var moved:URL;var project:Project;var jobs:[Job];var generation:Int}
    override func tearDown(){for root in temporary{try? fm.removeItem(at:root)};temporary=[];super.tearDown()}
    private func directory()->URL {let root=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("video-relocation-"+Codec.id());temporary.append(root);return root}
    private func fixture(jobs:Int=1,history:Bool=false,change:((inout [Job])->Void)?=nil)throws->Fixture {
        let source=directory(),moved=directory();let repo=try Repository(root:source),workspace=Workspace(name:"迁移夹具",owner:"owner")
        var product=Product(workspaceID:workspace.id,sku:"demo",name:"练习",checkout:"https://example.com/course",audience:"学习者",task:"演示",outcome:"理解",prerequisite:"无",scope:"一个例子",prices:[Price(money:Money(0),from:Date(timeIntervalSince1970:0),source:"练习",verified:true)]);product.isExample=true
        var project=Project(workspaceID:workspace.id,name:"练习",revision:Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"原镜头",body:"保留原内容")],cta:"继续",change:"原始版本"))
        let revision=project.current,digest=try revision.contentDigest()
        if history{var second=revision;second.id=Codec.id();second.parentID=revision.id;second.number=2;second.scenes[0].body="后续版本";project.revisions.append(second)}
        var records:[Job]=[]
        for n in 0..<jobs {
            let quote=Quote(projectID:project.id,revisionID:revision.id,digest:digest,upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(60),confirmed:true)
            var job=Job(workspaceID:workspace.id,projectID:project.id,revisionID:revision.id,digest:digest,requestKey:"fixture-\(n)",quote:quote);job.state = .needsReview;job.progress=1
            let outputs=[("video.mp4","video/mp4"),("cover.png","image/png"),("captions.srt","application/x-subrip"),("publication.txt","text/plain")]
            for (filename,mime) in outputs {let data=Data("real fixture bytes \(n) \(filename)".utf8),file=repo.root.appendingPathComponent("exports/\(job.id)/\(filename)");try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:file);job.artifacts.append(Artifact(path:file.path,mime:mime,bytes:data.count,sha256:Codec.hash(data),revision:revision.id))}
            records.append(job)
        }
        change?(&records)
        try repo.transaction{$0.workspaces=[workspace];$0.products=[product];$0.projects=[project];$0.jobs=records}
        return Fixture(source:repo.root,moved:moved,project:project,jobs:records,generation:try repo.read().generation)
    }
    private func move(_ fixture:Fixture)throws {try fm.moveItem(at:fixture.source,to:fixture.moved)}
    private func target(_ fixture:Fixture,job:Int=0,artifact:Int=0)->URL {fixture.moved.appendingPathComponent("exports/\(fixture.jobs[job].id)/"+URL(fileURLWithPath:fixture.jobs[job].artifacts[artifact].path).lastPathComponent)}
    private func assertUnchanged(_ repository:Repository,_ fixture:Fixture,file:StaticString=#filePath,line:UInt=#line)throws {
        let state=try repository.read();XCTAssertEqual(state.generation,fixture.generation,file:file,line:line)
        XCTAssertEqual(try Codec.data(state.jobs),try Codec.data(fixture.jobs),file:file,line:line)
    }
    func testMovedWorkspaceRebindsFourOutputsAtomicallyPreservesHistoryAndBacksUp()throws {
        let fixture=try fixture(history:true);try move(fixture)
        let repository=try Repository(root:fixture.moved),state=try repository.read(),job=try XCTUnwrap(state.jobs.first)
        XCTAssertEqual(state.generation,fixture.generation+1);XCTAssertEqual(try Codec.data(state.projects),try Codec.data([fixture.project]))
        var restored=job;for i in restored.artifacts.indices{XCTAssertEqual(restored.artifacts[i].path,target(fixture,artifact:i).path);restored.artifacts[i].path=fixture.jobs[0].artifacts[i].path}
        XCTAssertEqual(try Codec.data(restored),try Codec.data(fixture.jobs[0]));try repository.verifyDelivery(job,revision:fixture.project.revisions[0])
        XCTAssertEqual(try repository.relocateHistoricalArtifacts(),0);XCTAssertEqual(try Repository(root:fixture.moved).read().generation,state.generation)
        let backup=try repository.backup(),destination=directory(),copy=try Repository.restore(backup,to:destination),copied=try XCTUnwrap(copy.read().jobs.first)
        try copy.verifyDelivery(copied,revision:fixture.project.revisions[0]);XCTAssertTrue(copied.artifacts.allSatisfy{$0.path.hasPrefix(copy.root.path+"/exports/"+job.id+"/")})
    }
    func testReadOnlyOpenNeverRewritesButVerifiedReadAndBackupUseCurrentBytes()throws {
        let fixture=try fixture();try move(fixture);let repository=try Repository(root:fixture.moved,readOnly:true)
        XCTAssertEqual(try repository.relocateHistoricalArtifacts(),0);try assertUnchanged(repository,fixture)
        let job=fixture.jobs[0];XCTAssertEqual(try repository.verifiedArtifactURL(job.artifacts[0],job:job,revision:fixture.project.current),target(fixture))
        _ = try repository.backup();try assertUnchanged(repository,fixture)
    }
    func testCorruptOneOutputKeepsWholeJobAndWorkspaceReadable()throws {
        let fixture=try fixture();try move(fixture);try Data(repeating:88,count:fixture.jobs[0].artifacts[2].bytes).write(to:target(fixture,artifact:2))
        let repository=try Repository(root:fixture.moved);try assertUnchanged(repository,fixture)
        XCTAssertThrowsError(try repository.verifyDelivery(fixture.jobs[0],revision:fixture.project.current));XCTAssertThrowsError(try repository.backup())
    }
    func testBadHistoryDoesNotPreventAnotherJobFromRecovering()throws {
        let fixture=try fixture(jobs:2);try move(fixture);try Data("corrupt".utf8).write(to:target(fixture,artifact:0))
        let repository=try Repository(root:fixture.moved),state=try repository.read()
        XCTAssertEqual(state.jobs[0].artifacts[0].path,fixture.jobs[0].artifacts[0].path);XCTAssertEqual(state.jobs[1].artifacts[0].path,target(fixture,job:1).path)
        XCTAssertEqual(state.generation,fixture.generation+1);try repository.verifyDelivery(state.jobs[1],revision:fixture.project.current)
    }
    func testFinalAndParentLinksInsideOrOutsideWorkspaceAreRejectedEverywhere()throws {
        for parent in [false,true] {for external in [false,true] {
            let fixture=try fixture();try move(fixture)
            let output=target(fixture),source=parent ? output.deletingLastPathComponent():output
            let destination=(external ? directory():fixture.moved.appendingPathComponent("internal-copy"))
            try fm.moveItem(at:source,to:destination);try fm.createSymbolicLink(at:source,withDestinationURL:destination)
            let repository=try Repository(root:fixture.moved);try assertUnchanged(repository,fixture)
            XCTAssertThrowsError(try repository.verifiedArtifactURL(fixture.jobs[0].artifacts[0],job:fixture.jobs[0],revision:fixture.project.current));XCTAssertThrowsError(try repository.verifyDelivery(fixture.jobs[0],revision:fixture.project.current));XCTAssertThrowsError(try repository.backup())
            XCTAssertThrowsError(try repository.scopedArtifactURL(projectID:fixture.project.id,revisionID:fixture.project.current.id,jobID:fixture.jobs[0].id,sha256:fixture.jobs[0].artifacts[0].sha256,access:WorkspaceAccessContext(workspaceID:fixture.project.workspaceID,principal:"owner")))
        }}
    }
    func testHardLinksAreRejectedEvenWhenBytesAndHashMatch()throws {
        let fixture=try fixture();try move(fixture);let link=fixture.moved.appendingPathComponent("second-link")
        try fm.linkItem(at:target(fixture),to:link);let repository=try Repository(root:fixture.moved);try assertUnchanged(repository,fixture)
        XCTAssertThrowsError(try repository.verifiedArtifactURL(fixture.jobs[0].artifacts[0],job:fixture.jobs[0],revision:fixture.project.current))
    }
    func testWrongJobRevisionDigestWorkspaceAndQuoteBindingsDoNotMigrate()throws {
        for mutation in 0..<6 {
            let fixture=try fixture(change:{jobs in switch mutation {case 0:jobs[0].projectID=Codec.id();case 1:jobs[0].revisionID=Codec.id();case 2:jobs[0].digest=String(repeating:"0",count:64);case 3:jobs[0].workspaceID=Codec.id();case 4:jobs[0].quote.digest=String(repeating:"0",count:64);default:jobs[0].artifacts[0].revision=Codec.id()}})
            try move(fixture);let repository=try Repository(root:fixture.moved);try assertUnchanged(repository,fixture)
            XCTAssertThrowsError(try repository.verifiedArtifactURL(fixture.jobs[0].artifacts[0],job:fixture.jobs[0],revision:fixture.project.current))
        }
    }
    func testUnrelatedRootTraversalWrongJobDirectoryAndMixedOriginsAreRejected()throws {
        for mutation in 0..<4 {
            let fixture=try fixture(change:{jobs in let path=jobs[0].artifacts[0].path
                switch mutation {case 0:jobs[0].artifacts[0].path="/unrelated/video.mp4";case 1:jobs[0].artifacts[0].path=path.replacingOccurrences(of:"/exports/",with:"/../exports/");case 2:jobs[0].artifacts[0].path=path.replacingOccurrences(of:"/exports/"+jobs[0].id+"/",with:"/exports/other-job/");default:jobs[0].artifacts[0].path="/different-root/exports/"+jobs[0].id+"/video.mp4"}})
            try move(fixture);let repository=try Repository(root:fixture.moved);try assertUnchanged(repository,fixture)
            XCTAssertThrowsError(try repository.verifiedArtifactURL(fixture.jobs[0].artifacts[0],job:fixture.jobs[0],revision:fixture.project.current))
        }
    }
    func testSingleGeneratedDraftRemainsScopedReadableAndBacksUpAfterMove()throws {
        var fixture=try fixture()
        do {let repo=try Repository(root:fixture.source);var job=fixture.jobs[0];let bytes=Data("original generated draft".utf8),path=repo.root.appendingPathComponent("drafts/"+job.id+".txt");try fm.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try bytes.write(to:path);job.artifacts=[Artifact(path:path.path,mime:"text/plain",bytes:bytes.count,sha256:Codec.hash(bytes),revision:job.revisionID)];try repo.transaction{$0.jobs=[job]};fixture.jobs=[job];fixture.generation=try repo.read().generation}
        try move(fixture);let repository=try Repository(root:fixture.moved),job=try XCTUnwrap(repository.read().jobs.first),artifact=job.artifacts[0]
        let scoped=try repository.scopedArtifactURL(projectID:fixture.project.id,revisionID:job.revisionID,jobID:job.id,sha256:artifact.sha256,access:WorkspaceAccessContext(workspaceID:job.workspaceID,principal:"owner"))
        XCTAssertEqual(scoped,repository.root.appendingPathComponent("drafts/"+job.id+".txt"));XCTAssertEqual(try repository.read().generation,fixture.generation+1)
        let copy=try Repository.restore(repository.backup(),to:directory()),copied=try XCTUnwrap(copy.read().jobs.first)
        XCTAssertEqual(try Data(contentsOf:copy.verifiedArtifactURL(copied.artifacts[0],job:copied,revision:fixture.project.current)),Data("original generated draft".utf8))
    }
    func testHistoricalManagedGenerationRemainsReadableAndCannotAutoRewrite()throws {
        let fixture=try fixture(),slot=directory(),generation="gen-"+Codec.id(),generationRoot=slot.appendingPathComponent("generations/"+generation),data=generationRoot.appendingPathComponent("data")
        try fm.createDirectory(at:generationRoot,withIntermediateDirectories:true);try fm.moveItem(at:fixture.source,to:data)
        try Data("managed slot".utf8).write(to:slot.appendingPathComponent(ManagedInstallRules.slotMarker))
        let marker=ManagedInstallGeneration(id:generation,product:.coreCLI,previousGeneration:nil,manifestDigest:"fixture",rollbackFloor:1,dataDigest:"fixture")
        try PropertyListEncoder().encode(marker).write(to:generationRoot.appendingPathComponent(ManagedInstallRules.markerName));try fm.createSymbolicLink(at:slot.appendingPathComponent("current"),withDestinationURL:slot.appendingPathComponent("generations/gen-"+Codec.id()))
        let repository=try Repository(root:data);try assertUnchanged(repository,fixture);XCTAssertThrowsError(try repository.relocateHistoricalArtifacts());try assertUnchanged(repository,fixture)
    }
}

final class BackupRestoreInventoryTests:XCTestCase {
    private let fm=FileManager.default
    private var temporary:[URL]=[]
    override func tearDown(){for url in temporary{try? fm.removeItem(at:url)};temporary=[];super.tearDown()}
    private func directory()->URL {let url=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("video-restore-inventory-"+Codec.id());temporary.append(url);return url}
    private func fixture()throws->(Repository,Asset,Repository.Backup) {
        let repository=try Repository(root:directory()),workspace=Workspace(name:"隔离恢复规则",owner:"isolated-owner")
        let asset=try repository.ingest(Data("原讲稿保持不变".utf8),name:"notes.txt",workspaceID:workspace.id,mediaType:"text")
        try repository.transaction{$0.workspaces=[workspace];$0.assets=[asset]}
        return(repository,asset,try PropertyListDecoder().decode(Repository.Backup.self,from:repository.backup()))
    }
    func testUnreferencedExportIsRejectedBeforeAnyDestinationWrite()throws {
        let(repository,asset,backup)=try fixture(),destination=directory(),before=try Codec.data(repository.read())
        var changed=backup;changed.exports=["exports/orphan/unreferenced.txt":Data("not bound to any original task".utf8)]
        XCTAssertThrowsError(try Repository.restore(PropertyListEncoder().encode(changed),to:destination))
        XCTAssertFalse(fm.fileExists(atPath:destination.path),"An invalid inventory must be rejected before creating the recovery directory")
        XCTAssertEqual(try Codec.data(repository.read()),before)
        XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),backup.assets[asset.relativePath])
    }
    func testUnreferencedSourceBlobIsRejectedBeforeAnyDestinationWrite()throws {
        let(repository,asset,backup)=try fixture(),destination=directory(),before=try Codec.data(repository.read())
        var changed=backup;let extra=Data("unreferenced source".utf8);changed.assets["assets/"+Codec.hash(extra)+".txt"]=extra
        XCTAssertThrowsError(try Repository.restore(PropertyListEncoder().encode(changed),to:destination))
        XCTAssertFalse(fm.fileExists(atPath:destination.path))
        XCTAssertEqual(try Codec.data(repository.read()),before)
        XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),backup.assets[asset.relativePath])
    }
    func testSharedSourceReferencesRemainOneVerifiedBlobAndRestoreBothRecords()throws {
        let(repository,asset,_)=try fixture(),destination=directory()
        var second=asset;second.id=Codec.id();second.name="同源另一引用.txt"
        try repository.transaction{$0.assets.append(second)}
        let data=try repository.backup(),envelope=try PropertyListDecoder().decode(Repository.Backup.self,from:data)
        XCTAssertEqual(envelope.assets.count,1)
        let restored=try Repository.restore(data,to:destination),state=try restored.read()
        XCTAssertEqual(state.assets.map(\.id),[asset.id,second.id]);try restored.verifyAssets(state)
    }
    func testLegacyV1SourceOnlyBackupStillRestoresWithoutExportInventory()throws {
        let(_,asset,backup)=try fixture(),destination=directory()
        var legacy=backup;legacy.version=1;legacy.exports=nil
        let restored=try Repository.restore(PropertyListEncoder().encode(legacy),to:destination)
        XCTAssertEqual(try restored.read().assets.first?.id,asset.id);try restored.verifyAssets(restored.read())
    }
}

final class RenderedPriceFreshnessTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_780_000_000)
    private func fixture(nextAmount:Decimal=200)throws->Revision {
        let boundary=now.addingTimeInterval(-60)
        let product=Product(workspaceID:"w",sku:"scheduled-price",name:"课程",checkout:"https://example.com/course",audience:"学习者",task:"学习",outcome:"可复现",prerequisite:"无",scope:"一个例子",prices:[Price(money:Money(99),from:now.addingTimeInterval(-10000),until:boundary,source:"已核旧价",verified:true),Price(money:Money(nextAmount),from:boundary,source:"已核新价",verified:true)])
        var scene=Scene(title:"课程内容",body:"按真实材料操作");scene.showPrice=true
        var revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[scene],cta:"查看课程内容",change:"先前制作");revision.createdAt=now.addingTimeInterval(-3600)
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[],now:revision.createdAt)
        revision.review.text=true;revision.review.rights=true;revision.review.fullPreview=true;revision.review.sound=true;revision.review.captions=true;revision.review.digest=try revision.contentDigest();revision.review.reviewer="owner";revision.review.at=revision.createdAt
        return revision
    }
    private func issues(_ revision:Revision,at:Date?=nil,review:Bool=true)throws->[QualityIssue] {var database=Database();database.products=[revision.product!];return try Quality.inspect(revision,database:database,requireReview:review,now:at ?? now,enforceBrandDelivery:false)}
    func testUnchangedProductAndApprovedOldRevisionAreBlockedAfterScheduledPriceChange()throws {
        let revision=try fixture(),before=try Codec.data(revision)
        XCTAssertTrue(revision.review.complete);XCTAssertTrue(try issues(revision,at:revision.createdAt).isEmpty)
        XCTAssertTrue(try issues(revision).contains{$0.id=="stale_rendered_price"})
        XCTAssertTrue(try issues(revision,review:false).contains{$0.id=="stale_rendered_price"})
        XCTAssertEqual(try Codec.data(revision),before)
        var teaching=revision;teaching.purpose = .education
        XCTAssertTrue(try issues(teaching,review:false).contains{$0.id=="stale_rendered_price"})
    }
    func testNewPriceRecordWithSameMoneyDoesNotInvalidateVisiblePrice()throws {
        let revision=try fixture(nextAmount:99)
        XCTAssertNotEqual(revision.product!.prices[0].id,revision.product!.prices[1].id)
        XCTAssertFalse(try issues(revision).contains{$0.id=="stale_rendered_price"})
    }
    func testNewRevisionAtCurrentPricePassesFreshnessButStillNeedsItsOwnReview()throws {
        var revision=try fixture();revision.parentID=revision.id;revision.id=Codec.id();revision.number+=1;revision.createdAt=now;revision.review=Review()
        XCTAssertFalse(try issues(revision,review:false).contains{$0.id=="stale_rendered_price"})
        XCTAssertTrue(try issues(revision).contains{$0.id=="review"})
    }
    func testExplicitProductPriceCTATriggersGateButOrdinaryNumbersAndHistoricalTextDoNot()throws {
        var revision=try fixture();revision.scenes[0].showPrice=false;revision.cta="课程价格99元"
        XCTAssertTrue(try issues(revision,review:false).contains{$0.id=="stale_rendered_price"})
        revision.cta="价格200元";XCTAssertTrue(try issues(revision,review:false).contains{$0.id=="stale_rendered_price"})
        revision.cta="练习3个步骤";XCTAssertFalse(try issues(revision,review:false).contains{$0.id=="stale_rendered_price"})
        revision.cta="查看历史价格分析";revision.scenes[0].body="比较历史99元与200元的示例";XCTAssertFalse(try issues(revision,review:false).contains{$0.id=="stale_rendered_price"})
    }
}
