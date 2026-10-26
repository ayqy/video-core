import Foundation

public struct MusicGainSegment: Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var startGain: Double
    public var endGain: Double
}

/// Deterministic accompaniment envelopes shared by rendering and UI descriptions.
/// Duck only the audible, real voice interval. A muted scene is silent on all tracks.
public enum AudioMixRules {
    /// The IR allows 0...2, whereas AVAudioMix volume parameters allow only 0...1.
    /// Use one scale for every track, then restore it once on the mixed Float32 PCM.
    /// This is rendering headroom, not source normalization or an automatic limiter.
    public static func mixerHeadroom(scenes: [Scene], fps: Int) throws -> Double {
        guard (1...120).contains(fps) else { throw VideoError.invalid("混音帧率无效") }
        var result = 1.0
        for scene in scenes {
            try validate(scene, fps: fps)
            for cue in scene.classicArtwork?.audioCues ?? [] {
                guard cue.gain.isFinite, (0...1).contains(cue.gain) else { throw VideoError.invalid("游戏音效音量超出0到1范围") }
            }
            if !scene.muted { result = max(result, max(scene.voiceGain, max(scene.sourceGain, scene.musicGain))) }
        }
        return result
    }

    public static func mixerVolume(_ requested: Double, headroom: Double) throws -> Double {
        guard headroom.isFinite, (1...2).contains(headroom), requested.isFinite,
              (0...2).contains(requested), requested <= headroom else { throw VideoError.invalid("混音增益或统一余量无效") }
        return requested / headroom
    }

    /// Check the actual restored samples before AAC can hide an upstream overload.
    /// Validate the whole buffer first, so a rejected buffer remains unchanged.
    public static func restoreMixedPCM(_ samples: inout [Float], headroom: Double) throws {
        guard headroom.isFinite, (1...2).contains(headroom), !samples.isEmpty,
              samples.count <= 8 * 1024 * 1024 else { throw VideoError.invalid("混音PCM缓冲或统一余量无效") }
        for sample in samples {
            let restored = Float(Double(sample) * headroom)
            guard restored.isFinite else { throw VideoError.review("实际混音含非有限采样，未送入AAC编码") }
            guard abs(restored) < 1 else { throw VideoError.review("实际混音在AAC编码前达到满幅过载，请降低分轨音量并重做、听审") }
        }
        if headroom > 1 {
            for index in samples.indices { samples[index] = Float(Double(samples[index]) * headroom) }
        }
    }

    public static func musicEnvelope(scenes: [Scene], fps: Int) throws -> [MusicGainSegment] {
        guard (1...120).contains(fps) else { throw VideoError.invalid("混音帧率无效") }
        var cursor = 0.0
        var result: [MusicGainSegment] = []
        for scene in scenes {
            try validate(scene, fps: fps)
            let length = Double(scene.timelineFrames) / Double(fps)
            result += envelope(scene: scene, gain: scene.musicGain, length: length, offset: cursor, fps: fps)
            cursor += length
        }
        return result
    }

    /// Scene-local source audio ends with the speed-adjusted clip, before any held-frame pause.
    /// The historical MusicGainSegment type remains the shared gain-ramp representation.
    public static func sourceEnvelope(scene: Scene, fps: Int) throws -> [MusicGainSegment] {
        try validate(scene, fps: fps)
        let length = Double(scene.timelineFrames - scene.pauseFrames) / Double(fps)
        return envelope(scene: scene, gain: scene.sourceGain, length: length, offset: 0, fps: fps)
    }

    private static func validate(_ scene: Scene, fps: Int) throws {
        guard (1...120).contains(fps) else { throw VideoError.invalid("混音帧率无效") }
        guard scene.speed.isFinite, (0.25...4).contains(scene.speed),
              (0...2).contains(scene.musicGain), (0...2).contains(scene.sourceGain),
              (0...2).contains(scene.voiceGain), scene.durationFrames > 0, scene.pauseFrames >= 0 else {
            throw VideoError.invalid("混音镜头速度、音量或时长无效")
        }
        if !scene.muted, scene.voiceGain > 0, let voice = scene.voice, voice.durationFrames > 0 {
            guard voice.durationFrames <= scene.durationFrames else { throw VideoError.review("实际配音超出镜头，不能通过混音截断句尾") }
        }
    }

    private static func envelope(scene: Scene, gain requested: Double, length: Double, offset: Double, fps: Int) -> [MusicGainSegment] {
        let gain = scene.muted ? 0 : requested
        guard !scene.muted, scene.voiceGain > 0, let voice = scene.voice, voice.durationFrames > 0 else {
            return [.init(startSeconds: offset, endSeconds: offset + length, startGain: gain, endGain: gain)]
        }
        let voiceEnd = min(length, Double(voice.durationFrames) / scene.speed / Double(fps))
        let releaseEnd = min(length, voiceEnd + 0.15)
        var result: [MusicGainSegment] = [.init(startSeconds: offset, endSeconds: offset + voiceEnd, startGain: gain * 0.3, endGain: gain * 0.3)]
        if releaseEnd > voiceEnd { result.append(.init(startSeconds: offset + voiceEnd, endSeconds: offset + releaseEnd, startGain: gain * 0.3, endGain: gain)) }
        if length > releaseEnd { result.append(.init(startSeconds: offset + releaseEnd, endSeconds: offset + length, startGain: gain, endGain: gain)) }
        return result
    }
}
