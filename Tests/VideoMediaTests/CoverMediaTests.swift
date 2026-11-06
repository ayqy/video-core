import XCTest
import CoreGraphics
import ImageIO
import CoreText
import VideoCore
@testable import VideoMedia

final class CoverMediaTests:XCTestCase {
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
            XCTAssertGreaterThan(changed,1280*720/25,"真实内容应是构图组成部分，不能缩成邮票：\(style)")
        }
        XCTAssertGreaterThan(try XCTUnwrap(affected[.media]),1280*720*7/10,"真实影像应大幅铺满；连续遮光不能退化成底部窄图条")
        XCTAssertGreaterThan(try XCTUnwrap(affected[.pencil]),1280*720*12/100,"彩铅大故事组景应保实际素材可见面积")
        XCTAssertNotEqual(affected[.media],affected[.code],"类型间内容组织不同，不能只换背景色")
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
                            XCTAssertEqual(CTFontCopyPostScriptName(font) as String,CoverTypeface.displayPostScriptName)
                            sizes.insert(Int((CTFontGetSize(font)*100).rounded()))
                        }
                        if let color=attributes[kCTForegroundColorAttributeName] as! CGColor? {inkColors.insert(String(describing:color.components))}
                    }
                }
                XCTAssertEqual(sizes.count,2,"主题词与标题其余文字须有真实字级对比")
                XCTAssertEqual(inkColors.count,2,"主题词与标题其余文字须有真实文字色对比")
                let expectedKeyword:[CoverStyle:[CGFloat]]=[.presenter:[1,152.0/255,93.0/255,1],
                    .pencil:[99.0/255,240.0/255,228.0/255,1],.code:[80.0/255,227.0/255,218.0/255,1]]
                if let components=expectedKeyword[style] {
                    let space=CGColorSpace(name:CGColorSpace.sRGB)!
                    let white=try XCTUnwrap(CGColor(colorSpace:space,components:[1,1,1,1]))
                    let keyword=try XCTUnwrap(CGColor(colorSpace:space,components:components))
                    XCTAssertEqual(inkColors,Set([String(describing:white.components),String(describing:keyword.components)]),"常见广告高反差白字配橙/青主题字，不得恢复黄底黑字")
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
                let bubble=CoverPainter.gameDialogueBubble(square:square,canvas:CGRect(x:0,y:0,width:aspect.width,height:aspect.height),variant:variant,titleBounds:composition.visibleBounds)
                XCTAssertLessThan(bubble.height,d*0.19,"短题气泡按实际单行字高收紧，不保留原两行大气泡")
                XCTAssertTrue(bubble.contains(composition.visibleBounds))
            }
            short.coverPresentation?.title="合作，还是背叛？"
            XCTAssertGreaterThan(try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:short),width:CGFloat(aspect.width),height:CGFloat(aspect.height)).lines.count,1,"含明确短语逗号仍按原合法断行策略")
        }
        for template in [CoverTemplate.spotlight,.editorial,.contrast] {
            var value=try revision();value.coverPresentation=CoverPresentation(style:.game,template:template,title:"选择与后果",hero:CoverImage(assetID:"hero"),background:CoverImage(assetID:"scene"))
            let image=try CoverPainter.image(revision:value,source:bitmap(width:1280,height:720),images:["hero":hero,"scene":background]),raw=try pixels(image)
            var red=0,cream=0,bluePixels=0
            for offset in stride(from:0,to:raw.count,by:4) {
                let r=Int(raw[offset]),g=Int(raw[offset+1]),b=Int(raw[offset+2])
                if r>250 && g<5 && b<5 {red+=1}
                if abs(r-255)<3 && abs(g-251)<3 && abs(b-232)<3 {cream+=1}
                if r<5 && g<5 && b>250 {bluePixels+=1}
            }
            XCTAssertGreaterThan(red,100,"原透明角色保真实可见像素")
            XCTAssertGreaterThan(cream,10000,"题目使用原游戏式米白气泡，只有标题文字")
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
            XCTAssertGreaterThanOrEqual(bubble.width/bubble.height,3,"对话泡须宽扁，不能退回盖住场景的大圆泡")
            XCTAssertTrue(bubble.contains(composition.visibleBounds))
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
                XCTAssertGreaterThanOrEqual(placement.rect.height,d*0.90,"上半身构图须醒目，不再以小全身人像充数")
                XCTAssertGreaterThanOrEqual(placement.rect.width,d*0.70)
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
