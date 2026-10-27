import XCTest
import VideoCore
@testable import VideoMedia

#if os(macOS)
final class ScriptJobsTests:XCTestCase {
    private func fixture()throws->(Repository,Job) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("script-jobs-"+Codec.id(),isDirectory:true)
        let repository=try Repository(root:root)
        var workspace=Workspace(name:"本机规则工作区",owner:"owner");workspace.id="w"
        var profile=ProviderProfile(name:"未联网规则配置",endpoint:"https://api.example.com/chat/completions",model:"declared-model",supportedParameters:[],allowsUpload:true,keyReference:"unread-opaque-reference")
        profile.capabilities=ProviderCapabilities(version:"declared-v1",source:"供应商文档占位，仅本地规则测试")
        let revision=try Planner.create(workspaceID:"w",name:"普通教学",aspect:.landscape,scenes:[Scene(title:"解释",body:"明确的本地内容")])
        let project=Project(workspaceID:"w",name:"普通教学",revision:revision)
        try repository.transaction{$0.workspaces=[workspace];$0.projects=[project];$0.providers=[profile]}
        let quote=try EstimateBreakdown(version:"rule-v1",specification:ScriptJobRules.specification(profile:profile,revision:revision,evidence:[],brief:"解释已选内容"),source:"本地规则夹具，不代表真实账单",validFrom:.distantPast,expiresAt:Date().addingTimeInterval(3600),lines:[RateLine(label:"规则预算",quantity:1,unit:"次",price:Money(3))],excluded:[]).quote(project:project,provider:profile.id,confirmed:true)
        let job=try repository.transaction{try ScriptJobRules.prepare(database:&$0,workspaceID:"w",projectID:project.id,profile:profile,evidence:[],brief:"解释已选内容",quote:quote,requestKey:"original-paid-intent",principal:"owner")}.job
        return(repository,job)
    }
    private func remoteFixture()throws->(Repository,Job,ProviderProfile) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("remote-job-"+Codec.id(),isDirectory:true),repository=try Repository(root:root)
        var workspace=Workspace(name:"查询工作区",owner:"owner")
        let revision=try Planner.create(workspaceID:workspace.id,name:"普通知识",aspect:.landscape,scenes:[Scene(title:"原内容",body:"内容保留")]),project=Project(workspaceID:workspace.id,name:"原工程",revision:revision)
        let profile=ProviderProfile(name:"未联网状态规则",endpoint:"https://status.example.com",model:"declared-status",supportedParameters:[],keyReference:"unused-opaque-reference",kind:"video-job-v1",statusPath:"/jobs/status",cancelPath:"/jobs/cancel")
        let quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(9),unit:"CNY",provider:profile.id,expiresAt:Date().addingTimeInterval(600),confirmed:true)
        var job=Job(workspaceID:workspace.id,projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),requestKey:"PRIVATE_ORIGINAL_REQUEST",quote:quote)
        job.remoteID="PRIVATE_ORIGINAL_REMOTE";job.state = .unknownRemote;job.billingUnknown=true
        job.artifacts=[Artifact(path:"/private-original/video.mp4",mime:"video/mp4",bytes:12,sha256:String(repeating:"a",count:64),revision:revision.id)]
        workspace.grants=[Grant(principal:"editor",role:.collaborator,projectIDs:[project.id],revisionIDs:[revision.id],expiresAt:Date().addingTimeInterval(600))]
        try repository.transaction{$0.workspaces=[workspace];$0.projects=[project];$0.providers=[profile];$0.jobs=[job]}
        return(repository,try repository.read().jobs[0],profile)
    }
    func testDelayedRemoteQueryCannotReplaceSameSecondCancellationAndSpend()throws {
        for command in ["jobs query","worker run"] {
            let(repository,_,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{$0.jobs[0].state = .running;$0.jobs[0].artifacts=[]}
            let original=try repository.read().jobs[0]
            let prepared=try repository.transaction{db in db.jobs[0]=JobRules.cancel(db.jobs[0]);return db.jobs[0]}
            let checked=Date(timeIntervalSince1970:Date().timeIntervalSince1970.rounded(.down))
            let cancelled=try RemoteJobs.accept(RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.cancelled,progress:0.7,actual:Money(7),checkedAt:checked),original:prepared,profile:profile,repository:repository,principal:"owner",command:"jobs remote-cancel")
            XCTAssertEqual(cancelled.state,.cancelled);XCTAssertEqual(cancelled.actual,Money(7))
            let before=try Codec.data(repository.read())
            let delayed=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.failed,progress:0,actual:Money(0),checkedAt:checked)
            XCTAssertThrowsError(try RemoteJobs.accept(delayed,original:original,profile:profile,repository:repository,principal:"owner",command:command))
            XCTAssertEqual(try Codec.data(repository.read()),before)
            let retained=try repository.read().jobs[0]
            XCTAssertEqual(retained.state,.cancelled);XCTAssertEqual(retained.actual,Money(7));XCTAssertEqual(retained.exposure,Money(7))
        }
    }
    func testDelayedRemoteQueryCannotConsumeNewCancellationIntent()throws {
        for command in ["jobs query","worker run"] {
            let(repository,_,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{$0.jobs[0].state = .running;$0.jobs[0].artifacts=[]}
            let original=try repository.read().jobs[0]
            try repository.transaction{$0.jobs[0]=JobRules.cancel($0.jobs[0])}
            let before=try Codec.data(repository.read())
            let delayed=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.unknown,progress:0.2,actual:Money(0))
            XCTAssertThrowsError(try RemoteJobs.accept(delayed,original:original,profile:profile,repository:repository,principal:"owner",command:command))
            XCTAssertEqual(try Codec.data(repository.read()),before)
            let retained=try repository.read().jobs[0]
            XCTAssertEqual(retained.state,.cancelRequested);XCTAssertNil(retained.actual);XCTAssertTrue(retained.billingUnknown)
        }
    }
    func testFreshGenericQueryKeepsCancelledOverrunWithoutInventingRefundReceipt()throws {
        let(repository,_,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        try repository.transaction{$0.jobs[0].state = .cancelRequested;$0.jobs[0].artifacts=[]}
        let original=try repository.read().jobs[0]
        let checked=Date(timeIntervalSince1970:Date().timeIntervalSince1970.rounded(.down))
        let cancelled=try RemoteJobs.accept(RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.cancelled,progress:0.7,actual:Money(20),checkedAt:checked),original:original,profile:profile,repository:repository,principal:"owner",command:"jobs remote-cancel")
        XCTAssertEqual(cancelled.remoteObservationSequence,1)
        let updated=try RemoteJobs.accept(RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.unknown,progress:0.1,actual:Money(0),checkedAt:checked),original:cancelled,profile:profile,repository:repository,principal:"owner",command:"jobs query")
        XCTAssertEqual(updated.remoteObservationSequence,2);XCTAssertEqual(updated.state,.cancelled)
        XCTAssertEqual(updated.actual,Money(20));XCTAssertEqual(updated.remoteReportedActual,Money(20));XCTAssertEqual(updated.exposure,Money(20))
        XCTAssertTrue(updated.billingUnknown);XCTAssertTrue((updated.billing ?? []).isEmpty);XCTAssertNil(updated.refundPending)
        let persisted=try repository.read().jobs[0]
        XCTAssertEqual(try Codec.data(persisted),try Codec.data(updated));XCTAssertEqual(persisted.remoteID,original.remoteID)
        XCTAssertEqual(try Codec.data(persisted.quote),try Codec.data(original.quote))
    }
    func testDelayedCancellationReplyCannotOverwriteNewerQueryOrConcurrentRefund()throws {
        for command in ["jobs query","worker run"] {
            let(repository,_,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{$0.jobs[0].state = .cancelRequested;$0.jobs[0].artifacts=[]}
            let original=try repository.read().jobs[0]
            let checked=Date(timeIntervalSince1970:Date().timeIntervalSince1970.rounded(.down))
            _ = try RemoteJobs.accept(RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.running,progress:0.8,actual:Money(7),checkedAt:checked),original:original,profile:profile,repository:repository,principal:"owner",command:command)
            try repository.transaction{db in
                for event in [BillingRecord(id:"charge",kind:.charge,money:Money(12),source:"本地规则费用凭据"),BillingRecord(id:"request",kind:.refundRequested,money:Money(5),source:"本地规则申请凭据"),BillingRecord(id:"refund",kind:.refundReceived,money:Money(3),source:"本地规则到账凭据")] {db.jobs[0]=try JobOperations.reconcile(db.jobs[0],record:event)}
            }
            let before=try Codec.data(repository.read())
            XCTAssertThrowsError(try RemoteJobs.accept(RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.cancelled,progress:0.8,actual:Money(0),checkedAt:checked),original:original,profile:profile,repository:repository,principal:"owner",command:"jobs remote-cancel"))
            XCTAssertEqual(try Codec.data(repository.read()),before)
            let retained=try repository.read().jobs[0]
            XCTAssertEqual(retained.remoteObservationSequence,1);XCTAssertEqual(retained.state,.cancelRequested)
            XCTAssertEqual(retained.actual,Money(9));XCTAssertEqual(retained.refundPending,Money(2));XCTAssertEqual(retained.billing?.count,3)
        }
    }
    func testFreshUnknownCancelReplyKeepsIntentAndConcurrentReceiptLedger()throws {
        let(repository,_,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        try repository.transaction{$0.jobs[0].state = .cancelRequested}
        let original=try repository.read().jobs[0]
        try repository.transaction{db in
            for event in [BillingRecord(id:"charge",kind:.charge,money:Money(12),source:"本地规则费用凭据"),BillingRecord(id:"request",kind:.refundRequested,money:Money(5),source:"本地规则申请凭据"),BillingRecord(id:"refund",kind:.refundReceived,money:Money(3),source:"本地规则到账凭据")] {db.jobs[0]=try JobOperations.reconcile(db.jobs[0],record:event)}
        }
        let ledger=try Codec.data(repository.read().jobs[0].billing)
        let updated=try RemoteJobs.accept(RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.unknown,progress:0.2,actual:Money(0)),original:original,profile:profile,repository:repository,principal:"owner",command:"jobs remote-cancel")
        XCTAssertEqual(updated.remoteObservationSequence,1);XCTAssertEqual(updated.state,.cancelRequested);XCTAssertTrue(updated.billingUnknown)
        XCTAssertEqual(updated.actual,Money(9));XCTAssertEqual(updated.refundPending,Money(2));XCTAssertEqual(try Codec.data(updated.billing),ledger)
        XCTAssertEqual(try Codec.data(updated.artifacts),try Codec.data(original.artifacts));XCTAssertEqual(updated.remoteID,original.remoteID)
    }
    func testInvalidRemoteSequenceCannotStoreCancellationIntent()async throws {
        for invalid in [-1,Int.max] {
            let(repository,_,_)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{$0.jobs[0].state = .running;$0.jobs[0].remoteObservationSequence=invalid}
            let original=try repository.read().jobs[0],before=try Codec.data(repository.read())
            do {
                _ = try await RemoteJobs.cancel(repository:repository,workspaceID:original.workspaceID,jobID:original.id,principal:"owner")
                XCTFail("invalid observation version reached cancellation transport")
            }catch let problem as VideoError {
                guard case .conflict = problem else {XCTFail("invalid observation version did not fail before credential access");return}
            }
            XCTAssertEqual(try Codec.data(repository.read()),before)
        }
    }
    func testRemoteProfileParameterSetsAreStableAcrossPersistenceAndRejectRealChanges()throws {
        let(repository,job,original)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        var profile=original;profile.supportedParameters=["temperature","top_p","max_tokens","seed"]
        try repository.transaction{$0.providers=[profile]}
        for _ in 0..<12 {
            let read=try repository.read()
            XCTAssertEqual(try RemoteJobs.checkedTarget(original:job,profile:profile,database:read,principal:"owner",command:"jobs query").id,job.id)
            XCTAssertEqual(try RemoteJobs.profileIdentity(read.providers[0]),try RemoteJobs.profileIdentity(profile))
            XCTAssertEqual(try RemoteJobs.profileIdentity(read.providers[0]),try ProviderRules.profileIdentity(profile))
        }
        var changed=try repository.read();changed.providers[0].supportedParameters.remove("seed")
        XCTAssertThrowsError(try RemoteJobs.checkedTarget(original:job,profile:profile,database:changed,principal:"owner",command:"jobs query"))
    }
    func testRemoteReplyRejectsRevokedAuthorityAndChangedBindingWithoutWritingGeneration()throws {
        for mode in 0..<7 {
            let(repository,original,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{db in
                switch mode {
                case 0:db.workspaces[0].owner="new-owner"
                case 1:db.workspaces[0].grants[0].revoked=true
                case 2:db.providers[0].endpoint="https://replacement.example.com"
                case 3:db.jobs[0].remoteID="replacement-remote"
                case 4:db.jobs[0].quote.upper=Money(1)
                case 5:db.jobs=[]
                default:db.projects[0].revisions[0].scenes[0].body="changed content"
                }
            }
            let before=try Codec.digest(repository.read()),response=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.running,progress:0.6)
            XCTAssertThrowsError(try RemoteJobs.accept(response,original:original,profile:profile,repository:repository,principal:mode==1 ? "editor":"owner",command:"jobs query"),"mode \(mode)")
            XCTAssertEqual(try Codec.digest(repository.read()),before,"rejected reply changed DB/generation \(mode)")
        }
    }
    func testRemoteReplyUsesLiveBillingAndRestrictedStatusWithoutFinancialOrPathDisclosure()throws {
        let(repository,_,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        try repository.transaction{$0.jobs[0].state = .cancelRequested}
        let original=try repository.read().jobs[0]
        try repository.transaction{db in
            db.jobs[0]=try JobOperations.reconcile(db.jobs[0],record:BillingRecord(id:"PRIVATE_BILL",kind:.charge,money:Money(4),source:"规则账单"))
            db.jobs[0]=try JobOperations.reconcile(db.jobs[0],record:BillingRecord(id:"PRIVATE_REFUND",kind:.refundRequested,money:Money(2),source:"规则退款"))
        }
        let response=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.running,progress:0.7)
        let updated=try RemoteJobs.accept(response,original:original,profile:profile,repository:repository,principal:"editor",command:"jobs query")
        XCTAssertEqual(updated.state,.cancelRequested);XCTAssertEqual(updated.actual?.amount,4);XCTAssertEqual(updated.refundPending?.amount,2)
        XCTAssertEqual(updated.billing?.count,2);XCTAssertEqual(updated.id,original.id);XCTAssertEqual(updated.requestKey,original.requestKey)
        let db=try repository.read(),restricted=try AgentJobAccess.status(jobID:original.id,workspaceID:original.workspaceID,database:db,principal:"editor")
        let value=try restricted.value();guard let object=value.object else{return XCTFail("missing scoped object")}
        XCTAssertEqual(Set(object.keys),Set(["id","projectID","revisionID","state","progress","artifacts"]))
        let raw=String(decoding:try Codec.data(value),as:UTF8.self)
        for privateValue in ["PRIVATE_ORIGINAL_REQUEST","PRIVATE_ORIGINAL_REMOTE","PRIVATE_BILL","PRIVATE_REFUND","/private-original/","CNY","quote","refundPending","actual"] {XCTAssertFalse(raw.contains(privateValue),privateValue)}
        guard case .owner(let owner)=try AgentJobAccess.status(jobID:original.id,workspaceID:original.workspaceID,database:db,principal:"owner") else{return XCTFail("owner details removed")}
        XCTAssertEqual(owner.actual?.amount,4);XCTAssertEqual(owner.billing?.count,2)
    }
    func testRemoteOwnerOnlyCommitKeepsMacAndWorkerBoundariesAfterOwnershipChange()throws {
        let(repository,original,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let response=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.running,progress:0.2)
        let before=try Codec.digest(repository.read())
        XCTAssertThrowsError(try RemoteJobs.accept(response,original:original,profile:profile,repository:repository,principal:"editor",command:"jobs query",ownerOnly:true))
        XCTAssertThrowsError(try RemoteJobs.accept(response,original:original,profile:profile,repository:repository,principal:"editor",command:"worker run"))
        XCTAssertEqual(try Codec.digest(repository.read()),before)
        let result=try RemoteJobs.accept(response,original:original,profile:profile,repository:repository,principal:"owner",command:"worker run")
        XCTAssertEqual(result.remoteID,original.remoteID);XCTAssertEqual(result.state,.running)
    }
    func testPrecancelledRepositoryQueryAndCancelNeverAccessCredentialsOrChangeJob()async throws {
        let(repository,job,_)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let before=try Codec.digest(repository.read())
        for cancel in [false,true] {
            let task=Task {withUnsafeCurrentTask{$0?.cancel()};return try await (cancel ? RemoteJobs.cancel(repository:repository,workspaceID:job.workspaceID,jobID:job.id,principal:"owner"):RemoteJobs.query(repository:repository,workspaceID:job.workspaceID,jobID:job.id,principal:"owner"))}
            do{_ = try await task.value;XCTFail("precancelled remote operation ran")}
            catch{XCTAssertTrue(error is CancellationError)}
            XCTAssertEqual(try Codec.digest(repository.read()),before)
        }
    }
    private func absent(_ url:URL)->Bool{!FileManager.default.fileExists(atPath:url.path)}
    func testCandidateCancellationAfterStagingPublishesNothingAndKeepsOldDraft()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"新候选原文",job:job,repository:repository,principal:"owner")
        let old=staged.parent.appendingPathComponent("previous.txt"),oldBytes=Data("以前的讲稿".utf8)
        try oldBytes.write(to:old)
        try repository.transaction{$0.jobs[0]=JobRules.cancel($0.jobs[0])}
        let before=try Codec.digest(repository.read())
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertTrue(absent(staged.final));XCTAssertTrue(absent(staged.staging));XCTAssertEqual(try Data(contentsOf:old),oldBytes)
        XCTAssertEqual(try Codec.digest(repository.read()),before)
        XCTAssertEqual(try repository.read().jobs[0].state,.cancelRequested)
    }
    func testRevokedOwnerAfterStagingCannotLeaveFormalCandidate()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"仍未授权发布的候选",job:job,repository:repository,principal:"owner")
        try repository.transaction{$0.workspaces[0].owner="new-owner"}
        let before=try Codec.digest(repository.read())
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertTrue(absent(staged.final));XCTAssertTrue(absent(staged.staging));XCTAssertEqual(try Codec.digest(repository.read()),before)
    }
    func testExistingFormalCandidateIsNeverReplacedOrRemoved()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"新返回的候选",job:job,repository:repository,principal:"owner"),old=Data("预存文件，不能覆盖".utf8)
        try old.write(to:staged.final)
        let before=try Codec.digest(repository.read())
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertEqual(try Data(contentsOf:staged.final),old);XCTAssertTrue(absent(staged.staging))
        XCTAssertEqual(try Codec.digest(repository.read()),before);XCTAssertTrue(try repository.read().jobs[0].artifacts.isEmpty)
    }
    func testNormalCandidatePublicationPreservesOriginalIDAndCanBeReadBack()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let text="四个人各出一枚硬币。三枚就能修路。",staged=try ScriptJobs.prepareDraft(text:text,job:job,repository:repository,principal:"owner")
        XCTAssertTrue(absent(staged.final))
        let completed=try ScriptJobs.publishDraft(staged,repository:repository)
        XCTAssertEqual(completed.id,job.id);XCTAssertEqual(completed.requestKey,job.requestKey);XCTAssertEqual(completed.quote.id,job.quote.id)
        XCTAssertEqual(completed.state,.billingPending);XCTAssertTrue(completed.billingUnknown);XCTAssertNil(completed.lease)
        XCTAssertTrue(absent(staged.staging));XCTAssertEqual(try Data(contentsOf:staged.final),Data(text.utf8))
        XCTAssertEqual(try ScriptJobs.draft(repository:repository,job:completed),text)
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertEqual(try repository.read().jobs.count,1)
    }
    func testTransactionWriteFailureAfterRenameReclaimsOnlyOwnCandidate()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"事务未提交，不能留下正式文件",job:job,repository:repository,principal:"owner")
        let before=try Codec.digest(repository.read()),process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3")
        process.arguments=[repository.root.appendingPathComponent("workspace.sqlite").path,"CREATE TRIGGER reject_candidate BEFORE INSERT ON snapshot BEGIN SELECT RAISE(ABORT, 'controlled local persistence failure'); END;"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertTrue(absent(staged.final));XCTAssertTrue(absent(staged.staging));XCTAssertEqual(try Codec.digest(repository.read()),before)
    }
    func testChangedTemporaryFileIsPreservedInsteadOfDeletingSomeoneElsesBytes()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"原暂存",job:job,repository:repository,principal:"owner"),changed=Data("已被其它操作替换".utf8)
        try changed.write(to:staged.temporary,options:.atomic)
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertTrue(absent(staged.final));XCTAssertEqual(try Data(contentsOf:staged.temporary),changed)
        XCTAssertTrue(try repository.read().jobs[0].artifacts.isEmpty)
    }
    func testReadOnlyPreparationRejectsBeforeCreatingAnyStagingFile()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let readonly=try Repository(root:repository.root,readOnly:true)
        XCTAssertThrowsError(try ScriptJobs.prepareDraft(text:"不能写入",job:job,repository:readonly,principal:"owner"))
        XCTAssertTrue(absent(repository.root.appendingPathComponent("drafts")))
    }
    func testExpiredProviderDeadlineRefusesBeforeCredentialOrNetworkAccess()async throws {
        let(repository,_)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let database=try repository.read()
        do {
            _=try await ProviderClient.script(profile:database.providers[0],revision:database.projects[0].current,evidence:[],brief:"期限已过，不得发送",deadline:Date().addingTimeInterval(-1))
            XCTFail("expired request was allowed")
        }catch let error as VideoError {
            XCTAssertTrue(error.localizedDescription.contains("明确执行期限"))
        }
        XCTAssertEqual(try repository.read().jobs.count,1)
    }
    func testProviderCancellationRemainsCancellationBeforeCredentials()async throws {
        let(repository,_)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let database=try repository.read()
        let task=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return try await ProviderClient.script(profile:database.providers[0],revision:database.projects[0].current,evidence:[],brief:"已取消，不得发送")
        }
        do{_ = try await task.value;XCTFail("cancelled request was allowed")}catch{XCTAssertTrue(error is CancellationError)}
    }
    func testPrecancelledPublicSubmissionNeverReadsCredentialsOrStoresPaidIntent()async throws {
        let(repository,prepared)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        try repository.transaction{$0.jobs=[]}
        let database=try repository.read(),before=try Codec.digest(database)
        let task=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return try await ScriptJobs.submit(repository:repository,workspaceID:"w",projectID:database.projects[0].id,profileID:database.providers[0].id,evidenceIDs:[],brief:"解释已选内容",quote:prepared.quote,requestKey:"pre-cancelled-public",principal:"owner")
        }
        do{_ = try await task.value;XCTFail("pre-cancelled submission was allowed")}
        catch{XCTAssertTrue(error is CancellationError,"public entry must return cancellation before local credential access; got \(type(of:error))")}
        XCTAssertEqual(try Codec.digest(repository.read()),before)
        XCTAssertTrue(try repository.read().jobs.isEmpty)
    }
    func testCancellationAfterPreparedReceiptDoesNotEnterTransmissionBoundary()async throws {
        let(repository,_)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        var profile=try repository.read().providers[0]
        profile.keyReference="script-rules-"+Codec.id()
        try SecureCredentials.save("local-rule-value",reference:profile.keyReference)
        defer{SecureCredentials.remove(profile.keyReference)}
        let boundary=ScriptTestTransmissionCount(),revision=try repository.read().projects[0].current
        let task=Task {
            try await ProviderClient.script(profile:profile,revision:revision,evidence:[],brief:"取消边界",onTransmissionStarted:{boundary.record()},onAttempt:{_ in withUnsafeCurrentTask{$0?.cancel()}})
        }
        do{_ = try await task.value;XCTFail("cancelled after preparation")}
        catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(boundary.value,0)
    }
    func testEnteredTransportFailureRetainsUnknownSpendAndPreventsNewPaidIntent()async throws {
        let(repository,prepared)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let reference="script-rules-"+Codec.id()
        try SecureCredentials.save("local-rule-value",reference:reference);defer{SecureCredentials.remove(reference)}
        try repository.transaction{db in db.jobs=[];db.providers[0].keyReference=reference;db.providers[0].endpoint="https://127.0.0.1:1/chat/completions"}
        let db=try repository.read(),p=db.projects[0],profile=db.providers[0]
        // A refused local TLS connection is a transport-boundary rule test,
        // never a real supplier acceptance or a supplier billing receipt.
        do{_ = try await ScriptJobs.submit(repository:repository,workspaceID:"w",projectID:p.id,profileID:profile.id,evidenceIDs:[],brief:"解释已选内容",quote:prepared.quote,requestKey:"local-refused-transport",principal:"owner");XCTFail("loopback port unexpectedly accepted script")}
        catch{XCTAssertFalse(error is CancellationError)}
        let actual=try repository.read();XCTAssertEqual(actual.jobs.count,1)
        let unknown=try XCTUnwrap(actual.jobs.first)
        XCTAssertEqual(unknown.state,.unknownRemote);XCTAssertTrue(unknown.billingUnknown);XCTAssertEqual(unknown.exposure.amount,3);XCTAssertNil(unknown.actual);XCTAssertNil(unknown.lease)
        var next=prepared.quote;next.id=Codec.id()
        XCTAssertThrowsError(try repository.transaction{try ScriptJobRules.prepare(database:&$0,workspaceID:"w",projectID:p.id,profile:profile,evidence:[],brief:"解释已选内容",quote:next,requestKey:"cannot-pay-again",principal:"owner")})
        XCTAssertEqual(try repository.read().jobs.count,1)
    }
    func testFailureAfterWorkspaceRevocationCannotWriteZeroCostOrUnknownState()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let token=try XCTUnwrap(job.lease).token
        try repository.transaction{$0.workspaces[0].owner="new-owner"}
        let before=try Codec.digest(repository.read())
        for transmitted in [false,true] {
            XCTAssertThrowsError(try ScriptJobs.handleFailure(repository:repository,job:job,principal:"owner",executionToken:token,transmissionStarted:transmitted))
            XCTAssertEqual(try Codec.digest(repository.read()),before)
        }
    }
    private func attemptFixture()throws->(Repository,Job,ProviderProfile,[Evidence]) {
        let(repository,_)=try fixture()
        try repository.transaction{database in
            database.jobs=[];database.providers[0].capabilities?.repairLimit=1
            database.evidence=[Evidence(workspaceID:"w",title:"本地规则证据",source:"author-rule-only",claim:"仅为上传撤销规则",owner:"owner",commercialAllowed:false,uploadConsent:true,verified:true)]
        }
        let database=try repository.read(),profile=database.providers[0],project=database.projects[0],evidence=database.evidence
        let quote=try EstimateBreakdown(version:"rule-two",specification:ScriptJobRules.specification(profile:profile,revision:project.current,evidence:evidence,brief:"解释已选内容"),source:"本地规则费用，不代表供应商账单",validFrom:.distantPast,expiresAt:Date().addingTimeInterval(600),lines:[RateLine(label:"两次规则预算",quantity:1,unit:"次",price:Money(3),attempts:2)],excluded:[]).quote(project:project,provider:profile.id,confirmed:true)
        let job=try repository.transaction{try ScriptJobRules.prepare(database:&$0,workspaceID:"w",projectID:project.id,profile:profile,evidence:evidence,brief:"解释已选内容",quote:quote,requestKey:"original-repair",principal:"owner")}.job
        return(repository,job,profile,evidence)
    }
    func testRevokingCredentialAfterPreparedReceiptPreventsTransmission()async throws {
        let(repository,_)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        var profile=try repository.read().providers[0];profile.keyReference="revoke-before-send-"+Codec.id()
        let reference=profile.keyReference
        try SecureCredentials.save("local-rule-value",reference:reference);defer{SecureCredentials.remove(reference)}
        let boundary=ScriptTestTransmissionCount(),revision=try repository.read().projects[0].current
        do {
            _=try await ProviderClient.script(profile:profile,revision:revision,evidence:[],brief:"撤销后的凭据不能传输",onTransmissionStarted:{boundary.record()},onAttempt:{_ in try SecureCredentials.revoke(reference)})
            XCTFail("revoked credential entered transport")
        }catch let error as VideoError {XCTAssertTrue(error.localizedDescription.contains("模型凭据不可用"))}
        XCTAssertEqual(boundary.value,0);XCTAssertFalse(SecureCredentials.contains(reference))
    }
    func testScriptRepairRechecksLiveProfileEvidenceAndContentWithoutRejectedWrites()throws {
        for mode in 0..<10 {
            let(repository,job,profile,evidence)=try attemptFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            let token=try XCTUnwrap(job.lease).token
            var first=try XCTUnwrap(job.providerAttempts?.first);first.respondedAt=Date()
            try ScriptJobs.recordAttempt(first,job:job,profile:profile,evidence:evidence,brief:"解释已选内容",repository:repository,principal:"owner",executionToken:token)
            try repository.transaction{database in
                switch mode {
                case 0:database.providers[0].allowsUpload=false
                case 1:database.providers[0].keyReference="rebound-reference"
                case 2:database.providers[0].model="different-model"
                case 3:database.providers[0].capabilities?.version="changed-contract"
                case 4:database.evidence[0].uploadConsent=false
                case 5:database.evidence[0].verified=false
                case 6:database.evidence[0].claim="改过的实际内容"
                case 7:database.evidence[0].expiresAt=Date().addingTimeInterval(-1)
                case 8:database.evidence=[]
                default:
                    let original=database.projects[0]
                    database.projects[0]=try Editor.apply([.cta("正常变更创作目标")],to:original,baseRevision:original.current.id,assets:[],message:"正常编辑")
                }
            }
            let before=try Codec.data(repository.read())
            let repair=ProviderAttempt(id:job.requestKey+"-attempt-2",number:2,inputDigest:Codec.hash(Data("有界修复".utf8)),capabilityVersion:profile.capabilities?.version)
            XCTAssertThrowsError(try ScriptJobs.recordAttempt(repair,job:job,profile:profile,evidence:evidence,brief:"解释已选内容",repository:repository,principal:"owner",executionToken:token),"mode \(mode)")
            XCTAssertEqual(try Codec.data(repository.read()),before)
            XCTAssertEqual(try repository.read().jobs[0].providerAttempts?.count,1)
        }
    }
    func testOriginalResponseThenSingleRepairKeepsIdentityAndUnknownSpend()throws {
        let(repository,job,profile,evidence)=try attemptFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let token=try XCTUnwrap(job.lease).token
        var first=try XCTUnwrap(job.providerAttempts?.first);first.respondedAt=Date();first.inputTokens=20
        try ScriptJobs.recordAttempt(first,job:job,profile:profile,evidence:evidence,brief:"解释已选内容",repository:repository,principal:"owner",executionToken:token)
        let repair=ProviderAttempt(id:job.requestKey+"-attempt-2",number:2,inputDigest:Codec.hash(Data("唯一结构修复".utf8)),capabilityVersion:profile.capabilities?.version)
        try ScriptJobs.recordAttempt(repair,job:job,profile:profile,evidence:evidence,brief:"解释已选内容",repository:repository,principal:"owner",executionToken:token)
        let saved=try repository.read().jobs[0]
        XCTAssertEqual(saved.id,job.id);XCTAssertEqual(saved.requestKey,job.requestKey);XCTAssertEqual(saved.providerAttempts?.count,2)
        XCTAssertEqual(saved.providerAttempts?.first?.inputTokens,20);XCTAssertEqual(saved.attempt,2);XCTAssertTrue(saved.billingUnknown);XCTAssertNil(saved.actual)
        var third=repair;third.id=job.requestKey+"-attempt-3";third.number=3
        let before=try Codec.data(repository.read())
        XCTAssertThrowsError(try ScriptJobs.recordAttempt(third,job:job,profile:profile,evidence:evidence,brief:"解释已选内容",repository:repository,principal:"owner",executionToken:token))
        XCTAssertEqual(try Codec.data(repository.read()),before)
    }
    func testLateRemoteBillCannotOverwriteLivePartialRefundLedger()throws {
        for amount:Decimal in [0,12,100] {
            let(repository,original,profile)=try remoteFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{database in
                for record in [BillingRecord(id:"rule-charge",kind:.charge,money:Money(12),source:"本地账单规则"),BillingRecord(id:"rule-refund-request",kind:.refundRequested,money:Money(5),source:"本地申请规则"),BillingRecord(id:"rule-refund-received",kind:.refundReceived,money:Money(3),source:"本地到账规则")] {
                    database.jobs[0]=try JobOperations.reconcile(database.jobs[0],record:record)
                }
            }
            let ledger=try Codec.data(repository.read().jobs[0].billing)
            let response=RemoteSnapshot(remoteID:original.remoteID!,requestKey:original.requestKey,state:.cancelled,progress:0.8,actual:Money(amount))
            let updated=try RemoteJobs.accept(response,original:original,profile:profile,repository:repository,principal:"owner",command:"jobs query")
            XCTAssertEqual(updated.actual?.amount,9);XCTAssertEqual(updated.refundPending?.amount,2);XCTAssertEqual(try Codec.data(updated.billing),ledger)
            XCTAssertEqual(updated.remoteReportedActual?.amount,amount);XCTAssertTrue(updated.billingUnknown);XCTAssertGreaterThanOrEqual(updated.exposure.amount,max(9,amount))
        }
    }

}
private final class ScriptTestTransmissionCount:@unchecked Sendable {
    private let lock=NSLock();private var count=0
    func record(){lock.lock();defer{lock.unlock()};count+=1}
    var value:Int{lock.lock();defer{lock.unlock()};return count}
}
#endif
