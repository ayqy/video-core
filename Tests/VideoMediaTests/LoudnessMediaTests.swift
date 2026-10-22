import XCTest
import AVFoundation
import VideoCore
import VideoMedia

final class LoudnessMediaTests:XCTestCase {
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
