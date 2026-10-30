import XCTest
import VideoCore
@testable import VideoMedia
import CoreGraphics

final class LayerImageSequenceMediaTests: XCTestCase {
    private func atlas() throws -> CGImage {
        let c=try XCTUnwrap(CGContext(data:nil,width:200,height:100,bitsPerComponent:8,bytesPerRow:800,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));c.fill(CGRect(x:0,y:0,width:200,height:100))
        c.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));c.fill(CGRect(x:0,y:50,width:100,height:50))
        c.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1));c.fill(CGRect(x:100,y:50,width:100,height:50))
        return try XCTUnwrap(c.makeImage())
    }
    private var regions:[MediaFraming] {[
        MediaFraming(x:0,y:0,width:0.25,height:0.5),
        MediaFraming(x:0.5,y:0,width:0.25,height:0.5),
        MediaFraming(x:0,y:0.5,width:0.25,height:0.5)
    ]}
    private func scene()->Scene {
        var s=Scene(title:"真实图集动作",body:"按同一源帧连续切换",durationFrames:30)
        s.paperPresentation=PaperPresentation()
        var layer=SceneLayer(kind:.image,assetID:"atlas",endFrame:30)
        layer.x=0.5;layer.y=0.45;layer.width=0.35;layer.height=0.35
        layer.imageSequence=LayerImageSequence(frames:regions.enumerated().map{.init(startFrame:$0.offset*10,endFrame:($0.offset+1)*10,sourceRect:$0.element)})
        s.layers=[layer];return s
    }
    private func revision(_ scene:Scene,aspect:Aspect = .landscape)->Revision {
        Revision(contentContext:ContentContext(workspaceID:"w",name:"真实序列"),aspect:aspect,scenes:[scene])
    }
    private func hash(_ image:CGImage)throws->String {Codec.hash(try ScenePainter.png(image))}
    func testNormalScenePainterSelectsActualTopLeftAtlasPixelsAndFitsTheCroppedPose() throws {
        let image=try atlas(),originalScene=scene()
        for aspect in Aspect.allCases {
            var hashes:[String]=[]
            for frame in [0,9,10,19,20,29] {
                let pose=regions[frame/10]
                let actual=try ScenePainter.image(revision:revision(originalScene,aspect:aspect),frame:frame,layerImages:["atlas":image])
                var plain=originalScene;plain.layers?[0].imageSequence=nil
                let expected=try ScenePainter.image(revision:revision(plain,aspect:aspect),frame:frame,layerImages:["atlas":MediaFramingRenderer.crop(image,framing:pose)])
                XCTAssertEqual(try hash(actual),try hash(expected),"正常Host图片图层必须选取实际源像素，并按所选姿态尺寸fit")
                hashes.append(try hash(actual))
            }
            XCTAssertEqual(hashes[0],hashes[1]);XCTAssertEqual(hashes[2],hashes[3]);XCTAssertEqual(hashes[4],hashes[5])
            XCTAssertNotEqual(hashes[0],hashes[2]);XCTAssertNotEqual(hashes[2],hashes[4])
        }
    }
    func testSinglePoseSplitAndFinalPauseKeepIdenticalActualPixels() throws {
        let image=try atlas();var s=scene();s.pauseFrames=4
        var asset=Asset(workspaceID:"w",name:"图集",hash:"atlas",ext:"png",bytes:16,mediaType:"image/png");asset.id="atlas"
        let p=Project(workspaceID:"w",name:"保真实帧",revision:revision(s))
        let split=try Editor.apply([.splitScene(s.id,5)],to:p,baseRevision:p.current.id,assets:[asset],message:"切入单姿态")
        for frame in 0..<s.timelineFrames {
            XCTAssertEqual(try hash(ScenePainter.image(revision:p.current,frame:frame,layerImages:["atlas":image])),try hash(ScenePainter.image(revision:split.current,frame:frame,layerImages:["atlas":image])))
        }
        let sample=try XCTUnwrap(s.layers?.first)
        for source in [29,30,31,32,33] {
            let expected=try LayerPainter.sample(layer:sample,scene:s,sourceFrame:29,aspect:.landscape)
            let held=try LayerPainter.sample(layer:sample,scene:s,sourceFrame:source,aspect:.landscape)
            XCTAssertEqual(held.rect,expected.rect)
            XCTAssertEqual(try sample.imageSequence?.sourceRect(at:LayerRules.renderSourceFrame(scene:s,sourceFrame:source)),regions[2])
        }
    }
    func testMalformedSequenceCannotBeSilentlyRenderedOrFallbackToWholeAtlas() throws {
        let image=try atlas()
        var bad=scene();bad.layers?[0].imageSequence?.frames[1].startFrame=11
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(bad),frame:0,layerImages:["atlas":image]))
        bad=scene();bad.layers?[0].imageSequence?.frames[1].sourceRect=regions[0]
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(bad),frame:10,layerImages:["atlas":image]))
        bad=scene();bad.layers?[0].kind = .rectangle
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(bad),frame:0,layerImages:["atlas":image]))
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(scene()),frame:0,layerImages:[:]))
    }
    func testSequenceWindowOrAtlasChangesInvalidateVisualCacheIdentity() throws {
        var a=Asset(workspaceID:"w",name:"图集",hash:"source-a",ext:"png",bytes:16,mediaType:"image/png");a.id="atlas"
        var db=Database();db.assets=[a]
        let original=revision(scene())
        let key=try VisualClipCache.fingerprint(revision:original,index:0,database:db,modules:nil)
        var changed=original;changed.scenes[0].layers?[0].imageSequence?.frames[1].sourceRect=MediaFraming(x:0.75,y:0,width:0.25,height:0.5)
        XCTAssertNotEqual(key,try VisualClipCache.fingerprint(revision:changed,index:0,database:db,modules:nil))
        db.assets[0].hash="source-b"
        XCTAssertNotEqual(key,try VisualClipCache.fingerprint(revision:original,index:0,database:db,modules:nil))
    }
    func testStaticAtlasCropUsesExactPixelsAndSurvivesNormalSplit() throws {
        let image=try atlas();var s=scene()
        s.layers?[0].imageSequence=nil;s.layers?[0].sourceRect=regions[1]
        for aspect in Aspect.allCases {
            let actual=try ScenePainter.image(revision:revision(s,aspect:aspect),frame:0,layerImages:["atlas":image])
            var plain=s;plain.layers?[0].sourceRect=nil
            let expected=try ScenePainter.image(revision:revision(plain,aspect:aspect),frame:0,layerImages:["atlas":MediaFramingRenderer.crop(image,framing:regions[1])])
            XCTAssertEqual(try hash(actual),try hash(expected))
            XCTAssertNotEqual(try hash(actual),try hash(ScenePainter.image(revision:revision(plain,aspect:aspect),frame:0,layerImages:["atlas":image])))
        }
        var asset=Asset(workspaceID:"w",name:"静止道具图集",hash:"atlas",ext:"png",bytes:16,mediaType:"image/png");asset.id="atlas"
        let p=Project(workspaceID:"w",name:"原图裁区",revision:revision(s))
        let split=try Editor.apply([.splitScene(s.id,5)],to:p,baseRevision:p.current.id,assets:[asset],message:"保静态道具")
        for frame in 0..<s.timelineFrames {
            XCTAssertEqual(try hash(ScenePainter.image(revision:p.current,frame:frame,layerImages:["atlas":image])),try hash(ScenePainter.image(revision:split.current,frame:frame,layerImages:["atlas":image])))
        }
        var bad=s;bad.layers?[0].imageSequence=scene().layers?[0].imageSequence
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(bad),frame:0,layerImages:["atlas":image]))
        bad=s;bad.layers?[0].kind = .rectangle
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(bad),frame:0,layerImages:["atlas":image]))
        bad=s;bad.layers?[0].sourceRect=MediaFraming(x:0.9,width:0.2)
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(bad),frame:0,layerImages:["atlas":image]))
    }
}
