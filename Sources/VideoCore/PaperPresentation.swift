import Foundation

/// An authored paper canvas for ordinary teaching shots. Raster artwork remains
/// an imported image layer; selecting this canvas does not generate artwork.
public struct PaperPresentation: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable { case cover, explanation }
    public var version = 1
    public var layout: Layout
    public var paperColor: String
    public var inkColor: String

    public init(layout: Layout = .explanation, paperColor: String = "FFF9EF", inkColor: String = "243638") {
        self.layout = layout; self.paperColor = paperColor; self.inkColor = inkColor
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case version, layout, paperColor, inkColor }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: PaperPresentationKey.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw VideoError.invalid("纸面呈现包含当前版本不支持的字段")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        layout = try c.decode(Layout.self, forKey: .layout)
        paperColor = try c.decode(String.self, forKey: .paperColor)
        inkColor = try c.decode(String.self, forKey: .inkColor)
        try validate()
    }

    public func validate() throws {
        func color(_ value: String) -> Bool {
            value.utf8.count == 6 && value.range(of: "^[A-Fa-f0-9]{6}$", options: .regularExpression) != nil
        }
        guard version == 1, color(paperColor), color(inkColor) else {
            throw VideoError.invalid("纸面呈现版本或六位RGB颜色无效")
        }
    }
}

private struct PaperPresentationKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
