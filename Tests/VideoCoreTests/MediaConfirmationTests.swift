import Foundation
import XCTest
@testable import VideoCore

final class MediaConfirmationTests:XCTestCase {
    private func fixture() throws -> (Repository,String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-confirmation-rules-"+UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root)
        var workspace=Workspace(name:"独立确认规则",owner:"rules-owner");workspace.id="w"
        let asset=try repository.ingest(Data("isolated complete audio fixture".utf8),name:"rule.wav",workspaceID:"w",mediaType:"audio",durationFrames:60)
        var scene=Scene(title:"留下硬币",body:"一个人留下一枚硬币。",durationFrames:60)
        scene.narration="留下一枚。"
        scene.voice=VoiceTake(assetID:asset.id,textDigest:try scene.speechDigest(),durationFrames:60,method:"isolated-rule-recording")
        scene.captions=[Caption(text:"留下一枚。",startFrame:0,endFrame:60)]
        var revision=try Planner.create(workspaceID:"w",name:"独立声音字幕确认",scenes:[scene],assets:[asset])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[])
        let project=Project(workspaceID:"w",name:"独立确认规则",revision:revision)
        let quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(3600),confirmed:true)
        var job=Job(workspaceID:"w",projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),requestKey:"isolated-existing-job",quote:quote)
        job.state = .needsReview
        try repository.transaction {db in db.workspaces=[workspace];db.assets=[asset];db.projects=[project];db.jobs=[job]}
        return(repository,project.id)
    }

    private func request(_ repository:Repository,_ projectID:String,voice:Bool=true,captions:Bool=false,
                         method:MediaConfirmationMethod = .approvedOriginal) throws -> MediaConfirmationRequest {
        let database=try repository.read(),revision=try database.project(projectID).current
        return MediaConfirmationRequest(voice:voice,captions:captions,method:method,
            statement:"隔离规则中的明确人工声明，不代表真实业务素材已经听审。",
            expected:try MediaConfirmationRules.binding(revision:revision,scene:revision.scenes[0],database:database))
    }

    @discardableResult private func confirm(_ repository:Repository,_ projectID:String,_ request:MediaConfirmationRequest,
                                            requestID:String=UUID().uuidString) throws -> MediaConfirmation {
        let project=try repository.read().project(projectID)
        return try repository.recordMediaConfirmation(workspaceID:"w",projectID:projectID,revisionID:project.current.id,
            sceneID:project.current.scenes[0].id,confirmation:request,principal:"rules-owner",requestID:requestID)
    }

    func testSourceApprovalKeepsContentJobsAndFiveReviewsUnchanged() throws {
        let (repository,id)=try fixture(),before=try repository.read(),revision=try before.project(id).current
        let original=try revision.contentDigest()
        let record=try confirm(repository,id,request(repository,id))
        let after=try repository.read(),current=try after.project(id).current
        XCTAssertEqual(try Codec.data(before.projects),try Codec.data(after.projects))
        XCTAssertEqual(try Codec.data(before.jobs),try Codec.data(after.jobs))
        XCTAssertEqual(try Codec.data(before.assets),try Codec.data(after.assets))
        XCTAssertEqual(try current.contentDigest(),original)
        XCTAssertEqual(current.scenes[0].voice?.listened,false)
        XCTAssertTrue(current.scenes[0].captions.allSatisfy{!$0.confirmed})
        XCTAssertFalse(current.review.text || current.review.rights || current.review.fullPreview || current.review.sound || current.review.captions)
        XCTAssertTrue(record.voice);XCTAssertFalse(record.captions)
        let status=try MediaConfirmationRules.status(revision:current,scene:current.scenes[0],database:after)
        XCTAssertTrue(status.voice);XCTAssertFalse(status.captions)
        let issues=try Quality.inspect(current,database:after,requireReview:true)
        XCTAssertFalse(issues.contains{$0.id==current.scenes[0].id+"listened"})
        XCTAssertTrue(issues.contains{$0.id==current.scenes[0].id+"captions"})
        XCTAssertTrue(issues.contains{$0.id=="review"})
    }

    func testCaptionConfirmationIsIndependentFromVoiceAndWholeFilmReview() throws {
        let (repository,id)=try fixture()
        try confirm(repository,id,request(repository,id,voice:false,captions:true,method:.manual))
        let database=try repository.read(),revision=try database.project(id).current
        let status=try MediaConfirmationRules.status(revision:revision,scene:revision.scenes[0],database:database)
        XCTAssertFalse(status.voice);XCTAssertTrue(status.captions)
        let issues=try Quality.inspect(revision,database:database,requireReview:true)
        XCTAssertTrue(issues.contains{$0.id==revision.scenes[0].id+"listened"})
        XCTAssertFalse(issues.contains{$0.id==revision.scenes[0].id+"captions"})
        XCTAssertTrue(issues.contains{$0.id=="review"})
        XCTAssertEqual(database.jobs[0].state,.needsReview)
    }

    func testBothLocalConfirmationsStillRequireAnActualCompletePreviewAndFiveReviews() throws {
        let (repository,id)=try fixture()
        try confirm(repository,id,request(repository,id,voice:true,captions:true,method:.manual))
        let before=try repository.read(),revision=try before.project(id).current
        let issues=try Quality.inspect(revision,database:before,requireReview:true)
        XCTAssertFalse(issues.contains{$0.id==revision.scenes[0].id+"listened" || $0.id==revision.scenes[0].id+"captions"})
        XCTAssertTrue(issues.contains{$0.id=="review"})
        var review=Review();review.text=true;review.rights=true;review.fullPreview=true;review.sound=true;review.captions=true
        let value:AgentValue = .object(["workspace_id":.string("w"),"project_id":.string(id),"base_revision":.string(revision.id),
            "review":try Codec.decoder().decode(AgentValue.self,from:Codec.data(review)),"request_id":.string("cannot-approve-without-preview")])
        XCTAssertThrowsError(try repository.performAgentMutation(command:"review record",data:Codec.data(value),principal:"rules-owner",requestID:"cannot-approve-without-preview"))
        XCTAssertEqual(try Codec.data(repository.read()),try Codec.data(before))
        XCTAssertEqual(try repository.read().jobs[0].state,.needsReview)
    }

    func testChangedExpectedDigestVoiceSourceTextDurationOrCaptionTimingRejectsAtomically() throws {
        let (repository,id)=try fixture(),before=try Codec.data(repository.read())
        for field in ["revision","source","asset","text","duration","method","captions"] {
            var input=try request(repository,id)
            switch field {
            case "revision":input.expected.contentDigest=String(repeating:"0",count:64)
            case "source":input.expected.voice?.sha256=String(repeating:"0",count:64)
            case "asset":input.expected.voice?.assetID="different-asset"
            case "text":input.expected.voice?.textDigest=String(repeating:"0",count:64)
            case "duration":input.expected.voice?.durationFrames=59
            case "method":input.expected.voice?.method="another-recording"
            default:input.expected.captionsDigest=String(repeating:"0",count:64)
            }
            XCTAssertThrowsError(try confirm(repository,id,input),field)
            XCTAssertEqual(try Codec.data(repository.read()),before,field)
        }
    }

    func testWrongWorkspacePrincipalAndStaleRevisionCannotRecordConfirmation() throws {
        let (repository,id)=try fixture(),input=try request(repository,id),project=try repository.read().project(id)
        let before=try Codec.data(repository.read())
        for (workspace,principal,revision) in [("w","uninvited",project.current.id),("missing","rules-owner",project.current.id),("w","rules-owner","stale-revision")] {
            XCTAssertThrowsError(try repository.recordMediaConfirmation(workspaceID:workspace,projectID:id,revisionID:revision,
                sceneID:project.current.scenes[0].id,confirmation:input,principal:principal,requestID:UUID().uuidString))
            XCTAssertEqual(try Codec.data(repository.read()),before)
        }
    }

    func testPhysicalSourceBytesMustStillMatchBeforeTheAtomicWrite() throws {
        let (repository,id)=try fixture(),input=try request(repository,id),before=try repository.read()
        let asset=before.assets[0]
        try Data("changed actual original bytes".utf8).write(to:repository.assetURL(asset))
        XCTAssertThrowsError(try confirm(repository,id,input))
        XCTAssertEqual(try Codec.data(repository.read()),try Codec.data(before))
    }

    func testPhysicalSourceFileSymlinkParentSymlinkAndHardlinkAreRejected() throws {
        for kind in ["file-symlink","parent-symlink","hardlink"] {
            let (repository,id)=try fixture(),input=try request(repository,id),before=try repository.read()
            let source=repository.assetURL(before.assets[0])
            if kind=="parent-symlink" {
                let assets=source.deletingLastPathComponent(),saved=repository.root.appendingPathComponent("original-assets")
                try FileManager.default.moveItem(at:assets,to:saved)
                try FileManager.default.createSymbolicLink(at:assets,withDestinationURL:saved)
            } else {
                let saved=repository.root.appendingPathComponent("original-audio.wav")
                try FileManager.default.moveItem(at:source,to:saved)
                if kind=="file-symlink" {try FileManager.default.createSymbolicLink(at:source,withDestinationURL:saved)}
                else {try FileManager.default.linkItem(at:saved,to:source)}
            }
            XCTAssertThrowsError(try confirm(repository,id,input),kind)
            XCTAssertEqual(try Codec.data(repository.read()),try Codec.data(before),kind)
        }
    }

    func testOriginalApprovalCannotConfirmCaptionsAndEstimatedTimingCannotClaimReliableTimestamps() throws {
        let (repository,id)=try fixture()
        XCTAssertThrowsError(try confirm(repository,id,request(repository,id,voice:true,captions:true)))
        XCTAssertThrowsError(try confirm(repository,id,request(repository,id,voice:true,captions:false,method:.reliableTimestamps)))
        try repository.transaction {db in db.projects[0].revisions[0].scenes[0].captions[0].alignment="estimated_sentence_no_word_timestamps"}
        let before=try Codec.data(repository.read())
        XCTAssertThrowsError(try confirm(repository,id,request(repository,id,voice:false,captions:true,method:.reliableTimestamps)))
        XCTAssertEqual(try Codec.data(repository.read()),before)
    }

    func testRequestReplayIsIdempotentAndChangedClaimCannotReuseTheRequestID() throws {
        let (repository,id)=try fixture(),input=try request(repository,id)
        let first=try confirm(repository,id,input,requestID:"confirmation-replay")
        let replay=try confirm(repository,id,input,requestID:"confirmation-replay")
        XCTAssertEqual(first,replay)
        XCTAssertEqual(try repository.read().mediaConfirmations?.count,1)
        var different=input;different.statement="同一个请求不能改成另一份声明。"
        XCTAssertThrowsError(try confirm(repository,id,different,requestID:"confirmation-replay"))
        XCTAssertEqual(try repository.read().mediaConfirmations?.count,1)
    }

    func testNewRevisionNeverInheritsTheOldConfirmationEvenWithTheSameVoice() throws {
        let (repository,id)=try fixture()
        try confirm(repository,id,request(repository,id))
        try repository.transaction {db in
            let project=try db.project(id)
            var scene=project.current.scenes[0];scene.body="当前版本的画面说明已改变。"
            db.projects[0]=try Editor.apply([.replaceScene(scene.id,scene)],to:project,baseRevision:project.current.id,assets:db.assets,message:"规则中的实际内容编辑")
        }
        let database=try repository.read(),project=try database.project(id)
        XCTAssertEqual(database.mediaConfirmations?.count,1)
        XCTAssertTrue(try MediaConfirmationRules.status(revision:project.revisions[0],scene:project.revisions[0].scenes[0],database:database).voice)
        let status=try MediaConfirmationRules.status(revision:project.current,scene:project.current.scenes[0],database:database)
        XCTAssertFalse(status.voice);XCTAssertFalse(status.captions)
    }

    func testChangedSourceMetadataAndMissingHistoricalReferencesOnlyInvalidateLookup() throws {
        let (repository,id)=try fixture()
        try confirm(repository,id,request(repository,id))
        let original=try repository.read(),revision=try original.project(id).current
        // An asset metadata correction can make a historical declaration stale;
        // its frozen audit facts must not block unrelated normal transactions.
        try repository.transaction {database in database.assets[0].durationFrames=61}
        let changed=try repository.read()
        XCTAssertEqual(changed.mediaConfirmations,original.mediaConfirmations)
        XCTAssertFalse(try MediaConfirmationRules.status(revision:revision,scene:revision.scenes[0],database:changed).voice)
        var missing=original;missing.projects=[]
        XCTAssertNoThrow(try MediaConfirmationRules.validate(database:missing))
        XCTAssertFalse(try MediaConfirmationRules.status(revision:revision,scene:revision.scenes[0],database:missing).voice)
        XCTAssertEqual(missing.mediaConfirmations,original.mediaConfirmations)
    }

    func testBackupColdRestorePreservesTheIndependentRecordAndOriginalHistory() throws {
        let (repository,id)=try fixture()
        try confirm(repository,id,request(repository,id))
        let before=try repository.read(),data=try repository.backup()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-confirmation-cold-"+UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        let restored=try Repository.restore(data,to:root),after=try restored.read()
        XCTAssertEqual(before.mediaConfirmations,after.mediaConfirmations)
        XCTAssertEqual(try Codec.data(before.projects),try Codec.data(after.projects))
        XCTAssertEqual(try Codec.data(before.jobs),try Codec.data(after.jobs))
        XCTAssertEqual(try Data(contentsOf:repository.assetURL(before.assets[0])),try Data(contentsOf:restored.assetURL(after.assets[0])))
        let revision=try after.project(id).current
        XCTAssertTrue(try MediaConfirmationRules.status(revision:revision,scene:revision.scenes[0],database:after).voice)
        XCTAssertFalse(revision.review.complete)
    }

    func testLegacySnapshotWithoutTheOptionalLedgerKeepsItsExactRevisionDigest() throws {
        let (repository,id)=try fixture(),before=try repository.read()
        let raw=try Codec.data(before)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
        XCTAssertNil(json["mediaConfirmations"])
        let decoded=try Codec.decoder().decode(Database.self,from:raw)
        XCTAssertNil(decoded.mediaConfirmations)
        XCTAssertEqual(try decoded.project(id).current.contentDigest(),try before.project(id).current.contentDigest())
    }

    func testDryRunAndStrictCommandSchemaNeverWriteOrAcceptNestedApprovals() throws {
        let (repository,id)=try fixture(),database=try repository.read(),project=try database.project(id)
        let confirmation=try Codec.decoder().decode(AgentValue.self,from:Codec.data(request(repository,id)))
        var input:[String:AgentValue] = ["workspace_id":.string("w"),"project_id":.string(id),"base_revision":.string(project.current.id),
            "scene_id":.string(project.current.scenes[0].id),"confirmation":confirmation,"request_id":.string("dry-confirmation")]
        _=try AgentPreview.evaluate(command:"media confirm",data:Codec.data(AgentValue.object(input)),database:database,principal:"rules-owner")
        XCTAssertEqual(try Codec.data(repository.read()),try Codec.data(database))
        var nested=try XCTUnwrap(confirmation.object);nested["review"] = .object(["sound":.boolean(true)])
        input["confirmation"] = .object(nested)
        XCTAssertThrowsError(try AgentContract.validate(command:"media confirm",data:Codec.data(AgentValue.object(input))))
    }
}
