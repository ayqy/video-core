import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import VideoCore

public struct RenderResult: Sendable { public var artifacts: [Artifact]; public var frames: Int; public var seconds: Double; public var warnings: [String] }
public final class MediaRenderer: @unchecked Sendable {
    public let modules:RenderModuleRegistry?
    public init(modules:RenderModuleRegistry?=nil) { self.modules=modules }
    public func render(revision r: Revision, repository: Repository, output: URL, invocation: RenderInvocation? = nil, progress: @escaping @Sendable (Double) throws -> Void = { _ in }) async throws -> RenderResult {
        do {
            try invocation?.verify(revision:r)
            let result = try await renderBody(revision:r,repository:repository,output:output,invocation:invocation,progress:progress)
            try invocation?.check()
            if let invocation { try modules?.close(invocationID:invocation.id) }
            return result
        } catch {
            if let invocation { invocation.cancellation.cancel(); try? modules?.close(invocationID:invocation.id) }
            throw error
        }
    }
    private func renderBody(revision r: Revision, repository: Repository, output: URL, invocation: RenderInvocation?, progress: @escaping @Sendable (Double) throws -> Void) async throws -> RenderResult {
        try r.validateContext()
        guard !r.scenes.isEmpty,r.frames>0,r.frames<=54000 else{throw VideoError.review("工程尚无可制作内容或时长超出范围，请添加真实片段后重试")}
        try ManagedInstallRules.authorizeWrite(repositoryRoot:repository.root)
        let start = Date(); let db = try repository.read()
        // Verify every actual dependency, including layer images, voices, music and rights documents.
        // A valid scene cache does not authorize silently changed source bytes.
        let graph=try DependencyRules.freeze(revision:r,assets:db.assets,evidence:db.evidence)
        for record in graph.records {
            if let asset=record.asset {
                guard asset.hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,asset.ext.range(of:"^[a-z0-9]{1,12}$",options:.regularExpression) != nil else{throw VideoError.review("引用素材路径元数据无效，拒绝读取")}
                let url=repository.assetURL(asset)
                guard url.resolvingSymlinksInPath().path==url.standardizedFileURL.path else{throw VideoError.review("引用素材路径含链接，拒绝读取未核原件")}
                let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,(attributes[.size] as? NSNumber)?.intValue==asset.bytes,asset.bytes>0,asset.bytes<=256*1024*1024,Codec.hash(try Data(contentsOf:url))==asset.hash else{throw VideoError.review("引用的源文件、元素、声音或授权原件摘要不一致，请从原件恢复后重做")}
            }
        }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let raw = output.appendingPathComponent("working.mp4"), final = output.appendingPathComponent("video.mp4")
        for u in [raw,final] { if FileManager.default.fileExists(atPath:u.path) { try FileManager.default.removeItem(at:u) } }
        defer { try? FileManager.default.removeItem(at:raw) }
        let visuals = try await VisualClipCache.compose(revision:r,repository:repository,database:db,output:raw,modules:modules,invocation:invocation,progress:progress)
        do {
            try await mix(video:raw,final:final,revision:r,repository:repository,database:db,progress:progress)
            let inspection=try await MediaInspection.inspect(final)
            guard inspection.width==r.aspect.width,inspection.height==r.aspect.height,inspection.videoCodec=="avc1",inspection.isH2644208Bit,inspection.isBT709,inspection.audioCodec=="aac ",inspection.sampleRate==48000,abs(inspection.duration-Double(r.frames)/Double(r.fps))<0.15,abs(inspection.fps-30)<0.1 else { throw VideoError.review("成片尺寸、H.264 420 8bit/BT709、AAC48kHz、帧率或时长核验失败") }
            try await MediaInspection.verifyCadence(final,frames:r.frames,fps:r.fps,progress:{value in try progress(0.97+value*0.02)})
            let policy=r.audioQuality ?? AudioQualityPolicy()
            let audio=try await AudioInspection.inspect(final,policy:policy)
            guard audio.clippedSamples==0,audio.rmsDBFS <= -10 else { throw VideoError.review("实际混音存在削波或过高平均电平，请降低分轨音量并重做、听审；失败产物未标可交付") }
            let audible=r.scenes.contains { !$0.muted && (($0.voice != nil && $0.voiceGain>0) || ($0.kind == .video && $0.sourceGain>0) || ($0.classicArtwork?.audioCues.contains(where:{$0.gain>0}) == true)) } || (r.musicAssetID != nil && r.scenes.contains{$0.musicGain>0})
            if audible && audio.peakDBFS < -50 { throw VideoError.review("工程含声音但实际混音接近静音，请核对分轨与源音轨后重做") }
            guard let loudness=audio.loudness else{throw VideoError.review("实际混音尚无响度与真峰值检测，未标可交付")}
            if audible,let peak=loudness.truePeakDBTP,peak>=0 {throw VideoError.review(String(format:"实际混音的4倍过采样真峰值估计 %.2f dBTP 达到满幅过载，请降低分轨音量并重新制作、听审",peak))}
            let violations=loudness.violations(policy:policy,audible:audible)
            guard violations.isEmpty else{throw VideoError.review(violations.joined(separator:"；"))}

            // The cover is the first decoded frame of this verified final video.
            // Re-submitting frame zero to a long-lived plugin scope would replay an
            // evicted execution receipt, and could differ from the actual encode.
            try invocation?.check(); try Task.checkCancellation()
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:final))
            generator.appliesPreferredTrackTransform=true;generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            let cover=output.appendingPathComponent("cover.png")
            try ScenePainter.png(generator.copyCGImage(at:.zero,actualTime:nil)).write(to:cover,options:.atomic)
            let subtitles=output.appendingPathComponent("captions.srt"); try Self.subtitles(r).write(to:subtitles,atomically:true,encoding:.utf8)
            let text=output.appendingPathComponent("publication.txt");let note=try Self.publicationNotes(r,audio:audio);try note.write(to:text,atomically:true,encoding:.utf8)
            let refs=try [final,cover,subtitles,text].map { u -> Artifact in let data=try Data(contentsOf:u); let mime:[String:String]=["mp4":"video/mp4","png":"image/png","srt":"application/x-subrip","txt":"text/plain"]; return Artifact(path:u.path,mime:mime[u.pathExtension]!,bytes:data.count,sha256:Codec.hash(data),revision:r.id) }
            try progress(1); return RenderResult(artifacts:refs,frames:r.frames,seconds:Date().timeIntervalSince(start),warnings:(r.scenes.allSatisfy({$0.voice == nil && $0.sourceGain==0 && ($0.classicArtwork?.audioCues.allSatisfy{$0.gain==0} ?? true)}) ? ["此版本无旁白，AAC音轨为明确的静音底轨"] : []) + ["画面缓存复用 \(visuals)/\(r.scenes.count) 镜头；声音与整片时间轴重新合成"])
        } catch { try? FileManager.default.removeItem(at:final); throw error }
    }
    private func mix(video:URL,final:URL,revision r:Revision,repository:Repository,database:Database,progress: @escaping @Sendable (Double) throws -> Void) async throws {
        let composition=AVMutableComposition(); let source=AVURLAsset(url:video); let tracks=try await source.loadTracks(withMediaType:.video); guard let sourceTrack=tracks.first,let dest=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw VideoError.unavailable("视频轨道缺失") }
        let total=CMTime(value:Int64(r.frames),timescale:Int32(r.fps)); try dest.insertTimeRange(CMTimeRange(start:.zero,duration:total),of:sourceTrack,at:.zero)
        var parameters:[AVAudioMixInputParameters]=[]; var cursor=0
        for s in r.scenes {
            let at=CMTime(value:Int64(cursor),timescale:Int32(r.fps)); let span=CMTime(value:Int64(s.timelineFrames-s.pauseFrames),timescale:Int32(r.fps))
            if !s.muted {
                for cue in s.classicArtwork?.audioCues ?? [] where cue.gain>0 {
                    guard let asset=database.assets.first(where:{$0.id==cue.assetID && $0.workspaceID==r.workspaceID}) else{throw VideoError.notFound("场景游戏录音已缺失")}
                    let offset=try Self.sceneAudioTime(frames:cue.startFrame,fps:r.fps,speed:s.speed)
                    let length=try Self.sceneAudioTime(frames:cue.durationFrames,fps:r.fps,speed:s.speed)
                    let parameter=try await addAudio(repository.assetURL(asset),to:composition,at:CMTimeAdd(at,offset),sourceStart:.zero,sourceFrames:cue.durationFrames,targetDuration:length,fps:r.fps,gain:Float(cue.gain),preservePitch:s.preservePitch)
                    parameters.append(parameter)
                }
                if let take=s.voice,let a=database.assets.first(where:{$0.id==take.assetID}) { let p=try await addAudio(repository.assetURL(a),to:composition,at:at,sourceStart:.zero,sourceFrames:take.durationFrames,targetDuration:try Self.sceneAudioTime(frames:take.durationFrames,fps:r.fps,speed:s.speed),fps:r.fps,gain:Float(s.voiceGain),preservePitch:s.preservePitch); parameters.append(p) }
                if let aid=s.assetID,let a=database.assets.first(where:{$0.id==aid}),s.kind == .video,s.sourceGain>0 { if !(try await AVURLAsset(url:repository.assetURL(a)).loadTracks(withMediaType:.audio)).isEmpty { let p=try await addAudio(repository.assetURL(a),to:composition,at:at,sourceStart:CMTime(value:Int64(s.sourceStartFrame),timescale:Int32(r.fps)),sourceFrames:s.durationFrames,targetDuration:span,fps:r.fps,gain:Float(s.sourceGain),preservePitch:s.preservePitch); parameters.append(p) } }
            }; cursor += s.timelineFrames
        }
        if let aid=r.musicAssetID,let a=database.assets.first(where:{$0.id==aid}),let track=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) { let music=AVURLAsset(url:repository.assetURL(a)); guard let src=try await music.loadTracks(withMediaType:.audio).first else { throw VideoError.invalid("配乐没有音轨") }; let duration=try await music.load(.duration); guard duration.seconds>0 else { throw VideoError.invalid("配乐时长无效") }; var t=CMTime.zero; while t<total { let length=CMTimeMinimum(duration,CMTimeSubtract(total,t)); try track.insertTimeRange(CMTimeRange(start:.zero,duration:length),of:src,at:t); t=CMTimeAdd(t,length) }; let p=AVMutableAudioMixInputParameters(track:track)
            for segment in try AudioMixRules.musicEnvelope(scenes:r.scenes,fps:r.fps) {
                let start=CMTime(seconds:segment.startSeconds,preferredTimescale:60000)
                let end=CMTime(seconds:segment.endSeconds,preferredTimescale:60000)
                // Constant intervals must be explicit too: isolated setVolume points can
                // interpolate toward a later mute and lower earlier, still-audible music.
                p.setVolumeRamp(fromStartVolume:Float(segment.startGain),toEndVolume:Float(segment.endGain),timeRange:CMTimeRange(start:start,end:end))
            }
            parameters.append(p) }
        // An explicit silent AAC floor ensures a standard audio stream even for a user-authored silent lesson.
        let silence=repository.root.appendingPathComponent("cache/silence.caf"); try FileManager.default.createDirectory(at:silence.deletingLastPathComponent(),withIntermediateDirectories:true); try Self.silence(to:silence,seconds:Double(r.frames)/Double(r.fps)); defer { try? FileManager.default.removeItem(at:silence) }
        parameters.append(try await addAudio(silence,to:composition,at:.zero,sourceStart:.zero,sourceFrames:r.frames,targetDuration:total,fps:r.fps,gain:0,preservePitch:true))
        let mix=AVMutableAudioMix(); mix.inputParameters=parameters
        // Explicit AAC48kHz output; preset exports may silently choose 44.1kHz or change portrait dimensions.
        let reader=try AVAssetReader(asset:composition);reader.timeRange=CMTimeRange(start:.zero,duration:total)
        let videoOutput=AVAssetReaderTrackOutput(track:dest,outputSettings:nil);videoOutput.alwaysCopiesSampleData=false
        let audioOutput=AVAssetReaderAudioMixOutput(audioTracks:composition.tracks(withMediaType:.audio),audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false]);audioOutput.audioMix=mix;audioOutput.alwaysCopiesSampleData=false
        guard reader.canAdd(videoOutput),reader.canAdd(audioOutput)else{throw VideoError.unavailable("混音读取器不可用")};reader.add(videoOutput);reader.add(audioOutput)
        let writer=try AVAssetWriter(outputURL:final,fileType:.mp4)
        let descriptions=try await sourceTrack.load(.formatDescriptions)
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:nil,sourceFormatHint:descriptions.first);videoInput.mediaTimeScale=Int32(r.fps*1000)
        let audioInput=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128000])
        guard writer.canAdd(videoInput),writer.canAdd(audioInput)else{throw VideoError.unavailable("AAC48kHz编码器不可用")};writer.add(videoInput);writer.add(audioInput)
        guard writer.startWriting(),reader.startReading()else{throw VideoError.unavailable("混音无法启动")};writer.startSession(atSourceTime:.zero)
        var videoDone=false,audioDone=false;var copiedFrames=0
        do {
            while !videoDone || !audioDone {
                try Task.checkCancellation();var advanced=false
                if !videoDone && videoInput.isReadyForMoreMediaData {if let sample=videoOutput.copyNextSampleBuffer(){if CMSampleBufferGetNumSamples(sample)>0{guard videoInput.append(sample)else{throw VideoError.unavailable("合成视频写入失败")};copiedFrames+=1;if copiedFrames%60==0{try progress(0.8+Double(copiedFrames)/Double(r.frames)*0.16)}}}else{videoInput.markAsFinished();videoDone=true};advanced=true}
                if !audioDone && audioInput.isReadyForMoreMediaData {if let sample=audioOutput.copyNextSampleBuffer(){if CMSampleBufferGetNumSamples(sample)>0{guard audioInput.append(sample)else{throw VideoError.unavailable("混音写入失败")}}}else{audioInput.markAsFinished();audioDone=true};advanced=true}
                guard reader.status != .failed,writer.status != .failed else{throw VideoError.unavailable("音画合成失败")}
                if !advanced{try await Task.sleep(nanoseconds:2_000_000)}
            }
            writer.endSession(atSourceTime:total)
            await withCheckedContinuation{(c:CheckedContinuation<Void,Never>)in writer.finishWriting{c.resume()}}
            guard writer.status == .completed else{throw VideoError.unavailable("混音未完成")}
        }catch{reader.cancelReading();writer.cancelWriting();throw error}
    }
    static func sceneAudioTime(frames:Int,fps:Int,speed:Double)throws->CMTime {
        guard frames>=0,(1...120).contains(fps),speed.isFinite,(0.25...4).contains(speed) else{throw VideoError.invalid("场景声音时间或速度无效")}
        // Audio is not quantized to video frames: even a one-frame effect at 4x retains its positive duration.
        return CMTime(seconds:Double(frames)/Double(fps)/speed,preferredTimescale:60_000)
    }
    private func addAudio(_ url:URL,to composition:AVMutableComposition,at:CMTime,sourceStart:CMTime,sourceFrames:Int,targetDuration:CMTime,fps:Int,gain:Float,preservePitch:Bool) async throws -> AVMutableAudioMixInputParameters {
        let asset=AVURLAsset(url:url); guard let src=try await asset.loadTracks(withMediaType:.audio).first,let track=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw VideoError.invalid("声音素材没有可用音轨") }
        let available=try await asset.load(.duration); let desired=CMTime(value:Int64(sourceFrames),timescale:Int32(fps)); let duration=CMTimeMinimum(desired,CMTimeSubtract(available,sourceStart)); guard duration.seconds>0 else { throw VideoError.invalid("音轨裁切超出范围") }
        try track.insertTimeRange(CMTimeRange(start:sourceStart,duration:duration),of:src,at:at); track.scaleTimeRange(CMTimeRange(start:at,duration:duration),toDuration:targetDuration); let p=AVMutableAudioMixInputParameters(track:track); p.audioTimePitchAlgorithm=preservePitch ? .spectral : .varispeed; p.setVolume(gain,at:at); return p
    }
    private static func silence(to url:URL,seconds:Double) throws { let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!; let file=try AVAudioFile(forWriting:url,settings:format.settings); let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!; buffer.frameLength=48000; memset(buffer.floatChannelData![0],0,48000*MemoryLayout<Float>.size); var remaining=Int(ceil(seconds*48000)); while remaining>0 { buffer.frameLength=AVAudioFrameCount(min(remaining,48000)); try file.write(from:buffer); remaining -= Int(buffer.frameLength) } }
    public static func publicationNotes(_ r:Revision,audio:AudioDiagnostics) throws -> String {
        var lines=[r.contentName,r.cta,"","用途："+r.purpose.rawValue,"AI辅助制作；请按实际用途核对AI/商业标识、版权和文字。通用文件导出不要求运营账号或平台挂载资格。","版本："+r.id,"IR/schema：\(r.schemaVersion)；工具链：\(r.toolchain)","摘要："+(try r.contentDigest()),"混音实测：峰值 \(audio.peakDBFS) dBFS；未加权RMS \(audio.rmsDBFS) dBFS（不是LUFS）","当前文件为待看听预览；人工审核与真实发布状态在工程中另记。","此包未自动发布。"]
        if let brief=r.productionBrief {
            lines += ["制作目标："+brief.objective,"约定用途："+brief.intendedUse,"修改要求："+brief.modifications,"AI标识声明："+brief.aiDisclosure,"商业标识声明："+brief.commercialDisclosure,"使用限制："+brief.restrictions,"用途截止："+(brief.permittedUntil.map(BeijingTime.string) ?? "未另设；不扩张原授权"),"Brief证据："+brief.evidenceIDs.joined(separator:",")]
        }
        if let product=r.product {lines += ["SKU："+product.sku,"已有承接页："+product.checkout,"受众："+product.audience,"学习任务："+product.task,"内容范围："+product.scope]}
        if let loudness=audio.loudness {
            lines.append("响度算法："+loudness.method)
            lines.append("真峰值为标准四倍FIR估计，骤起/骤停等边界可能与其他重采样器存在差异；检测不替代人工完整听审。")
            lines.append("综合响度："+(loudness.integratedLUFS.map{String(format:"%.2f LUFS",$0)} ?? ("不可测："+(loudness.unavailableReason ?? "无有效测量块"))))
            lines.append("真峰值："+(loudness.truePeakDBTP.map{String(format:"%.2f dBTP",$0)} ?? "全静音，无有限峰值"))
            if let target=audio.loudness?.analysisPolicy.targetLUFS {lines.append(String(format:"自定综合响度目标：%.2f±%.2f LUFS",target,loudness.analysisPolicy.toleranceLU))}
            if let ceiling=loudness.analysisPolicy.maximumTruePeakDBTP {lines.append(String(format:"自定真峰值上限：%.2f dBTP",ceiling))}
            for interval in loudness.silenceRanges {lines.append(String(format:"待看听静音区间：%.3f—%.3f秒",interval.startSeconds,interval.endSeconds))}
        }
        if let snapshot=r.dependencies { lines.append("素材与证据冻结于 "+BeijingTime.string(snapshot.capturedAt));for record in snapshot.records {if let a=record.asset {lines.append("素材：\(a.name)；SHA256 \(a.hash)；所用页：\(record.pageNumbers?.map(String.init).joined(separator:",") ?? "不适用")")};if let e=record.evidence {lines.append("证据：\(e.title)；来源 \(e.source)；权利人 \(e.owner)；授权截止 \(e.expiresAt.map(BeijingTime.string) ?? "未设置（不等于永久许可）")；商用 \(e.commercialAllowed ? "已声明允许，发布前再核":"未确认")")}} } else {lines.append("旧版本未冻结完整依赖，须回工程重建并审核。")}
        return lines.joined(separator:"\n")+"\n"
    }
    public static func subtitles(_ r:Revision) -> String { var cursor=0,index=0; var result=""; func stamp(_ f:Int)->String { let ms=f*1000/r.fps; return String(format:"%02d:%02d:%02d,%03d",ms/3600000,(ms/60000)%60,(ms/1000)%60,ms%1000) }; for s in r.scenes { for c in s.captions { index += 1; result += "\(index)\n\(stamp(cursor+Int(Double(c.startFrame)/s.speed))) --> \(stamp(cursor+Int(Double(c.endFrame)/s.speed)))\n\(c.text)\n\n" }; cursor += s.timelineFrames }; return result }
}

