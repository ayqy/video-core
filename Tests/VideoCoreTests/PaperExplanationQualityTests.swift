import XCTest
import VideoCore

final class PaperExplanationQualityTests: XCTestCase {
    // Keep the normal workspace/project, complete audio take and registered
    // image-source fixture used by the content-project quality checks.
    private func fixture() throws -> (Database, Revision) {
        let workspace=Workspace(name:"纸面知识工程",owner:"owner")
        let image=Asset(workspaceID:workspace.id,name:"illustration.png",hash:String(repeating:"a",count:64),ext:"png",bytes:100,mediaType:"image/png")
        let audio=Asset(workspaceID:workspace.id,name:"narration.wav",hash:String(repeating:"b",count:64),ext:"wav",bytes:100,mediaType:"audio",durationFrames:60)
        var scene=Scene(title:"",body:"",narration:"路修成后，邻居都能使用。",durationFrames:60)
        scene.paperPresentation=PaperPresentation(layout:.explanation)
        scene.layers=[SceneLayer(kind:.image,assetID:image.id,endFrame:60)]
        scene.voice=VoiceTake(assetID:audio.id,textDigest:try scene.speechDigest(),durationFrames:60,method:"recorded")
        scene.captions=[Caption(text:scene.narration,startFrame:0,endFrame:60)]
        let revision=try Planner.create(workspaceID:workspace.id,name:"纸面知识",aspect:.landscape,scenes:[scene],assets:[image,audio])
        let project=Project(workspaceID:workspace.id,name:"纸面知识",revision:revision)
        var database=Database();database.workspaces=[workspace];database.projects=[project];database.assets=[image,audio]
        return(database,revision)
    }

