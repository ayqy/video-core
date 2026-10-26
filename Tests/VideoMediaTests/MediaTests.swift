import XCTest
import VideoCore
@testable import VideoMedia
import AVFoundation
import CoreMedia
import CoreGraphics

final class MediaTests:XCTestCase {
    func testWrappedChineseTitleSurvivesPortraitConversionWithOverflowStillRejected() throws {
        var scene=Scene(kind:.explanation,title:"完整原音：内部技术回归（待审）",body:"保留完整原音与字幕，尚未完整看听。",durationFrames:287)
        scene.captions=[Caption(text:"每一组都赢，合起来却输了。",startFrame:0,endFrame:107)]
        var revision=try Planner.create(workspaceID:"w",name:"双画幅文字",aspect:.landscape,scenes:[scene])
        XCTAssertNoThrow(try ScenePainter.image(revision:revision,frame:53))
        revision.aspect = .portrait
        XCTAssertNoThrow(try ScenePainter.image(revision:revision,frame:53),"转换后应完整显示两行中文标题")
        revision.scenes[0].title=String(repeating:"完整中文标题必须保留且不可越界",count:8)
        XCTAssertThrowsError(try ScenePainter.image(revision:revision,frame:53),"仍应阻止真正超出安全区的标题")
    }

    func testSnapshotPriceCaptionsCTAAndFooterRemainDistinctInBothAspectFrames() throws {
        let product=Product(workspaceID:"w",sku:"layout",name:"课程",checkout:"https://example.com",audience:"学习者",task:"核对",outcome:"可复现",prerequisite:"无",scope:"布局",prices:[Price(money:Money(99),from:.distantPast,source:"合成测试",verified:true)])
        let source=try XCTUnwrap(CGContext(data:nil,width:80,height:40,bitsPerComponent:8,bytesPerRow:320,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red:0.1,green:0.3,blue:0.6,alpha:1));source.fill(CGRect(x:0,y:0,width:80,height:40))
        let image=try XCTUnwrap(source.makeImage())
        func regionHash(_ image:CGImage,_ rect:CGRect)throws->String {
            // CGImage's pixel rows start at the top; Painter layout uses canvas y-up.
            let pixels=CGRect(x:rect.minX,y:CGFloat(image.height)-rect.maxY,width:rect.width,height:rect.height)
            return Codec.hash(try ScenePainter.png(XCTUnwrap(image.cropping(to:pixels))))
        }
        for aspect in Aspect.allCases {for hasMedia in [false,true] {
            var scene=Scene(kind:hasMedia ? .image:.explanation,title:"核对当前版本",body:"真实材料与关键文字应清楚可见。",durationFrames:60)
            scene.showPrice=true;scene.captions=[Caption(text:"逐项核对字幕",startFrame:0,endFrame:60,confirmed:true)]
            let revision=Revision(product:product,purpose:.course,aspect:aspect,scenes:[scene],cta:"查看课程内容")
            let layout=ScenePainter.OverlayLayout(width:CGFloat(aspect.width),height:CGFloat(aspect.height),showPrice:true,separateBody:hasMedia)
            let regions=[layout.price,layout.captionBackground,layout.cta,layout.footer]
            let canvas=CGRect(x:0,y:0,width:aspect.width,height:aspect.height)
            for (index,rect) in regions.enumerated() {
                XCTAssertTrue(canvas.contains(rect))
                XCTAssertFalse(layout.visual.intersects(rect),"主画面不能覆盖关键文字保留区")
                if hasMedia {XCTAssertFalse(layout.mediaBody.intersects(rect),"材料说明不能覆盖关键文字保留区")}
                for other in regions.dropFirst(index+1) {XCTAssertFalse(rect.intersects(other),"价格、字幕、CTA与页脚须分别保留可见区域")}
            }
            func paint(_ value:Revision)throws->CGImage {try ScenePainter.image(revision:value,frame:15,media:hasMedia ? image:nil)}
            let original=try paint(revision)
            var price=revision;price.product!.prices[0].money=Money(200)
            var captions=revision;captions.scenes[0].captions[0].text="同步检查画面"
            var cta=revision;cta.cta="核对课程前提"
            for (changedRegion,variant) in [price,captions,cta].enumerated() {
                let changed=try paint(variant)
                for (index,rect) in regions.enumerated() {
                    let before=try regionHash(original,rect),after=try regionHash(changed,rect)
                    if index==changedRegion {XCTAssertNotEqual(before,after,"修改关键字段必须改变自己的实际像素")}
                    else {XCTAssertEqual(before,after,"修改一项不得污染其他关键字段的实际像素")}
                }
            }
            var noCaptions=revision;noCaptions.scenes[0].captions=[]
            let uncovered=try paint(noCaptions)
            for rect in [layout.price,layout.cta,layout.footer] {
                XCTAssertEqual(try regionHash(original,rect),try regionHash(uncovered,rect),"字幕出现不能遮住价格、CTA或页脚")
            }
        }}
    }

