import XCTest
@testable import VideoCore

final class AgentWorkerTests:XCTestCase {
    private func fixture()throws->(Database,Workspace,Job) {
        var db=Database();let w=Workspace(name:"甲",owner:"owner"),p=Product(workspaceID:w.id,sku:"one",name:"课程",checkout:"https://example.com",audience:"新人",task:"复现",outcome:"理解",prerequisite:"",scope:"知识",prices:[Price(money:Money(1),source:"产品页")]);let r=Revision(product:p,purpose:.education,aspect:.portrait,scenes:[Scene(title:"知识",body:"解释")],cta:"复现"),project=Project(workspaceID:w.id,name:"项目",revision:r),quote=Quote(projectID:project.id,revisionID:r.id,digest:try r.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:.distantFuture,confirmed:true),job=Job(workspaceID:w.id,projectID:project.id,revisionID:r.id,digest:try r.contentDigest(),requestKey:"original-key",quote:quote)
        db.workspaces=[w];db.products=[p];db.projects=[project];db.jobs=[job];return(db,w,job)
    }
    func testFinitePlanningHasRealBoundsAndRejectsCrossWorkspaceOrNonOwner()throws {
        let(db,w,job)=try fixture(),plan=try AgentWorkerPlan(workspaceID:w.id,jobIDs:[job.id],maximumJobs:1,timeoutSeconds:5)
        XCTAssertEqual(try plan.select(database:db,principal:"owner"),[job.id]);XCTAssertThrowsError(try plan.select(database:db,principal:"reviewer"));XCTAssertThrowsError(try AgentWorkerPlan(workspaceID:w.id,jobIDs:["foreign"]).select(database:db,principal:"owner"));XCTAssertThrowsError(try AgentWorkerPlan(workspaceID:w.id,maximumJobs:26));XCTAssertThrowsError(try AgentWorkerPlan(workspaceID:w.id,timeoutSeconds:3601));XCTAssertThrowsError(try AgentWorkerPlan(workspaceID:w.id,jobIDs:[job.id,job.id]))
    }
    func testUnknownRemoteCanOnlyBeQueriedAndIsNeverTurnedIntoNewLocalJob()throws {
        let(_,w,original)=try fixture();var remote=original;remote.quote.provider="user-provider";remote.state = .unknownRemote;remote.remoteID="original-remote"
        XCTAssertEqual(try AgentWorkerPlan(workspaceID:w.id,queryRemote:true).action(for:remote),.query)
        if case .run=try AgentWorkerPlan(workspaceID:w.id,resumeInterrupted:true).action(for:remote){XCTFail("unknown remote resubmitted")}
        XCTAssertEqual(remote.requestKey,"original-key");XCTAssertEqual(remote.remoteID,"original-remote")
    }
    func testExpiredLeaseRequiresExplicitResumeAndCancelIsNeverResumed()throws {
        let(_,w,original)=try fixture();var expired=try JobOperations.claim(original,owner:"old",now:Date(timeIntervalSince1970:0));expired.updatedAt=Date(timeIntervalSince1970:0)
        if case .run=try AgentWorkerPlan(workspaceID:w.id).action(for:expired){XCTFail("implicit resume")}
        XCTAssertEqual(try AgentWorkerPlan(workspaceID:w.id,resumeInterrupted:true).action(for:expired),.run)
        expired=JobRules.cancel(expired);if case .run=try AgentWorkerPlan(workspaceID:w.id,resumeInterrupted:true).action(for:expired){XCTFail("cancelled job resumed")}
    }
    func testWorkerStopInvalidatesOnlyItsOriginalLeasesAndLateFinishCannotWin()throws {
        var(db,_,job)=try fixture();job=try JobOperations.claim(job,owner:"worker:one");let token=try XCTUnwrap(job.lease?.token);var other=job;other.id="other";other.lease?.owner="worker:two";db.jobs=[job,other]
        AgentWorkerPlan.interruptOwned(database:&db,owner:"worker:one")
        XCTAssertEqual(db.jobs[0].state,.interrupted);XCTAssertNil(db.jobs[0].lease);XCTAssertEqual(db.jobs[1].state,.running)
        XCTAssertThrowsError(try JobOperations.finish(db.jobs[0],token:token,artifacts:[Artifact(path:"exports/file.mp4",mime:"video/mp4",bytes:10,sha256:String(repeating:"a",count:64),revision:job.revisionID)]))
        let resumed=try JobRules.recover(db.jobs[0]);XCTAssertEqual(resumed.id,job.id);XCTAssertEqual(resumed.requestKey,job.requestKey)
    }
    func testScopedWorkerInterruptionRejectsRevokedOwnerWithoutAnyDatabaseChange()throws {
        var(db,w,job)=try fixture();job=try JobOperations.claim(job,owner:"worker:original");db.jobs=[job]
        db.workspaces[0].owner="replacement-owner"
        let before=try Codec.digest(db)
        XCTAssertThrowsError(try AgentWorkerPlan.interruptOwned(database:&db,owner:"worker:original",workspaceID:w.id,principal:"owner"))
        XCTAssertEqual(try Codec.digest(db),before);XCTAssertEqual(db.jobs[0].state,.running)
        XCTAssertEqual(db.jobs[0].lease?.token,job.lease?.token)
        XCTAssertThrowsError(try AgentWorkerPlan.interruptOwned(database:&db,owner:"worker:original",workspaceID:"missing-workspace",principal:"replacement-owner"))
        XCTAssertEqual(try Codec.digest(db),before)
    }
    func testScopedWorkerInterruptionCannotAffectSameLeaseOwnerInAnotherWorkspaceAndRepeatsAreUnchanged()throws {
        var(db,w,job)=try fixture();let(otherDB,otherWorkspace,otherOriginal)=try fixture()
        job=try JobOperations.claim(job,owner:"worker:shared-request")
        let foreign=try JobOperations.claim(otherOriginal,owner:"worker:shared-request")
        db.workspaces.append(otherWorkspace);db.projects.append(contentsOf:otherDB.projects);db.products.append(contentsOf:otherDB.products)
        var remote=job;remote.id=Codec.id();remote.quote.provider="external-provider"
        var queued=job;queued.id=Codec.id();queued.state = .queued
        var otherLease=job;otherLease.id=Codec.id();otherLease.lease?.owner="worker:another-request"
        var noLease=job;noLease.id=Codec.id();noLease.lease=nil
        db.jobs=[job,foreign,remote,queued,otherLease,noLease]
        let unaffected=try Codec.digest(Array(db.jobs.dropFirst())),generation=db.generation
        XCTAssertTrue(try AgentWorkerPlan.interruptOwned(database:&db,owner:"worker:shared-request",workspaceID:w.id,principal:"owner"))
        XCTAssertEqual(db.jobs[0].state,.interrupted);XCTAssertNil(db.jobs[0].lease)
        XCTAssertEqual(db.jobs[0].id,job.id);XCTAssertEqual(db.jobs[0].requestKey,job.requestKey)
        XCTAssertEqual(try Codec.digest(Array(db.jobs.dropFirst())),unaffected);XCTAssertEqual(db.generation,generation)
        let once=try Codec.digest(db)
        XCTAssertFalse(try AgentWorkerPlan.interruptOwned(database:&db,owner:"worker:shared-request",workspaceID:w.id,principal:"owner"))
        XCTAssertEqual(try Codec.digest(db),once)
    }
}
