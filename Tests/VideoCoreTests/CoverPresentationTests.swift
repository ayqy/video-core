import XCTest
import VideoCore

final class CoverPresentationTests:XCTestCase {
    func revision()throws->Revision {
        try Planner.create(workspaceID:"w",name:"囚徒困境",scenes:[Scene(title:"选择与后果",body:"观察两人的选择",narration:"两人分别作出选择。",durationFrames:30)])
    }
    func asset(_ id:String="pose",workspace:String="w")->Asset {
        var image=Asset(workspaceID:workspace,name:"固定角色原图",hash:String(repeating:"a",count:64),ext:"png",bytes:80,mediaType:"image/png")
        image.id=id;return image
    }
    func testOldProjectEncodingHasNoNewFieldAndRoundTripsItsDigest()throws {
        let original=try revision(),raw=try Codec.data(original)
        XCTAssertFalse(String(decoding:raw,as:UTF8.self).contains("coverPresentation"))
        let decoded=try Codec.decoder().decode(Revision.self,from:raw)
        XCTAssertEqual(try decoded.contentDigest(),try original.contentDigest())
        let resolved=try CoverRules.resolved(revision:decoded)
        XCTAssertEqual(resolved.style,.explanation);XCTAssertEqual(resolved.title,"囚徒困境")
        XCTAssertNotEqual(resolved.template,.automatic)
    }
    func testAutomaticStyleFollowsRealSceneKindsAndAuthoredPresentation()throws {
        var value=try revision()
        value.scenes[0].kind = .video;XCTAssertEqual(CoverRules.inferredStyle(revision:value),.media)
        value.scenes[0].kind = .explanation;value.scenes[0].paperPresentation=PaperPresentation()
        XCTAssertEqual(CoverRules.inferredStyle(revision:value),.pencil)
        value.scenes[0].paperPresentation=nil
        value.scenes[0].layers=[SceneLayer(kind:.chart,endFrame:30)]
        XCTAssertEqual(CoverRules.inferredStyle(revision:value),.chart)
        value.scenes[0].layers=[SceneLayer(kind:.code,endFrame:30)]
        XCTAssertEqual(CoverRules.inferredStyle(revision:value),.code)
        value.scenes[0].kind = .simulation;XCTAssertEqual(CoverRules.inferredStyle(revision:value),.game)
        value.scenes[0].kind = .cartoon;XCTAssertEqual(CoverRules.inferredStyle(revision:value),.cartoon)
    }
    func testNicknameOnlyAppliesToIdentifiedDoubaoPresenter()throws {
        var value=try revision()
        value.scenes[0].cartoonPresenter=CartoonPresenter(id:"host",masterRole:"neutral",x:0.5,y:0.5,width:0.2,height:0.4,clips:[],cues:[])
        XCTAssertEqual(try CoverRules.resolved(revision:value).title,"囚徒困境")
        value.scenes[0].id="doubao-prison-presenter"
        XCTAssertEqual(try CoverRules.resolved(revision:value).title,"豆子姐讲「囚徒困境」")
        value.coverPresentation=CoverPresentation(title:"豆子姐讲「合作的代价」")
        XCTAssertEqual(try CoverRules.resolved(revision:value).title,"豆子姐讲「合作的代价」")
    }
    func testThemeSelectsRealExpressionAndExplicitHeroWins()throws {
        var value=try revision()
        let curious=CoverPose(id:"curious",image:CoverImage(assetID:"curious"),expression:"好奇",action:"摊手",keywords:["修桥"])
        let choice=CoverPose(id:"choice",image:CoverImage(assetID:"choice"),expression:"怀疑",action:"叉手",keywords:["囚徒","选择"])
        value.coverPresentation=CoverPresentation(poses:[curious,choice])
        XCTAssertEqual(try CoverRules.resolved(revision:value).hero?.assetID,"choice")
        XCTAssertEqual(try CoverRules.resolved(revision:value).poseID,"choice")
        value.coverPresentation?.hero=CoverImage(assetID:"manual")
        XCTAssertEqual(try CoverRules.resolved(revision:value).hero?.assetID,"manual")
        XCTAssertNil(try CoverRules.resolved(revision:value).poseID)
    }
    func testUnknownFieldsVersionInvalidCropAndEmptyTitlesAreRejected()throws {
        for raw in [#"{"version":1,"style":"pencil","template":"spotlight","execute":"never"}"#,
                    #"{"version":2,"style":"pencil","template":"spotlight"}"#,
                    #"{"version":1,"style":"pencil","template":"spotlight","title":" "}"#,
                    #"{"version":1,"style":"pencil","template":"spotlight","hero":{"assetID":"a","execute":"never"}}"#,
                    #"{"version":1,"style":"pencil","template":"spotlight","hero":{"assetID":"a","sourceRect":{"x":0.9,"y":0,"width":0.5,"height":1}}}"#,
                    #"{"version":1,"style":"pencil","template":"spotlight","poses":[{"id":"a","image":{"assetID":"a"},"expression":"笑","action":"指向","keywords":[],"execute":"never"}]}"#] {
            XCTAssertThrowsError(try Codec.decoder().decode(CoverPresentation.self,from:Data(raw.utf8)))
        }
    }
    func testForeignOrNonImageCoverCannotEnterEditorDatabaseOrFreeze()throws {
        var value=try revision();value.coverPresentation=CoverPresentation(hero:CoverImage(assetID:"pose"))
        for wrong in [asset(workspace:"other"),{()->Asset in var a=asset();a.mediaType="audio/wav";return a}()] {
            XCTAssertThrowsError(try CoverRules.validate(revision:value,assets:[wrong]))
            XCTAssertThrowsError(try DependencyRules.freeze(revision:value,assets:[wrong],evidence:[]))
            var database=Database(),workspace=Workspace(name:"w",owner:"owner");workspace.id="w"
            database.workspaces=[workspace];database.assets=[wrong]
            database.projects=[Project(workspaceID:"w",name:"囚徒困境",revision:value)]
            XCTAssertThrowsError(try database.validate())
        }
    }
    func testEveryPoseAndItsRightsFreezeWithoutAffectingUnrelatedSceneAudio()throws {
        var value=try revision(),a=asset("a"),b=asset("b")
        var proof=Evidence(workspaceID:"w",title:"原件来源",source:"local-original",claim:"封面角色原件",owner:"作者",commercialAllowed:true,verified:true)
        proof.id="proof";a.evidenceID=proof.id;b.evidenceID=proof.id
        value.coverPresentation=CoverPresentation(poses:[CoverPose(id:"a",image:CoverImage(assetID:a.id),expression:"笑",action:"指向"),CoverPose(id:"b",image:CoverImage(assetID:b.id),expression:"疑问",action:"摊手")])
        value.dependencies=try DependencyRules.freeze(revision:value,assets:[a,b],evidence:[proof])
        XCTAssertEqual(Set(value.dependencies!.records.map(\.id)),["asset:a","asset:b","evidence:proof"])
        XCTAssertTrue(value.dependencies!.records.allSatisfy{$0.sceneIDs.isEmpty})
        var changed=a;changed.hash=String(repeating:"b",count:64)
        let changes=DependencyRules.diff(revision:value,assets:[changed,b],evidence:[proof])
        XCTAssertTrue(changes.contains{$0.id=="asset:a:changed"})
        XCTAssertTrue(changes.allSatisfy{$0.sceneIDs.isEmpty})
    }
    func testNormalCoverEditChangesDigestClearsFilmReviewAndPreservesCaptionsAndVoice()throws {
        var value=try revision()
        let audio=Asset(workspaceID:"w",name:"完整原音",hash:String(repeating:"a",count:64),ext:"wav",bytes:80,mediaType:"audio/wav",durationFrames:30)
        value.scenes[0].voice=VoiceTake(assetID:audio.id,textDigest:try value.scenes[0].speechDigest(),durationFrames:30,method:"imported-original",listened:true)
        value.scenes[0].captions=[Caption(text:"两人分别作出选择。",startFrame:0,endFrame:30,confirmed:true)]
        value.review.text=true;value.review.sound=true;value.review.fullPreview=true
        let project=Project(workspaceID:"w",name:"囚徒困境",revision:value)
        let cover=CoverPresentation(style:.pencil,template:.editorial,title:"合作还是背叛？")
        let changed=try Editor.apply([.coverPresentation(cover)],to:project,baseRevision:value.id,assets:[audio],message:"更新封面")
        XCTAssertEqual(changed.current.scenes,value.scenes)
        XCTAssertTrue(changed.current.scenes[0].voice!.listened);XCTAssertTrue(changed.current.scenes[0].captions[0].confirmed)
        XCTAssertFalse(changed.current.review.fullPreview);XCTAssertFalse(changed.current.review.sound)
        XCTAssertNotEqual(try changed.current.contentDigest(),try value.contentDigest())
        XCTAssertTrue(RevisionDifference.compare(value,changed.current).contains{$0.id=="cover"})
        let restored=try Editor.apply([.restore(value.id)],to:changed,baseRevision:changed.current.id,assets:[audio],message:"恢复旧版")
        XCTAssertNil(restored.current.coverPresentation)
    }
    func testSchemaPublishesBoundedTypedCoverAndNormalEdit()throws {
        let definitions=AgentSchemas.definitions()
        XCTAssertEqual(definitions["CoverPresentation"]?.object?["additionalProperties"],.boolean(false))
        XCTAssertEqual(definitions["CoverImage"]?.object?["additionalProperties"],.boolean(false))
        XCTAssertEqual(definitions["CoverPose"]?.object?["additionalProperties"],.boolean(false))
        XCTAssertTrue(String(decoding:try Codec.data(definitions),as:UTF8.self).contains("coverPresentation"))
    }
    func testOnlyCoverParentChainRetainsIndependentDeclarationsAndNeverFilmReview()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cover-confirm-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root)
        var workspace=Workspace(name:"封面独立确认规则",owner:"owner");workspace.id="w"
        let audio=try repository.ingest(Data("isolated complete original audio".utf8),name:"test.wav",workspaceID:"w",mediaType:"audio",durationFrames:30)
        var original=try revision()
        original.scenes[0].voice=VoiceTake(assetID:audio.id,textDigest:try original.scenes[0].speechDigest(),durationFrames:30,method:"isolated-original")
        original.scenes[0].captions=[Caption(text:"两人分别作出选择。",startFrame:0,endFrame:30)]
        original.dependencies=try DependencyRules.freeze(revision:original,assets:[audio],evidence:[])
        let project=Project(workspaceID:"w",name:"囚徒困境",revision:original)
        try repository.transaction{$0.workspaces=[workspace];$0.assets=[audio];$0.projects=[project]}
        let binding=try MediaConfirmationRules.binding(revision:original,scene:original.scenes[0],database:repository.read())
        let record=try repository.recordMediaConfirmation(workspaceID:"w",projectID:project.id,revisionID:original.id,sceneID:original.scenes[0].id,
            confirmation:MediaConfirmationRequest(voice:true,captions:true,method:.manual,statement:"隔离规则声明，不代表实际业务已听审",expected:binding),principal:"owner",requestID:UUID().uuidString)
        func apply(_ operations:[Edit])throws {
            try repository.transaction {database in
                let previous=database.projects[0]
                var changed=try Editor.apply(operations,to:previous,baseRevision:previous.current.id,assets:database.assets,message:"隔离编辑规则")
                changed.revisions[changed.revisions.count-1].dependencies=try DependencyRules.freeze(revision:changed.current,assets:database.assets,evidence:database.evidence)
                database.projects[0]=changed
            }
        }
        func status()throws->MediaConfirmationStatus {
            let database=try repository.read(),current=database.projects[0].current
            return try MediaConfirmationRules.status(revision:current,scene:current.scenes[0],database:database)
        }
        try apply([.coverPresentation(CoverPresentation(style:.pencil,template:.spotlight,title:"合作还是背叛？"))])
        try apply([.coverPresentation(CoverPresentation(style:.pencil,template:.editorial,title:"合作还是背叛？"))])
        XCTAssertTrue(try status().voice);XCTAssertTrue(try status().captions)
        XCTAssertFalse(try repository.read().projects[0].current.review.complete)
        XCTAssertEqual(try repository.read().mediaConfirmations,[record],"不得制造或迁移人工确认记录")
        try repository.transaction{$0.workspaces[0].owner="new-owner"}
        XCTAssertFalse(try status().voice);XCTAssertFalse(try status().captions)
        try repository.transaction{$0.workspaces[0].owner="owner"}
        try repository.transaction{$0.assets[0].hash=String(repeating:"f",count:64)}
        XCTAssertFalse(try status().voice);XCTAssertFalse(try status().captions)
        try repository.transaction{$0.assets[0]=audio}
        XCTAssertTrue(try status().voice);XCTAssertTrue(try status().captions)
        // A temporary movie edit breaks the parent chain permanently. A later
        // reversion and another cover edit must not jump over that boundary.
        try apply([.aspect(.portrait)]);try apply([.aspect(.landscape)])
        try apply([.coverPresentation(CoverPresentation(title:"再看一次选择"))])
        XCTAssertFalse(try status().voice);XCTAssertFalse(try status().captions)
    }
    func testCoverOnlySourceRefreshPreservesMovieAndInvalidatesFilmReview()throws {
        // A cover source update appends a normal draft without changing movie
        // scenes; its frozen asset identity keeps the old delivery stale.
        var value=try revision(),image=asset()
        value.coverPresentation=CoverPresentation(hero:CoverImage(assetID:image.id))
        value.dependencies=try DependencyRules.freeze(revision:value,assets:[image],evidence:[])
        var workspace=Workspace(name:"w",owner:"owner");workspace.id="w"
        var database=Database();database.workspaces=[workspace];database.assets=[image]
        database.projects=[Project(workspaceID:"w",name:"囚徒困境",revision:value)]
        image.hash=String(repeating:"b",count:64);database.assets=[image]
        let changes=DependencyRules.diff(revision:value,assets:database.assets,evidence:[])
        XCTAssertTrue(changes.contains{$0.reason == .changed && $0.sceneIDs.isEmpty})
        try DependencyRules.refreshDependents(in:&database,workspaceID:"w",changedAssetIDs:[image.id],reason:"替换封面原件")
        XCTAssertEqual(database.projects[0].revisions.count,2)
        XCTAssertEqual(database.projects[0].current.scenes,value.scenes)
        XCTAssertFalse(database.projects[0].current.review.complete)
    }
}
