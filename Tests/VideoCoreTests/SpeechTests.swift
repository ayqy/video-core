import XCTest
@testable import VideoCore

final class SpeechTests: XCTestCase {
    func testCaptionTimelineUsesActualDiscreteSamplesAtNonDivisibleSpeeds() throws {
        for (speed, start, end, expected) in [(2.0, 31, 61, 16..<31), (1.5, 31, 62, 21..<42),
                                               (1.1, 33, 67, 30..<61)] {
            var scene = Scene(title: "字幕映射", body: "保留实际显示的句段", durationFrames: 90)
            scene.speed = speed
            scene.captions = [Caption(text: "这句须完整保留。", startFrame: start, endFrame: end)]
            let mapped = try SpeechRules.captionTimelineRanges(for: scene)
            XCTAssertEqual(mapped.map(\.frames), [expected])
            // Linear sampling of the shipped painter is an independent oracle
            // for the inverse's binary search, including floating-point edges.
            for frame in 0..<scene.timelineFrames {
                let source = scene.renderSourceFrame(atTimelineFrame: frame)
                XCTAssertEqual(mapped[0].frames.contains(frame), start <= source && source < end)
            }
        }
    }

    func testCaptionTimelineSortsLegalUnorderedCuesAndPreservesGapsAndIdentity() throws {
        var scene = Scene(title: "字幕顺序", body: "两句话之间保留空隙", durationFrames: 90)
        scene.speed = 1.5
        let late = Caption(text: "后一句。", startFrame: 31, endFrame: 62, confirmed: true)
        let early = Caption(text: "前一句。", startFrame: 0, endFrame: 20, confirmed: false)
        scene.captions = [late, early]
        let original = scene.captions
        let mapped = try SpeechRules.captionTimelineRanges(for: scene)
        XCTAssertEqual(mapped.map(\.caption), [early, late])
        XCTAssertEqual(mapped.map(\.frames), [0..<14, 21..<42])
        XCTAssertFalse(mapped.contains { $0.frames.contains(14) || $0.frames.contains(20) })
        XCTAssertEqual(scene.captions, original, "时间输出不重写作者字幕或确认元数据")
    }

    func testCaptionTimelineRetainsRoundedTailAndTheShippedPauseMapping() throws {
        var tail = Scene(title: "句尾", body: "最后一帧仍显示字幕", durationFrames: 123)
        tail.speed = 2
        tail.captions = [Caption(text: "最后一句。", startFrame: 56, endFrame: 123)]
        XCTAssertEqual(tail.timelineFrames, 62)
        XCTAssertEqual(try SpeechRules.captionTimelineRanges(for: tail).map(\.frames), [28..<62])
        var roundedDown = Scene(title: "有限输出", body: "不在镜头外增加一帧", durationFrames: 110)
        roundedDown.speed = 1.5
        roundedDown.captions = [Caption(text: "完整可见窗。", startFrame: 0, endFrame: 110)]
        XCTAssertEqual(try SpeechRules.captionTimelineRanges(for: roundedDown).map(\.frames), [0..<73])
        var pause = Scene(title: "既有停顿映射", body: "按画面实际源帧核对", durationFrames: 9)
        pause.speed = 4; pause.pauseFrames = 2
        pause.captions = [Caption(text: "末帧。", startFrame: 8, endFrame: 9)]
        XCTAssertEqual(pause.timelineFrames, 4)
        XCTAssertEqual(try SpeechRules.captionTimelineRanges(for: pause).map(\.frames), [2..<3])
        pause.pauseFrames = 0
        XCTAssertThrowsError(try SpeechRules.captionTimelineRanges(for: pause))
    }

    func testCaptionTimelineRejectsInvisibleCueInsteadOfDroppingItsText() throws {
        var scene = Scene(title: "保留原句", body: "快放也不能省略字幕", durationFrames: 90)
        scene.speed = 4
        scene.captions = [Caption(text: "可见一句。", startFrame: 0, endFrame: 1),
                          Caption(text: "不能省掉这句。", startFrame: 1, endFrame: 2)]
        let original = scene.captions
        XCTAssertThrowsError(try SpeechRules.captionTimelineRanges(for: scene)) { error in
            XCTAssertEqual((error as? VideoError)?.code, "needs_review")
            XCTAssertTrue(error.localizedDescription.contains("调慢"))
        }
        XCTAssertEqual(scene.captions, original)
    }

