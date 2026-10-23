import XCTest
@testable import VideoCore

final class ContentWorkflowIntegrationTests:XCTestCase {
    private func fixture()throws->(Database,Workspace,Project) {
        var db=Database();let w=Workspace(name:"制作空间",owner:"author");db.workspaces=[w]
        var first=try Planner.create(workspaceID:w.id,name:"材料剪辑",aspect:.landscape,scenes:[Scene(title:"所授镜头",body:"公开给受邀者的本版文字")])
        first.dependencies=try DependencyRules.freeze(revision:first,assets:[],evidence:[])
        var next=first;next.id=Codec.id();next.number=2;next.parentID=first.id;next.scenes[0].body="UNSHARED_NEXT_VERSION"
        var project=Project(workspaceID:w.id,name:"历史版本工程",revision:first);project.revisions.append(next);project.tags=["课程"];db.projects=[project]
        return(db,w,project)
    }
    func testProductionSearchExcludesLegacyFinanceAndDiscoversAllOwnVersions()throws {
        var(db,w,p)=try fixture()
        let order=try Order(workspaceID:w.id,platform:"legacy",rawOrderID:"PRIVATE_LEGACY_ORDER",rawBuyerID:"PRIVATE_BUYER",salt:w.salt,sku:"old",paidAt:Date(),paid:Money(10),fee:0,importID:"old-import")
        db.orders=[order];db.imports=[ImportReceipt(id:"old-import",kind:"orders",orderIDs:[order.id])]
        var q=WorkspaceSearchQuery();q.productionOnly=true
        let rows=try WorkspaceAccessRules.search(query:q,access:WorkspaceAccessContext(workspaceID:w.id,principal:w.owner),in:db)
        XCTAssertEqual(rows.filter{$0.kind == .version}.count,p.revisions.count)
        XCTAssertFalse(rows.contains{$0.kind == .order || $0.objectID=="old-import" || $0.detail.contains("PRIVATE")})
        q.kinds=[.order]
        XCTAssertThrowsError(try WorkspaceAccessRules.search(query:q,access:WorkspaceAccessContext(workspaceID:w.id,principal:w.owner),in:db))
    }
    func testScopedVersionSearchNeverFindsOtherRevisionOrWorkspaceCatalogAndRevocationStopsReads()throws {
        var(db,w,p)=try fixture()
        db.workspaces[0].grants=[Grant(principal:"actual-bound-reviewer",role:.reviewer,projectIDs:[p.id],revisionIDs:[p.revisions[0].id],expiresAt:Date().addingTimeInterval(300))]
        db.narrativeTemplates=[NarrativeTemplate(workspaceID:w.id,name:"PRIVATE_TEMPLATE")]
        var q=WorkspaceSearchQuery();q.productionOnly=true
        let access=WorkspaceAccessContext(workspaceID:w.id,principal:"actual-bound-reviewer")
        let rows=try WorkspaceAccessRules.search(query:q,access:access,in:db)
        XCTAssertEqual(rows.filter{$0.kind == .version}.map(\.objectID),[p.revisions[0].id])
        XCTAssertFalse(rows.contains{$0.kind == .template || $0.detail.contains("UNSHARED_NEXT_VERSION") || $0.title.contains("PRIVATE_TEMPLATE")})
        db.workspaces[0].grants[0].revoked=true
        XCTAssertThrowsError(try WorkspaceAccessRules.search(query:q,access:access,in:db))
    }
    func testCatalogTagsDatesAndWorkspaceAreFilteredWithoutInventingLegacyTimes()throws {
        var(db,w,_)=try fixture()
        var current=NarrativeTemplate(workspaceID:w.id,name:"当前教学模板");current.tags=["知识","短片"];current.createdAt=Date()
        var legacy=NarrativeTemplate(workspaceID:w.id,name:"旧模板");legacy.tags=["知识"];legacy.createdAt=nil
        var foreign=current;foreign.id=Codec.id();foreign.workspaceID="foreign"
        db.narrativeTemplates=[current,legacy,foreign]
        var q=WorkspaceSearchQuery();q.productionOnly=true;q.kinds=[.template];q.tags=["知识"];q.from=Date().addingTimeInterval(-60);q.through=Date().addingTimeInterval(60)
        let access=WorkspaceAccessContext(workspaceID:w.id,principal:w.owner)
        XCTAssertEqual(try WorkspaceAccessRules.search(query:q,access:access,in:db).map(\.objectID),[current.id])
        q.from=nil;q.through=nil
        XCTAssertEqual(try WorkspaceAccessRules.search(query:q,access:access,in:db).count,2)
        try TagRules.apply(kind:.template,objectID:current.id,tags:["重新归类"],access:access,in:&db)
        XCTAssertEqual(db.narrativeTemplates?[0].tags,["重新归类"])
    }
    func testCatalogNilMetadataKeepsOldEncodedShapeAndDecodeDoesNotInventCreationTime()throws {
        var value=StyleKit(workspaceID:"w",name:"旧风格");value.createdAt=nil;value.tags=nil
        let encoded=try Codec.data(value)
        let object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        XCTAssertNil(object["createdAt"]);XCTAssertNil(object["tags"])
        let decoded=try Codec.decoder().decode(StyleKit.self,from:encoded)
        XCTAssertNil(decoded.createdAt);XCTAssertEqual(try Codec.data(decoded),encoded)
    }
    func testBriefRightsAndOriginalDocumentJoinFrozenCloudScopeAndRequireUploadConsent()throws {
        var(db,w,_)=try fixture()
        var source=Asset(workspaceID:w.id,name:"授权原件",hash:String(repeating:"a",count:64),ext:"pdf",bytes:123,mediaType:"document")
        let sourceRights=Evidence(workspaceID:w.id,title:"原件使用许可",source:"signed-document",claim:"允许核对原件",owner:"权利方",commercialAllowed:true,uploadConsent:true,verified:true)
        source.evidenceID=sourceRights.id
        let briefRights=Evidence(workspaceID:w.id,title:"制作许可",source:"signed-production-terms",claim:"允许本次制作",owner:"权利方",commercialAllowed:true,uploadConsent:false,verified:true,assetID:source.id)
        db.assets=[source];db.evidence=[sourceRights,briefRights]
        var revision=db.projects[0].current
        revision.parentID=revision.id;revision.id=Codec.id();revision.number += 1
        revision.productionBrief=ProductionBrief(objective:"讲解步骤",intendedUse:"教学片",evidenceIDs:[briefRights.id])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:db.assets,evidence:db.evidence)
        db.projects[0].revisions.append(revision)
        let ids=Set(revision.dependencies!.records.map(\.id))
        XCTAssertTrue(ids.contains("evidence:"+briefRights.id));XCTAssertTrue(ids.contains("asset:"+source.id));XCTAssertTrue(ids.contains("evidence:"+sourceRights.id))
        let p=db.projects[0],access=WorkspaceAccessContext(workspaceID:w.id,principal:w.owner)
        let scope=try WorkspaceAccessRules.readModel(projectID:p.id,revisionID:revision.id,access:access,in:db)
        let preview=ScopedArtifact(id:"preview",jobID:"real-job",mime:"video/mp4",sha256:String(repeating:"b",count:64),bytes:1)
        var checkedScope=scope;checkedScope.artifacts=[preview]
        XCTAssertThrowsError(try CloudReviewRules.prepare(scope:checkedScope,preview:preview,role:.collaborator,expiresAt:Date().addingTimeInterval(300)))
    }
    func testNativeZeroBatchStillPinsVersionWhileForeignCurrencyDoesNotBlockFreeLocalWork()throws {
        var(db,w,p)=try fixture()
        let variant=TeachingVariant(name:"美元预算条目",hook:"同材料不同开场",aspect:.landscape,budget:Money(0,"USD"))
        let batch=try TeachingBatchRules.create(database:&db,workspaceID:w.id,title:"原币对照",sourceProjectID:p.id,variants:[variant])
        let project=try db.project(XCTUnwrap(batch.items[0].projectID))
        let quote=Quote(projectID:project.id,revisionID:project.current.id,digest:try project.current.contentDigest(),upper:Money(0,"CNY"),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(300),confirmed:true)
        XCTAssertNoThrow(try TeachingBatchRules.validateSubmission(project:project,quote:quote,batches:db.teachingBatches ?? []))
        var changed=quote;changed.digest="wrong-frozen-version"
        XCTAssertThrowsError(try TeachingBatchRules.validateSubmission(project:project,quote:changed,batches:db.teachingBatches ?? []))
        var remote=quote;remote.provider="real-remote"
        XCTAssertThrowsError(try TeachingBatchRules.validateSubmission(project:project,quote:remote,batches:db.teachingBatches ?? []))
    }
    func testBatchSearchReflectsLatestJobAndMatchesRequestedItemState()throws {
        var(db,w,p)=try fixture()
        let variant=TeachingVariant(name:"真实状态条目",hook:"对照开场",aspect:.landscape,budget:Money(10,"USD"))
        let batch=try TeachingBatchRules.create(database:&db,workspaceID:w.id,title:"创作批次",sourceProjectID:p.id,variants:[variant])
        let project=try db.project(XCTUnwrap(batch.items[0].projectID))
        let quote=Quote(projectID:project.id,revisionID:project.current.id,digest:try project.current.contentDigest(),upper:Money(3,"USD"),unit:"USD",provider:"real-remote",expiresAt:Date().addingTimeInterval(300),confirmed:true)
        var job=Job(workspaceID:w.id,projectID:project.id,revisionID:project.current.id,digest:try project.current.contentDigest(),requestKey:"status-rule",quote:quote);job.state = .failed;db.jobs=[job]
        var q=WorkspaceSearchQuery();q.productionOnly=true;q.kinds=[.batch];q.statuses=["failed"]
        let access=WorkspaceAccessContext(workspaceID:w.id,principal:w.owner)
        let failed=try WorkspaceAccessRules.search(query:q,access:access,in:db)
        XCTAssertEqual(failed.map(\.objectID),[batch.id]);XCTAssertEqual(failed.first?.status,"failed")
        db.jobs[0].state = .needsReview;q.statuses=["needs_review"]
        let waiting=try WorkspaceAccessRules.search(query:q,access:access,in:db)
        XCTAssertEqual(waiting.map(\.objectID),[batch.id]);XCTAssertTrue(waiting[0].detail.contains(TopicBatchState.needsReview.rawValue))
        q.statuses=["failed"];XCTAssertTrue(try WorkspaceAccessRules.search(query:q,access:access,in:db).isEmpty)
    }

}
