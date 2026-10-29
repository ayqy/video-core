import XCTest
@testable import VideoCore

/// Pure IR identity/range rules. Audio metadata here is an isolated fixture,
/// never evidence of real decoding, a production voice or a review grant.
final class StoryActionTests:XCTestCase {
    private func fixture() throws -> (Scene,[Asset]) {
        var scene=Scene(kind:.cartoon,title:"共同修路",body:"",narration:"先出钱，再修路。",durationFrames:30)
        scene.classicArtworkRequired=false
        let asset=Asset(workspaceID:"w",name:"isolated-audio-identity",hash:String(repeating:"a",count:64),ext:"mp3",bytes:100,mediaType:"audio",durationFrames:30)
        scene.voice=VoiceTake(assetID:asset.id,textDigest:try scene.speechDigest(),durationFrames:30,method:"isolated-import",listened:true)
        scene.cartoonRig=CartoonRig(actors:[.init(id:"speaker",name:"小陈",x:0.5,y:0.5)],cues:[.init(actorID:"speaker",startFrame:0,endFrame:30,expression:.thinking,gesture:.offer)],speech:.init(actorID:"speaker",voiceAssetID:asset.id,sourceSHA256:asset.hash,textDigest:try scene.speechDigest(),durationFrames:30,energy:[.init(startFrame:0,endFrame:3,rms:0),.init(startFrame:3,endFrame:27,rms:0.10),.init(startFrame:27,endFrame:30,rms:0)]))
        return(scene,[asset])
    }
    private func worldFixture() throws -> (Scene,[Asset],[Evidence]) {
        var asset=Asset(workspaceID:"w",name:"isolated-original-map.png",hash:String(repeating:"b",count:64),ext:"png",bytes:100,mediaType:"image")
        let proof=Evidence(workspaceID:"w",title:"隔离原图来源",source:"isolated-original-map",claim:"仅规则夹具，不是媒体或审核证据",owner:"isolated-rules",commercialAllowed:false,verified:true,assetID:asset.id)
        asset.evidenceID=proof.id
        let source=ClassicSource(assetID:asset.id,hash:asset.hash,source:proof.source,owner:proof.owner,license:"isolated-rules",evidenceID:proof.id)
        var scene=Scene(kind:.simulation,title:"完整地图",body:"勇士沿通路行走。",durationFrames:30)
        scene.gameWorld=GameWorld(width:2,height:2,tiles:Array(repeating:"ground",count:4),entities:[.init(id:"hero",name:"勇士",role:"hero",x:0,y:0)])
        scene.classicArtwork=ClassicArtwork(gameplay:.sokoban,sprites:[.init(role:"ground",assetID:asset.id),.init(role:"hero",assetID:asset.id)],sources:[source],derivation:.original,originalAssetIDs:[asset.id])
        scene.simulationRecording=try SimulationReplay.record(scene:scene)
        scene.simulationRecordingConfirmed=true // Rule fixture only, never a production approval.
        return(scene,[asset],[proof])
    }
    private func quality(_ scene:Scene,assets:[Asset],evidence:[Evidence]=[],review:Bool=false)throws->[QualityIssue] {
        var database=Database();database.assets=assets;database.evidence=evidence
        let revision=Revision(contentContext:ContentContext(workspaceID:"w",name:"隔离质量规则"),aspect:.landscape,scenes:[scene])
        return try Quality.inspect(revision,database:database,requireReview:review,enforceBrandDelivery:false)
    }
    func testDynamicTwentyThreeByThirteenWorldUsesActualRolesAndSourceUpdates() throws {
        let actor=GameWorldEntity(id:"hero",name:"勇士",role:"hero-down",x:1,y:2,value:8)
        let world=GameWorld(width:23,height:13,tiles:Array(repeating:"ground",count:299),entities:[actor],updates:[.init(frame:12,entityID:"hero",x:14,y:8,role:"hero-right",value:7)])
        try world.validate(durationFrames:30,availableRoles:["ground","hero-down","hero-right"])
        XCTAssertEqual(try world.frameState(frame:11,durationFrames:30)[0],actor)
        XCTAssertEqual(try world.frameState(frame:12,durationFrames:30)[0].value,7)
        XCTAssertEqual(try world.frameState(frame:12,durationFrames:30)[0].x,14)
        XCTAssertEqual(try world.frameState(frame:300,durationFrames:30),try world.frameState(frame:29,durationFrames:30))
    }
    func testWorldRejectsIncompleteGridUnknownRolesOutsidePositionsAndConflictingUpdates() throws {
        let world=GameWorld(width:2,height:2,tiles:Array(repeating:"floor",count:4),entities:[.init(id:"a",name:"甲",role:"hero",x:0,y:0)])
        var bad=world;bad.tiles.removeLast();XCTAssertThrowsError(try bad.validate(durationFrames:30))
        bad=world;bad.width=Int.max;XCTAssertThrowsError(try bad.validate(durationFrames:30))
        bad=world;bad.entities[0].x = .nan;XCTAssertThrowsError(try bad.validate(durationFrames:30))
        bad=world;bad.updates=[.init(frame:4,entityID:"a",value:1),.init(frame:4,entityID:"a",value:2)];XCTAssertThrowsError(try bad.validate(durationFrames:30))
        XCTAssertThrowsError(try world.validate(durationFrames:30,availableRoles:["floor"]))
    }
    func testDeliveryConstructionAndSpeechKeepCorrectProcessAndTerminalStates() throws {
        let actions=[StoryAction(kind:.transfer,subjectID:"coin",targetID:"road",startFrame:3,endFrame:13,from:.init(x:0.1,y:0.8),to:.init(x:0.7,y:0.3),quantity:1),StoryAction(kind:.build,subjectID:"road",startFrame:13,endFrame:23),StoryAction(kind:.speak,subjectID:"hero",startFrame:4,endFrame:12,text:"我补一枚")]
        try StoryActionRules.validate(actions,durationFrames:30,subjectIDs:["coin","road","hero"])
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"road",actions:actions,frame:0).opacity,0)
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"coin",actions:actions,frame:12).position,.init(x:0.7,y:0.3))
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"coin",actions:actions,frame:29).position,.init(x:0.7,y:0.3))
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"coin",actions:actions,frame:6).progress,1,"移动不能被误当建造裁切")
        XCTAssertGreaterThan(StoryActionRules.presentation(subjectID:"road",actions:actions,frame:18).progress,0)
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"road",actions:actions,frame:29).progress,1)
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"hero",actions:actions,frame:4).bubbleText,"我补一枚")
        XCTAssertNil(StoryActionRules.presentation(subjectID:"hero",actions:actions,frame:12).bubbleText)
    }
    func testActionValidationRejectsUnknownObjectsOverlapAndNonfiniteCoordinates() throws {
        let move=StoryAction(kind:.move,subjectID:"a",startFrame:0,endFrame:10,from:.init(x:0,y:0),to:.init(x:1,y:1))
        XCTAssertThrowsError(try StoryActionRules.validate([move],durationFrames:30,subjectIDs:[]))
        var other=move;other.id=Codec.id();other.startFrame=3;other.endFrame=12
        XCTAssertThrowsError(try StoryActionRules.validate([move,other],durationFrames:30,subjectIDs:["a"]))
        other=move;other.to?.x = .infinity
        XCTAssertThrowsError(try StoryActionRules.validate([other],durationFrames:30,subjectIDs:["a"]))
        other=move;other.kind = .speak;other.from=nil;other.to=nil;other.text=String(repeating:"字",count:49)
        XCTAssertThrowsError(try StoryActionRules.validate([other],durationFrames:30,subjectIDs:["a"]))
    }
    func testNativeRigMouthUsesBoundRMSAndReturnsClosedDuringActualSilence() throws {
        let (scene,assets)=try fixture();try scene.validate(assets:assets)
        let rig=try XCTUnwrap(scene.cartoonRig),track=try XCTUnwrap(rig.speech)
        XCTAssertEqual(track.mouthOpenness(frame:0),0)
        XCTAssertGreaterThan(track.mouthOpenness(frame:4),0)
        XCTAssertEqual(track.mouthOpenness(frame:27),0)
        XCTAssertEqual(track.mouthOpenness(frame:31),0)
        XCTAssertEqual(rig.frameState(frame:4,durationFrames:30)[0].gesture,.offer)
        XCTAssertEqual(rig.frameState(frame:0,durationFrames:30)[0].mouthOpenness,0)
    }
    func testChangingVoiceSourceTextOrDurationRejectsOldLipCues() throws {
        let (scene,assets)=try fixture()
        var changed=scene;changed.voice?.assetID=Codec.id();XCTAssertThrowsError(try changed.validate(assets:assets))
        var replaced=assets;replaced[0].hash=String(repeating:"b",count:64);XCTAssertThrowsError(try scene.validate(assets:replaced))
        changed=scene;changed.narration += "再想一想。";XCTAssertThrowsError(try changed.validate(assets:assets))
        changed=scene;changed.voice?.durationFrames=29;XCTAssertThrowsError(try changed.validate(assets:assets))
        changed=scene;changed.cartoonRig?.speech?.energy[1].startFrame=4;XCTAssertThrowsError(try changed.validate(assets:assets))
        changed=scene;changed.cartoonRig?.speech?.energy[1].rms = .nan;XCTAssertThrowsError(try changed.validate(assets:assets))
    }
    func testOldEncodingsStayAbsentAndNewContractsRoundTripWithoutReplacingSpeech() throws {
        let legacy=Scene(title:"旧镜头",body:"")
        let old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as! [String:Any]
        for key in ["storyActions","gameWorld","cartoonRig"] {XCTAssertNil(old[key])}
        var (scene,assets)=try fixture();scene.storyActions=[.init(kind:.speak,subjectID:"speaker",startFrame:0,endFrame:10,text:"我先出钱")]
        let restored=try JSONDecoder().decode(Scene.self,from:JSONEncoder().encode(scene))
        XCTAssertEqual(restored,scene);try restored.validate(assets:assets)
        XCTAssertEqual(restored.voice,scene.voice)
    }
    func testSchemasExposeNewContractsOnlyForGameSevenAndCartoonFive() throws {
        XCTAssertNil(PluginRPCSchemas.definitions(inputSchemaVersion:6,pluginID:"video.game")["GameWorld"])
        XCTAssertNil(PluginRPCSchemas.definitions(inputSchemaVersion:5,pluginID:"video.game")["StoryAction"])
        XCTAssertNotNil(PluginRPCSchemas.definitions(inputSchemaVersion:7,pluginID:"video.game")["GameWorld"])
        XCTAssertNil(PluginRPCSchemas.definitions(inputSchemaVersion:4,pluginID:"video.cartoon")["CartoonRig"])
        let current=PluginDescription(pluginID:"video.cartoon",capabilityID:"cartoon.animate",version:"isolated",inputSchemaVersion:5)
        XCTAssertNotNil(current.inputSchema.object?["$defs"]?.object?["CartoonRig"])
        XCTAssertNotNil(AgentSchemas.definitions()["SpeechEnergyCue"])
    }
    func testOldModulesRejectNewFeaturesAndLegacyProjectsRemainSupported() throws {
        let actions:[StoryAction]=[]
        for (id,old,new) in [("video.game",6,7),("video.cartoon",4,5)] {
            XCTAssertNoThrow(try PluginInputCompatibility.requireStorySupport(storyActions:nil,gameWorld:nil,cartoonRig:nil,pluginID:id,inputSchema:old))
            XCTAssertThrowsError(try PluginInputCompatibility.requireStorySupport(storyActions:actions,gameWorld:nil,cartoonRig:nil,pluginID:id,inputSchema:old))
            XCTAssertNoThrow(try PluginInputCompatibility.requireStorySupport(storyActions:actions,gameWorld:nil,cartoonRig:nil,pluginID:id,inputSchema:new))
        }
    }
    func testNewCueOrProcessEditsInvalidateReviewsAndUnsafeSplittingRejects() throws {
        var (scene,assets)=try fixture()
        scene.captions=[Caption(text:scene.narration,startFrame:0,endFrame:30,confirmed:true)]
        let project=Project(workspaceID:"w",name:"隔离规则",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"隔离规则"),aspect:.landscape,scenes:[scene]))
        var changed=scene;changed.cartoonRig?.cues[0].gesture = .withdraw
        let edited=try Editor.apply([.replaceScene(scene.id,changed)],to:project,baseRevision:project.current.id,assets:assets,message:"更改真实动作")
        XCTAssertFalse(try XCTUnwrap(edited.current.scenes[0].voice).listened)
        XCTAssertFalse(edited.current.scenes[0].captions[0].confirmed)
        var silent=scene;silent.voice=nil;silent.cartoonRig?.speech=nil
        let silentProject=Project(workspaceID:"w",name:"拆分规则",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"拆分规则"),aspect:.landscape,scenes:[silent]))
        XCTAssertThrowsError(try Editor.apply([.splitScene(silent.id,15)],to:silentProject,baseRevision:silentProject.current.id,assets:assets,message:"不得复制旧cue"))
    }
    func testNativeRigQualityRequiresRealSpeechBindingAndKeepsSoundSubtitleReview() throws {
        var (scene,assets)=try fixture();scene.voice?.listened=false
        scene.captions=[Caption(text:scene.narration,startFrame:0,endFrame:30,confirmed:false)]
        XCTAssertTrue(try quality(scene,assets:assets).isEmpty,"原生独立rig不应被要求绑定游戏图集")
        let reviewed=try quality(scene,assets:assets,review:true)
        XCTAssertTrue(reviewed.contains{$0.id==scene.id+"listened"})
        XCTAssertTrue(reviewed.contains{$0.id==scene.id+"captions"})
        var bad=scene;bad.cartoonRig?.speech=nil;XCTAssertThrowsError(try quality(bad,assets:assets))
        bad=scene;bad.voice=nil;XCTAssertThrowsError(try quality(bad,assets:assets))
        bad=scene;bad.classicArtworkRequired=true;XCTAssertThrowsError(try quality(bad,assets:assets))
        var changed=assets;changed[0].hash=String(repeating:"c",count:64)
        XCTAssertThrowsError(try quality(scene,assets:changed),"真实原音换字节后不能借rig标签通过质量门")
    }
    func testOriginalWorldQualityStillRejectsRevokedRightsUnknownRolesAndForeignSources() throws {
        let (scene,assets,evidence)=try worldFixture()
        XCTAssertTrue(try quality(scene,assets:assets,evidence:evidence).isEmpty,"完整原图地图不应被改标签冒充Q版派生")
        var revoked=evidence;revoked[0].verified=false
        XCTAssertTrue(try quality(scene,assets:assets,evidence:revoked).contains{$0.id==scene.id+"classic_rights" && $0.blocking})
        var unknown=scene;unknown.gameWorld?.tiles[0]="unbound-tile"
        XCTAssertThrowsError(try quality(unknown,assets:assets,evidence:evidence))
        var foreign=assets;foreign[0].workspaceID="another-workspace"
        XCTAssertThrowsError(try quality(scene,assets:foreign,evidence:evidence))
    }
    func testLegacyOriginalArtworkAndArtlessCartoonKeepTheirExistingQualityGates() throws {
        var (scene,assets,evidence)=try worldFixture();scene.gameWorld=nil
        scene.classicArtwork=ClassicArtwork.quadrants(assetID:assets[0].id,gameplay:.sokoban,sources:try XCTUnwrap(scene.classicArtwork).sources)
        XCTAssertTrue(try quality(scene,assets:assets,evidence:evidence).contains{$0.id==scene.id+"classic_qstyle" && $0.blocking})
        var cartoon=Scene(kind:.cartoon,title:"旧几何预览",body:"仍需实际素材。",durationFrames:30)
        cartoon.classicArtworkRequired=false
        XCTAssertTrue(try quality(cartoon,assets:[]).contains{$0.id==cartoon.id+"classic_artwork" && $0.blocking},"单改标记不能冒原生rig")
    }
    func testNewWorldPreservesRecordedKnowledgeWindowAndOriginalTakeUntilExplicitTimingChange() throws {
        let (world,images,_)=try worldFixture()
        var (scene,audio)=try fixture();scene.kind = .simulation;scene.cartoonRig=nil
        scene.classicArtworkRequired=false
        scene.simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"隔离公共品",participants:[.init(id:"a",name:"甲",strategy:.contribute),.init(id:"b",name:"乙",strategy:.freeRide)],rounds:2)
        scene.simulationPresentation=SimulationPresentation(sourceStartFrame:330,sourceEndFrame:360,presentationFrames:30)
        scene.simulationRecording=try SimulationReplay.record(scene:scene);scene.simulationRecordingConfirmed=true
        let assets=audio+images
        let project=Project(workspaceID:"w",name:"隔离业务窗口",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"隔离业务窗口"),aspect:.landscape,scenes:[scene]))
        let original=try Codec.data(project.revisions[0])
        var changed=scene;changed.gameWorld=world.gameWorld;changed.classicArtwork=world.classicArtwork;changed.classicArtworkRequired=true
        let edited=try Editor.apply([.replaceScene(scene.id,changed)],to:project,baseRevision:project.current.id,assets:assets,message:"新地图只改视觉")
        XCTAssertEqual(try Codec.data(edited.revisions[0]),original)
        XCTAssertEqual(edited.current.scenes[0].simulationPresentation,scene.simulationPresentation)
        XCTAssertEqual(edited.current.scenes[0].simulationRecording,scene.simulationRecording)
        XCTAssertEqual(edited.current.scenes[0].simulationRecordingConfirmed,true)
        XCTAssertEqual(edited.current.scenes[0].voice?.assetID,scene.voice?.assetID)
        XCTAssertFalse(try XCTUnwrap(edited.current.scenes[0].voice).listened)
        XCTAssertNoThrow(try SimulationReplay.verify(scene:edited.current.scenes[0]))
        changed.simulationPresentation=nil
        let invalidated=try Editor.apply([.replaceScene(scene.id,changed)],to:project,baseRevision:project.current.id,assets:assets,message:"明确撤去旧业务窗口")
        XCTAssertNil(invalidated.current.scenes[0].voice)
        XCTAssertEqual(invalidated.current.scenes[0].simulationRecordingConfirmed,false)
        XCTAssertThrowsError(try SimulationReplay.verify(scene:invalidated.current.scenes[0]))
    }
    func testRigVersionTwoExpandsOnlyExplicitActorLimitAndRejectsUnknownVersions()throws {
        func actors(_ count:Int)->[CartoonRigActor] {(0..<count).map{.init(id:"actor-\($0)",name:"角色\($0)",x:0.5,y:0.5)}}
        let legacy=CartoonRig(actors:actors(4));XCTAssertEqual(legacy.version,1);try legacy.validate(durationFrames:30,voiceBinding:nil)
        XCTAssertThrowsError(try CartoonRig(actors:actors(5)).validate(durationFrames:30,voiceBinding:nil))
        for count in [1,4,7,8] {try CartoonRig(version:2,actors:actors(count)).validate(durationFrames:30,voiceBinding:nil)}
        for count in [0,9] {XCTAssertThrowsError(try CartoonRig(version:2,actors:actors(count)).validate(durationFrames:30,voiceBinding:nil))}
        for version in [0,3,99] {XCTAssertThrowsError(try CartoonRig(version:version,actors:actors(1)).validate(durationFrames:30,voiceBinding:nil))}
        var duplicate=CartoonRig(version:2,actors:actors(7));duplicate.actors[6].id=duplicate.actors[0].id
        XCTAssertThrowsError(try duplicate.validate(durationFrames:30,voiceBinding:nil))
    }
    func testVersionOneRigWireAndOriginalRMSPresentationRemainUnchanged()throws {
        let (scene,assets)=try fixture(),rig=try XCTUnwrap(scene.cartoonRig),data=try Codec.data(rig)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(object.keys),Set(["version","actors","cues","speech"]));XCTAssertEqual(object["version"] as? Int,1)
        let decoded=try Codec.decoder().decode(CartoonRig.self,from:data)
        XCTAssertEqual(try Codec.data(decoded),data);XCTAssertEqual(decoded,rig)
        for frame in [0,3,15,27,29] {XCTAssertEqual(decoded.frameState(frame:frame,durationFrames:30),rig.frameState(frame:frame,durationFrames:30))}
        try scene.validate(assets:assets)
        let legacy=Scene(title:"旧无rig",body:"旧镜头")
        XCTAssertFalse(String(decoding:try Codec.data(legacy),as:UTF8.self).contains("cartoonRig"))
    }
}
