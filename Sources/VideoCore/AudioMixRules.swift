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
