import Foundation

/// A Host-owned view of a continuous source simulation. A shot changes how long
/// events are shown, never the rules, seed, decisions or settlement history.
public struct SimulationPresentation: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var sourceStartFrame: Int
    public var sourceEndFrame: Int
    public var presentationFrames: Int
    public var presentationOffsetFrames: Int

    public init(sourceStartFrame: Int, sourceEndFrame: Int, presentationFrames: Int,
                presentationOffsetFrames: Int = 0) {
        self.sourceStartFrame=sourceStartFrame; self.sourceEndFrame=sourceEndFrame
        self.presentationFrames=presentationFrames; self.presentationOffsetFrames=presentationOffsetFrames
    }
    public func validate(durationFrames: Int) throws {
        guard version == 1, (0...216000).contains(sourceStartFrame),
              sourceEndFrame > sourceStartFrame, sourceEndFrame <= 216001,
              (1...54000).contains(presentationFrames), (1...54000).contains(durationFrames),
              presentationFrames > 1 || sourceEndFrame-sourceStartFrame == 1,
              presentationOffsetFrames >= 0, presentationOffsetFrames < presentationFrames,
              durationFrames <= presentationFrames-presentationOffsetFrames else {
            throw VideoError.invalid("仿真分镜须有有限源窗口、展示时长及连续展示偏移")
        }
    }
    public func sourceFrame(atSceneFrame frame: Int, durationFrames: Int) throws -> Int {
        try validate(durationFrames:durationFrames)
        guard (0...432000).contains(frame) else { throw VideoError.invalid("仿真展示帧超出有限范围") }
        let position=presentationOffsetFrames+min(frame,durationFrames-1)
        // Integer endpoint interpolation is deterministic across architectures.
        // Widen before multiplying so the mapping also remains explicit and
        // deterministic if the Host is built for a narrower integer platform.
        return sourceStartFrame + Int(Int64(position)*Int64(sourceEndFrame-sourceStartFrame-1)/Int64(max(1,presentationFrames-1)))
    }
    public func sliced(from start: Int, to end: Int, durationFrames: Int) throws -> SimulationPresentation {
        try validate(durationFrames:durationFrames)
        guard start >= 0, end > start, end <= durationFrames else { throw VideoError.invalid("仿真分镜拆分超出当前展示范围") }
        var value=self; value.presentationOffsetFrames += start
        try value.validate(durationFrames:end-start)
        return value
    }
    /// Reframe a visible slice to match an explicitly requested new narration
    /// length. The first and last visible source frames remain unchanged.
    public func retimed(to newDurationFrames: Int, durationFrames: Int) throws -> SimulationPresentation {
        try validate(durationFrames:durationFrames)
        let first=try sourceFrame(atSceneFrame:0,durationFrames:durationFrames)
        let last=try sourceFrame(atSceneFrame:durationFrames-1,durationFrames:durationFrames)
        let value=SimulationPresentation(sourceStartFrame:first,sourceEndFrame:last+1,presentationFrames:newDurationFrames)
        try value.validate(durationFrames:newDurationFrames)
        return value
    }
}

public extension Scene {
    func renderSimulationSourceFrame(atTimelineFrame frame: Int) throws -> Int {
        let mapped=renderSourceFrame(atTimelineFrame:frame)
        guard let presentation=simulationPresentation else { return mapped }
        guard kind == .simulation else { throw VideoError.invalid("仿真展示窗口只能用于规则镜头") }
        return try presentation.sourceFrame(atSceneFrame:mapped,durationFrames:durationFrames)
    }
}
