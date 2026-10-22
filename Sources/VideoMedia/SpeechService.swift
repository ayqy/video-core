import Foundation
import AVFoundation
import VideoCore

public struct SystemSpeechVoice: Identifiable, Equatable, Sendable {
    public var id: String; public var name: String; public var language: String; public var quality: String
    public init(id: String, name: String, language: String, quality: String) { self.id = id; self.name = name; self.language = language; self.quality = quality }
}
public struct SpeechProduction: Sendable {
    public var asset: Asset
    public var evidence: Evidence
    public var diagnostics: AudioDiagnostics
    public var plan: SpeechPlan
    public var captions: [Caption]
    public var take: VoiceTake
}

/// Streams decoded 48kHz mono/stereo through independent raw-sample and BS.1770 meters; never changes the source file.
public enum AudioInspection {
    public static func inspect(_ url: URL,policy:AudioQualityPolicy = .init()) async throws -> AudioDiagnostics {
        try policy.validate()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 3600 else { throw VideoError.invalid("音频实长无效或超过一小时") }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw VideoError.invalid("文件没有真实音轨") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey:48000, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings); output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.unavailable("当前音频格式不能解码检查，请转换为WAV或M4A") }
        reader.add(output); guard reader.startReading() else { throw VideoError.invalid("音频解码未启动") }
        var meter: AudioMeter?;var loudness:LoudnessMeter?; var format: (Double, Int)?
        do {
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
                guard let description = CMSampleBufferGetFormatDescription(buffer), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                      let block = CMSampleBufferGetDataBuffer(buffer) else { throw VideoError.invalid("解码音频格式不符合32位浮点PCM约定") }
                let current = (asbd.mSampleRate, Int(asbd.mChannelsPerFrame))
                if let format { guard format.0 == current.0, format.1 == current.1 else { throw VideoError.invalid("音轨中途变更采样格式，需先转换为一致格式") } }
                else { format = current; meter = try AudioMeter(sampleRate: current.0, channels: current.1);loudness=try LoudnessMeter(sampleRate:current.0,channels:current.1,policy:policy) }
                let length = CMBlockBufferGetDataLength(block)
                guard length <= 32 * 1024 * 1024, length % MemoryLayout<Float>.size == 0 else { throw VideoError.invalid("解码音频缓冲范围异常") }
                var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let status = values.withUnsafeMutableBytes { bytes in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { throw VideoError.invalid("无法读取解码音频采样") }
                try meter?.append(values);try loudness?.append(values)
            }
            guard reader.status == .completed, var meter,var loudness else { throw VideoError.invalid("音频解码中断或没有有效采样") }
            var diagnostics=try meter.finish();diagnostics.loudness=try loudness.finish();diagnostics.containerDuration=duration;return diagnostics
        } catch { reader.cancelReading(); throw error }
    }
}

private final class SpeechFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<Void, Error>?
    private var completed = false
    private var writtenFrames: Int64 = 0
    private let url: URL
    init(url: URL, continuation: CheckedContinuation<Void, Error>) { self.url = url; self.continuation = continuation }
    func accept(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { finishLocked(.failure(VideoError.invalid("系统语音返回非PCM音频"))); return }
        if pcm.frameLength == 0 {
            finishLocked(writtenFrames > 0 ? .success(()) : .failure(VideoError.unavailable("所选系统声音未生成音频；请在系统设置下载该声音后重试，或导入已授权录音")))
            return
        }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
            guard writtenFrames + Int64(pcm.frameLength) <= Int64(pcm.format.sampleRate * 3600) else { throw VideoError.invalid("系统配音超出一小时限制") }
            try file?.write(from: pcm); writtenFrames += Int64(pcm.frameLength)
        } catch { finishLocked(.failure(VideoError.invalid("配音文件写入失败，请检查磁盘空间与可用声音"))) }
    }
    func finish(_ result: Result<Void, Error>) { lock.lock(); defer { lock.unlock() }; finishLocked(result) }
    private func finishLocked(_ result: Result<Void, Error>) {
        guard !completed else { return }; completed = true; file = nil
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume(with: result)
    }
}

