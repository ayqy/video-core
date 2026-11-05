import XCTest
import CoreGraphics
import ImageIO
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
    func testEveryStyleHasTwoDistinctDeterministicReadableTemplatesInBothAspects()throws {
        XCTAssertEqual(CoverPainter.displayTitle("豆子姐讲「囚徒困境」",style:.presenter),"豆子姐讲\n「囚徒困境」")
        XCTAssertEqual(CoverPainter.displayTitle("豆子姐讲「囚徒困境」",style:.pencil),"豆子姐讲「囚徒困境」")
        for aspect in [Aspect.landscape,.portrait] {
            let source=try bitmap(width:aspect.width,height:aspect.height)
            var styleHashes=Set<String>()
            for style in CoverStyle.allCases where style != .automatic {
                var hashes=Set<String>()
                for template in [CoverTemplate.spotlight,.editorial] {
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
                XCTAssertEqual(hashes.count,2,"同类型的两个模板必须有真实像素差异")
            }
            XCTAssertEqual(styleHashes.count,16,"八种风格的模板应保各自配色、布局或设计标识")
        }
    }
    func testCroppedImportedBitmapChangesCoverAndMissingImageCannotFallback()throws {
        let atlas=try bitmap(width:100,height:100,red:1,green:0,blue:0)
        var value=try revision();value.coverPresentation=CoverPresentation(style:.presenter,title:"豆子姐讲「囚徒困境」",hero:CoverImage(assetID:"ip",sourceRect:MediaFraming(x:0,y:0,width:0.5,height:0.5)))
        let source=try bitmap(width:1280,height:720)
        XCTAssertThrowsError(try CoverPainter.image(revision:value,source:source))
        let composed=try CoverPainter.image(revision:value,source:source,images:["ip":atlas])
        let alternate=try bitmap(width:1280,height:720,red:0.8,green:0.1,blue:0.9)
        for template in [CoverTemplate.spotlight,.editorial] {
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
    func testWideFrameKeepsCornerLabelsAndContentWithoutRepeatedEditorialBackground()throws {
        try assertRGBAFixture()
        func marked(_ width:Int,_ height:Int)throws->CGImage {
            let space=CGColorSpace(name:CGColorSpace.sRGB)!
            let c=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,1,1,1])));c.fill(CGRect(x:0,y:0,width:width,height:height))
            let components:[[CGFloat]]=[[1,0,0,1],[0,1,0,1],[0,0,1,1],[1,0,1,1]]
            let colors=try components.map{try XCTUnwrap(CGColor(colorSpace:space,components:$0))}
            for (index,point) in [CGPoint(x:0,y:0),CGPoint(x:width-64,y:0),CGPoint(x:0,y:height-64),CGPoint(x:width-64,y:height-64)].enumerated() {
                c.setFillColor(colors[index]);c.fill(CGRect(origin:point,size:CGSize(width:64,height:64)))
            }
            c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,1,0,1])));c.fill(CGRect(x:CGFloat(width)*0.2,y:CGFloat(height)*0.45,width:CGFloat(width)*0.6,height:CGFloat(height)*0.1))
            return try XCTUnwrap(c.makeImage())
        }
        let source=try marked(1280,720),background=try marked(2400,600)
        for style in [CoverStyle.pencil,.code,.media] {
            for template in [CoverTemplate.spotlight,.editorial] {
                for explicit in [false,true] {
                    var value=try revision();value.coverPresentation=CoverPresentation(style:style,template:template,title:"差一枚，路就修不成？",subtitle:"完整画面保留标题、图例与字幕",background:explicit ? CoverImage(assetID:"wide"):nil)
                    let image=try CoverPainter.image(revision:value,source:source,images:["wide":background]),raw=try pixels(image)
                    var marks=Array(repeating:[CGPoint](),count:5)
                    for offset in stride(from:0,to:raw.count,by:4) {
                        let r=raw[offset],g=raw[offset+1],b=raw[offset+2]
                        let index:Int?
                        if r>240 && g<15 && b<15 {index=0}
                        else if r<15 && g>240 && b<15 {index=1}
                        else if r<15 && g<15 && b>240 {index=2}
                        else if r>240 && g<15 && b>240 {index=3}
                        else if r>240 && g>240 && b<15 {index=4}
                        else {index=nil}
                        if let index {marks[index].append(CGPoint(x:(offset/4)%image.width,y:(offset/4)/image.width))}
                    }
                    for (index,mark) in marks.enumerated() {XCTAssertGreaterThan(mark.count,128,"四角标签与中央横向内容均须实际可见：\(index)/\(style)/\(template)/\(explicit)")}
                    func center(_ index:Int)throws->CGPoint {
                        let points=marks[index];_ = try XCTUnwrap(points.first,"四角标签和内容均须有实际像素")
                        return CGPoint(x:points.map(\.x).reduce(0,+)/CGFloat(points.count),y:points.map(\.y).reduce(0,+)/CGFloat(points.count))
                    }
                    let a=try center(0),b=try center(1),d=try center(2),e=try center(3),middle=try center(4)
                    XCTAssertLessThan(a.x,b.x);XCTAssertLessThan(d.x,e.x)
                    XCTAssertEqual(a.y,b.y,accuracy:2);XCTAssertEqual(d.y,e.y,accuracy:2)
                    XCTAssertGreaterThan(abs(a.y-d.y),100)
                    XCTAssertGreaterThan(middle.x,a.x);XCTAssertLessThan(middle.x,b.x)
                    if style == .media && template == .editorial && !explicit {
                        let clean=try pixels(CoverPainter.image(revision:value,source:bitmap(width:1280,height:720)))
                        let offset=(image.height/2*image.width+8)*4
                        XCTAssertEqual(Array(raw[offset..<offset+4]),Array(clean[offset..<offset+4]),"宽帧只在内容卡出现，页边不得残留重复暗字底图")
                    }
                }
            }
        }
    }
    func testCodeAndMediaBadgesHaveDarkLegibleLetterPixels()throws {
        try assertRGBAFixture()
        let source=try bitmap(width:1280,height:720)
        for (style,accent) in [(CoverStyle.code,[169,228,109]),(.media,[245,198,75])] {
            // Match production's device/generic CGColor conversion, independently
            // of the actual badge. The dark-letter rule remains in sRGB pixels.
            let swatch=try XCTUnwrap(CGContext(data:nil,width:4,height:1,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            swatch.setFillColor(CGColor(red:CGFloat(accent[0])/255,green:CGFloat(accent[1])/255,blue:CGFloat(accent[2])/255,alpha:1));swatch.fill(CGRect(x:0,y:0,width:4,height:1))
            let reference=try pixels(XCTUnwrap(swatch.makeImage()))
            var value=try revision();value.coverPresentation=CoverPresentation(style:style,template:.editorial,title:"差一枚，路就修不成？")
            let image=try CoverPainter.image(revision:value,source:source),raw=try pixels(image)
            var dark=0
            for y in 0..<image.height {
                let colored=(0..<image.width).filter {x in
                    let offset=(y*image.width+x)*4
                    return (0..<3).allSatisfy{abs(Int(raw[offset+$0])-Int(reference[$0]))<3}
                }
                guard let first=colored.first,let last=colored.last,last-first>image.width*35/100 else {continue}
                for x in (first+24)..<(last-24) {
                    let offset=(y*image.width+x)*4
                    if raw[offset]<100 && raw[offset+1]<100 && raw[offset+2]<100 {dark+=1}
                }
            }
            XCTAssertGreaterThan(dark,100,"浅色标签内部须有深色文字像素，不能用浅字叠浅底：\(style)")
        }
    }
    func testTransparentHeroKeepsItsExistingIndependentLayoutInBothAspects()throws {
        try assertRGBAFixture()
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let c=try XCTUnwrap(CGContext(data:nil,width:120,height:200,bitsPerComponent:8,bytesPerRow:480,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        c.clear(CGRect(x:0,y:0,width:120,height:200));c.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));c.fillEllipse(in:CGRect(x:20,y:20,width:80,height:160))
        let hero=try XCTUnwrap(c.makeImage())
        for aspect in [Aspect.landscape,.portrait] {
            for style in [CoverStyle.presenter,.game] {
                for template in [CoverTemplate.spotlight,.editorial] {
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
