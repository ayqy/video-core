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
    func testSourceDucksActualVoiceAndRestoresBeforeHeldFramePause() throws {
        var s=Scene(title:"原片声",body:"内容",durationFrames:120)
        s.speed=2;s.pauseFrames=30;s.sourceGain=0.8
        s.voice=VoiceTake(assetID:"audio",textDigest:"digest",durationFrames:30,method:"imported")
        let source=try AudioMixRules.sourceEnvelope(scene:s,fps:30)
        XCTAssertEqual(source.count,3)
        XCTAssertEqual(source[0].startSeconds,0)
        XCTAssertEqual(source[0].endSeconds,0.5,accuracy:0.000001)
        XCTAssertEqual(source[0].startGain,0.24,accuracy:0.000001)
        XCTAssertEqual(source[1].endSeconds,0.65,accuracy:0.000001)
        XCTAssertEqual(source[2].endSeconds,2,accuracy:0.000001)
        XCTAssertEqual(source[2].endGain,0.8)
        let music=try AudioMixRules.musicEnvelope(scenes:[s],fps:30)
        XCTAssertEqual(music.last?.endSeconds,3,"配乐仍按原行为覆盖镜头停顿，原片声不延长")
    }
    func testSourceWithoutAudibleVoiceKeepsGainAndMutedSourceIsSilent() throws {
        var s=Scene(title:"原片声",body:"内容",durationFrames:60)
        s.sourceGain=0.7
        let noVoice=try AudioMixRules.sourceEnvelope(scene:s,fps:30)
        XCTAssertEqual(noVoice.count,1);XCTAssertEqual(noVoice[0].startGain,0.7)
        s.voice=VoiceTake(assetID:"audio",textDigest:"digest",durationFrames:30,method:"imported");s.voiceGain=0
        XCTAssertEqual(try AudioMixRules.sourceEnvelope(scene:s,fps:30),noVoice)
        s.voiceGain=1;s.muted=true
        let muted=try AudioMixRules.sourceEnvelope(scene:s,fps:30)
        XCTAssertEqual(muted.count,1);XCTAssertEqual(muted[0].startGain,0);XCTAssertEqual(muted[0].endGain,0)
        s.muted=false;s.sourceGain=0
        XCTAssertTrue(try AudioMixRules.sourceEnvelope(scene:s,fps:30).allSatisfy{$0.startGain==0 && $0.endGain==0})
    }
    func testSourceVoiceAtClipEndNeverReleasesIntoPause() throws {
        var s=Scene(title:"句尾",body:"内容",durationFrames:30)
        s.speed=2;s.pauseFrames=30;s.sourceGain=0.8
        s.voice=VoiceTake(assetID:"audio",textDigest:"digest",durationFrames:30,method:"imported")
        let source=try AudioMixRules.sourceEnvelope(scene:s,fps:30)
        XCTAssertEqual(source.count,1)
        XCTAssertEqual(source[0].endSeconds,0.5,accuracy:0.000001)
        XCTAssertEqual(source[0].endGain,0.24,accuracy:0.000001)
        s.durationFrames=1;s.voice?.durationFrames=1;s.speed=4
        let short=try AudioMixRules.sourceEnvelope(scene:s,fps:30)
        XCTAssertEqual(short[0].endSeconds,1.0/120,accuracy:0.000001)
        XCTAssertEqual(short.last?.endSeconds,1.0/30,"不足一帧的源片仍只覆盖保留的可见帧，不进入停顿")
    }
    func testSourceRejectsInvalidGainTimingAndVoiceTruncation() throws {
        var s=Scene(title:"原片声",body:"内容",durationFrames:30)
        for gain in [-0.01,2.01,Double.nan,Double.infinity] {
            s.sourceGain=gain
            XCTAssertThrowsError(try AudioMixRules.sourceEnvelope(scene:s,fps:30))
        }
        s.sourceGain=0.8
        XCTAssertThrowsError(try AudioMixRules.sourceEnvelope(scene:s,fps:0))
        s.voice=VoiceTake(assetID:"audio",textDigest:"digest",durationFrames:31,method:"imported")
        XCTAssertThrowsError(try AudioMixRules.sourceEnvelope(scene:s,fps:30))
        s.voice=nil;s.pauseFrames = -1
        XCTAssertThrowsError(try AudioMixRules.sourceEnvelope(scene:s,fps:30))
    }
}
