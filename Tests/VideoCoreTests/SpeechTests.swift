import XCTest
@testable import VideoCore

final class SpeechTests: XCTestCase {
    private func captionFixture() throws -> (Project, Scene, Asset) {
        let asset = Asset(workspaceID: "w", name: "isolated-recording.caf", hash: "isolated-domain-audio-reference",
            ext: "caf", bytes: 100, mediaType: "audio", durationFrames: 100)
        var scene = Scene(title: "术语校正规则", body: "字幕草稿与声音独立", narration: "API。示例。", durationFrames: 120)
        var plan = try ChineseSpeech.normalize(scene.narration, dictionary: [SpeechTerm("API", "阿皮")])
        plan.voiceIdentifier = "isolated-voice-reference"; plan.confirmed = true
        scene.speechPlan = plan
        scene.captions = [Caption(text: "API。", startFrame: 0, endFrame: 40, confirmed: true),
                          Caption(text: "示例。", startFrame: 60, endFrame: 100, confirmed: true)]
        scene.voice = VoiceTake(assetID: asset.id, textDigest: try scene.speechDigest(), durationFrames: 100,
            method: "isolated-recording-reference", listened: true)
        var revision = try Planner.create(workspaceID: "w", name: "隔离字幕规则工程", scenes: [scene])
        // Deliberately approved prior state is isolated test data, never runtime acceptance.
        revision.review.text = true; revision.review.rights = true; revision.review.fullPreview = true
        revision.review.sound = true; revision.review.captions = true; revision.review.digest = try revision.contentDigest()
        return (Project(workspaceID: "w", name: "隔离字幕规则工程", revision: revision), scene, asset)
    }

    func testCaptionDraftKeepsOriginalRecordingAndAudioInputsWhileRevokingAllApprovals() throws {
        let (project, scene, asset) = try captionFixture()
        var captions = scene.captions; captions[0].text = "应用程序接口。"; captions[0].endFrame = 45
        let draft = try SpeechRules.captionDraft(captions, for: scene)
        var expected = scene.voice; expected?.listened = false
        XCTAssertEqual(draft.voice, expected)
        XCTAssertEqual(draft.speechPlan, scene.speechPlan); XCTAssertEqual(draft.narration, scene.narration)
        XCTAssertEqual(draft.durationFrames, scene.durationFrames)
        XCTAssertEqual(try draft.speechDigest(), try scene.speechDigest())
        XCTAssertEqual(draft.captions.map(\.id), scene.captions.map(\.id))
        XCTAssertTrue(draft.captions.allSatisfy { !$0.confirmed })
        XCTAssertTrue(scene.voice!.listened); XCTAssertTrue(scene.captions.allSatisfy(\.confirmed))
        let saved = try Editor.apply([.replaceScene(scene.id, draft)], to: project,
            baseRevision: project.current.id, assets: [asset], message: "字幕草稿")
        XCTAssertFalse(saved.current.review.complete); XCTAssertNil(saved.current.review.digest)
        XCTAssertEqual(saved.revisions[0].scenes[0].voice, scene.voice)
        XCTAssertEqual(saved.revisions[0].scenes[0].captions, scene.captions)
    }

    func testMatchingVoiceAllowsEditorialPlanMetadataButRejectsChangedAudioInputs() throws {
        let (_, scene, _) = try captionFixture()
        var editorial = try XCTUnwrap(scene.speechPlan)
        editorial.confirmed = false; editorial.notes = ["新的审校备注"]
        editorial.mappings = [SpeechMapping(sourceStart: 0, sourceLength: editorial.source.utf16.count,
            normalizedStart: 0, normalizedLength: editorial.normalized.utf16.count, kind: "manual_document")]
        XCTAssertEqual(try SpeechRules.matchingVoice(in: scene, plan: editorial), scene.voice)
        var changed: [SpeechPlan] = []
        var value = editorial; value.normalized = "应用程序接口。示例。"; value.mappings = []; changed.append(value)
        value = editorial; value.dictionary = [SpeechTerm("API", "应用程序接口")]; changed.append(value)
        value = editorial; value.voiceIdentifier = "different-isolated-voice"; changed.append(value)
        value = editorial; value.rate = 0.4; changed.append(value)
        for plan in changed { XCTAssertNil(try SpeechRules.matchingVoice(in: scene, plan: plan)) }
        value = editorial; value.source = "另一原文"; value.mappings = []
        XCTAssertThrowsError(try SpeechRules.matchingVoice(in: scene, plan: value))
    }

