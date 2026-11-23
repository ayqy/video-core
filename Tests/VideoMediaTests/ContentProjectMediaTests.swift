import XCTest
import AVFoundation
import VideoCore
@testable import VideoMedia

final class ContentProjectMediaTests:XCTestCase {
    func testOrdinaryJobRendersRealMediaWithoutProductAndBackupRestoresArtifacts()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("content-media-"+UUID().uuidString)
        let restoredRoot=FileManager.default.temporaryDirectory.appendingPathComponent("content-media-restored-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:restoredRoot)}
        let repo=try Repository(root:root),workspace=Workspace(name:"隔离媒体规则",owner:"owner")
        var scene=Scene(title:"观察状态",body:"操作后对照前后结果。",durationFrames:30)
        scene.captions=[Caption(text:"操作后对照前后结果。",startFrame:0,endFrame:30)]
        var revision=try Planner.create(workspaceID:workspace.id,name:"普通教学剪辑",scenes:[scene])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[])
        let project=Project(workspaceID:workspace.id,name:"普通教学剪辑",revision:revision)
        let quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(300),confirmed:true)
        let job=try JobRules.submit(workspaceID:workspace.id,project:project,quote:quote,requestKey:"normal",existing:[],budget:BudgetPolicy())
        try repo.transaction{$0.workspaces=[workspace];$0.projects=[project];$0.jobs=[job]}
        let result=try await LocalJobExecutor.run(repository:repo,jobID:job.id,owner:"host-rule")
        XCTAssertEqual(result.state,.needsReview);XCTAssertEqual(result.artifacts.count,4)
        XCTAssertTrue(try repo.read().products.isEmpty);XCTAssertNil(try repo.read().projects[0].current.product)
        try repo.verifyDelivery(result,revision:revision)
        let video=try XCTUnwrap(result.artifacts.first{$0.mime=="video/mp4"})
        let inspection=try await MediaInspection.inspect(URL(fileURLWithPath:video.path))
        XCTAssertEqual(inspection.width,1280);XCTAssertEqual(inspection.height,720);XCTAssertEqual(inspection.duration,1,accuracy:0.1)
        XCTAssertEqual(inspection.videoCodec,"avc1");XCTAssertEqual(inspection.audioCodec,"aac ");XCTAssertEqual(inspection.sampleRate,48000)
        let cover=try XCTUnwrap(result.artifacts.first{$0.mime=="image/png"})
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:URL(fileURLWithPath:video.path)))
        generator.appliesPreferredTrackTransform=true;generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let first=try generator.copyCGImage(at:.zero,actualTime:nil)
        XCTAssertEqual(cover.sha256,Codec.hash(try ScenePainter.png(first)),"独立封面须等于同版视频的实际首帧，不重复套模板")
        let body=try generator.copyCGImage(at:CMTime(value:1,timescale:30),actualTime:nil)
        XCTAssertNotEqual(Codec.hash(try ScenePainter.png(first)),Codec.hash(try ScenePainter.png(body)),"只替换零帧，下一帧恢复原场景")
        let notes=try XCTUnwrap(result.artifacts.first{$0.mime=="text/plain"})
        let text=try String(contentsOf:URL(fileURLWithPath:notes.path),encoding:.utf8)
        XCTAssertTrue(text.contains("普通教学剪辑"));XCTAssertFalse(text.contains("SKU："));XCTAssertFalse(text.contains("已有承接页："))
        let restored=try Repository.restore(repo.backup(),to:restoredRoot),database=try restored.read()
        XCTAssertTrue(database.products.isEmpty);XCTAssertEqual(database.projects[0].current.schemaVersion,2)
        XCTAssertEqual(database.projects[0].current.contentContext?.id,revision.contentContext?.id)
        let restoredJob=try XCTUnwrap(database.jobs.first{$0.id==job.id});try restored.verifyDelivery(restoredJob,revision:database.projects[0].current)
        XCTAssertEqual(restoredJob.artifacts.map(\.sha256),result.artifacts.map(\.sha256))
    }
    func testCoverCacheInvalidatesFirstSceneForLayoutAndSelectedSourceOnly()throws {
        var revision=try Planner.create(workspaceID:"w",name:"封面依赖",scenes:[
            Scene(title:"首景",body:"同版源画面",durationFrames:15),Scene(title:"正文",body:"保留缓存",durationFrames:15)])
        let selected=Asset(workspaceID:"w",name:"hero.png",hash:String(repeating:"a",count:64),ext:"png",bytes:100,mediaType:"image/png")
        let unused=Asset(workspaceID:"w",name:"unused.png",hash:String(repeating:"b",count:64),ext:"png",bytes:100,mediaType:"image/png")
        var database=Database();database.assets=[selected,unused]
        revision.coverPresentation=CoverPresentation(style:.media,template:.spotlight,title:"封面标题",hero:CoverImage(assetID:selected.id))
        let configuration=try VisualClipCache.EncodingConfiguration.capture(aspect:revision.aspect,fps:revision.fps)
        func key(_ index:Int)throws->String {try VisualClipCache.fingerprint(revision:revision,index:index,database:database,modules:nil,encoding:configuration)}
        let first=try key(0),body=try key(1)
        database.assets[1].hash=String(repeating:"c",count:64)
        XCTAssertEqual(try key(0),first,"未选用图片不影响当前封面")
        database.assets[0].hash=String(repeating:"d",count:64)
        XCTAssertNotEqual(try key(0),first,"选用图片变更须使首镜缓存失效")
        XCTAssertEqual(try key(1),body,"封面图片不污染后续镜头缓存")
        let changedSource=try key(0)
        revision.coverPresentation?.title="新的封面标题"
        XCTAssertNotEqual(try key(0),changedSource);XCTAssertEqual(try key(1),body)
        let changedTitle=try key(0)
        revision.coverPresentation?.template = .contrast
        XCTAssertNotEqual(try key(0),changedTitle);XCTAssertEqual(try key(1),body)
    }
    func testPresenterExplicitSettingIsBoundOnlyToFirstCoverCache()throws {
        var revision=try Planner.create(workspaceID:"w",name:"囚徒困境",scenes:[Scene(title:"首景",body:"同版正文",durationFrames:15),Scene(title:"尾景",body:"保原时轴",durationFrames:15)])
        let setting=Asset(workspaceID:"w",name:"actual-setting.png",hash:String(repeating:"a",count:64),ext:"png",bytes:100,mediaType:"image/png")
        var database=Database();database.assets=[setting]
        revision.coverPresentation=CoverPresentation(style:.presenter,title:"囚徒困境",setting:CoverImage(assetID:setting.id))
        let configuration=try VisualClipCache.EncodingConfiguration.capture(aspect:revision.aspect,fps:revision.fps)
        let cover=try VisualClipCache.fingerprint(revision:revision,index:0,database:database,modules:nil,encoding:configuration),body=try VisualClipCache.fingerprint(revision:revision,index:1,database:database,modules:nil,encoding:configuration)
        database.assets[0].hash=String(repeating:"b",count:64)
        XCTAssertNotEqual(cover,try VisualClipCache.fingerprint(revision:revision,index:0,database:database,modules:nil,encoding:configuration))
        XCTAssertEqual(body,try VisualClipCache.fingerprint(revision:revision,index:1,database:database,modules:nil,encoding:configuration))
        XCTAssertThrowsError(try CoverRules.validate(revision:revision,assets:[]),"实际场景缺失不能退回普通底色")
    }
    func testOnlyPresenterDrawingVersionInvalidatesFirstCoverWhileOtherStylesKeepLegacyKeys()throws {
        struct Legacy:Encodable {
            var version="cover-first-frame-2";var presentation:CoverPresentation;var images:[String:String];var fonts:[String];var islandStyle:String;var noticeBoard:String
        }
        var revision=try Planner.create(workspaceID:"w",name:"囚徒困境",scenes:[Scene(title:"首景",body:"正文保持",durationFrames:15),Scene(title:"尾景",body:"原时轴",durationFrames:15)])
        let database=Database(),configuration=try VisualClipCache.EncodingConfiguration.capture(aspect:revision.aspect,fps:revision.fps)
        var bodyKey:String?
        for style in [CoverStyle.presenter,.code,.pencil,.media,.explanation,.game] {
            revision.coverPresentation=CoverPresentation(style:style,template:.spotlight,title:"囚徒困境",emphasis:["囚徒困境"])
            let resolved=try CoverRules.resolved(revision:revision)
            let presentation=CoverPresentation(style:resolved.style,template:resolved.template,title:resolved.title,hero:resolved.hero,background:resolved.background,emphasis:resolved.emphasis.isEmpty ? nil:resolved.emphasis,quantityGraphic:resolved.quantityGraphic)
            let legacy=try Codec.digest(Legacy(presentation:presentation,images:[:],fonts:[CoverTypeface.sourceSHA256,CoverDisplayTypeface.sourceSHA256,IslandTypeface.sourceSHA256],islandStyle:IslandTheme.styleVersion,noticeBoard:CommunityNoticeBoardArtwork.sha256))
            let actual=try VisualClipCache.firstFrameCoverFingerprint(revision:revision,database:database)
            if style == .presenter {XCTAssertNotEqual(actual,legacy,"仅新解说员布局必须重绘首帧")}
            else {XCTAssertEqual(actual,legacy,"未改风格应保原有首帧缓存身份")}
            let current=try VisualClipCache.fingerprint(revision:revision,index:1,database:database,modules:nil,encoding:configuration)
            if let bodyKey {XCTAssertEqual(current,bodyKey,"封面布局及版本均不污染正文缓存")} else {bodyKey=current}
        }
    }
    func testCoverOnlyEditKeepsCompleteSoundtrackCaptionsCadenceAndBodyInBothAspects()async throws {
        let retained=ProcessInfo.processInfo.environment["FF_COVER_REGRESSION_OUTPUT"]
        let root=retained.map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("cover-first-frame-"+UUID().uuidString)
        if retained != nil {XCTAssertFalse(FileManager.default.fileExists(atPath:root.path),"证据输出必须使用新目录，不能覆盖既有产物")}
        defer{if retained==nil {try? FileManager.default.removeItem(at:root)}}
        var proof=["# 首帧封面正常渲染回归", "", "仅验证技术与原时轴保持；测试音不代表中文听审，封面视觉和全类型效果仍待验收。", ""]
        let repo=try Repository(root:root.appendingPathComponent("workspace"))
        let tone=root.appendingPathComponent("original.caf")
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000));buffer.frameLength=48000
        for i in 0..<48000 {buffer.floatChannelData![0][i]=Float(sin(Double(i)*2 * .pi*440/48000)*0.1)}
        do {let file=try AVAudioFile(forWriting:tone,settings:format.settings);try file.write(from:buffer)}
        let original=try Data(contentsOf:tone)
        let audio=try repo.ingest(original,name:"original.caf",workspaceID:"w",mediaType:"audio",durationFrames:30)
        func coverFixture(_ presenter:Bool)throws->CGImage {
            let w=presenter ? 100:80,h=presenter ? 120:140
            let c=try XCTUnwrap(CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.clear(CGRect(x:0,y:0,width:w,height:h))
            c.setFillColor(CGColor(srgbRed:presenter ? 0.9:0.2,green:0.4,blue:presenter ? 0.3:0.9,alpha:1))
            c.fillEllipse(in:CGRect(x:presenter ? 42:15,y:presenter ? 60:95,width:45,height:45))
            c.fill(CGRect(x:presenter ? 42:20,y:0,width:40,height:presenter ? 65:100))
            if presenter {c.fill(CGRect(x:0,y:45,width:55,height:12))}
            return try XCTUnwrap(c.makeImage())
        }
        let ip=try repo.ingest(ScenePainter.png(coverFixture(true)),name:"presenter-fixture.png",workspaceID:"w",mediaType:"image/png")
        let subject=try repo.ingest(ScenePainter.png(coverFixture(false)),name:"subject-fixture.png",workspaceID:"w",mediaType:"image/png")
        let contextSetting=try repo.ingest(ScenePainter.png(coverFixture(false)),name:"setting-fixture.png",workspaceID:"w",mediaType:"image/png")
        try repo.transaction{$0.assets=[audio,ip,subject,contextSetting]}
        func samples(_ url:URL,media:AVMediaType)async throws->[(Double,Double,String)] {
            let asset=AVURLAsset(url:url)
            let reader=try AVAssetReader(asset:asset)
            let tracks=try await asset.loadTracks(withMediaType:media)
            let output=AVAssetReaderTrackOutput(track:try XCTUnwrap(tracks.first),outputSettings:nil)
            reader.add(output);XCTAssertTrue(reader.startReading())
            var result:[(Double,Double,String)]=[]
            while let sample=output.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample)>0 else {continue}
                let block=try XCTUnwrap(CMSampleBufferGetDataBuffer(sample)),count=CMBlockBufferGetDataLength(block)
                var data=Data(count:count)
                let status=data.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count,destination:$0.baseAddress!)}
                XCTAssertEqual(status,kCMBlockBufferNoErr)
                result.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds,CMSampleBufferGetDuration(sample).seconds,Codec.hash(data)))
            }
            XCTAssertEqual(reader.status,.completed);return result
        }
        func pixels(_ image:CGImage)throws->[UInt8] {
            var data=[UInt8](repeating:0,count:image.width*image.height*4)
            try data.withUnsafeMutableBytes {raw in
                let context=try XCTUnwrap(CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            };return data
        }
        func difference(_ a:CGImage,_ b:CGImage)throws->Double {
            let left=try pixels(a),right=try pixels(b)
            return zip(left,right).enumerated().reduce(0.0){value,pair in pair.offset%4==3 ? value:value+Double(abs(Int(pair.element.0)-Int(pair.element.1)))}/Double(a.width*a.height*3)
        }
        for aspect in Aspect.allCases {
            var scene=Scene(title:"观察结果",body:"完整旁白、字幕与正文保持原时序。",narration:"隔离原声",durationFrames:30)
            scene.captions=[Caption(text:"正文字幕保持。",startFrame:0,endFrame:30)]
            scene.voice=VoiceTake(assetID:audio.id,textDigest:try scene.speechDigest(),durationFrames:30,method:"isolated_test_tone")
            let ending=Scene(title:"最后画面",body:"片尾仍保留。",durationFrames:15)
            var revision=try Planner.create(workspaceID:"w",name:"首帧同版封面",aspect:aspect,scenes:[scene,ending])
            var results:[RenderResult]=[]
            for style in [CoverStyle.explanation,.presenter] {
            for template in [CoverTemplate.spotlight,.contrast] {
                revision.coverPresentation=CoverPresentation(style:style,template:template,title:template == .spotlight ? "观察结果":"结果保持",hero:style == .presenter ? CoverImage(assetID:ip.id,pointing:.left,figureFraming:.fullFigure):nil,background:style == .presenter ? CoverImage(assetID:subject.id):nil,setting:style == .presenter ? CoverImage(assetID:contextSetting.id):nil,emphasis:["结果"])
                revision.dependencies=try DependencyRules.freeze(revision:revision,assets:repo.read().assets,evidence:[])
                let images=try CoverPainter.loadImages(revision:revision,repository:repo,database:repo.read())
                let expectedCover=try CoverPainter.image(revision:revision,source:ScenePainter.image(revision:revision,frame:0),images:images)
                let result=try await MediaRenderer().render(revision:revision,repository:repo,output:root.appendingPathComponent(aspect.rawValue+style.rawValue+template.rawValue))
                let video=URL(fileURLWithPath:try XCTUnwrap(result.artifacts.first{$0.mime=="video/mp4"}).path)
                let generator=AVAssetImageGenerator(asset:AVURLAsset(url:video));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                let first=try generator.copyCGImage(at:.zero,actualTime:nil)
                let firstDifference=try difference(first,expectedCover)
                XCTAssertLessThan(firstDifference,8,"编码后的零帧须保完整模板内容")
                XCTAssertEqual(Codec.hash(try ScenePainter.png(first)),try XCTUnwrap(result.artifacts.first{$0.mime=="image/png"}).sha256)
                var bodyDifference=0.0
                for frame in [1,15,29,30,44] {
                    let decoded=try generator.copyCGImage(at:CMTime(value:Int64(frame),timescale:30),actualTime:nil)
                    let error=try difference(decoded,ScenePainter.image(revision:revision,frame:frame))
                    bodyDifference=max(bodyDifference,error)
                    XCTAssertLessThan(error,8,"封面不得覆盖或移位任何正文/片尾画面")
                }
                let cadence=try await samples(video,media:.video)
                XCTAssertEqual(cadence.count,45)
                for (frame,sample) in cadence.enumerated(){XCTAssertEqual(sample.0,Double(frame)/30,accuracy:0.0001)}
                let captions=try XCTUnwrap(result.artifacts.first{$0.mime=="application/x-subrip"})
                XCTAssertEqual(try String(contentsOfFile:captions.path,encoding:.utf8),try MediaRenderer.subtitles(revision))
                proof.append("- \(aspect.rawValue) / \(style.rawValue) / \(template.rawValue)：45帧、0…44全部PTS精确；首帧RGB平均误差 \(firstDifference)，正文/片尾指定帧最大平均误差 \(bodyDifference)；首帧PNG与独立封面hash精确相同；字幕同原SRT。视频：\(video.path)")
                results.append(result)
            }
            }
            let firstVideo=URL(fileURLWithPath:try XCTUnwrap(results[0].artifacts.first{$0.mime=="video/mp4"}).path)
            let firstAudio=try await samples(firstVideo,media:.audio)
            XCTAssertFalse(firstAudio.isEmpty)
            for other in results.dropFirst() {
                let nextVideo=URL(fileURLWithPath:try XCTUnwrap(other.artifacts.first{$0.mime=="video/mp4"}).path)
                let nextAudio=try await samples(nextVideo,media:.audio)
                XCTAssertEqual(firstAudio.map{$0.0},nextAudio.map{$0.0});XCTAssertEqual(firstAudio.map{$0.1},nextAudio.map{$0.1})
                XCTAssertEqual(firstAudio.map{$0.2},nextAudio.map{$0.2},"说明与解说员两类型、两封面的完整AAC压缩流字节与时序须保持")
            }
            XCTAssertEqual(try Data(contentsOf:repo.assetURL(audio)),original)
            proof.append("- \(aspect.rawValue)：两类型两模板完整 \(firstAudio.count) 个AAC压缩样本缓冲的全量payload字节、PTS和duration精确相同；完整原音源hash \(Codec.hash(original)) 保持。")
        }
        if retained != nil {try proof.joined(separator:"\n").write(to:root.appendingPathComponent("regression.md"),atomically:true,encoding:.utf8)}
    }
    func testEmptyContentDraftCannotRenderOrDrawUnprovenProductPrice()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("content-empty-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root),empty=try Planner.create(workspaceID:"w",name:"真实空工程")
        do{_=try await MediaRenderer().render(revision:empty,repository:repo,output:root.appendingPathComponent("rejected"));XCTFail("empty draft rendered")}
        catch{XCTAssertEqual((error as? VideoError)?.exitCode,5)}
        var price=try Planner.create(workspaceID:"w",name:"无商品说明",scenes:[Scene(title:"说明",body:"实际内容",durationFrames:30)])
        price.scenes[0].showPrice=true
        XCTAssertThrowsError(try ScenePainter.image(revision:price,frame:0))
    }
}
