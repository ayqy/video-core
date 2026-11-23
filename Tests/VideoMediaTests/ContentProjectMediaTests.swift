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
        try repo.transaction{$0.assets=[audio]}
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
            for template in [CoverTemplate.spotlight,.contrast] {
                revision.coverPresentation=CoverPresentation(style:.explanation,template:template,title:template == .spotlight ? "观察结果":"结果保持",emphasis:["结果"])
                let expectedCover=try CoverPainter.image(revision:revision,source:ScenePainter.image(revision:revision,frame:0))
                let result=try await MediaRenderer().render(revision:revision,repository:repo,output:root.appendingPathComponent(aspect.rawValue+template.rawValue))
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
                proof.append("- \(aspect.rawValue) / \(template.rawValue)：45帧、0…44全部PTS精确；首帧RGB平均误差 \(firstDifference)，正文/片尾指定帧最大平均误差 \(bodyDifference)；首帧PNG与独立封面hash精确相同；字幕同原SRT。视频：\(video.path)")
                results.append(result)
            }
            let firstVideo=URL(fileURLWithPath:try XCTUnwrap(results[0].artifacts.first{$0.mime=="video/mp4"}).path)
            let nextVideo=URL(fileURLWithPath:try XCTUnwrap(results[1].artifacts.first{$0.mime=="video/mp4"}).path)
            let firstAudio=try await samples(firstVideo,media:.audio),nextAudio=try await samples(nextVideo,media:.audio)
            XCTAssertFalse(firstAudio.isEmpty);XCTAssertEqual(firstAudio.map{$0.0},nextAudio.map{$0.0})
            XCTAssertEqual(firstAudio.map{$0.1},nextAudio.map{$0.1});XCTAssertEqual(firstAudio.map{$0.2},nextAudio.map{$0.2},"仅换封面须保完整AAC压缩流字节与时序")
            XCTAssertEqual(try Data(contentsOf:repo.assetURL(audio)),original)
            proof.append("- \(aspect.rawValue)：两封面版本完整 \(firstAudio.count) 个AAC压缩样本缓冲的全量payload字节、PTS和duration精确相同；完整原音源hash \(Codec.hash(original)) 保持。")
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
