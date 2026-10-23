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
}