    func testCaptionContentChangesCannotCarryOldVoiceOrCueApprovalsThroughEditor() throws {
        let (project, scene, asset) = try captionFixture()
        var changes: [[Caption]] = []
        var value = scene.captions; value[0].text = "接口。"; changes.append(value)
        value = scene.captions; value[0].startFrame = 1; changes.append(value)
        value = scene.captions; value[0].endFrame = 39; changes.append(value)
        value = scene.captions; value.insert(Caption(text: "补充", startFrame: 40, endFrame: 60, confirmed: true), at: 1); changes.append(value)
        changes.append(Array(scene.captions.dropFirst())); changes.append(Array(scene.captions.reversed()))
        for captions in changes {
            var supplied = scene; supplied.captions = captions
            let saved = try Editor.apply([.replaceScene(scene.id, supplied)], to: project,
                baseRevision: project.current.id, assets: [asset], message: "实际字幕变化")
            let result = saved.current.scenes[0]
            XCTAssertEqual(result.voice?.assetID, scene.voice?.assetID)
            XCTAssertEqual(result.voice?.textDigest, scene.voice?.textDigest)
            XCTAssertEqual(result.voice?.durationFrames, scene.voice?.durationFrames)
            XCTAssertEqual(result.speechPlan, scene.speechPlan)
            XCTAssertFalse(result.voice!.listened); XCTAssertTrue(result.captions.allSatisfy { !$0.confirmed })
            XCTAssertFalse(saved.current.review.complete)
        }
    }

    func testApprovalAndProvenanceMetadataDoNotInvalidateMatchingCaptionContent() throws {
        let (project, scene, asset) = try captionFixture()
        var metadata = scene
        for index in metadata.captions.indices {
            metadata.captions[index].id = Codec.id(); metadata.captions[index].alignment = "user-reviewed-timing"
            metadata.captions[index].confirmed = false
        }
        XCTAssertEqual(try SpeechRules.captionContentDigest(metadata.captions), try SpeechRules.captionContentDigest(scene.captions))
        let saved = try Editor.apply([.replaceScene(scene.id, metadata)], to: project,
            baseRevision: project.current.id, assets: [asset], message: "字幕确认元数据")
        XCTAssertTrue(saved.current.scenes[0].voice!.listened)
        XCTAssertEqual(saved.current.scenes[0].captions, metadata.captions)
    }

    func testSavedCaptionDraftCanBeReheardAndConfirmedWithoutAnotherContentInvalidation() throws {
        let (project, scene, asset) = try captionFixture()
        var captions = scene.captions; captions[0].text = "接口。"
        let draft = try SpeechRules.captionDraft(captions, for: scene)
        let saved = try Editor.apply([.replaceScene(scene.id, draft)], to: project,
            baseRevision: project.current.id, assets: [asset], message: "先存字幕草稿")
        var confirmed = saved.current.scenes[0]
        confirmed.voice?.listened = true
        for index in confirmed.captions.indices { confirmed.captions[index].confirmed = true }
        let reviewed = try Editor.apply([.replaceScene(scene.id, confirmed)], to: saved,
            baseRevision: saved.current.id, assets: [asset], message: "后存真实听审声明")
        XCTAssertTrue(reviewed.current.scenes[0].voice!.listened)
        XCTAssertTrue(reviewed.current.scenes[0].captions.allSatisfy(\.confirmed))
        XCTAssertFalse(reviewed.current.review.complete)
        XCTAssertFalse(saved.current.scenes[0].voice!.listened)
    }

