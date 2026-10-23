import Foundation

public struct MusicGainSegment: Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var startGain: Double
    public var endGain: Double
}

/// A deterministic music envelope shared by rendering and UI descriptions.
/// Duck only the audible, real voice interval. A muted scene is silent on all tracks.
public enum AudioMixRules {
    public static func musicEnvelope(scenes: [Scene], fps: Int) throws -> [MusicGainSegment] {
        guard (1...120).contains(fps) else { throw VideoError.invalid("混音帧率无效") }
        var cursor = 0.0
        var result: [MusicGainSegment] = []
        for scene in scenes {
            guard scene.speed.isFinite, (0.25...4).contains(scene.speed), (0...2).contains(scene.musicGain), (0...2).contains(scene.voiceGain), scene.durationFrames > 0, scene.pauseFrames >= 0 else { throw VideoError.invalid("混音镜头速度、音量或时长无效") }
            let length = Double(scene.timelineFrames) / Double(fps)
            let gain = scene.muted ? 0 : scene.musicGain
            if !scene.muted, scene.voiceGain > 0, let voice = scene.voice, voice.durationFrames > 0 {
                guard voice.durationFrames <= scene.durationFrames else { throw VideoError.review("实际配音超出镜头，不能通过混音截断句尾") }
                let voiceEnd = min(length, Double(voice.durationFrames) / scene.speed / Double(fps))
                let releaseEnd = min(length, voiceEnd + 0.15)
                result.append(.init(startSeconds: cursor, endSeconds: cursor + voiceEnd, startGain: gain * 0.3, endGain: gain * 0.3))
                if releaseEnd > voiceEnd { result.append(.init(startSeconds: cursor + voiceEnd, endSeconds: cursor + releaseEnd, startGain: gain * 0.3, endGain: gain)) }
                if length > releaseEnd { result.append(.init(startSeconds: cursor + releaseEnd, endSeconds: cursor + length, startGain: gain, endGain: gain)) }
            } else {
                result.append(.init(startSeconds: cursor, endSeconds: cursor + length, startGain: gain, endGain: gain))
            }
            cursor += length
        }
        return result
    }
}
