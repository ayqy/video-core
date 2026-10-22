import XCTest
@testable import VideoCore

final class AgentJobAccessTests:XCTestCase {
    private func fixture()throws->(Database,Workspace,Job) {
        let w=Workspace(name:"授权客户",owner:"owner"),product=Product(workspaceID:w.id,sku:"one",name:"课程",checkout:"https://example.com",audience:"初学者",task:"复现",outcome:"理解",prerequisite:"",scope:"知识",prices:[Price(money:Money(1),source:"产品页")]),revision=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"已授权内容",body:"知识解释")],cta:"复现"),project=Project(workspaceID:w.id,name:"授权工程",revision:revision),quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(87,"USD"),unit:"USD",provider:"PRIVATE_PROVIDER_REFERENCE",expiresAt:Date().addingTimeInterval(600))
        var job=Job(workspaceID:w.id,projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),requestKey:"PRIVATE_REQUEST_KEY",quote:quote);job.actual=Money(72,"USD");job.remoteID="PRIVATE_REMOTE_ID";job.billing=[BillingRecord(id:"PRIVATE_BILL_ID",kind:.charge,money:Money(72,"USD"),source:"PRIVATE_BILL_RECEIPT")];job.message="PRIVATE_BILL_MESSAGE";job.state = .needsReview;job.progress=1;job.artifacts=[Artifact(path:"/private-customer-dir/video.mp4",mime:"video/mp4",bytes:123,sha256:String(repeating:"a",count:64),revision:revision.id)]
        var db=Database();var granted=w;granted.grants=[Grant(principal:"reviewer",role:.reviewer,projectIDs:[project.id],revisionIDs:[revision.id],expiresAt:Date().addingTimeInterval(600))];db.workspaces=[granted];db.products=[product];db.projects=[project];db.jobs=[job];return(db,granted,job)
    }
    func testNonOwnerSerializedStatusHasActualIDAndVersionWithoutFinanceMessagesOrPaths()throws {
        let(db,w,job)=try fixture(),status=try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer")
        guard case .restricted(let dto)=status else{return XCTFail("reviewer got full Job")}
        XCTAssertEqual(dto.id,job.id);XCTAssertEqual(dto.state,job.state);XCTAssertEqual(dto.progress,1);XCTAssertEqual(dto.revisionID,job.revisionID);XCTAssertEqual(dto.artifacts.first?.sha256,job.artifacts.first?.sha256)
        let json=String(decoding:try Codec.data(status.value()),as:UTF8.self)
        for forbidden in ["PRIVATE_","private-customer-dir","quote","actual","billing","requestKey","remoteID","provider","message","USD","path"]{XCTAssertFalse(json.contains(forbidden),forbidden)}
        XCTAssertEqual(Set(try XCTUnwrap(status.value().object).keys),["id","projectID","revisionID","state","progress","artifacts"])
        guard case .owner(let complete)=try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"owner") else{return XCTFail("owner lost full status")};XCTAssertEqual(complete.actual?.amount,72);XCTAssertEqual(complete.billing?.first?.source,"PRIVATE_BILL_RECEIPT")
    }
    func testOldRevisionGrantCannotReadNewJobAndRevocationAppliesToEveryQuery()throws {
        var(db,w,job)=try fixture();var revision=db.projects[0].current;revision.id=Codec.id();revision.number += 1;revision.scenes[0].body="UNGRANTED_NEW_REVISION";db.projects[0].revisions.append(revision)
        var new=job;new.id=Codec.id();new.revisionID=revision.id;new.digest=try revision.contentDigest();new.message="UNGRANTED_NEW_REVISION";new.artifacts=[];db.jobs.append(new)
        XCTAssertThrowsError(try AgentJobAccess.status(jobID:new.id,workspaceID:w.id,database:db,principal:"reviewer"))
        let oldJSON=String(decoding:try Codec.data(AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer").value()),as:UTF8.self);XCTAssertFalse(oldJSON.contains("UNGRANTED_NEW_REVISION"));XCTAssertFalse(oldJSON.contains(revision.id))
        db.workspaces[0].grants[0].revoked=true;XCTAssertThrowsError(try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer"))
        db.workspaces[0].grants[0].revoked=false;db.workspaces[0].grants[0].expiresAt=Date().addingTimeInterval(-1);XCTAssertThrowsError(try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer"))
    }
    func testForeignOrMismatchedArtifactsCannotLeakIntoScopedResult()throws {
        var(db,w,job)=try fixture();db.jobs[0].artifacts[0].revision="OTHER_REVISION"
        XCTAssertThrowsError(try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer"))
        db.jobs[0]=job;db.jobs[0].artifacts[0].sha256="PRIVATE_BILL_RECEIPT"
        XCTAssertThrowsError(try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer"))
        db.jobs[0]=job;db.jobs[0].artifacts[0].mime="PRIVATE_PROVIDER_REFERENCE"
        XCTAssertThrowsError(try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer"))
        db.jobs[0]=job;db.jobs[0].artifacts[0].bytes = -1
        XCTAssertThrowsError(try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer"))
        db.jobs[0]=job;db.jobs[0].artifacts[0].bytes=0
        XCTAssertThrowsError(try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer"))
        db.jobs[0].artifacts[0].mime="application/x-subrip"
        XCTAssertNoThrow(try AgentJobAccess.status(jobID:job.id,workspaceID:w.id,database:db,principal:"reviewer"))
        let foreign=Workspace(name:"PRIVATE_OTHER_CUSTOMER",owner:"owner");db.workspaces.append(foreign)
        XCTAssertThrowsError(try AgentJobAccess.status(jobID:job.id,workspaceID:foreign.id,database:db,principal:"reviewer"))
        XCTAssertThrowsError(try AgentJobAccess.status(jobID:"unavailable",workspaceID:w.id,database:db,principal:"reviewer"))
    }
}
