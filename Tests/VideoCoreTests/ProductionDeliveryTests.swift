import XCTest
@testable import VideoCore

final class ProductionDeliveryTests:XCTestCase {
    private func fixture(approval:Bool=true)throws->(Database,String) {
        var db=Database();var workspace=Workspace(name:"隔离制作规则",owner:"rules");workspace.id="w";db.workspaces=[workspace]
        var evidence=Evidence(workspaceID:"w",title:"规则中的授权凭据",source:"isolated-authorized-document",claim:"本制作允许教学使用",owner:"规则权利人",commercialAllowed:true,verified:true)
        evidence.checkedAt=Date().addingTimeInterval(-5);db.evidence=[evidence]
        var revision=try Planner.create(workspaceID:"w",name:"普通受托视频",aspect:.landscape,scenes:[Scene(title:"解释概念",body:"对照原材料理解概念。")])
        revision.purpose = .brand
        revision.productionBrief=ProductionBrief(objective:"讲解概念",intendedUse:"约定的教学成片",modifications:"保留来源",commercialDisclosure:"受托制作内容",evidenceIDs:[evidence.id],permittedUntil:Date().addingTimeInterval(3600),approvalRequired:approval)
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:db.evidence)
        revision.review.text=true;revision.review.rights=true;revision.review.sound=true;revision.review.captions=true;revision.review.fullPreview=true
        revision.review.digest=try revision.contentDigest();revision.review.at=Date();revision.review.reviewer="规则作者"
        let project=Project(workspaceID:"w",name:"普通受托视频",revision:revision);db.projects=[project]
        let digest=try revision.contentDigest()
        let quote=Quote(projectID:project.id,revisionID:revision.id,digest:digest,upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(3600),confirmed:true)
        var job=Job(workspaceID:"w",projectID:project.id,revisionID:revision.id,digest:digest,requestKey:"rules-production",quote:quote)
        job.state = .succeeded;job.artifacts=["video/mp4","image/png","application/x-subrip","text/plain"].enumerated().map{index,mime in Artifact(path:"/isolated-rules/"+String(index),mime:mime,bytes:1,sha256:String(repeating:String(index),count:64),revision:revision.id)}
        db.jobs=[job];return(db,project.id)
    }
    private func approve(_ db:inout Database,_ id:String)throws{try db.approveProduction(projectID:id,revisionID:db.project(id).current.id,reviewer:"本机明确审稿声明",note:"规则用指定版审批")}
    func testOrdinaryBrandContentNeedsProductionApprovalButNoSalesOrChannelAccount()throws {
        var (db,id)=try fixture()
        XCTAssertTrue(db.products.isEmpty);XCTAssertTrue(db.brandDeals.isEmpty);XCTAssertTrue(db.publications.isEmpty)
        XCTAssertTrue(try Quality.inspect(db.project(id).current,database:db,requireReview:false).isEmpty)
        XCTAssertTrue(try Quality.inspect(db.project(id).current,database:db,requireReview:true,enforceBrandDelivery:false).isEmpty)
        XCTAssertFalse(try Quality.inspect(db.project(id).current,database:db,requireReview:true).isEmpty)
        try approve(&db,id)
        XCTAssertTrue(try Quality.inspect(db.project(id).current,database:db,requireReview:true).isEmpty)
    }
    func testOldApprovalCannotCoverNewVersionOrModifiedTerms()throws {
        var (db,id)=try fixture();try approve(&db,id)
        var scene=db.projects[0].current.scenes[0];scene.body="实际修改后的解释。"
        let updated=try Editor.apply([.replaceScene(scene.id,scene)],to:db.projects[0],baseRevision:db.projects[0].current.id,assets:[],message:"修改")
        db.projects[0]=updated
        XCTAssertFalse(ProductionDeliveryRules.inspect(revision:updated.current,database:db).isEmpty)
        XCTAssertThrowsError(try db.approveProduction(projectID:id,revisionID:updated.revisions[0].id,reviewer:"审稿",note:"过时"))
    }
    func testRightsChangeNeedsApprovalAgainButSearchTagsDoNot()throws {
        var (db,id)=try fixture();try approve(&db,id)
        db.evidence[0].tags=["查找用"]
        XCTAssertTrue(ProductionDeliveryRules.inspect(revision:db.projects[0].current,database:db).isEmpty)
        db.evidence[0].claim="适用范围已变化"
        XCTAssertFalse(ProductionDeliveryRules.inspect(revision:db.projects[0].current,database:db).isEmpty)
    }
    func testUnresolvedCommentsAndInsufficientAuthorizationPeriodRejectApproval()throws {
        var (db,id)=try fixture()
        db.projects[0].comments=[Comment(revisionID:db.projects[0].current.id,sceneID:nil,frame:0,element:"整片",text:"请修改",author:"规则审稿")]
        XCTAssertThrowsError(try approve(&db,id))
        db.projects[0].comments[0].resolved=true;db.evidence[0].expiresAt=Date().addingTimeInterval(30)
        XCTAssertThrowsError(try approve(&db,id))
        db.evidence[0].expiresAt=Date().addingTimeInterval(7200)
        // Extending permission changes a frozen dependency. The old review must
        // still fail; only a normal new version with an explicit review can pass.
        XCTAssertThrowsError(try approve(&db,id))
        let prior=db.projects[0].current
        db.projects[0]=try Editor.apply([.productionBrief(prior.productionBrief)],to:db.projects[0],baseRevision:prior.id,assets:[],message:"核验更新后的许可")
        let i=db.projects[0].revisions.count-1
        db.projects[0].revisions[i].dependencies=try DependencyRules.freeze(revision:db.projects[0].current,assets:[],evidence:db.evidence)
        var reviewed=prior.review
        reviewed.reviewer="规则中的重新看听声明";reviewed.at=Date()
        reviewed.digest=try db.projects[0].current.contentDigest()
        db.projects[0].revisions[i].review=reviewed
        try approve(&db,id)
    }
    func testUsePeriodAlsoCoversSceneRightsOutsideManuallySelectedBriefEvidence()throws {
        var (db,_)=try fixture()
        db.projects[0].revisions[0].productionBrief?.evidenceIDs=[]
        db.projects[0].revisions[0].scenes[0].evidenceIDs=[db.evidence[0].id]
        db.evidence[0].expiresAt=Date().addingTimeInterval(30)
        XCTAssertFalse(ProductionDeliveryRules.inspect(revision:db.projects[0].current,database:db,requireApproval:false).isEmpty)
    }
    func testExpiredUsePreservesHistoricalRecordsButRejectsNewDelivery()throws {
        var (db,id)=try fixture();try approve(&db,id)
        let past=Date().addingTimeInterval(-1)
        db.projects[0].revisions[0].productionBrief?.permittedUntil=past
        XCTAssertFalse(ProductionDeliveryRules.inspect(revision:db.projects[0].current,database:db).isEmpty)
        XCTAssertEqual(db.projects[0].productionApprovals?.count,1)
    }
    func testFourArtifactReadBackHashesAndCurrentJobAreRequiredToRecordExport()throws {
        var (db,id)=try fixture();try approve(&db,id)
        let hashes=Dictionary(uniqueKeysWithValues:db.jobs[0].artifacts.map{($0.mime,$0.sha256)})
        var broken=hashes;broken.removeValue(forKey:"text/plain")
        XCTAssertThrowsError(try db.recordProductionDelivery(projectID:id,jobID:db.jobs[0].id,destinationName:"规则文件夹",artifactHashes:broken))
        try db.recordProductionDelivery(projectID:id,jobID:db.jobs[0].id,destinationName:"规则文件夹",artifactHashes:hashes)
        XCTAssertEqual(db.projects[0].deliveryRecords?.first?.state,"files_exported")
        XCTAssertEqual(db.projects[0].deliveryRecords?.first?.artifactHashes.count,4)
        XCTAssertNoThrow(try ProductionDeliveryRules.validate(project:db.projects[0],assets:[],evidence:db.evidence))
        db.jobs[0].digest="outdated"
        XCTAssertThrowsError(try db.recordProductionDelivery(projectID:id,jobID:db.jobs[0].id,destinationName:"另一位置",artifactHashes:hashes))
    }
    func testOverlappingConfirmedCaptionsCannotPassFinalQuality()throws {
        var (db,id)=try fixture();try approve(&db,id)
        db.projects[0].revisions[0].scenes[0].captions=[Caption(text:"第一段",startFrame:0,endFrame:60,confirmed:true),Caption(text:"重叠段",startFrame:30,endFrame:80,confirmed:true)]
        XCTAssertTrue(try Quality.inspect(db.projects[0].current,database:db,requireReview:false).contains{$0.id.hasSuffix("caption_ranges")})
    }
    func testOptionalFieldsPreservePriorEncodingAndLegacyDigest()throws {
        let revision=try Planner.create(workspaceID:"w",name:"不含交易",aspect:.landscape,scenes:[])
        let object=try JSONSerialization.jsonObject(with:Codec.data(revision)) as! [String:Any]
        XCTAssertNil(object["productionBrief"])
        let decoded=try Codec.decoder().decode(Revision.self,from:Codec.data(revision))
        XCTAssertEqual(try decoded.contentDigest(),try revision.contentDigest())
        let project=Project(workspaceID:"w",name:"普通工程",revision:revision)
        let p=try JSONSerialization.jsonObject(with:Codec.data(project)) as! [String:Any]
        XCTAssertNil(p["productionApprovals"]);XCTAssertNil(p["deliveryRecords"])
    }
    func testRestoreAlsoRestoresPurposeAndProductionBriefAndRevokesAuthorReview()throws {
        var (db,_)=try fixture();let original=db.projects[0].current
        let changed=try Editor.apply([.purpose(.education),.productionBrief(nil)],to:db.projects[0],baseRevision:original.id,assets:[],message:"修改用途")
        let restored=try Editor.apply([.restore(original.id)],to:changed,baseRevision:changed.current.id,assets:[],message:"恢复")
        XCTAssertEqual(restored.current.purpose,original.purpose)
        XCTAssertEqual(restored.current.productionBrief,original.productionBrief)
        XCTAssertFalse(restored.current.review.complete)
        db.projects[0]=restored
    }
}
