import XCTest
import VideoCore
@testable import VideoMedia
import CoreGraphics

final class MediaFramingMediaTests: XCTestCase {
    private func source() throws -> CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:200,height:100,bitsPerComponent:8,bytesPerRow:800,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        // Canvas y-up: the blue bottom half is the source raster's lower half.
        context.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:200,height:100))
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));context.fill(CGRect(x:0,y:50,width:100,height:50))
        context.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1));context.fill(CGRect(x:100,y:50,width:100,height:50))
        return try XCTUnwrap(context.makeImage())
    }
    private func hash(_ image:CGImage) throws -> String {Codec.hash(try ScenePainter.png(image))}

    func testWindowUsesSourceTopLeftAndKeepsFullFramePixels() throws {
        let image=try source()
        XCTAssertEqual(try hash(image),try hash(MediaFramingRenderer.crop(image,framing:nil)))
        XCTAssertEqual(try hash(image),try hash(MediaFramingRenderer.crop(image,framing:MediaFraming())))
        let topLeft=try MediaFramingRenderer.crop(image,framing:MediaFraming(x:0,y:0,width:0.5,height:0.5))
        let expected=try XCTUnwrap(image.cropping(to:CGRect(x:0,y:0,width:100,height:50)))
        XCTAssertEqual(topLeft.width,100);XCTAssertEqual(topLeft.height,50)
        XCTAssertEqual(try hash(topLeft),try hash(expected))
        let topRight=try MediaFramingRenderer.crop(image,framing:MediaFraming(x:0.5,y:0,width:0.5,height:0.5))
        XCTAssertNotEqual(try hash(topLeft),try hash(topRight))
        let bottom=try MediaFramingRenderer.crop(image,framing:MediaFraming(x:0,y:0.5,width:0.5,height:0.5))
        XCTAssertNotEqual(try hash(topLeft),try hash(bottom))
        let edge=try MediaFramingRenderer.crop(image,framing:MediaFraming(x:0.9,y:0.9,width:0.1,height:0.1))
        XCTAssertEqual(edge.width,20);XCTAssertEqual(edge.height,10)
        XCTAssertThrowsError(try MediaFramingRenderer.crop(image,framing:MediaFraming(x:0.9,width:0.5)))
    }

    func testFramedSourceIsTheSamePixelsInPreviewAndPreservesCaptionAndFooterRegions() throws {
        let image=try source()
        for aspect in Aspect.allCases {
            var scene=Scene(kind:.image,title:"局部放大知识区域",body:"材料中的红色与绿色区域。",durationFrames:60)
            scene.mediaFraming=MediaFraming(x:0,y:0,width:0.5,height:0.5)
            scene.captions=[Caption(text:"核对局部信息",startFrame:0,endFrame:60,confirmed:false)]
            let revision=Revision(contentContext:ContentContext(workspaceID:"w",name:"取景"),aspect:aspect,scenes:[scene],cta:"回看原始材料")
            let before=try ScenePainter.image(revision:revision,frame:15,media:image)
            var changed=revision;changed.scenes[0].mediaFraming=MediaFraming(x:0.5,y:0,width:0.5,height:0.5)
            let after=try ScenePainter.image(revision:changed,frame:15,media:image)
            let layout=ScenePainter.OverlayLayout(width:CGFloat(aspect.width),height:CGFloat(aspect.height),showPrice:false,separateBody:true,knowledge:true)
            func region(_ image:CGImage,_ rect:CGRect)throws->String {
                try hash(XCTUnwrap(image.cropping(to:CGRect(x:rect.minX,y:CGFloat(image.height)-rect.maxY,width:rect.width,height:rect.height))))
            }
            XCTAssertNotEqual(try region(before,layout.visual),try region(after,layout.visual))
            for rect in [layout.captionBackground,layout.cta,layout.footer,layout.mediaBody] {
                XCTAssertEqual(try region(before,rect),try region(after,rect))
                XCTAssertFalse(layout.visual.intersects(rect))
            }
            if aspect == .landscape {XCTAssertEqual(layout.visual.height,316)}
        }
    }
}
