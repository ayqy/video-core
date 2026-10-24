import XCTest
import VideoCore

final class SplitTimelineRulesTests:XCTestCase {
    private func project(scene:Scene)->Project {
        Project(workspaceID:"w",name:"普通镜头拆分",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"时间轴内容"),aspect:.landscape,scenes:[scene]))
    }
    private func sourceSamples(_ scene:Scene)->[Int] {
        (0..<scene.timelineFrames).map {scene.sourceStartFrame+min(scene.durationFrames-1,scene.renderSourceFrame(atTimelineFrame:$0))}
    }
    func testOrdinarySplitPreservesSourceSamplesAndLeavesTailPauseOnlyOnFinalPiece()throws {
        for kind in [SceneKind.explanation,.image,.video] {
            let asset=Asset(workspaceID:"w",name:kind == .video ? "source.mp4":"source.png",hash:String(repeating:"a",count:64),ext:kind == .video ? "mp4":"png",bytes:100,mediaType:kind == .video ? "video":"image",durationFrames:kind == .video ? 360:nil)
            var scene=Scene(kind:kind,title:"保留原尾停顿",body:"拆分不改变完整时间轴",durationFrames:120)
            scene.pauseFrames=30
            if kind != .explanation {
                scene.assetID=asset.id
                scene.mediaFraming=MediaFraming(x:0.9,y:0.9,width:0.1,height:0.1)
            }
            if kind == .video {scene.sourceStartFrame=37;scene.sourceEndFrame=157}
            let original=project(scene:scene),before=try Codec.data(original)
            let changed=try Editor.apply([.splitScene(scene.id,60)],to:original,baseRevision:original.current.id,assets:[asset],message:"按源帧拆分")
            let parts=changed.current.scenes
            XCTAssertEqual(parts.map(\.pauseFrames),[0,30])
            XCTAssertEqual(changed.current.frames,original.current.frames)
            XCTAssertEqual(parts.flatMap(sourceSamples),sourceSamples(scene))
            XCTAssertEqual(parts.map(\.mediaFraming),[scene.mediaFraming,scene.mediaFraming])
            XCTAssertEqual(try Codec.data(original),before)
            XCTAssertEqual(try Codec.data(changed.revisions[0]),try Codec.data(original.current))
            let splitAgain=try Editor.apply([.splitScene(parts[1].id,30)],to:changed,baseRevision:changed.current.id,assets:[asset],message:"再拆分尾段")
            XCTAssertEqual(splitAgain.current.scenes.map(\.pauseFrames),[0,0,30])
            XCTAssertEqual(splitAgain.current.frames,original.current.frames)
            XCTAssertEqual(splitAgain.current.scenes.flatMap(sourceSamples),sourceSamples(scene))
        }
    }
    func testRetimedSplitRejectsAddedFrameAndChangedSamplingPhase()throws {
        for (speed,point) in [(2.0,61),(1.5,61)] {
            var scene=Scene(title:"连续采样",body:"不悄悄增加或改变输出帧",durationFrames:120)
            scene.speed=speed
            let original=project(scene:scene),before=try Codec.data(original)
            XCTAssertThrowsError(try Editor.apply([.splitScene(scene.id,point)],to:original,baseRevision:original.current.id,assets:[],message:"拒绝不能连续采样的切点")) {error in
                XCTAssertEqual((error as? VideoError)?.code,"needs_review")
                XCTAssertTrue((error as? VideoError)?.localizedDescription.contains("恢复1×") == true)
            }
            XCTAssertEqual(try Codec.data(original),before)
        }
    }
    func testRepresentableRetimedSplitKeepsEverySourceSampleAndTrailingHold()throws {
        for speed in [0.5,1.5,2.0] {
            var scene=Scene(title:"连续采样",body:"可表达的变速拆分保持输出",durationFrames:120)
            scene.speed=speed;scene.pauseFrames=30
            let original=project(scene:scene)
            let changed=try Editor.apply([.splitScene(scene.id,60)],to:original,baseRevision:original.current.id,assets:[],message:"在连续采样处拆分")
            XCTAssertEqual(changed.current.frames,original.current.frames)
            XCTAssertEqual(changed.current.scenes.map(\.pauseFrames),[0,30])
            XCTAssertEqual(changed.current.scenes.flatMap(sourceSamples),sourceSamples(scene))
        }
    }
}