public struct MediaInspection:Codable,Sendable {
    public var width:Int;public var height:Int;public var duration:Double;public var fps:Double;public var videoCodec:String;public var audioCodec:String;public var sampleRate:Double
    public var h264ProfileIDC:Int? = nil;public var h264ChromaFormatIDC:Int? = nil;public var h264BitDepthLuma:Int? = nil;public var h264BitDepthChroma:Int? = nil
    public var colorPrimaries:String? = nil;public var transferFunction:String? = nil;public var ycbcrMatrix:String? = nil
    public var allVideoFormats4208Bit:Bool? = nil;public var allVideoFormatsBT709:Bool? = nil
    public var isH2644208Bit:Bool {videoCodec=="avc1" && allVideoFormats4208Bit==true}
    public var isBT709:Bool {allVideoFormatsBT709==true}
    public static func inspect(_ url:URL)async throws->MediaInspection{
        let a=AVURLAsset(url:url);let duration=try await a.load(.duration);guard let v=try await a.loadTracks(withMediaType:.video).first,let audio=try await a.loadTracks(withMediaType:.audio).first else{throw VideoError.review("导出缺少视频或音频轨")}
        let size=try await v.load(.naturalSize),fps=try await v.load(.nominalFrameRate),vs=try await v.load(.formatDescriptions),ads=try await audio.load(.formatDescriptions)
        guard let vd=vs.first,let ad=ads.first,let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(ad)else{throw VideoError.review("媒体编码信息不可读")}
        func fourCC(_ n:FourCharCode)->String{String(bytes:[UInt8((n>>24)&255),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)],encoding:.ascii) ?? "未知"}
        var result=MediaInspection(width:Int(size.width),height:Int(size.height),duration:duration.seconds,fps:Double(fps),videoCodec:fourCC(CMFormatDescriptionGetMediaSubType(vd)),audioCodec:fourCC(CMFormatDescriptionGetMediaSubType(ad)),sampleRate:asbd.pointee.mSampleRate)
        func color(_ description:CMFormatDescription,_ key:CFString)->String? {CMFormatDescriptionGetExtension(description,extensionKey:key) as? String}
        result.colorPrimaries=color(vd,kCMFormatDescriptionExtension_ColorPrimaries)
        result.transferFunction=color(vd,kCMFormatDescriptionExtension_TransferFunction)
        result.ycbcrMatrix=color(vd,kCMFormatDescriptionExtension_YCbCrMatrix)
        result.allVideoFormatsBT709=vs.allSatisfy { description in
            color(description,kCMFormatDescriptionExtension_ColorPrimaries)==(kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) && color(description,kCMFormatDescriptionExtension_TransferFunction)==(kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String) && color(description,kCMFormatDescriptionExtension_YCbCrMatrix)==(kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        }
        var layouts:[H264SPSLayout]=[];var all420=true
        for description in vs {
            guard CMFormatDescriptionGetMediaSubType(description)==kCMVideoCodecType_H264 else{all420=false;continue}
            let actual=try h264Layouts(description)
            layouts += actual;all420 = all420 && actual.allSatisfy(\.is4208Bit)
        }
        result.h264ProfileIDC=layouts.first?.profileIDC;result.h264ChromaFormatIDC=layouts.first?.chromaFormatIDC;result.h264BitDepthLuma=layouts.first?.bitDepthLuma;result.h264BitDepthChroma=layouts.first?.bitDepthChroma
        result.allVideoFormats4208Bit=all420 && !layouts.isEmpty
        return result
    }
    private static func h264Layouts(_ description:CMFormatDescription)throws->[H264SPSLayout]{
        var count=0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,parameterSetIndex:0,parameterSetPointerOut:nil,parameterSetSizeOut:nil,parameterSetCountOut:&count,nalUnitHeaderLengthOut:nil)==noErr,(1...64).contains(count)else{throw VideoError.review("实际H.264配置缺少可核验参数集")}
        var layouts:[H264SPSLayout]=[]
        for index in 0..<count {
            var pointer:UnsafePointer<UInt8>?;var size=0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,parameterSetIndex:index,parameterSetPointerOut:&pointer,parameterSetSizeOut:&size,parameterSetCountOut:nil,nalUnitHeaderLengthOut:nil)==noErr,let pointer,(1...65536).contains(size)else{throw VideoError.review("实际H.264参数集读取失败或超出检查上限")}
            if pointer.pointee & 0x1f == 7 {layouts.append(try H264Rules.parseSPS(Data(bytes:pointer,count:size)))}
        }
        guard !layouts.isEmpty else{throw VideoError.review("实际H.264配置没有SPS，未推断色度与位深")};return layouts
    }
    public static func verifyCadence(_ url:URL,frames:Int,fps:Int,progress:(Double)throws->Void = {_ in})async throws{
        let asset=AVURLAsset(url:url);guard let track=try await asset.loadTracks(withMediaType:.video).first else{throw VideoError.review("成片无视频轨")};let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]);output.alwaysCopiesSampleData=false;guard reader.canAdd(output)else{throw VideoError.review("无法核对视频时间戳")};reader.add(output);guard reader.startReading()else{throw VideoError.review("无法读取视频帧")}
        var times:[Double]=[]
        do {
            while let sample=output.copyNextSampleBuffer(){
                try Task.checkCancellation()
                if let image=CMSampleBufferGetImageBuffer(sample){
                    let time=CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    try verifyVisibleFrame(image,frame:times.count)
                    times.append(time)
                    guard times.count<=frames else{throw VideoError.review("成片视频帧超过冻结版本，未标交付")}
                    if times.count%300==0{try progress(Double(times.count)/Double(frames))}
                }
            }
            guard reader.status == .completed,times.count==frames else{throw VideoError.review("视频帧核验失败：预期\(frames)帧，实际\(times.count)帧，读取状态\(reader.status.rawValue)")};times.sort()
            for (i,t) in times.enumerated(){guard t.isFinite,abs(t-Double(i)/Double(fps))<1.0/48000 else{throw VideoError.review("视频时间戳不是连续30fps；导出未标成功")}}
        } catch {reader.cancelReading();throw error}
    }
    /// Inspect every decoded frame. A near-uniform video-range black image is a failure,
    /// not a complete semantic check of deliberately dark footage or covered source regions.
    static func verifyVisibleFrame(_ image:CVPixelBuffer,frame:Int)throws {
        guard CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,CVPixelBufferGetPlaneCount(image)==2 else{throw VideoError.review("画面检查需要实际解码的420视频范围亮度平面")}
        guard CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else{throw VideoError.review("无法读取实际画面亮度平面")}
        defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
        let width=CVPixelBufferGetWidthOfPlane(image,0),height=CVPixelBufferGetHeightOfPlane(image,0),stride=CVPixelBufferGetBytesPerRowOfPlane(image,0)
        guard width>0,height>0,width<=8192,height<=8192,stride>=width,let base=CVPixelBufferGetBaseAddressOfPlane(image,0)?.assumingMemoryBound(to:UInt8.self) else{throw VideoError.review("解码画面亮度平面尺寸异常")}
        let brightLimit=max(1,width*height/1000);var bright=0
        for y in 0..<height {
            let row=base.advanced(by:y*stride)
            for x in 0..<width where row[x]>24 {bright+=1;if bright>brightLimit{return}}
        }
        throw VideoError.review("第\(frame+1)帧接近整帧黑场，请核对源片、裁切和渲染后重做；失败产物未标可交付")
    }
}
