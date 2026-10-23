import XCTest
@testable import VideoCore

final class WorkspaceAccessTests:XCTestCase {
    private func fixture() throws -> (Database,Workspace,Project,WorkspaceAccessContext) {
        var database=Database()
        var workspace=Workspace(name:"客户甲",owner:"author")
        let other=Workspace(name:"客户乙",owner:"other-owner")
        let product=Product(workspaceID:workspace.id,sku:"existing",name:"甲的课程",checkout:"https://example.com/course",audience:"初学者",task:"操作软件",outcome:"完成真实操作",prerequisite:"无",scope:"基础操作",prices:[Price(money:Money(99),from:.distantPast,source:"课程现价",verified:true)])
        let first=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"获准教学内容",body:"第一版允许审核")],cta:product.checkout)
        var second=first;second.id=Codec.id();second.parentID=first.id;second.number=2;second.scenes[0].body="PRIVATE_UNSHARED_REVISION";second.change="PRIVATE_UNSHARED_REVISION"
        var project=Project(workspaceID:workspace.id,name:"甲的项目",revision:first);project.revisions.append(second);project.tags=["教学","甲"]
        workspace.grants=[Grant(principal:"brand-reviewer",role:.reviewer,projectIDs:[project.id],revisionIDs:[first.id],expiresAt:Date().addingTimeInterval(3600)),Grant(principal:"editor",role:.collaborator,projectIDs:[project.id],revisionIDs:[first.id],expiresAt:Date().addingTimeInterval(3600))]
        var otherProduct=product;otherProduct.id=Codec.id();otherProduct.workspaceID=other.id;otherProduct.name="PRIVATE_OTHER_CUSTOMER"
        var otherRevision=first;otherRevision.id=Codec.id();otherRevision.product=otherProduct
        let otherProject=Project(workspaceID:other.id,name:"PRIVATE_OTHER_CUSTOMER",revision:otherRevision)
        database.workspaces=[workspace,other];database.products=[product,otherProduct];database.projects=[project,otherProject]
        database.orders=[try Order(workspaceID:workspace.id,platform:"course-platform",rawOrderID:"secret-order-raw",rawBuyerID:"secret-buyer-raw",salt:workspace.salt,sku:product.sku,paidAt:Date(),paid:Money(99),fee:0,importID:"batch")]
        database.providers=[ProviderProfile(name:"PRIVATE_PROVIDER",endpoint:"https://example.com/api",model:"PRIVATE_MODEL",supportedParameters:[],keyReference:"PRIVATE_KEYCHAIN_REFERENCE")]
        return(database,workspace,project,WorkspaceAccessContext(workspaceID:workspace.id,principal:"brand-reviewer"))
    }
    func testSearchOnlyFindsAuthorizedWorkspaceAndRevision() throws {
        let(database,workspace,project,access)=try fixture()
        let results=try WorkspaceAccessRules.search(query:WorkspaceSearchQuery(),access:access,in:database)
        let projects=results.filter{$0.kind == .project}
        XCTAssertEqual(projects.count,1);XCTAssertEqual(projects[0].revisionID,project.revisions[0].id)
        XCTAssertFalse(results.contains{$0.kind == .order || $0.title.contains("PRIVATE") || $0.detail.contains("PRIVATE")})
        var query=WorkspaceSearchQuery();query.text="PRIVATE_OTHER_CUSTOMER"
        XCTAssertTrue(try WorkspaceAccessRules.search(query:query,access:WorkspaceAccessContext(workspaceID:workspace.id,principal:workspace.owner),in:database).isEmpty)
        query.projectID=project.id;query.revisionID=project.current.id
        XCTAssertThrowsError(try WorkspaceAccessRules.search(query:query,access:access,in:database))
    }
    func testCollaboratorExplicitFinancialSearchIsRejected() throws {
        let(database,_,_,access)=try fixture();var query=WorkspaceSearchQuery();query.kinds=[.order]
        XCTAssertThrowsError(try WorkspaceAccessRules.search(query:query,access:access,in:database)) {error in XCTAssertEqual((error as? VideoError)?.code,"permission_required")}
    }
    func testScopedReadModelDoesNotSerializeOtherRevisionOrCredentials() throws {
        let(database,workspace,project,access)=try fixture()
        let value=try WorkspaceAccessRules.readModel(projectID:project.id,revisionID:project.revisions[0].id,access:access,in:database)
        let json=try XCTUnwrap(String(data:Codec.data(value),encoding:.utf8))
        for forbidden in [workspace.salt,"PRIVATE_OTHER_CUSTOMER","PRIVATE_UNSHARED_REVISION","PRIVATE_PROVIDER","PRIVATE_MODEL","PRIVATE_KEYCHAIN_REFERENCE","secret-order-raw","secret-buyer-raw",database.orders[0].buyer] {XCTAssertFalse(json.contains(forbidden),forbidden)}
        XCTAssertTrue(json.contains("第一版允许审核"))
    }
    func testRevocationAndExpiryApplyToEveryFreshRepositoryReadAndComment() throws {
        let(database,workspace,project,access)=try fixture()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("access-revoke-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root);try repository.transaction{$0=database}
        _=try repository.revisionReadModel(projectID:project.id,revisionID:project.revisions[0].id,access:access)
        _=try repository.appendScopedComment(projectID:project.id,revisionID:project.revisions[0].id,sceneID:nil,frame:0,element:"整片",text:"请核实该例子",access:access)
        try repository.transaction {db in let w=db.workspaces.firstIndex{$0.id==workspace.id}!;db.workspaces[w].grants[0].revoked=true}
        XCTAssertThrowsError(try repository.search(query:WorkspaceSearchQuery(),access:access))
        XCTAssertThrowsError(try repository.revisionReadModel(projectID:project.id,revisionID:project.revisions[0].id,access:access))
        XCTAssertThrowsError(try repository.appendScopedComment(projectID:project.id,revisionID:project.revisions[0].id,sceneID:nil,frame:0,element:"整片",text:"已撤销不得写入",access:access))
        let future=Date().addingTimeInterval(7200)
        XCTAssertThrowsError(try WorkspaceAccessRules.readModel(projectID:project.id,revisionID:project.revisions[0].id,access:access,in:database,now:future))
        XCTAssertEqual(try repository.read().projects[0].comments.count,1)
    }
    func testReviewerCanCommentOnlyExistingElementsButCannotEdit() throws {
        let(database,_,project,access)=try fixture()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("access-comment-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root);try repository.transaction{$0=database}
        let revision=project.revisions[0]
        let comment=try repository.appendScopedComment(projectID:project.id,revisionID:revision.id,sceneID:revision.scenes[0].id,frame:0,element:"正文",text:"核对当前表述",access:access)
        XCTAssertEqual(comment.author,access.principal)
        XCTAssertThrowsError(try repository.appendScopedComment(projectID:project.id,revisionID:revision.id,sceneID:revision.scenes[0].id,frame:0,element:"不属于场景的元素",text:"错误元素",access:access))
        XCTAssertThrowsError(try repository.applyScopedEdits(projectID:project.id,baseRevision:revision.id,operations:[.cta("新CTA")],message:"不允许",access:access))
    }
    func testTwoEditorsUsingSameBaseDoNotOverwriteNewerVersion() throws {
        var(database,workspace,project,_)=try fixture()
        project.revisions=[project.revisions[0]];database.projects[0]=project
        let access=WorkspaceAccessContext(workspaceID:workspace.id,principal:"editor")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("access-concurrency-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let first=try Repository(root:root);try first.transaction{$0=database};let second=try Repository(root:root)
        let created=try first.applyScopedEdits(projectID:project.id,baseRevision:project.current.id,operations:[.cta("第一客户端CTA")],message:"第一客户端",access:access)
        XCTAssertThrowsError(try second.applyScopedEdits(projectID:project.id,baseRevision:project.current.id,operations:[.cta("第二客户端CTA")],message:"第二客户端",access:access)) {error in XCTAssertEqual((error as? VideoError)?.code,"revision_conflict")}
        XCTAssertEqual(try second.read().projects[0].current.id,created.id);XCTAssertEqual(try second.read().projects[0].current.cta,"第一客户端CTA")
    }
    private func historyFixture() throws -> (Database,Workspace,Project,WorkspaceAccessContext) {
        var(database,workspace,project,_)=try fixture()
        project.revisions[0].scenes[0].body="PRIVATE_HISTORY_NOT_GRANTED"
        project.revisions[0].product!.name="PRIVATE_HISTORICAL_PRODUCT"
        project.revisions[1].scenes[0].body="当前获准编辑的版本"
        workspace.grants=[Grant(principal:"editor",role:.collaborator,projectIDs:[project.id],revisionIDs:[project.current.id],expiresAt:Date().addingTimeInterval(3600))]
        database.workspaces[0]=workspace;database.projects[0]=project
        return(database,workspace,project,WorkspaceAccessContext(workspaceID:workspace.id,principal:"editor"))
    }
    func testCollaboratorCannotRestoreUnsharedHistoryOrCommitEarlierOperations() throws {
        let(database,_,project,access)=try historyFixture()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("access-restore-denied-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root);try repository.transaction{$0=database}
        let before=try Codec.digest(repository.read())
        XCTAssertThrowsError(try repository.applyScopedEdits(projectID:project.id,baseRevision:project.current.id,operations:[.cta("不得提交的前序改动"),.restore(project.revisions[0].id)],message:"越权恢复",access:access)) {error in XCTAssertEqual((error as? VideoError)?.code,"permission_required")}
        XCTAssertEqual(try Codec.digest(repository.read()),before)
    }
    func testRevokedExpiredOrWrongScopeHistoryGrantCannotAuthorizeRestore() throws {
        let now=Date()
        for kind in ["revoked","expired","other-project","other-principal","other-workspace"] {
            var(database,workspace,project,access)=try historyFixture()
            var grant=Grant(principal:"editor",role:.reviewer,projectIDs:[project.id],revisionIDs:[project.revisions[0].id],expiresAt:now.addingTimeInterval(3600))
            if kind=="revoked"{grant.revoked=true}
            if kind=="expired"{grant.expiresAt=now.addingTimeInterval(-1)}
            if kind=="other-project"{grant.projectIDs=["unrelated-project"]}
            if kind=="other-principal"{grant.principal="other-editor"}
            if kind=="other-workspace"{database.workspaces[1].grants.append(grant)}else{workspace.grants.append(grant)}
            database.workspaces[0]=workspace
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("access-restore-"+kind+"-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
            let repository=try Repository(root:root);try repository.transaction{$0=database}
            XCTAssertThrowsError(try repository.applyScopedEdits(projectID:project.id,baseRevision:project.current.id,operations:[.restore(project.revisions[0].id)],message:"无有效来源授权",access:access,now:now)) {error in XCTAssertEqual((error as? VideoError)?.code,"permission_required",kind)}
            XCTAssertEqual(try repository.read().projects[0].revisions.count,2,kind)
        }
    }
    func testCollaboratorCanRestoreHistoryWithExplicitValidReadGrant() throws {
        var(database,workspace,project,access)=try historyFixture()
        workspace.grants.append(Grant(principal:access.principal,role:.reviewer,projectIDs:[project.id],revisionIDs:[project.revisions[0].id],expiresAt:Date().addingTimeInterval(3600)))
        database.workspaces[0]=workspace
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("access-restore-granted-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root);try repository.transaction{$0=database}
        let restored=try repository.applyScopedEdits(projectID:project.id,baseRevision:project.current.id,operations:[.restore(project.revisions[0].id)],message:"恢复明确授权来源",access:access)
        XCTAssertEqual(restored.scenes[0].body,"PRIVATE_HISTORY_NOT_GRANTED")
        XCTAssertEqual(restored.product!.name,"PRIVATE_HISTORICAL_PRODUCT")
        XCTAssertEqual(restored.parentID,project.current.id);XCTAssertEqual(restored.number,3)
        XCTAssertEqual(try repository.read().projects[0].revisions.count,3)
    }
    func testWorkspaceOwnerCanRestoreOwnHistoryWithoutCollaborationGrant() throws {
        let(database,workspace,project,_)=try historyFixture()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("access-restore-owner-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root);try repository.transaction{$0=database}
        let restored=try repository.applyScopedEdits(projectID:project.id,baseRevision:project.current.id,operations:[.restore(project.revisions[0].id)],message:"作者恢复历史",access:WorkspaceAccessContext(workspaceID:workspace.id,principal:workspace.owner))
        XCTAssertEqual(restored.scenes[0].body,project.revisions[0].scenes[0].body)
        XCTAssertEqual(restored.product!.name,project.revisions[0].product!.name)
        XCTAssertFalse(restored.review.complete)
    }
    func testKeywordTagStatusAndImportedTimeFiltersUseActualRecordDates() throws {
        var(database,workspace,_,_)=try fixture()
        let now=Date()
        var asset=Asset(workspaceID:workspace.id,name:"课堂录屏",hash:"a",ext:"mp4",bytes:1,mediaType:"video",durationFrames:30);asset.tags=["演示"];asset.importedAt=now
        var old=asset;old.id=Codec.id();old.name="旧录屏";old.importedAt=nil;database.assets=[asset,old]
        var query=WorkspaceSearchQuery();query.kinds=[.asset];query.text="课堂";query.tags=["演示"];query.statuses=["needs_review"];query.from=now.addingTimeInterval(-1);query.through=now.addingTimeInterval(1)
        let owner=WorkspaceAccessContext(workspaceID:workspace.id,principal:workspace.owner)
        let results=try WorkspaceAccessRules.search(query:query,access:owner,in:database)
        XCTAssertEqual(results.map(\.objectID),[asset.id]);XCTAssertEqual(results[0].at,now);XCTAssertEqual(results[0].dateBasis,"素材导入时间")
        query.text="";XCTAssertEqual(try WorkspaceAccessRules.search(query:query,access:owner,in:database).count,1)
    }
    func testEvidenceOrdersAndUnstartedBatchesHaveEditableScopedTags() throws {
        var(database,workspace,_,reviewer)=try fixture()
        let owner=WorkspaceAccessContext(workspaceID:workspace.id,principal:workspace.owner)
        let evidence=Evidence(workspaceID:workspace.id,title:"真实课件",source:"原件",claim:"操作演示",owner:"作者",commercialAllowed:true,verified:true)
        database.evidence=[evidence]
        let topic=Topic(workspaceID:workspace.id,productID:database.products[0].id,audience:"初学者",task:"操作软件",knowledge:"知识",hook:"如何操作",outcome:"完成真实操作",proof:"原件",grammar:"实操演示",cta:"了解课程",channel:"手工发布",evidenceIDs:[],series:"试验",budget:Money(0))
        let batch=try BatchRules.create(workspaceID:workspace.id,title:"尚未生成项目的批次",topics:[topic],products:database.products)
        database.topicBatches=[batch]
        try TagRules.apply(kind:.evidence,objectID:evidence.id,tags:["  待复盘 ","待复盘"],access:owner,in:&database)
        try TagRules.apply(kind:.order,objectID:database.orders[0].id,tags:["待复盘"],access:owner,in:&database)
        try TagRules.apply(kind:.batch,objectID:batch.id,tags:["待复盘"],access:owner,in:&database)
        var query=WorkspaceSearchQuery();query.tags=["待复盘"]
        let hits=try WorkspaceAccessRules.search(query:query,access:owner,in:database)
        XCTAssertEqual(Set(hits.map(\.kind)),[.evidence,.order,.batch])
        XCTAssertEqual(database.evidence[0].tags,["待复盘"])
        XCTAssertThrowsError(try TagRules.apply(kind:.order,objectID:database.orders[0].id,tags:["越权"],access:reviewer,in:&database))
        XCTAssertThrowsError(try TagRules.apply(kind:.product,objectID:database.products[1].id,tags:["越域"],access:owner,in:&database))
        XCTAssertThrowsError(try TagRules.normalized([String(repeating:"长",count:41)]))
    }
    func testOrderReimportPreservesLabelsAndRolledBackBatchKeepsItsScope() throws {
        var(database,workspace,_,_)=try fixture()
        let owner=WorkspaceAccessContext(workspaceID:workspace.id,principal:workspace.owner)
        database.orders[0].tags=["售后"]
        var update=database.orders[0];update.importID="next";update.tags=nil
        try database.importOrders([update],batchID:"next")
        XCTAssertEqual(database.orders[0].tags,["售后"])
        try TagRules.apply(kind:.batch,objectID:"next",tags:["对账"],access:owner,in:&database)
        try database.rollbackImport("next")
        var query=WorkspaceSearchQuery();query.kinds=[.batch];query.tags=["对账"];query.statuses=["rolled_back"]
        let hits=try WorkspaceAccessRules.search(query:query,access:owner,in:database)
        XCTAssertEqual(hits.map(\.objectID),["next"])
        let other=WorkspaceAccessContext(workspaceID:database.workspaces[1].id,principal:database.workspaces[1].owner)
        XCTAssertTrue(try WorkspaceAccessRules.search(query:query,access:other,in:database).isEmpty)
    }
}
