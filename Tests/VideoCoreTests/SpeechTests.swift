import XCTest
@testable import VideoCore

final class SpeechTests: XCTestCase {
    func testChineseNormalizationPreservesSourceAndAuditableMapping() throws {
        let text = "2026-10-22，AI课￥99.50，增长12.5%，预算10001。"
        let plan = try ChineseSpeech.normalize(text, dictionary: [SpeechTerm("AI", "人工智能")])
        XCTAssertEqual(plan.source, text)
        XCTAssertEqual(plan.normalized, "二零二六年十月二十二日，人工智能课九十九点五零元，增长百分之十二点五，预算一万零一。")
        XCTAssertFalse(plan.confirmed)
        XCTAssertEqual(plan.mappings.reduce(0) { $0 + $1.sourceLength }, text.utf16.count)
        XCTAssertEqual(plan.mappings.reduce(0) { $0 + $1.normalizedLength }, plan.normalized.utf16.count)
        try plan.validate()
    }
    func testLongestTermWinsAndReplacementsAreNeverReprocessed() throws {
        let plan = try ChineseSpeech.normalize("GPT4与GPT，USD12。", dictionary: [SpeechTerm("GPT", "AI"), SpeechTerm("GPT4", "版本四"), SpeechTerm("USD12", "十二美金")])
        XCTAssertEqual(plan.normalized, "版本四与AI，十二美金。")
        XCTAssertEqual(ChineseSpeech.number("100000001"), "一亿零一")
        XCTAssertEqual(ChineseSpeech.number("100010001"), "一亿零一万零一")
        XCTAssertEqual(ChineseSpeech.number("-0.05"), "负零点零五")
        XCTAssertEqual(ChineseSpeech.number("00123"), "零零一二三")
        XCTAssertEqual(try ChineseSpeech.normalize("API与99元").normalized, "A P I与九十九元")
    }
    func testSpeechBindingDetectsDictionaryVoiceAndRateChangesIndependentlyOfScript() throws {
        var scene = Scene(title: "术语", body: "AI", narration: "AI是工具")
        let legacy = try scene.speechDigest()
        XCTAssertEqual(legacy, try Codec.digest(scene.narration))
        var plan = try ChineseSpeech.normalize(scene.narration, dictionary: [SpeechTerm("AI", "人工智能")])
        plan.voiceIdentifier = "actual-installed-voice-id"; plan.confirmed = true; scene.speechPlan = plan
        let bound = try SpeechRules.digest(scene)
        scene.speechPlan?.confirmed = false
        XCTAssertEqual(bound, try SpeechRules.digest(scene))
        scene.speechPlan?.dictionary = [SpeechTerm("AI", "A I")]
        XCTAssertNotEqual(bound, try SpeechRules.digest(scene))
        scene.speechPlan = plan; scene.speechPlan?.rate = 0.4
        XCTAssertNotEqual(bound, try SpeechRules.digest(scene))
        scene.speechPlan = plan; scene.speechPlan?.voiceIdentifier = "different-voice"
        XCTAssertNotEqual(bound, try SpeechRules.digest(scene))
        scene.narration = "已修改原文"
        XCTAssertThrowsError(try SpeechRules.digest(scene))
    }
    func testEstimatedCaptionsNeverClaimWordAlignmentOrApproval() throws {
        let plan = try ChineseSpeech.normalize("价格99元。请先了解范围！")
        let captions = try SpeechRules.captions(plan, durationFrames: 120)
        XCTAssertEqual(captions.count, 2)
        XCTAssertEqual(captions.first?.text, "价格99元。")
        XCTAssertEqual(captions.last?.endFrame, 120)
        XCTAssertTrue(captions.allSatisfy { !$0.confirmed && $0.alignment == "estimated_sentence_no_word_timestamps" })
        try SpeechRules.validateCaptions(captions, durationFrames: 120)
        var overlapping = captions; overlapping[1].startFrame = 0
        XCTAssertThrowsError(try SpeechRules.validateCaptions(overlapping, durationFrames: 120))
        let revised = plan.manuallyRevised("价格九十九元。了解课程范围。")
        XCTAssertFalse(revised.confirmed); XCTAssertEqual(revised.mappings.first?.kind, "manual_document")
        try revised.validate()
    }
    func testSampleMeterRetainsStereoClippingAndSilenceBoundaries() throws {
        var meter = try AudioMeter(sampleRate: 8000, channels: 2)
        try meter.append([Float](repeating: 0, count: 1600)) // 100 ms silence
        var tone: [Float] = []
        for _ in 0..<800 { tone += [1, -1] } // Opposite-phase stereo must not cancel the peak meter.
        try meter.append(tone)
        try meter.append([Float](repeating: 0, count: 1600))
        let result = try meter.finish()
        XCTAssertEqual(result.duration, 0.3, accuracy: 0.000001)
        XCTAssertEqual(result.leadingSilence, 0.1, accuracy: 0.000001)
        XCTAssertEqual(result.trailingSilence, 0.1, accuracy: 0.000001)
        XCTAssertEqual(result.peakDBFS, 0, accuracy: 0.001)
        XCTAssertEqual(result.rmsDBFS, 10 * log10(1.0 / 3.0), accuracy: 0.001)
        XCTAssertEqual(result.clippedSamples, 1600)
        XCTAssertTrue(result.warnings.contains { $0.contains("削波") })
        XCTAssertEqual(result.envelope.map(\.peak).max(), 1)
        XCTAssertThrowsError(try meter.append([.nan, 0]))
        XCTAssertThrowsError(try AudioMeter(sampleRate: 0, channels: 1))
    }
    func testEditorialTNConfirmationKeepsMatchingAudioButActualPronunciationChangeInvalidatesIt() throws {
        let product = Product(workspaceID: "w", sku: "test", name: "课堂", checkout: "https://example.com/course", audience: "学习者", task: "理解概念", outcome: "能解释", prerequisite: "无", scope: "概念", prices: [Price(money: Money(99), source: "规则夹具")])
        let asset = Asset(workspaceID: "w", name: "actual-take.caf", hash: "test-domain-reference", ext: "caf", bytes: 100, mediaType: "audio", durationFrames: 90)
        var scene = Scene(title: "术语", body: "学习知识", narration: "AI", durationFrames: 120)
        scene.speechPlan = try ChineseSpeech.normalize(scene.narration, dictionary: [SpeechTerm("AI", "人工智能")])
        scene.captions = [Caption(text: "AI", startFrame: 0, endFrame: 90, alignment: "manual", confirmed: true)]
        scene.voice = VoiceTake(assetID: asset.id, textDigest: try scene.speechDigest(), durationFrames: 90, method: "imported-recording", listened: true)
        let project = Project(workspaceID: "w", name: "术语", revision: Revision(product: product, purpose: .education, aspect: .portrait, scenes: [scene], cta: "复现"))
        var confirmed = scene
        confirmed.speechPlan?.confirmed = true; confirmed.speechPlan?.notes = ["人工复核读法一致"]
        let saved = try Editor.apply([.replaceScene(scene.id, confirmed)], to: project, baseRevision: project.current.id, assets: [asset], message: "补充审校")
        XCTAssertEqual(saved.current.scenes[0].voice, scene.voice)
        XCTAssertTrue(saved.current.scenes[0].captions[0].confirmed)
        XCTAssertFalse(saved.current.review.complete)
        var changed = confirmed
        changed.speechPlan?.dictionary = [SpeechTerm("AI", "A I")]
        changed.speechPlan?.normalized = "A I"
        changed.speechPlan?.mappings = []
        let revised = try Editor.apply([.replaceScene(scene.id, changed)], to: saved, baseRevision: saved.current.id, assets: [asset], message: "修改发音")
        XCTAssertNil(revised.current.scenes[0].voice)
        XCTAssertFalse(revised.current.scenes[0].captions[0].confirmed)
    }
}
