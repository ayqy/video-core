import XCTest
@testable import VideoCore

final class AudioMixRulesTests: XCTestCase {
    func testMixerHeadroomKeepsUnityAndHonoursAllThreeGainRanges() throws {
        var s=Scene(title:"三轨音量",body:"规则输入",durationFrames:60)
        s.voiceGain=0.75;s.sourceGain=0.25;s.musicGain=1
        XCTAssertEqual(try AudioMixRules.mixerHeadroom(scenes:[s],fps:30),1)
        for key in [\Scene.voiceGain,\Scene.sourceGain,\Scene.musicGain] {
            var changed=s;changed[keyPath:key]=1.5
            XCTAssertEqual(try AudioMixRules.mixerHeadroom(scenes:[changed],fps:30),1.5)
            changed[keyPath:key]=2
            XCTAssertEqual(try AudioMixRules.mixerHeadroom(scenes:[changed],fps:30),2)
        }
        s.voiceGain=2;s.sourceGain=2;s.musicGain=2;s.muted=true
        XCTAssertEqual(try AudioMixRules.mixerHeadroom(scenes:[s],fps:30),1,"全轨静音不需要恢复增益")
        XCTAssertThrowsError(try AudioMixRules.mixerHeadroom(scenes:[s],fps:0))
        for bad in [-0.01,2.01,Double.nan,Double.infinity] {
            s.voiceGain=bad
            XCTAssertThrowsError(try AudioMixRules.mixerHeadroom(scenes:[s],fps:30),"静音不能掩盖非法工程音量")
        }
    }

    func testMixerVolumePreservesRequestedLevelsWithinAppleRange() throws {
        for headroom in [1.0,1.5,2.0] {
            for requested in [0.0,0.3,0.75,1.0,headroom] {
                let volume=try AudioMixRules.mixerVolume(requested,headroom:headroom)
                XCTAssertTrue((0...1).contains(volume))
                XCTAssertEqual(volume*headroom,requested,accuracy:0.0000001)
            }
        }
        for headroom in [0.0,0.99,2.01,Double.nan,Double.infinity] {
            XCTAssertThrowsError(try AudioMixRules.mixerVolume(0.5,headroom:headroom))
        }
        for requested in [-0.01,2.01,Double.nan,Double.infinity] {
            XCTAssertThrowsError(try AudioMixRules.mixerVolume(requested,headroom:2))
        }
        XCTAssertThrowsError(try AudioMixRules.mixerVolume(1.5,headroom:1),"归一常数须覆盖全部轨道")
    }

    func testMixerHeadroomDoesNotExpandCueRangeOrBoostItsRequestedGain() throws {
        var s=Scene(title:"提示音",body:"只验证原0到1合同",durationFrames:60)
        s.voiceGain=2
        s.classicArtwork=ClassicArtwork(gameplay:.sokoban,sprites:[],sources:[],audioCues:[ClassicAudioCue(assetID:"cue",startFrame:0,durationFrames:30,gain:0.4)])
        let headroom=try AudioMixRules.mixerHeadroom(scenes:[s],fps:30)
        XCTAssertEqual(headroom,2)
        XCTAssertEqual(try AudioMixRules.mixerVolume(0.4,headroom:headroom)*headroom,0.4)
        for invalid in [-0.01,1.01,Double.nan,Double.infinity] {
            s.classicArtwork?.audioCues[0].gain=invalid
            XCTAssertThrowsError(try AudioMixRules.mixerHeadroom(scenes:[s],fps:30))
        }
    }

    func testCommonHeadroomKeepsDuckReleaseTimesAndUnaffectedTrackGain() throws {
        var s=Scene(title:"原片与配乐",body:"实际旁白时间",durationFrames:120)
        s.speed=2;s.pauseFrames=30;s.sourceGain=2;s.musicGain=1.5;s.voiceGain=0.5
        s.voice=VoiceTake(assetID:"voice",textDigest:"text",durationFrames:30,method:"imported")
        let headroom=try AudioMixRules.mixerHeadroom(scenes:[s],fps:30)
        let source=try AudioMixRules.sourceEnvelope(scene:s,fps:30)
        let music=try AudioMixRules.musicEnvelope(scenes:[s],fps:30)
        XCTAssertEqual(headroom,2)
        XCTAssertEqual(source.map(\.endSeconds),[0.5,0.65,2])
        XCTAssertEqual(music.map(\.endSeconds),[0.5,0.65,3])
        for interval in source+music {
            for requested in [interval.startGain,interval.endGain] {
                XCTAssertEqual(try AudioMixRules.mixerVolume(requested,headroom:headroom)*headroom,requested,accuracy:0.0000001)
            }
        }
        XCTAssertEqual(try AudioMixRules.mixerVolume(s.voiceGain,headroom:headroom)*headroom,0.5,"别的轨道放大不能改变旁白请求")
        s.voiceGain=0
        XCTAssertEqual(try AudioMixRules.sourceEnvelope(scene:s,fps:30).count,1)
        XCTAssertEqual(try AudioMixRules.musicEnvelope(scenes:[s],fps:30).count,1)
    }

    func testMixedPCMRestoresOnceAndUnityKeepsExactSampleBits() throws {
        let original:[Float]=[0,-0.0,0.1,-0.3,0.49,-0.49]
        var unity=original
        try AudioMixRules.restoreMixedPCM(&unity,headroom:1)
        XCTAssertEqual(unity.map(\.bitPattern),original.map(\.bitPattern))
        var scaled=original
        try AudioMixRules.restoreMixedPCM(&scaled,headroom:2)
        XCTAssertEqual(scaled,original.map{Float(Double($0)*2)})
        XCTAssertEqual(scaled.count,original.count,"只恢复增益，不能增删声道采样或补静音")
    }

    func testMixedPCMRejectsOverloadNonFiniteAndInvalidScaleWithoutPartialWrite() throws {
        for bad in [Float(0.5),-0.5,Float.nan,Float.infinity,-Float.infinity] {
            var samples:[Float]=[0.1,bad,-0.1]
            let before=samples.map(\.bitPattern)
            XCTAssertThrowsError(try AudioMixRules.restoreMixedPCM(&samples,headroom:2))
            XCTAssertEqual(samples.map(\.bitPattern),before)
        }
        var full:[Float]=[1]
        XCTAssertThrowsError(try AudioMixRules.restoreMixedPCM(&full,headroom:1))
        for invalid in [0.99,2.01,Double.nan,Double.infinity] {
            var samples:[Float]=[0.1]
            XCTAssertThrowsError(try AudioMixRules.restoreMixedPCM(&samples,headroom:invalid))
            XCTAssertEqual(samples,[0.1])
        }
        var empty:[Float]=[]
        XCTAssertThrowsError(try AudioMixRules.restoreMixedPCM(&empty,headroom:2))
    }

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
