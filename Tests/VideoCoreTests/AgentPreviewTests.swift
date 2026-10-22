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
}
