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
        XCTAssertEqual(CoverPainter.displayTitle("豆子姐讲「囚徒困境」",style:.presenter),"豆子姐讲\n「囚徒困境」")
        XCTAssertEqual(CoverPainter.displayTitle("豆子姐讲「囚徒困境」",style:.pencil),"豆子姐讲「囚徒困境」")
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
                XCTAssertEqual(hashes.count,3,"同类型三个模板须有真实结构差异；不代表艺术效果已审")
            }
            XCTAssertEqual(styleHashes.count,24,"八种风格各三个确定性模板，不借规则检查声称视觉通过")
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
        XCTAssertEqual(CTFontCopyPostScriptName(try CoverTypeface.font(size:40)) as String,CoverTypeface.postScriptName)
        for aspect in [Aspect.landscape,.portrait] {
            for style in CoverStyle.allCases where style != .automatic {
                var value=try revision(aspect:aspect)
                value.coverPresentation=CoverPresentation(style:style,title:"豆子姐讲「囚徒困境」",subtitle:"这一行必须只保存而不绘制",emphasis:["囚徒困境"])
                let resolved=try CoverRules.resolved(revision:value)
                let composition=try CoverPainter.composeTitle(cover:resolved,width:CGFloat(aspect.width),height:CGFloat(aspect.height))
                XCTAssertFalse(composition.bounds.isEmpty);XCTAssertFalse(composition.highlights.isEmpty)
                var sizes=Set<Int>(),inkColors=Set<String>()
                for line in composition.lines {
                    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                        let attributes=CTRunGetAttributes(run) as NSDictionary
                        if let font=attributes[kCTFontAttributeName] as! CTFont? {
                            XCTAssertEqual(CTFontCopyPostScriptName(font) as String,CoverTypeface.postScriptName)
                            sizes.insert(Int((CTFontGetSize(font)*100).rounded()))
                        }
                        if let color=attributes[kCTForegroundColorAttributeName] as! CGColor? {inkColors.insert(String(describing:color.components))}
                    }
                }
                XCTAssertEqual(sizes.count,2,"主题词与标题其余文字须有真实字级对比")
                XCTAssertEqual(inkColors.count,2,"主题词与标题其余文字须有真实文字色对比")
                let side=CGFloat(min(aspect.width,aspect.height)),w=CGFloat(aspect.width),h=CGFloat(aspect.height)
                let square=CGRect(x:(w-side)/2,y:(h-side)/2,width:side,height:side)
                let ww=min(w,h*16/9),hh=min(h,w*9/16),wide=CGRect(x:(w-ww)/2,y:(h-hh)/2,width:ww,height:hh)
                for bound in composition.bounds+composition.highlights {
                    XCTAssertTrue(square.contains(bound));XCTAssertTrue(wide.contains(bound));XCTAssertTrue(composition.safeRect.contains(bound))
                }
                XCTAssertEqual(composition.visibleBounds.midY,h/2,accuracy:0.01)
                for bound in composition.bounds {XCTAssertEqual(bound.midX,w/2,accuracy:0.01)}
                let firstImage=try CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height))
                let first=try ScenePainter.png(firstImage)
                if style == .cartoon {
                    let raw=try pixels(firstImage)
                    var yellow=0
                    for offset in stride(from:0,to:raw.count,by:4) {
                        let red=Int(raw[offset]),green=Int(raw[offset+1]),blue=Int(raw[offset+2])
                        if abs(red-255)<3 && abs(green-229)<3 && abs(blue-109)<3 {yellow+=1}
                    }
                    XCTAssertGreaterThan(yellow,1000,"漫画白色爆发框中必须实际可见黄色荧光笔背景，不能白底叠白块")
                }
                value.coverPresentation?.subtitle="另一个不应出现在封面的历史副标题"
                let second=try ScenePainter.png(CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height)))
                XCTAssertEqual(first,second,"subtitle原文兼容，不得成为额外小字")
                value.coverPresentation?.emphasis=["豆子姐"]
                XCTAssertNotEqual(first,try ScenePainter.png(CoverPainter.image(revision:value,source:bitmap(width:aspect.width,height:aspect.height))),"强调主题词须影响实际字级、颜色和荧光笔背景")
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
    func testOriginalGameBackgroundAndSmallHeroRemainVisibleAcrossRim()throws {
        try assertRGBAFixture()
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let c=try XCTUnwrap(CGContext(data:nil,width:120,height:200,bitsPerComponent:8,bytesPerRow:480,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.clear(CGRect(x:0,y:0,width:120,height:200));c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));c.fill(CGRect(x:20,y:0,width:80,height:200))
        let hero=try XCTUnwrap(c.makeImage())
        let blue=try XCTUnwrap(CGContext(data:nil,width:1280,height:720,bitsPerComponent:8,bytesPerRow:5120,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        blue.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,0,1,1])));blue.fill(CGRect(x:0,y:0,width:1280,height:720))
        let background=try XCTUnwrap(blue.makeImage())
        for template in [CoverTemplate.spotlight,.editorial,.contrast] {
            var value=try revision();value.coverPresentation=CoverPresentation(style:.game,template:template,title:"选择与后果",hero:CoverImage(assetID:"hero"),background:CoverImage(assetID:"scene"))
            let image=try CoverPainter.image(revision:value,source:bitmap(width:1280,height:720),images:["hero":hero,"scene":background]),raw=try pixels(image)
            var red:[CGPoint]=[],bluePixels:[CGPoint]=[]
            for offset in stride(from:0,to:raw.count,by:4) {
                let point=CGPoint(x:(offset/4)%image.width,y:(offset/4)/image.width)
                if raw[offset]>240 && raw[offset+1]<15 && raw[offset+2]<15 {red.append(point)}
                if raw[offset]<15 && raw[offset+1]<15 && raw[offset+2]>240 {bluePixels.append(point)}
            }
            XCTAssertGreaterThan(red.count,100);XCTAssertGreaterThan(bluePixels.count,1000)
            XCTAssertLessThan(red.count,image.width*image.height/10,"人物是标题的辅助，小于整图十分之一")
            let minRed=try XCTUnwrap(red.map(\.y).min()),maxRed=try XCTUnwrap(red.map(\.y).max())
            let minBlue=try XCTUnwrap(bluePixels.map(\.y).min()),maxBlue=try XCTUnwrap(bluePixels.map(\.y).max())
            XCTAssertTrue(minRed<minBlue-5 || maxRed>maxBlue+5,"真实透明角色须有像素越过原景下边缘，不能只贴在照片里")
            let composition=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:value),width:1280,height:720)
            let square=CGRect(x:280,y:0,width:720,height:720),variant=template == .editorial ? 1:(template == .contrast ? 2:0)
            XCTAssertFalse(CoverPainter.auxiliaryRect(square:square,variant:variant).intersects(composition.visibleBounds),"小IP不可遮中心标题")
        }
    }
    func testTransparentHeroKeepsIndependentSmallLayoutInBothAspects()throws {
        try assertRGBAFixture()
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let c=try XCTUnwrap(CGContext(data:nil,width:120,height:200,bitsPerComponent:8,bytesPerRow:480,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        c.clear(CGRect(x:0,y:0,width:120,height:200));c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));c.fillEllipse(in:CGRect(x:20,y:20,width:80,height:160))
        let hero=try XCTUnwrap(c.makeImage())
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
