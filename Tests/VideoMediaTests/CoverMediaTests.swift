import XCTest
import CoreGraphics
import ImageIO
import CoreText
import VideoCore
@testable import VideoMedia

final class CoverMediaTests:XCTestCase {
    private func gameFootOriginal(padding:Int=0)throws->CGImage {
        let width=100+padding*2,height=200+padding*2,space=CGColorSpace(name:CGColorSpace.sRGB)!
        let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x:0,y:0,width:width,height:height));context.translateBy(x:CGFloat(padding),y:CGFloat(padding))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])))
        context.fill(CGRect(x:10,y:40,width:80,height:160))
        context.fill(CGRect(x:20,y:0,width:16,height:40));context.fill(CGRect(x:64,y:0,width:16,height:40))
        return try XCTUnwrap(context.makeImage())
    }
    func testGameContactShadowActuallyGroundsFeetAndLeavesHeadOutlineAndTitleClean()throws {
        try assertRGBAFixture()
        let hero=try gameFootOriginal(),tight=try CoverPainter.visibleArtwork(hero)
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let white=try XCTUnwrap(CGContext(data:nil,width:1280,height:720,bitsPerComponent:8,bytesPerRow:5120,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        white.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,1,1,1])));white.fill(CGRect(x:0,y:0,width:1280,height:720))
        let scene=try XCTUnwrap(white.makeImage())
        for aspect in [Aspect.landscape,.portrait] {
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:.game,template:template,title:"合作还是背叛？",hero:CoverImage(assetID:"hero"),background:CoverImage(assetID:"scene"),emphasis:["背叛"])
                let source=try bitmap(width:aspect.width,height:aspect.height)
                let rendered=try CoverPainter.image(revision:value,source:source,images:["hero":hero,"scene":scene])
                value.coverPresentation?.hero=nil
                let background=try CoverPainter.image(revision:value,source:source,images:["scene":scene])
                let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                let d=CGFloat(min(aspect.width,aspect.height)),canvas=CGRect(x:0,y:0,width:aspect.width,height:aspect.height)
                let square=CGRect(x:(canvas.width-d)/2,y:(canvas.height-d)/2,width:d,height:d)
                let variant=template == .editorial ? 1:(template == .contrast ? 2:0)
                let layout=CoverPainter.gameDepthLayout(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds,heroAspect:CGFloat(tight.width)/CGFloat(tight.height))
                let shadow=try CoverPainter.gameContactShadowRect(artwork:tight,placement:layout.hero)
                XCTAssertLessThan(shadow.width,layout.hero.width,"接触范围应来自实际双脚，不能直接取整个上身宽度")
                let raw=try pixels(rendered),plain=try pixels(background)
                // The admitted board is in front of both actor and shadow.
                // Its genuine alpha determines where a foot is still exposed;
                // a completely covered foot must not be made visible on top.
                let paper=CoverPainter.gameDialogueBubble(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds)
                let board=try XCTUnwrap(CGContext(data:nil,width:aspect.width,height:aspect.height,bitsPerComponent:8,
                    bytesPerRow:aspect.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                board.clear(canvas);board.setFillColor(CGColor(gray:1,alpha:1));board.fill(paper)
                board.draw(try CommunityNoticeBoardArtwork.image(),in:CoverPainter.gameNoticeBoardImageFrame(
                    square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds))
                let foreground=try pixels(XCTUnwrap(board.makeImage()))
                func rgba(_ bytes:[UInt8],_ point:CGPoint)->[UInt8] {
                    let x=Int(point.x),y=aspect.height-1-Int(point.y),at=(y*aspect.width+x)*4
                    return Array(bytes[at..<(at+4)])
                }
                for fraction in [CGFloat(0.15),0.30,0.45] {
                    let underFoot=CGPoint(x:shadow.midX,y:shadow.minY+shadow.height*fraction)
                    let footPixel=rgba(raw,underFoot),plainPixel=rgba(plain,underFoot)
                    let alpha=Int(rgba(foreground,underFoot)[3])
                    if alpha==0 {
                        XCTAssertLessThan(Int(footPixel[0])+Int(footPixel[1])+Int(footPixel[2]),Int(plainPixel[0])+Int(plainPixel[1])+Int(plainPixel[2])-20,"未被公告板遮挡的实际脚底下方须有可观察的接触影")
                    } else if alpha==255 {
                        XCTAssertEqual(footPixel,plainPixel,"完全不透明的公告板纸面必须盖过脚和接触影")
                    } else {
                        // Source-over can reveal at most the true residual
                        // transmission, plus one byte of rounding.
                        for channel in 0..<3 {
                            XCTAssertLessThanOrEqual(abs(Int(footPixel[channel])-Int(plainPixel[channel])),256-alpha,
                                "木边必须按原图真实透明度覆盖角色与脚影，不能把影重画到公告板前")
                        }
                    }
                }
                var exposedActor=0
                for fraction in [CGFloat(0.50),0.65,0.80,0.95] {
                    let point=CGPoint(x:layout.hero.midX,y:layout.hero.minY+layout.hero.height*fraction)
                    if rgba(foreground,point)[3]==0 {
                        XCTAssertEqual(rgba(raw,point),[255,0,0,255],"接触影不能重染未遮挡的原角色不透明像素")
                        exposedActor+=1
                    }
                }
                XCTAssertGreaterThan(exposedActor,0,"公告板前景不能把真实角色全部遮掉")
                let besideHead=CGPoint(x:layout.hero.maxX+2,y:layout.hero.minY+layout.hero.height*0.70)
                XCTAssertEqual(rgba(raw,besideHead),rgba(plain,besideHead),"头身外不得残留贴纸式均匀投影")
                let crop=CGRect(x:title.visibleBounds.minX,y:CGFloat(aspect.height)-title.visibleBounds.maxY,width:title.visibleBounds.width,height:title.visibleBounds.height)
                XCTAssertEqual(try pixels(XCTUnwrap(rendered.cropping(to:crop))),try pixels(XCTUnwrap(background.cropping(to:crop))),"足底影与原人物均不能污染完整居中标题")
            }
        }
    }
    func testGameContactShadowUsesActualFeetRatherThanTransparentCanvasMargins()throws {
        let original=try gameFootOriginal(),padded=try gameFootOriginal(padding:30)
        let scene=try bitmap(width:1280,height:720)
        for aspect in [Aspect.landscape,.portrait] {
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:.game,template:template,title:"合作还是背叛？",hero:CoverImage(assetID:"hero"),background:CoverImage(assetID:"scene"),emphasis:["背叛"])
                let source=try bitmap(width:aspect.width,height:aspect.height)
                let first=try CoverPainter.image(revision:value,source:source,images:["hero":original,"scene":scene])
                let second=try CoverPainter.image(revision:value,source:source,images:["hero":padded,"scene":scene])
                XCTAssertEqual(try pixels(first),try pixels(second),"只加透明边距时，正常生产的完整角色和足底接触影必须保持同位置")
            }
        }
    }
    func testGameContactShadowRejectsEmptyArtAndInvalidPlacementInsteadOfInventingFeet()throws {
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let context=try XCTUnwrap(CGContext(data:nil,width:80,height:120,bitsPerComponent:8,bytesPerRow:320,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x:0,y:0,width:80,height:120))
        let empty=try XCTUnwrap(context.makeImage()),hero=try gameFootOriginal()
        XCTAssertThrowsError(try CoverPainter.gameContactShadowRect(artwork:empty,placement:CGRect(x:100,y:100,width:80,height:120)))
        for invalid in [CGRect.zero,.null,.infinite] {
            XCTAssertThrowsError(try CoverPainter.gameContactShadowRect(artwork:hero,placement:invalid))
        }
    }
    func testPencilPairFitsBothCompleteOriginalsAroundActualTitleInAllCanvasShapes()throws {
        for (width,height) in [(1280.0,720.0),(720.0,1280.0),(720.0,720.0)] {
            let canvas=CGRect(x:0,y:0,width:width,height:height),d=CGFloat(min(width,height))
            let square=CGRect(x:(canvas.width-d)/2,y:(canvas.height-d)/2,width:d,height:d)
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision();value.coverPresentation=CoverPresentation(style:.pencil,template:template,title:"合作还是背叛？",emphasis:["背叛"])
                let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:canvas.width,height:canvas.height)
                let variant=template == .editorial ? 1:(template == .contrast ? 2:0)
                let primary=CoverPainter.pencilArtworkRect(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds,imageAspect:351.0/491)
                let counterpart=try CoverPainter.pencilCounterpartRect(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds,primary:primary,imageAspect:179.0/266)
                for rect in [primary,counterpart] {
                    XCTAssertTrue(canvas.contains(rect));XCTAssertFalse(rect.intersects(title.visibleBounds))
                    XCTAssertGreaterThan(rect.width*rect.height,canvas.width*canvas.height*0.01,"每个完整人物须有可观察区域，不能靠近零缩放冒充已显示")
                }
                XCTAssertFalse(primary.intersects(counterpart));XCTAssertEqual(counterpart.width/counterpart.height,179.0/266,accuracy:0.0001)
                XCTAssertTrue(title.safeRect.contains(title.visibleBounds))
                XCTAssertThrowsError(try CoverPainter.pencilCounterpartRect(square:square,canvas:canvas,variant:variant,titleBounds:canvas,primary:primary,imageAspect:1),"没有净空必须明确拒绝，不能丢掉作者第二原图")
            }
        }
    }
    func testPencilPairRendersWholeConnectedOriginalsWithoutTintingTitleOrFirstActor()throws {
        func marked(_ width:Int,_ height:Int,body:[CGFloat],corner:[CGFloat])throws->CGImage {
            let space=CGColorSpace(name:CGColorSpace.sRGB)!
            let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:body)));context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:corner)))
            for x in [0,width-width/5] {for y in [0,height-height/5] {context.fill(CGRect(x:x,y:y,width:width/5,height:height/5))}}
            return try XCTUnwrap(context.makeImage())
        }
        let first=try marked(351,491,body:[1,0,0,1],corner:[1,1,0,1])
        let second=try marked(179,266,body:[0,0,1,1],corner:[0,1,0,1])
        let changed=try marked(179,266,body:[1,0,1,1],corner:[0,1,0,1])
        for aspect in [Aspect.landscape,.portrait] {
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:.pencil,template:template,title:"合作还是背叛？",hero:CoverImage(assetID:"first"),background:CoverImage(assetID:"second"),emphasis:["背叛"])
                let source=try bitmap(width:aspect.width,height:aspect.height)
                let original=try CoverPainter.image(revision:value,source:source,images:["first":first,"second":second])
                let alternate=try CoverPainter.image(revision:value,source:source,images:["first":first,"second":changed])
                let raw=try pixels(original)
                func bounds(_ matches:(UInt8,UInt8,UInt8)->Bool)throws->CGRect {
                    var left=aspect.width,right = -1,top=aspect.height,bottom = -1
                    for y in 0..<aspect.height {for x in 0..<aspect.width {
                        let at=(y*aspect.width+x)*4
                        if matches(raw[at],raw[at+1],raw[at+2]) {left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)}
                    }}
                    XCTAssertGreaterThanOrEqual(right,left);XCTAssertGreaterThanOrEqual(bottom,top)
                    return CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1)
                }
                let primary=try bounds{$0>245 && $2<10}
                let counterpart=try bounds{($0<10 && $1<10 && $2>245) || ($0<10 && $1>245 && $2<10)}
                XCTAssertFalse(primary.intersects(counterpart))
                XCTAssertEqual(primary.width/primary.height,351.0/491,accuracy:0.025)
                XCTAssertEqual(counterpart.width/counterpart.height,179.0/266,accuracy:0.025)
                for (rect,kind) in [(primary,0),(counterpart,1)] {
                    for x in [rect.minX,rect.maxX-rect.width*0.12] {for y in [rect.minY,rect.maxY-rect.height*0.12] {
                        var markers=0
                        for py in Int(y)..<Int(y+rect.height*0.12) {for px in Int(x)..<Int(x+rect.width*0.12) {
                            let at=(py*aspect.width+px)*4
                            if raw[at+1]>245 && raw[at+2]<10 && (kind == 0 ? raw[at]>245:raw[at]<10) {markers+=1}
                        }}
                        XCTAssertGreaterThan(markers,2,"完整连接原图的四角标记都须实际可见，不能裁脚、裁帽或只返回几何")
                    }}
                }
                func region(_ image:CGImage,_ rect:CGRect)throws->[UInt8] {try pixels(XCTUnwrap(image.cropping(to:rect.integral)))}
                XCTAssertEqual(try region(original,primary),try region(alternate,primary),"替换第二原图不能改动第一角色像素")
                let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                let titleRaster=CGRect(x:title.visibleBounds.minX,y:CGFloat(aspect.height)-title.visibleBounds.maxY,width:title.visibleBounds.width,height:title.visibleBounds.height)
                XCTAssertEqual(try region(original,titleRaster),try region(alternate,titleRaster),"第二原图不得全画面均色污染居中主题")
            }
        }
    }
    func testPencilCounterpartHonorsNormalSourceRectAndRejectsMissingOriginal()throws {
        try assertRGBAFixture()
        let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
        let context=try XCTUnwrap(CGContext(data:nil,width:200,height:160,bitsPerComponent:8,bytesPerRow:800,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,0,1,1])));context.fill(CGRect(x:0,y:0,width:100,height:160))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,1,0,1])));context.fill(CGRect(x:100,y:0,width:100,height:160))
        let atlas=try XCTUnwrap(context.makeImage()),first=try bitmap(width:100,height:160,red:1,green:0,blue:0)
        for (x,expected) in [(0.0,[UInt8(0),0,255,255]),(0.5,[UInt8(0),255,0,255])] {
            let original=try MediaFramingRenderer.crop(atlas,framing:MediaFraming(x:x,y:0,width:0.5,height:1))
            let raw=try pixels(original),center=((original.height/2)*original.width+original.width/2)*4
            XCTAssertEqual(Array(raw[center..<center+4]),expected,"先确认源裁区的真实 sRGB 像素，再验证封面保持该裁区")
        }
        var value=try revision();value.coverPresentation=CoverPresentation(style:.pencil,title:"合作还是背叛？",hero:CoverImage(assetID:"first"),background:CoverImage(assetID:"atlas",sourceRect:MediaFraming(x:0,y:0,width:0.5,height:1)),emphasis:["背叛"])
        let source=try bitmap(width:1280,height:720),images=["first":first,"atlas":atlas]
        func count(_ image:CGImage,blue:Bool)throws->Int {
            let raw=try pixels(image)
            var result=0
            for index in stride(from:0,to:raw.count,by:4) {
                let red=raw[index],green=raw[index+1],value=raw[index+2]
                let selected=blue ? (green<10 && value>245):(green>245 && value<10)
                if red<10 && selected {result+=1}
            }
            return result
        }
        let left=try CoverPainter.image(revision:value,source:source,images:images)
        XCTAssertGreaterThan(try count(left,blue:true),500);XCTAssertEqual(try count(left,blue:false),0)
        value.coverPresentation?.background?.sourceRect=MediaFraming(x:0.5,y:0,width:0.5,height:1)
        let right=try CoverPainter.image(revision:value,source:source,images:images)
        XCTAssertEqual(try count(right,blue:true),0);XCTAssertGreaterThan(try count(right,blue:false),500)
        XCTAssertThrowsError(try CoverPainter.image(revision:value,source:source,images:["first":first]),"正常显式第二图缺失不能降级单人封面")
    }
    func testPresenterSharedSquareKeepsBothUpperSubjectBandsClearOfCenteredTitle()throws {
        for aspect in Aspect.allCases {
            let canvas=CGRect(x:0,y:0,width:aspect.width,height:aspect.height),d=CGFloat(min(aspect.width,aspect.height))
            let square=CGRect(x:canvas.midX-d/2,y:canvas.midY-d/2,width:d,height:d)
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                for headline in ["囚徒困境","豆子姐讲囚徒困境"] {
                    var value=try revision(aspect:aspect)
                    value.coverPresentation=CoverPresentation(style:.presenter,template:template,title:headline,emphasis:["囚徒困境"])
                    let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:canvas.width,height:canvas.height)
                    let variant=template == .editorial ? 1:(template == .contrast ? 2:0)
                    // Actual v4 nonzero-alpha silhouette: 1265 by 1217. Its
                    // face occupies the original upper band, independently
                    // of the hand/torso overlap allowed under the headline.
                    let hero=CoverPainter.presenterPlacement(square:square,variant:variant,titleBounds:title.visibleBounds,pointing:.left,imageAspect:1265.0/1217)
                    let subject=CoverPainter.presenterSubjectPlacement(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds,heroPlacement:hero,imageAspect:384.0/522)
                    XCTAssertTrue(square.insetBy(dx:d*0.01,dy:d*0.01).contains(hero.rect),"完整IP轮廓须进入中心方形，不能只保标题")
                    XCTAssertTrue(square.contains(subject),"真实故事人物须进入相同共享裁切区")
                    XCTAssertEqual(hero.rect.width/hero.rect.height,1265.0/1217,accuracy:0.0001)
                    XCTAssertEqual(subject.width/subject.height,384.0/522,accuracy:0.0001)
                    let head=CGRect(x:hero.rect.minX,y:hero.rect.minY+hero.rect.height*0.408,width:hero.rect.width,height:hero.rect.height*0.592)
                    let reaction=CGRect(x:subject.minX,y:subject.minY+subject.height*0.58,width:subject.width,height:subject.height*0.42)
                    XCTAssertFalse(head.intersects(title.visibleBounds),"原IP面部带不能被标题高亮遮住")
                    XCTAssertFalse(reaction.intersects(title.visibleBounds),"故事脸和帽子须在标题上方完整可辨")
                    XCTAssertGreaterThan(subject.height,d*0.40)
                    XCTAssertGreaterThan(CoverPainter.presenterStageTop(square:square,heroPlacement:hero),hero.rect.minY,"半身裁口应有真实前景遮挡，而非悬在空中")
                }
            }
        }
    }
    func testPresenterSharedSquareLayoutIsTheSameInLandscapePortraitAndSquare()throws {
        var canonical:[CGRect]=[]
        for size in [CGSize(width:1280,height:720),CGSize(width:720,height:1280),CGSize(width:720,height:720)] {
            let canvas=CGRect(origin:.zero,size:size),d=min(size.width,size.height)
            let square=CGRect(x:canvas.midX-d/2,y:canvas.midY-d/2,width:d,height:d)
            var value=try revision()
            value.coverPresentation=CoverPresentation(style:.presenter,title:"囚徒困境",emphasis:["囚徒困境"])
            let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:canvas.width,height:canvas.height)
            let hero=CoverPainter.presenterPlacement(square:square,variant:0,titleBounds:title.visibleBounds,pointing:.left,imageAspect:1265.0/1217)
            let subject=CoverPainter.presenterSubjectPlacement(square:square,canvas:canvas,variant:0,titleBounds:title.visibleBounds,heroPlacement:hero,imageAspect:384.0/522)
            let normalized=[hero.rect,subject].map{CGRect(x:($0.minX-square.minX)/d,y:($0.minY-square.minY)/d,width:$0.width/d,height:$0.height/d)}
            if canonical.isEmpty {canonical=normalized}
            else {for (a,b) in zip(canonical,normalized) {XCTAssertEqual(a.minX,b.minX,accuracy:0.005);XCTAssertEqual(a.minY,b.minY,accuracy:0.005);XCTAssertEqual(a.width,b.width,accuracy:0.005);XCTAssertEqual(a.height,b.height,accuracy:0.005)}}
        }
    }
    func testFullFigurePresenterReallyRetainsBootsAndFaceInSharedSquare()throws {
        let context=try XCTUnwrap(CGContext(data:nil,width:100,height:160,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x:0,y:0,width:100,height:160))
        context.setFillColor(CGColor(srgbRed:0.2,green:0.2,blue:0.2,alpha:1));context.fill(CGRect(x:35,y:15,width:30,height:120))
        context.setFillColor(CGColor(srgbRed:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:10,y:0,width:80,height:20))
        context.setFillColor(CGColor(srgbRed:1,green:0,blue:0,alpha:1));context.fill(CGRect(x:10,y:110,width:80,height:40))
        let source=try XCTUnwrap(context.makeImage()),tight=try CoverPainter.visibleArtwork(source),ratio=CGFloat(tight.width)/CGFloat(tight.height)
        for aspect in Aspect.allCases {
            var value=try revision(aspect:aspect)
            value.coverPresentation=CoverPresentation(style:.presenter,template:.spotlight,title:"囚徒困境",hero:CoverImage(assetID:"ip",pointing:.left,figureFraming:.fullFigure),emphasis:["囚徒困境"])
            let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
            let d=CGFloat(min(aspect.width,aspect.height)),square=CGRect(x:(CGFloat(aspect.width)-d)/2,y:(CGFloat(aspect.height)-d)/2,width:d,height:d)
            let placement=CoverPainter.presenterPlacement(square:square,variant:0,titleBounds:title.visibleBounds,pointing:.left,imageAspect:ratio,fullFigure:true)
            XCTAssertTrue(square.contains(placement.rect));XCTAssertEqual(placement.rect.width/placement.rect.height,ratio,accuracy:0.0001)
            let raw=try pixels(CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height),images:["ip":source]))
            func point(_ localY:CGFloat)->[UInt8] {let x=Int(placement.rect.midX),y=aspect.height-1-Int(placement.rect.minY+placement.rect.height*localY),at=(y*aspect.width+x)*4;return Array(raw[at..<(at+4)])}
            let feet=point(0.05),face=point(0.86)
            XCTAssertGreaterThan(feet[2],245);XCTAssertLessThan(feet[0],10,"完整人物声明必须保留实际脚部，不能仍走72%半身截取")
            XCTAssertGreaterThan(face[0],245);XCTAssertLessThan(face[1],10,"中心裁切内必须真实保留原上部像素")
        }
    }
    func testPresenterSubjectAlwaysPreservesCompleteProportionsInSharedCrop()throws {
        for aspect in Aspect.allCases {
            let canvas=CGRect(x:0,y:0,width:aspect.width,height:aspect.height),d=CGFloat(min(aspect.width,aspect.height))
            let square=CGRect(x:canvas.midX-d/2,y:canvas.midY-d/2,width:d,height:d)
            var value=try revision(aspect:aspect);value.coverPresentation=CoverPresentation(style:.presenter,title:"合作还是背叛？",emphasis:["背叛"])
            let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:canvas.width,height:canvas.height)
            for variant in 0...2 {
                let hero=CoverPainter.presenterPlacement(square:square,variant:variant,titleBounds:title.visibleBounds,pointing:.right,imageAspect:1.0)
                for sourceAspect in [0.5,384.0/522,1,2] {
                    let subject=CoverPainter.presenterSubjectPlacement(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds,heroPlacement:hero,imageAspect:sourceAspect)
                    XCTAssertTrue(square.contains(subject));XCTAssertEqual(subject.width/subject.height,sourceAspect,accuracy:0.0001)
                }
            }
        }
    }
    func testQuantitySpotlightFocusTracksMissingGroupAcrossCanvasShapesAndTemplates()throws {
        for (width,height) in [(1280.0,720.0),(720.0,720.0),(720.0,1280.0)] {
            let side=CGFloat(min(width,height))
            let square=CGRect(x:(CGFloat(width)-side)/2,y:(CGFloat(height)-side)/2,width:side,height:side)
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision()
                value.coverPresentation=CoverPresentation(style:.code,template:template,title:"少一枚，路就修不成？",
                    emphasis:["少一枚"],quantityGraphic:CoverQuantityGraphic(available:2,required:3))
                let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(width),height:CGFloat(height))
                let variant=template == .editorial ? 1:(template == .contrast ? 2:0)
                let slots=try CoverPainter.quantitySlots(square:square,titleBounds:title.visibleBounds,required:3,variant:variant)
                let oneMissing=try CoverPainter.quantitySpotlightFocus(slots:slots,available:2)
                XCTAssertEqual(oneMissing,slots[2],"缺一枚时，聚光只能以真实空位为中心")
                let manyMissing=try CoverPainter.quantitySpotlightFocus(slots:slots,available:1)
                XCTAssertTrue(manyMissing.contains(slots[1]) && manyMissing.contains(slots[2]),"多个空位应共同成为视觉焦点")
                XCTAssertFalse(manyMissing.contains(slots[0]),"已筹到的左侧实币不应冒充缺位范围")
                let none=try CoverPainter.quantitySpotlightFocus(slots:slots,available:0)
                let full=try CoverPainter.quantitySpotlightFocus(slots:slots,available:3)
                XCTAssertEqual(full,none,"无实币和全部筹齐均以整个已声明对象组为范围")
                XCTAssertTrue(slots.allSatisfy{full.contains($0)},"完整聚光范围须包含各槽外边界：\(width)×\(height)，\(template.rawValue)")
                for available in 0...3 {
                    let focus=try CoverPainter.quantitySpotlightFocus(slots:slots,available:available)
                    XCTAssertTrue(square.contains(focus));XCTAssertFalse(focus.intersects(title.visibleBounds))
                    let light=try CoverPainter.quantitySpotlightEnvelope(focus:focus,square:square,titleBounds:title.visibleBounds)
                    XCTAssertTrue(light.contains(focus),"柔光须覆盖实际缺位联合范围，不能压扁到只剩一条光线")
                    XCTAssertLessThan(light.maxY,title.visibleBounds.minY,"径向光须在标题下方自然归零，不依赖矩形截光")
                    XCTAssertFalse(light.intersects(title.visibleBounds))
                    XCTAssertEqual(light.midX,focus.midX,accuracy:0.0001)
                    XCTAssertEqual(light.midY,focus.midY,accuracy:0.0001)
                }
            }
        }
    }
    func testQuantitySpotlightFocusPreservesLayoutCoordinatesAndRejectsInvalidCounts()throws {
        let slots=[CGRect(x:20,y:30,width:50,height:50),CGRect(x:90,y:55,width:50,height:50),CGRect(x:160,y:80,width:50,height:50)]
        let original=slots
        for available in 0...3 {
            let focus=try CoverPainter.quantitySpotlightFocus(slots:slots,available:available)
            let moved=slots.map{$0.offsetBy(dx:83,dy:-17)}
            XCTAssertEqual(try CoverPainter.quantitySpotlightFocus(slots:moved,available:available),focus.offsetBy(dx:83,dy:-17),"移动对象组后焦点须跟随实际对象，而非固定画布位置")
            let doubled=slots.map{CGRect(x:$0.minX*2,y:$0.minY*2,width:$0.width*2,height:$0.height*2)}
            XCTAssertEqual(try CoverPainter.quantitySpotlightFocus(slots:doubled,available:available),
                CGRect(x:focus.minX*2,y:focus.minY*2,width:focus.width*2,height:focus.height*2))
        }
        XCTAssertEqual(slots,original,"光色布局不得移动或缩放真实数量物")
        let fractional=[CGRect(x:0.1,y:0.2,width:0.2,height:0.3),CGRect(x:0.4,y:0.6,width:0.3,height:0.2)]
        let enclosing=try CoverPainter.quantitySpotlightFocus(slots:fractional,available:0)
        XCTAssertTrue(fractional.allSatisfy{enclosing.contains($0)},"小数坐标重建后仍须包含对象外边界，不能只近似包含")
        XCTAssertThrowsError(try CoverPainter.quantitySpotlightFocus(slots:slots,available:-1))
        XCTAssertThrowsError(try CoverPainter.quantitySpotlightFocus(slots:slots,available:4))
        XCTAssertThrowsError(try CoverPainter.quantitySpotlightFocus(slots:[],available:0))
        XCTAssertThrowsError(try CoverPainter.quantitySpotlightFocus(slots:[.zero],available:0))
        XCTAssertThrowsError(try CoverPainter.quantitySpotlightFocus(slots:[.infinite],available:0))
    }
    func testQuantitySpotlightChangesBackdropWithoutChangingTitleOrAvailableCoinPixels()throws {
        for aspect in [Aspect.landscape,.portrait] {
            var value=try revision(aspect:aspect)
            value.coverPresentation=CoverPresentation(style:.code,template:.spotlight,title:"少一枚，路就修不成？",
                emphasis:["少一枚"],quantityGraphic:CoverQuantityGraphic(available:2,required:3))
            let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
            let side=CGFloat(min(aspect.width,aspect.height))
            let square=CGRect(x:(CGFloat(aspect.width)-side)/2,y:(CGFloat(aspect.height)-side)/2,width:side,height:side)
            let slots=try CoverPainter.quantitySlots(square:square,titleBounds:title.visibleBounds,required:3)
            let source=try bitmap(width:aspect.width,height:aspect.height)
            let missing=try CoverPainter.image(revision:value,source:source)
            value.coverPresentation?.quantityGraphic?.available=3
            let funded=try CoverPainter.image(revision:value,source:source)
            func region(_ image:CGImage,_ rect:CGRect)throws->[UInt8] {
                let top=CGRect(x:rect.minX,y:CGFloat(image.height)-rect.maxY,width:rect.width,height:rect.height).integral
                return try pixels(XCTUnwrap(image.cropping(to:top)))
            }
            XCTAssertEqual(try region(missing,title.visibleBounds),try region(funded,title.visibleBounds),"筹款数量改变时保持同一完整标题、字号和深色背景")
            value.coverPresentation?.quantityGraphic=nil
            let studio=try CoverPainter.image(revision:value,source:source)
            // The top corners are outside both the quantity light and the
            // non-quantity programming symbols. They retain the same studio
            // lighting that gives the existing code template spatial depth.
            for x in [CGFloat(10),CGFloat(aspect.width)-20] {
                let corner=CGRect(x:x,y:CGFloat(aspect.height)-20,width:10,height:10)
                XCTAssertEqual(try region(missing,corner),try region(studio,corner),"缺位聚光须叠在原工作室光色之上，不能移除共有的空间背景")
                XCTAssertEqual(try region(funded,corner),try region(studio,corner))
            }
            for slot in slots.prefix(2) {
                let center=CGRect(x:slot.midX-5,y:slot.midY-5,width:10,height:10)
                XCTAssertEqual(try region(missing,center),try region(funded,center),"焦点光色不能重绘已有金币的真实金属表面")
            }
            let backdrop=CGRect(x:slots[2].maxX+side*0.015,y:slots[2].midY-5,width:10,height:10)
            XCTAssertNotEqual(try region(missing,backdrop),try region(funded,backdrop),"聚光须真正跟随缺位改变背景，而非只返回几何描述")
        }
    }
    func testQuantityGraphicRendersExactObjectsAndKeepsCommonCropClearOfTitle()throws {
        func gold(_ image:CGImage,slot:CGRect)throws->Int {
            let top=CGRect(x:slot.minX,y:CGFloat(image.height)-slot.maxY,width:slot.width,height:slot.height).insetBy(dx:5,dy:5)
            let crop=try XCTUnwrap(image.cropping(to:top)),raw=try pixels(crop)
            return stride(from:0,to:raw.count,by:4).filter{raw[$0]>180 && raw[$0+1]>100 && raw[$0+2]<140}.count
        }
        func thumbnail(_ image:CGImage)throws->CGImage {
            let width=image.width/4,height=image.height/4
            let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return try XCTUnwrap(context.makeImage())
        }
        for aspect in [Aspect.landscape,.portrait] {
            var variants=Set<String>()
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:.code,template:template,title:"少一枚，路就修不成？",
                    emphasis:["少一枚"],quantityGraphic:CoverQuantityGraphic(available:2,required:3))
                let resolved=try CoverRules.resolved(revision:value)
                let title=try CoverPainter.composeTitle(cover:resolved,width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                let side=CGFloat(min(aspect.width,aspect.height))
                let square=CGRect(x:(CGFloat(aspect.width)-side)/2,y:(CGFloat(aspect.height)-side)/2,width:side,height:side)
                let variant=template == .editorial ? 1:(template == .contrast ? 2:0)
                let slots=try CoverPainter.quantitySlots(square:square,titleBounds:title.visibleBounds,required:3,variant:variant)
                XCTAssertEqual(slots.count,3);XCTAssertTrue(title.safeRect.contains(title.visibleBounds))
                for (index,slot) in slots.enumerated() {
                    XCTAssertTrue(square.contains(slot),"全部真实对象须保留在横竖共用的方形裁切区")
                    XCTAssertFalse(slot.intersects(title.visibleBounds),"数量图形不能压住唯一标题")
                    for other in slots.dropFirst(index+1) {XCTAssertFalse(slot.intersects(other))}
                }
                let source=try bitmap(width:aspect.width,height:aspect.height)
                let short=try CoverPainter.image(revision:value,source:source)
                variants.insert(Codec.hash(Data(try pixels(short))))
                XCTAssertGreaterThan(try gold(short,slot:slots[0]),100)
                XCTAssertGreaterThan(try gold(short,slot:slots[1]),100)
                XCTAssertEqual(try gold(short,slot:slots[2]),0,"缺的一枚只绘空槽，不能冒充已筹到")
                value.coverPresentation?.quantityGraphic?.available=3
                let full=try CoverPainter.image(revision:value,source:source)
                XCTAssertGreaterThan(try gold(full,slot:slots[2]),100,"仅真实available变化就须补上对应金币")
                XCTAssertEqual(try gold(short,slot:slots[0]),try gold(full,slot:slots[0]))
                let reducedShort=try thumbnail(short),reducedFull=try thumbnail(full)
                for (index,slot) in slots.enumerated() {
                    let reduced=CGRect(x:slot.minX/4,y:slot.minY/4,width:slot.width/4,height:slot.height/4)
                    if index<2 {
                        XCTAssertGreaterThan(try gold(reducedShort,slot:reduced),25,"广告缩略图仍须读出两枚实际金币")
                    } else {
                        XCTAssertEqual(try gold(reducedShort,slot:reduced),0,"缩略后的凹槽仍为空缺，不能被金属高光冒充已筹金额")
                        XCTAssertGreaterThan(try gold(reducedFull,slot:reduced),25,"真实补齐后缩略图须显示第三枚金币")
                    }
                }
                for count in 1...8 {
                    let bounded=try CoverPainter.quantitySlots(square:square,titleBounds:title.visibleBounds,required:count,variant:variant)
                    XCTAssertEqual(bounded.count,count);XCTAssertTrue(bounded.allSatisfy{square.contains($0) && !$0.intersects(title.visibleBounds)})
                }
            }
            XCTAssertEqual(variants.count,3,"同一真实数量和标题的三模板须保持不同几何排布")
        }
    }
    func bitmap(width:Int,height:Int,red:CGFloat=0.1,green:CGFloat=0.5,blue:CGFloat=0.6)throws->CGImage {
        let c=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(red:red,green:green,blue:blue,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
        return try XCTUnwrap(c.makeImage())
    }
    func revision(aspect:Aspect = .landscape)throws->Revision {
        try Planner.create(workspaceID:"w",name:"囚徒困境",aspect:aspect,scenes:[Scene(title:"选择与后果",body:"观察两人的选择",durationFrames:30)])
    }
    func pixels(_ image:CGImage)throws->[UInt8] {
        let c=try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        c.setBlendMode(.copy);c.interpolationQuality = .none
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        c.flush()
        let snapshot=try XCTUnwrap(c.makeImage()),raw=try XCTUnwrap(snapshot.dataProvider?.data)
        XCTAssertEqual(snapshot.alphaInfo,.premultipliedLast);XCTAssertEqual(snapshot.bitmapInfo.intersection(.byteOrderMask),.byteOrder32Big)
        XCTAssertEqual(snapshot.bytesPerRow,image.width*4);XCTAssertEqual(CFDataGetLength(raw),image.width*image.height*4)
        return Array(raw as Data)
    }
    func assertRGBAFixture()throws {
        let expected:[UInt8]=[255,0,0,255,0,255,0,255,0,0,255,255,32,64,96,128]
        let provider=try XCTUnwrap(CGDataProvider(data:Data(expected) as CFData))
        let image=try XCTUnwrap(CGImage(width:4,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:16,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        XCTAssertEqual(try pixels(image),expected,"先验证固定RGBA与半透明像素的实际读回，禁止用错误通道解释内容丢失")
    }
    func testEveryStyleHasThreeDeterministicLayoutsInBothAspects()throws {
        XCTAssertEqual(CoverPainter.displayTitle("豆子姐讲「囚徒困境」",style:.presenter),"豆子姐讲\n囚徒困境")
        XCTAssertEqual(CoverPainter.displayTitle("豆子姐讲「囚徒困境」",style:.pencil),"豆子姐讲囚徒困境")
        XCTAssertEqual(CoverPainter.displayTitle("『合作』还是「背叛」？",style:.code),"合作还是背叛？")
        let phrase="人人都想省钱，路就修不成？",phraseText=phrase as NSString
        let forbidden=phraseText.range(of:"不成").location+1
        XCTAssertFalse(CoverPainter.titleArrangements(phrase).contains{$0.ranges.dropLast().contains{NSMaxRange($0)==forbidden}},"否定短语不能在不字后断开")
        for aspect in [Aspect.landscape,.portrait] {
            var value=try revision(aspect:aspect)
            value.coverPresentation=CoverPresentation(style:.code,title:phrase,emphasis:["不成"])
            let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
            let lines=title.lines.map{line -> String in let r=CTLineGetStringRange(line);return phraseText.substring(with:NSRange(location:r.location,length:r.length))}
            XCTAssertEqual(lines,["人人都想省钱，","路就修不成？"],"先按真实中文逗号分短语，再均衡字号，不能只贪心填满行宽")
            XCTAssertTrue(title.safeRect.contains(title.visibleBounds))
        }
        for aspect in [Aspect.landscape,.portrait] {
            let source=try bitmap(width:aspect.width,height:aspect.height)
            var styleHashes=Set<String>()
            for style in CoverStyle.allCases where style != .automatic {
                var hashes=Set<String>()
                for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                    var value=try revision(aspect:aspect)
                    value.coverPresentation=CoverPresentation(style:style,template:template,title:style == .presenter ? "豆子姐讲「囚徒困境」":"合作还是背叛？",subtitle:"每一次选择，都有代价")
                    let image=try CoverPainter.image(revision:value,source:source)
                    XCTAssertEqual(value.coverPresentation?.title,style == .presenter ? "豆子姐讲「囚徒困境」":"合作还是背叛？","标题换行只影响绘制，不改保存原文")
                    XCTAssertEqual(image.width,aspect.width);XCTAssertEqual(image.height,aspect.height)
                    let bytes=try ScenePainter.png(image)
                    XCTAssertEqual(bytes,try ScenePainter.png(CoverPainter.image(revision:value,source:source)))
                    XCTAssertNotEqual(bytes,try ScenePainter.png(source))
                    hashes.insert(Codec.hash(bytes));styleHashes.insert(Codec.hash(bytes))
                }
                XCTAssertEqual(hashes.count,3,"style=\(style.rawValue), aspect=\(aspect.rawValue)：同类型三个模板须有真实结构差异；不代表艺术效果已审")
            }
            XCTAssertEqual(styleHashes.count,24,"aspect=\(aspect.rawValue)：八种风格各三个确定性模板，不借规则检查声称视觉通过")
        }
    }
    func testCroppedImportedBitmapChangesCoverAndMissingImageCannotFallback()throws {
        let atlas=try bitmap(width:100,height:100,red:1,green:0,blue:0)
        var value=try revision();value.coverPresentation=CoverPresentation(style:.presenter,title:"豆子姐讲「囚徒困境」",hero:CoverImage(assetID:"ip",sourceRect:MediaFraming(x:0,y:0,width:0.5,height:0.5)))
        let source=try bitmap(width:1280,height:720)
        XCTAssertThrowsError(try CoverPainter.image(revision:value,source:source))
        let composed=try CoverPainter.image(revision:value,source:source,images:["ip":atlas])
        let alternate=try bitmap(width:1280,height:720,red:0.8,green:0.1,blue:0.9)
        for template in [CoverTemplate.spotlight,.editorial,.contrast] {
            value.coverPresentation?.template=template
            let clean=try ScenePainter.png(CoverPainter.image(revision:value,source:source,images:["ip":atlas]))
            XCTAssertEqual(clean,try ScenePainter.png(CoverPainter.image(revision:value,source:alternate,images:["ip":atlas])),"独立IP无显式背景时不能残留视频里的旧脸或字幕")
            value.coverPresentation?.background=CoverImage(assetID:"background")
            let explicit=try ScenePainter.png(CoverPainter.image(revision:value,source:source,images:["ip":atlas,"background":alternate]))
            XCTAssertNotEqual(clean,explicit,"作者显式选择的背景仍应参与合成")
            value.coverPresentation?.background=nil
        }
        value.coverPresentation?.hero=nil
        XCTAssertNotEqual(try ScenePainter.png(composed),try ScenePainter.png(CoverPainter.image(revision:value,source:source)))
        XCTAssertThrowsError(try CoverPainter.image(revision:value,source:atlas))
    }
    func testArtworkHasTypeSpecificScaleAndMediaFillsTheCanvas()throws {
        try assertRGBAFixture()
        func solid(_ components:[CGFloat])throws->CGImage {
            let space=CGColorSpace(name:CGColorSpace.sRGB)!
            let c=try XCTUnwrap(CGContext(data:nil,width:900,height:900,bitsPerComponent:8,bytesPerRow:3600,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:components)));c.fill(CGRect(x:0,y:0,width:900,height:900))
            return try XCTUnwrap(c.makeImage())
        }
        let magenta=try solid([1,0,1,1]),cyan=try solid([0,1,1,1]),source=try bitmap(width:1280,height:720)
        var affected:[CoverStyle:Int]=[:]
        for style in CoverStyle.allCases where style != .automatic {
            var value=try revision();value.coverPresentation=CoverPresentation(style:style,template:.spotlight,title:"出钱修路",background:CoverImage(assetID:"content"),emphasis:["修路"])
            let first=try pixels(CoverPainter.image(revision:value,source:source,images:["content":magenta]))
            let second=try pixels(CoverPainter.image(revision:value,source:source,images:["content":cyan]))
            var changed=0
            for offset in stride(from:0,to:first.count,by:4) {
                if abs(Int(first[offset])-Int(second[offset]))>20 || abs(Int(first[offset+1])-Int(second[offset+1]))>20 {changed+=1}
            }
            affected[style]=changed
            if style == .code {
                XCTAssertEqual(changed,0,"代码主题封面使用可复用岛屿组件，不能重新铺入无关作者图片")
            } else {
                XCTAssertGreaterThan(changed,1280*720/25,"真实内容应是构图组成部分，不能缩成邮票：\(style)")
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(affected[.media]),1280*720*7/10,"真实影像应大幅铺满；连续遮光不能退化成底部窄图条")
        XCTAssertGreaterThan(try XCTUnwrap(affected[.pencil]),1280*720*12/100,"彩铅大故事组景应保实际素材可见面积")
        XCTAssertNotEqual(affected[.media],affected[.code],"类型间内容组织不同，不能只换背景色")
    }
    func testPencilArtworkRemainsVisibleWithoutPassingBehindTheCenteredHeadline()throws {
        let red=try bitmap(width:300,height:420,red:1,green:0,blue:0)
        let blue=try bitmap(width:300,height:420,red:0,green:0,blue:1)
        for aspect in [Aspect.landscape,.portrait] {
            let source=try bitmap(width:aspect.width,height:aspect.height)
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:.pencil,template:template,title:"合作还是背叛？",
                    hero:CoverImage(assetID:"subject"),emphasis:["背叛"])
                let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                XCTAssertTrue(title.safeRect.contains(title.visibleBounds))
                for bounds in title.bounds {XCTAssertEqual(bounds.midX,CGFloat(aspect.width)/2,accuracy:0.01,"主标题须保持视觉居中")}
                let first=try CoverPainter.image(revision:value,source:source,images:["subject":red])
                let second=try CoverPainter.image(revision:value,source:source,images:["subject":blue])
                let crop=CGRect(x:title.visibleBounds.minX,y:CGFloat(aspect.height)-title.visibleBounds.maxY,
                                width:title.visibleBounds.width,height:title.visibleBounds.height)
                XCTAssertEqual(try pixels(XCTUnwrap(first.cropping(to:crop))),try pixels(XCTUnwrap(second.cropping(to:crop))),
                               "替换真实主物不能改变标题区底像素；细节不能再穿过标题")
                let a=try pixels(first),b=try pixels(second)
                var changed=0
                for offset in stride(from:0,to:a.count,by:4) {
                    let redDifference=abs(Int(a[offset])-Int(b[offset]))
                    let blueDifference=abs(Int(a[offset+2])-Int(b[offset+2]))
                    if redDifference>100 || blueDifference>100 {changed+=1}
                }
                XCTAssertGreaterThan(changed,aspect.width*aspect.height/10,"标题留净区后真实主物仍须清楚可见，不能缩成邮票")
            }
        }
    }
    func testArtworkSeparatesOnlyThroughRealTransparencyAndKeepsConnectedImagesWhole()throws {
        try assertRGBAFixture()
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let c=try XCTUnwrap(CGContext(data:nil,width:200,height:120,bitsPerComponent:8,bytesPerRow:800,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        c.clear(CGRect(x:0,y:0,width:200,height:120))
        c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));c.fill(CGRect(x:10,y:10,width:108,height:100))
        c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,0,1,1])));c.fill(CGRect(x:140,y:10,width:50,height:100))
        let image=try XCTUnwrap(c.makeImage()),pair=try XCTUnwrap(CoverPainter.separatedArtwork(image))
        XCTAssertGreaterThan(pair.0.width,100,"左物体越过正中线时必须完整保留，不能二等分切下碎片")
        XCTAssertEqual(pair.0.width+pair.1.width,image.width)
        let left=try pixels(pair.0),right=try pixels(pair.1)
        XCTAssertEqual(stride(from:0,to:left.count,by:4).filter{left[$0+2]>240 && left[$0+3]>0}.count,0,"左侧原件不能混入右物体")
        XCTAssertEqual(stride(from:0,to:right.count,by:4).filter{right[$0]>240 && right[$0+3]>0}.count,0,"右侧原件不能带走左物体碎片")
        c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));c.fill(CGRect(x:10,y:0,width:180,height:1))
        XCTAssertNil(CoverPainter.separatedArtwork(try XCTUnwrap(c.makeImage())),"一条真实像素连接也不可以切断；无透明分隔则保整图")
        XCTAssertNil(CoverPainter.separatedArtwork(try bitmap(width:200,height:120)),"不透明图片不能猜测语义切成两半")
    }
    func testOnlyTitleUsesOfflineFontHighlightAndFitsBothPreviewCrops()throws {
        XCTAssertEqual(CoverTypeface.displayPostScriptName,"DOUYINSANSBOLD-GB")
        XCTAssertEqual(CoverDisplayTypeface.sourceBytes,1919404)
        XCTAssertEqual(CoverDisplayTypeface.sourceSHA256,"fbecfacdfac33982774e301073a8d357a09c698cd3134bb6ddec0f5bfc268fa1")
        XCTAssertEqual(CTFontCopyPostScriptName(try CoverTypeface.font(size:40)) as String,CoverTypeface.postScriptName)
        XCTAssertEqual(CTFontCopyPostScriptName(try CoverTypeface.displayFont(size:40)) as String,CoverTypeface.displayPostScriptName)
        for aspect in [Aspect.landscape,.portrait] {
            for style in CoverStyle.allCases where style != .automatic {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:style,title:"豆子姐讲「囚徒困境」",subtitle:"这一行必须只保存而不绘制",emphasis:["囚徒困境"])
                let resolved=try CoverRules.resolved(revision:value)
                let composition=try CoverPainter.composeTitle(cover:resolved,width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                XCTAssertFalse(composition.bounds.isEmpty);XCTAssertFalse(composition.highlights.isEmpty)
                XCTAssertEqual(composition.outline,0,"原加粗字库不得再加内侵描边堵住境等复杂汉字的字腔")
                XCTAssertEqual(composition.depth,0,"不再用多次位移字形制造挤出重影")
                var sizes=Set<Int>(),inkColors=Set<String>()
                for line in composition.lines {
                    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                        let attributes=CTRunGetAttributes(run) as NSDictionary
                        if let font=attributes[kCTFontAttributeName] as! CTFont? {
                            let expectedFont=[CoverStyle.game,.code].contains(style) ? "ChillRoundF":"DOUYINSANSBOLD-GB"
                            XCTAssertEqual(CTFontCopyPostScriptName(font) as String,expectedFont)
                            sizes.insert(Int((CTFontGetSize(font)*100).rounded()))
                        }
                        if let color=attributes[kCTForegroundColorAttributeName] as! CGColor? {inkColors.insert(String(describing:color.components))}
                    }
                }
                XCTAssertEqual(sizes.count,2,"主题词与标题其余文字须有真实字级对比")
                if style == .presenter {
                    let attributionSize=try XCTUnwrap(sizes.min()),topicSize=try XCTUnwrap(sizes.max())
                    XCTAssertGreaterThanOrEqual(Double(topicSize)/Double(attributionSize),1.5,
                                                "现有解说员署名须让主题先读，不能与主题争同等字级")
                }
                XCTAssertEqual(inkColors.count,2,"主题词与标题其余文字须有真实文字色对比")
                let expectedKeyword:[CoverStyle:[CGFloat]]=[.presenter:[7.0/255,22.0/255,56.0/255,1],
                    .pencil:[99.0/255,240.0/255,228.0/255,1],
                    .game:[17.0/255,126.0/255,112.0/255,1],.code:[17.0/255,126.0/255,112.0/255,1]]
                if let components=expectedKeyword[style] {
                    let space=CGColorSpace(name:CGColorSpace.sRGB)!
                    // Explicit source/design colors: island ink #725D42 and
                    // readable deep mint #117E70, independent of Palette.
                    let normal:[CGFloat]=[CoverStyle.game,.code].contains(style) ? [114.0/255,93.0/255,66.0/255,1]:[1,1,1,1]
                    let base=try XCTUnwrap(CGColor(colorSpace:space,components:normal))
                    let keyword=try XCTUnwrap(CGColor(colorSpace:space,components:components))
                    XCTAssertEqual(inkColors,Set([String(describing:base.components),String(describing:keyword.components)]),"岛屿主题使用暖棕与深薄荷字，广告主题保留原高对比文字色；不恢复黄底黑字")
                }
                let side=CGFloat(min(aspect.width,aspect.height)),w=CGFloat(aspect.width),h=CGFloat(aspect.height)
                let square=CGRect(x:(w-side)/2,y:(h-side)/2,width:side,height:side)
                let ww=min(w,h*16/9),hh=min(h,w*9/16),wide=CGRect(x:(w-ww)/2,y:(h-hh)/2,width:ww,height:hh)
                for bound in composition.bounds+composition.highlights+composition.effects {
                    XCTAssertTrue(square.contains(bound));XCTAssertTrue(wide.contains(bound));XCTAssertTrue(composition.safeRect.contains(bound))
                }
                XCTAssertEqual(composition.visibleBounds.midY,h/2,accuracy:0.01)
                for bound in composition.bounds {XCTAssertEqual(bound.midX,w/2,accuracy:0.01)}
                let firstImage=try CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height))
                let first=try ScenePainter.png(firstImage)
                if style == .presenter {
                    for highlight in composition.highlights {
                        let sourceRect=CGRect(x:highlight.minX,y:CGFloat(aspect.height)-highlight.maxY,width:highlight.width,height:highlight.height)
                        let crop=try XCTUnwrap(firstImage.cropping(to:sourceRect)),raw=try pixels(crop)
                        let coral=stride(from:0,to:raw.count,by:4).filter{raw[$0]==255 && raw[$0+1]==152 && raw[$0+2]==93}.count
                        let navy=stride(from:0,to:raw.count,by:4).filter{raw[$0]==7 && raw[$0+1]==22 && raw[$0+2]==56}.count
                        XCTAssertGreaterThan(coral,100,"实际主题范围须有可见高反差底色")
                        XCTAssertGreaterThan(navy,100,"实际主题字形须清楚绘制在底色上，不以空色块代标题")
                    }
                }
                if [CoverStyle.presenter,.pencil,.code].contains(style) {
                    let raw=try pixels(firstImage)
                    var yellow=0
                    for offset in stride(from:0,to:raw.count,by:4) {
                        let red=Int(raw[offset]),green=Int(raw[offset+1]),blue=Int(raw[offset+2])
                        if red>230 && green>190 && blue<90 {yellow+=1}
                    }
                    XCTAssertEqual(yellow,0,"当前三种广告封面不得继续绘制被明确拒绝的黄色关键词底块")
                }
                value.coverPresentation?.subtitle="另一个不应出现在封面的历史副标题"
                let second=try ScenePainter.png(CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height)))
                XCTAssertEqual(first,second,"subtitle原文兼容，不得成为额外小字")
                value.coverPresentation?.emphasis=["豆子姐"]
                XCTAssertNotEqual(first,try ScenePainter.png(CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height))),"强调主题词须影响实际字级和主题文字色")
            }
        }
    }
    func testUnsupportedOrOverlongTitleCannotSilentlyClipOrUseMissingGlyphs()throws {
        for title in [String(repeating:"知识讲解",count:40),"知识\u{10FFFF}"] {
            var value=try revision();value.coverPresentation=CoverPresentation(title:title)
            XCTAssertThrowsError(try CoverPainter.image(revision:value,source:bitmap(width:1280,height:720)))
        }
        var value=try revision();value.coverPresentation=CoverPresentation(style:.presenter,title:"豆子姐讲「囚徒困境」",emphasis:["讲「囚徒"])
        let composition=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:1280,height:720)
        XCTAssertGreaterThanOrEqual(composition.highlights.count,2,"真实标题片段跨排版换行后仍在两行强调")
    }
    func testOriginalGameSceneFillsCanvasAndUsesNativeTopicBubble()throws {
        try assertRGBAFixture()
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let c=try XCTUnwrap(CGContext(data:nil,width:120,height:200,bitsPerComponent:8,bytesPerRow:480,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.clear(CGRect(x:0,y:0,width:120,height:200))
        c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));c.fill(CGRect(x:20,y:0,width:80,height:200))
        let hero=try XCTUnwrap(c.makeImage())
        let blue=try XCTUnwrap(CGContext(data:nil,width:1280,height:720,bitsPerComponent:8,bytesPerRow:5120,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        blue.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,0,1,1])));blue.fill(CGRect(x:0,y:0,width:1280,height:720))
        let background=try XCTUnwrap(blue.makeImage())
        for aspect in [Aspect.landscape,.portrait] {
            var short=try revision(aspect:aspect)
            short.coverPresentation=CoverPresentation(style:.game,title:"合作还是背叛？",emphasis:["背叛"])
            let composition=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:short),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
            XCTAssertEqual(composition.lines.count,1,"无换行、无逗号的短game题须优先单行，不能用不必要两行放大气泡遮人物")
            XCTAssertTrue(composition.safeRect.contains(composition.visibleBounds))
            XCTAssertEqual(composition.visibleBounds.midY,CGFloat(aspect.height)/2,accuracy:0.01)
            let d=CGFloat(min(aspect.width,aspect.height)),square=CGRect(x:(CGFloat(aspect.width)-d)/2,y:(CGFloat(aspect.height)-d)/2,width:d,height:d)
            for variant in 0..<3 {
                var current=short
                current.coverPresentation?.template=[CoverTemplate.spotlight,.editorial,.contrast][variant]
                let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:current),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                let canvas=CGRect(x:0,y:0,width:aspect.width,height:aspect.height)
                let paper=CoverPainter.gameDialogueBubble(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds)
                let board=CoverPainter.gameNoticeBoardFrame(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds)
                let artwork=CoverPainter.gameNoticeBoardImageFrame(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds)
                XCTAssertEqual(title.lines.count,1,"短标题仍须完整单行置于公告栏纸面")
                XCTAssertEqual(paper.width/paper.height,(0.518*1672)/(0.475*941),accuracy:0.001,"公告栏保持完整原图纸面的宽面比例")
                XCTAssertTrue(paper.contains(title.visibleBounds));XCTAssertTrue(board.contains(paper))
                XCTAssertTrue(canvas.contains(artwork),"公告栏整张原图不能为了塞入标题而被裁掉")
            }
            short.coverPresentation?.title="合作，还是背叛？"
            XCTAssertGreaterThan(try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:short),width:CGFloat(aspect.width),height:CGFloat(aspect.height)).lines.count,1,"含明确短语逗号仍按原合法断行策略")
        }
        for template in [CoverTemplate.spotlight,.editorial,.contrast] {
            var value=try revision();value.coverPresentation=CoverPresentation(style:.game,template:template,title:"选择与后果",hero:CoverImage(assetID:"hero"),background:CoverImage(assetID:"scene"))
            let image=try CoverPainter.image(revision:value,source:bitmap(width:1280,height:720),images:["hero":hero,"scene":background]),raw=try pixels(image)
            var red=0,bluePixels=0
            for offset in stride(from:0,to:raw.count,by:4) {
                let r=Int(raw[offset]),g=Int(raw[offset+1]),b=Int(raw[offset+2])
                if r>250 && g<5 && b<5 {red+=1}
                if r<5 && g<5 && b>250 {bluePixels+=1}
            }
            XCTAssertGreaterThan(red,100,"原透明角色保真实可见像素")
            XCTAssertGreaterThan(bluePixels,1280*720/2,"原场景须全幅而非缩进门户或照片卡片")
            for point in [(0,0),(1279,0),(0,719),(1279,719)] {
                let offset=(point.1*1280+point.0)*4
                XCTAssertLessThan(raw[offset],5);XCTAssertLessThan(raw[offset+1],5);XCTAssertGreaterThan(raw[offset+2],250)
            }
            let composition=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:1280,height:720)
            let square=CGRect(x:280,y:0,width:720,height:720),variant=template == .editorial ? 1:(template == .contrast ? 2:0)
            let layout=CoverPainter.gameDepthLayout(square:square,canvas:CGRect(x:0,y:0,width:1280,height:720),variant:variant,titleBounds:composition.visibleBounds)
            XCTAssertEqual(layout.aperture,CGRect(x:0,y:0,width:1280,height:720))
            XCTAssertTrue(layout.frontLip.isEmpty,"新默认不再凭空生成门户框沿或纸台")
            let bubble=CoverPainter.gameDialogueBubble(square:square,canvas:CGRect(x:0,y:0,width:1280,height:720),variant:variant,titleBounds:composition.visibleBounds)
            XCTAssertGreaterThanOrEqual(bubble.width/bubble.height,1.7,"社区公告栏须保留宽面大纸张，而非旧窄气泡")
            XCTAssertTrue(bubble.contains(composition.visibleBounds))
            let alternate=try CoverPainter.image(revision:value,source:bitmap(width:1280,height:720),
                images:["hero":hero,"scene":bitmap(width:1280,height:720,red:1,green:1,blue:0)])
            let interior=bubble.insetBy(dx:2,dy:2)
            let raster=CGRect(x:interior.minX,y:720-interior.maxY,width:interior.width,height:interior.height)
            let paperPixels=try pixels(XCTUnwrap(image.cropping(to:raster)))
            XCTAssertEqual(paperPixels,try pixels(XCTUnwrap(alternate.cropping(to:raster))),"整块公告纸与标题必须不透明，换场景也不能透底")
            let warmPaper=stride(from:0,to:paperPixels.count,by:4).filter {
                paperPixels[$0]>200 && paperPixels[$0+1]>190 && paperPixels[$0+2]>130
            }.count
            XCTAssertGreaterThan(warmPaper,10000,"原公告栏须真实绘制大面积浅暖色纸面，不能留下透明占位")
        }
    }
    func testGameNoticeAndTitleStayTogetherAboveEveryHeroInBothAspects()throws {
        // Contrasting originals expose an arm incorrectly repainted between
        // title paper and text. This checks real pixels, not a layer-name flag.
        try assertRGBAFixture()
        let red=try bitmap(width:120,height:200,red:1,green:0,blue:0)
        let blue=try bitmap(width:120,height:200,red:0,green:0,blue:1)
        let original=try ScenePainter.png(red)
        for aspect in [Aspect.landscape,.portrait] {
            var variants=Set<String>()
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:.game,template:template,title:"合作还是背叛？",
                    hero:CoverImage(assetID:"hero"),background:CoverImage(assetID:"scene"),emphasis:["背叛"])
                let source=try bitmap(width:aspect.width,height:aspect.height)
                let scene=try bitmap(width:aspect.width,height:aspect.height,red:0,green:1,blue:0)
                let first=try CoverPainter.image(revision:value,source:source,images:["hero":red,"scene":scene])
                let second=try CoverPainter.image(revision:value,source:source,images:["hero":blue,"scene":scene])
                variants.insert(Codec.hash(try ScenePainter.png(first)))
                let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                let d=CGFloat(min(aspect.width,aspect.height)),canvas=CGRect(x:0,y:0,width:aspect.width,height:aspect.height)
                let square=CGRect(x:(canvas.width-d)/2,y:(canvas.height-d)/2,width:d,height:d)
                let variant=template == .editorial ? 1:(template == .contrast ? 2:0)
                let paper=CoverPainter.gameDialogueBubble(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds)
                let board=CoverPainter.gameNoticeBoardFrame(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds)
                let layout=CoverPainter.gameDepthLayout(square:square,canvas:canvas,variant:variant,titleBounds:title.visibleBounds,heroAspect:0.6)
                XCTAssertTrue(board.contains(paper));XCTAssertTrue(paper.contains(title.visibleBounds))
                XCTAssertTrue(canvas.contains(board));XCTAssertTrue(layout.hero.intersects(paper))
                let a=try pixels(first),b=try pixels(second)
                // Protect the actual opaque paper, rather than inventing a
                // capsule around transparent cutouts of the retained original.
                let guardPath=CGPath(rect:paper.insetBy(dx:2,dy:2),transform:nil)
                var protected=0,changedOutside=0,wood=0,protectedMismatch=0
                for y in 0..<aspect.height {for x in 0..<aspect.width {
                    let at=(y*aspect.width+x)*4,point=CGPoint(x:CGFloat(x)+0.5,y:CGFloat(aspect.height-y)-0.5)
                    if guardPath.contains(point) {
                        if a[at] != b[at] || a[at+1] != b[at+1] || a[at+2] != b[at+2] || a[at+3] != b[at+3] {protectedMismatch+=1}
                        protected+=1
                    } else if abs(Int(a[at])-Int(b[at]))>100 || abs(Int(a[at+2])-Int(b[at+2]))>100 {changedOutside+=1}
                    if board.contains(point),!paper.contains(point),a[at]>100 && a[at+1]>75 && a[at+1]<235 && a[at+2]<175 {wood+=1}
                }}
                XCTAssertEqual(protectedMismatch,0,"标题及其公告板必须整体盖过原人物，拳头不能夹进字和底之间");XCTAssertGreaterThan(protected,10000);XCTAssertGreaterThan(wood,100,"原场景上应有实际木质公告板边缘，不以标题换名充数")
                XCTAssertGreaterThan(changedOutside,5000,"标题后仍须保留真实人物，不能通过删掉hero假装修好层次")
            }
            XCTAssertEqual(variants.count,3)
        }
        XCTAssertEqual(try ScenePainter.png(red),original,"公告板合成不能改写原人物像素")
    }
    func testPresenterActualSilhouetteHasStablePaddingAndWaistCutBehindForeground()throws {
        try assertRGBAFixture()
        func marked(width:Int,height:Int,padding:Int)throws->CGImage {
            let w=width+padding*2,h=height+padding*2
            let c=try XCTUnwrap(CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.clear(CGRect(x:0,y:0,width:w,height:h));c.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[1,0,0,1])!)
            c.fill(CGRect(x:padding,y:padding,width:width,height:height));return try XCTUnwrap(c.makeImage())
        }
        for dimensions in [(80,160),(160,80)] {
            let original=try marked(width:dimensions.0,height:dimensions.1,padding:0),padded=try marked(width:dimensions.0,height:dimensions.1,padding:24)
            let tight=try CoverPainter.presenterArtwork(CoverPainter.visibleArtwork(original)),ratio=CGFloat(tight.width)/CGFloat(tight.height)
            for aspect in [Aspect.landscape,.portrait] {
                for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                    var value=try revision(aspect:aspect)
                    value.coverPresentation=CoverPresentation(style:.presenter,template:template,title:"囚徒困境",hero:CoverImage(assetID:"hero",pointing:.left),emphasis:["囚徒困境"])
                    let first=try CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height),images:["hero":original])
                    XCTAssertEqual(try pixels(first),try pixels(CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height),images:["hero":padded])),"透明边距不能改变原IP的真实位置、比例或裁口")
                    let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                    let d=CGFloat(min(aspect.width,aspect.height)),square=CGRect(x:(CGFloat(aspect.width)-d)/2,y:(CGFloat(aspect.height)-d)/2,width:d,height:d)
                    let variant=template == .editorial ? 1:(template == .contrast ? 2:0)
                    let placement=CoverPainter.presenterPlacement(square:square,variant:variant,titleBounds:title.visibleBounds,pointing:.left,imageAspect:ratio)
                    XCTAssertTrue(square.contains(placement.rect));XCTAssertEqual(placement.rect.width/placement.rect.height,ratio,accuracy:0.0001)
                    let raw=try pixels(first),stage=CoverPainter.presenterStageTop(square:square,heroPlacement:placement)
                    func rgba(_ x:CGFloat,_ y:CGFloat)->ArraySlice<UInt8> {let at=((aspect.height-1-Int(y))*aspect.width+Int(x))*4;return raw[at..<(at+4)]}
                    let upper=Array(rgba(placement.rect.midX,placement.rect.maxY-d*0.025)),cut=Array(rgba(placement.rect.midX,placement.rect.minY+d*0.003))
                    XCTAssertGreaterThan(upper[0],245);XCTAssertLessThan(upper[1],10,"共享裁切内的原IP像素须实际保留")
                    XCTAssertFalse(cut[0]>245 && cut[1]<10 && cut[2]<10,"截断下缘应在讲台或标题前景后，而非露出红色悬空切线")
                    XCTAssertGreaterThan(stage,placement.rect.minY)
                }
            }
        }
    }
    func testPresenterGestureMirrorsActualPixelsTowardCenteredTitle()throws {
        try assertRGBAFixture()
        let c=try XCTUnwrap(CGContext(data:nil,width:120,height:200,bitsPerComponent:8,bytesPerRow:480,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.clear(CGRect(x:0,y:0,width:120,height:200))
        c.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[1,0,0,1])!);c.fill(CGRect(x:5,y:20,width:45,height:160))
        c.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[0,0,1,1])!);c.fill(CGRect(x:70,y:20,width:45,height:160))
        let hero=try XCTUnwrap(c.makeImage())
        for aspect in [Aspect.landscape,.portrait] {
            for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:.presenter,template:template,title:"豆子姐讲「囚徒困境」",hero:CoverImage(assetID:"pointing-right",pointing:.right),emphasis:["囚徒困境"])
                let title=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                let d=CGFloat(min(aspect.width,aspect.height)),square=CGRect(x:(CGFloat(aspect.width)-d)/2,y:(CGFloat(aspect.height)-d)/2,width:d,height:d)
                let variant=template == .editorial ? 1:(template == .contrast ? 2:0)
                let placement=CoverPainter.presenterPlacement(square:square,variant:variant,titleBounds:title.visibleBounds,pointing:.right)
                XCTAssertEqual(placement.renderedDirection(.right),placement.target)
                XCTAssertGreaterThanOrEqual(placement.rect.height,d*0.45,"保留可辨上半身，同时完整进入共享裁切区")
                XCTAssertGreaterThanOrEqual(placement.rect.width,d*0.30)
                let horizontalGap=max(0,max(title.visibleBounds.minX-placement.rect.maxX,placement.rect.minX-title.visibleBounds.maxX))
                XCTAssertLessThanOrEqual(horizontalGap,d*0.05,"大人物紧贴中心标题，不孤立在边角")
                let output=try CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height),images:["pointing-right":hero]),raw=try pixels(output)
                var redX=0.0,blueX=0.0,redCount=0,blueCount=0
                for offset in stride(from:0,to:raw.count,by:4) {
                    let x=Double((offset/4)%aspect.width)
                    if raw[offset]>250 && raw[offset+1]<5 && raw[offset+2]<5 {redX+=x;redCount+=1}
                    if raw[offset]<5 && raw[offset+1]<5 && raw[offset+2]>250 {blueX+=x;blueCount+=1}
                }
                XCTAssertGreaterThan(redCount,100);XCTAssertGreaterThan(blueCount,100)
                if redCount>0 && blueCount>0 {
                    let pointsRight=blueX/Double(blueCount)>redX/Double(redCount)
                    XCTAssertEqual(pointsRight,placement.target == .right,"按放置侧真正翻转原图像素，不只改方向标签")
                }
            }
        }
    }
    func testChartCoverUsesActualDeclaredValuesInsteadOfInventedBars()throws {
        var value=try revision()
        value.coverPresentation=CoverPresentation(style:.chart,template:.editorial,title:"合作的代价")
        var layer=SceneLayer(kind:.chart,endFrame:30)
        let first=DataSeries(id:"a",label:"合作",color:"6386D9",keyframes:[DataValueKeyframe(frame:0,value:2)])
        let second=DataSeries(id:"b",label:"背叛",color:"BDF176",keyframes:[DataValueKeyframe(frame:0,value:8)])
        layer.dataPresentation=DataPresentation(chart:DataChart(title:"结果",axisLabel:"代价",minimum:0,maximum:10,series:[first,second]))
        value.scenes[0].layers=[layer]
        let source=try bitmap(width:1280,height:720),original=try ScenePainter.png(CoverPainter.image(revision:value,source:source))
        value.scenes[0].layers?[0].dataPresentation?.chart?.series[0].keyframes[0].value=9
        XCTAssertNotEqual(original,try ScenePainter.png(CoverPainter.image(revision:value,source:source)),"实际业务数值变化应影响可见封面图形")
        // A code cover now has title copy only. Real code stays in the movie
        // and source project; no line or document screenshot becomes small copy.
        value.coverPresentation=CoverPresentation(style:.code,title:"人人都想省钱，路就修不成？",emphasis:["不成"])
        let code=CodePresentation(title:"不应成为额外封面小字",lines:["if sum(contributions) >= threshold:","    build_road()","else: keep_waiting()","# another hidden line"])
        var codeLayer=SceneLayer(kind:.code,endFrame:30)
        codeLayer.dataPresentation=DataPresentation(code:code)
        value.scenes[0].layers=[codeLayer]
        let codeImage=try ScenePainter.png(CoverPainter.image(revision:value,source:source))
        value.scenes[0].layers?[0].dataPresentation?.code?.title="另一个不应画的代码标题"
        value.scenes[0].layers?[0].dataPresentation?.code?.lines=["arbitrary_unrelated_text()","do_not_paint_any_of_this()"]
        XCTAssertEqual(codeImage,try ScenePainter.png(CoverPainter.image(revision:value,source:source)),"所有实际代码行与元数据均不得成为封面额外文字")
        value.coverPresentation?.title="为什么合作总是失败？";value.coverPresentation?.emphasis=["合作"]
        XCTAssertNotEqual(codeImage,try ScenePainter.png(CoverPainter.image(revision:value,source:source)),"只更换标题仍真实生成对应的新封面")
    }
    func testTransparentHeroUsesVisibleSilhouetteWithoutLeakingMoviePixels()throws {
        try assertRGBAFixture()
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let c=try XCTUnwrap(CGContext(data:nil,width:120,height:200,bitsPerComponent:8,bytesPerRow:480,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        c.clear(CGRect(x:0,y:0,width:120,height:200));c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));c.fillEllipse(in:CGRect(x:20,y:20,width:80,height:160))
        let hero=try XCTUnwrap(c.makeImage()),tight=try CoverPainter.visibleArtwork(hero)
        XCTAssertLessThanOrEqual(tight.width,80);XCTAssertLessThanOrEqual(tight.height,160)
        let upper=try CoverPainter.presenterArtwork(tight)
        XCTAssertLessThanOrEqual(upper.height,Int((CGFloat(tight.height)*0.72).rounded(.up)),"站姿肖像使用实际上半身裁切，不把完整小人塞回版位")
        XCTAssertGreaterThan(upper.width,0)
        let originalPixels=try pixels(hero),tightPixels=try pixels(tight)
        var originalAlpha=0,tightAlpha=0
        for offset in stride(from:3,to:originalPixels.count,by:4) where originalPixels[offset]>0 {originalAlpha+=1}
        for offset in stride(from:3,to:tightPixels.count,by:4) where tightPixels[offset]>0 {tightAlpha+=1}
        XCTAssertEqual(originalAlpha,tightAlpha,"只除全透明外边，不能裁掉任何非零alpha轮廓")
        c.clear(CGRect(x:0,y:0,width:120,height:200))
        XCTAssertThrowsError(try CoverPainter.visibleArtwork(try XCTUnwrap(c.makeImage())),"全透明原件不能冒可见IP")
        for aspect in [Aspect.landscape,.portrait] {
            for style in [CoverStyle.presenter,.game] {
                for template in [CoverTemplate.spotlight,.editorial,.contrast] {
                    var value=try revision(aspect:aspect);value.coverPresentation=CoverPresentation(style:style,template:template,title:"选择与后果",hero:CoverImage(assetID:"ip"))
                    let first=try CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height),images:["ip":hero])
                    let second=try CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height,red:1,green:0.5,blue:0),images:["ip":hero])
                    XCTAssertEqual(try ScenePainter.png(first),try ScenePainter.png(second),"透明IP不能触发无hero宽帧布局或透出旧视频字幕")
                    let raw=try pixels(first)
                    XCTAssertGreaterThan(stride(from:0,to:raw.count,by:4).filter{raw[$0]>240 && raw[$0+1]<15 && raw[$0+2]<15}.count,100,"原透明IP本体仍须有实际可见像素")
                }
            }
        }
    }
    func testCoverSourcesAndSettingsSurviveOrdinaryFullBackupAndRejectTamperedBytes()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cover-cas-"+UUID().uuidString)
        let restoredRoot=FileManager.default.temporaryDirectory.appendingPathComponent("cover-restored-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:restoredRoot)}
        let repository=try Repository(root:root),raw=try ScenePainter.png(bitmap(width:80,height:120,red:1,green:0.5,blue:0.1))
        let ip=try repository.ingest(raw,name:"cover-expression.png",workspaceID:"w",mediaType:"image/png")
        var value=try revision();value.coverPresentation=CoverPresentation(style:.presenter,template:.spotlight,title:"豆子姐讲「囚徒困境」",poses:[CoverPose(id:"curious",image:CoverImage(assetID:ip.id),expression:"好奇",action:"指向",keywords:["囚徒"])])
        value.dependencies=try DependencyRules.freeze(revision:value,assets:[ip],evidence:[])
        var workspace=Workspace(name:"封面恢复",owner:"owner");workspace.id="w"
        try repository.transaction{$0.workspaces=[workspace];$0.assets=[ip];$0.projects=[Project(workspaceID:"w",name:"囚徒困境",revision:value)]}
        let source=try bitmap(width:1280,height:720),images=try CoverPainter.loadImages(revision:value,repository:repository,database:repository.read())
        let expected=try ScenePainter.png(CoverPainter.image(revision:value,source:source,images:images))
        let restored=try Repository.restore(repository.backup(),to:restoredRoot),database=try restored.read()
        let actual=try ScenePainter.png(CoverPainter.image(revision:database.projects[0].current,source:source,images:CoverPainter.loadImages(revision:database.projects[0].current,repository:restored,database:database)))
        XCTAssertEqual(expected,actual);XCTAssertEqual(try Data(contentsOf:restored.assetURL(ip)),raw)
        try Data(repeating:0,count:raw.count).write(to:restored.assetURL(ip))
        XCTAssertThrowsError(try CoverPainter.loadImages(revision:database.projects[0].current,repository:restored,database:database))
    }
}