    func testCaptionTimelineRejectsInvalidMapInputsBeforeIntegerConversion() throws {
        let valid = Scene(title: "输入核对", body: "不把非法速度转为整数", durationFrames: 90)
        for speed in [Double.nan, .infinity, -.infinity, 0, 0.249, 4.001] {
            var scene = valid; scene.speed = speed
            XCTAssertThrowsError(try SpeechRules.captionTimelineRanges(for: scene))
        }
        for count in [Int.min, -1, 0, 54001, Int.max] {
            var scene = valid; scene.durationFrames = count
            XCTAssertThrowsError(try SpeechRules.captionTimelineRanges(for: scene))
        }
        for count in [Int.min, -1, 54001, Int.max] {
            var scene = valid; scene.pauseFrames = count
            XCTAssertThrowsError(try SpeechRules.captionTimelineRanges(for: scene))
        }
    }

    func testQualityBlocksInvisibleCaptionsForBothPreviewAndFormalReview() throws {
        var scene = Scene(title: "检查字幕", body: "先调好可见时间再制作", durationFrames: 90)
        scene.speed = 4
        scene.captions = [Caption(text: "这句不能消失。", startFrame: 1, endFrame: 2)]
        let revision = try Planner.create(workspaceID: "w", name: "字幕可见性规则", scenes: [scene])
        let before = try Codec.data(revision)
        for requireReview in [false, true] {
            let issues = try Quality.inspect(revision, database: Database(), requireReview: requireReview)
            let issue = try XCTUnwrap(issues.first { $0.id == scene.id + "caption_ranges" })
            XCTAssertTrue(issue.message.contains("可见输出帧"))
        }
        XCTAssertEqual(try Codec.data(revision), before, "质量门不能替作者修改字幕或伪造确认")
    }

