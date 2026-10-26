import XCTest
import VideoCore
@testable import VideoMedia

final class BaiduVideoProviderTests:XCTestCase {
    private func fixture()throws->(Repository,Job,ProviderProfile,Asset) {
        let(repository,job,profile,asset,_)=try liveFixture()
        return(repository,job,profile,asset)
    }
    private func liveFixture()throws->(Repository,Job,ProviderProfile,Asset,BaiduSubmissionPermit) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("baidu-reply-rules-"+Codec.id(),isDirectory:true),repository=try Repository(root:root)
        let workspace=Workspace(name:"百度回包本地规则",owner:"owner"),revision=try Planner.create(workspaceID:workspace.id,name:"本地知识",aspect:.landscape,scenes:[Scene(title:"解释",body:"原有本地内容")]),project=Project(workspaceID:workspace.id,name:"本地知识",revision:revision)
        let profile=BaiduVideoRules.profile(keyReference:"unused-rules-reference",allowsUpload:true),input=BaiduVideoInput(segments:[.init(text:"输入和输出共同占用上下文容量，请在真实界面对照复现并理解边界。"),.init(type:.image,url:"https://example.com/original-rule-image.png")])
        let details=EstimateBreakdown(version:BaiduVideoRules.version,specification:try BaiduVideoRules.specification(input:input),source:"本地规则上界，不是供应商账单",validFrom:Date().addingTimeInterval(-60),expiresAt:Date().addingTimeInterval(600),lines:[RateLine(label:"一次请求",quantity:1,unit:"次",price:Money(3))],excluded:[]),quote=try details.quote(project:project,provider:profile.id,confirmed:true)
        let asset=try repository.ingest(Data("已有原件，回包不得改写".utf8),name:"existing.txt",workspaceID:workspace.id,mediaType:"text")
        let prepared=try repository.transaction{db->(job:Job,shouldSubmit:Bool,permit:BaiduSubmissionPermit?) in
            db.workspaces=[workspace];db.projects=[project];db.providers=[profile];db.assets=[asset]
            return try BaiduVideoRules.prepareForSubmission(database:&db,workspaceID:workspace.id,projectID:project.id,profile:profile,input:input,quote:quote,requestID:"one-original-request",principal:"owner")
        }
        return(repository,prepared.job,profile,asset,try XCTUnwrap(prepared.permit))
    }
    func testBaiduAcceptedReplyUsesLiveBillingAndPreservesOriginalSource()throws {
        let(repository,original,profile,asset)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let bytes=try Data(contentsOf:repository.assetURL(asset))
        try repository.transaction{db in db.jobs[0]=try JobOperations.reconcile(db.jobs[0],record:BillingRecord(id:"confirmed-rule-charge",kind:.charge,money:Money(2),source:"本地规则确认"));db.jobs[0].progress=0.4}
        let before=try repository.read(),updated=try BaiduVideoProvider.update(repository:repository,original:original,profile:profile,principal:"owner",command:"baidu submit"){job,_ in job=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:job)}
        XCTAssertEqual(updated.remoteID,"1717153286267015037");XCTAssertEqual(updated.state,.queued)
        XCTAssertEqual(updated.actual?.amount,2);XCTAssertEqual(updated.billing?.first?.id,"confirmed-rule-charge");XCTAssertEqual(updated.progress,0.4)
        XCTAssertEqual(updated.requestKey,original.requestKey);XCTAssertEqual(try Codec.digest(updated.quote),try Codec.digest(original.quote))
        XCTAssertEqual(try repository.read().generation,before.generation+1)
        XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes);XCTAssertEqual(try repository.read().assets.first?.id,asset.id)
    }
    func testBaiduRevokedOwnerBlocksEveryReplyTransactionWithoutGenerationChange()throws {
        let(repository,original,profile,asset)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        try repository.transaction{$0.workspaces[0].owner="replacement-owner"}
        let before=try Codec.digest(repository.read()),bytes=try Data(contentsOf:repository.assetURL(asset))
        for command in ["baidu submit","baidu query","baidu collect"] {
            var mutated=false
            XCTAssertThrowsError(try BaiduVideoProvider.update(repository:repository,original:original,profile:profile,principal:"owner",command:command){job,_ in mutated=true;job.message="must not commit"})
            XCTAssertFalse(mutated);XCTAssertEqual(try Codec.digest(repository.read()),before)
        }
        XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
    }
    func testBaiduChangedTargetOrProviderRejectsCallbackBeforeMutation()throws {
        let mutations:[(inout Database)->Void]=[
            {$0.jobs=[]},{$0.jobs[0].projectID="another-project"},{$0.jobs[0].revisionID="another-version"},
            {$0.jobs[0].requestKey="another-request"},{$0.jobs[0].quote.id=Codec.id()},{$0.jobs[0].remoteID="already-bound-original"},
            {$0.jobs[0].videoGeneration?.inputDigest=String(repeating:"b",count:64)},
            {$0.jobs[0].videoGeneration?.contractVersion="another-contract"},{$0.providers=[]},
            {$0.providers[0].name="service-renamed-during-request"},{$0.providers[0].keyReference="another-reference"},
            {$0.projects[0].revisions[0].scenes[0].body="source-content-changed"}
        ]
        for (index,mutation) in mutations.enumerated() {
            let(repository,original,profile,asset)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{mutation(&$0)}
            let before=try Codec.digest(repository.read()),bytes=try Data(contentsOf:repository.assetURL(asset));var mutated=false
            XCTAssertThrowsError(try BaiduVideoProvider.update(repository:repository,original:original,profile:profile,principal:"owner",command:"baidu collect"){job,_ in mutated=true;job.state = .billingPending},"target mutation \(index)")
            XCTAssertFalse(mutated);XCTAssertEqual(try Codec.digest(repository.read()),before)
            XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
        }
    }
    func testBaiduLateCleanupCannotClearReplacedLeaseOrWriteAfterRevocation()throws {
        let(repository,original,profile,_)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let claimed=try BaiduVideoProvider.update(repository:repository,original:original,profile:profile,principal:"owner",command:"baidu collect"){job,_ in job.videoGeneration?.collectionToken="original-collector";job.videoGeneration?.collectionExpiresAt=Date().addingTimeInterval(240)}
        try repository.transaction{$0.jobs[0].videoGeneration?.collectionToken="replacement-collector"}
        let replacement=try Codec.digest(repository.read())
        XCTAssertThrowsError(try BaiduVideoProvider.releaseCollection(repository:repository,original:claimed,profile:profile,principal:"owner",token:"original-collector"))
        XCTAssertEqual(try Codec.digest(repository.read()),replacement)
        try repository.transaction{$0.workspaces[0].owner="replacement-owner"}
        let revoked=try Codec.digest(repository.read())
        XCTAssertThrowsError(try BaiduVideoProvider.releaseCollection(repository:repository,original:claimed,profile:profile,principal:"owner",token:"replacement-collector"))
        XCTAssertEqual(try Codec.digest(repository.read()),revoked)
        try BaiduVideoProvider.releaseCollection(repository:repository,original:claimed,profile:profile,principal:"replacement-owner",token:"replacement-collector")
        XCTAssertNil(try repository.read().jobs[0].videoGeneration?.collectionToken)
        let released=try Codec.digest(repository.read())
        XCTAssertThrowsError(try BaiduVideoProvider.releaseCollection(repository:repository,original:claimed,profile:profile,principal:"replacement-owner",token:"replacement-collector"))
        XCTAssertEqual(try Codec.digest(repository.read()),released)
    }
    func testBaiduFailedMutationRollsBackAppendedDataAndCurrentJobTogether()throws {
        let(repository,original,profile,asset)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let before=try Codec.digest(repository.read()),bytes=try Data(contentsOf:repository.assetURL(asset))
        XCTAssertThrowsError(try BaiduVideoProvider.update(repository:repository,original:original,profile:profile,principal:"owner",command:"baidu collect"){job,db in
            db.assets=[];job.message="uncommitted"
            throw VideoError.conflict("受控规则失败，未提交回包")
        })
        XCTAssertEqual(try Codec.digest(repository.read()),before);XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
    }
    func testOfficialBaiduContractCannotCallCustomCancelOrPretendToBeChat()throws {
        let profile=BaiduVideoRules.profile(keyReference:"test-keychain-reference-not-credential")
        XCTAssertThrowsError(try RemoteJobs.requireCancellationSupport(profile:profile))
        XCTAssertThrowsError(try ProviderRules.validate(profile:profile))
        XCTAssertFalse(profile.idempotency);XCTAssertNil(profile.cancelPath)
    }
    func testUnknownOriginalDoesNotReadKeychainOrResubmitFromQuery()async throws {
        let product=Product(workspaceID:"w",sku:"one",name:"课程",checkout:"https://example.com",audience:"新人",task:"复现",outcome:"理解",prerequisite:"",scope:"知识",prices:[Price(money:Money(1),source:"产品页")]),revision=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"知识",body:"内容")],cta:"复现"),profile=BaiduVideoRules.profile(keyReference:"intentionally-missing-keychain-reference")
        let quote=Quote(projectID:"p",revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(3),unit:"CNY",provider:profile.id,expiresAt:Date().addingTimeInterval(60));var job=Job(workspaceID:"w",projectID:"p",revisionID:revision.id,digest:try revision.contentDigest(),requestKey:"original",quote:quote);job.videoGeneration=VideoGenerationReceipt(inputDigest:String(repeating:"a",count:64));job.state = .unknownRemote
        do{_ = try await RemoteJobs.query(profile:profile,job:job);XCTFail("unknown ID was queried or submitted")}
        catch{XCTAssertEqual((error as? VideoError)?.exitCode,8);XCTAssertFalse(error.localizedDescription.contains("intentionally-missing-keychain-reference"))}
        XCTAssertEqual(job.state,.unknownRemote);XCTAssertNil(job.remoteID);XCTAssertEqual(job.requestKey,"original")
    }
    func testPrecancelledPublicBaiduSubmissionNeverReadsCredentialsOrStoresIntent()async throws {
        let(repository,original,profile,asset)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        try repository.transaction{$0.jobs=[]}
        let before=try Codec.digest(repository.read()),bytes=try Data(contentsOf:repository.assetURL(asset))
        let payload=BaiduVideoInput(segments:[.init(text:"输入和输出共同占用上下文容量，请在真实界面对照复现并理解边界。"),.init(type:.image,url:"https://example.com/original-rule-image.png")])
        let task=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return try await BaiduVideoProvider.submit(repository:repository,workspaceID:original.workspaceID,projectID:original.projectID,profileID:profile.id,input:payload,quote:original.quote,requestID:"precancelled-public",principal:"owner")
        }
        do{_ = try await task.value;XCTFail("pre-cancelled Baidu submission was allowed")}
        catch{XCTAssertTrue(error is CancellationError,"must stop before the absent rule-only credential reference; got \(type(of:error))")}
        XCTAssertEqual(try Codec.digest(repository.read()),before);XCTAssertTrue(try repository.read().jobs.isEmpty)
        XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
    }
    func testPrecancelledBaiduQueryRefreshAndCollectionLeaveOriginalUnchanged()async throws {
        let(repository,original,profile,asset)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let accepted=try repository.transaction{db->Job in db.jobs[0]=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:db.jobs[0]);return db.jobs[0]}
        let before=try Codec.digest(repository.read()),bytes=try Data(contentsOf:repository.assetURL(asset))
        for operation in 0..<4 {
            let task=Task {
                withUnsafeCurrentTask{$0?.cancel()}
                switch operation {
                case 0:_ = try await BaiduVideoProvider.refresh(repository:repository,workspaceID:original.workspaceID,jobID:original.id,principal:"owner")
                case 1:_ = try await BaiduVideoProvider.collect(repository:repository,workspaceID:original.workspaceID,jobID:original.id,principal:"owner")
                case 2:_ = try await BaiduVideoProvider.query(profile:profile,job:accepted)
                default:_ = try await BaiduVideoProvider.querySnapshot(profile:profile,job:accepted)
                }
                return true
            }
            do{_ = try await task.value;XCTFail("pre-cancelled Baidu operation \(operation) was allowed")}
            catch{XCTAssertTrue(error is CancellationError)}
            XCTAssertEqual(try Codec.digest(repository.read()),before)
        }
        XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
    }
    func testLiveUntransmittedFailureKeepsScopeAndSourceWithZeroCost()throws {
        for cancelled in [false,true] {
            let(repository,original,profile,asset,permit)=try liveFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            let before=try repository.read(),bytes=try Data(contentsOf:repository.assetURL(asset))
            let changed=try BaiduVideoProvider.handleSubmissionFailure(repository:repository,original:original,profile:profile,principal:"owner",permit:permit,wasCancelled:cancelled)
            XCTAssertEqual(changed.state,cancelled ? .cancelled:.failed);XCTAssertEqual(changed.actual,Money(0,original.quote.upper.currency));XCTAssertEqual(changed.exposure,Money(0,original.quote.upper.currency));XCTAssertFalse(changed.billingUnknown)
            XCTAssertEqual(changed.id,original.id);XCTAssertEqual(changed.requestKey,original.requestKey);XCTAssertEqual(try Codec.digest(changed.quote),try Codec.digest(original.quote));XCTAssertNil(changed.refundPending);XCTAssertTrue((changed.billing ?? []).isEmpty)
            let after=try repository.read();var expected=before;expected.jobs[0]=changed;expected.generation=after.generation
            XCTAssertEqual(after.generation,before.generation+1);XCTAssertEqual(try Codec.digest(after),try Codec.digest(expected));XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
            let completed=try Codec.digest(after)
            XCTAssertThrowsError(try BaiduVideoProvider.handleSubmissionFailure(repository:repository,original:original,profile:profile,principal:"owner",permit:permit,wasCancelled:cancelled))
            XCTAssertEqual(try Codec.digest(repository.read()),completed)
        }
    }
    func testEnteredTransmissionFailureRetainsUnknownReservationAndReceiptLedger()throws {
        let(repository,original,profile,asset,permit)=try liveFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        try permit.markTransmissionStarted()
        try repository.transaction{db in
            db.jobs[0]=try JobOperations.reconcile(db.jobs[0],record:BillingRecord(id:"local-charge",kind:.charge,money:Money(3),source:"隔离规则账单"))
            db.jobs[0]=try JobOperations.reconcile(db.jobs[0],record:BillingRecord(id:"local-refund-request",kind:.refundRequested,money:Money(2),source:"隔离规则申请"))
            db.jobs[0]=try JobOperations.reconcile(db.jobs[0],record:BillingRecord(id:"local-refund-received",kind:.refundReceived,money:Money(1),source:"隔离规则到账"))
        }
        let before=try repository.read(),bytes=try Data(contentsOf:repository.assetURL(asset)),ledger=try Codec.digest(before.jobs[0].billing)
        let changed=try BaiduVideoProvider.handleSubmissionFailure(repository:repository,original:original,profile:profile,principal:"owner",permit:permit,wasCancelled:true)
        XCTAssertEqual(changed.state,.unknownRemote);XCTAssertTrue(changed.billingUnknown);XCTAssertEqual(changed.videoGeneration?.phase,.unknown);XCTAssertEqual(changed.actual,Money(2));XCTAssertEqual(changed.refundPending,Money(1));XCTAssertEqual(changed.exposure,original.quote.upper)
        XCTAssertEqual(try Codec.digest(changed.billing),ledger);XCTAssertEqual(changed.requestKey,original.requestKey);XCTAssertEqual(try Codec.digest(changed.quote),try Codec.digest(original.quote));XCTAssertNil(changed.remoteID);XCTAssertFalse(changed.message.contains("实际费用为0"));XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
        let frozen=try Codec.digest(repository.read())
        XCTAssertThrowsError(try BaiduVideoProvider.handleSubmissionFailure(repository:repository,original:original,profile:profile,principal:"owner",permit:permit,wasCancelled:true))
        XCTAssertEqual(try Codec.digest(repository.read()),frozen)
    }
    func testSubmissionFailureCannotClearCostAfterAuthorityOrTargetChanges()throws {
        let mutations:[(inout Database)->Void]=[
            {$0.workspaces[0].owner="replacement-owner"},{$0.providers[0].keyReference="replaced-reference"},
            {$0.jobs[0].requestKey="replaced-request"},{$0.jobs[0].quote.id=Codec.id()},
            {$0.projects[0].revisions[0].scenes[0].body="changed-original-content"}
        ]
        for mutation in mutations {
            let(repository,original,profile,asset,permit)=try liveFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{mutation(&$0)}
            let before=try Codec.digest(repository.read()),bytes=try Data(contentsOf:repository.assetURL(asset))
            for transmitted in [false,true] {
                if transmitted{try permit.markTransmissionStarted()}
                XCTAssertThrowsError(try BaiduVideoProvider.handleSubmissionFailure(repository:repository,original:original,profile:profile,principal:"owner",permit:permit,wasCancelled:true))
                XCTAssertEqual(try Codec.digest(repository.read()),before)
            }
            XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
        }
    }
    func testUntransmittedCleanupCannotEraseConcurrentBillingOrAcceptedResponse()throws {
        let mutations:[(inout Job)throws->Void]=[
            {$0=try JobOperations.reconcile($0,record:BillingRecord(id:"concurrent-charge",kind:.charge,money:Money(1),source:"隔离规则并发账单"))},
            {$0=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:$0)},
            {$0.videoGeneration?.phase = .unknown},{$0.videoGeneration?.points=0}
        ]
        for mutation in mutations {
            let(repository,original,profile,asset,permit)=try liveFixture();defer{try? FileManager.default.removeItem(at:repository.root)}
            try repository.transaction{db in try mutation(&db.jobs[0])}
            let before=try Codec.digest(repository.read()),bytes=try Data(contentsOf:repository.assetURL(asset))
            XCTAssertThrowsError(try BaiduVideoProvider.handleSubmissionFailure(repository:repository,original:original,profile:profile,principal:"owner",permit:permit,wasCancelled:true))
            XCTAssertEqual(try Codec.digest(repository.read()),before);XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),bytes)
        }
    }
}
