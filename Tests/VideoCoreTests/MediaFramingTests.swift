import XCTest
import VideoCore

final class MediaFramingTests: XCTestCase {
    func testStrictWindowRejectsUnknownMissingAndOutOfBoundsFields() throws {
        let valid=MediaFraming(x:0.2,y:0.1,width:0.6,height:0.8)
        XCTAssertEqual(try Codec.decoder().decode(MediaFraming.self,from:Codec.data(valid)),valid)
        let edge=MediaFraming(x:0.9,y:0.9,width:0.1,height:0.1)
        XCTAssertNoThrow(try edge.validate(),"90%+10%须能贴源画面右下边，不因浮点减法误拒")
        XCTAssertEqual(try Codec.decoder().decode(MediaFraming.self,from:Codec.data(edge)),edge)
        XCTAssertThrowsError(try MediaFraming(x:0.900000000001,width:0.1).validate())
        for value in [MediaFraming(x:-0.1),MediaFraming(y:.infinity),MediaFraming(width:0),MediaFraming(height:0.009),MediaFraming(x:0.9,width:0.2),MediaFraming(y:0.7,height:0.4),MediaFraming(width:.nan)] {
            XCTAssertThrowsError(try value.validate())
        }
        for raw in ["{\"x\":0,\"y\":0,\"width\":1,\"height\":1,\"left\":0}","{\"x\":0,\"y\":0,\"width\":1}","{\"x\":0,\"y\":0,\"width\":1.1,\"height\":1}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(MediaFraming.self,from:Data(raw.utf8)))
        }
    }

    func testOldSceneOmitsWindowAndKeepsItsDigestWhenDecoded() throws {
        let scene=Scene(title:"已有工程",body:"保持原来的源画面",durationFrames:120)
        let original=try Codec.data(scene)
        XCTAssertFalse(String(decoding:original,as:UTF8.self).contains("mediaFraming"))
        let old=try Codec.decoder().decode(Scene.self,from:original)
        XCTAssertNil(old.mediaFraming)
        XCTAssertEqual(try Codec.digest(scene),try Codec.digest(old))
        var changed=old; changed.mediaFraming=MediaFraming()
        XCTAssertNotEqual(try Codec.digest(old),try Codec.digest(changed))
    }

    func testWindowRequiresActualMatchingMediaAndSurvivesSplitAndRetime() throws {
        let asset=Asset(workspaceID:"w",name:"lesson.mp4",hash:String(repeating:"a",count:64),ext:"mp4",bytes:100,mediaType:"video",durationFrames:360)
        var scene=Scene(kind:.video,title:"知识录屏",body:"只放大实际源中的知识区域",durationFrames:120)
        scene.assetID=asset.id; scene.mediaFraming=MediaFraming(x:0.1,y:0.2,width:0.7,height:0.6)
        XCTAssertNoThrow(try scene.validate(assets:[asset]))
        XCTAssertThrowsError(try scene.validate(assets:[]))
        var mismatch=scene;mismatch.kind = .image
        XCTAssertThrowsError(try mismatch.validate(assets:[asset]))
        mismatch.kind = .explanation
        XCTAssertThrowsError(try mismatch.validate(assets:[asset]))
        var project=Project(workspaceID:"w",name:"实际录屏",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"知识"),aspect:.landscape,scenes:[scene]))
        project.revisions[0].review.fullPreview=true;project.revisions[0].review.sound=true
        let split=try Editor.apply([.splitScene(scene.id,60)],to:project,baseRevision:project.current.id,assets:[asset],message:"拆分录屏")
        XCTAssertEqual(split.current.scenes.map(\.mediaFraming),[scene.mediaFraming,scene.mediaFraming])
        XCTAssertEqual(split.current.scenes[1].sourceStartFrame,60)
        XCTAssertFalse(split.current.review.fullPreview);XCTAssertFalse(split.current.review.sound)
        var faster=split.current.scenes[1]; faster.speed=2
        let retimed=try Editor.apply([.replaceScene(faster.id,faster)],to:split,baseRevision:split.current.id,assets:[asset],message:"改变播放速度")
        XCTAssertEqual(retimed.current.scenes[1].mediaFraming,scene.mediaFraming)
        var locked=project;locked.revisions[0].scenes[0].locked=true
        var crop=locked.current.scenes[0];crop.mediaFraming=MediaFraming()
        XCTAssertThrowsError(try Editor.apply([.replaceScene(crop.id,crop)],to:locked,baseRevision:locked.current.id,assets:[asset],message:"拒绝修改锁定取景"))
    }
}
