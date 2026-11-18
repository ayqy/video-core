import XCTest
import AVFoundation
import VideoCore
@testable import VideoMedia

final class LoudnessMediaTests:XCTestCase {
    private func pcmBuffer(start:CMTime,frames:Int,sampleRate:Double=48000,sampleDuration:CMTime?=nil)throws->CMSampleBuffer {
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:1))
        var block:CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,
            blockLength:frames*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,
            offsetToData:0,dataLength:frames*4,flags:0,blockBufferOut:&block),kCMBlockBufferNoErr)
        let storage=try XCTUnwrap(block)
        var values=[Float](repeating:0.1,count:frames)
        if frames>0 {values[frames-1]=1} // An out-of-range tail must not inflate measured levels.
        XCTAssertEqual(values.withUnsafeBytes {CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:storage,
            offsetIntoDestination:0,dataLength:frames*4)},kCMBlockBufferNoErr)
        var timing=CMSampleTimingInfo(duration:sampleDuration ?? CMTime(value:1,timescale:CMTimeScale(sampleRate)),
            presentationTimeStamp:start,decodeTimeStamp:.invalid)
        var result:CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:storage,
            formatDescription:format.formatDescription,sampleCount:frames,sampleTimingEntryCount:1,
            sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&result),noErr)
        return try XCTUnwrap(result)
    }

    private func selection(_ buffer:CMSampleBuffer,range:CMTimeRange)throws->Range<Int> {
        try AudioInspection.presentedFrameRange(buffer:buffer,sampleRate:48000,playbackRange:range)
    }

    private func attachTrim(_ time:CMTime,to buffer:CMSampleBuffer,key:CFString)throws {
        let value=try XCTUnwrap(CMTimeCopyAsDictionary(time,allocator:kCFAllocatorDefault))
        CMSetAttachment(buffer,key:key,value:value,attachmentMode:kCMAttachmentMode_ShouldPropagate)
    }

    func testCoreMediaTrimAttachmentsChangePlaybackClockWithoutMovingRawPCM()throws {
        let rawStart=CMTime(value:-3,timescale:48000)
        let buffer=try pcmBuffer(start:rawStart,frames:8)
        let block=try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
        func contents()throws->Data {
            var bytes=Data(count:CMBlockBufferGetDataLength(block))
            let result=bytes.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(block,atOffset:0,
                dataLength:$0.count,destination:$0.baseAddress!)}
            XCTAssertEqual(result,kCMBlockBufferNoErr)
            return bytes
        }
        let original=try contents()
        let trimStart=try XCTUnwrap(CMTimeCopyAsDictionary(CMTime(value:3,timescale:48000),allocator:kCFAllocatorDefault))
        let trimEnd=try XCTUnwrap(CMTimeCopyAsDictionary(CMTime(value:1,timescale:48000),allocator:kCFAllocatorDefault))
        CMSetAttachment(buffer,key:kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value:trimStart,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        CMSetAttachment(buffer,key:kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
            value:trimEnd,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(buffer),rawStart),0)
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetDuration(buffer),CMTime(value:8,timescale:48000)),0)
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetOutputPresentationTimeStamp(buffer),.zero),0)
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetOutputDuration(buffer),CMTime(value:4,timescale:48000)),0)
        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer),8)
        XCTAssertEqual(CMBlockBufferGetDataLength(block),8*MemoryLayout<Float>.size)
        XCTAssertEqual(try contents(),original,"trim附件描述解码后的播放范围，没有移动原PCM样本索引")
    }

    func testTrimmedPlaybackUsesRawPCMIndexAndIntersectsBothPlaybackWindows()throws {
        let buffer=try pcmBuffer(start:CMTime(value:-3,timescale:48000),frames:8)
        try attachTrim(CMTime(value:3,timescale:48000),to:buffer,key:kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        try attachTrim(CMTime(value:1,timescale:48000),to:buffer,key:kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        let complete=CMTimeRange(start:CMTime(value:-10,timescale:48000),duration:CMTime(value:20,timescale:48000))
        XCTAssertEqual(try selection(buffer,range:complete),3..<7,"宽源区间也不能把trim前后的原样本送入计量")
        let inside=CMTimeRange(start:CMTime(value:1,timescale:48000),duration:CMTime(value:2,timescale:48000))
        XCTAssertEqual(try selection(buffer,range:inside),4..<6,"源播放范围与缓冲output范围共同限制真实样本")
        let after=CMTimeRange(start:CMTime(value:4,timescale:48000),duration:CMTime(value:4,timescale:48000))
        XCTAssertEqual(try selection(buffer,range:after),7..<7,"零交集不得保留恰好end的样本")
    }

    func testEntirePrimingOrDrainBufferHasNoPresentedSamples()throws {
        let range=CMTimeRange(start:.zero,duration:CMTime(value:16,timescale:48000))
        let priming=try pcmBuffer(start:.zero,frames:8)
        try attachTrim(CMTime(value:8,timescale:48000),to:priming,key:kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        XCTAssertEqual(try selection(priming,range:range),8..<8)
        let drain=try pcmBuffer(start:.zero,frames:8)
        try attachTrim(CMTime(value:8,timescale:48000),to:drain,key:kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        XCTAssertEqual(try selection(drain,range:range),0..<0)
        XCTAssertEqual(CMSampleBufferGetNumSamples(priming),8)
        XCTAssertEqual(CMSampleBufferGetNumSamples(drain),8,"空播放区间保留完整原始解码计数，不补零")
    }

    func testUnsupportedPCMClockTransformsAreRejectedInsteadOfGuessingSamplePositions()throws {
        let range=CMTimeRange(start:.zero,duration:CMTime(value:8,timescale:48000))
        let speed=try pcmBuffer(start:.zero,frames:8)
        CMSetAttachment(speed,key:kCMSampleBufferAttachmentKey_SpeedMultiplier,
            value:NSNumber(value:2),attachmentMode:kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try selection(speed,range:range))
        let reverse=try pcmBuffer(start:.zero,frames:8)
        CMSetAttachment(reverse,key:kCMSampleBufferAttachmentKey_Reverse,
            value:kCFBooleanTrue,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try selection(reverse,range:range))
        let shifted=try pcmBuffer(start:.zero,frames:8)
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(shifted,newValue:CMTime(value:1,timescale:48000)),noErr)
        XCTAssertThrowsError(try selection(shifted,range:range))
        let unmodified=try pcmBuffer(start:.zero,frames:8)
        CMSetAttachment(unmodified,key:kCMSampleBufferAttachmentKey_SpeedMultiplier,
            value:NSNumber(value:1),attachmentMode:kCMAttachmentMode_ShouldPropagate)
        CMSetAttachment(unmodified,key:kCMSampleBufferAttachmentKey_Reverse,
            value:kCFBooleanFalse,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        XCTAssertEqual(try selection(unmodified,range:range),0..<8)
    }

    func testInvalidPCMTrimAndClockMetadataAreRejected()throws {
        let range=CMTimeRange(start:.zero,duration:CMTime(value:8,timescale:48000))
        for trim in [CMTime(value:-1,timescale:48000),CMTime(value:9,timescale:48000),CMTime.invalid] {
            let buffer=try pcmBuffer(start:.zero,frames:8)
            try attachTrim(trim,to:buffer,key:kCMSampleBufferAttachmentKey_TrimDurationAtStart)
            XCTAssertThrowsError(try selection(buffer,range:range))
        }
        let malformed=try pcmBuffer(start:.zero,frames:8)
        CMSetAttachment(malformed,key:kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value:"not a time" as CFString,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try selection(malformed,range:range))
        let wrongClock=try pcmBuffer(start:.zero,frames:8,sampleDuration:CMTime(value:2,timescale:48000))
        XCTAssertThrowsError(try selection(wrongClock,range:range))
        XCTAssertThrowsError(try AudioInspection.presentedFrameRange(bufferStart:.invalid,frameCount:8,
            sampleRate:48000,playbackRange:range))
        XCTAssertThrowsError(try AudioInspection.presentedFrameRange(bufferStart:.zero,frameCount:8,
            sampleRate:48000,playbackRange:CMTimeRange(start:.zero,duration:.indefinite)))
    }

    func testPCMBufferPresentationRangeUsesExactHalfOpenSampleBoundaries()throws {
        let crossing=try pcmBuffer(start:CMTime(value:-3,timescale:48000),frames:8)
        let range=CMTimeRange(start:.zero,duration:CMTime(value:4,timescale:48000))
        XCTAssertEqual(try selection(crossing,range:range),3..<7,
            "只选0、1、2、3号源采样；负PTS与恰好end的样本都在原播放区间外")
        let fractional=CMTimeRange(start:CMTime(value:1,timescale:96000),
            duration:CMTime(value:12,timescale:96000))
        let start=try pcmBuffer(start:.zero,frames:8)
        XCTAssertEqual(try selection(start,range:fractional),1..<7,
            "半采样边界必须精确ceil，不把源最后一个合法样本四舍五入丢掉")
        XCTAssertEqual(try selection(start,range:range),0..<4)
        XCTAssertEqual(try selection(try pcmBuffer(start:CMTime(value:4,timescale:48000),frames:8),range:range),0..<0)
        XCTAssertEqual(try selection(try pcmBuffer(start:CMTime(value:-8,timescale:48000),frames:8),range:range),8..<8)
    }

    func testDecoderTailOutsideActualPlaybackDoesNotBecomeSourceOrLoudnessSamples()throws {
        // Synthetic PCM packet reproduces the measured clocks, not product audio.
        let packet=try pcmBuffer(start:CMTime(value:974848,timescale:48000),frames:7684)
        let source=CMTimeRange(start:.zero,duration:CMTime(value:490752,timescale:24000))
        let selected=try selection(packet,range:source)
        XCTAssertEqual(selected,0..<6656)
        XCTAssertEqual(CMSampleBufferGetNumSamples(packet)-selected.count,1028)
        let storage=try XCTUnwrap(CMSampleBufferGetDataBuffer(packet))
        var values=[Float](repeating:0,count:7684)
        XCTAssertEqual(values.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(storage,atOffset:0,
            dataLength:7684*4,destination:$0.baseAddress!)},kCMBlockBufferNoErr)
        var meter=try AudioMeter(sampleRate:48000,channels:1)
        var loudness=try LoudnessMeter(channels:1)
        let presented=Array(values[selected])
        try meter.append(presented);try loudness.append(presented)
        let measured=try meter.finish(),levels=try loudness.finish()
        XCTAssertEqual(measured.duration,6656.0/48000,accuracy:1.0/48000)
        XCTAssertEqual(measured.clippedSamples,0)
        XCTAssertEqual(measured.peakDBFS,-20,accuracy:0.001)
        XCTAssertEqual(levels.totalBlocks,0,"区间外drain不能凑成额外的400ms测量块")
    }

    func testActualWAVRetainsEveryPresentedSampleAndDecodeAccounting()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("presented-wav-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("authored.wav")
        try file(url,seconds:1.125)
        let before=try Data(contentsOf:url)
        let measured=try await AudioInspection.inspect(url)
        XCTAssertEqual(try Data(contentsOf:url),before)
        XCTAssertEqual(measured.readerCompleted,true)
        XCTAssertEqual(measured.presentedPCMFrames,54000)
        XCTAssertEqual(measured.rawDecodedPCMFrames,54000)
        XCTAssertEqual(measured.outsidePlaybackStartPCMFrames,0)
        XCTAssertEqual(measured.outsidePlaybackEndPCMFrames,0)
        XCTAssertEqual(measured.duration,1.125,accuracy:1.0/48000)
        XCTAssertEqual(try XCTUnwrap(measured.rawDecodedDuration),1.125,accuracy:1.0/48000)
    }

    func testHistoricalDiagnosticsDecodeWithoutNewOptionalAccountingFields()throws {
        var meter=try AudioMeter(sampleRate:48000,channels:1)
        try meter.append([Float](repeating:0.1,count:480))
        let original=try meter.finish()
        let legacy=try Codec.data(original)
        let decoded=try Codec.decoder().decode(AudioDiagnostics.self,from:legacy)
        XCTAssertEqual(decoded,original)
        XCTAssertNil(decoded.rawDecodedPCMFrames)
        XCTAssertNil(decoded.readerCompleted)
    }

    private func file(_ url:URL,sampleRate:Double=48000,seconds:Double=2,silence:Bool=false)throws {
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:1))
        let file=try AVAudioFile(forWriting:url,settings:format.settings)
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)),data=try XCTUnwrap(buffer.floatChannelData)
        let total=Int((sampleRate*seconds).rounded())
        // Known signal used only to validate a real CAF/AAC adapter, never product voice material.
        for start in stride(from:0,to:total,by:4096) {
            let count=min(4096,total-start);buffer.frameLength=AVAudioFrameCount(count)
            for index in 0..<count {
                let time=Double(start+index)/sampleRate
                data[0][index]=silence && (0.5..<2.5).contains(time) ? 0:Float(0.1*sin(2 * .pi * 997*time))
            };try file.write(from:buffer)
        }
    }
    func testActual44100FileIsResampledForNormative48kHzMeter()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("loudness-file-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("source.caf");try file(url,sampleRate:44100)
        let result=try await AudioInspection.inspect(url)
        XCTAssertEqual(result.sampleRate,48000);XCTAssertEqual(result.channels,1);XCTAssertEqual(result.duration,2,accuracy:0.01)
        XCTAssertEqual(try XCTUnwrap(result.loudness?.integratedLUFS),-23.01,accuracy:0.05)
        XCTAssertEqual(try XCTUnwrap(result.loudness?.truePeakDBTP),-20,accuracy:0.15)
        XCTAssertNotNil(result.containerDuration)
    }
    func testActualFileLongSilenceAndAACAreMeasuredWithoutAutomaticListening()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("loudness-aac-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        // Keep 50ms beyond the final complete 400ms/100ms block. AppleM4A may use
        // 44.1kHz and a slightly shorter valid duration; 3.000s sat exactly on a
        // block boundary, so a sub-3ms change legitimately removed one loud block.
        // Same-PCM independent comparison is retained in aac-measurement-investigation.md.
        let sourceSeconds=6.25,expectedBlocks=59
        let url=root.appendingPathComponent("source.caf");try file(url,seconds:sourceSeconds,silence:true)
        let policy=AudioQualityPolicy(targetLUFS:-23,toleranceLU:1,maximumTruePeakDBTP:-1,silenceThresholdDBFS:-70,longSilenceSeconds:1)
        let raw=try await AudioInspection.inspect(url,policy:policy),ranges=try XCTUnwrap(raw.loudness?.silenceRanges)
        XCTAssertEqual(ranges.count,1);XCTAssertEqual(ranges[0].startSeconds,0.5,accuracy:0.001);XCTAssertEqual(ranges[0].endSeconds,2.5,accuracy:0.001)
        let target=root.appendingPathComponent("compressed.m4a")
        let session=try XCTUnwrap(AVAssetExportSession(asset:AVURLAsset(url:url),presetName:AVAssetExportPresetAppleM4A));session.outputURL=target;session.outputFileType = .m4a
        await withCheckedContinuation{(continuation:CheckedContinuation<Void,Never>)in session.exportAsynchronously{continuation.resume()}}
        XCTAssertEqual(session.status,.completed)
        let decoded=try await AudioInspection.inspect(target,policy:policy)
        XCTAssertNotNil(decoded.loudness?.integratedLUFS);XCTAssertNotNil(decoded.loudness?.truePeakDBTP)
        let sourceI=try XCTUnwrap(raw.loudness?.integratedLUFS),decodedI=try XCTUnwrap(decoded.loudness?.integratedLUFS)
        if abs(decodedI-sourceI)>0.2 || abs(decoded.duration-sourceSeconds)>0.01 || decoded.loudness?.totalBlocks != expectedBlocks {
            // Retain only a failing, bounded synthetic fixture inside xcresult. These are
            // never product media or mail attachments; the temporary directory still clears.
            for (name,file) in [("loudness-source.caf",url),("loudness-actual-aac.m4a",target)] {let attachment=XCTAttachment(contentsOfFile:file);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)}
            let report="source="+String(describing:raw)+"\ndecoded="+String(describing:decoded)+"\n"
            retainText(report,name:"loudness-measured-diagnostics")
            await retainDecodedEvidence(url,name:"loudness-source",policy:policy)
            await retainDecodedEvidence(target,name:"loudness-aac",policy:policy)
        }
        XCTAssertEqual(raw.duration,sourceSeconds,accuracy:1.0/48000)
        XCTAssertEqual(decoded.duration,sourceSeconds,accuracy:0.01,"核对实际解码时长，不补零或用容器时长冒充PCM长度")
        XCTAssertEqual(try XCTUnwrap(decoded.containerDuration),sourceSeconds,accuracy:0.01)
        XCTAssertEqual(raw.loudness?.totalBlocks,expectedBlocks)
        XCTAssertEqual(decoded.loudness?.totalBlocks,expectedBlocks,"同一完整测量块范围内才检查AAC保真，不能用阈值放宽掩盖时长差异")
        XCTAssertEqual(decodedI,sourceI,accuracy:0.2)
        XCTAssertGreaterThan(decoded.peakDBFS,-50)
    }
    func testActualPCMShortFinalWindowIsNotPaddedToAnIntegerSecond()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("loudness-window-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        for (seconds,blocks) in [(2.999,26),(3.0,27)] {
            let url=root.appendingPathComponent("window-\(seconds).caf");try file(url,seconds:seconds,silence:true)
            let diagnostics=try await AudioInspection.inspect(url)
            XCTAssertEqual(diagnostics.duration,seconds,accuracy:1.0/48000)
            XCTAssertEqual(diagnostics.loudness?.totalBlocks,blocks,"只测实际PCM中的完整400ms窗口，不能补零凑到3秒")
        }
    }
    private func retainText(_ text:String,name:String) {let attachment=XCTAttachment(string:text);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)}
    private func retainDecodedEvidence(_ url:URL,name:String,policy:AudioQualityPolicy) async {
        do {
            let asset=AVURLAsset(url:url),duration=try await asset.load(.duration)
            let tracks=try await asset.loadTracks(withMediaType:.audio),track=try XCTUnwrap(tracks.first),range=try await track.load(.timeRange),segments=try await track.load(.segments)
            func time(_ value:CMTime)->String {"\(value.value)/\(value.timescale)=\(value.seconds);flags=\(value.flags.rawValue)"}
            func attachmentTime(_ buffer:CMSampleBuffer,_ key:CFString)->CMTime {
                guard let value=CMGetAttachment(buffer,key:key,attachmentModeOut:nil),CFGetTypeID(value)==CFDictionaryGetTypeID() else{return .zero}
                return CMTimeMakeFromDictionary(value as! CFDictionary)
            }
            var rows=["assetDuration="+time(duration),"trackStart="+time(range.start),"trackDuration="+time(range.duration)]
            for (i,segment) in segments.enumerated(){rows.append("segment\(i) empty=\(segment.isEmpty) source=\(time(segment.timeMapping.source.start)) + \(time(segment.timeMapping.source.duration)) target=\(time(segment.timeMapping.target.start)) + \(time(segment.timeMapping.target.duration))")}
            let reader=try AVAssetReader(asset:asset)
            let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false]);output.alwaysCopiesSampleData=false;reader.add(output)
            guard reader.startReading() else{throw VideoError.invalid("诊断解码未启动")}
            var bytes=Data(),count=0,frames=0,trimmedValues:[Float]=[],clippedValues:[Float]=[]
            var naive=try LoudnessMeter(channels:1,policy:policy)
            while let buffer=output.copyNextSampleBuffer() {
                let samples=CMSampleBufferGetNumSamples(buffer),pts=CMSampleBufferGetPresentationTimeStamp(buffer),outputPTS=CMSampleBufferGetOutputPresentationTimeStamp(buffer),sampleDuration=CMSampleBufferGetDuration(buffer),outputDuration=CMSampleBufferGetOutputDuration(buffer)
                let start=attachmentTime(buffer,kCMSampleBufferAttachmentKey_TrimDurationAtStart),end=attachmentTime(buffer,kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
                guard start.seconds.isFinite,end.seconds.isFinite,start.seconds>=0,end.seconds>=0,outputPTS.seconds.isFinite else{throw VideoError.invalid("诊断时间戳无效，未猜测裁切位置")}
                if count<512 {rows.append("buffer\(count) samples=\(samples) PTS=\(time(pts)) outputPTS=\(time(outputPTS)) duration=\(time(sampleDuration)) outputDuration=\(time(outputDuration)) trimStart=\(time(start)) trimEnd=\(time(end))")}
                count+=1;guard samples>0,let block=CMSampleBufferGetDataBuffer(buffer) else{continue}
                let length=CMBlockBufferGetDataLength(block);guard length<=1024*1024,length%4==0,bytes.count+length<=2*1024*1024 else{throw VideoError.invalid("有限诊断PCM超出范围")}
                var values=[Float](repeating:0,count:length/4)
                let status=values.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:length,destination:$0.baseAddress!)}
                guard status==kCMBlockBufferNoErr else{throw VideoError.invalid("诊断PCM读取失败")}
                values.withUnsafeBytes{bytes.append(contentsOf:$0)};frames+=values.count;try naive.append(values)
                // Diagnostic hypotheses only. Do not silently install either as production trimming.
                let lower=min(values.count,max(0,Int((start.seconds*48000).rounded()))),upper=max(lower,min(values.count,values.count-max(0,Int((end.seconds*48000).rounded()))))
                trimmedValues.append(contentsOf:values[lower..<upper])
                for index in lower..<upper {let at=outputPTS.seconds+Double(index-lower)/48000;if at>=range.start.seconds && at<min(duration.seconds,range.end.seconds){clippedValues.append(values[index])}}
            }
            guard reader.status == .completed else{throw VideoError.invalid("诊断解码未完成")}
            rows.append("buffers=\(count) decodedFrames=\(frames) decodedSeconds=\(Double(frames)/48000) pcmSHA256=\(Codec.hash(bytes))")
            rows.append("naive="+String(describing:try naive.finish()))
            for (label,values) in [("attachment-trim-hypothesis",trimmedValues),("outputPTS-range-hypothesis",clippedValues)] where !values.isEmpty {var meter=try LoudnessMeter(channels:1,policy:policy);try meter.append(values);rows.append(label+" frames=\(values.count) "+String(describing:try meter.finish()))}
            let pcm=XCTAttachment(data:bytes,uniformTypeIdentifier:"public.data");pcm.name=name+"-48k-mono-f32le";pcm.lifetime = .keepAlways;add(pcm)
            retainText(rows.joined(separator:"\n"),name:name+"-sample-timing")
        } catch {retainText("诊断采集失败："+String(describing:error),name:name+"-diagnostic-error")}
    }
}
