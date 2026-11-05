import Foundation
import XCTest
@testable import VideoCore

final class SceneAudioCueTests: XCTestCase {
    /// Metadata fixtures exercise Core rules only, never actual audio or listening.
    private func fixture() -> (Scene, Asset, Evidence) {
        var asset=Asset(workspaceID:"w",name:"downloaded-effect.wav",hash:String(repeating:"a",count:64),ext:"wav",bytes:100,mediaType:"audio",durationFrames:30)
        asset.id="effect"
        var proof=Evidence(workspaceID:"w",title:"固定来源",source:"isolated-source",claim:"规则夹具，非动森原音",owner:"fixture-author",commercialAllowed:true,verified:true,assetID:asset.id)
        proof.id="effect-proof";asset.evidenceID=proof.id
        var scene=Scene(title:"完整事件",body:"动作后呈现后果",durationFrames:120)
        scene.id="scene"
        var cue=ClassicAudioCue(assetID:asset.id,startFrame:30,durationFrames:30,gain:0.25)
        cue.id="cue";scene.audioCues=[cue]
        return(scene,asset,proof)
    }
    private func project(_ scene: Scene) -> Project {
        Project(workspaceID:"w",name:"Host音效规则",revision:Revision(contentContext:.init(workspaceID:"w",name:"Host音效规则"),aspect:.landscape,scenes:[scene]))
    }