    func testCaptionApprovalCanBeSavedWithoutConfirmingVoice() throws {
        let (project, scene, asset) = try captionFixture()
        var captions = scene.captions; captions[0].text = "接口。"
        let draft = try SpeechRules.captionDraft(captions, for: scene)
        let saved = try Editor.apply([.replaceScene(scene.id, draft)], to: project,
            baseRevision: project.current.id, assets: [asset], message: "隔离字幕草稿")
        var captionsOnly = saved.current.scenes[0]
        for index in captionsOnly.captions.indices { captionsOnly.captions[index].confirmed = true }
        let result = try Editor.apply([.replaceScene(scene.id, captionsOnly)], to: saved,
            baseRevision: saved.current.id, assets: [asset], message: "仅记录隔离字幕确认")
        XCTAssertTrue(result.current.scenes[0].captions.allSatisfy(\.confirmed))
        XCTAssertFalse(result.current.scenes[0].voice!.listened)
        XCTAssertEqual(result.current.scenes[0].voice, saved.current.scenes[0].voice)
        XCTAssertEqual(result.current.scenes[0].speechPlan, scene.speechPlan)
        XCTAssertEqual(result.current.scenes[0].narration, scene.narration)
        XCTAssertFalse(saved.current.scenes[0].captions.allSatisfy(\.confirmed))
        XCTAssertFalse(result.current.review.complete)
    }

    func testVoiceApprovalCanBeSavedWithoutConfirmingCaptions() throws {
        let (project, scene, asset) = try captionFixture()
        var captions = scene.captions; captions[0].text = "接口。"
        let draft = try SpeechRules.captionDraft(captions, for: scene)
        let saved = try Editor.apply([.replaceScene(scene.id, draft)], to: project,
            baseRevision: project.current.id, assets: [asset], message: "隔离字幕草稿")
        var voiceOnly = saved.current.scenes[0]; voiceOnly.voice?.listened = true
        let result = try Editor.apply([.replaceScene(scene.id, voiceOnly)], to: saved,
            baseRevision: saved.current.id, assets: [asset], message: "仅记录隔离声音确认")
        XCTAssertTrue(result.current.scenes[0].voice!.listened)
        XCTAssertTrue(result.current.scenes[0].captions.allSatisfy { !$0.confirmed })
        XCTAssertEqual(result.current.scenes[0].voice?.assetID, scene.voice?.assetID)
        XCTAssertEqual(result.current.scenes[0].voice?.textDigest, scene.voice?.textDigest)
        XCTAssertEqual(result.current.scenes[0].captions, saved.current.scenes[0].captions)
        XCTAssertEqual(result.current.scenes[0].speechPlan, scene.speechPlan)
        XCTAssertEqual(result.current.scenes[0].narration, scene.narration)
        XCTAssertFalse(saved.current.scenes[0].voice!.listened)
        XCTAssertFalse(result.current.review.complete)
    }

