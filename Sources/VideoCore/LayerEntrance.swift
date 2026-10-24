import Foundation

/// A bounded image/layer entrance, sampled on the original scene source axis.
/// revealLeft reveals an existing raster rectangle; it is not stroke synthesis.
public struct LayerEntrance: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case fade, revealLeft }
    public var version = 1
    public var kind: Kind
    public var startFrame: Int
    public var endFrame: Int
    public var sourceOffsetFrames: Int?

    public init(kind: Kind = .fade, startFrame: Int = 0, endFrame: Int = 15, sourceOffsetFrames: Int? = nil) {
        self.kind = kind; self.startFrame = startFrame; self.endFrame = endFrame; self.sourceOffsetFrames = sourceOffsetFrames
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case version, kind, startFrame, endFrame, sourceOffsetFrames }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: LayerEntranceKey.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw VideoError.invalid("图层入场包含当前版本不支持的字段")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        kind = try c.decode(Kind.self, forKey: .kind)
        startFrame = try c.decode(Int.self, forKey: .startFrame)
        endFrame = try c.decode(Int.self, forKey: .endFrame)
        sourceOffsetFrames = try c.decodeIfPresent(Int.self, forKey: .sourceOffsetFrames)
        try validateDomain()
    }

    private func validateDomain() throws {
        guard version == 1, (0...54000).contains(startFrame), endFrame > startFrame,
              endFrame <= 54000, (0...54000).contains(sourceOffsetFrames ?? 0) else {
            throw VideoError.invalid("图层入场版本、源帧区间或源窗口无效")
        }
    }

    public func validate(endFrame layerEndFrame: Int) throws {
        try validateDomain()
        // The reveal interval can extend outside a sliced shot: retaining the
        // full interval is what makes an in-progress reveal survive splitting.
        guard layerEndFrame > 0, layerEndFrame <= 54000 - (sourceOffsetFrames ?? 0) else {
            throw VideoError.invalid("图层入场的可见源窗口超出范围")
        }
    }

    public func sourceFrame(at sceneSourceFrame: Int) throws -> Int {
        try validateDomain()
        let offset = sourceOffsetFrames ?? 0
        guard (0...54000).contains(sceneSourceFrame), sceneSourceFrame <= 54000 - offset else {
            throw VideoError.invalid("图层入场采样帧超出范围")
        }
        return offset + sceneSourceFrame
    }

    /// The caller holds the final scene source frame during an output pause.
    /// Layer visibility/layout and this progress must use the same held frame.
    public func progress(at sceneSourceFrame: Int) throws -> Double {
        let frame = try sourceFrame(at: sceneSourceFrame)
        if frame <= startFrame { return 0 }
        if frame >= endFrame { return 1 }
        return Double(frame - startFrame) / Double(endFrame - startFrame)
    }

    public func advancingSource(by frames: Int) throws -> Self {
        let next = try sourceFrame(at: frames)
        var copy = self; copy.sourceOffsetFrames = next; return copy
    }
}

private struct LayerEntranceKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