/// Foreground, local system synthesis. It does not upload text or automatically buy/download voices.
@MainActor public final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    private var writer: SpeechFileWriter?
    public private(set) var generating = false
    public override init() { super.init() }
    public static func voices(languagePrefix: String? = "zh") -> [SystemSpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            (languagePrefix == nil || voice.language.lowercased().hasPrefix(languagePrefix!.lowercased())) && !voice.voiceTraits.contains(.isPersonalVoice)
        }.map { voice in
            let quality = voice.quality == .premium ? "高品质" : voice.quality == .enhanced ? "增强" : "系统默认"
            return SystemSpeechVoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
        }.sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
    }
    public func cancel() {
        synthesizer?.stopSpeaking(at: .immediate)
        writer?.finish(.failure(CancellationError()))
    }
    public func synthesize(plan: SpeechPlan, scene: Scene, repository: Repository, workspaceID: String) async throws -> SpeechProduction {
        try plan.validate()
        guard !generating else { throw VideoError.conflict("已有配音生成，请等待完成或取消") }
        guard plan.source == scene.narration, plan.confirmed else { throw VideoError.review("请核对并确认当前原文、规范稿与术语读法后生成") }
        guard let identifier = plan.voiceIdentifier,
              Self.voices().contains(where: { $0.id == identifier }),
              let voice = AVSpeechSynthesisVoice(identifier: identifier), voice.identifier == identifier,
              !voice.voiceTraits.contains(.isPersonalVoice) else {
            throw VideoError.unavailable("所选声音不可用；请重新选择本机可用声音，或导入已授权配音。不会用其他语种静默替代。")
        }
        guard voice.language.lowercased().hasPrefix("zh") else { throw VideoError.invalid("中文配音请选择中文系统声音") }
        let cache = repository.root.appendingPathComponent("cache/speech", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let output = cache.appendingPathComponent(Codec.id() + ".caf")
        defer { try? FileManager.default.removeItem(at: output); synthesizer = nil; writer = nil; generating = false }
        generating = true
        let synth = AVSpeechSynthesizer(); synth.delegate = self; synthesizer = synth
        #if os(iOS)
        synth.usesApplicationAudioSession = false
        #endif
        let utterance = AVSpeechUtterance(string: plan.normalized); utterance.voice = voice; utterance.rate = Float(plan.rate)
        utterance.prefersAssistiveTechnologySettings = false
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(900, max(60, Double(plan.normalized.count) * 0.7 + 30))) * 1_000_000_000) }
            catch { return }
            self?.synthesizer?.stopSpeaking(at: .immediate)
            self?.writer?.finish(.failure(VideoError.unavailable("系统声音生成超时；原稿保留，请下载声音或导入已授权录音")))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let writer = SpeechFileWriter(url: output, continuation: continuation); self.writer = writer
                synth.write(utterance) { buffer in writer.accept(buffer) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
        try Task.checkCancellation()
        let diagnostics = try await AudioInspection.inspect(output)
        guard diagnostics.peakDBFS > -70 else { throw VideoError.unavailable("系统生成结果接近静音，请选择其他本机中文声音或导入录音") }
        var asset = try repository.ingest(Data(contentsOf: output), name: "配音-\(scene.title.prefix(24)).caf", workspaceID: workspaceID, mediaType: "audio", durationFrames: Int(ceil(diagnostics.duration * 30)))
        asset.warnings = diagnostics.warnings + ["本机系统合成，不含可核验的字级时间戳；字幕句段须人工校正。", "系统声音使用权与商用范围需按适用条款人工核对；生成成功不等于商用授权。"]
        let evidence = Evidence(workspaceID: workspaceID, title: "系统声音权利核对：" + voice.name, source: "本机AVSpeechSynthesizer；voice=" + voice.identifier, claim: "系统合成语音的适用授权范围待人工核对", owner: "Apple系统声音 / " + voice.name, commercialAllowed: false, uploadConsent: false, verified: false, assetID: asset.id)
        asset.evidenceID = evidence.id
        var boundScene = scene; boundScene.speechPlan = plan
        let take = VoiceTake(assetID: asset.id, textDigest: try SpeechRules.digest(boundScene), durationFrames: asset.durationFrames!, method: "local_system_speech:" + voice.identifier, listened: false)
        return SpeechProduction(asset: asset, evidence: evidence, diagnostics: diagnostics, plan: plan, captions: try SpeechRules.captions(plan, durationFrames: asset.durationFrames!), take: take)
    }
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.writer?.finish(.failure(CancellationError())) }
    }
}
