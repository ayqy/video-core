import XCTest
@testable import VideoCore

final class AgentJobAccessTests:XCTestCase {
    private func fixture()throws->(Database,Workspace,Job) {
        let w=Workspace(name:"授权客户",owner:"owner"),product=Product(workspaceID:w.id,sku:"one",name:"课程",checkout:"https://example.com",audience:"初学者",task:"复现",outcome:"理解",prerequisite:"",scope:"知识",prices:[Price(money:Money(1),source:"产品页")]),revision=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"已授权内容",body:"知识解释")],cta:"复现"),project=Project(workspaceID:w.id,name:"授权工程",revision:revision),quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(87,"USD"),unit:"USD",provider:"PRIVATE_PROVIDER_REFERENCE",expiresAt:Date().addingTimeInterval(600))
        var job=Job(workspaceID:w.id,projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),requestKey:"PRIVATE_REQUEST_KEY",quote:quote);job.actual=Money(72,"USD");job.remoteID="PRIVATE_REMOTE_ID";job.billing=[BillingRecord(id:"PRIVATE_BILL_ID",kind:.charge,money:Money(72,"USD"),source:"PRIVATE_BILL_RECEIPT")];job.message="PRIVATE_BILL_MESSAGE";job.state = .needsReview;job.progress=1;job.artifacts=[Artifact(path:"/private-customer-dir/video.mp4",mime:"video/mp4",bytes:123,sha256:String(repeating:"a",count:64),revision:revision.id)]
        var db=Database();var granted=w;granted.grants=[Grant(principal:"reviewer",role:.reviewer,projectIDs:[project.id],revisionIDs:[revision.id],expiresAt:Date().addingTimeInterval(600))];db.workspaces=[granted];db.products=[product];db.projects=[project];db.jobs=[job];return(db,granted,job)
    }
    private func remoteFixture(baidu:Bool=false)throws->(Database,Job) {
        var(db,_,job)=try fixture()
        var profile=baidu ? BaiduVideoRules.profile(keyReference:"unused-local-reference") : ProviderProfile(name:"状态查询规则",endpoint:"https://example.com",model:"known-model",supportedParameters:[],keyReference:"unused-local-reference",kind:"video-job-v1",statusPath:"/jobs/status",cancelPath:"/jobs/cancel")
        profile.id=job.quote.provider;db.providers=[profile]
        if baidu{job.videoGeneration=VideoGenerationReceipt(inputDigest:String(repeating:"a",count:64))}
        db.jobs=[job]
        db.workspaces[0].grants.append(Grant(principal:"editor",role:.collaborator,projectIDs:[job.projectID],revisionIDs:[job.revisionID],expiresAt:Date().addingTimeInterval(600)))
        return(db,job)
    }
    func testRemoteTargetPreservesOwnerAndScopedEditorAuthorityWithoutWideningOwnerCommands()throws {
        let(db,job)=try remoteFixture(),(baiduDB,baidu)=try remoteFixture(baidu:true)
        for command in ["jobs query","jobs remote-cancel","worker run"] {
            XCTAssertEqual(try AgentJobAccess.remoteTarget(original:job,database:db,principal:"owner",command:command).id,job.id)
        }
        for command in ["jobs query","jobs remote-cancel"] {
            XCTAssertEqual(try AgentJobAccess.remoteTarget(original:job,database:db,principal:"editor",command:command).id,job.id)
            XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:db,principal:"reviewer",command:command))
        }
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:db,principal:"editor",command:"worker run"))
        for command in ["baidu submit","baidu query","baidu collect"] {
            XCTAssertEqual(try AgentJobAccess.remoteTarget(original:baidu,database:baiduDB,principal:"owner",command:command).id,baidu.id)
            XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:baidu,database:baiduDB,principal:"editor",command:command))
            XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:db,principal:"owner",command:command))
        }
        for command in ["jobs status","jobs reconcile","worker launch","jobs query ","schema",""] {
            XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:db,principal:"owner",command:command))
        }
    }
    func testRemoteTargetRechecksRevocationExpiryOwnerAndExactGrantedRevision()throws {
        let(db,job)=try remoteFixture()
        var changed=db;changed.workspaces[0].grants[1].revoked=true
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"editor",command:"jobs query"))
        changed=db;changed.workspaces[0].grants[1].expiresAt=Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"editor",command:"jobs query"))
        changed=db;changed.workspaces[0].owner="new-owner"
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"owner",command:"jobs query"))
        XCTAssertEqual(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"new-owner",command:"jobs query").id,job.id)
        changed=db;changed.workspaces[0].grants[1].revisionIDs=["different-revision"]
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"editor",command:"jobs remote-cancel"))
        changed=db;changed.workspaces[0].grants[1].projectIDs=["different-project"]
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"editor",command:"jobs query"))
    }
    func testRemoteTargetRejectsChangedOriginalJobAndCompleteQuoteBindings()throws {
        let(db,job)=try remoteFixture()
        let mutations:[(inout Job)->Void]=[
            {$0.id=Codec.id()},{$0.workspaceID="other-workspace"},{$0.projectID="other-project"},
            {$0.revisionID="other-revision"},{$0.digest=String(repeating:"b",count:64)},{$0.requestKey="another-request"},
            {$0.createdAt=$0.createdAt.addingTimeInterval(10)},{$0.remoteID="another-remote"},{$0.remoteID=nil},
            {$0.quote.id=Codec.id()},{$0.quote.projectID="other-project"},{$0.quote.revisionID="other-revision"},
            {$0.quote.digest="other-digest"},{$0.quote.upper=Money(88,"USD")},{$0.quote.unit="credits"},
            {$0.quote.provider="another-provider"},{$0.quote.expiresAt=$0.quote.expiresAt.addingTimeInterval(10)},
            {$0.quote.attempts += 1},{$0.quote.confirmed.toggle()},{$0.quote.createdAt=$0.quote.createdAt.addingTimeInterval(10)},
            {$0.quote.breakdown=EstimateBreakdown(version:"changed",specification:"changed",source:"规则夹具",validFrom:Date(),expiresAt:Date().addingTimeInterval(600),lines:[],excluded:[])}
        ]
        for (index,mutation) in mutations.enumerated() {
            var changed=db;mutation(&changed.jobs[0])
            XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"owner",command:"jobs query"),"identity mutation \(index)")
        }
        var unbound=job;unbound.remoteID=nil
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:unbound,database:db,principal:"owner",command:"jobs query"))
        var invalid=db;invalid.jobs[0].quote.projectID="mismatched-project"
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:invalid.jobs[0],database:invalid,principal:"owner",command:"jobs query"))
    }
    func testRemoteTargetRejectsMissingAmbiguousProviderAndAlteredSourceRevision()throws {
        let(db,job)=try remoteFixture()
        let mutations:[(inout Database)->Void]=[
            {$0.jobs=[]},{$0.jobs.append($0.jobs[0])},{$0.workspaces=[]},{$0.workspaces.append($0.workspaces[0])},
            {$0.projects=[]},{$0.projects.append($0.projects[0])},{$0.projects[0].workspaceID="other-workspace"},
            {$0.projects[0].revisions=[]},{$0.projects[0].revisions.append($0.projects[0].revisions[0])},
            {$0.projects[0].revisions[0].scenes[0].body="实际内容已改变"},
            {$0.providers=[]},{$0.providers.append($0.providers[0])},{$0.providers[0].id="other-provider"},
            {$0.providers[0].endpoint="http://example.com"}
        ]
        for (index,mutation) in mutations.enumerated() {
            var changed=db;mutation(&changed)
            XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"owner",command:"jobs query"),"source mutation \(index)")
        }
    }
    func testRemoteTargetAllowsConcurrentStateBillingAndPersistedDateNormalization()throws {
        let(db,job)=try remoteFixture(baidu:true)
        var changed=db;changed.jobs[0].state = .cancelRequested;changed.jobs[0].progress=0.4
        changed.jobs[0].actual=Money(69,"USD");changed.jobs[0].refundPending=Money(2,"USD");changed.jobs[0].billingUnknown=true
        changed.jobs[0].billing?.append(BillingRecord(id:"new-bill",kind:.refundRequested,money:Money(2,"USD"),source:"规则账单"))
        changed.jobs[0].message="另一客户端查询完成";changed.jobs[0].updatedAt=Date().addingTimeInterval(1)
        changed.jobs[0].remoteCheckedAt=Date();changed.jobs[0].videoGeneration?.phase = .accepted
        changed.jobs[0].videoGeneration?.points=4;changed.jobs[0].videoGeneration?.collectionToken="live-collection"
        changed.jobs[0].videoGeneration?.collectionExpiresAt=Date().addingTimeInterval(100)
        let persisted=try Codec.decoder().decode(Database.self,from:Codec.data(changed))
        let current=try AgentJobAccess.remoteTarget(original:job,database:persisted,principal:"owner",command:"baidu query")
        XCTAssertEqual(current.state,.cancelRequested);XCTAssertEqual(current.progress,0.4)
        XCTAssertEqual(current.actual?.amount,69);XCTAssertEqual(current.refundPending?.amount,2)
        XCTAssertEqual(current.billing?.last?.id,"new-bill");XCTAssertEqual(current.videoGeneration?.collectionToken,"live-collection")
    }
    func testRemoteTargetRejectsReplacedGenerationInputContractAndProviderModel()throws {
        let(db,job)=try remoteFixture(baidu:true)
        let mutations:[(inout Database)->Void]=[
            {$0.jobs[0].videoGeneration=nil},{$0.jobs[0].videoGeneration?.inputDigest=String(repeating:"b",count:64)},
            {$0.jobs[0].videoGeneration?.contractVersion="changed-contract"},{$0.jobs[0].videoGeneration?.model="changed-model"},
            {$0.jobs[0].videoGeneration?.startedAt=Date().addingTimeInterval(10)},{$0.providers[0].model="changed-model"},
            {$0.providers[0].kind="video-job-v1"}
        ]
        for (index,mutation) in mutations.enumerated() {
            var changed=db;mutation(&changed)
            XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:job,database:changed,principal:"owner",command:"baidu collect"),"generation mutation \(index)")
        }
        var noReceipt=job;noReceipt.videoGeneration=nil
        XCTAssertThrowsError(try AgentJobAccess.remoteTarget(original:noReceipt,database:db,principal:"owner",command:"jobs query"))
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