    func testAbsentHostListKeepsLiteralLegacySceneBytesAndRoundTrip() throws {
        let literal=Data(#"{"body":"legacy","captions":[],"character":"圆仔","classicArtworkRequired":true,"color":"6366F1","durationFrames":180,"emotion":"好奇","evidenceIDs":[],"id":"legacy-scene","keyframes":[],"kind":"图文讲解","locked":false,"musicGain":0.15,"muted":false,"narration":"","pauseFrames":0,"preservePitch":true,"scale":1,"showPrice":false,"simulation":{"capacity":10,"events":[],"initial":0,"seed":1,"unit":"金币"},"sourceGain":0,"sourceStartFrame":0,"speed":1,"title":"legacy","voiceGain":1,"x":0.5,"y":0.5}"#.utf8)
        let decoded=try Codec.decoder().decode(Scene.self,from:literal)
        XCTAssertNil(decoded.audioCues)
        XCTAssertEqual(try Codec.data(decoded),literal)
        var nilAgain=decoded;nilAgain.audioCues=nil
        XCTAssertEqual(try Codec.data(nilAgain),literal)
    }

    func testIndependentCuesNeverCrossTheExistingDrawingWire() throws {
        let(scene,_,_)=fixture()
        var old=scene;old.audioCues=nil
        let before=PluginVisualProps(scene:old),after=PluginVisualProps(scene:scene)
        XCTAssertNotEqual(try Codec.data(old),try Codec.data(scene))
        XCTAssertEqual(try Codec.data(before),try Codec.data(after))
        XCTAssertNil(after.drawingScene().audioCues)
        let sceneDefinition=try XCTUnwrap(AgentSchemas.definitions()["Scene"]?.object)
        XCTAssertNotNil(sceneDefinition["properties"]?.object?["audioCues"])
        for schema in [9,10] {
            let definitions=PluginRPCSchemas.definitions(inputSchemaVersion:schema,pluginID:"video.game")
            XCTAssertNil(definitions["Scene"])
            XCTAssertNil(definitions["ClassicAudioCue"])
        }
    }

    func testNormalBindingUsesRealRegisteredWholeRecordingWithoutClassicArtwork() throws {
        var(scene,asset,proof)=fixture();scene.audioCues=nil
        let bound=try SceneAudioCueRules.addingCue(assetID:asset.id,startFrame:90,gain:0.35,use:.effect,to:scene,assets:[asset],evidence:[proof],workspaceID:"w")
        XCTAssertNil(bound.classicArtwork)
        XCTAssertEqual(bound.audioCues?.count,1)
        XCTAssertEqual(bound.audioCues?.first?.durationFrames,asset.durationFrames)
        XCTAssertEqual(bound.audioCues?.first?.startFrame,90)
        XCTAssertEqual(bound.audioCues?.first?.listened,false)
        try bound.validate(assets:[asset])
        XCTAssertThrowsError(try SceneAudioCueRules.addingCue(assetID:asset.id,startFrame:91,gain:0.35,use:.effect,to:scene,assets:[asset],evidence:[proof],workspaceID:"w"))
        scene.locked=true
        XCTAssertThrowsError(try SceneAudioCueRules.addingCue(assetID:asset.id,startFrame:0,gain:0.35,use:.effect,to:scene,assets:[asset],evidence:[proof],workspaceID:"w"))
    }

    func testNativeModelSceneAcceptsHostEventsWithoutAddingAnArtworkOrRPCField() throws {
        let(scene,audio,proof)=fixture()
        let xml="""
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><unit meter="1"/><up_axis>Y_UP</up_axis></asset>
        <library_geometries><geometry id="triangle"><mesh><source id="positions"><float_array id="position-array" count="9">0 0 0 1 0 0 0 1 0</float_array></source></mesh></geometry></library_geometries>
        <library_visual_scenes><visual_scene id="stage"><node id="mesh"><instance_geometry url="#triangle"/></node></visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#stage"/></scene></COLLADA>
        """
        let bytes=Data(xml.utf8)
        let mesh=Asset(workspaceID:"w",name:"authored-test.dae",hash:Codec.hash(bytes),ext:"dae",bytes:bytes.count,mediaType:"model3d")
        let resource=ModelDAEResource(model:.init(asset:mesh),inspection:try DAEInspector.inspect(bytes),textures:[:])
        var native=scene;native.kind = .simulation
        native.modelScene3D=ModelScene3D(instances:[.init(id:"fixture",name:"自制规则网格",resource:resource)],camera:.init(position:.init(x:0,y:2,z:5),target:.init()),lights:[.init(id:"sun",kind:.directional)])
        XCTAssertNil(native.classicArtwork)
        XCTAssertNoThrow(try native.validate(assets:[audio,mesh]))
        XCTAssertNoThrow(try SceneAudioCueRules.validateRights(scene:native,workspaceID:"w",assets:[audio,mesh],evidence:[proof],commercial:false))
        var before=native;before.audioCues=nil
        XCTAssertEqual(try Codec.data(PluginVisualProps(scene:before)),try Codec.data(PluginVisualProps(scene:native)))
        native.classicArtwork=ClassicArtwork(gameplay:.sokoban,sprites:[],sources:[])
        XCTAssertThrowsError(try native.validate(assets:[audio,mesh]))
    }

    func testAssetScopeActualDurationAndIntegerExtremesRejectWithoutMutation() throws {
        let(scene,asset,_)=fixture(),before=try Codec.data(scene)
        var badAssets:[Asset]=[]
        var item=asset;item.workspaceID="foreign";badAssets.append(item)
        item=asset;item.mediaType="image";badAssets.append(item)
        item=asset;item.durationFrames=nil;badAssets.append(item)
        item=asset;item.durationFrames=29;badAssets.append(item)
        item=asset;item.bytes=0;badAssets.append(item)
        for bad in badAssets {XCTAssertThrowsError(try SceneAudioCueRules.validate(scene:scene,assets:[bad],workspaceID:"w"))}
        for values in [(Int.min,30),(Int.max,30),(0,Int.max),(0,0),(91,30),(-1,30)] {
            var bad=scene;bad.audioCues?[0].startFrame=values.0;bad.audioCues?[0].durationFrames=values.1
            XCTAssertThrowsError(try SceneAudioCueRules.validate(scene:bad,assets:[asset],workspaceID:"w"))
        }
        for gain in [-0.01,1.01,Double.infinity,Double.nan] {
            var bad=scene;bad.audioCues?[0].gain=gain
            XCTAssertThrowsError(try SceneAudioCueRules.validate(scene:bad,assets:[asset],workspaceID:"w"))
            XCTAssertThrowsError(try AudioMixRules.mixerHeadroom(scenes:[bad],fps:30))
        }
        XCTAssertEqual(try Codec.data(scene),before)
        let p=project(scene)
        var foreign=asset;foreign.workspaceID="foreign"
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id,scene)],to:p,baseRevision:p.current.id,assets:[foreign],message:"跨域拒绝"))
        XCTAssertThrowsError(try DependencyRules.freeze(revision:p.current,assets:[foreign],evidence:[]))
    }

    func testClassicAndHostListsKeepOrderAndRejectDuplicateIDsOrCombinedOverflow() throws {
        let(scene,asset,_)=fixture()
        var withBoth=scene
        var classic=scene.audioCues![0];classic.id="old-classic";classic.startFrame=0
        withBoth.classicArtwork=ClassicArtwork(gameplay:.sokoban,sprites:[],sources:[],audioCues:[classic])
        XCTAssertEqual(SceneAudioCueRules.combined(scene:withBoth).map(\.id),["old-classic","cue"])
        try SceneAudioCueRules.validate(scene:withBoth,assets:[asset],workspaceID:"w")
        withBoth.audioCues?[0].id=classic.id
        XCTAssertThrowsError(try SceneAudioCueRules.validate(scene:withBoth,assets:[asset],workspaceID:"w"))
        withBoth.audioCues=(0..<128).map { index in var cue=classic;cue.id="new-\(index)";return cue }
        XCTAssertThrowsError(try SceneAudioCueRules.validate(scene:withBoth,assets:[asset],workspaceID:"w"))
        withBoth.classicArtwork=nil
        XCTAssertNoThrow(try SceneAudioCueRules.validate(scene:withBoth,assets:[asset],workspaceID:"w"))
    }

    func testHostCuePresentationEndHonoursRoundedSceneBoundaryAndRealTrailingPause() throws {
        var(scene,asset,_)=fixture()
        scene.durationFrames=5;scene.speed=4
        asset.durationFrames=5;scene.audioCues?[0].startFrame=0;scene.audioCues?[0].durationFrames=5
        XCTAssertEqual(scene.timelineFrames,1)
        XCTAssertThrowsError(try SceneAudioCueRules.validate(scene:scene,assets:[asset],workspaceID:"w"))
        scene.pauseFrames=1
        XCTAssertEqual(scene.timelineFrames,2)
        XCTAssertNoThrow(try SceneAudioCueRules.validate(scene:scene,assets:[asset],workspaceID:"w"))
        scene.pauseFrames=0;scene.durationFrames=8;asset.durationFrames=8
        scene.audioCues?[0].startFrame=4;scene.audioCues?[0].durationFrames=4
        XCTAssertEqual(scene.timelineFrames,2)
        XCTAssertNoThrow(try SceneAudioCueRules.validate(scene:scene,assets:[asset],workspaceID:"w"))
        scene.durationFrames=1;asset.durationFrames=1;scene.audioCues?[0].startFrame=0;scene.audioCues?[0].durationFrames=1
        XCTAssertEqual(scene.timelineFrames,1)
        XCTAssertNoThrow(try SceneAudioCueRules.validate(scene:scene,assets:[asset],workspaceID:"w"))
        scene.durationFrames=Int.max
        XCTAssertThrowsError(try SceneAudioCueRules.validate(scene:scene,assets:[asset],workspaceID:"w"))
        scene.durationFrames=1;scene.pauseFrames=Int.max
        XCTAssertThrowsError(try SceneAudioCueRules.validate(scene:scene,assets:[asset],workspaceID:"w"))
    }

    func testSourceOwnerExpiryCommercialScopeAndListeningStayIndependent() throws {
        let(scene,asset,proof)=fixture()
        try SceneAudioCueRules.validateRights(scene:scene,workspaceID:"w",assets:[asset],evidence:[proof],commercial:true)
        XCTAssertThrowsError(try SceneAudioCueRules.validateRights(scene:scene,workspaceID:"w",assets:[asset],evidence:[proof],commercial:true,requireListening:true))
        var heard=scene;heard.audioCues?[0].listened=true
        XCTAssertNoThrow(try SceneAudioCueRules.validateRights(scene:heard,workspaceID:"w",assets:[asset],evidence:[proof],commercial:true,requireListening:true))
        var bad:[Evidence]=[]
        var item=proof;item.owner=" ";bad.append(item)
        item=proof;item.source="";bad.append(item)
        item=proof;item.verified=false;bad.append(item)
        item=proof;item.expiresAt=Date().addingTimeInterval(-1);bad.append(item)
        item=proof;item.workspaceID="foreign";bad.append(item)
        item=proof;item.commercialAllowed=false;bad.append(item)
        for source in bad {XCTAssertThrowsError(try SceneAudioCueRules.validateRights(scene:heard,workspaceID:"w",assets:[asset],evidence:[source],commercial:true))}
        XCTAssertThrowsError(try SceneAudioCueRules.validateRights(scene:heard,workspaceID:"w",assets:[asset],evidence:[],commercial:false))
        var education=proof;education.commercialAllowed=false
        XCTAssertNoThrow(try SceneAudioCueRules.validateRights(scene:heard,workspaceID:"w",assets:[asset],evidence:[education],commercial:false))
    }

    func testRightsDependencyChainCannotEscapeWorkspaceOrLoseItsSourceDocument() throws {
        let(scene,asset,proof)=fixture()
        var document=Asset(workspaceID:"w",name:"author-license.txt",hash:String(repeating:"c",count:64),ext:"txt",bytes:4,mediaType:"text")
        document.id="license"
        var upstream=proof;upstream.id="upstream-proof";upstream.assetID=document.id
        document.evidenceID=upstream.id
        var linked=proof;linked.assetID=document.id
        try SceneAudioCueRules.validateRights(scene:scene,workspaceID:"w",assets:[asset,document],evidence:[linked,upstream],commercial:true)
        XCTAssertThrowsError(try SceneAudioCueRules.validateRights(scene:scene,workspaceID:"w",assets:[asset],evidence:[linked,upstream],commercial:true))
        var foreign=document;foreign.workspaceID="foreign"
        XCTAssertThrowsError(try SceneAudioCueRules.validateRights(scene:scene,workspaceID:"w",assets:[asset,foreign],evidence:[linked,upstream],commercial:true))
        var revoked=upstream;revoked.commercialAllowed=false
        XCTAssertThrowsError(try SceneAudioCueRules.validateRights(scene:scene,workspaceID:"w",assets:[asset,document],evidence:[linked,revoked],commercial:true))
    }

    func testFrozenGraphIncludesExactCueAssetAndSourceAndDetectsSourceChanges() throws {
        let(scene,asset,proof)=fixture()
        var revision=project(scene).current
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[proof])
        XCTAssertTrue(revision.dependencies!.records.contains{$0.id=="asset:"+asset.id && $0.sceneIDs==[scene.id]})
        XCTAssertTrue(revision.dependencies!.records.contains{$0.id=="evidence:"+proof.id && $0.sceneIDs==[scene.id]})
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[proof]).isEmpty)
        var changed=asset;changed.hash=String(repeating:"b",count:64)
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[changed],evidence:[proof]).contains{$0.sceneIDs==[scene.id]})
        var source=proof;source.owner="different source owner"
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[source]).contains{$0.sceneIDs==[scene.id]})
        var removed=revision;removed.scenes[0].audioCues=nil
        XCTAssertTrue(DependencyRules.diff(revision:removed,assets:[asset],evidence:[proof]).contains{$0.id=="graph"})
    }

    func testChangedEventRevokesOnlyItsListeningAndWholeMixReview() throws {
        var(scene,asset,_)=fixture();scene.audioCues?[0].listened=true
        scene.narration="完整旁白。"
        scene.voice=VoiceTake(assetID:asset.id,textDigest:try scene.speechDigest(),durationFrames:30,method:"isolated-recording",listened:true)
        scene.captions=[Caption(text:scene.narration,startFrame:0,endFrame:30,alignment:"manual",confirmed:true)]
        let p=project(scene)
        var changed=scene;changed.audioCues?[0].startFrame=60
        let updated=try Editor.apply([.replaceScene(scene.id,changed)],to:p,baseRevision:p.current.id,assets:[asset],message:"局部改音效起点")
        XCTAssertEqual(updated.current.scenes[0].audioCues?[0].listened,false)
        XCTAssertEqual(updated.current.scenes[0].voice,scene.voice)
        XCTAssertEqual(updated.current.scenes[0].captions,scene.captions)
        XCTAssertFalse(updated.current.review.complete)
        XCTAssertTrue(updated.current.invalidated.contains("场景音效、混音与声音审核重新复核"))
        XCTAssertEqual(p.current.scenes[0].audioCues?[0].listened,true)
        var retimed=scene;retimed.speed=2
        let changedTime=try Editor.apply([.replaceScene(scene.id,retimed)],to:p,baseRevision:p.current.id,assets:[asset],message:"改实际速度")
        XCTAssertEqual(changedTime.current.scenes[0].audioCues?[0].listened,false)

        var paper=scene;paper.paperPresentation=PaperPresentation()
        var entrance=SceneLayer(kind:.text,text:"开门后离开",endFrame:120)
        entrance.entrance=LayerEntrance(startFrame:0,endFrame:15);paper.layers=[entrance]
        let paperProject=project(paper)
        var later=paper;later.layers?[0].entrance=LayerEntrance(startFrame:45,endFrame:60)
        let moved=try Editor.apply([.replaceScene(paper.id,later)],to:paperProject,baseRevision:paperProject.current.id,assets:[asset],message:"画面动作移到音效之后")
        XCTAssertEqual(moved.current.scenes[0].audioCues?[0].startFrame,30)
        XCTAssertEqual(moved.current.scenes[0].audioCues?[0].listened,false)
        XCTAssertEqual(paperProject.current.scenes[0].audioCues?[0].listened,true)

        let atlas=Asset(workspaceID:"w",name:"two-authored-poses.png",hash:String(repeating:"f",count:64),ext:"png",bytes:100,mediaType:"image/png")
        let left=MediaFraming(x:0,y:0,width:0.5,height:1),right=MediaFraming(x:0.5,y:0,width:0.5,height:1)
        var image=SceneLayer(kind:.image,assetID:atlas.id,endFrame:120)
        image.imageSequence=LayerImageSequence(frames:[.init(startFrame:0,endFrame:60,sourceRect:left),.init(startFrame:60,endFrame:120,sourceRect:right)])
        var animated=scene;animated.layers=[image]
        let animationProject=project(animated)
        var earlier=animated;earlier.layers?[0].imageSequence?.frames[0].endFrame=45;earlier.layers?[0].imageSequence?.frames[1].startFrame=45
        XCTAssertEqual(try XCTUnwrap(animated.layers?[0].imageSequence).sourceRect(at:50),left)
        XCTAssertEqual(try XCTUnwrap(earlier.layers?[0].imageSequence).sourceRect(at:50),right)
        let recut=try Editor.apply([.replaceScene(animated.id,earlier)],to:animationProject,baseRevision:animationProject.current.id,assets:[asset,atlas],message:"同一音效下替换实际序列姿态时点")
        XCTAssertEqual(recut.current.scenes[0].audioCues?[0].listened,false)
        XCTAssertEqual(recut.current.scenes[0].audioCues?[0].assetID,asset.id)

        var simulation=scene;simulation.kind = .simulation
        simulation.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:120,presentationFrames:120)
        let simulationProject=project(simulation)
        var reframed=simulation;reframed.simulationPresentation=SimulationPresentation(sourceStartFrame:30,sourceEndFrame:150,presentationFrames:120)
        XCTAssertEqual(try XCTUnwrap(simulation.simulationPresentation).sourceFrame(atSceneFrame:30,durationFrames:120),30)
        XCTAssertEqual(try XCTUnwrap(reframed.simulationPresentation).sourceFrame(atSceneFrame:30,durationFrames:120),60)
        let selected=try Editor.apply([.replaceScene(simulation.id,reframed)],to:simulationProject,baseRevision:simulationProject.current.id,assets:[asset],message:"保事件时点但更换真实仿真源窗口")
        XCTAssertEqual(selected.current.scenes[0].audioCues?[0].listened,false)
    }

    func testExplicitListeningDeclarationDoesNotBecomeAContentChange() throws {
        var(scene,asset,_)=fixture()
        scene.paperPresentation=PaperPresentation()
        var layer=SceneLayer(kind:.text,text:"保持同一实际入场",endFrame:120)
        layer.entrance=LayerEntrance(startFrame:0,endFrame:15);scene.layers=[layer]
        let p=project(scene)
        var heard=scene;heard.audioCues?[0].listened=true
        let saved=try Editor.apply([.replaceScene(scene.id,heard)],to:p,baseRevision:p.current.id,assets:[asset],message:"实际试听声明夹具")
        XCTAssertEqual(saved.current.scenes[0].audioCues?[0].listened,true)
        XCTAssertFalse(saved.current.review.complete)
        XCTAssertFalse(saved.current.invalidated.contains("场景音效、混音与声音审核重新复核"))
    }

    func testVideoSourceAndWindowChangesRevokeCueListeningWithoutRevokingUnchangedVoice() throws {
        var(scene,audio,_)=fixture();scene.audioCues?[0].listened=true
        let video=Asset(workspaceID:"w",name:"actual-window.mp4",hash:String(repeating:"d",count:64),ext:"mp4",bytes:100,mediaType:"video",durationFrames:360)
        var replacement=video;replacement.id="other-video";replacement.hash=String(repeating:"e",count:64)
        scene.kind = .video;scene.assetID=video.id;scene.sourceEndFrame=120;scene.sourceGain=0
        scene.narration="独立完整旁白。"
        scene.voice=VoiceTake(assetID:audio.id,textDigest:try scene.speechDigest(),durationFrames:30,method:"isolated-recording",listened:true)
        scene.captions=[Caption(text:scene.narration,startFrame:0,endFrame:30,alignment:"manual",confirmed:true)]
        let p=project(scene),assets=[audio,video,replacement]
        var changes:[Scene]=[]
        var changed=scene;changed.assetID=replacement.id;changes.append(changed)
        changed=scene;changed.sourceStartFrame=15;changes.append(changed)
        changed=scene;changed.sourceEndFrame=150;changes.append(changed)
        for change in changes {
            let result=try Editor.apply([.replaceScene(scene.id,change)],to:p,baseRevision:p.current.id,assets:assets,message:"只变片源或源窗")
            XCTAssertEqual(result.current.scenes[0].audioCues?[0].listened,false)
            XCTAssertEqual(result.current.scenes[0].voice,scene.voice)
            XCTAssertEqual(result.current.scenes[0].captions,scene.captions)
        }
        changed=scene;changed.mediaPresentation=MediaPresentation()
        let canvas=try Editor.apply([.replaceScene(scene.id,changed)],to:p,baseRevision:p.current.id,assets:assets,message:"变画面呈现语境")
        XCTAssertEqual(canvas.current.scenes[0].audioCues?[0].listened,false)
        // Existing MediaPresentation editing keeps its own earlier voice/caption
        // invalidation rule; the new cue rule neither weakens nor widens it.
    }

    func testOrdinarySplitKeepsEachEventOnceAndRejectsCuttingItsActualWindow() throws {
        var(scene,asset,_)=fixture()
        var second=scene.audioCues![0];second.id="after";second.startFrame=90
        scene.audioCues?.append(second)
        let p=project(scene)
        XCTAssertThrowsError(try Editor.apply([.splitScene(scene.id,45)],to:p,baseRevision:p.current.id,assets:[asset],message:"不截断原事件"))
        let split=try Editor.apply([.splitScene(scene.id,60)],to:p,baseRevision:p.current.id,assets:[asset],message:"事件间拆分")
        XCTAssertEqual(split.current.scenes.count,2)
        XCTAssertEqual(split.current.scenes[0].audioCues?.map(\.id),["cue"])
        XCTAssertEqual(split.current.scenes[1].audioCues?.map(\.id),["after"])
        XCTAssertEqual(split.current.scenes[1].audioCues?.first?.startFrame,30)
        XCTAssertTrue(split.current.scenes.flatMap{$0.audioCues ?? []}.allSatisfy{!$0.listened})
    }

    func testQualityRequiresActualCueRightsAndListeningOnlyWhenReviewed() throws {
        let(scene,asset,proof)=fixture(),revision=project(scene).current
        var database=Database();database.assets=[asset];database.evidence=[proof]
        XCTAssertFalse(try Quality.inspect(revision,database:database,requireReview:false).contains{$0.id==scene.id+"scene_audio_rights"})
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:true).contains{$0.id==scene.id+"scene_audio_rights"})
        database.evidence=[]
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).contains{$0.id==scene.id+"scene_audio_rights"})
    }
}
