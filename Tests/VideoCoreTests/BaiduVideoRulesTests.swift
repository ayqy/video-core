import XCTest
@testable import VideoCore

final class BaiduVideoRulesTests:XCTestCase {
    func testPublicQueryObservationRejectsEveryChangedOriginalBinding()throws {
        var(db,w,project,profile,quote)=try fixture()
        let prepared=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"bound-query",principal:"owner")
        let accepted=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:prepared.job),before=try Codec.digest(accepted)
        let changes:[(inout Job)->Void]=[
            {$0.id="another-job"},{$0.workspaceID="another-workspace"},{$0.projectID="another-project"},
            {$0.revisionID="another-revision"},{$0.digest=String(repeating:"b",count:64)},
            {$0.requestKey="another-request"},{$0.quote.provider="another-provider"},{$0.remoteID="1717153286267015038"},
            {$0.createdAt=$0.createdAt.addingTimeInterval(1)},{$0.quote.id="another-quote"},{$0.quote.upper=Money(999)},
            {$0.videoGeneration?.inputDigest=String(repeating:"b",count:64)},
            {$0.videoGeneration?.contractVersion="another-contract"},{$0.videoGeneration?.model="another-model"},
            {$0.videoGeneration?.startedAt=Date(timeIntervalSince1970:1000)}
        ]
        for (index,change) in changes.enumerated() {
            var mismatched=accepted;change(&mismatched)
            // Identical local counter/phase/empty lease cannot bind another task.
            XCTAssertEqual(mismatched.videoGeneration?.querySequence,accepted.videoGeneration?.querySequence)
            XCTAssertThrowsError(try BaiduVideoRules.applyQuery(BaiduQueryResponse(state:.running,progress:0.4),to:accepted,observing:mismatched),"binding \(index)")
            XCTAssertEqual(try Codec.digest(accepted),before)
        }
    }
    func testLegacyQueryReceiptAdvancesPersistedSequenceEvenAtSameTime()throws {
        var(db,w,project,profile,quote)=try fixture()
        let prepared=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"query-sequence",principal:"owner")
        var original=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:prepared.job)
        let raw=try Codec.data(try XCTUnwrap(original.videoGeneration)),object=try XCTUnwrap(try JSONSerialization.jsonObject(with:raw) as? [String:Any])
        XCTAssertNil(object["querySequence"])
        original.videoGeneration=try Codec.decoder().decode(VideoGenerationReceipt.self,from:raw)
        XCTAssertNil(original.videoGeneration?.querySequence)
        let now=Date().addingTimeInterval(10),response=BaiduQueryResponse(state:.running,progress:0.4,points:7.5)
        let first=try BaiduVideoRules.applyQuery(response,to:original,observing:original,now:now)
        XCTAssertEqual(first.videoGeneration?.querySequence,1)
        let restored=try Codec.decoder().decode(Job.self,from:Codec.data(first))
        let second=try BaiduVideoRules.applyQuery(response,to:restored,observing:restored,now:now)
        XCTAssertEqual(second.videoGeneration?.querySequence,2)
        XCTAssertEqual(second.videoGeneration?.checkedAt,first.videoGeneration?.checkedAt)
        XCTAssertThrowsError(try BaiduVideoRules.applyQuery(response,to:second,observing:first,now:now))
    }
    func testQuerySequenceRejectsNegativeAndExhaustedReceiptWithoutOverflow()throws {
        var(db,w,project,profile,quote)=try fixture()
        let prepared=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"query-limit",principal:"owner")
        let accepted=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:prepared.job)
        for invalid in [-1,Int.max] {
            var original=accepted;original.videoGeneration?.querySequence=invalid
            let before=try Codec.digest(original)
            XCTAssertThrowsError(try BaiduVideoRules.applyQuery(BaiduQueryResponse(state:.running,progress:0.4),to:original,observing:original))
            XCTAssertEqual(try Codec.digest(original),before)
        }
    }
    func testCollectedLocalFactsSurviveEveryFreshSupplierQueryState()throws {
        var(db,w,project,profile,quote)=try fixture()
        let prepared=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"collected-query",principal:"owner")
        var original=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:prepared.job)
        original.videoGeneration?.phase = .collected;original.outputAssetIDs=["isolated-source-id"]
        original.state = .billingPending;original.progress=1;original.actual=Money(1);original.billingUnknown=false
        let now=Date().addingTimeInterval(10)
        for state in [BaiduQueryResponse.State.queued,.running,.ready,.failed,.expired,.unknown] {
            let response=BaiduQueryResponse(state:state,progress:0.4,videoAddress:state == .ready ? "https://cdn.example.com/result.mp4":nil,points:12.25,basicDurationMilliseconds:61250,errorCode:state == .expired ? 31001:nil)
            let changed=try BaiduVideoRules.applyQuery(response,to:original,observing:original,now:now)
            XCTAssertEqual(changed.videoGeneration?.phase,.collected);XCTAssertEqual(changed.outputAssetIDs,original.outputAssetIDs)
            XCTAssertEqual(changed.state,original.state);XCTAssertEqual(changed.progress,1);XCTAssertFalse(changed.billingUnknown)
            XCTAssertEqual(changed.actual,original.actual);XCTAssertEqual(changed.remoteID,original.remoteID);XCTAssertEqual(changed.requestKey,original.requestKey)
            XCTAssertEqual(changed.videoGeneration?.points,12.25);XCTAssertEqual(changed.videoGeneration?.basicDurationMilliseconds,61250)
            XCTAssertEqual(changed.videoGeneration?.querySequence,1);XCTAssertEqual(changed.remoteCheckedAt,now)
        }
    }
    private func input()->BaiduVideoInput {BaiduVideoInput(segments:[.init(text:"输入和输出共同占用上下文容量，请在真实界面对照复现并理解边界。"),.init(type:.image,url:"https://example.com/owned.png")])}
    private func fixture()throws->(Database,Workspace,Project,ProviderProfile,Quote) {
        var db=Database();let w=Workspace(name:"百度本地合同夹具",owner:"owner"),product=Product(workspaceID:w.id,sku:"course",name:"课程",checkout:"https://example.com/course",audience:"初学者",task:"理解上下文",outcome:"复现",prerequisite:"",scope:"输入输出",prices:[Price(money:Money(1),from:Date(timeIntervalSince1970:0),source:"产品页",verified:true)])
        let revision=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"知识",body:"解释")],cta:"复现"),project=Project(workspaceID:w.id,name:"项目",revision:revision),profile=BaiduVideoRules.profile(keyReference:"test-reference-only",allowsUpload:true)
        let details=EstimateBreakdown(version:BaiduVideoRules.version,specification:try BaiduVideoRules.specification(input:input()),source:"已核账号的报价出处（隔离合同测试，不实际下单）",validFrom:Date().addingTimeInterval(-60),expiresAt:Date().addingTimeInterval(600),lines:[RateLine(label:"一次请求测试上界",quantity:1,unit:"本次请求",price:Money(2),attempts:1)],excluded:["不把点数伪装成现金"]),quote=try details.quote(project:project,provider:profile.id,confirmed:true)
        db.workspaces=[w];db.products=[product];db.projects=[project];db.providers=[profile];return(db,w,project,profile,quote)
    }
    func testOfficialPayloadUsesRealNamesResolutionAndURLTypeWithoutInventedKey()throws {
        let data=try BaiduVideoRules.requestBody(input:input()),object=try XCTUnwrap(try JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(object.keys),["source","config"]);let source=try XCTUnwrap(object["source"] as? [String:Any]),segments=try XCTUnwrap(source["structs"] as? [[String:Any]])
        XCTAssertEqual(segments.count,2);XCTAssertEqual(segments[1]["type"] as? String,"image");XCTAssertEqual((segments[1]["mediaSource"] as? [String:Any])?["type"] as? Int,3)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("access_token"));XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("request_id"))
        var invalid=input();invalid.config.productType="timeline";XCTAssertThrowsError(try BaiduVideoRules.validate(input:invalid))
        invalid=input();invalid.config.resolution=[900,900];XCTAssertThrowsError(try BaiduVideoRules.validate(input:invalid))
        invalid=input();invalid.config.templateId="30";XCTAssertThrowsError(try BaiduVideoRules.validate(input:invalid))
        invalid=input();invalid.source.structs[0].text="太短";XCTAssertThrowsError(try BaiduVideoRules.validate(input:invalid))
    }
    func testStringIDIsNeverRecoveredFromRoundedNumericJobID()throws {
        let exact="1717153286267015037",data=Data(("{\"data\":{\"jobId\":1717153286267015037,\"id\":\""+exact+"\"},\"log_id\":1717153286267015037}").utf8)
        XCTAssertEqual(try BaiduVideoRules.createResponse(data),.accepted(exact))
        XCTAssertThrowsError(try BaiduVideoRules.createResponse(Data("{\"data\":{\"jobId\":1717153286267015037}}".utf8)))
        XCTAssertThrowsError(try BaiduVideoRules.createResponse(Data("{\"data\":{\"id\":1717153286267015037}}".utf8)))
        let query=try XCTUnwrap(try JSONSerialization.jsonObject(with:BaiduVideoRules.queryBody(remoteID:exact)) as? [String:Any]);XCTAssertEqual(query["jobId"] as? String,exact);XCTAssertEqual(query["includeTimeline"] as? Bool,false)
    }
    func testQueryOnlyMapsDocumentedFiniteStatesAndPreservesOriginalUnits()throws {
        let ready=try BaiduVideoRules.queryResponse(Data("{\"error_code\":0,\"data\":{\"statusCode\":\"1\",\"progress\":1,\"videoAddr\":\"https://cdn.example.com/result.mp4?expires=1\",\"points\":12.25,\"basicDuration\":61250,\"digitalHumanDuration\":0}}".utf8))
        XCTAssertEqual(ready.state,.ready);XCTAssertEqual(ready.points,Decimal(string:"12.25"));XCTAssertEqual(ready.basicDurationMilliseconds,61250)
        XCTAssertEqual(try BaiduVideoRules.queryResponse(Data("{\"error_code\":31001}".utf8)).state,.expired)
        XCTAssertEqual(try BaiduVideoRules.queryResponse(Data("{\"error_code\":0,\"data\":{\"statusCode\":\"999\",\"progress\":0.5}}".utf8)).state,.unknown)
        XCTAssertThrowsError(try BaiduVideoRules.queryResponse(Data("{\"error_code\":0,\"data\":{\"statusCode\":\"1\",\"progress\":1}}".utf8)))
        XCTAssertThrowsError(try BaiduVideoRules.queryResponse(Data("{\"error_code\":0,\"data\":{\"statusCode\":1,\"progress\":1}}".utf8)))
        XCTAssertEqual(try BaiduVideoRules.createResponse(Data("{\"error_code\":30901,\"error_msg\":\"vendor text is not echoed\"}".utf8)),.rejected(30901))
    }
    func testQuerySystemErrorsCannotBecomeTaskStatesOrExposeVendorText()throws {
        let privateText="vendor-private-token-and-address-must-not-be-echoed"
        for code in [1,2,4,6,15,17,18,19,100,110,111,282000,30901,999999] {
            // Even apparently complete task data cannot override a failed query.
            let object:[String:Any]=["error_code":code,"error_msg":privateText,"data":["statusCode":"1","progress":1,"videoAddr":"https://cdn.example.com/result.mp4","points":0]]
            let payload=try JSONSerialization.data(withJSONObject:object)
            XCTAssertThrowsError(try BaiduVideoRules.queryResponse(payload),"system code \(code)"){error in
                XCTAssertEqual((error as? VideoError)?.code,(code==110 || code==111) ? "permission_required":"unavailable")
                XCTAssertTrue(error.localizedDescription.contains("原状态、用量"))
                XCTAssertTrue(error.localizedDescription.contains("未重新提交"))
                XCTAssertFalse(error.localizedDescription.contains(privateText))
                XCTAssertFalse(error.localizedDescription.contains("cdn.example.com"))
            }
        }
        let expired=try BaiduVideoRules.queryResponse(Data("{\"error_code\":31001,\"error_msg\":\"vendor-private-token-and-address-must-not-be-echoed\"}".utf8))
        XCTAssertEqual(expired.state,.expired);XCTAssertEqual(expired.errorCode,31001)
    }
    func testSuccessfulQueryStillDistinguishesDocumentedTaskStatesFromSystemErrors()throws {
        let states:[(String,BaiduQueryResponse.State)]=[("0",.queued),("3",.running),("15",.failed),("30701",.failed),("30702",.failed),("30703",.failed),("282000",.failed),("30901",.failed),("31001",.expired),("999",.unknown)]
        for (status,expected) in states {
            let object:[String:Any]=["error_code":0,"data":["statusCode":status,"progress":0.6,"points":7.5,"basicDuration":12345,"digitalHumanDuration":42]]
            let payload=try JSONSerialization.data(withJSONObject:object)
            let response=try BaiduVideoRules.queryResponse(payload)
            XCTAssertEqual(response.state,expected,"task status \(status)")
            XCTAssertNil(response.errorCode);XCTAssertEqual(response.progress,0.6)
            XCTAssertEqual(response.points,Decimal(string:"7.5"));XCTAssertEqual(response.basicDurationMilliseconds,12345);XCTAssertEqual(response.digitalHumanDurationMilliseconds,42)
        }
    }
    func testSubmissionIntentIsStoredBeforeNetworkAndRepeatedUnknownRequestNeverSubmits()throws {
        var(db,w,project,profile,quote)=try fixture();let first=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"original",principal:"owner")
        XCTAssertTrue(first.shouldSubmit);XCTAssertEqual(first.job.state,.unknownRemote);XCTAssertEqual(first.job.videoGeneration?.phase,.submissionStarted);XCTAssertEqual(first.job.attempt,1);XCTAssertNil(first.job.remoteID);XCTAssertTrue(first.job.billingUnknown)
        let replay=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"original",principal:"owner")
        XCTAssertFalse(replay.shouldSubmit);XCTAssertEqual(replay.job.id,first.job.id);XCTAssertEqual(db.jobs.count,1)
        var changed=input();changed.config.withCaptions=false
        XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:changed,quote:quote,requestID:"original",principal:"owner"))
        XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"new-id-same-spent-quote",principal:"owner"))
        var replacement=quote;replacement.id=Codec.id()
        XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:replacement,requestID:"new-id-new-quote",principal:"owner"));XCTAssertEqual(db.jobs.count,1)
    }
    func testQuoteMustBindEntireInputAndScopeUploadAndOneAttempt()throws {
        var(db,w,project,profile,quote)=try fixture();var changed=input();changed.config.withVoiceBroadcast=false
        XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:changed,quote:quote,requestID:"changed",principal:"owner"))
        XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"not-owner",principal:"collaborator"))
        var denied=profile;denied.allowsUpload=false;XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:denied,input:input(),quote:quote,requestID:"upload-denied",principal:"owner"))
        var retry=quote;retry.attempts=2;XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:retry,requestID:"retries",principal:"owner"));XCTAssertTrue(db.jobs.isEmpty)
        XCTAssertThrowsError(try BaiduVideoRules.safeHTTPS("https://127.0.0.1/private.mp4"));XCTAssertThrowsError(try BaiduVideoRules.safeHTTPS("https://public.example.com/file.png?access_token=not-a-real-token"));XCTAssertThrowsError(try BaiduVideoRules.safeHTTPS("https://name:pass@example.com/a.png"))
    }
    func testReadyRemoteRemainsBillingPendingAndCannotMasqueradeAsFinalDelivery()throws {
        var(db,w,project,profile,quote)=try fixture();let prepared=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"one",principal:"owner")
        let accepted=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:prepared.job)
        let ready=try BaiduVideoRules.applyQuery(BaiduQueryResponse(state:.ready,progress:1,videoAddress:"https://cdn.example.com/a.mp4",points:12,basicDurationMilliseconds:60000),to:accepted)
        XCTAssertEqual(ready.state,.billingPending);XCTAssertTrue(ready.billingUnknown);XCTAssertNil(ready.actual);XCTAssertEqual(ready.quote.upper.amount,2);XCTAssertTrue(ready.artifacts.isEmpty);XCTAssertNil(ready.outputAssetIDs)
        XCTAssertEqual(ready.videoGeneration?.points,12);XCTAssertEqual(ready.remoteID,accepted.remoteID);XCTAssertEqual(ready.requestKey,"one")
        var fake=profile;fake.idempotency=true;XCTAssertThrowsError(try BaiduVideoRules.validate(profile:fake));fake=profile;fake.cancelPath="/made-up-cancel";XCTAssertThrowsError(try BaiduVideoRules.validate(profile:fake))
    }
    func testGeneratedSourceChangesInvalidateFrozenApprovalEvenWithSameFileHash()throws {
        var(db,w,project,profile,quote)=try fixture();let job=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"provenance",principal:"owner").job
        var asset=Asset(workspaceID:w.id,name:"generated.mp4",hash:String(repeating:"a",count:64),ext:"mp4",bytes:100,mediaType:"video",durationFrames:180)
        asset.generatedSource=GeneratedAssetSource(job:job,receipt:VideoGenerationReceipt(inputDigest:String(repeating:"b",count:64)),at:Date(timeIntervalSince1970:1000))
        var revision=project.current;revision.scenes[0].assetID=asset.id;revision.scenes[0].durationFrames=60;revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[])
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[]).isEmpty)
        let fields:[WritableKeyPath<GeneratedAssetSource,String>]=[\.sourceJobID,\.providerID,\.model,\.promptDigest,\.contractVersion]
        for field in fields {var changed=asset;var source=try XCTUnwrap(changed.generatedSource);source[keyPath:field]+="-changed";changed.generatedSource=source;XCTAssertEqual(changed.hash,asset.hash);XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[changed],evidence:[]).contains{$0.reason == .changed})}
        var onlyTags=asset;onlyTags.tags=["查找用标签"];XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[onlyTags],evidence:[]).isEmpty)
    }
    func testLocalCancelCannotPretendOfficialBaiduCancellationOrEraseFeesAndID()throws {
        var(db,w,project,profile,quote)=try fixture();let pending=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"cancel",principal:"owner").job
        var original=try BaiduVideoRules.applyCreated(.accepted("1717153286267015037"),to:pending);original.state = .running;original.actual=Money(1);original.billingUnknown=true
        let result=JobRules.cancel(original)
        XCTAssertEqual(result.state,original.state);XCTAssertEqual(result.remoteID,original.remoteID);XCTAssertEqual(result.requestKey,original.requestKey);XCTAssertEqual(result.quote.upper,original.quote.upper);XCTAssertEqual(result.actual,original.actual);XCTAssertEqual(result.billingUnknown,original.billingUnknown);XCTAssertTrue(result.message.contains("未"));XCTAssertFalse(result.message.contains("须查询远端取消结果"))
    }
    func testLiveUntransmittedCancellationKeepsOriginalIntentAndReleasesOnlyReservation()throws {
        var(db,w,project,profile,quote)=try fixture()
        let prepared=try BaiduVideoRules.prepareForSubmission(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"live-not-transmitted",principal:"owner"),original=prepared.job,permit=try XCTUnwrap(prepared.permit)
        let stopped=try BaiduVideoRules.notSubmitted(original,permit:permit,wasCancelled:true)
        XCTAssertEqual(stopped.state,.cancelled);XCTAssertEqual(stopped.actual,Money(0,quote.upper.currency));XCTAssertEqual(stopped.exposure,Money(0,quote.upper.currency));XCTAssertFalse(stopped.billingUnknown)
        XCTAssertEqual(stopped.id,original.id);XCTAssertEqual(stopped.requestKey,original.requestKey);XCTAssertEqual(stopped.revisionID,original.revisionID);XCTAssertEqual(stopped.digest,original.digest)
        XCTAssertEqual(try Codec.digest(stopped.quote),try Codec.digest(original.quote));XCTAssertEqual(stopped.videoGeneration?.inputDigest,original.videoGeneration?.inputDigest);XCTAssertEqual(stopped.videoGeneration?.startedAt,original.videoGeneration?.startedAt)
        XCTAssertEqual(stopped.videoGeneration?.phase,.failed);XCTAssertNil(stopped.remoteID);XCTAssertNil(stopped.refundPending);XCTAssertTrue((stopped.billing ?? []).isEmpty);XCTAssertTrue(stopped.message.contains("不是远端取消或退款"))
        XCTAssertThrowsError(try BaiduVideoRules.notSubmitted(original,permit:permit,wasCancelled:true));XCTAssertThrowsError(try permit.markTransmissionStarted())
    }
    func testLiveUntransmittedLocalFailureIsFailedAndCannotAutomaticallyReuseQuote()throws {
        var(db,w,project,profile,quote)=try fixture()
        let prepared=try BaiduVideoRules.prepareForSubmission(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"local-setup-failure",principal:"owner"),original=prepared.job,permit=try XCTUnwrap(prepared.permit)
        db.jobs[0]=try BaiduVideoRules.notSubmitted(original,permit:permit,wasCancelled:false)
        XCTAssertEqual(db.jobs[0].state,.failed);XCTAssertEqual(db.jobs[0].actual,Money(0));XCTAssertFalse(db.jobs[0].billingUnknown);XCTAssertTrue(db.jobs[0].message.contains("前失败"))
        let replay=try BaiduVideoRules.prepareForSubmission(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:original.requestKey,principal:"owner")
        XCTAssertFalse(replay.shouldSubmit);XCTAssertNil(replay.permit);XCTAssertEqual(replay.job.id,original.id);XCTAssertEqual(db.jobs.count,1)
        XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"reuse-old-quote",principal:"owner"))
        var confirmedAgain=quote;confirmedAgain.id=Codec.id()
        let explicit=try BaiduVideoRules.prepareForSubmission(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:confirmedAgain,requestID:"explicit-new-intent",principal:"owner")
        XCTAssertTrue(explicit.shouldSubmit);XCTAssertNotNil(explicit.permit);XCTAssertNotEqual(explicit.job.id,original.id);XCTAssertEqual(db.jobs.count,2);XCTAssertNil(explicit.job.actual)
    }
    func testUntransmittedRuleRejectsRemoteBillingUsageAndChangedLifecycle()throws {
        var(db,w,project,profile,quote)=try fixture()
        let prepared=try BaiduVideoRules.prepareForSubmission(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"guard-local-proof",principal:"owner"),original=prepared.job,permit=try XCTUnwrap(prepared.permit)
        let mutations:[(inout Job)->Void]=[
            {$0.state = .running},{$0.videoGeneration?.phase = .unknown},{$0.videoGeneration?.phase = .accepted},
            {$0.remoteID="1717153286267015037"},{$0.remoteCheckedAt=Date()},{$0.progress=0.1},
            {$0.actual=Money(0)},{$0.remoteReportedActual=Money(2)},{$0.refundPending=Money(1)},
            {$0.billing=[BillingRecord(id:"local-rule-charge",kind:.charge,money:Money(1),source:"隔离账单规则")]},
            {$0.artifacts=[Artifact(path:"local-rule-output",mime:"video/mp4",bytes:1,sha256:String(repeating:"a",count:64),revision:$0.revisionID)]},
            {$0.outputAssetIDs=["existing-source"]},{$0.lease=WorkerLease(owner:"other",token:"other",heartbeat:Date(),expiresAt:Date().addingTimeInterval(60))},
            {$0.videoGeneration?.acceptedAt=Date()},{$0.videoGeneration?.checkedAt=Date()},{$0.videoGeneration?.points=0},
            {$0.videoGeneration?.basicDurationMilliseconds=0},{$0.videoGeneration?.digitalHumanDurationMilliseconds=0},
            {$0.videoGeneration?.collectionToken="collector"},{$0.videoGeneration?.collectionExpiresAt=Date()},
            {$0.videoGeneration?.contractVersion="other-contract"},{$0.videoGeneration?.model="other-model"},{$0.attempt=2}
        ]
        for (index,mutation) in mutations.enumerated() {
            var changed=original;mutation(&changed);let before=try Codec.digest(changed)
            XCTAssertThrowsError(try BaiduVideoRules.notSubmitted(changed,permit:permit,wasCancelled:true),"guard \(index)")
            XCTAssertEqual(try Codec.digest(changed),before)
        }
        var other=original;other.requestKey="another-original"
        XCTAssertThrowsError(try BaiduVideoRules.notSubmitted(other,permit:permit,wasCancelled:true))
        try permit.markTransmissionStarted();XCTAssertTrue(permit.transmissionStarted)
        XCTAssertThrowsError(try BaiduVideoRules.notSubmitted(original,permit:permit,wasCancelled:true))
        try permit.markTransmissionStarted();XCTAssertTrue(permit.transmissionStarted)
    }
    func testRecoveredUnknownReceiptCannotBeInferredUnsentOrPaidAgain()throws {
        var(db,w,project,profile,quote)=try fixture()
        var original=try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"lost-response",principal:"owner").job
        let oldIntent=try BaiduVideoRules.prepareForSubmission(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"lost-response",principal:"owner")
        XCTAssertFalse(oldIntent.shouldSubmit);XCTAssertNil(oldIntent.permit);XCTAssertEqual(oldIntent.job.videoGeneration?.phase,.submissionStarted)
        original.videoGeneration?.phase = .unknown
        let recovered=try Codec.decoder().decode(Job.self,from:Codec.data(original));db.jobs=[recovered]
        let replay=try BaiduVideoRules.prepareForSubmission(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:quote,requestID:"lost-response",principal:"owner")
        XCTAssertFalse(replay.shouldSubmit);XCTAssertNil(replay.permit);XCTAssertEqual(replay.job.state,.unknownRemote);XCTAssertTrue(replay.job.billingUnknown);XCTAssertEqual(replay.job.exposure,quote.upper)
        var replacement=quote;replacement.id=Codec.id()
        XCTAssertThrowsError(try BaiduVideoRules.prepare(database:&db,workspaceID:w.id,projectID:project.id,profile:profile,input:input(),quote:replacement,requestID:"cannot-guess-unsent",principal:"owner"));XCTAssertEqual(db.jobs.count,1)
    }
}
