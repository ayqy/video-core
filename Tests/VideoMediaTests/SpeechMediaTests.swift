import XCTest
import AVFoundation
import VideoCore
import VideoMedia

final class SpeechMediaTests: XCTestCase {
    func testRendererRejectsIncompleteHistoricalVoiceBeforeCreatingOutput() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("speech-incomplete-history-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root.appendingPathComponent("workspace"))
        let workspace=Workspace(name:"隔离旧配音制作门",owner:"owner")
        let asset=Asset(workspaceID:workspace.id,name:"registered-source.caf",hash:String(repeating:"a",count:64),ext:"caf",bytes:100,mediaType:"audio",durationFrames:100)
        var scene=Scene(title:"历史配音",body:"保留完整原音",narration:"句尾不能截断。",durationFrames:120)
        scene.voice=VoiceTake(assetID:asset.id,textDigest:try scene.speechDigest(),durationFrames:90,method:"imported-recording",listened:false)
        let revision=try Planner.create(workspaceID:workspace.id,name:"旧版声音",scenes:[scene])
        let project=Project(workspaceID:workspace.id,name:"旧版声音",revision:revision)
        try repository.transaction {$0.workspaces=[workspace];$0.assets=[asset];$0.projects=[project]}
        let before=try Codec.data(repository.read())
        let output=root.appendingPathComponent("rejected-output")
        do {
            _=try await MediaRenderer().render(revision:revision,repository:repository,output:output)
            XCTFail("不完整的历史 take 不能重新制作")
        } catch let error as VideoError {
            XCTAssertEqual(error.code,"needs_review")
            XCTAssertTrue(error.localizedDescription.contains("完整音频原件"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        XCTAssertEqual(try Codec.data(repository.read()),before)
    }
    /// A decoded PCM fixture checks the adapter, not merely arithmetic that mirrors the meter.
    func testReadsActualStereoAudioWithoutCancellingOppositePhaseOrInventingLoudness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("phase.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)); buffer.frameLength = 48000
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<48000 {
            let value: Float = (9600..<38400).contains(frame) ? 0.5 : 0
            channels[0][frame] = value; channels[1][frame] = -value
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let result = try await AudioInspection.inspect(url)
        XCTAssertEqual(result.channels, 2)
        XCTAssertEqual(result.sampleRate, 48000)
        XCTAssertEqual(result.duration, 1, accuracy: 0.001)
        XCTAssertEqual(result.leadingSilence, 0.2, accuracy: 0.001)
        XCTAssertEqual(result.trailingSilence, 0.2, accuracy: 0.001)
        XCTAssertEqual(result.peakDBFS, -6.0206, accuracy: 0.01)
        XCTAssertEqual(result.rmsDBFS, 20 * log10(sqrt(0.25 * 0.6)), accuracy: 0.01)
        XCTAssertEqual(result.clippedSamples, 0)
        XCTAssertEqual(result.measurement, "sample_peak_and_unweighted_rms_dbfs_not_lufs")
    }
    @MainActor func testAvailableVoicesAreRealAndNoMissingChineseVoiceGetsSilentFallback() async throws {
        let voices = SpeechService.voices()
        let actual = AVSpeechSynthesisVoice.speechVoices()
        XCTAssertTrue(voices.allSatisfy { voice in actual.contains { $0.identifier == voice.id && $0.language == voice.language } && voice.language.hasPrefix("zh") })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-unavailable-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root)
        var scene = Scene(title: "配音", body: "正常文本", narration: "正常文本")
        var plan = try ChineseSpeech.normalize(scene.narration); plan.voiceIdentifier = "nonexistent-voice-" + UUID().uuidString; plan.confirmed = true; scene.speechPlan = plan
        do { _ = try await SpeechService().synthesize(plan: plan, scene: scene, repository: repository, workspaceID: "test"); XCTFail("Unavailable voice must never generate a different-language substitute") }
        catch let error as VideoError { XCTAssertEqual(error.code, "unavailable") }
        XCTAssertTrue(try repository.read().assets.isEmpty)
    }
    @MainActor func testInstalledChineseVoiceProducesRealAudioWithUnreviewedRightsAndEstimatedCaptions() async throws {
        let voices = SpeechService.voices()
        guard let voice = voices.first(where: { $0.language == "zh-CN" }) ?? voices.first else {
            throw XCTSkip("本机未提供中文系统声音；未以其他语种或模拟音轨冒充配音生成通过")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-real-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root)
        var scene = Scene(title: "数字读法", body: "先核对课程范围。", narration: "课程九十九元。先核对范围。", durationFrames: 600)
        var plan = try ChineseSpeech.normalize(scene.narration)
        plan.voiceIdentifier = voice.id; plan.confirmed = true; scene.speechPlan = plan
        let result: SpeechProduction
        do { result = try await SpeechService().synthesize(plan: plan, scene: scene, repository: repository, workspaceID: "media-test") }
        catch let error as VideoError where error.code == "unavailable" {
            throw XCTSkip("系统列出中文声音但当前运行时无法实际合成：" + error.localizedDescription)
        }
        let audio = try Data(contentsOf: repository.assetURL(result.asset))
        XCTAssertGreaterThan(audio.count, 1000)
        XCTAssertEqual(result.asset.hash, Codec.hash(audio))
        XCTAssertGreaterThan(result.diagnostics.peakDBFS, -70)
        XCTAssertGreaterThan(result.diagnostics.duration, 0.1)
        XCTAssertEqual(result.take.textDigest, try scene.speechDigest())
        XCTAssertFalse(result.take.listened)
        XCTAssertFalse(result.evidence.verified); XCTAssertFalse(result.evidence.commercialAllowed)
        XCTAssertFalse(result.evidence.owner.isEmpty); XCTAssertFalse(result.evidence.source.isEmpty)
        XCTAssertEqual(result.asset.evidenceID, result.evidence.id)
        XCTAssertTrue(result.captions.allSatisfy { !$0.confirmed && $0.alignment == "estimated_sentence_no_word_timestamps" })
    }
}
