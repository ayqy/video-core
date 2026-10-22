import XCTest
@testable import VideoCore

final class BaiduVideoRulesTests:XCTestCase {
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
}
