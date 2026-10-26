import XCTest
@testable import VideoCore

final class SpeechProjectRulesTests: XCTestCase {
    private func fixture() throws -> (Database, SpeechProjectRequest) {
        let w=Workspace(name:"中文本地课堂",owner:"owner")
        var s=Scene(title:"公共品",body:"规则演示",narration:"两位居民共同修桥。贡献有成本，收益由两人共享。",durationFrames:30)
        var layer=SceneLayer(kind:.text,text:"每人贡献有成本",endFrame:30);layer.locked=true;s.layers=[layer]
        let p=Project(workspaceID:w.id,name:"公共品",revision:Revision(contentContext:.init(workspaceID:w.id,name:"公共品"),aspect:.landscape,scenes:[s]))
        var d=Database();d.workspaces=[w];d.projects=[p]
        var plan=try ChineseSpeech.normalize(s.narration);plan.voiceIdentifier="installed.zh.fixture";plan.confirmed=true
        return (d,SpeechProjectRequest(workspaceID:w.id,projectID:p.id,sceneID:s.id,baseRevision:p.current.id,plan:plan,requestID:"confirmed-input-1"))
    }
    private func production(_ q: SpeechProjectRequest, frames: Int) throws -> (Asset,Evidence,VoiceTake,[Caption]) {
        var a=Asset(workspaceID:q.workspaceID,name:"actual.caf",hash:String(repeating:"a",count:64),ext:"caf",bytes:128,mediaType:"audio",durationFrames:frames)
        let e=Evidence(workspaceID:q.workspaceID,title:"声音使用范围待核",source:"local system",claim:"未验证",owner:"系统声音",commercialAllowed:false,uploadConsent:false,verified:false,assetID:a.id);a.evidenceID=e.id
        var s=Scene(title:"source",body:"",narration:q.plan.source);s.speechPlan=q.plan
        return(a,e,VoiceTake(assetID:a.id,textDigest:try SpeechRules.digest(s),durationFrames:frames,method:"local_system_speech:"+q.plan.voiceIdentifier!,listened:false),try SpeechRules.captions(q.plan,durationFrames:frames))
    }
    func testDiscoveryAndStrictBoundedDTO() throws {
        let (_,q)=try fixture();let encoded=try Codec.data(q)
        XCTAssertEqual(try AgentContract.describe("speech synthesize").permission,.projectWrite)
        XCTAssertFalse(try AgentContract.describe("speech synthesize").network)
        _=try AgentContract.validate(command:"speech synthesize",data:encoded)
        var value=try XCTUnwrap(Codec.decoder().decode(AgentValue.self,from:encoded).object)
        value["extend_scene"] = .string("true");XCTAssertThrowsError(try AgentContract.validate(command:"speech synthesize",data:Codec.data(AgentValue.object(value))))
        value["extend_scene"] = .boolean(true);value["timeout_seconds"] = .number(901)
        XCTAssertThrowsError(try AgentContract.validate(command:"speech synthesize",data:Codec.data(AgentValue.object(value))))
        XCTAssertThrowsError(try AgentContract.validate(command:"speech voices",data:Data("{\"path\":\"/tmp\"}".utf8)))
        XCTAssertNotNil(try AgentContract.inputSchema("speech synthesize").object?["$defs"]?.object?["SpeechPlan"])
    }
    func testConfirmationExactSourceAndVersionAreRequiredWithoutMutation() throws {
        let (d,q)=try fixture();let before=try Codec.digest(d)
        _=try SpeechProjectRules.prepare(q,database:d,principal:"owner")
        _=try AgentPreview.evaluate(command:"speech synthesize",data:Codec.data(q),database:d,principal:"owner")
        var bad=q;bad.plan.confirmed=false;XCTAssertThrowsError(try SpeechProjectRules.prepare(bad,database:d,principal:"owner"))
        bad=q;bad.plan=try ChineseSpeech.normalize("完全不同的原文");bad.plan.voiceIdentifier=q.plan.voiceIdentifier;bad.plan.confirmed=true
        XCTAssertThrowsError(try SpeechProjectRules.prepare(bad,database:d,principal:"owner"))
        bad=q;bad.baseRevision="stale";XCTAssertThrowsError(try SpeechProjectRules.prepare(bad,database:d,principal:"owner"))
        XCTAssertEqual(before,try Codec.digest(d))
    }
    func testScopedWriterReviewerRevocationAndExpiry() throws {
        var (d,q)=try fixture()
        d.workspaces[0].grants=[Grant(principal:"writer",role:.collaborator,projectIDs:[q.projectID],revisionIDs:[q.baseRevision],expiresAt:Date().addingTimeInterval(300))]
        _=try SpeechProjectRules.prepare(q,database:d,principal:"writer")
        d.workspaces[0].grants[0].role = .reviewer;XCTAssertThrowsError(try SpeechProjectRules.prepare(q,database:d,principal:"writer"))
        d.workspaces[0].grants[0].role = .collaborator;d.workspaces[0].grants[0].revoked=true;XCTAssertThrowsError(try SpeechProjectRules.prepare(q,database:d,principal:"writer"))
        d.workspaces[0].grants[0].revoked=false;d.workspaces[0].grants[0].expiresAt=Date().addingTimeInterval(-1);XCTAssertThrowsError(try SpeechProjectRules.prepare(q,database:d,principal:"writer"))
        XCTAssertThrowsError(try SpeechProjectRules.prepare(q,database:d,principal:"unknown"))
    }
    func testLockedSceneAndArchivedProjectFailBeforeSynthesis() throws {
        var (d,q)=try fixture();d.projects[0].revisions[0].scenes[0].locked=true
        XCTAssertThrowsError(try SpeechProjectRules.prepare(q,database:d,principal:"owner"))
        d.projects[0].revisions[0].scenes[0].locked=false;d.projects[0].archived=true
        XCTAssertThrowsError(try SpeechProjectRules.prepare(q,database:d,principal:"owner"))
    }
    func testLongSpeechIsRejectedAtomicallyWithoutExplicitExtension() throws {
        var (d,q)=try fixture();let (a,e,t,c)=try production(q,frames:241);let before=try Codec.digest(d)
        XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:e,take:t,captions:c,database:&d,principal:"owner"))
        XCTAssertEqual(before,try Codec.digest(d));XCTAssertTrue(d.assets.isEmpty);XCTAssertTrue(d.evidence.isEmpty)
    }
    func testCompleteSourceIsBoundToNewUnreviewedRevisionAndLockedLayersStayExact() throws {
        var (d,q)=try fixture();q.extendScene=true
        let original=d.projects[0].current.scenes[0];let (a,e,t,c)=try production(q,frames:241)
        let changed=try SpeechProjectRules.apply(q,asset:a,evidence:e,take:t,captions:c,database:&d,principal:"owner")
        let s=changed.current.scenes[0]
        XCTAssertEqual(changed.revisions.count,2);XCTAssertEqual(changed.revisions[0].scenes[0],original)
        XCTAssertEqual(s.durationFrames,241);XCTAssertEqual(s.voice?.durationFrames,241);XCTAssertEqual(s.captions.last?.endFrame,241)
        XCTAssertEqual(s.layers,original.layers);XCTAssertFalse(s.voice!.listened);XCTAssertTrue(s.captions.allSatisfy{!$0.confirmed})
        XCTAssertFalse(changed.current.review.complete);XCTAssertFalse(changed.current.review.sound);XCTAssertNotNil(changed.current.dependencies)
        XCTAssertFalse(d.evidence[0].verified);XCTAssertFalse(d.evidence[0].commercialAllowed);XCTAssertFalse(d.evidence[0].uploadConsent)
    }
    func testForgedListeningRightsAndMismatchedSourceAreRejected() throws {
        var (d,q)=try fixture();q.extendScene=true;let (a,e,t,c)=try production(q,frames:90);let before=try Codec.digest(d)
        var listened=t;listened.listened=true;XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:e,take:listened,captions:c,database:&d,principal:"owner"))
        var rights=e;rights.verified=true;XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:rights,take:t,captions:c,database:&d,principal:"owner"))
        var other=t;other.textDigest="wrong";XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:e,take:other,captions:c,database:&d,principal:"owner"))
        XCTAssertEqual(before,try Codec.digest(d))
    }
    func testDedicatedAttachRejectsShortenedOrExtendedTakeWithoutCommittingMetadata() throws {
        var (d,q)=try fixture();q.extendScene=true
        let (asset,evidence,take,captions)=try production(q,frames:90)
        let before=try Codec.data(d)
        for frames in [0,89,91] {
            var incomplete=take;incomplete.durationFrames=frames
            XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:asset,evidence:evidence,take:incomplete,captions:captions,database:&d,principal:"owner")) { error in
                XCTAssertEqual((error as? VideoError)?.code,"needs_review")
            }
            XCTAssertEqual(try Codec.data(d),before)
        }
    }
    func testPostGenerationStaleRevisionAndRevokedWriterCannotCommit() throws {
        var (d,q)=try fixture();q.extendScene=true;let (a,e,t,c)=try production(q,frames:90)
        d.workspaces[0].grants=[Grant(principal:"writer",role:.collaborator,projectIDs:[q.projectID],revisionIDs:[q.baseRevision],expiresAt:Date().addingTimeInterval(300))]
        _=try SpeechProjectRules.prepare(q,database:d,principal:"writer")
        d.workspaces[0].grants[0].revoked=true;let revoked=try Codec.digest(d)
        XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:e,take:t,captions:c,database:&d,principal:"writer"));XCTAssertEqual(revoked,try Codec.digest(d))
        d.projects[0]=try Editor.apply([.cta("new")],to:d.projects[0],baseRevision:q.baseRevision,assets:[],message:"other edit")
        let stale=try Codec.digest(d)
        XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:e,take:t,captions:c,database:&d,principal:"owner"));XCTAssertEqual(stale,try Codec.digest(d))
    }
    func testIdempotencyBindsPrincipalExactPlanAndRequest() throws {
        let (_,q)=try fixture();let data=try AgentMutationExecutor.canonicalInput(command:SpeechProjectRules.command,data:Codec.data(q),principal:"owner",requestID:q.requestID)
        let record=AgentReplayRecord(requestID:q.requestID,command:SpeechProjectRules.command,fingerprint:try AgentContract.fingerprint(command:SpeechProjectRules.command,data:data),response:.string("original"))
        XCTAssertEqual(try AgentContract.replay(command:SpeechProjectRules.command,data:data,records:[record]),.replay(.string("original")))
        let different=try AgentMutationExecutor.canonicalInput(command:SpeechProjectRules.command,data:Codec.data(q),principal:"writer",requestID:q.requestID)
        XCTAssertThrowsError(try AgentContract.replay(command:SpeechProjectRules.command,data:different,records:[record]))
        var changed=q;changed.plan.rate=0.4
        XCTAssertThrowsError(try AgentContract.replay(command:SpeechProjectRules.command,data:AgentMutationExecutor.canonicalInput(command:SpeechProjectRules.command,data:Codec.data(changed),principal:"owner",requestID:q.requestID),records:[record]))
    }

    func testImportedPlanAllowsNoSystemVoiceButRequiresSpecificVerifiedSource() throws {
        var (d,q)=try fixture();q.extendScene=true;q.plan.voiceIdentifier=nil
        let (original,rights,_,_)=try productionForImport(q,frames:90)
        q.assetID=original.id;d.assets=[original];d.evidence=[rights]
        let (_,_,take,captions)=try productionForImport(q,frames:90,asset:original,evidence:rights)
        let saved=try SpeechProjectRules.apply(q,asset:original,evidence:rights,take:take,captions:captions,database:&d,principal:"owner")
        XCTAssertEqual(d.assets.count,1);XCTAssertEqual(d.evidence.count,1);XCTAssertEqual(saved.current.scenes[0].voice?.method,"imported-recording")
        XCTAssertFalse(saved.current.scenes[0].voice!.listened);XCTAssertNil(saved.current.scenes[0].speechPlan?.voiceIdentifier)
    }
    private func productionForImport(_ q: SpeechProjectRequest, frames:Int, asset:Asset?=nil,evidence:Evidence?=nil) throws -> (Asset,Evidence,VoiceTake,[Caption]) {
        var a=asset ?? Asset(workspaceID:q.workspaceID,name:"authored.wav",hash:String(repeating:"b",count:64),ext:"wav",bytes:128,mediaType:"audio",durationFrames:frames)
        let e=evidence ?? Evidence(workspaceID:q.workspaceID,title:"规则夹具适用权利",source:"test authored tone",claim:"fixture",owner:"test",commercialAllowed:false,uploadConsent:false,verified:true,assetID:a.id);a.evidenceID=e.id
        var scene=Scene(title:"source",body:"",narration:q.plan.source);scene.speechPlan=q.plan
        return(a,e,VoiceTake(assetID:a.id,textDigest:try scene.speechDigest(),durationFrames:frames,method:"imported-recording",listened:false),try SpeechRules.captions(q.plan,durationFrames:frames))
    }
    func testImportedPermissionAndCASMetadataCannotBeSubstituted() throws {
        var (d,q)=try fixture();q.extendScene=true;q.plan.voiceIdentifier=nil
        let(a,e,t,c)=try productionForImport(q,frames:90);q.assetID=a.id;d.assets=[a];d.evidence=[e]
        d.evidence[0].verified=false;let original=try Codec.digest(d)
        XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:e,take:t,captions:c,database:&d,principal:"owner"));XCTAssertEqual(original,try Codec.digest(d))
        d.evidence=[e];d.assets[0].hash=String(repeating:"c",count:64)
        XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:e,take:t,captions:c,database:&d,principal:"owner"))
        d.assets=[a];d.projects[0].revisions[0].purpose = .course
        XCTAssertThrowsError(try SpeechProjectRules.apply(q,asset:a,evidence:e,take:t,captions:c,database:&d,principal:"owner"))
    }
}
