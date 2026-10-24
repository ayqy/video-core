import Foundation

/// A source-space window, measured from the top-left of the actual image or video.
/// It changes neither the stored media nor its audio/time mapping.
public struct MediaFraming: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x=x; self.y=y; self.width=width; self.height=height
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width >= 0.01, height >= 0.01,
              x <= 1, y <= 1, x+width <= 1.0.nextUp, y+height <= 1.0.nextUp else {
            throw VideoError.invalid("局部取景须在源画面内，宽高至少为源画面的1%")
        }
    }

    private enum CodingKeys: String, CodingKey { case x,y,width,height }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue=stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let raw=try decoder.container(keyedBy:AnyKey.self)
        guard raw.allKeys.allSatisfy({CodingKeys(stringValue:$0.stringValue) != nil}) else {
            throw VideoError.invalid("局部取景包含未知字段")
        }
        let c=try decoder.container(keyedBy:CodingKeys.self)
        x=try c.decode(Double.self,forKey:.x); y=try c.decode(Double.self,forKey:.y)
        width=try c.decode(Double.self,forKey:.width); height=try c.decode(Double.self,forKey:.height)
        try validate()
    }
}
