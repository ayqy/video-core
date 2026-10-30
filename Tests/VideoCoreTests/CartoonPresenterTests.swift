import XCTest
import Foundation
@testable import VideoCore

final class CartoonPresenterTests:XCTestCase {
    private func fixture() throws -> (Scene,[Asset]) {
        var image=Asset(workspaceID:"w",name:"three-real-regions.png",hash:String(repeating:"a",count:64),ext:"png",bytes:200,mediaType:"image/png");image.id="sheet";image.evidenceID="proof"
        var take=Asset(workspaceID:"w",name:"actual-take.wav",hash:String(repeating:"b",count:64),ext:"wav",bytes:144000,mediaType:"audio/wav",durationFrames:30);take.id="take"
        var scene=Scene(kind:.cartoon,title:"图片解说",body:"",narration:"同一人物按实际声音表演。",durationFrames:30)
        let digest=try scene.speechDigest()
        scene.voice=VoiceTake(assetID:take.id,textDigest:digest,durationFrames:30,method:"isolated-actual-identity",listened:true)
        scene.classicArtwork=ClassicArtwork(gameplay:.platformer,sprites:(0..<3).map{ClassicSprite(role:"frame-\($0)",assetID:image.id,x:Double($0)/3,width:1.0/3)},sources:[ClassicSource(assetID:image.id,hash:image.hash,source:"isolated fixture",owner:"test",license:"test only",evidenceID:"proof")])
        let frames=[CartoonPresenterFrame(role:"frame-0",mouthOpen:0),.init(role:"frame-1",mouthOpen:0.4),.init(role:"frame-2",mouthOpen:1)]
        let speech=CartoonSpeechTrack(actorID:"presenter",voiceAssetID:take.id,sourceSHA256:take.hash,textDigest:digest,durationFrames:30,energy:[.init(startFrame:0,endFrame:10,rms:0),.init(startFrame:10,endFrame:20,rms:0.18),.init(startFrame:20,endFrame:30,rms:0.02)])
        scene.cartoonPresenter=CartoonPresenter(id:"presenter",masterRole:"frame-0",x:0.75,y:0.5,width:0.4,height:0.9,clips:[.init(id:"neutral",frames:frames)],cues:[.init(startFrame:0,endFrame:30,clipID:"neutral")],speech:speech)
        return(scene,[image,take])
    }
    func testActualVoiceSelectsDistinctImageMouthShapesAndSilenceCloses() throws {
        let (scene,assets)=try fixture();try scene.validate(assets:assets)
        let actor=try XCTUnwrap(scene.cartoonPresenter)
        XCTAssertEqual(actor.role(at:9,durationFrames:30),"frame-0")
        XCTAssertEqual(actor.role(at:10,durationFrames:30),"frame-2")
        XCTAssertEqual(actor.role(at:20,durationFrames:30),"frame-1")
        XCTAssertEqual(actor.role(at:29,durationFrames:30,speechFrame:35),"frame-0","尾停顿保留主体画面但原音已结束，不能冻住开口")
    }
    func testExplicitAppearanceWindowsNeverInventAFrameInGaps() throws {
        var (scene,assets)=try fixture();scene.cartoonPresenter?.cues=[.init(startFrame:3,endFrame:8,clipID:"neutral"),.init(startFrame:15,endFrame:25,clipID:"neutral")]
        try scene.validate(assets:assets)
        for frame in [0,2,8,14,25,29] {XCTAssertNil(scene.cartoonPresenter?.role(at:frame,durationFrames:30))}
        XCTAssertNotNil(scene.cartoonPresenter?.role(at:15,durationFrames:30))
    }
    func testMissingFrameUnknownClipDuplicateRegionAndSingleMouthFailClosed() throws {
        let (source,assets)=try fixture()
        var missing=source;missing.classicArtwork?.sprites.removeLast();XCTAssertThrowsError(try missing.validate(assets:assets))
        var unknown=source;unknown.cartoonPresenter?.cues[0].clipID="unknown";XCTAssertThrowsError(try unknown.validate(assets:assets))
        var duplicate=source;duplicate.classicArtwork?.sprites[1].x=0;XCTAssertThrowsError(try duplicate.validate(assets:assets))
        var fixed=source;fixed.cartoonPresenter?.clips[0].frames[1].mouthOpen=0;fixed.cartoonPresenter?.clips[0].frames[2].mouthOpen=0;XCTAssertThrowsError(try fixed.validate(assets:assets))
    }
    func testVoiceHashTextDurationAndContinuousRMSMustMatchCurrentFullTake() throws {
        let (source,assets)=try fixture()
        var wrong=source;wrong.cartoonPresenter?.speech?.sourceSHA256=String(repeating:"c",count:64);XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.cartoonPresenter?.speech?.textDigest=String(repeating:"c",count:64);XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.cartoonPresenter?.speech?.durationFrames=29;XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.cartoonPresenter?.speech?.energy[1].startFrame=11;XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.cartoonPresenter?.speech=nil;XCTAssertThrowsError(try wrong.validate(assets:assets))
    }
    func testOverlappingOutOfRangeWindowsAndOffCanvasPresenterReject() throws {
        let (source,assets)=try fixture()
        var wrong=source;wrong.cartoonPresenter?.cues.append(.init(startFrame:20,endFrame:30,clipID:"neutral"));XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.cartoonPresenter?.cues[0].endFrame=31;XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.cartoonPresenter?.x=0.95;XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.storyActions=[.init(kind:.move,subjectID:"presenter",startFrame:0,endFrame:10,from:.init(x:0.75,y:0.5),to:.init(x:0.95,y:0.5))];XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.storyActions=[.init(kind:.speak,subjectID:"presenter",startFrame:0,endFrame:10,text:"不能静默忽略")];XCTAssertThrowsError(try wrong.validate(assets:assets))
        wrong=source;wrong.cartoonRig=CartoonRig(actors:[.init(id:"old",name:"旧人物",x:0.5,y:0.5)]);XCTAssertThrowsError(try wrong.validate(assets:assets))
    }
    func testNewPresenterNeedsExplicitSevenAndDoesNotChangeLegacyRigRoutes() throws {
        let (scene,_)=try fixture()
        for schema in [1,4,5,6] {XCTAssertThrowsError(try PluginInputCompatibility.requirePresenterSupport(scene.cartoonPresenter,pluginID:"video.cartoon",inputSchema:schema))}
        XCTAssertNoThrow(try PluginInputCompatibility.requirePresenterSupport(scene.cartoonPresenter,pluginID:"video.cartoon",inputSchema:7))
        XCTAssertThrowsError(try PluginInputCompatibility.requirePresenterSupport(scene.cartoonPresenter,pluginID:"video.game",inputSchema:7))
        for version in [1,2] {let rig=CartoonRig(version:version,actors:[.init(id:"old",name:"旧人物",x:0.5,y:0.5)])
            for schema in [6,7] {XCTAssertNoThrow(try PluginInputCompatibility.requireStorySupport(storyActions:nil,gameWorld:nil,cartoonRig:rig,pluginID:"video.cartoon",inputSchema:schema))}
        }
    }
    func testNewSchemaExposesOnlyVisualFramesNotHostCausalOrRightsData() throws {
        let current=PluginRPCSchemas.definitions(inputSchemaVersion:7,pluginID:"video.cartoon"),old=PluginRPCSchemas.definitions(inputSchemaVersion:6,pluginID:"video.cartoon")
        XCTAssertNotNil(current["CartoonPresenter"]);XCTAssertNil(old["CartoonPresenter"])
        let fields=try XCTUnwrap(current["PluginVisualProps"]?.object?["properties"]?.object)
        XCTAssertNotNil(fields["cartoonPresenter"]);XCTAssertNil(fields["storyCausality"]);XCTAssertNil(fields["evidence"])
        XCTAssertNil(old["PluginVisualProps"]?.object?["properties"]?.object?["cartoonPresenter"])
    }
    func testNilPresenterEncodingAndLegacyRigRoundTripKeepExactBytes() throws {
        let rigs:[CartoonRig?]=[nil,CartoonRig(version:1,actors:[.init(id:"old",name:"旧人物",x:0.5,y:0.5)]),CartoonRig(version:2,actors:[.init(id:"old",name:"旧人物",x:0.5,y:0.5)])]
        for rig in rigs {
            var old=Scene(kind:.cartoon,title:"旧工程",body:"");old.cartoonRig=rig
            let bytes=try Codec.data(old);XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("cartoonPresenter"))
            XCTAssertEqual(bytes,try Codec.data(Codec.decoder().decode(Scene.self,from:bytes)))
        }
    }
    func testUnknownPresenterFieldsRejectAndEditingInvalidatesReviews() throws {
        let (source,assets)=try fixture();let actor=try XCTUnwrap(source.cartoonPresenter)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(actor)) as? [String:Any]);object["inventedFallback"]=true
        XCTAssertThrowsError(try Codec.decoder().decode(CartoonPresenter.self,from:JSONSerialization.data(withJSONObject:object)))
        var old=source;old.captions=[Caption(text:old.narration,startFrame:0,endFrame:30,confirmed:true)]
        let project=Project(workspaceID:"w",name:"图片表演规则",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"图片表演规则"),aspect:.landscape,scenes:[old]))
        var changed=old;changed.cartoonPresenter?.clips[0].frameDurationFrames=2
        let edited=try Editor.apply([.replaceScene(old.id,changed)],to:project,baseRevision:project.current.id,assets:assets,message:"修改实际帧节奏")
        XCTAssertFalse(try XCTUnwrap(edited.current.scenes[0].voice).listened);XCTAssertFalse(edited.current.scenes[0].captions[0].confirmed)
        XCTAssertThrowsError(try Editor.apply([.splitScene(old.id,15)],to:project,baseRevision:project.current.id,assets:assets,message:"不得复制旧帧口型"))
    }
}
