import XCTest
@testable import VideoCore

final class AgentMutationTests:XCTestCase {
    private func fixture()throws->(Repository,Workspace,Product) {
        let repo=try Repository(root:FileManager.default.temporaryDirectory.appendingPathComponent("agent-ledger-"+UUID().uuidString)),w=Workspace(name:"真实工作区",owner:"owner")
        let p=Product(workspaceID:w.id,sku:"one",name:"课程",checkout:"https://example.com/course",audience:"初学者",task:"理解上下文",outcome:"复现过程",prerequisite:"会用聊天",scope:"输入输出",prices:[Price(money:Money(10),from:.distantPast,source:"产品页",verified:true)])
        try repo.transaction{$0.workspaces=[w];$0.products=[p]};return(repo,w,p)
    }
    private func draft(_ w:Workspace,_ p:Product)->Data {try! Codec.data(AgentValue.object(["workspace_id":.string(w.id),"product_id":.string(p.id),"knowledge":.string("输入输出占用上下文"),"demonstration":.string("对照真实界面"),"hook":.string("为什么输出也占用容量")]))}
    func testDatabaseMutationAndCompleteResponseCommitTogetherAndReplayAcrossAdapters()throws {
        let(repo,w,p)=try fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let first=try repo.performAgentMutation(command:"script create",data:draft(w,p),principal:"owner",requestID:"stable")
        let second=try repo.performAgentMutation(command:"script create",data:draft(w,p),principal:"owner",requestID:"stable",origin:.nativeIntent)
        XCTAssertEqual(first,second);let db=try repo.read();XCTAssertEqual(db.projects.count,1);XCTAssertEqual(db.agentReplayRecords?.count,1);XCTAssertEqual(db.agentReplayRecords?.first?.response,first);XCTAssertTrue(db.jobs.isEmpty)
        let value=try XCTUnwrap(first.object);for key in ["job_id","error"]{XCTAssertEqual(value[key],.null)}
        var changed=try AgentContract.validate(command:"script create",data:draft(w,p));changed["hook"] = .string("改变内容")
        XCTAssertThrowsError(try repo.performAgentMutation(command:"script create",data:Codec.data(AgentValue.object(changed)),principal:"owner",requestID:"stable"));XCTAssertEqual(try repo.read().projects.count,1)
    }
    func testFailedDomainWriteRollsBackEntityAndReceipt()throws {
        let(repo,w,p)=try fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        var invalid=p;invalid.checkout="invalid";let data=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"product":try Codec.decoder().decode(AgentValue.self,from:Codec.data(invalid))]))
        XCTAssertThrowsError(try repo.performAgentMutation(command:"products import",data:data,principal:"owner",requestID:"rejected"))
        let db=try repo.read();XCTAssertEqual(db.products[0].checkout,p.checkout);XCTAssertTrue(db.agentReplayRecords?.isEmpty ?? true)
        _ = try repo.performAgentMutation(command:"script create",data:draft(w,p),principal:"owner",requestID:"rejected");XCTAssertEqual(try repo.read().projects.count,1)
    }
    func testReplayRechecksCurrentOwnerAndDoesNotRevealFormerWorkspaceSalt()throws {
        let(repo,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let input=Data("{\"name\":\"客户空间\"}".utf8),first=try repo.performAgentMutation(command:"workspaces create",data:input,principal:"owner",requestID:"create-space")
        let id=try XCTUnwrap(first.object?["result"]?.object?["id"]?.string)
        try repo.transaction{db in db.workspaces[db.workspaces.firstIndex{$0.id==id}!].owner="new-owner"}
        XCTAssertThrowsError(try repo.performAgentMutation(command:"workspaces create",data:input,principal:"owner",requestID:"create-space"));XCTAssertEqual(try repo.read().workspaces.count,2)
    }
    func testEditReplayReturnsOriginalRevisionAndRevokedGrantIsRejected()throws {
        let(repo,w,p)=try fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        _ = try repo.performAgentMutation(command:"script create",data:draft(w,p),principal:"owner",requestID:"draft")
        let project=try XCTUnwrap(repo.read().projects.first),edits=try Codec.decoder().decode(AgentValue.self,from:Codec.data([Edit.cta("收藏并复现")]))
        let input=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"project_id":.string(project.id),"base_revision":.string(project.current.id),"edits":edits]))
        try repo.transaction{db in db.workspaces[0].grants=[Grant(principal:"editor",role:.collaborator,projectIDs:[project.id],revisionIDs:[project.current.id],expiresAt:Date().addingTimeInterval(600))]}
        let first=try repo.performAgentMutation(command:"edit apply",data:input,principal:"editor",requestID:"edit")
        XCTAssertEqual(first,try repo.performAgentMutation(command:"edit apply",data:input,principal:"editor",requestID:"edit"));XCTAssertEqual(try repo.read().projects[0].revisions.count,2)
        try repo.transaction{$0.workspaces[0].grants[0].revoked=true}
        XCTAssertThrowsError(try repo.performAgentMutation(command:"edit apply",data:input,principal:"editor",requestID:"edit"));XCTAssertEqual(try repo.read().projects[0].revisions.count,2)
    }
    func testCrossCustomerEntityIDCannotOverwriteAndDryRunDoesNotWriteLedger()throws {
        let(repo,w,p)=try fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let foreign=Workspace(name:"客户乙",owner:"owner");try repo.transaction{$0.workspaces.append(foreign)}
        var stolen=p;stolen.workspaceID=foreign.id
        let input=try Codec.data(AgentValue.object(["workspace_id":.string(foreign.id),"product":try Codec.decoder().decode(AgentValue.self,from:Codec.data(stolen))]))
        XCTAssertThrowsError(try repo.performAgentMutation(command:"products import",data:input,principal:"owner",requestID:"foreign"));XCTAssertEqual(try repo.read().products[0].workspaceID,w.id)
        _ = try AgentPreview.evaluate(command:"script create",data:draft(w,p),database:repo.read(),principal:"owner")
        XCTAssertTrue(try repo.read().projects.isEmpty);XCTAssertTrue(try repo.read().agentReplayRecords?.isEmpty ?? true)
    }
    private func historyFixture(sourceGrant:Bool=false)throws->(Repository,Workspace,Project,Data) {
        let(repo,w,p)=try fixture()
        var old=Revision(product:p,purpose:.education,aspect:.portrait,scenes:[Scene(title:"历史",body:"PRIVATE_UNGRANTED_HISTORY")],cta:p.checkout)
        old.product.name="PRIVATE_HISTORICAL_PRODUCT"
        var current=old;current.id=Codec.id();current.parentID=old.id;current.number=2;current.scenes[0].body="当前获准编辑内容";current.product=p
        var project=Project(workspaceID:w.id,name:"指定版本工程",revision:old);project.revisions.append(current)
        try repo.transaction {database in
            database.projects=[project]
            database.workspaces[0].grants=[Grant(principal:"editor",role:.collaborator,projectIDs:[project.id],revisionIDs:[current.id],expiresAt:Date().addingTimeInterval(3600))]
            if sourceGrant {database.workspaces[0].grants.append(Grant(principal:"editor",role:.reviewer,projectIDs:[project.id],revisionIDs:[old.id],expiresAt:Date().addingTimeInterval(3600)))}
        }
        let edits=try Codec.decoder().decode(AgentValue.self,from:Codec.data([Edit.cta("前序编辑不能越权提交"),.restore(old.id),.restore(current.id)]))
        let input=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"project_id":.string(project.id),"base_revision":.string(current.id),"edits":edits]))
        return(repo,w,project,input)
    }
    func testAgentRestoreChecksEverySourceBeforePreviewOrAtomicMutation()throws {
        for invalid in ["unshared","revoked","expired","other-project","other-principal","other-workspace","other-revision"] {
            let(repo,w,project,input)=try historyFixture();defer{try? FileManager.default.removeItem(at:repo.root)}
            if invalid != "unshared" {try repo.transaction {database in
                var grant=Grant(principal:"editor",role:.reviewer,projectIDs:[project.id],revisionIDs:[project.revisions[0].id],expiresAt:Date().addingTimeInterval(3600))
                switch invalid {
                case "revoked":grant.revoked=true
                case "expired":grant.expiresAt=Date().addingTimeInterval(-1)
                case "other-project":grant.projectIDs=["other-project"]
                case "other-principal":grant.principal="other-editor"
                case "other-revision":grant.revisionIDs=["other-revision"]
                default:break
                }
                if invalid=="other-workspace" {var other=Workspace(name:"另一客户",owner:"other-owner");other.grants=[grant];database.workspaces.append(other)}
                else {database.workspaces[0].grants.append(grant)}
            }}
            let before=try Codec.data(repo.read())
            XCTAssertThrowsError(try AgentPreview.evaluate(command:"edit apply",data:input,database:repo.read(),principal:"editor")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required",invalid)}
            XCTAssertThrowsError(try repo.performAgentMutation(command:"edit apply",data:input,principal:"editor",requestID:"denied-restore")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required",invalid)}
            XCTAssertEqual(try Codec.data(repo.read()),before,invalid)
            XCTAssertTrue(try repo.read().agentReplayRecords?.isEmpty ?? true)
            XCTAssertEqual(try repo.read().workspaces[0].id,w.id)
        }
    }
    func testAgentRestoreAllowsOwnerAndExplicitReadSourceWithWriteBase()throws {
        for principal in ["owner","editor"] {
            let(repo,w,project,_)=try historyFixture(sourceGrant:principal=="editor");defer{try? FileManager.default.removeItem(at:repo.root)}
            let edits=try Codec.decoder().decode(AgentValue.self,from:Codec.data([Edit.restore(project.revisions[0].id)]))
            let input=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"project_id":.string(project.id),"base_revision":.string(project.current.id),"edits":edits]))
            let before=try Codec.data(repo.read())
            _=try AgentPreview.evaluate(command:"edit apply",data:input,database:repo.read(),principal:principal)
            XCTAssertEqual(try Codec.data(repo.read()),before)
            let result=try repo.performAgentMutation(command:"edit apply",data:input,principal:principal,requestID:"valid-restore")
            let restored=try XCTUnwrap(repo.read().projects.first?.current)
            XCTAssertEqual(restored.scenes[0].body,"PRIVATE_UNGRANTED_HISTORY");XCTAssertEqual(restored.product.name,"PRIVATE_HISTORICAL_PRODUCT")
            XCTAssertEqual(restored.parentID,project.current.id);XCTAssertFalse(restored.review.complete)
            XCTAssertEqual(result,try repo.performAgentMutation(command:"edit apply",data:input,principal:principal,requestID:"valid-restore"))
            XCTAssertEqual(try repo.read().projects[0].revisions.count,3)
        }
    }
    func testAgentRestoreReplayRechecksRevokedOrExpiredSourceGrant()throws {
        for invalid in ["revoked","expired"] {
            let(repo,_,_,input)=try historyFixture(sourceGrant:true);defer{try? FileManager.default.removeItem(at:repo.root)}
            _=try repo.performAgentMutation(command:"edit apply",data:input,principal:"editor",requestID:"restore-replay")
            try repo.transaction {database in
                if invalid=="revoked" {database.workspaces[0].grants[1].revoked=true}
                else {database.workspaces[0].grants[1].expiresAt=Date().addingTimeInterval(-1)}
            }
            let before=try Codec.data(repo.read())
            let canonical=try AgentMutationExecutor.canonicalInput(command:"edit apply",data:input,principal:"editor",requestID:"restore-replay")
            XCTAssertThrowsError(try AgentPreview.evaluate(command:"edit apply",data:canonical,database:repo.read(),principal:"editor")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required",invalid)}
            XCTAssertThrowsError(try repo.performAgentMutation(command:"edit apply",data:input,principal:"editor",requestID:"restore-replay")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required",invalid)}
            XCTAssertEqual(try Codec.data(repo.read()),before,invalid)
            XCTAssertEqual(try repo.read().agentReplayRecords?.count,1)
        }
    }
}