    func testOffCanvasTextAndMissingFontCannotProduceApprovedPixels() throws {
        let data=Data(EditorPracticeRules.sourceText.utf8)
        let source=Asset(workspaceID:"w",name:"source.txt",hash:Codec.hash(data),ext:"txt",bytes:data.count,mediaType:"text")
        var p=try LearningExample.project(workspaceID:"w",asset:source);var scene=p.current.scenes[0]
        var layer=SceneLayer(kind:.text,text:"实际文字",endFrame:30);layer.x=0;scene.layers=[layer];p.revisions[0].scenes[0]=scene
        XCTAssertThrowsError(try ScenePainter.image(revision:p.current,frame:0))
        scene.layers=nil;scene.fontName="Video-Deliberately-Missing-Font-For-Rule-Test";p.revisions[0].scenes[0]=scene
        XCTAssertThrowsError(try ScenePainter.image(revision:p.current,frame:0))
        scene.fontName=nil;scene.title="\u{10FFFF}";p.revisions[0].scenes[0]=scene
        XCTAssertThrowsError(try ScenePainter.image(revision:p.current,frame:0))
    }

    func testDecodedBlackFrameCannotPassCadenceInspection() throws {
        var buffer:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,64,64,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nil,&buffer),kCVReturnSuccess)
        let image=try XCTUnwrap(buffer)
        func fill(_ luma:UInt8) {
            CVPixelBufferLockBaseAddress(image,[])
            let stride=CVPixelBufferGetBytesPerRowOfPlane(image,0),height=CVPixelBufferGetHeightOfPlane(image,0)
            memset(CVPixelBufferGetBaseAddressOfPlane(image,0),Int32(luma),stride*height)
            CVPixelBufferUnlockBaseAddress(image,[])
        }
        fill(16);XCTAssertThrowsError(try MediaInspection.verifyVisibleFrame(image,frame:29))
        fill(22);XCTAssertThrowsError(try MediaInspection.verifyVisibleFrame(image,frame:0))
        fill(180);XCTAssertNoThrow(try MediaInspection.verifyVisibleFrame(image,frame:0))
    }

    func testReferencedLayerSourceHashIsCheckedBeforeCacheOrRendering() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("video-layer-integrity-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root),workspace=Workspace(name:"素材完整性",owner:"tester")
        let sourceText=Data(EditorPracticeRules.sourceText.utf8),source=try repo.ingest(sourceText,name:"practice.txt",workspaceID:workspace.id,mediaType:"text")
        var project=try LearningExample.project(workspaceID:workspace.id,asset:source)
        let picture=try repo.ingest(ScenePainter.png(ScenePainter.image(revision:project.current,frame:0)),name:"layer.png",workspaceID:workspace.id,mediaType:"image/png")
        project.revisions[0].scenes[0].layers=[SceneLayer(kind:.image,assetID:picture.id,endFrame:30)]
        try repo.transaction{$0.workspaces=[workspace];$0.assets=[source,picture];$0.products=[project.current.product!];$0.projects=[project]}
        var corrupt=try Data(contentsOf:repo.assetURL(picture));corrupt.append(0);try corrupt.write(to:repo.assetURL(picture),options:.atomic)
        do{_ = try await MediaRenderer().render(revision:project.current,repository:repo,output:root.appendingPathComponent("failed"));XCTFail("tampered layer was rendered")}
        catch{XCTAssertEqual((error as? VideoError)?.exitCode,5)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("failed/video.mp4").path))
    }

    func testDualAspectAAC48ExportAndFrozenPriceFrames()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("video-media-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root);let w=Workspace(name:"媒体夹具",owner:"tester");try repo.transaction{$0.workspaces.append(w)}
        let p=Product(workspaceID:w.id,sku:"synthetic-qa",name:"上下文课",checkout:"https://example.com/qa",audience:"验收角色",task:"理解上下文",outcome:"复现变化",prerequisite:"会输入文字",scope:"容量与压缩",prices:[Price(money:Money(99),from:Date(timeIntervalSince1970:0),source:"合成验收材料",verified:true)])
        let a=Scene(title:"容量有限",body:"输入和输出共同占用容量。",durationFrames:30);var b=Scene(title:"核对当前产品",body:"这是合成验收材料，不代表真实销售。",durationFrames:30);b.showPrice=true
        var revision=Revision(product:p,purpose:.course,aspect:.landscape,scenes:[a,b],cta:"查看真实内容与前置条件")
        let first=try ScenePainter.png(ScenePainter.image(revision:revision,frame:0));let last=try ScenePainter.png(ScenePainter.image(revision:revision,frame:59));var changed=revision;changed.id=Codec.id();changed.number=2;changed.product!.prices[0].money=Money(200)
        XCTAssertEqual(Codec.hash(first),Codec.hash(try ScenePainter.png(ScenePainter.image(revision:changed,frame:0))));XCTAssertNotEqual(Codec.hash(last),Codec.hash(try ScenePainter.png(ScenePainter.image(revision:changed,frame:59))))
        for aspect in Aspect.allCases{revision.aspect=aspect;let result=try await MediaRenderer().render(revision:revision,repository:repo,output:root.appendingPathComponent(aspect == .landscape ? "wide":"tall"));let video=try XCTUnwrap(result.artifacts.first{$0.mime=="video/mp4"});let info=try await MediaInspection.inspect(URL(fileURLWithPath:video.path));XCTAssertEqual(info.width,aspect.width);XCTAssertEqual(info.height,aspect.height);XCTAssertEqual(info.videoCodec,"avc1");XCTAssertEqual(info.audioCodec,"aac ");XCTAssertEqual(info.sampleRate,48000);XCTAssertEqual(info.h264ChromaFormatIDC,1);XCTAssertEqual(info.h264BitDepthLuma,8);XCTAssertEqual(info.h264BitDepthChroma,8);XCTAssertTrue(info.isH2644208Bit);XCTAssertTrue(info.isBT709);XCTAssertEqual(info.colorPrimaries,kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String);XCTAssertEqual(info.transferFunction,kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String);XCTAssertEqual(info.ycbcrMatrix,kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String);XCTAssertEqual(info.duration,2,accuracy:0.15);XCTAssertEqual(result.artifacts.count,4);XCTAssertEqual(video.sha256,Codec.hash(try Data(contentsOf:URL(fileURLWithPath:video.path))))}
    }
    func testSubtitleRetimingUsesClipMapping()throws{
        let p=Product(workspaceID:"w",sku:"q",name:"q",checkout:"https://example.com",audience:"a",task:"t",outcome:"o",prerequisite:"p",scope:"s",prices:[Price(money:Money(1),source:"test")]);var s=Scene(title:"t",body:"b",durationFrames:120);s.speed=2;s.captions=[Caption(text:"99元 / AI",startFrame:30,endFrame:90,confirmed:true)];let r=Revision(product:p,purpose:.education,aspect:.portrait,scenes:[s],cta:"复现");XCTAssertTrue(try MediaRenderer.subtitles(r).contains("00:00:00,500 --> 00:00:01,500"))
    }
    func testVisualCacheIdentityBindsTheActualWriterConfigurationAndFrameworkBuilds() throws {
        let scene=Scene(title:"缓存身份",body:"编码参数来自同一配置。",durationFrames:15)
        for aspect in Aspect.allCases {
            let revision=try Planner.create(workspaceID:"w",name:"编码配置",aspect:aspect,scenes:[scene])
            let configuration=try VisualClipCache.EncodingConfiguration.capture(aspect:aspect,fps:revision.fps)
            let settings=configuration.writerSettings
            let compression=try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String:Any])
            let colors=try XCTUnwrap(settings[AVVideoColorPropertiesKey] as? [String:Any])
            XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType,.h264)
            XCTAssertEqual(settings[AVVideoWidthKey] as? Int,aspect.width)
            XCTAssertEqual(settings[AVVideoHeightKey] as? Int,aspect.height)
            XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int,2_500_000)
            XCTAssertEqual(compression[AVVideoExpectedSourceFrameRateKey] as? Int,30)
            XCTAssertEqual(compression[AVVideoAllowFrameReorderingKey] as? Bool,false)
            XCTAssertEqual(compression[AVVideoMaxKeyFrameIntervalKey] as? Int,60)
            XCTAssertEqual(compression[AVVideoProfileLevelKey] as? String,AVVideoProfileLevelH264HighAutoLevel)
            XCTAssertEqual(colors[AVVideoColorPrimariesKey] as? String,AVVideoColorPrimaries_ITU_R_709_2)
            XCTAssertEqual(colors[AVVideoTransferFunctionKey] as? String,AVVideoTransferFunction_ITU_R_709_2)
            XCTAssertEqual(colors[AVVideoYCbCrMatrixKey] as? String,AVVideoYCbCrMatrix_ITU_R_709_2)
            XCTAssertEqual(configuration.pixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? UInt32,kCVPixelFormatType_32ARGB)
            XCTAssertEqual(configuration.mediaTimeScale,30_000)
            XCTAssertEqual(configuration.fileType,AVFileType.mp4.rawValue)
            let key=try VisualClipCache.fingerprint(revision:revision,index:0,database:Database(),modules:nil,encoding:configuration)
            XCTAssertEqual(key,try VisualClipCache.fingerprint(revision:revision,index:0,database:Database(),modules:nil))
            func changesKey(_ change:(inout VisualClipCache.EncodingConfiguration)->Void) throws {
                var changed=configuration; change(&changed)
                XCTAssertNotEqual(key,try VisualClipCache.fingerprint(revision:revision,index:0,database:Database(),modules:nil,encoding:changed))
            }
            try changesKey{$0.averageBitRate += 1}
            try changesKey{$0.allowsFrameReordering=true}
            try changesKey{$0.maximumKeyFrameInterval += 1}
            try changesKey{$0.profileLevel=AVVideoProfileLevelH264MainAutoLevel}
            try changesKey{$0.colorPrimaries=AVVideoColorPrimaries_ITU_R_2020}
            try changesKey{$0.transferFunction=AVVideoTransferFunction_Linear}
            try changesKey{$0.ycbcrMatrix=AVVideoYCbCrMatrix_ITU_R_2020}
            try changesKey{$0.pixelFormat=kCVPixelFormatType_32BGRA}
            try changesKey{$0.mediaTimeScale += 1}
            // A changed build here is an isolated identity fixture, not a claim that
            // the machine's actual codec or frameworks have been upgraded.
            try changesKey{$0.frameworks[0].buildVersion="different-test-build"}
            try changesKey{$0.frameworks[1].buildVersion="different-test-build"}
        }
    }

    func testMissingFrameworkIdentityRendersWithoutPersistentCacheReuse() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("video-cache-unidentified-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root),workspace=Workspace(name:"依赖身份缺失",owner:"tester")
        try repo.transaction{$0.workspaces=[workspace]}
        let scene=Scene(title:"依赖身份缺失",body:"仍可制作，不复用未知缓存。",durationFrames:15)
        let revision=try Planner.create(workspaceID:workspace.id,name:"未知编码依赖",aspect:.landscape,scenes:[scene])
        var configuration=try VisualClipCache.EncodingConfiguration.capture(aspect:revision.aspect,fps:revision.fps)
        configuration.frameworks[0] = .init(expectedIdentifier:"com.apple.avfoundation",bundle:nil)
        XCTAssertFalse(configuration.canReusePersistentCache)
        for name in ["first.mp4","second.mp4"] {
            let output=root.appendingPathComponent(name)
            let hits=try await VisualClipCache.compose(revision:revision,repository:repo,database:repo.read(),output:output,modules:nil,encoding:configuration,progress:{_ in})
            XCTAssertEqual(hits,0)
            let tracks=try await AVURLAsset(url:output).loadTracks(withMediaType:.video)
            XCTAssertEqual(tracks.count,1)
            let descriptions=try await XCTUnwrap(tracks.first).load(.formatDescriptions)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first)),kCMVideoCodecType_H264)
        }
        let cache=root.appendingPathComponent("cache")
        let files=try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)
        XCTAssertFalse(files.contains{$0.lastPathComponent.hasPrefix("visuals")},"未知依赖的临时编码不得留成共享缓存")
    }

    func testActualSceneCacheReusesUnaffectedClipAndRejectsCorruptionOrToolchainChange()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("video-cache-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root);let w=Workspace(name:"缓存夹具",owner:"tester");try repo.transaction{$0.workspaces.append(w)}
        let product=Product(workspaceID:w.id,sku:"cache",name:"课程",checkout:"https://example.com",audience:"学习者",task:"核对",outcome:"可复现",prerequisite:"无",scope:"缓存",prices:[Price(money:Money(99),from:.distantPast,source:"合成测试",verified:true)])
        let a=Scene(title:"知识",body:"知识保持不变。",durationFrames:15);var b=Scene(title:"课程",body:"价格来自产品快照。",durationFrames:15);b.showPrice=true
        var r=Revision(product:product,purpose:.course,aspect:.landscape,scenes:[a,b],cta:"查看原课程")
        let first=try await MediaRenderer().render(revision:r,repository:repo,output:root.appendingPathComponent("one"));XCTAssertTrue(first.warnings.contains{$0.contains("0/2")})
        r.id=Codec.id();r.number=2;r.product!.prices[0].money=Money(200)
        let changed=try await MediaRenderer().render(revision:r,repository:repo,output:root.appendingPathComponent("two"));XCTAssertTrue(changed.warnings.contains{$0.contains("1/2")})
        let cached=try await MediaRenderer().render(revision:r,repository:repo,output:root.appendingPathComponent("three"));XCTAssertTrue(cached.warnings.contains{$0.contains("2/2")})
        func frame(_ result:RenderResult,_ at:Int)throws->String {let url=URL(fileURLWithPath:result.artifacts.first{$0.mime=="video/mp4"}!.path);let g=AVAssetImageGenerator(asset:AVURLAsset(url:url));g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter = .zero;return Codec.hash(try ScenePainter.png(g.copyCGImage(at:CMTime(value:Int64(at),timescale:30),actualTime:nil)))}
        XCTAssertEqual(try frame(first,0),try frame(changed,0));XCTAssertNotEqual(try frame(first,29),try frame(changed,29))
        let directory=root.appendingPathComponent("cache/visuals");for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where file.pathExtension=="mp4" {try Data("corrupt".utf8).write(to:file,options:.atomic)}
        let rebuilt=try await MediaRenderer().render(revision:r,repository:repo,output:root.appendingPathComponent("four"));XCTAssertTrue(rebuilt.warnings.contains{$0.contains("0/2")})
        // This checks explicit toolchain namespacing, not an actual codec upgrade.
        r.toolchain="changed-toolchain-marker";let changedToolchain=try await MediaRenderer().render(revision:r,repository:repo,output:root.appendingPathComponent("five"));XCTAssertTrue(changedToolchain.warnings.contains{$0.contains("0/2")})
    }
}
