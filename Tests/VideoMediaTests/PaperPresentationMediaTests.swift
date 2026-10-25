import XCTest
import VideoCore
@testable import VideoMedia
import CoreGraphics

final class PaperPresentationMediaTests:XCTestCase {
    private func scene(mode:PaperPresentation.Layout = .explanation)->Scene {
        var value=Scene(title:"不出钱，反而赚更多？",body:"先看一次选择",durationFrames:90)
        value.paperPresentation=PaperPresentation(layout:mode)
        return value
    }
    private func revision(_ scene:Scene,aspect:Aspect = .landscape)->Revision {
        Revision(contentContext:ContentContext(workspaceID:"w",name:"纸面知识"),aspect:aspect,scenes:[scene],cta:"")
    }
    private func hash(_ image:CGImage)throws->String {Codec.hash(try ScenePainter.png(image))}
    private func region(_ image:CGImage,_ rect:CGRect)throws->Data {
        let crop=try XCTUnwrap(image.cropping(to:CGRect(x:rect.minX,y:CGFloat(image.height)-rect.maxY,width:rect.width,height:rect.height)))
        let context=try XCTUnwrap(CGContext(data:nil,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
        return Data(bytes:try XCTUnwrap(context.data),count:crop.width*crop.height*4)
    }
    private func pixel(_ image:CGImage,x:Int,y:Int)throws->[UInt8] {Array(try region(image,CGRect(x:x,y:y,width:1,height:1)))}
    private func save(_ image:CGImage,name:String)throws {
        guard let path=ProcessInfo.processInfo.environment["VIDEO_PAPER_FRAME_DIRECTORY"] else{return}
        let directory=URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try ScenePainter.png(image).write(to:directory.appendingPathComponent(name))
    }
    private func source()throws->CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:240,height:160,bitsPerComponent:8,bytesPerRow:960,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.9,green:0.25,blue:0.15,alpha:1));context.fill(CGRect(x:0,y:0,width:120,height:160))
        context.setFillColor(CGColor(red:0.1,green:0.55,blue:0.65,alpha:1));context.fill(CGRect(x:120,y:0,width:120,height:160))
        return try XCTUnwrap(context.makeImage())
    }
    private func rectangle(entrance:LayerEntrance?)->SceneLayer {
        var layer=SceneLayer(kind:.rectangle,endFrame:90)
        layer.color="FF0000";layer.x=0.5;layer.y=0.5;layer.width=0.4;layer.height=0.2;layer.entrance=entrance
        return layer
    }

    func testActualImageCoverAndExplanationAreVisibleInBothAspects()throws {
        let source=try source()
        var index=0
        for aspect in Aspect.allCases {
            for mode in PaperPresentation.Layout.allCases {
                var value=scene(mode:mode)
                var layer=SceneLayer(kind:.image,assetID:"drawing",endFrame:90)
                let layout=PaperPresentationPainter.Layout(aspect:aspect,mode:mode,showPrice:false,showAction:false)
                layer.x=Double(layout.visual.midX)/Double(aspect.width)
                layer.y=1-Double(layout.visual.midY)/Double(aspect.height)
                layer.width=Double(layout.visual.width)/Double(aspect.width)*0.68
                layer.height=Double(layout.visual.height)/Double(aspect.height)*0.8
                value.layers=[layer]
                let r=revision(value,aspect:aspect)
                let frame=try ScenePainter.image(revision:r,frame:0,layerImages:["drawing":source])
                XCTAssertEqual(frame.width,aspect.width);XCTAssertEqual(frame.height,aspect.height)
                let middle=try pixel(frame,x:Int(layout.visual.midX-20),y:Int(layout.visual.midY))
                XCTAssertGreaterThan(middle[0],middle[2],"实际图片应在第0帧可见，不得用自动淡入隐藏封面主图")
                var empty=value;empty.layers=[]
                let without=try ScenePainter.image(revision:revision(empty,aspect:aspect),frame:0)
                XCTAssertNotEqual(try region(frame,layout.visual),try region(without,layout.visual))
                XCTAssertEqual(try region(frame,layout.title),try region(without,layout.title))
                try save(frame,name:String(format:"%02d-paper-%@-%@.png",index,aspect.rawValue,mode.rawValue));index+=1
            }
        }
    }

    func testOneBodyRegionAndNoLegacyMetaOrPlaybackFooter()throws {
        var a=scene();a.body="选择先发生"
        var b=a;b.body="结果后出现"
        let first=try ScenePainter.image(revision:revision(a),frame:0),second=try ScenePainter.image(revision:revision(b),frame:0)
        let layout=PaperPresentationPainter.Layout(aspect:.landscape,mode:.explanation,showPrice:false,showAction:false)
        XCTAssertNotEqual(try region(first,layout.body),try region(second,layout.body))
        XCTAssertEqual(try region(first,layout.visual),try region(second,layout.visual),"正文不能重复进入主图区域")
        for rect in [CGRect(x:80,y:680,width:1120,height:24),CGRect(x:80,y:24,width:1120,height:26)] {
            let values=try region(first,rect)
            let sample=try pixel(first,x:10,y:10)
            XCTAssertEqual(values,Data((0..<(values.count/4)).flatMap{_ in sample}))
        }
    }

    func testFadeAndRevealUseActualFrameAndDoNotHideInvalidText()throws {
        for kind in LayerEntrance.Kind.allCases {
            var value=scene();value.layers=[rectangle(entrance:LayerEntrance(kind:kind,startFrame:0,endFrame:60))]
            let r=revision(value)
            let start=try ScenePainter.image(revision:r,frame:0),half=try ScenePainter.image(revision:r,frame:30),end=try ScenePainter.image(revision:r,frame:60)
            var complete=value;complete.layers=[rectangle(entrance:nil)]
            let opaque=try ScenePainter.image(revision:revision(complete),frame:60)
            XCTAssertEqual(try hash(end),try hash(opaque),"动画完成态必须与同一真实图层的普通绘制逐像素一致")
            XCTAssertGreaterThan(try pixel(start,x:400,y:360)[1],200)
            XCTAssertEqual(try pixel(end,x:880,y:360),try pixel(opaque,x:880,y:360))
            if kind == .fade {
                let first=try pixel(start,x:640,y:360)[1],middle=try pixel(half,x:640,y:360)[1],last=try pixel(end,x:640,y:360)[1]
                XCTAssertGreaterThan(first,middle);XCTAssertGreaterThan(middle,last)
            } else {
                XCTAssertEqual(try pixel(half,x:400,y:360),try pixel(opaque,x:400,y:360))
                XCTAssertGreaterThan(try pixel(half,x:880,y:360)[1],200)
                try save(half,name:"04-paper-reveal-half.png")
            }
        }
        var invalid=scene();var text=SceneLayer(kind:.text,text:String(repeating:"文字",count:80),endFrame:90)
        text.width=0.1;text.height=0.05;text.entrance=LayerEntrance(startFrame:0,endFrame:60);invalid.layers=[text]
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(invalid),frame:0),"透明或尚未揭示不能绕过完整文字与安全区检查")
    }

    func testSplitSpeedAndPauseRetainSourceEntrancePixels()throws {
        var value=scene();value.layers=[rectangle(entrance:LayerEntrance(kind:.revealLeft,startFrame:0,endFrame:60))]
        let before=revision(value)
        let project=Project(workspaceID:"w",name:"源帧动画",revision:before)
        let split=try Editor.apply([.splitScene(value.id,30)],to:project,baseRevision:before.id,assets:[],message:"保留源动画")
        for frame in [0,15,29,30,45,60,89] {
            XCTAssertEqual(try hash(ScenePainter.image(revision:before,frame:frame)),try hash(ScenePainter.image(revision:split.current,frame:frame)))
        }
        value.speed=2;value.pauseFrames=15
        let fast=revision(value)
        XCTAssertEqual(try hash(ScenePainter.image(revision:fast,frame:15)),try hash(ScenePainter.image(revision:before,frame:30)))
        XCTAssertEqual(try hash(ScenePainter.image(revision:fast,frame:59)),try hash(ScenePainter.image(revision:before,frame:89)))
        try save(ScenePainter.image(revision:fast,frame:59),name:"05-paper-pause-complete.png")
    }

    func testOverflowMissingFontAndUnsupportedSceneKindAreRejected()throws {
        var value=scene();value.title=String(repeating:"超长标题",count:40)
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(value),frame:0))
        value=scene();value.body=String(repeating:"正文不能偷偷裁掉",count:40)
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(value),frame:0))
        value=scene();value.fontName="NoSuchFont-FF1480"
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(value),frame:0))
        value=scene();value.kind = .cartoon
        XCTAssertThrowsError(try ScenePainter.image(revision:revision(value),frame:0))
    }

    func testNilDefaultKeepsLegacyWireAndActualDarkCanvas()throws {
        var legacy=Scene(title:"旧知识标题",body:"旧正文保持",durationFrames:90)
        let before=revision(legacy)
        let first=try ScenePainter.image(revision:before,frame:0)
        legacy.paperPresentation=nil
        let data=try Codec.encoder().encode(legacy)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("paperPresentation"))
        let decoded=try Codec.decoder().decode(Scene.self,from:data)
        XCTAssertEqual(try hash(first),try hash(ScenePainter.image(revision:revision(decoded),frame:0)))
        let topLeft=try pixel(first,x:10,y:700)
        XCTAssertLessThan(topLeft[0],32);XCTAssertLessThan(topLeft[1],32);XCTAssertLessThan(topLeft[2],64)
        var paper=legacy;paper.paperPresentation=PaperPresentation()
        XCTAssertNotEqual(try hash(first),try hash(ScenePainter.image(revision:revision(paper),frame:0)))
    }

    func testPaperTextReservationsAreSeparateAndCaptionChangesDoNotMoveArt()throws {
        for aspect in Aspect.allCases {
            for mode in PaperPresentation.Layout.allCases {
                let layout=PaperPresentationPainter.Layout(aspect:aspect,mode:mode,showPrice:true,showAction:true)
                let fields=[layout.title,layout.body,layout.price,layout.caption,layout.action]
                for i in fields.indices {
                    XCTAssertFalse(fields[i].intersects(layout.visual))
                    for j in fields.indices where j>i {XCTAssertFalse(fields[i].intersects(fields[j]))}
                }
                var a=scene(mode:mode);a.captions=[Caption(text:"先看选择",startFrame:0,endFrame:90,confirmed:false)]
                var b=a;b.captions[0].text="再看结果"
                let first=try ScenePainter.image(revision:revision(a,aspect:aspect),frame:0),second=try ScenePainter.image(revision:revision(b,aspect:aspect),frame:0)
                XCTAssertEqual(try region(first,layout.visual),try region(second,layout.visual))
                XCTAssertNotEqual(try region(first,layout.caption),try region(second,layout.caption))
            }
        }
    }

    func testPaperGridRepeatsAcrossShotsAndReservesASeparateCinemaCaptionBand()throws {
        for aspect in Aspect.allCases {
            for mode in PaperPresentation.Layout.allCases {
                let plain=PaperPresentationPainter.Layout(aspect:aspect,mode:mode,showPrice:false,showAction:false)
                let final=PaperPresentationPainter.Layout(aspect:aspect,mode:mode,showPrice:true,showAction:true)
                XCTAssertEqual(plain.visual,final.visual,"价格或片尾提示不应让同组主体跳位")
                XCTAssertEqual(plain.caption,final.caption)
                XCTAssertEqual(plain.body.minX,plain.title.minX)
                XCTAssertEqual(plain.visual.minX,plain.title.minX)
                XCTAssertEqual(plain.caption.midX,plain.visual.midX)
                XCTAssertLessThan(CinemaSubtitles.fontSize,plain.bodySize)
                XCTAssertLessThan(plain.bodySize,plain.titleSize)
                XCTAssertGreaterThanOrEqual(plain.body.minY-plain.action.maxY,14)
                XCTAssertGreaterThanOrEqual(plain.action.minY-plain.caption.maxY,14)
            }
        }
    }

    func testVisualCacheBindsPaperColorsAndSourceEntrance()throws {
        var value=scene();value.layers=[rectangle(entrance:LayerEntrance(kind:.fade,startFrame:0,endFrame:60))]
        var r=revision(value)
        let database=Database()
        let first=try VisualClipCache.fingerprint(revision:r,index:0,database:database,modules:nil)
        r.scenes[0].paperPresentation?.paperColor="FFFFFF"
        let recolored=try VisualClipCache.fingerprint(revision:r,index:0,database:database,modules:nil)
        XCTAssertNotEqual(first,recolored)
        r.scenes[0].layers?[0].entrance?.kind = .revealLeft
        let revealed=try VisualClipCache.fingerprint(revision:r,index:0,database:database,modules:nil)
        XCTAssertNotEqual(recolored,revealed)
        r.scenes[0].layers?[0].entrance?.sourceOffsetFrames=15
        XCTAssertNotEqual(revealed,try VisualClipCache.fingerprint(revision:r,index:0,database:database,modules:nil))
    }
}
