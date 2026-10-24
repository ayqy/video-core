import XCTest
import VideoCore

final class LayerEntranceTests: XCTestCase {
    private func scene(speed:Double=1,pause:Int=0)->Scene {
        var s=Scene(title:"图形揭示",body:"先看实际变化",durationFrames:120)
        s.paperPresentation=PaperPresentation();s.speed=speed;s.pauseFrames=pause
        var layer=SceneLayer(kind:.rectangle,endFrame:120);layer.startFrame=10
        layer.entrance=LayerEntrance(kind:.revealLeft,startFrame:20,endFrame:100,sourceOffsetFrames:5)
        s.layers=[layer];return s
    }
    private func project(_ scene:Scene)->Project {
        Project(workspaceID:"w",name:"源帧节拍",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"知识"),aspect:.landscape,scenes:[scene]))
    }
    private func samples(_ scene:Scene)throws->[Double?] {
        let layer=try XCTUnwrap(scene.layers?.first),entrance=try XCTUnwrap(layer.entrance)
        return try (0..<scene.timelineFrames).map { local in
            let source=min(scene.durationFrames-1,scene.renderSourceFrame(atTimelineFrame:local))
            return layer.startFrame<=source && source<layer.endFrame ? try entrance.progress(at:source):nil
        }
    }
    func testProgressUsesSceneSourceFramesAndOffsetRatherThanLayerStart() throws {
        let value=LayerEntrance(kind:.fade,startFrame:20,endFrame:100,sourceOffsetFrames:5)
        XCTAssertEqual(try value.progress(at:0),0)
        XCTAssertEqual(try value.progress(at:15),0)
        XCTAssertEqual(try value.progress(at:55),0.5,accuracy:1e-12)
        XCTAssertEqual(try value.progress(at:95),1)
        XCTAssertEqual(try value.progress(at:119),1)
        XCTAssertEqual(try value.advancingSource(by:60).progress(at:15),try value.progress(at:75))
    }
    func testStrictDecodeRejectsUnknownMissingVersionKindAndInvalidFrames() throws {
        let value=LayerEntrance(kind:.revealLeft,startFrame:20,endFrame:100,sourceOffsetFrames:5)
        XCTAssertEqual(try Codec.decoder().decode(LayerEntrance.self,from:Codec.data(value)),value)
        for raw in [
            #"{"version":1,"kind":"fade","startFrame":0,"endFrame":30,"stroke":"never"}"#,
            #"{"kind":"fade","startFrame":0,"endFrame":30}"#,
            #"{"version":2,"kind":"fade","startFrame":0,"endFrame":30}"#,
            #"{"version":1,"kind":"script","startFrame":0,"endFrame":30}"#,
            #"{"version":1,"kind":"fade","startFrame":30,"endFrame":30}"#,
            #"{"version":1,"kind":"fade","startFrame":-1,"endFrame":30}"#,
            #"{"version":1,"kind":"fade","startFrame":0,"endFrame":54001}"#,
            #"{"version":1,"kind":"fade","startFrame":0,"endFrame":30,"sourceOffsetFrames":-1}"#
        ] {XCTAssertThrowsError(try Codec.decoder().decode(LayerEntrance.self,from:Data(raw.utf8)))}
    }
    func testExtremeSamplingAndWindowArithmeticRejectWithoutOverflow() throws {
        for frame in [Int.min,-1,54001,Int.max] {
            XCTAssertThrowsError(try LayerEntrance().progress(at:frame))
            XCTAssertThrowsError(try LayerEntrance().advancingSource(by:frame))
        }
        for offset in [Int.min,-1,54001,Int.max] {
            XCTAssertThrowsError(try LayerEntrance(sourceOffsetFrames:offset).validate(endFrame:120))
        }
        XCTAssertThrowsError(try LayerEntrance(sourceOffsetFrames:54000).sourceFrame(at:1))
        XCTAssertThrowsError(try LayerEntrance(sourceOffsetFrames:53900).validate(endFrame:120))
        var bad=LayerEntrance();bad.endFrame=Int.max;XCTAssertThrowsError(try bad.progress(at:0))
        XCTAssertNoThrow(try LayerEntrance(startFrame:0,endFrame:54000).validate(endFrame:54000))
    }
    func testLegacyLayerHasIdenticalBytesWithNoEntrance() throws {
        let legacy=Data(#"{"color":"FFFFFF","endFrame":120,"height":0.2,"id":"legacy-layer","keyframes":[],"kind":"文字","locked":false,"opacity":1,"startFrame":0,"text":"旧元素","width":0.5,"x":0.5,"y":0.5}"#.utf8)
        let layer=try Codec.decoder().decode(SceneLayer.self,from:legacy)
        XCTAssertNil(layer.entrance);XCTAssertEqual(try Codec.data(layer),legacy)
    }
    func testSplitAndRepeatedSplitRetainEveryEntranceSampleAndSingleFinalPause() throws {
        let original=scene(pause:15),p=project(original)
        let split=try Editor.apply([.splitScene(original.id,60)],to:p,baseRevision:p.current.id,assets:[],message:"揭示中拆分")
        XCTAssertEqual(split.current.scenes.map(\.pauseFrames),[0,15])
        XCTAssertEqual(split.current.scenes[1].layers?[0].entrance?.sourceOffsetFrames,65)
        let expected=try samples(original),actual=try split.current.scenes.flatMap{try samples($0)}
        XCTAssertEqual(actual,expected)
        let right=split.current.scenes[1]
        let again=try Editor.apply([.splitScene(right.id,30)],to:split,baseRevision:split.current.id,assets:[],message:"再次拆分")
        XCTAssertEqual(again.current.scenes.last?.layers?.first?.entrance?.sourceOffsetFrames,95)
        XCTAssertEqual(try again.current.scenes.flatMap{try samples($0)},expected)
        XCTAssertEqual(again.current.frames,original.timelineFrames)
    }
    func testAlignedSpeedSplitsKeepOutputPhaseAndUnrepresentableCutsAreRejected() throws {
        for speed in [0.25,0.5,1,2,4] {
            let original=scene(speed:speed,pause:7),p=project(original)
            let split=try Editor.apply([.splitScene(original.id,60)],to:p,baseRevision:p.current.id,assets:[],message:"保留变速采样")
            XCTAssertEqual(try split.current.scenes.flatMap{try samples($0)},try samples(original))
        }
        let original=scene(speed:2),p=project(original)
        XCTAssertThrowsError(try Editor.apply([.splitScene(original.id,61)],to:p,baseRevision:p.current.id,assets:[],message:"不改变采样相位"))
        XCTAssertEqual(p.current.scenes,[original])
    }
    func testRetimingUsesTheSameSourceAxisAndPauseHoldsTheFinalState() throws {
        let original=scene(),p=project(original)
        var slower=original;slower.speed=0.5;slower.pauseFrames=12
        let next=try Editor.apply([.replaceScene(original.id,slower)],to:p,baseRevision:p.current.id,assets:[],message:"延缓图形揭示")
        let changed=next.current.scenes[0],entrance=try XCTUnwrap(changed.layers?[0].entrance)
        XCTAssertEqual(try entrance.progress(at:changed.renderSourceFrame(atTimelineFrame:110)),try original.layers![0].entrance!.progress(at:55))
        XCTAssertEqual(Array(try samples(changed).suffix(12)),Array(repeating:Optional(1.0),count:12))
    }
}
