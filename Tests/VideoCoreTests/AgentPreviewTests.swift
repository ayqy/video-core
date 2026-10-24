import XCTest
import VideoCore

final class AgentPreviewTests:XCTestCase {
    func fixture()throws->(Database,Workspace,Project) {
        var db=Database();let w=Workspace(name:"作者",owner:"local-owner");db.workspaces=[w]
        let product=Product(workspaceID:w.id,sku:"existing",name:"已有课程",checkout:"https://example.com",audience:"学习者",task:"复现",outcome:"可完成",prerequisite:"无",scope:"软件",prices:[Price(money:Money(99),source:"原页",verified:true)])
        db.products=[product];var revision=try Planner.create(product:product,knowledge:"完整知识",demonstration:"演示步骤",hook:"开场",purpose:.course,aspect:.portrait,kind:.explanation,evidenceIDs:[]);revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[]);let p=Project(workspaceID:w.id,name:"作品",revision:revision);db.projects=[p];return(db,w,p)
    }
    func testDryRunChecksBudgetWithoutAppendingJobOrChangingGeneration()throws {
        let(db,w,p)=try fixture();let before=try Codec.digest(db)
        let q=Quote(projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),upper:Money(80),unit:"CNY",provider:"supplier",expiresAt:Date().addingTimeInterval(100),confirmed:true)
        let input:AgentValue = .object(["workspace_id":.string(w.id),"project_id":.string(p.id),"quote":try Codec.decoder().decode(AgentValue.self,from:Codec.data(q)),"request_id":.string("once")])
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"render submit",data:Codec.data(input),database:db)) { error in XCTAssertEqual((error as? VideoError)?.code,"budget_exceeded") }
        XCTAssertEqual(before,try Codec.digest(db));XCTAssertTrue(db.jobs.isEmpty)
    }
    func testReadOnlyRepositoryDoesNotPermitMutationAndKeepsBusinessGeneration()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("read-only-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root);let(db,_,_)=try fixture();try repo.transaction{$0=db};let generation=try repo.read().generation
        let read=try Repository(root:root,readOnly:true);XCTAssertThrowsError(try read.transaction{$0.workspaces=[]});XCTAssertEqual(try repo.read().generation,generation);XCTAssertEqual(try read.read().projects.count,1)
    }
    func testMalformedMoneyOrUnknownFieldCannotGetSuccessfulDryRun()throws {
        XCTAssertThrowsError(try Money(text:"12元"));XCTAssertThrowsError(try Money(text:"1.2oops"));XCTAssertThrowsError(try Money(text:"NaN"))
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"workspaces create",data:Data(#"{"name":"x","unexpected":"y"}"#.utf8),database:Database()))
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"workspaces create",data:Data(#"{"name":"   "}"#.utf8),database:Database()))
    }
    private func quoteInput(_ workspace:Workspace,_ project:Project)throws->AgentValue {
        let quote=Quote(projectID:project.id,revisionID:project.current.id,digest:try project.current.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(600),confirmed:true)
        return .object(["workspace_id":.string(workspace.id),"project_id":.string(project.id),"quote":try Codec.decoder().decode(AgentValue.self,from:Codec.data(quote)),"request_id":.string("scoped-dry-run")])
    }
    private func granted(_ original:Database,project:Project,revisionID:String,role:Role = .collaborator,expiresAt:Date=Date().addingTimeInterval(600),revoked:Bool=false)->Database {
        var database=original
        var grant=Grant(principal:"editor",role:role,projectIDs:[project.id],revisionIDs:[revisionID],expiresAt:expiresAt)
        grant.revoked=revoked;database.workspaces[0].grants=[grant]
        return database
    }
    func testScopedCollaboratorCanPreviewCurrentNativeQuoteWithoutWritingAJob()throws {
        let(original,w,p)=try fixture(),db=granted(original,project:p,revisionID:p.current.id)
        let before=try Codec.data(db),input=try quoteInput(w,p)
        XCTAssertNoThrow(try AgentPreview.evaluate(command:"render estimate",data:Codec.data(AgentValue.object(["workspace_id":.string(w.id),"project_id":.string(p.id)])),database:db,principal:"editor"))
        XCTAssertNoThrow(try AgentPreview.evaluate(command:"render submit",data:Codec.data(input),database:db,principal:"editor"))
        XCTAssertEqual(try Codec.data(db),before);XCTAssertTrue(db.jobs.isEmpty)
    }
    private func historicalJob()throws->(Database,Workspace,Project,Job) {
        var(db,w,p)=try fixture()
        let quote=Quote(projectID:p.id,revisionID:p.current.id,digest:try p.current.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(600),confirmed:true)
        let job=try JobRules.submit(workspaceID:w.id,project:p,quote:quote,requestKey:"original-historical-job",existing:[],budget:db.budget)
        p=try Editor.apply([.cta("当前版本的新说明")],to:p,baseRevision:p.current.id,assets:[],message:"保留原作业的历史版本")
        db.projects=[p];db.jobs=[job]
        return(db,w,p,job)
    }
    func testScopedJobPreviewUsesItsFrozenRevisionInsteadOfTheCurrentProject()throws {
        let(original,w,p,job)=try historicalJob()
        let db=granted(original,project:p,revisionID:job.revisionID),before=try Codec.data(db)
        let input=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"job_id":.string(job.id)]))
        for command in ["jobs status","jobs cancel","jobs run"] {
            XCTAssertNoThrow(try AgentPreview.evaluate(command:command,data:input,database:db,principal:"editor"),command)
        }
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"render submit",data:Codec.data(quoteInput(w,p)),database:db,principal:"editor")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required")}
        XCTAssertEqual(try Codec.data(db),before);XCTAssertEqual(db.jobs[0].state,.queued);XCTAssertNil(db.jobs[0].lease)
    }
    func testCurrentRevisionGrantCannotAuthorizeAnotherHistoricalJob()throws {
        let(original,w,p,job)=try historicalJob()
        let db=granted(original,project:p,revisionID:p.current.id),before=try Codec.data(db)
        let input=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"job_id":.string(job.id)]))
        for command in ["jobs status","jobs cancel","jobs run"] {
            XCTAssertThrowsError(try AgentPreview.evaluate(command:command,data:input,database:db,principal:"editor")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required",command)}
        }
        XCTAssertNoThrow(try AgentPreview.evaluate(command:"render submit",data:Codec.data(quoteInput(w,p)),database:db,principal:"editor"))
        XCTAssertEqual(try Codec.data(db),before)
    }
    func testScopedPreviewPreservesExpiredRevokedForeignAndNonmemberRejections()throws {
        let(original,w,p)=try fixture()
        let estimate=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"project_id":.string(p.id)])),submit=try Codec.data(quoteInput(w,p))
        var foreignProject=p;foreignProject.id="unrelated-project"
        let cases:[(String,Database)]=[
            ("expired",granted(original,project:p,revisionID:p.current.id,expiresAt:Date().addingTimeInterval(-60))),
            ("revoked",granted(original,project:p,revisionID:p.current.id,revoked:true)),
            ("foreign-project",granted(original,project:foreignProject,revisionID:p.current.id)),
            ("foreign-revision",granted(original,project:p,revisionID:"not-the-selected-revision")),
            ("nonmember",original)]
        for (label,db) in cases {
            let before=try Codec.data(db)
            for (command,input) in [("render estimate",estimate),("render submit",submit)] {
                XCTAssertThrowsError(try AgentPreview.evaluate(command:command,data:input,database:db,principal:"editor")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required",label+" "+command)}
            }
            XCTAssertEqual(try Codec.data(db),before,label)
        }
    }
    func testReviewerMayPreviewReadingButCannotPreviewProjectWrites()throws {
        let(original,w,p)=try fixture()
        let db=granted(original,project:p,revisionID:p.current.id,role:.reviewer),before=try Codec.data(db)
        XCTAssertNoThrow(try AgentPreview.evaluate(command:"render estimate",data:Codec.data(AgentValue.object(["workspace_id":.string(w.id),"project_id":.string(p.id)])),database:db,principal:"editor"))
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"render submit",data:Codec.data(quoteInput(w,p)),database:db,principal:"editor")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required")}
        XCTAssertEqual(try Codec.data(db),before)
    }
    func testScopedJobPreviewDoesNotBorrowAJobFromAnotherWorkspace()throws {
        var(db,w,p,job)=try historicalJob()
        let other=Workspace(name:"另一工作区",owner:"local-owner")
        db.workspaces.append(other);db.jobs[0].workspaceID=other.id
        db=granted(db,project:p,revisionID:job.revisionID)
        let input=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"job_id":.string(job.id)])),before=try Codec.data(db)
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"jobs cancel",data:input,database:db,principal:"editor")) {XCTAssertEqual(($0 as? VideoError)?.code,"permission_required")}
        XCTAssertEqual(try Codec.data(db),before)
    }
    func testOwnerPreviewStillWorksAndStrictSchemasRejectInjectedBaseRevision()throws {
        let(db,w,p,job)=try historicalJob()
        XCTAssertNoThrow(try AgentPreview.evaluate(command:"render submit",data:Codec.data(quoteInput(w,p)),database:db,principal:w.owner))
        let jobInput:AgentValue = .object(["workspace_id":.string(w.id),"job_id":.string(job.id)])
        XCTAssertNoThrow(try AgentPreview.evaluate(command:"jobs cancel",data:Codec.data(jobInput),database:db,principal:w.owner))
        for (command,input) in [("render submit",try quoteInput(w,p)),("jobs cancel",jobInput)] {
            var values=try XCTUnwrap(input.object);values["base_revision"] = .string(job.revisionID)
            XCTAssertThrowsError(try AgentPreview.evaluate(command:command,data:Codec.data(AgentValue.object(values)),database:db,principal:w.owner)) {XCTAssertEqual(($0 as? VideoError)?.code,"invalid_input",command)}
        }
    }
}
