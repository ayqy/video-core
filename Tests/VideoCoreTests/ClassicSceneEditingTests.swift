import XCTest
@testable import VideoCore

final class ClassicSceneEditingTests:XCTestCase {
    private func fixture()->([Asset],[Evidence]) {
        var images:[Asset]=[];var evidence:[Evidence]=[]
        for index in 0..<2 {
            var asset=Asset(workspaceID:"w",name:"isolated-\(index).png",hash:String(repeating:String(index),count:64),ext:"png",bytes:10,mediaType:"image")
            let e=Evidence(workspaceID:"w",title:"隔离来源\(index)",source:"isolated-source/\(index)",claim:"固定来源，不授予商用",owner:"隔离权利人",commercialAllowed:false,verified:true)
            asset.evidenceID=e.id;images.append(asset);evidence.append(e)
        }
        var audio=Asset(workspaceID:"w",name:"downloaded-cue.wav",hash:String(repeating:"2",count:64),ext:"wav",bytes:10,mediaType:"audio",durationFrames:120)
        let proof=Evidence(workspaceID:"w",title:"隔离原音",source:"isolated-source/sound",claim:"下载原音未听审",owner:"隔离权利人",commercialAllowed:false,verified:true)
        audio.evidenceID=proof.id;images.append(audio);evidence.append(proof)
        return(images,evidence)
    }
    func testActualDifferentDerivativeAndOriginalSourcesAreRequired()throws {
        let (assets,evidence)=fixture()
        XCTAssertThrowsError(try ClassicSceneEditing.derivedAtlas(assetID:assets[0].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"改标签",assets:assets,evidence:evidence,workspaceID:"w"))
        let art=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"已有实际编辑图集及原件",assets:assets,evidence:evidence,workspaceID:"w")
        let scene=try ClassicSceneEditing.binding(art,character:"熟悉角色",to:Scene(kind:.simulation,title:"知识",body:"规则仅用于教学"),assets:assets,evidence:evidence,workspaceID:"w")
        XCTAssertEqual(scene.classicArtwork?.derivation,.qStyle)
        XCTAssertEqual(scene.characterProfile?.original,false)
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:scene,workspaceID:"w",assets:assets,evidence:evidence,commercial:true))
    }
    func testNewMacBindingCannotPromoteOriginalFilesToQProduction()throws {
        let (assets,evidence)=fixture()
        let source=try ClassicSceneEditing.source(assetID:assets[0].id,assets:assets,evidence:evidence,workspaceID:"w")
        let original=ClassicArtwork.quadrants(assetID:assets[0].id,gameplay:.platformer,sources:[source])
        var draft=Scene(kind:.simulation,title:"知识",body:"实际原件")
        draft.simulation.unit=""
        XCTAssertThrowsError(try ClassicSceneEditing.binding(original,character:"熟悉角色原件",to:draft,assets:assets,evidence:evidence,workspaceID:"w",requireQStyle:true))
        let actual=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"已有实际处理图集",assets:assets,evidence:evidence,workspaceID:"w")
        let bound=try ClassicSceneEditing.binding(actual,character:"熟悉角色实际派生",to:draft,assets:assets,evidence:evidence,workspaceID:"w",requireQStyle:true)
        XCTAssertEqual(bound.classicArtwork?.derivation,.qStyle)
        XCTAssertTrue(bound.simulation.unit.isEmpty,"素材可先绑定为草稿；不伪造教学规则单位")
    }
    func testSourceCannotBorrowOtherWorkspaceOrUnrelatedAuthorization()throws {
        let (assets,evidence)=fixture()
        XCTAssertThrowsError(try ClassicSceneEditing.source(assetID:assets[0].id,assets:assets,evidence:evidence,workspaceID:"other"))
        XCTAssertThrowsError(try ClassicSceneEditing.source(assetID:assets[0].id,assets:assets,evidence:[],workspaceID:"w"))
    }
    func testDownloadedAudioNeverAutoTruncatesOrBecomesListened()throws {
        let (assets,evidence)=fixture()
        let art=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"实际派生",assets:assets,evidence:evidence,workspaceID:"w")
        var scene=Scene(kind:.simulation,title:"知识",body:"示例",durationFrames:60);scene.classicArtwork=art
        XCTAssertThrowsError(try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:30,gain:0.3,use:.prompt,extendScene:false,to:scene,assets:assets,evidence:evidence,workspaceID:"w"))
        let extended=try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:30,gain:0.3,use:.prompt,extendScene:true,to:scene,assets:assets,evidence:evidence,workspaceID:"w")
        XCTAssertEqual(extended.durationFrames,150)
        XCTAssertEqual(extended.classicArtwork?.audioCues.first?.durationFrames,120)
        XCTAssertFalse(extended.classicArtwork?.audioCues.first?.listened ?? true)
        XCTAssertEqual(extended.simulationRecordingConfirmed,false)
    }
    func testAudioExtensionRetainsSourceWindowAndPreviouslyRetimedWholeCues()throws {
        let (assets,evidence)=fixture()
        let art=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"实际派生",assets:assets,evidence:evidence,workspaceID:"w")
        var scene=Scene(kind:.simulation,title:"知识",body:"示例",durationFrames:240);scene.classicArtwork=art
        scene.simulationPresentation=SimulationPresentation(sourceStartFrame:60,sourceEndFrame:180,presentationFrames:240)
        scene=try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:30,gain:0.3,use:.effect,extendScene:false,to:scene,assets:assets,evidence:evidence,workspaceID:"w")
        scene.classicArtwork?.audioCues[0].listened=true
        let originalID=try XCTUnwrap(scene.classicArtwork?.audioCues.first?.id)
        let changed=try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:240,gain:0.4,use:.prompt,extendScene:true,to:scene,assets:assets,evidence:evidence,workspaceID:"w")
        XCTAssertEqual(changed.durationFrames,360)
        XCTAssertEqual(try changed.renderSimulationSourceFrame(atTimelineFrame:0),60)
        XCTAssertEqual(try changed.renderSimulationSourceFrame(atTimelineFrame:359),179)
        let cues=try XCTUnwrap(changed.classicArtwork?.audioCues)
        XCTAssertEqual(cues.count,2);XCTAssertEqual(cues[0].id,originalID)
        XCTAssertEqual(cues.map(\.startFrame),[45,240]);XCTAssertEqual(cues.map(\.durationFrames),[120,120])
        XCTAssertTrue(cues.allSatisfy{!$0.listened})
        XCTAssertEqual(changed.simulationRecordingConfirmed,false)
    }
    func testSplitKeepsWholeAudioCuesOnTheirOwnSideAndRetimesTheRight()throws {
        var (assets,evidence)=fixture();assets[2].durationFrames=30
        var scene=try characterScene(assets:assets,evidence:evidence);scene.durationFrames=240
        scene.classicArtwork?.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        let cues=[ClassicAudioCue(assetID:assets[2].id,startFrame:10,durationFrames:30,gain:0.2,use:.effect,listened:true),
                  ClassicAudioCue(assetID:assets[2].id,startFrame:90,durationFrames:30,gain:0.4,use:.prompt,listened:true),
                  ClassicAudioCue(assetID:assets[2].id,startFrame:120,durationFrames:30,gain:0.3,use:.prompt,listened:true),
                  ClassicAudioCue(assetID:assets[2].id,startFrame:180,durationFrames:30,gain:0.5,use:.effect,listened:true)]
        scene.classicArtwork?.audioCues=cues
        scene.captions=[Caption(text:"拆分前后字幕重新核对",startFrame:90,endFrame:150,confirmed:true)]
        var (_,project)=versionDatabase(scene:scene,assets:assets,evidence:evidence)
        project.revisions[0].review.text=true;project.revisions[0].review.rights=true;project.revisions[0].review.fullPreview=true;project.revisions[0].review.sound=true;project.revisions[0].review.captions=true;project.revisions[0].review.digest="original-review"
        let before=try Codec.data(project),originalRevision=project.current
        let changed=try Editor.apply([.splitScene(scene.id,120)],to:project,baseRevision:originalRevision.id,assets:assets,message:"在完整原音之间拆分")
        XCTAssertEqual(changed.current.scenes.map(\.durationFrames),[120,120])
        let left=try XCTUnwrap(changed.current.scenes[0].classicArtwork),right=try XCTUnwrap(changed.current.scenes[1].classicArtwork)
        XCTAssertEqual(left.audioCues.map(\.id),Array(cues.prefix(2)).map(\.id));XCTAssertEqual(right.audioCues.map(\.id),Array(cues.suffix(2)).map(\.id))
        XCTAssertEqual(left.audioCues.map(\.startFrame),[10,90]);XCTAssertEqual(right.audioCues.map(\.startFrame),[0,60])
        for (index,cue) in (left.audioCues+right.audioCues).enumerated() {
            XCTAssertEqual(cue.assetID,cues[index].assetID);XCTAssertEqual(cue.durationFrames,30);XCTAssertEqual(cue.gain,cues[index].gain);XCTAssertEqual(cue.use,cues[index].use);XCTAssertFalse(cue.listened)
        }
        XCTAssertEqual(left.sources,scene.classicArtwork?.sources);XCTAssertEqual(right.sources,scene.classicArtwork?.sources)
        XCTAssertEqual(left.sprites,scene.classicArtwork?.sprites);XCTAssertEqual(right.sprites,scene.classicArtwork?.sprites)
        XCTAssertEqual(changed.current.scenes[0].captions[0].endFrame,120);XCTAssertEqual(changed.current.scenes[1].captions[0].startFrame,0);XCTAssertEqual(changed.current.scenes[1].captions[0].endFrame,30)
        XCTAssertFalse(changed.current.scenes[0].captions[0].confirmed);XCTAssertFalse(changed.current.scenes[1].captions[0].confirmed)
        XCTAssertFalse(changed.current.review.sound);XCTAssertFalse(changed.current.review.fullPreview);XCTAssertFalse(changed.current.review.captions);XCTAssertNil(changed.current.review.digest)
        XCTAssertTrue(changed.current.invalidated.contains("声音确认"));XCTAssertTrue(changed.revisions[0].review.complete)
        XCTAssertEqual(changed.revisions[0].scenes[0],scene);XCTAssertEqual(try Codec.data(project),before)
        for value in changed.current.scenes {try value.validate(assets:assets)}
    }
    func testSplitRejectsAnyCueCrossingTheBoundaryWithoutTruncationEvenWhenSilent()throws {
        var (assets,evidence)=fixture();assets[2].durationFrames=30
        var source=try characterScene(assets:assets,evidence:evidence);source.durationFrames=240
        source.classicArtwork?.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        for use in ClassicAudioCue.Use.allCases {for gain in [0.0,0.35] {for muted in [false,true] {
            var scene=source;scene.muted=muted
            scene.classicArtwork?.audioCues=[ClassicAudioCue(assetID:assets[2].id,startFrame:105,durationFrames:30,gain:gain,use:use,listened:true)]
            let (_,project)=versionDatabase(scene:scene,assets:assets,evidence:evidence),before=try Codec.data(project)
            try scene.validate(assets:assets)
            XCTAssertThrowsError(try Editor.apply([.splitScene(scene.id,120)],to:project,baseRevision:project.current.id,assets:assets,message:"不得截断原音")) { error in
                XCTAssertEqual((error as? VideoError)?.code,"needs_review")
                XCTAssertTrue(error.localizedDescription.contains("不会自动截断原音"))
            }
            XCTAssertEqual(try Codec.data(project),before)
        }}}
    }
    func testSplitRejectsMalformedCueBeforeFrameArithmetic()throws {
        let (assets,evidence)=fixture();var scene=try characterScene(assets:assets,evidence:evidence)
        scene.classicArtwork?.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        scene.classicArtwork?.audioCues=[ClassicAudioCue(assetID:assets[2].id,startFrame:Int.max,durationFrames:120)]
        let (_,project)=versionDatabase(scene:scene,assets:assets,evidence:evidence)
        XCTAssertThrowsError(try Editor.apply([.splitScene(scene.id,60)],to:project,baseRevision:project.current.id,assets:assets,message:"拒绝无效音效位置")) {error in XCTAssertEqual((error as? VideoError)?.code,"invalid_input")}
    }
    func testSameTickClampingUsesTheSameCausalInputOrderInSDKAndRecording()throws {
        var simulation=Simulation();simulation.initial=5;simulation.capacity=10;simulation.unit="箱"
        var first=RuleEvent(tick:1,delta:20,label:"先增加");first.id="z-first"
        var second=RuleEvent(tick:1,delta:-10,label:"后减少");second.id="a-second"
        simulation.events=[first,second]
        let trace=try SimulationReplay.record(simulation:simulation,throughTick:1)
        XCTAssertEqual(trace.transitions.map(\.after),[10,0])
        XCTAssertEqual(try simulation.state(at:1),trace.finalState)
        XCTAssertEqual(try SimulationReplay.frameState(simulation:simulation,frame:30).value,0)
        XCTAssertEqual(trace.transitions.map(\.clippedDelta),[15,0])
    }
    private func characterScene(assets:[Asset],evidence:[Evidence])throws->Scene {
        let artwork=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"已存在的实际派生过程",assets:assets,evidence:evidence,workspaceID:"w")
        return try ClassicSceneEditing.binding(artwork,character:"熟悉角色",to:Scene(kind:.cartoon,title:"角色讲解",body:"明确的教学内容"),assets:assets,evidence:evidence,workspaceID:"w",requireQStyle:true)
    }
    private func versionDatabase(scene:Scene,assets:[Asset],evidence:[Evidence])->(Database,Project) {
        var workspace=Workspace(name:"实际工作区",owner:"actual-owner");workspace.id="w"
        let revision=Revision(contentContext:ContentContext(workspaceID:"w",name:"历史角色"),aspect:.landscape,scenes:[scene])
        let project=Project(workspaceID:"w",name:"实际角色来源",revision:revision)
        var database=Database();database.workspaces=[workspace];database.assets=assets;database.evidence=evidence;database.projects=[project]
        return(database,project)
    }
    func testExpressionUsesAnActualBoundDerivativeAndKeepsOtherSceneData()throws {
        let (assets,evidence)=fixture();var original=try characterScene(assets:assets,evidence:evidence)
        original.kind = .simulation;original.simulationRecording=try SimulationReplay.record(scene:original);original.simulationRecordingConfirmed=true
        original.classicArtwork?.audioCues=[ClassicAudioCue(assetID:assets[2].id,startFrame:0,durationFrames:120,listened:false)]
        original.classicArtwork?.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        let before=try Codec.data(original)
        let expression=ClassicSprite(role:"惊喜",assetID:assets[1].id,x:0.5,y:0,width:0.5,height:0.5)
        let changed=try ClassicSceneEditing.settingExpressionSprite(expression,to:original,assets:assets,evidence:evidence,workspaceID:"w",commercial:false)
        XCTAssertEqual(changed.classicArtwork?.sprites.first{$0.role=="惊喜"},expression)
        XCTAssertEqual(changed.classicArtwork?.sprites.filter{$0.role != "惊喜"},original.classicArtwork?.sprites)
        XCTAssertEqual(changed.characterProfile?.expressions.last,"惊喜");XCTAssertEqual(changed.emotion,"惊喜")
        XCTAssertEqual(changed.classicArtwork?.audioCues,original.classicArtwork?.audioCues)
        XCTAssertEqual(changed.durationFrames,original.durationFrames);XCTAssertEqual(changed.simulation,original.simulation)
        XCTAssertEqual(changed.simulationRecording,original.simulationRecording);XCTAssertEqual(changed.simulationRecordingConfirmed,true)
        XCTAssertEqual(changed.title,original.title);XCTAssertEqual(changed.body,original.body)
        XCTAssertEqual(try Codec.data(original),before)
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:changed,workspaceID:"w",assets:assets,evidence:evidence,commercial:true))
    }
    func testExpressionRejectsOriginalUnboundReservedAndInvalidCropWithoutRelabelling()throws {
        let (baseAssets,baseEvidence)=fixture();let original=try characterScene(assets:baseAssets,evidence:baseEvidence)
        var unbound=baseAssets[1];unbound.id=Codec.id();unbound.hash=String(repeating:"3",count:64)
        let assets=baseAssets+[unbound]
        let candidates=[ClassicSprite(role:"惊喜",assetID:assets[0].id),ClassicSprite(role:"惊喜",assetID:unbound.id),
                        ClassicSprite(role:"hero",assetID:assets[1].id),ClassicSprite(role:"floor",assetID:assets[1].id),
                        ClassicSprite(role:"惊喜",assetID:assets[1].id,x:0.8,width:0.3),
                        ClassicSprite(role:"惊喜",assetID:assets[1].id,width:Double.nan),
                        ClassicSprite(role:"惊\n喜",assetID:assets[1].id)]
        for sprite in candidates {XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(sprite,to:original,assets:assets,evidence:baseEvidence,workspaceID:"w",commercial:false))}
        var locked=original;locked.locked=true
        XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(ClassicSprite(role:"惊喜",assetID:assets[1].id),to:locked,assets:assets,evidence:baseEvidence,workspaceID:"w",commercial:false))
        XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(ClassicSprite(role:"惊喜",assetID:assets[1].id),to:original,assets:assets,evidence:baseEvidence,workspaceID:"other",commercial:false))
    }
    func testExpressionReplacementIsUniqueAndCurrentRightsRemainRequired()throws {
        let (assets,evidence)=fixture();let original=try characterScene(assets:assets,evidence:evidence)
        let expression=ClassicSprite(role:"思考",assetID:assets[1].id,x:0,y:0,width:0.5,height:0.5)
        let first=try ClassicSceneEditing.settingExpressionSprite(expression,to:original,assets:assets,evidence:evidence,workspaceID:"w",commercial:false)
        let replacement=ClassicSprite(role:"思考",assetID:assets[1].id,x:0.5,y:0,width:0.5,height:0.5)
        let next=try ClassicSceneEditing.settingExpressionSprite(replacement,to:first,assets:assets,evidence:evidence,workspaceID:"w",commercial:false)
        XCTAssertEqual(next.classicArtwork?.sprites.filter{$0.role=="思考"},[replacement])
        XCTAssertEqual(next.characterProfile?.expressions.filter{$0=="思考"}.count,1)
        var expired=evidence;expired[1].expiresAt=Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(expression,to:original,assets:assets,evidence:expired,workspaceID:"w",commercial:false))
        var changed=evidence;changed[1].source="unrelated-source"
        XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(expression,to:original,assets:assets,evidence:changed,workspaceID:"w",commercial:false))
    }
    func testHistoricalCharacterReuseUsesExactAuthorizedVersionAndKeepsHistory()throws {
        let (assets,evidence)=fixture();var source=try characterScene(assets:assets,evidence:evidence)
        source.characterProfile?.actions=["原版本点头"]
        var (database,project)=versionDatabase(scene:source,assets:assets,evidence:evidence)
        let revisionID=project.current.id
        var newer=project.current;newer.id=Codec.id();newer.parentID=revisionID;newer.number+=1;newer.scenes[0].characterProfile?.actions=["新版本跳跃"]
        project.revisions.append(newer);database.projects=[project]
        let sourceBefore=try Codec.data(project)
        var target=try characterScene(assets:assets,evidence:evidence);target.title="目标自己的标题";target.durationFrames=210;target.narration="自己的旁白";target.simulation.seed=99
        let result=try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:revisionID,sceneID:source.id,to:target,access:WorkspaceAccessContext(workspaceID:"w",principal:"actual-owner"),database:database,commercial:false)
        XCTAssertEqual(result.characterProfile?.actions,["原版本点头"])
        XCTAssertEqual(result.title,target.title);XCTAssertEqual(result.narration,target.narration);XCTAssertEqual(result.durationFrames,target.durationFrames);XCTAssertEqual(result.simulation,target.simulation)
        for id in [project.id,revisionID,source.id]{XCTAssertTrue(result.classicArtwork?.transformation.contains(id)==true)}
        XCTAssertEqual(try Codec.data(project),sourceBefore)
        let reopened=try Codec.decoder().decode(Scene.self,from:Codec.data(result))
        XCTAssertEqual(reopened,result)
    }
    func testHistoricalReuseRequiresActualScopedReadAndCurrentPurposeRights()throws {
        let (assets,evidence)=fixture();let source=try characterScene(assets:assets,evidence:evidence)
        var (database,project)=versionDatabase(scene:source,assets:assets,evidence:evidence)
        let revisionID=project.current.id,target=try characterScene(assets:assets,evidence:evidence)
        func apply(_ principal:String,_ value:Database,_ commercial:Bool=false)throws->Scene {try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:revisionID,sceneID:source.id,to:target,access:WorkspaceAccessContext(workspaceID:"w",principal:principal),database:value,commercial:commercial)}
        XCTAssertThrowsError(try apply("ungranted-name",database))
        var grant=Grant(principal:"scoped-reader",role:.reviewer,projectIDs:[project.id],revisionIDs:[revisionID],expiresAt:Date().addingTimeInterval(60))
        database.workspaces[0].grants=[grant];XCTAssertNoThrow(try apply("scoped-reader",database))
        grant.revoked=true;database.workspaces[0].grants=[grant];XCTAssertThrowsError(try apply("scoped-reader",database))
        grant.revoked=false;grant.expiresAt=Date().addingTimeInterval(-1);database.workspaces[0].grants=[grant];XCTAssertThrowsError(try apply("scoped-reader",database))
        XCTAssertThrowsError(try apply("actual-owner",database,true))
        var expired=database;expired.evidence[1].expiresAt=Date().addingTimeInterval(-1);XCTAssertThrowsError(try apply("actual-owner",expired))
        var foreign=database;foreign.assets[1].workspaceID="other";XCTAssertThrowsError(try apply("actual-owner",foreign))
        XCTAssertThrowsError(try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:"unknown",sceneID:source.id,to:target,access:WorkspaceAccessContext(workspaceID:"w",principal:"actual-owner"),database:database,commercial:false))
    }
    func testVisualReuseDoesNotCopySourceAudioListeningOrReview()throws {
        var (assets,evidence)=fixture();var targetAudio=assets[2];targetAudio.id=Codec.id();targetAudio.hash=String(repeating:"4",count:64)
        var targetProof=evidence[2];targetProof.id=Codec.id();targetProof.source="isolated-target-sound";targetAudio.evidenceID=targetProof.id;assets.append(targetAudio);evidence.append(targetProof)
        var source=try characterScene(assets:assets,evidence:evidence)
        source=try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:0,gain:0.4,use:.prompt,extendScene:false,to:source,assets:assets,evidence:evidence,workspaceID:"w")
        source.classicArtwork?.audioCues[0].listened=true;source.characterProfile?.voiceAssetID=assets[2].id
        var (database,project)=versionDatabase(scene:source,assets:assets,evidence:evidence)
        project.revisions[0].review.text=true;project.revisions[0].review.rights=true;project.revisions[0].review.fullPreview=true;project.revisions[0].review.sound=true;project.revisions[0].review.captions=true;project.revisions[0].review.digest="isolated-reviewed-source";database.projects=[project]
        var target=try characterScene(assets:assets,evidence:evidence)
        target=try ClassicSceneEditing.addingCue(assetID:targetAudio.id,startFrame:0,gain:0.2,use:.effect,extendScene:false,to:target,assets:assets,evidence:evidence,workspaceID:"w")
        target.characterProfile?.voiceAssetID=targetAudio.id
        target.voice=VoiceTake(assetID:targetAudio.id,textDigest:"target-text",durationFrames:120,method:"existing-target",listened:false)
        let result=try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:project.current.id,sceneID:source.id,to:target,access:WorkspaceAccessContext(workspaceID:"w",principal:"actual-owner"),database:database,commercial:false)
        XCTAssertEqual(result.classicArtwork?.audioCues,target.classicArtwork?.audioCues)
        XCTAssertEqual(result.characterProfile?.voiceAssetID,targetAudio.id);XCTAssertEqual(result.voice,target.voice)
        XCTAssertFalse(result.classicArtwork?.sources.contains{$0.assetID==assets[2].id} ?? true)
        var untouched=Scene(title:"已锁定的其他镜头",body:"保持原画面");untouched.locked=true
        let originalRevision=Revision(contentContext:ContentContext(workspaceID:"w",name:"目标"),aspect:.landscape,scenes:[target,untouched])
        let targetProject=Project(workspaceID:"w",name:"目标",revision:originalRevision)
        let saved=try Editor.apply([.replaceScene(target.id,result)],to:targetProject,baseRevision:originalRevision.id,assets:assets,message:"复用明确角色版本")
        XCTAssertEqual(saved.revisions.count,2);XCTAssertEqual(saved.revisions[0].scenes[0],target)
        XCTAssertEqual(saved.current.scenes[1],untouched)
        XCTAssertFalse(saved.current.review.complete);XCTAssertTrue(project.current.review.complete)
        var locked=target;locked.locked=true
        XCTAssertThrowsError(try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:project.current.id,sceneID:source.id,to:locked,access:WorkspaceAccessContext(workspaceID:"w",principal:"actual-owner"),database:database,commercial:false))
    }
}
