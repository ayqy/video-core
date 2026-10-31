import Foundation

/// A real image texture follows stage-space route centerlines. Width is a
/// fraction of the full output width, including on a portrait stage.
public struct LayerTextureStroke: Codable, Equatable, Sendable {
    public var points: [StoryPoint]
    public var width: Double

    public init(points: [StoryPoint], width: Double) { self.points=points;self.width=width }

    private enum CodingKeys: String, CodingKey, CaseIterable { case points, width }
    public init(from decoder: Decoder) throws {
        try TexturePathKey.validate(decoder,allowed:CodingKeys.allCases.map(\.rawValue))
        let c=try decoder.container(keyedBy:CodingKeys.self)
        points=try c.decode([TexturePathPoint].self,forKey:.points).map(\.value)
        width=try c.decode(Double.self,forKey:.width)
        try validate()
    }
    public func validate() throws {
        guard (2...32).contains(points.count),width.isFinite,(0.01...0.2).contains(width) else {
            throw VideoError.invalid("纹理路线须有2—32个舞台点，宽度须为画幅宽的0.01—0.2")
        }
        for point in points { try point.validate() }
        guard zip(points,points.dropFirst()).allSatisfy({hypot($0.x-$1.x,$0.y-$1.y)>0.0000001}) else {
            throw VideoError.invalid("纹理路线不能含重复的相邻点")
        }
    }
}

public struct LayerTexturedPath: Codable, Equatable, Sendable {
    public var version: Int
    public var paths: [LayerTextureStroke]

    public init(version: Int=1, paths: [LayerTextureStroke]) { self.version=version;self.paths=paths }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, paths }
    public init(from decoder: Decoder) throws {
        try TexturePathKey.validate(decoder,allowed:CodingKeys.allCases.map(\.rawValue))
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version)
        paths=try c.decode([LayerTextureStroke].self,forKey:.paths)
        try validate()
    }
    public func validate() throws {
        guard version==1,(1...8).contains(paths.count) else {
            throw VideoError.invalid("纹理路线仅支持版本1和1—8条支路")
        }
        for path in paths { try path.validate() }
    }
}

private struct TexturePathPoint: Decodable {
    let value: StoryPoint
    private enum CodingKeys: String, CodingKey { case x,y }
    init(from decoder: Decoder) throws {
        try TexturePathKey.validate(decoder,allowed:["x","y"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        value=StoryPoint(x:try c.decode(Double.self,forKey:.x),y:try c.decode(Double.self,forKey:.y))
        try value.validate()
    }
}

private struct TexturePathKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue=stringValue }
    init?(intValue: Int) { return nil }
    static func validate(_ decoder: Decoder, allowed: [String]) throws {
        let c=try decoder.container(keyedBy:Self.self)
        guard Set(c.allKeys.map(\.stringValue)).isSubset(of:Set(allowed)) else {
            throw VideoError.invalid("纹理路线包含当前版本不支持的字段")
        }
    }
}
