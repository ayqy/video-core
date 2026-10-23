import XCTest
@testable import VideoCore

final class AudioMixRulesTests: XCTestCase {
    func testDuckingEndsAfterActualVoiceRatherThanWholeScene() throws {
        var s = Scene(title: "讲解", body: "内容", durationFrames: 90)
        s.pauseFrames = 30; s.musicGain = 0.8
        s.voice = VoiceTake(assetID: "audio", textDigest: "digest", durationFrames: 30, method: "imported")
        let points = try AudioMixRules.musicEnvelope(scenes: [s], fps: 30)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].endSeconds, 1, accuracy: 0.00001)
        XCTAssertEqual(points[0].startGain, 0.24, accuracy: 0.00001)
        XCTAssertEqual(points[1].endSeconds, 1.15, accuracy: 0.00001)
        XCTAssertEqual(points[2].endSeconds, 4, accuracy: 0.00001)
        XCTAssertEqual(points[2].endGain, 0.8)
    }
    func testMuteAndZeroVoiceGainNeverKeepBackgroundOrSpuriousDuck() throws {
        var s = Scene(title: "静音", body: "内容", durationFrames: 60)
        s.muted = true; s.voice = VoiceTake(assetID: "audio", textDigest: "digest", durationFrames: 30, method: "imported")
        XCTAssertEqual(try AudioMixRules.musicEnvelope(scenes: [s], fps: 30).first?.startGain, 0)
        s.muted = false; s.voiceGain = 0
        XCTAssertEqual(try AudioMixRules.musicEnvelope(scenes: [s], fps: 30).first?.startGain, s.musicGain)
    }
    func testSubFrameSpeedRetainsOneVisibleOutputFrameAndPositiveVoiceEnvelope() throws {
        var s=Scene(title:"短片段",body:"内容",durationFrames:1)
        s.speed=4;s.voice=VoiceTake(assetID:"audio",textDigest:"digest",durationFrames:1,method:"imported")
        XCTAssertEqual(s.timelineFrames,1)
        let envelope=try AudioMixRules.musicEnvelope(scenes:[s],fps:30)
        XCTAssertGreaterThan(envelope[0].endSeconds,0)
        XCTAssertEqual(envelope[0].endSeconds,1.0/120,accuracy:0.000001)
    }
    func testSpeedUsesActualAudioIntervalAndRejectsTruncation() throws {
        var s = Scene(title: "变速", body: "内容", durationFrames: 120)
        s.speed = 2; s.voice = VoiceTake(assetID: "audio", textDigest: "digest", durationFrames: 60, method: "imported")
        XCTAssertEqual(try AudioMixRules.musicEnvelope(scenes: [s], fps: 30).first!.endSeconds, 1, accuracy: 0.00001)
        s.voice?.durationFrames = 121
        XCTAssertThrowsError(try AudioMixRules.musicEnvelope(scenes: [s], fps: 30))
    }
}