    func testOrdinaryTitledSceneRetainsOriginalQualityPath() throws {
        let(database,original)=try fixture();var revision=original
        var scene=Scene(title:"观察变化",body:"先观察，再记录实际结果。",durationFrames:60)
        scene.layers=[SceneLayer(kind:.rectangle,endFrame:60)]
        revision.scenes=[scene]
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).isEmpty)
        revision.scenes[0].title=" \n\t"
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).contains{$0.id==scene.id+"text"})
    }

    func testNarratedPaperExplanationCanOmitTitleWithRegisteredImage() throws {
        let(database,original)=try fixture()
        for title in [""," \n\t"] {
            for body in [""," \n\t","观察共同道路。"] {
                var revision=original;revision.scenes[0].title=title;revision.scenes[0].body=body
                XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).isEmpty)
                XCTAssertEqual(revision.scenes[0].title,title)
                XCTAssertEqual(revision.scenes[0].narration,original.scenes[0].narration)
            }
        }
        var genericImage=database;genericImage.assets[0].mediaType="image"
        XCTAssertTrue(try Quality.inspect(original,database:genericImage,requireReview:false).isEmpty)
    }

    func testOmittedTitleStillFailsWithoutEveryPaperExplanationCondition() throws {
        let(database,original)=try fixture()
        for change in 0..<8 {
            var revision=original
            switch change {
            case 0:revision.scenes[0].paperPresentation=nil
            case 1:revision.scenes[0].paperPresentation?.layout = .cover
            case 2:revision.scenes[0].narration=" \n\t";revision.scenes[0].body="画面正文仍有知识。"
            case 3:revision.scenes[0].layers=nil
            case 4:revision.scenes[0].layers=[]
            case 5:revision.scenes[0].layers=[SceneLayer(kind:.rectangle,endFrame:60)]
            case 6:revision.scenes[0].layers=[SceneLayer(kind:.text,text:"知识要点",endFrame:60)]
            default:revision.scenes[0].layers?[0].opacity=0
            }
            XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).contains{$0.id==revision.scenes[0].id+"text"},"缺项 \(change)")
        }
        var emptyKnowledge=original;emptyKnowledge.scenes[0].body=" \n";emptyKnowledge.scenes[0].narration="\t"
        XCTAssertTrue(try Quality.inspect(emptyKnowledge,database:database,requireReview:false).contains{$0.id==emptyKnowledge.scenes[0].id+"text"})
    }

    func testMissingWrongWorkspaceAndWrongMediaSourcesRemainInvalid() throws {
        let(database,original)=try fixture()
        var noReference=original;noReference.scenes[0].layers?[0].assetID=nil
        XCTAssertThrowsError(try Quality.inspect(noReference,database:database,requireReview:false))
        var missing=database;missing.assets.removeFirst()
        XCTAssertThrowsError(try Quality.inspect(original,database:missing,requireReview:false))
        var foreign=database;foreign.assets[0].workspaceID="other-workspace"
        XCTAssertThrowsError(try Quality.inspect(original,database:foreign,requireReview:false))
        var wrongMedia=database;wrongMedia.assets[0].mediaType="audio"
        XCTAssertThrowsError(try Quality.inspect(original,database:wrongMedia,requireReview:false))
        var empty=database;empty.assets[0].bytes=0
        XCTAssertTrue(try Quality.inspect(original,database:empty,requireReview:false).contains{$0.id==original.scenes[0].id+"text"})
        var noncanonical=database;noncanonical.assets[0].mediaType="image-placeholder"
        XCTAssertTrue(try Quality.inspect(original,database:noncanonical,requireReview:false).contains{$0.id==original.scenes[0].id+"text"})
        var wrongWindow=original;wrongWindow.scenes[0].layers?[0].startFrame=60
        XCTAssertThrowsError(try Quality.inspect(wrongWindow,database:database,requireReview:false))
    }

    func testPaperAndSceneKindMustStillPassNormalValidation() throws {
        let(database,original)=try fixture()
        var otherKind=original;otherKind.scenes[0].kind = .image
        XCTAssertThrowsError(try Quality.inspect(otherKind,database:database,requireReview:false))
        var unsupported=original;unsupported.scenes[0].paperPresentation?.version=2
        XCTAssertThrowsError(try Quality.inspect(unsupported,database:database,requireReview:false))
    }

    func testOmittedTitleDoesNotBypassCompleteVoiceCaptionsOrReview() throws {
        let(database,original)=try fixture();let id=original.scenes[0].id
        var missing=original;missing.scenes[0].voice=nil
        let absent=try Quality.inspect(missing,database:database,requireReview:false)
        XCTAssertFalse(absent.contains{$0.id==id+"text"});XCTAssertTrue(absent.contains{$0.id==id+"voice_missing"})
        var stale=original;stale.scenes[0].voice?.textDigest="outdated"
        XCTAssertTrue(try Quality.inspect(stale,database:database,requireReview:false).contains{$0.id==id+"voice"})
        var truncated=original;truncated.scenes[0].voice?.durationFrames=59
        XCTAssertTrue(try Quality.inspect(truncated,database:database,requireReview:false).contains{$0.id==id+"voice_source"})
        let pending=try Quality.inspect(original,database:database,requireReview:true)
        XCTAssertFalse(pending.contains{$0.id==id+"text"})
        for key in [id+"listened",id+"captions","review"] {XCTAssertTrue(pending.contains{$0.id==key},key)}
        var noCaptions=original;noCaptions.scenes[0].captions=[]
        XCTAssertTrue(try Quality.inspect(noCaptions,database:database,requireReview:true).contains{$0.id==id+"captions_missing"})
    }

    func testOmittedTitlePreservesCommercialClaimsAndSourceRights() throws {
        let(base,original)=try fixture();var database=base,revision=original
        revision.purpose = .course
        revision.scenes[0].narration="已有100位学习者完成操作"
        let digest=try revision.scenes[0].speechDigest();revision.scenes[0].voice?.textDigest=digest
        revision.scenes[0].captions=[Caption(text:revision.scenes[0].narration,startFrame:0,endFrame:60)]
        let id=revision.scenes[0].id
        let unsupported=try Quality.inspect(revision,database:database,requireReview:false)
        XCTAssertFalse(unsupported.contains{$0.id==id+"text"})
        XCTAssertTrue(unsupported.contains{$0.id.hasPrefix(id+"claims-")})
        XCTAssertTrue(unsupported.contains{$0.id==database.assets[0].id+"rights"})
        XCTAssertTrue(unsupported.contains{$0.id==database.assets[1].id+"audio_rights"})
        var proof=Evidence(workspaceID:revision.workspaceID,title:"原图与讲解记录",source:"原件许可与核对记录",claim:"另一个记录",owner:"作者",commercialAllowed:true,verified:true)
        revision.scenes[0].evidenceIDs=[proof.id]
        for index in database.assets.indices {database.assets[index].evidenceID=proof.id}
        database.evidence=[proof]
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).contains{$0.id.hasPrefix(id+"claims-")})
        proof.claim=revision.scenes[0].narration;database.evidence=[proof]
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).isEmpty)
        database.evidence[0].verified=false
        let revoked=try Quality.inspect(revision,database:database,requireReview:false)
        XCTAssertTrue(revoked.contains{$0.id==proof.id+"rights"})
        XCTAssertTrue(revoked.contains{$0.id==database.assets[1].id+"audio_rights"})
        XCTAssertTrue(revoked.contains{$0.id.hasPrefix(id+"claims-")})
    }
}