    func testImportedVoiceKeepsCompleteSourceAcrossMeasuredResamplingFrameBoundary() throws {
        // Real 22050Hz source / completed 48000Hz AVAssetReader output from scene02.
        let source = 80128.0 / 22050
        let decoded = 174395.0 / 48000
        XCTAssertEqual(Int(ceil(source * 30)), 110)
        XCTAssertEqual(Int(ceil(decoded * 30)), 109)
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 110,
            containerDuration: source, decodedDuration: decoded), 110,
            "重采样时钟差不能把完整原音从110帧缩为109帧")
    }

    func testImportedVoicePreservesContainerSpanWhenDecodedClockIsSlightlyLonger() throws {
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 30,
            containerDuration: 1, decodedDuration: 1.0005), 30)
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 31,
            containerDuration: 1.0005, decodedDuration: 1), 31)
    }

    func testImportedVoiceRejectsRegistrationThatOnlyMatchesDecodedClock() throws {
        let source = 80128.0 / 22050
        let decoded = 174395.0 / 48000
        for registration in [109, 111, 0, -1, Int.min, Int.max] {
            XCTAssertThrowsError(try SpeechRules.importedDurationFrames(registeredFrames: registration,
                containerDuration: source, decodedDuration: decoded)) { error in
                XCTAssertEqual((error as? VideoError)?.code, "needs_review")
            }
        }
    }

    func testImportedVoiceRejectsInvalidDurationsBeforeIntegerConversion() throws {
        for invalid in [Double.nan, .infinity, -.infinity, 0, -0.001, 3600.001, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try SpeechRules.importedDurationFrames(registeredFrames: 30,
                containerDuration: invalid, decodedDuration: 1))
            XCTAssertThrowsError(try SpeechRules.importedDurationFrames(registeredFrames: 30,
                containerDuration: 1, decodedDuration: invalid))
        }
    }

    func testImportedVoiceRejectsCrossFrameDifferencesOverOneMillisecondInEitherDirection() throws {
        for (source, decoded, frames) in [(3.6345, 3.6325, 110), (1.0, 1.002, 30),
                                          (1.001001, 1.0, 31), (1.0, 1.001001, 30)] {
            XCTAssertThrowsError(try SpeechRules.importedDurationFrames(registeredFrames: frames,
                containerDuration: source, decodedDuration: decoded)) { error in
                XCTAssertEqual((error as? VideoError)?.code, "needs_review")
            }
        }
    }

    func testImportedVoiceAllowsOneMillisecondBoundaryWithoutShorteningSource() throws {
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 30,
            containerDuration: 1, decodedDuration: 1.001), 30)
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 31,
            containerDuration: 1.001, decodedDuration: 1), 31)
    }

    func testImportedVoiceRetainsPreviousSameFrameBucketBehavior() throws {
        // Both complete readings round to109; the existing equality rule accepted them.
        XCTAssertGreaterThan(abs(3.61 - 3.63), 0.001)
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 109,
            containerDuration: 3.61, decodedDuration: 3.63), 109)
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 109,
            containerDuration: 3.63, decodedDuration: 3.61), 109)
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 30,
            containerDuration: 1, decodedDuration: 1), 30)
        XCTAssertEqual(try SpeechRules.importedDurationFrames(registeredFrames: 108000,
            containerDuration: 3600, decodedDuration: 3600), 108000)
    }

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

    func testOrdinarySceneSpeedChangesRevokeVoiceAndCaptionApprovalsWhileKeepingSourcesAndHistory() throws {
        let (project, scene, voiceAsset) = try captionFixture()
        for kind in [SceneKind.explanation, .image, .video] {
            var original = scene
            original.kind = kind
            var assets = [voiceAsset]
            if kind != .explanation {
                let visual = Asset(workspaceID: "w", name: "isolated-visual-reference", hash: "isolated-visual-reference",
                    ext: kind == .image ? "png" : "mov", bytes: 100, mediaType: kind == .image ? "image" : "video", durationFrames: 120)
                assets.append(visual); original.assetID = visual.id
            }
            var prior = project
            var revision = prior.current; revision.scenes = [original]
            revision.review.digest = try revision.contentDigest(); prior.revisions[0] = revision
            let priorDigest = try Codec.digest(prior)
            for speed in [0.5, 2.0] {
                var supplied = original; supplied.speed = speed
                XCTAssertEqual(try supplied.speechDigest(), try original.speechDigest(), "成片变速不改源配音输入摘要")
                let saved = try Editor.apply([.replaceScene(original.id, supplied)], to: prior,
                    baseRevision: prior.current.id, assets: assets, message: "隔离普通镜头成片变速")
                let result = saved.current.scenes[0]
                var expectedVoice = original.voice; expectedVoice?.listened = false
                var expectedCaptions = original.captions
                for index in expectedCaptions.indices { expectedCaptions[index].confirmed = false }
                XCTAssertEqual(result.voice, expectedVoice); XCTAssertEqual(result.captions, expectedCaptions)
                XCTAssertEqual(result.speechPlan, original.speechPlan); XCTAssertEqual(result.narration, original.narration)
                XCTAssertEqual(result.assetID, original.assetID); XCTAssertEqual(result.durationFrames, original.durationFrames)
                XCTAssertEqual(result.sourceStartFrame, original.sourceStartFrame)
                XCTAssertEqual(result.timelineFrames, Int((Double(original.durationFrames) / speed).rounded()))
                XCTAssertFalse(saved.current.review.complete); XCTAssertNil(saved.current.review.digest)
                XCTAssertEqual(try Codec.digest(saved.revisions[0]), try Codec.digest(revision))
                XCTAssertEqual(try Codec.digest(prior), priorDigest)
            }
        }
    }

    func testPitchPreservationChangeRevokesVoiceAndCaptionsAtOriginalAndChangedSpeed() throws {
        let (project, scene, asset) = try captionFixture()
        for speed in [1.0, 1.5] {
            var original = scene; original.speed = speed
            var prior = project
            var revision = prior.current; revision.scenes = [original]
            revision.review.digest = try revision.contentDigest(); prior.revisions[0] = revision
            var supplied = original; supplied.preservePitch = false
            let saved = try Editor.apply([.replaceScene(original.id, supplied)], to: prior,
                baseRevision: prior.current.id, assets: [asset], message: "隔离成片变调设置")
            let result = saved.current.scenes[0]
            XCTAssertFalse(result.preservePitch); XCTAssertFalse(result.voice!.listened)
            XCTAssertTrue(result.captions.allSatisfy { !$0.confirmed })
            XCTAssertEqual(result.voice?.assetID, original.voice?.assetID)
            XCTAssertEqual(result.voice?.textDigest, original.voice?.textDigest)
            XCTAssertEqual(result.voice?.durationFrames, original.voice?.durationFrames)
            XCTAssertEqual(result.captions.map(\.text), original.captions.map(\.text))
            XCTAssertEqual(try Codec.digest(saved.revisions[0]), try Codec.digest(revision))
        }
    }

    func testRecordingIdentityChangesCannotCarryVoiceOrSubtitleApprovals() throws {
        let (project, scene, asset) = try captionFixture()
        var otherAsset = asset; otherAsset.id = Codec.id()
        var shorterAsset = asset; shorterAsset.id = Codec.id(); shorterAsset.durationFrames = 90
        var replacements: [VoiceTake] = []
        var take = scene.voice!; take.assetID = otherAsset.id; replacements.append(take)
        take = scene.voice!; take.method = "other-recording-method"; replacements.append(take)
        take = scene.voice!; take.assetID = shorterAsset.id; take.durationFrames = 90; replacements.append(take)
        take = scene.voice!; take.textDigest = "different-audio-input-digest"; replacements.append(take)
        for replacement in replacements {
            var supplied = scene; supplied.voice = replacement
            let saved = try Editor.apply([.replaceScene(scene.id, supplied)], to: project,
                baseRevision: project.current.id, assets: [asset, otherAsset, shorterAsset], message: "隔离实际配音身份变化")
            var expected = replacement; expected.listened = false
            XCTAssertEqual(saved.current.scenes[0].voice, expected)
            XCTAssertTrue(saved.current.scenes[0].captions.allSatisfy { !$0.confirmed })
            XCTAssertEqual(saved.current.scenes[0].narration, scene.narration)
            XCTAssertEqual(saved.current.scenes[0].speechPlan, scene.speechPlan)
            XCTAssertEqual(try Codec.digest(saved.revisions[0]), try Codec.digest(project.current))
        }
    }

    func testNewOrReplacementVoiceRejectsShortenedExtendedAndUnregisteredSourceAtomically() throws {
        let (project, scene, asset) = try captionFixture()
        let original = try Codec.digest(project)
        var invalidTakes: [VoiceTake] = []
        for frames in [0, 90, 101] {
            var take = scene.voice!; take.durationFrames = frames; invalidTakes.append(take)
        }
        var missing = scene.voice!; missing.assetID = "missing-recording"; invalidTakes.append(missing)
        for take in invalidTakes {
            var supplied = scene; supplied.voice = take
            XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id, supplied)], to: project,
                baseRevision: project.current.id, assets: [asset], message: "拒绝不完整配音")) { error in
                XCTAssertEqual((error as? VideoError)?.code, "needs_review")
            }
            supplied.id = Codec.id()
            XCTAssertThrowsError(try Editor.apply([.insertScene(supplied, 1)], to: project,
                baseRevision: project.current.id, assets: [asset], message: "拒绝新增不完整配音"))
            XCTAssertEqual(try Codec.digest(project), original)
        }
    }

    func testNewVoiceRequiresSameWorkspaceAudioWithPositiveRegisteredCompleteDuration() throws {
        let (project, scene, asset) = try captionFixture()
        var wrongWorkspace = asset; wrongWorkspace.workspaceID = "other-workspace"
        var wrongType = asset; wrongType.mediaType = "video"
        var unknownDuration = asset; unknownDuration.durationFrames = nil
        var zeroDuration = asset; zeroDuration.durationFrames = 0
        var withoutVoice = scene; withoutVoice.voice = nil
        var prior = project; prior.revisions[0].scenes = [withoutVoice]
        for source in [wrongWorkspace, wrongType, unknownDuration, zeroDuration] {
            XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id, scene)], to: prior,
                baseRevision: prior.current.id, assets: [source], message: "拒绝未登记完整声音"))
        }
        let restored = try Editor.apply([.replaceScene(scene.id, scene)], to: prior,
            baseRevision: prior.current.id, assets: [asset], message: "重新绑定完整声音")
        XCTAssertEqual(restored.current.scenes[0].voice?.durationFrames, asset.durationFrames)
        XCTAssertFalse(restored.current.scenes[0].voice!.listened)
    }

    func testHistoricalIncompleteVoiceStaysReadableAndEditableButQualityRejectsNewProduction() throws {
        var (project, scene, asset) = try captionFixture()
        scene.voice?.durationFrames = 90
        project.revisions[0].scenes = [scene]
        var workspace = Workspace(name: "保留历史配音", owner: "owner"); workspace.id = "w"
        var database = Database(); database.workspaces = [workspace]; database.assets = [asset]; database.projects = [project]
        let snapshot = try Codec.data(database)
        let decoded = try Codec.decoder().decode(Database.self, from: snapshot)
        try decoded.validate()
        XCTAssertEqual(try Codec.data(decoded), snapshot)
        for requireReview in [false, true] {
            let issues = try Quality.inspect(project.current, database: decoded, requireReview: requireReview)
            XCTAssertTrue(issues.contains { $0.id == scene.id + "voice_source" })
        }
        var metadata = scene; metadata.voice?.listened = false
        let changedMetadata = try Editor.apply([.replaceScene(scene.id, metadata)], to: project,
            baseRevision: project.current.id, assets: [asset], message: "保留旧版，仅撤听审")
        XCTAssertEqual(changedMetadata.current.scenes[0].voice?.durationFrames, 90)
        var edited = scene; edited.title = "新的画面标题"; edited.speed = 1.25; edited.pauseFrames = 12
        let saved = try Editor.apply([.replaceScene(scene.id, edited)], to: project,
            baseRevision: project.current.id, assets: [asset], message: "历史源上的普通编辑")
        XCTAssertEqual(saved.current.scenes[0].voice?.durationFrames, 90)
        XCTAssertFalse(saved.current.scenes[0].voice!.listened)
        XCTAssertEqual(try Codec.data(saved.revisions[0]), try Codec.data(project.current))
        XCTAssertEqual(try Codec.data(database), snapshot)
    }

    func testSourceVideoWindowChangesRevokeCaptionsWhileKeepingIndependentNarrationApproval() throws {
        let (project, scene, voiceAsset) = try captionFixture()
        let video = Asset(workspaceID: "w", name: "source-video.mov", hash: "isolated-video-reference",
            ext: "mov", bytes: 100, mediaType: "video", durationFrames: 400)
        var otherVideo = video; otherVideo.id = Codec.id()
        var original = scene; original.kind = .video; original.assetID = video.id; original.sourceGain = 1
        var prior = project; prior.revisions[0].scenes = [original]
        var changes: [Scene] = []
        var supplied = original; supplied.assetID = otherVideo.id; changes.append(supplied)
        supplied = original; supplied.sourceStartFrame = 30; changes.append(supplied)
        supplied = original; supplied.durationFrames = 110; changes.append(supplied)
        supplied = original; supplied.kind = .image; changes.append(supplied)
        supplied = original; supplied.assetID = otherVideo.id; supplied.muted = true; changes.append(supplied)
        for change in changes {
            let saved = try Editor.apply([.replaceScene(original.id, change)], to: prior,
                baseRevision: prior.current.id, assets: [voiceAsset, video, otherVideo], message: "实际原片源变化")
            XCTAssertEqual(saved.current.scenes[0].voice, original.voice)
            XCTAssertTrue(saved.current.scenes[0].captions.allSatisfy { !$0.confirmed })
            XCTAssertEqual(saved.current.scenes[0].captions.map(\.text), original.captions.map(\.text))
            XCTAssertFalse(saved.current.review.complete)
            XCTAssertEqual(try Codec.data(saved.revisions[0]), try Codec.data(prior.current))
        }
        var mutedPrior = prior; mutedPrior.revisions[0].scenes[0].muted = true
        var madeAudible = mutedPrior.current.scenes[0]; madeAudible.muted = false; madeAudible.sourceStartFrame = 30
        let saved = try Editor.apply([.replaceScene(original.id, madeAudible)], to: mutedPrior,
            baseRevision: mutedPrior.current.id, assets: [voiceAsset, video], message: "改源并启用原片音")
        XCTAssertEqual(saved.current.scenes[0].voice, original.voice)
        XCTAssertTrue(saved.current.scenes[0].captions.allSatisfy { !$0.confirmed })
    }

    func testSourceGainMuteAndSilentWindowChangesKeepIndependentCaptionApprovals() throws {
        let (project, scene, voiceAsset) = try captionFixture()
        let video = Asset(workspaceID: "w", name: "silent-source.mov", hash: "isolated-video-reference",
            ext: "mov", bytes: 100, mediaType: "video", durationFrames: 400)
        var original = scene; original.kind = .video; original.assetID = video.id; original.sourceGain = 1
        var prior = project; prior.revisions[0].scenes = [original]
        var changes: [Scene] = []
        for gain in [0.0, 0.5, 2.0] {var supplied = original; supplied.sourceGain = gain; changes.append(supplied)}
        var muted = original; muted.muted = true; changes.append(muted)
        for change in changes {
            let saved = try Editor.apply([.replaceScene(original.id, change)], to: prior,
                baseRevision: prior.current.id, assets: [voiceAsset, video], message: "仅改音量或静音")
            XCTAssertEqual(saved.current.scenes[0].voice, original.voice)
            XCTAssertEqual(saved.current.scenes[0].captions, original.captions)
            XCTAssertFalse(saved.current.review.complete)
        }
        for useMute in [false, true] {
            var silentPrior = prior
            silentPrior.revisions[0].scenes[0].sourceGain = useMute ? 1 : 0
            silentPrior.revisions[0].scenes[0].muted = useMute
            var changed = silentPrior.current.scenes[0]; changed.sourceStartFrame = 30
            let saved = try Editor.apply([.replaceScene(original.id, changed)], to: silentPrior,
                baseRevision: silentPrior.current.id, assets: [voiceAsset, video], message: "无原片声的源窗口编辑")
            XCTAssertEqual(saved.current.scenes[0].voice, original.voice)
            XCTAssertEqual(saved.current.scenes[0].captions, original.captions)
        }
    }

    func testAddingOrRemovingRecordingRequiresFreshSubtitleApproval() throws {
        let (project, scene, asset) = try captionFixture()
        var removed = scene; removed.voice = nil
        let withoutVoice = try Editor.apply([.replaceScene(scene.id, removed)], to: project,
            baseRevision: project.current.id, assets: [asset], message: "隔离解除配音")
        XCTAssertNil(withoutVoice.current.scenes[0].voice)
        XCTAssertTrue(withoutVoice.current.scenes[0].captions.allSatisfy { !$0.confirmed })
        var supplied = withoutVoice.current.scenes[0]
        supplied.voice = scene.voice; supplied.captions = scene.captions
        let rebound = try Editor.apply([.replaceScene(scene.id, supplied)], to: withoutVoice,
            baseRevision: withoutVoice.current.id, assets: [asset], message: "隔离重新绑定配音")
        XCTAssertFalse(rebound.current.scenes[0].voice!.listened)
        XCTAssertTrue(rebound.current.scenes[0].captions.allSatisfy { !$0.confirmed })
        XCTAssertEqual(rebound.current.scenes[0].voice?.assetID, asset.id)
        XCTAssertEqual(try Codec.digest(rebound.revisions[0]), try Codec.digest(project.current))
        XCTAssertEqual(try Codec.digest(rebound.revisions[1]), try Codec.digest(withoutVoice.current))
    }

    func testMusicChangesKeepUnchangedSourceVoiceAndCaptionApprovalsButRevokeWholeFilmReview() throws {
        let (project, scene, asset) = try captionFixture()
        var music = asset; music.id = Codec.id(); music.name = "isolated-music-reference"
        for gain in [0.0, 0.1, 2.0] {
            var supplied = scene; supplied.musicGain = gain
            let saved = try Editor.apply([.replaceScene(scene.id, supplied), .music(music.id)], to: project,
                baseRevision: project.current.id, assets: [asset, music], message: "隔离新增或调整配乐")
            XCTAssertEqual(saved.current.musicAssetID, music.id)
            XCTAssertEqual(saved.current.scenes[0].musicGain, gain)
            XCTAssertEqual(saved.current.scenes[0].voice, scene.voice)
            XCTAssertEqual(saved.current.scenes[0].captions, scene.captions)
            XCTAssertFalse(saved.current.review.complete); XCTAssertNil(saved.current.review.digest)
            XCTAssertEqual(try Codec.digest(saved.revisions[0]), try Codec.digest(project.current))
        }
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
