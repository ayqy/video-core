import XCTest
import CoreGraphics
import CoreText
import VideoCore
@testable import VideoMedia

final class DataPresentationPainterTests: XCTestCase {
    func chart() -> DataChart {
        DataChart(title:"简化模型中的代币",axisLabel:"代币（作者给定）",minimum:0,maximum:8,
            series:[DataSeries(id:"a",label:"甲",color:"38BDF8",keyframes:[.init(frame:0,value:4),.init(frame:60,value:3),.init(frame:120,value:5)]),
                    DataSeries(id:"d",label:"丁",color:"FBBF24",keyframes:[.init(frame:0,value:4),.init(frame:60,value:4),.init(frame:120,value:6)])])
    }
    func revision(code: Bool = false,aspect: Aspect = .landscape) -> Revision {
        var scene=Scene(title:code ? "代码步骤只展示，不执行":"从支出到收益",body:"给定投入与规则，逐步核对各人的数值变化。",durationFrames:181)
        var layer=SceneLayer(kind:code ? .code:.chart,endFrame:181)
        layer.x=0.5;layer.y=0.372222;layer.width=0.875;layer.height=0.438889
        if aspect == .portrait {layer.y=0.4609375;layer.width=592.0/720.0;layer.height=560.0/1280.0}
        if code {
            layer.dataPresentation=DataPresentation(code:CodePresentation(title:"作者给定的公式",lines:["total = sum(contributions)","built = total >= 3","payoff = 4 - cost + (2 if built else 0)"],highlights:[.init(startFrame:0,endFrame:60,line:0),.init(startFrame:60,endFrame:181,line:2)]))
        } else {layer.dataPresentation=DataPresentation(chart:chart())}
        scene.layers=[layer]
        return Revision(contentContext:ContentContext(workspaceID:"w",name:"数据知识"),aspect:aspect,scenes:[scene])
    }
    func bluePixels(_ image: CGImage) throws -> Int {
        let data=try XCTUnwrap(image.dataProvider?.data),bytes=CFDataGetBytePtr(data)!
        var count=0
        for row in 0..<image.height {for column in 0..<image.width {
            let i=row*image.bytesPerRow+column*4
            if bytes[i]<120 && bytes[i+1]>120 && bytes[i+2]>160 {count+=1}
        }}
        return count
    }
    func save(_ image: CGImage,name: String) throws {
        guard let path=ProcessInfo.processInfo.environment["VIDEO_DATA_FRAME_DIRECTORY"] else{return}
        let directory=URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try ScenePainter.png(image).write(to:directory.appendingPathComponent(name))
    }
    func paperRevision(code: Bool = false, paper: PaperPresentation = .init()) -> Revision {
        var result=revision(code:code)
        result.scenes[0].paperPresentation=paper
        result.scenes[0].title=""
        result.scenes[0].body=""
        result.cta=""
        result.scenes[0].layers?[0].y=343.0/720.0
        result.scenes[0].layers?[0].height=342.0/720.0
        return result
    }
    func pixel(_ image:CGImage,x:CGFloat,y:CGFloat) throws -> [UInt8] {
        let crop=try XCTUnwrap(image.cropping(to:CGRect(x:x,y:CGFloat(image.height)-y-1,width:1,height:1)))
        let context=try XCTUnwrap(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop,in:CGRect(x:0,y:0,width:1,height:1))
        let bytes=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
        return Array(UnsafeBufferPointer(start:bytes,count:3))
    }
    func referencePixel(_ hex:String,overlay:String?=nil,alpha:CGFloat=1)throws->[UInt8] {
        // Hex-authored CGColor uses Device RGB. Let CoreGraphics perform its
        // actual conversion/blending into the painter's sRGB output space;
        // the numeric source components are not output sRGB byte values.
        let context=try XCTUnwrap(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        func sourceColor(_ value:String,opacity:CGFloat)->CGColor {
            let rgb=UInt32(value,radix:16)!
            return CGColor(red:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:opacity)
        }
        let rect=CGRect(x:0,y:0,width:1,height:1)
        context.setFillColor(sourceColor(hex,opacity:1));context.fill(rect)
        if let overlay {context.setFillColor(sourceColor(overlay,opacity:alpha));context.fill(rect)}
        let bytes=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
        return Array(UnsafeBufferPointer(start:bytes,count:3))
    }
    func assertPixel(_ actual:[UInt8],equals expected:[UInt8],_ message:String="",file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(actual.count,3,file:file,line:line)
        XCTAssertEqual(expected.count,3,file:file,line:line)
        for (a,b) in zip(actual,expected) {XCTAssertLessThanOrEqual(abs(Int(a)-Int(b)),1,message,file:file,line:line)}
    }
    func testPaperChartUsesAuthoredPaperInkAndSeriesColors() throws {
        let standard=try ScenePainter.image(revision:paperRevision(),frame:0)
        assertPixel(try pixel(standard,x:82,y:208),equals:try referencePixel("FFF9EF"))
        let paper=PaperPresentation(paperColor:"EAF2DD",inkColor:"371B45")
        let custom=paperRevision(paper:paper)
        let first=try ScenePainter.image(revision:custom,frame:0)
        let next=try ScenePainter.image(revision:custom,frame:60)
        assertPixel(try pixel(first,x:82,y:208),equals:try referencePixel("EAF2DD"))
        // These are inside the first authored bar, clear of numeric labels.
        assertPixel(try pixel(first,x:300,y:365),equals:try referencePixel("38BDF8"))
        assertPixel(try pixel(next,x:300,y:365),equals:try referencePixel("EAF2DD"),"数值下降必须改变实际柱端，不能只更换文字或纸面颜色")
        let rgba=try XCTUnwrap(first.dataProvider?.data)
        let bytes=CFDataGetBytePtr(rgba)!
        let ink=try referencePixel("371B45")
        var solidInk=0
        for row in 0..<first.height {for column in 0..<first.width {
            let i=row*first.bytesPerRow+column*4
            if zip([bytes[i],bytes[i+1],bytes[i+2]],ink).allSatisfy({abs(Int($0.0)-Int($0.1))<=1}) {solidInk+=1}
        }}
        XCTAssertGreaterThan(solidInk,100,"图表标题、刻度与标签应使用作者指定的深墨色")
    }
    func testPaperCodeHighlightFollowsAuthoredTimingWithReadableInkWash() throws {
        let revision=paperRevision(code:true)
        let first=try ScenePainter.image(revision:revision,frame:0)
        let next=try ScenePainter.image(revision:revision,frame:60)
        // Right-hand whitespace within line one and line three. The highlight
        // is a subdued ink wash; actual text remains fully opaque ink.
        let highlighted=try pixel(first,x:1188,y:450)
        assertPixel(try pixel(next,x:1188,y:450),equals:try referencePixel("FFF9EF"))
        assertPixel(try pixel(first,x:1188,y:270),equals:try referencePixel("FFF9EF"))
        assertPixel(try pixel(next,x:1188,y:270),equals:highlighted)
        assertPixel(highlighted,equals:try referencePixel("FFF9EF",overlay:"243638",alpha:0.12))
    }
    func testOrdinaryDataAndCodeKeepLegacyDarkPanels() throws {
        let chart=try ScenePainter.image(revision:revision(),frame:0)
        assertPixel(try pixel(chart,x:82,y:296),equals:try referencePixel("111C31"))
        let code=try ScenePainter.image(revision:revision(code:true),frame:0)
        assertPixel(try pixel(code,x:82,y:296),equals:try referencePixel("111C31"))
        assertPixel(try pixel(code,x:1188,y:500),equals:try referencePixel("244A61"))
    }
    func testPaperDataSuffixSeparatesDrawingSemanticsUnderCurrentEncoding() throws {
        // Reconstruct the base drawing key under the current encoding identity.
        // This isolates the paper-data suffix; old encoding cache migration is
        // verified separately and is not represented by this fixture.
        let current=revision()
        let encoding=try VisualClipCache.EncodingConfiguration.capture(aspect:current.aspect,fps:current.fps)
        func baseKeyForCurrentEncoding(_ revision:Revision)throws->String {
            var scene=revision.scenes[0]
            scene.voice=nil;scene.speechPlan=nil;scene.voiceGain=1;scene.sourceGain=0;scene.musicGain=0;scene.muted=false
            scene.evidenceIDs=[];scene.courseMappingIDs=nil;scene.narrativeSources=nil;scene.locked=false
            scene.narration=scene.narration.isEmpty ? "":"speech"
            let font=CTFontCreateWithName("PingFangSC-Medium" as CFString,32,nil)
            let table=CTFontCopyTable(font,0x68656164,[]) as Data? ?? Data()
            return try Codec.digest(VisualClipCache.Key(version:VisualClipCache.version+revision.toolchain,cinemaSubtitleStyle:CinemaSubtitles.styleVersion,os:ProcessInfo.processInfo.operatingSystemVersionString,font:(CTFontCopyPostScriptName(font) as String)+Codec.hash(table),scene:scene,encoding:encoding,purpose:revision.purpose,aspect:revision.aspect,fps:revision.fps,index:0,sceneCount:1,startFrame:0,price:nil,cta:revision.cta,sourceHash:nil,layerHashes:[:],moduleIdentity:nil,artworkIdentity:nil))
        }
        for code in [false,true] {
            let ordinary=revision(code:code)
            XCTAssertEqual(try baseKeyForCurrentEncoding(ordinary),try VisualClipCache.fingerprint(revision:ordinary,index:0,database:Database(),modules:nil,encoding:encoding))
            let paper=paperRevision(code:code)
            XCTAssertNotEqual(try baseKeyForCurrentEncoding(paper),try VisualClipCache.fingerprint(revision:paper,index:0,database:Database(),modules:nil,encoding:encoding),"同一编码身份下，纸面数据绘制语义须区别于普通暗板")
        }
        var drawing=paperRevision();drawing.scenes[0].layers=[]
        XCTAssertEqual(try baseKeyForCurrentEncoding(drawing),try VisualClipCache.fingerprint(revision:drawing,index:0,database:Database(),modules:nil,encoding:encoding))
    }
    func testActualValuesMoveBarEndsWithoutChangingWidth() throws {
        let rect=CGRect(x:80,y:294,width:1120,height:316)
        let first=try DataPresentationPainter.chartGeometry(chart(),frame:0,rect:rect)
        let cost=try DataPresentationPainter.chartGeometry(chart(),frame:60,rect:rect)
        let reward=try DataPresentationPainter.chartGeometry(chart(),frame:120,rect:rect)
        XCTAssertEqual(first.bars[0].rect.width,cost.bars[0].rect.width,accuracy:1e-12)
        XCTAssertEqual(first.bars[0].rect.width,reward.bars[0].rect.width,accuracy:1e-12)
        XCTAssertEqual(cost.bars[0].value,3);XCTAssertEqual(reward.bars[0].value,5)
        XCTAssertEqual(cost.bars[0].rect.height,cost.plot.height*3/8,accuracy:1e-10)
        XCTAssertEqual(reward.bars[1].rect.height,reward.plot.height*6/8,accuracy:1e-10)
        XCTAssertEqual(DataPresentationPainter.number(4),"4")
        XCTAssertEqual(DataPresentationPainter.number(0.0005),"5e-4")
        let ticks=(0...4).map{Double($0)*0.00025}
        let labels=ticks.map{DataPresentationPainter.number($0)}
        XCTAssertEqual(Set(labels).count,5)
        for (value,label) in zip(ticks,labels) {XCTAssertEqual(Double(label),value)}
        XCTAssertEqual(DataPresentationPainter.number(4.0000000001),"≈4")
        XCTAssertEqual(DataPresentationPainter.number(4.026666666666667),"≈4.02667")
        XCTAssertEqual(DataPresentationPainter.number(1.0/120.0),"≈8.3333e-3")
        XCTAssertEqual(DataPresentationPainter.number(1e9),"1e9")
        var small=chart();small.minimum=0;small.maximum=0.001;small.title="小数量级保留实际值"
        for index in small.series.indices {small.series[index].keyframes=[.init(frame:0,value:index == 0 ? 0.0005:0.00075)]}
        var r=revision();r.scenes[0].layers?[0].dataPresentation=DataPresentation(chart:small)
        let image=try ScenePainter.image(revision:r,frame:0)
        XCTAssertGreaterThan(try bluePixels(image),0)
        if let path=ProcessInfo.processInfo.environment["VIDEO_DATA_SMALL_FRAME_DIRECTORY"] {
            let directory=URL(fileURLWithPath:path,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try ScenePainter.png(image).write(to:directory.appendingPathComponent("06-data-small-values.png"))
        }
    }
    func testNormalScenePainterDrawsRealDataChangesAndAllSixFramesAreIndexed() throws {
        let r=revision()
        let a=try ScenePainter.image(revision:r,frame:0),b=try ScenePainter.image(revision:r,frame:60),c=try ScenePainter.image(revision:r,frame:120)
        XCTAssertLessThan(try bluePixels(b),try bluePixels(a))
        XCTAssertGreaterThan(try bluePixels(c),try bluePixels(a))
        try save(a,name:"00-data-initial.png");try save(b,name:"01-data-cost.png");try save(c,name:"02-data-reward.png")
        let code=revision(code:true)
        let d=try ScenePainter.image(revision:code,frame:0),e=try ScenePainter.image(revision:code,frame:60)
        XCTAssertNotEqual(try ScenePainter.png(d),try ScenePainter.png(e))
        try save(d,name:"03-code-total.png");try save(e,name:"04-code-payoff.png")
        let portrait=try ScenePainter.image(revision:revision(aspect:.portrait),frame:120)
        XCTAssertEqual(portrait.width,720);XCTAssertEqual(portrait.height,1280)
        try save(portrait,name:"05-data-portrait.png")
        let production=publicGoodsProductionRevision()
        XCTAssertEqual(production.frames,1604)
        for frame in 0..<production.frames {
            do {
                try autoreleasepool {
                    let image=try ScenePainter.image(revision:production,frame:frame)
                    XCTAssertEqual(image.width,1280);XCTAssertEqual(image.height,720)
                }
            } catch {
                let (_,source,index)=ScenePainter.scene(revision:production,frame:frame)
                XCTFail("完整制作绘制拒绝：scene=\(index+1) sourceFrame=\(source) timelineFrame=\(frame)；\(error)")
                throw error
            }
        }
        print("完整制作视觉时轴：5场景/1604帧逐帧绘制通过；声音与人工审核不在此规则内")
    }
    func testUnreadableOrUnsafeDataRegionFailsInsteadOfClippingText() throws {
        for paper in [Optional<PaperPresentation>.none,.some(.init())] {
            var r=revision();r.scenes[0].paperPresentation=paper;r.scenes[0].layers?[0].width=0.1
            XCTAssertThrowsError(try ScenePainter.image(revision:r,frame:0))
            r=revision();r.scenes[0].paperPresentation=paper;r.scenes[0].layers?[0].x=0
            XCTAssertThrowsError(try ScenePainter.image(revision:r,frame:0))
            r=revision(code:true);r.scenes[0].paperPresentation=paper;r.scenes[0].layers?[0].height=0.06
            XCTAssertThrowsError(try ScenePainter.image(revision:r,frame:0))
        }
    }
    func testDisplayedCodeIsNotExecutedAndPublicSamplingCannotTrap() throws {
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true).appendingPathComponent(".data-display-"+Codec.id(),isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let sentinel=directory.appendingPathComponent("owned.txt")
        let original=Data("owned test file remains unchanged".utf8)
        try original.write(to:sentinel)
        var r=revision(code:true)
        r.scenes[0].title="代码"
        r.scenes[0].layers?[0].dataPresentation?.code?.lines=["rm -f \"\(directory.lastPathComponent)/owned.txt\""]
        r.scenes[0].layers?[0].dataPresentation?.code?.highlights=[]
        _=try ScenePainter.image(revision:r,frame:0)
        XCTAssertEqual(try Data(contentsOf:sentinel),original)
        r.scenes[0].paperPresentation = .init()
        _=try ScenePainter.image(revision:r,frame:0)
        XCTAssertEqual(try Data(contentsOf:sentinel),original)
        for frame in [Int.min,-1,Int.max] {
            XCTAssertThrowsError(try DataPresentationPainter.chartGeometry(chart(),frame:frame,rect:CGRect(x:80,y:294,width:1120,height:316)))
        }
    }

    func testDataPanelGapDoesNotRepeatBodyButSeparateBodyStillChanges() throws {
        var a=publicGoodsProductionRevision()
        a.scenes[0].body=String(repeating:"甲",count:35)
        var b=a
        b.scenes[0].body=String(repeating:"乙",count:35)
        let first=try ScenePainter.image(revision:a,frame:50)
        let second=try ScenePainter.image(revision:b,frame:50)
        let layout=ScenePainter.OverlayLayout(width:1280,height:720,showPrice:false,separateBody:true,knowledge:true)
        func pixels(_ image:CGImage,_ canvasRect:CGRect)throws->Data {
            let crop=try XCTUnwrap(image.cropping(to:CGRect(x:canvasRect.minX,y:CGFloat(image.height)-canvasRect.maxY,width:canvasRect.width,height:canvasRect.height)))
            let context=try XCTUnwrap(CGContext(data:nil,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
            return Data(bytes:try XCTUnwrap(context.data),count:crop.width*crop.height*4)
        }
        // The real chart ends at x=640 and the code panel starts at x=660.
        // The old placeholder body leaked between them near the stage's top.
        let gap=CGRect(x:642,y:layout.visual.minY,width:16,height:layout.visual.height)
        XCTAssertEqual(try pixels(first,gap),try pixels(second,gap),"数据面板中缝不能透出重复的旧占位正文")
        XCTAssertNotEqual(try pixels(first,layout.mediaBody),try pixels(second,layout.mediaBody),"正文仍须在独立区域完整绘制，不能以删除正文掩盖问题")
        if let path=ProcessInfo.processInfo.environment["VIDEO_DATA_GAP_FRAME_DIRECTORY"] {
            let directory=URL(fileURLWithPath:path,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let production=publicGoodsProductionRevision()
            try ScenePainter.png(ScenePainter.image(revision:production,frame:50)).write(to:directory.appendingPathComponent("00-initial-resources.png"))
            try ScenePainter.png(ScenePainter.image(revision:production,frame:838)).write(to:directory.appendingPathComponent("01-settled-payoff.png"))
        }
    }

    /// Visual fields copied from the actual five-scene normal CLI production,
    /// including all sentence captions and source-frame value/highlight times.
    /// Voice asset identifiers do not affect ScenePainter and are not embedded.
    func publicGoodsProductionRevision() -> Revision {
        var scenes:[Scene]=[]
        do {
            var scene=Scene(title:"共同愿望与个人激励",body:"共享道路使每个人受益；个人仍可能等待别人先投入。",durationFrames:306)
            scene.captions=[Caption(text:"一条不拥堵的共享道路，四个人都能走。",startFrame:0,endFrame:117,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"每个人都希望路修好，却也想让别人先出钱。",startFrame:117,endFrame:247,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"这就是搭便车问题。",startFrame:247,endFrame:306,alignment:"estimated_sentence_no_word_timestamps",confirmed:false)]
            var layer0=SceneLayer(kind:.chart,endFrame:306)
            layer0.x=0.28125;layer0.y=0.37222222222222223;layer0.width=0.4375;layer0.height=0.4388888888888889
            layer0.dataPresentation=DataPresentation(chart:DataChart(title:"初始资源：每人4枚",axisLabel:"每人的初始代币",minimum:0,maximum:6,series:[DataSeries(id:"person-0",label:"甲",color:"60A5FA",keyframes:[.init(frame:0,value:4)]),DataSeries(id:"person-1",label:"乙",color:"FBBF24",keyframes:[.init(frame:0,value:4)]),DataSeries(id:"person-2",label:"丙",color:"34D399",keyframes:[.init(frame:0,value:4)]),DataSeries(id:"person-3",label:"丁",color:"FB7185",keyframes:[.init(frame:0,value:4)])]))
            var layer1=SceneLayer(kind:.code,endFrame:306)
            layer1.x=0.7265625;layer1.y=0.37222222222222223;layer1.width=0.421875;layer1.height=0.4388888888888889
            layer1.dataPresentation=DataPresentation(code:CodePresentation(title:"先公开假设",lines:["n = 4","initial = 4","benefit = 2"],highlights:[.init(startFrame:0,endFrame:100,line:0),.init(startFrame:100,endFrame:200,line:1),.init(startFrame:200,endFrame:306,line:2)]))
            scene.layers=[layer0,layer1];scenes.append(scene)
        }
        do {
            var scene=Scene(title:"先明确模型的假设",body:"每人4枚；门槛3枚；每人最多投入1枚；修好后每人收益2枚。",durationFrames:312)
            scene.captions=[Caption(text:"用一个简化模型看激励。",startFrame:0,endFrame:70,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"每人有四枚代币，修路需要三枚，每人最多出一枚。",startFrame:70,endFrame:216,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"路修好后，每个人得到两枚收益。",startFrame:216,endFrame:312,alignment:"estimated_sentence_no_word_timestamps",confirmed:false)]
            var layer0=SceneLayer(kind:.chart,endFrame:312)
            layer0.x=0.28125;layer0.y=0.37222222222222223;layer0.width=0.4375;layer0.height=0.4388888888888889
            layer0.dataPresentation=DataPresentation(chart:DataChart(title:"比较一组明确的投入",axisLabel:"投入代币；修路门槛为3",minimum:0,maximum:3,series:[DataSeries(id:"person-0",label:"甲",color:"60A5FA",keyframes:[.init(frame:0,value:0),.init(frame:75,value:0),.init(frame:195,value:1)]),DataSeries(id:"person-1",label:"乙",color:"FBBF24",keyframes:[.init(frame:0,value:0),.init(frame:75,value:0),.init(frame:195,value:1)]),DataSeries(id:"person-2",label:"丙",color:"34D399",keyframes:[.init(frame:0,value:0),.init(frame:75,value:0),.init(frame:195,value:1)]),DataSeries(id:"person-3",label:"丁",color:"FB7185",keyframes:[.init(frame:0,value:0),.init(frame:75,value:0),.init(frame:195,value:0)])]))
            var layer1=SceneLayer(kind:.code,endFrame:312)
            layer1.x=0.7265625;layer1.y=0.37222222222222223;layer1.width=0.421875;layer1.height=0.4388888888888889
            layer1.dataPresentation=DataPresentation(code:CodePresentation(title:"作者给定的模型参数",lines:["c = [1, 1, 1, 0]","threshold = 3","sum(c) == 3"],highlights:[.init(startFrame:0,endFrame:105,line:0),.init(startFrame:105,endFrame:210,line:1),.init(startFrame:210,endFrame:312,line:2)]))
            scene.layers=[layer0,layer1];scenes.append(scene)
        }
        do {
            var scene=Scene(title:"逐步算清每个人的收益",body:"甲乙丙各投入1枚：各有5枚；丁没有投入：最后有6枚。",durationFrames:307)
            scene.captions=[Caption(text:"甲、乙、丙各出一枚，刚好修好道路。",startFrame:0,endFrame:102,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"三人各剩三枚，再加两枚收益，最后各有五枚。",startFrame:102,endFrame:229,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"没有出钱的丁，最后有六枚。",startFrame:229,endFrame:307,alignment:"estimated_sentence_no_word_timestamps",confirmed:false)]
            var layer0=SceneLayer(kind:.chart,endFrame:307)
            layer0.x=0.28125;layer0.y=0.37222222222222223;layer0.width=0.4375;layer0.height=0.4388888888888889
            layer0.dataPresentation=DataPresentation(chart:DataChart(title:"先扣投入，再加公共收益",axisLabel:"结算后的代币数量",minimum:0,maximum:7,series:[DataSeries(id:"person-0",label:"甲",color:"60A5FA",keyframes:[.init(frame:0,value:4),.init(frame:80,value:3),.init(frame:145,value:3),.init(frame:220,value:5)]),DataSeries(id:"person-1",label:"乙",color:"FBBF24",keyframes:[.init(frame:0,value:4),.init(frame:80,value:3),.init(frame:145,value:3),.init(frame:220,value:5)]),DataSeries(id:"person-2",label:"丙",color:"34D399",keyframes:[.init(frame:0,value:4),.init(frame:80,value:3),.init(frame:145,value:3),.init(frame:220,value:5)]),DataSeries(id:"person-3",label:"丁",color:"FB7185",keyframes:[.init(frame:0,value:4),.init(frame:80,value:4),.init(frame:145,value:4),.init(frame:220,value:6)])]))
            var layer1=SceneLayer(kind:.code,endFrame:307)
            layer1.x=0.7265625;layer1.y=0.37222222222222223;layer1.width=0.421875;layer1.height=0.4388888888888889
            layer1.dataPresentation=DataPresentation(code:CodePresentation(title:"逐步显示收益计算",lines:["total = sum(c)","built = total >= 3","payoff = 4-c[i]+(2 if built else 0)"],highlights:[.init(startFrame:0,endFrame:85,line:0),.init(startFrame:85,endFrame:165,line:1),.init(startFrame:165,endFrame:307,line:2)]))
            scene.layers=[layer0,layer1];scenes.append(scene)
        }
        do {
            var scene=Scene(title:"反事实：每个人都等待",body:"所有人投入0：道路未修成，最后每个人仍有4枚。",durationFrames:313)
            scene.captions=[Caption(text:"如果四个人都等别人出钱，公共投入就是零。",startFrame:0,endFrame:128,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"道路没有修成，大家仍只有最初的四枚。",startFrame:128,endFrame:243,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"这是改变策略后的结果。",startFrame:243,endFrame:313,alignment:"estimated_sentence_no_word_timestamps",confirmed:false)]
            var layer0=SceneLayer(kind:.chart,endFrame:313)
            layer0.x=0.28125;layer0.y=0.37222222222222223;layer0.width=0.4375;layer0.height=0.4388888888888889
            layer0.dataPresentation=DataPresentation(chart:DataChart(title:"反事实：大家都等待",axisLabel:"未修成；每人仍为4枚",minimum:0,maximum:7,series:[DataSeries(id:"person-0",label:"甲",color:"60A5FA",keyframes:[.init(frame:0,value:4)]),DataSeries(id:"person-1",label:"乙",color:"FBBF24",keyframes:[.init(frame:0,value:4)]),DataSeries(id:"person-2",label:"丙",color:"34D399",keyframes:[.init(frame:0,value:4)]),DataSeries(id:"person-3",label:"丁",color:"FB7185",keyframes:[.init(frame:0,value:4)])]))
            var layer1=SceneLayer(kind:.code,endFrame:313)
            layer1.x=0.7265625;layer1.y=0.37222222222222223;layer1.width=0.421875;layer1.height=0.4388888888888889
            layer1.dataPresentation=DataPresentation(code:CodePresentation(title:"只改变策略，再算一次",lines:["c = [0, 0, 0, 0]","sum(c) < 3","payoff = [4, 4, 4, 4]"],highlights:[.init(startFrame:0,endFrame:105,line:0),.init(startFrame:105,endFrame:210,line:1),.init(startFrame:210,endFrame:313,line:2)]))
            scene.layers=[layer0,layer1];scenes.append(scene)
        }
        do {
            var scene=Scene(title:"结论成立的条件与边界",body:"模型说明个人激励与共同结果可能分离；不等同现实行为预测。",durationFrames:366)
            scene.captions=[Caption(text:"搭便车的关键，是个人选择和共同结果可能不一致。",startFrame:0,endFrame:150,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"讲解时要把条件和收益说清楚。",startFrame:150,endFrame:242,alignment:"estimated_sentence_no_word_timestamps",confirmed:false),Caption(text:"这个简化模型，不等于对现实行为的预测。",startFrame:242,endFrame:366,alignment:"estimated_sentence_no_word_timestamps",confirmed:false)]
            var layer0=SceneLayer(kind:.chart,endFrame:366)
            layer0.x=0.28125;layer0.y=0.37222222222222223;layer0.width=0.4375;layer0.height=0.4388888888888889
            layer0.dataPresentation=DataPresentation(chart:DataChart(title:"比较公共投入的不同结果",axisLabel:"三人投入达门槛；等待投入为0",minimum:0,maximum:4,series:[DataSeries(id:"person-0",label:"三人投入",color:"60A5FA",keyframes:[.init(frame:0,value:0),.init(frame:90,value:3)]),DataSeries(id:"person-1",label:"全员等待",color:"FBBF24",keyframes:[.init(frame:0,value:0)])]))
            var layer1=SceneLayer(kind:.code,endFrame:366)
            layer1.x=0.7265625;layer1.y=0.37222222222222223;layer1.width=0.421875;layer1.height=0.4388888888888889
            layer1.dataPresentation=DataPresentation(code:CodePresentation(title:"这些结论有明确边界",lines:["non_excludable = True","no_congestion = True","model != prediction"],highlights:[.init(startFrame:0,endFrame:120,line:0),.init(startFrame:120,endFrame:240,line:1),.init(startFrame:240,endFrame:366,line:2)]))
            scene.layers=[layer0,layer1];scenes.append(scene)
        }
        return Revision(contentContext:ContentContext(workspaceID:"w",name:"公共品数据知识"),aspect:.landscape,scenes:scenes)
    }
}
