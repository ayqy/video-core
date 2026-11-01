import Foundation

/// Explicit ordinary-media canvas. Nil on Scene preserves the original Host layout.
/// This declaration changes no source bytes, source window or audio mapping.
public struct MediaPresentation: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable { case fullFrame }
    public var version = 1
    public var layout: Layout
    public var backgroundColor: String

    public init(layout: Layout = .fullFrame, backgroundColor: String = "FFFFFF") {
        self.layout = layout; self.backgroundColor = backgroundColor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, layout, backgroundColor }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: MediaPresentationKey.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw VideoError.invalid("媒体纯画面呈现包含当前版本不支持的字段")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        layout = try c.decode(Layout.self, forKey: .layout)
        backgroundColor = try c.decode(String.self, forKey: .backgroundColor)
        try validate()
    }

    public func validate() throws {
        guard version == 1, backgroundColor.utf8.count == 6,
              backgroundColor.range(of: "^[A-Fa-f0-9]{6}$", options: .regularExpression) != nil else {
            throw VideoError.invalid("媒体纯画面呈现版本或六位RGB颜色无效")
        }
    }
}

private struct MediaPresentationKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
