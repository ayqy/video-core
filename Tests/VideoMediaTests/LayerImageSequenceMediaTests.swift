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
    private func flipPixels(_ scene:Scene,frame:Int=0,aspect:Aspect = .landscape,image:CGImage) throws -> CGImage {
        let c=try XCTUnwrap(CGContext(data:nil,width:aspect.width,height:aspect.height,bitsPerComponent:8,bytesPerRow:aspect.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        try LayerPainter.draw(scene:scene,sourceFrame:frame,aspect:aspect,images:["atlas":image],context:c)
        return try XCTUnwrap(c.makeImage())
    }
    private func flipPixel(_ image:CGImage,x:Double,y:Double) throws -> [UInt8] {
        let selected=try XCTUnwrap(image.cropping(to:CGRect(x:floor(x*Double(image.width)),y:floor(y*Double(image.height)),width:1,height:1)))
        let c=try XCTUnwrap(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(selected,in:CGRect(x:0,y:0,width:1,height:1))
        return Array(UnsafeBufferPointer(start:try XCTUnwrap(c.data).assumingMemoryBound(to:UInt8.self),count:4))
    }
    private func staticFlipScene()->Scene {
        var s=scene();s.layers?[0].imageSequence=nil
        s.layers?[0].sourceRect=MediaFraming(x:0,y:0,width:0.75,height:0.5)
        s.layers?[0].x=0.37;s.layers?[0].y=0.42;s.layers?[0].width=0.4;s.layers?[0].height=0.3
        return s
    }
    func testHorizontalFlipReflectsSelectedCropAfterFitAndKeepsLegacyFalsePixels() throws {
        let image=try atlas(),original=staticFlipScene()
        let red=try flipPixel(image,x:0.125,y:0.25),green=try flipPixel(image,x:0.75,y:0.25)
        XCTAssertNotEqual(red,green)
        for aspect in Aspect.allCases {
            var explicitFalse=original;explicitFalse.layers?[0].imageFlipHorizontal=false
            var flipped=original;flipped.layers?[0].imageFlipHorizontal=true
            let plain=try flipPixels(original,aspect:aspect,image:image)
            let mirrored=try flipPixels(flipped,aspect:aspect,image:image)
            XCTAssertEqual(try hash(plain),try hash(flipPixels(explicitFalse,aspect:aspect,image:image)))
            XCTAssertEqual(try flipPixel(plain,x:0.21,y:0.42),red)
            XCTAssertEqual(try flipPixel(plain,x:0.53,y:0.42),green)
            XCTAssertEqual(try flipPixel(mirrored,x:0.21,y:0.42),green)
            XCTAssertEqual(try flipPixel(mirrored,x:0.53,y:0.42),red)
            XCTAssertEqual(try flipPixel(mirrored,x:0.37,y:0.42),red,"须先裁左侧75%再镜像，不能先镜像全图再裁")
            let outside=0.42+0.4*Double(aspect.width)/Double(aspect.height)/6+0.02
            XCTAssertEqual(try flipPixel(mirrored,x:0.37,y:outside)[3],0,"保持选中裁区原比例fit，不能把图层盒拉满")
            let old=try ScenePainter.image(revision:revision(original,aspect:aspect),frame:0,layerImages:["atlas":image])
            XCTAssertEqual(try hash(old),try hash(ScenePainter.image(revision:revision(explicitFalse,aspect:aspect),frame:0,layerImages:["atlas":image])))
            XCTAssertNotEqual(try hash(old),try hash(ScenePainter.image(revision:revision(flipped,aspect:aspect),frame:0,layerImages:["atlas":image])))
        }
    }
    func testHorizontalFlipKeepsSequenceSourceClockMovementAndFinalPause() throws {
        let image=try atlas();var original=staticFlipScene();original.pauseFrames=4
        let red=try flipPixel(image,x:0.125,y:0.25),green=try flipPixel(image,x:0.75,y:0.25)
        original.layers?[0].sourceRect=nil
        original.layers?[0].imageSequence=LayerImageSequence(frames:[
            .init(startFrame:0,endFrame:15,sourceRect:.init(x:0,y:0,width:0.75,height:0.5)),
            .init(startFrame:15,endFrame:30,sourceRect:.init(x:0.25,y:0,width:0.75,height:0.5))])
        original.layers?[0].keyframes=[.init(frame:0,x:0.3,y:0.42,scale:1),.init(frame:29,x:0.6,y:0.42,scale:1)]
        var flipped=original;flipped.layers?[0].imageFlipHorizontal=true
        for frame in [0,14,15,29,30,33] {
            let sample=try LayerPainter.sample(layer:XCTUnwrap(original.layers?.first),scene:original,sourceFrame:frame,aspect:.landscape)
            let other=try LayerPainter.sample(layer:XCTUnwrap(flipped.layers?.first),scene:flipped,sourceFrame:frame,aspect:.landscape)
            XCTAssertEqual(sample.rect,other.rect)
            let x=Double(sample.rect.midX)/Double(Aspect.landscape.width),w=Double(sample.rect.width)/Double(Aspect.landscape.width)
            let plain=try flipPixels(original,frame:frame,image:image),mirrored=try flipPixels(flipped,frame:frame,image:image)
            XCTAssertEqual(try flipPixel(mirrored,x:x-w*0.4,y:0.42),try flipPixel(plain,x:x+w*0.4,y:0.42))
            XCTAssertEqual(try flipPixel(mirrored,x:x+w*0.4,y:0.42),try flipPixel(plain,x:x-w*0.4,y:0.42))
            XCTAssertEqual(try flipPixel(mirrored,x:x,y:0.42),frame<15 ? red:green)
        }
        XCTAssertEqual(try hash(flipPixels(flipped,frame:29,image:image)),try hash(flipPixels(flipped,frame:33,image:image)))
    }
    func testHorizontalFlipKeepsStageRevealAndRestoresContextBeforeFollowingLayers() throws {
        let image=try atlas();var s=staticFlipScene();s.layers?[0].imageFlipHorizontal=true
        let green=try flipPixel(image,x:0.75,y:0.25)
        s.layers?[0].entrance=LayerEntrance(kind:.revealLeft,startFrame:0,endFrame:30)
        var marker=SceneLayer(kind:.rectangle,endFrame:30);marker.color="0000FF";marker.x=0.75;marker.y=0.2;marker.width=0.1;marker.height=0.1
        s.layers?.append(marker)
        let actual=try flipPixels(s,frame:15,image:image)
        var unflipped=s;unflipped.layers?[0].imageFlipHorizontal=nil
        let expected=try flipPixels(unflipped,frame:15,image:image)
        XCTAssertEqual(try flipPixel(actual,x:0.21,y:0.42),green)
        XCTAssertEqual(try flipPixel(actual,x:0.53,y:0.42)[3],0,"舞台左侧揭示方向不随图片镜像反转")
        XCTAssertEqual(try flipPixel(actual,x:0.75,y:0.2),try flipPixel(expected,x:0.75,y:0.2),"下一普通图层不能继承图片翻转矩阵或裁剪")
        XCTAssertEqual(try flipPixel(actual,x:0.75,y:0.2)[3],255)
    }
    func testHorizontalFlipChangesCacheAndSurvivesNormalCompleteBackupRestore() throws {
        let source=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("video-flip-source-"+Codec.id())
        let target=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("video-flip-restored-"+Codec.id())
        defer {try? FileManager.default.removeItem(at:source);try? FileManager.default.removeItem(at:target)}
        let repository=try Repository(root:source),workspace=Workspace(name:"镜像完整恢复",owner:"owner")
        let png=try ScenePainter.png(atlas())
        let asset=try repository.ingest(png,name:"existing-test-atlas.png",workspaceID:workspace.id,mediaType:"image/png")
        var original=scene();original.layers?[0].assetID=asset.id
        let before=Revision(contentContext:ContentContext(workspaceID:workspace.id,name:"同源镜像"),aspect:.landscape,scenes:[original])
        var changed=before;changed.scenes[0].layers?[0].imageFlipHorizontal=true
        var database=Database();database.assets=[asset]
        XCTAssertNotEqual(try VisualClipCache.fingerprint(revision:before,index:0,database:database,modules:nil),try VisualClipCache.fingerprint(revision:changed,index:0,database:database,modules:nil))
        let project=Project(workspaceID:workspace.id,name:"只变图层朝向",revision:changed)
        try repository.transaction {$0.workspaces=[workspace];$0.assets=[asset];$0.projects=[project]}
        let backup=try repository.backup(),restored=try Repository.restore(backup,to:target)
        try restored.verifyAssets(restored.read())
        XCTAssertEqual(try restored.read().projects[0].current.scenes[0].layers?[0].imageFlipHorizontal,true)
        XCTAssertEqual(try Codec.data(restored.read().projects),try Codec.data(repository.read().projects))
        XCTAssertEqual(try Data(contentsOf:restored.assetURL(asset)),png,"镜像不修改已存原始PNG")
    }
}