    func testCaptionDraftCannotBypassSceneLockOrStaleRevision() throws {
        let (project, scene, asset) = try captionFixture()
        var captions = scene.captions; captions[0].text = "接口。"
        let draft = try SpeechRules.captionDraft(captions, for: scene)
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id, draft)], to: project,
            baseRevision: "stale-revision", assets: [asset], message: "旧字幕窗口")) {
            XCTAssertEqual(($0 as? VideoError)?.code, "revision_conflict")
        }
        var locked = project; locked.revisions[0].scenes[0].locked = true
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id, draft)], to: locked,
            baseRevision: locked.current.id, assets: [asset], message: "锁定镜头字幕")) {
            XCTAssertEqual(($0 as? VideoError)?.code, "permission_required")
        }
    }

    func testCaptionDraftRejectsInvalidTimingAndStaleOrMissingAudioBinding() throws {
        let (_, scene, _) = try captionFixture()
        var invalid: [[Caption]] = []
        var value = scene.captions; value[0].text = ""; invalid.append(value)
        value = scene.captions; value[0].startFrame = -1; invalid.append(value)
        value = scene.captions; value[0].endFrame = 61; invalid.append(value)
        value = scene.captions; value[1].endFrame = 121; invalid.append(value)
        value = scene.captions; value[1].id = value[0].id; invalid.append(value)
        value = scene.captions; value[0].id = ""; invalid.append(value)
        for captions in invalid { XCTAssertThrowsError(try SpeechRules.captionDraft(captions, for: scene)) }
        var missing = scene; missing.voice = nil
        XCTAssertThrowsError(try SpeechRules.captionDraft(scene.captions, for: missing))
        var stale = scene; stale.speechPlan?.rate = 0.4
        XCTAssertThrowsError(try SpeechRules.captionDraft(scene.captions, for: stale))
    }

    func testUntrustedMappingIntegerExtremesAreRejectedAsInvalidInput() throws {
        let invalid = [
            SpeechMapping(sourceStart: .max, sourceLength: 1, normalizedStart: 0, normalizedLength: 1, kind: "manual"),
            SpeechMapping(sourceStart: 1, sourceLength: .max, normalizedStart: 0, normalizedLength: 1, kind: "manual"),
            SpeechMapping(sourceStart: 0, sourceLength: 1, normalizedStart: .max, normalizedLength: 1, kind: "manual"),
            SpeechMapping(sourceStart: 0, sourceLength: 1, normalizedStart: 1, normalizedLength: .max, kind: "manual"),
            SpeechMapping(sourceStart: .min, sourceLength: 1, normalizedStart: 0, normalizedLength: 1, kind: "manual"),
            SpeechMapping(sourceStart: 0, sourceLength: .min, normalizedStart: 0, normalizedLength: 1, kind: "manual"),
            SpeechMapping(sourceStart: 0, sourceLength: 1, normalizedStart: .min, normalizedLength: 1, kind: "manual"),
            SpeechMapping(sourceStart: 0, sourceLength: 1, normalizedStart: 0, normalizedLength: .min, kind: "manual")]
        for mapping in invalid {
            // Exercise the same Codable integer domain as an untrusted plan on
            // the normal CLI, rather than narrowing it to small UI offsets.
            let input = SpeechPlan(source: "甲乙", normalized: "甲乙", mappings: [mapping])
            let decoded = try Codec.decoder().decode(SpeechPlan.self, from: Codec.data(input))
            XCTAssertThrowsError(try decoded.validate()) { error in
                XCTAssertEqual((error as? VideoError)?.exitCode, 2, "极端映射须正常拒绝，不能溢出终止进程")
            }
        }
    }
    func testMappingExactUTF16EndsRemainValidWhileOverrunAndReorderingFail() throws {
        let exact = [SpeechMapping(sourceStart: 0, sourceLength: 1, normalizedStart: 0, normalizedLength: 1, kind: "literal"),
                     SpeechMapping(sourceStart: 1, sourceLength: 2, normalizedStart: 1, normalizedLength: 2, kind: "literal"),
                     SpeechMapping(sourceStart: 3, sourceLength: 1, normalizedStart: 3, normalizedLength: 1, kind: "literal")]
        let input = SpeechPlan(source: "甲😀乙", normalized: "丁😀戊", mappings: exact)
        XCTAssertEqual(input.source.utf16.count, 4); XCTAssertEqual(input.normalized.utf16.count, 4)
        try input.validate()
        var bad = input; bad.mappings[2].sourceLength = 2
        XCTAssertThrowsError(try bad.validate())
        bad = input; bad.mappings[2].normalizedLength = 2
        XCTAssertThrowsError(try bad.validate())
        bad = input; bad.mappings[2].sourceStart = 2
        XCTAssertThrowsError(try bad.validate())
        bad = input; bad.mappings[2].normalizedStart = 2
        XCTAssertThrowsError(try bad.validate())
        bad = input; bad.mappings[2].sourceLength = 0
        XCTAssertThrowsError(try bad.validate())
        bad = input; bad.mappings[2].normalizedLength = 0
        XCTAssertThrowsError(try bad.validate())
        let longest = SpeechPlan(source: String(repeating: "甲", count: 4000), normalized: String(repeating: "乙", count: 8000),
            mappings: [SpeechMapping(sourceStart: 0, sourceLength: 4000, normalizedStart: 0, normalizedLength: 8000, kind: "manual_document")])
        try longest.validate()
    }
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
