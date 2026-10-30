import XCTest
import VideoCore
@testable import VideoMedia
@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics

final class VisualCacheResumeTests:XCTestCase {
    private enum Interrupted:Error {case checkpoint}
    private final class Progress:@unchecked Sendable {
        private let lock=NSLock()
        private var storage:[Double]=[]
        let stop:Double?
        init(stop:Double?=nil) {self.stop=stop}
        func record(_ value:Double)throws {
            lock.lock();storage.append(value);lock.unlock()
            if let stop,value>=stop {throw Interrupted.checkpoint}
        }
        var values:[Double] {lock.lock();defer{lock.unlock()};return storage}
    }
    private func repository()throws->(URL,Repository,Workspace) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("visual-checkpoints-"+UUID().uuidString)
        let repo=try Repository(root:root),workspace=Workspace(name:"完整区间恢复",owner:"tester")
        try repo.transaction{$0.workspaces=[workspace]}
        return(root,repo,workspace)
    }
    private func configuration(_ revision:Revision)throws->VisualClipCache.EncodingConfiguration {
        let result=try VisualClipCache.EncodingConfiguration.capture(aspect:revision.aspect,fps:revision.fps)
        guard result.canReusePersistentCache else {throw XCTSkip("此机器没有完整可识别的编码器与框架，原有transient测试覆盖此分支")}
        return result
    }
    private func revision(_ workspace:Workspace,frames:Int=247)->Revision {
        var scene=Scene(title:"分段恢复",body:"同一时间轴，完成区间保留。",durationFrames:frames)
        scene.paperPresentation=PaperPresentation()
        var block=SceneLayer(kind:.rectangle,endFrame:frames)
        block.x=0.2;block.y=0.45;block.width=0.16;block.height=0.18;block.color="E54B4B"
        block.keyframes=[Keyframe(frame:0,x:0.2,y:0.45,scale:1),Keyframe(frame:frames-1,x:0.8,y:0.45,scale:1)]
        scene.layers=[block]
        scene.captions=[Caption(text:"上一段动作持续",startFrame:0,endFrame:120),Caption(text:"跨过边界继续",startFrame:120,endFrame:frames)]
        return Revision(contentContext:ContentContext(workspaceID:workspace.id,name:"同一源轴"),aspect:.landscape,scenes:[scene])
    }
    private func interval(_ revision:Revision,index:Int=0,range:Range<Int>,repo:Repository,
                          encoding:VisualClipCache.EncodingConfiguration)throws->(VisualClipCache.Interval,URL,URL) {
        let key=try VisualClipCache.fingerprint(revision:revision,index:index,database:repo.read(),modules:nil,encoding:encoding)
        let interval=VisualClipCache.Interval(sceneKey:key,lowerBound:range.lowerBound,upperBound:range.upperBound)
        let directory=repo.root.appendingPathComponent("cache/visuals"),name=try interval.key
        return(interval,directory.appendingPathComponent(name+".mp4"),directory.appendingPathComponent(name+".plist"))
    }
    private func compose(_ revision:Revision,repo:Repository,encoding:VisualClipCache.EncodingConfiguration,
                         name:String,progress:Progress=Progress())async throws->(Int,URL) {
        let output=repo.root.appendingPathComponent(name+".mp4")
        let hits=try await VisualClipCache.compose(revision:revision,repository:repo,database:repo.read(),output:output,
            modules:nil,encoding:encoding,progress:{try progress.record($0)})
        return(hits,output)
    }
    private struct Pixels {var points:[[Int]]}
    private func decode(_ url:URL,frames:Int,fps:Int=30)async throws->[Pixels] {
        let asset=AVURLAsset(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.video),track=try XCTUnwrap(tracks.first)
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData=false;reader.add(output);XCTAssertTrue(reader.startReading())
        var result:[Pixels]=[]
        while let sample=output.copyNextSampleBuffer() {
            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value:Int64(result.count),timescale:Int32(fps))),0,
                           "每一帧PTS必须连续，区间边界不能重播、漏帧或插入空隙")
            let buffer=try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            guard let address=CVPixelBufferGetBaseAddress(buffer) else {CVPixelBufferUnlockBaseAddress(buffer,.readOnly);throw VideoError.invalid("测试解码没有像素")}
            let bytes=address.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(buffer)
            let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer)
            var points:[[Int]]=[]
            for y in [height/5,height/2,height*4/5] {for x in [width/5,width/2,width*4/5] {
                var rgb=[0,0,0]
                for dy in -2...2 {for dx in -2...2 {
                    let offset=(y+dy)*stride+(x+dx)*4
                    rgb[0]+=Int(bytes[offset+2]);rgb[1]+=Int(bytes[offset+1]);rgb[2]+=Int(bytes[offset])
                }}
                points.append(rgb.map{$0/25})
            }}
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly);result.append(Pixels(points:points))
        }
        XCTAssertEqual(reader.status,.completed);XCTAssertEqual(result.count,frames)
        let duration=try await asset.load(.duration)
        XCTAssertEqual(CMTimeCompare(duration,CMTime(value:Int64(frames),timescale:Int32(fps))),0)
        return result
    }

    func testInterruptedSecondIntervalRetainsAndReusesTheFirstCompleteCheckpoint()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let r=revision(workspace),encoding=try configuration(r)
        let stop=Progress(stop:Double(120+15)/Double(r.frames)*0.75)
        do {_=try await compose(r,repo:repo,encoding:encoding,name:"interrupted",progress:stop);XCTFail("应在第二个区间中断")}
        catch Interrupted.checkpoint {}
        let(_,first,receipt)=try interval(r,range:0..<120,repo:repo,encoding:encoding)
        let saved=try Data(contentsOf:first),savedReceipt=try Data(contentsOf:receipt)
        let inode=(try FileManager.default.attributesOfItem(atPath:first.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        let files=try FileManager.default.contentsOfDirectory(at:first.deletingLastPathComponent(),includingPropertiesForKeys:nil)
        XCTAssertEqual(files.filter{$0.pathExtension=="mp4"}.count,1,"未完成的第二区间须删除，已完成首区间须保留")
        XCTAssertEqual(files.filter{$0.pathExtension=="plist"}.count,1)
        let progress=Progress(),(hits,resumed)=try await compose(r,repo:repo,encoding:encoding,name:"resumed",progress:progress)
        XCTAssertEqual(hits,0,"部分区间命中不能冒称整个scene命中")
        XCTAssertEqual(try XCTUnwrap(progress.values.first),Double(120)/Double(r.frames)*0.75,accuracy:0.0000001,
                       "恢复须先报告已有完整区间，不能重新绘制帧零")
        XCTAssertEqual(try Data(contentsOf:first),saved);XCTAssertEqual(try Data(contentsOf:receipt),savedReceipt)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:first.path)[.systemFileNumber] as? NSNumber)?.uint64Value,inode)
        _=try await decode(resumed,frames:r.frames)
        let(cached,again)=try await compose(r,repo:repo,encoding:encoding,name:"all-cached")
        XCTAssertEqual(cached,1);_=try await decode(again,frames:r.frames)
    }

    func testCorruptMissingAndWrongRangeReceiptsCannotAuthorizeReuse()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let r=revision(workspace),encoding=try configuration(r)
        _=try await compose(r,repo:repo,encoding:encoding,name:"original")
        let(_,first,receipt)=try interval(r,range:0..<120,repo:repo,encoding:encoding)
        let(_,second,_)=try interval(r,range:120..<240,repo:repo,encoding:encoding)
        let secondBytes=try Data(contentsOf:second)
        let originalReceipt=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt))
        for damage in 0..<5 {
            if damage==0 {try Data("truncated".utf8).write(to:first,options:.atomic)}
            if damage==1 {try FileManager.default.removeItem(at:first)}
            if damage==2 {var bad=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt));bad.artifact.frames-=1;try PropertyListEncoder().encode(bad).write(to:receipt,options:.atomic)}
            if damage==3 {var bad=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt));bad.interval.lowerBound=1;try PropertyListEncoder().encode(bad).write(to:receipt,options:.atomic)}
            if damage==4 {try FileManager.default.removeItem(at:receipt)}
            let(hits,video)=try await compose(r,repo:repo,encoding:encoding,name:"repaired-"+String(damage))
            XCTAssertEqual(hits,0);XCTAssertEqual(try Data(contentsOf:second),secondBytes,"修复坏块不得重绘相邻完整区间")
            let repaired=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt))
            XCTAssertEqual(repaired.interval,originalReceipt.interval);XCTAssertEqual(repaired.artifact.frames,120)
            XCTAssertEqual(repaired.artifact.sha256,Codec.hash(try Data(contentsOf:first)))
            _=try await decode(video,frames:r.frames)
        }
    }

    func testLegacyCompleteSceneIsPreferredWithoutCreatingIntervals()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let r=revision(workspace),encoding=try configuration(r)
        let directory=root.appendingPathComponent("cache/visuals")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let key=try VisualClipCache.fingerprint(revision:r,index:0,database:repo.read(),modules:nil,encoding:encoding)
        let clip=directory.appendingPathComponent(key+".mp4")
        try await VisualClipCache.renderClip(revision:r,index:0,startFrame:0,repository:repo,database:repo.read(),output:clip,modules:nil,encoding:encoding,progress:{_ in})
        let bytes=try Data(contentsOf:clip)
        let entry=VisualClipCache.Entry(key:key,bytes:bytes.count,sha256:Codec.hash(bytes),frames:r.frames)
        try PropertyListEncoder().encode(entry).write(to:directory.appendingPathComponent(key+".plist"),options:.atomic)
        let progress=Progress(),(hits,output)=try await compose(r,repo:repo,encoding:encoding,name:"legacy-hit",progress:progress)
        XCTAssertEqual(hits,1);XCTAssertEqual(progress.values,[0.75])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).count,2)
        XCTAssertEqual(try Data(contentsOf:clip),bytes);_=try await decode(output,frames:r.frames)
    }

    private func sourceVideo(_ url:URL,encoding:VisualClipCache.EncodingConfiguration)async throws {
        let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:encoding.writerSettings)
        input.mediaTimeScale=encoding.mediaTimeScale;input.expectsMediaDataInRealTime=false
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:encoding.pixelBufferAttributes)
        writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
        for frame in 0..<128 {
            while !input.isReadyForMoreMediaData {guard writer.status != .failed else{throw VideoError.unavailable("测试源编码失败")};try await Task.sleep(nanoseconds:1_000_000)}
            var optional:CVPixelBuffer?
            let pool=try XCTUnwrap(adaptor.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil,pool,&optional),kCVReturnSuccess)
            let buffer=try XCTUnwrap(optional);CVPixelBufferLockBaseAddress(buffer,[])
            let context=try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:encoding.width,height:encoding.height,bitsPerComponent:8,
                bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue))
            let colors:[[CGFloat]]=[[0.9,0.15,0.15],[0.15,0.85,0.15],[0.15,0.2,0.9],[0.9,0.85,0.15]]
            let c=colors[frame<45 ? 0:frame<75 ? 1:frame<105 ? 2:3]
            context.setFillColor(CGColor(red:c[0],green:c[1],blue:c[2],alpha:1));context.fill(CGRect(x:0,y:0,width:encoding.width,height:encoding.height))
            CVPixelBufferUnlockBaseAddress(buffer,[])
            XCTAssertTrue(adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30)))
        }
        input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:128,timescale:30))
        await withCheckedContinuation{(continuation:CheckedContinuation<Void,Never>)in writer.finishWriting{continuation.resume()}}
        XCTAssertEqual(writer.status,.completed)
    }

    func testSourceOffsetSpeedCaptionsAndPauseKeepExactCadenceAcrossIntervalBoundaries()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let encoding=try configuration(revision(workspace))
        let source=root.appendingPathComponent("source.mp4");try await sourceVideo(source,encoding:encoding)
        let bytes=try Data(contentsOf:source)
        let asset=Asset(workspaceID:workspace.id,name:"带绝对源帧的测试视频",hash:Codec.hash(bytes),ext:"mp4",bytes:bytes.count,mediaType:"video/mp4",durationFrames:128)
        let storedSource=repo.assetURL(asset)
        try FileManager.default.createDirectory(at:storedSource.deletingLastPathComponent(),withIntermediateDirectories:true)
        try bytes.write(to:storedSource);try repo.transaction{$0.assets=[asset]}
        let prelude=Scene(title:"另一个原镜头",body:"全局时间轴前移17帧。",durationFrames:17)
        var scene=Scene(kind:.video,title:"原源轴持续",body:"偏移17帧、半速和最后持画。",durationFrames:96)
        scene.assetID=asset.id;scene.sourceStartFrame=17;scene.speed=0.5;scene.pauseFrames=55
        scene.captions=[Caption(text:"边界前",startFrame:0,endFrame:60),Caption(text:"边界后仍连续",startFrame:60,endFrame:96)]
        let r=Revision(contentContext:ContentContext(workspaceID:workspace.id,name:"源轴比较"),aspect:.landscape,scenes:[prelude,scene])
        XCTAssertEqual(scene.timelineFrames,247);XCTAssertEqual(r.frames,264)
        let whole=root.appendingPathComponent("whole-reference.mp4")
        try await VisualClipCache.renderClip(revision:r,index:1,startFrame:17,repository:repo,database:repo.read(),output:whole,modules:nil,encoding:encoding,progress:{_ in})
        let(_,composed)=try await compose(r,repo:repo,encoding:encoding,name:"intervals")
        let reference=try await decode(whole,frames:247),segmented=try await decode(composed,frames:264)
        let selected=[0,55,56,115,116,119,120,121,175,176,191,192,239,240,246]
        for frame in selected {
            for (actual,expected) in zip(segmented[17+frame].points,reference[frame].points) {
                for (a,b) in zip(actual,expected) {XCTAssertLessThanOrEqual(abs(a-b),16,"同一原源帧的语义区域应一致；H.264区间GOP允许小压缩差异")}
            }
            // The center of the actual media viewport is one of the sampled
            // points. Distinct original source colors expose a source reset.
            let rgb=segmented[17+frame].points[4]
            if frame<56 {XCTAssertGreaterThan(rgb[0]-max(rgb[1],rgb[2]),60)}
            else if frame<116 {XCTAssertGreaterThan(rgb[1]-max(rgb[0],rgb[2]),60)}
            else if frame<176 {XCTAssertGreaterThan(rgb[2]-max(rgb[0],rgb[1]),60)}
            else {XCTAssertGreaterThan(min(rgb[0],rgb[1])-rgb[2],60)}
        }
        let(_,last,receipt)=try interval(r,index:1,range:240..<247,repo:repo,encoding:encoding)
        let tail=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt))
        XCTAssertEqual(tail.artifact.frames,7);_=try await decode(last,frames:7)
        // A valid checkpoint never authorizes changed source bytes.
        try Data("changed actual source".utf8).write(to:repo.assetURL(asset),options:.atomic)
        do {_=try await compose(r,repo:repo,encoding:encoding,name:"bad-source");XCTFail("源字节改变后不能复用任何区间")}
        catch let error as VideoError {XCTAssertEqual(error.code,"invalid_input")}
    }
}
