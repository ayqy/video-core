import Foundation

/// Author-supplied data and displayed code; never a script interpreter or an
/// assertion that measurements/code execution actually took place.
public struct DataPresentation: Codable, Equatable, Sendable {
    public var version = 1
    public var sourceOffsetFrames: Int?
    public var chart: DataChart?
    public var code: CodePresentation?
    public init(chart: DataChart? = nil, code: CodePresentation? = nil, sourceOffsetFrames: Int? = nil) {
        self.chart = chart; self.code = code; self.sourceOffsetFrames = sourceOffsetFrames
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case version, sourceOffsetFrames, chart, code }
    public init(from decoder: Decoder) throws {
        try DataPresentationCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        sourceOffsetFrames = try c.decodeIfPresent(Int.self, forKey: .sourceOffsetFrames)
        chart = try c.decodeIfPresent(DataChart.self, forKey: .chart)
        code = try c.decodeIfPresent(CodePresentation.self, forKey: .code)
    }
    public func validate(kind: SceneLayer.Kind, endFrame: Int) throws {
        let offset = sourceOffsetFrames ?? 0
        guard version == 1, (0...54000).contains(offset), endFrame > 0,
              endFrame <= 54000 - offset else { throw VideoError.invalid("数据展示版本、源窗口或帧数无效") }
        switch kind {
        case .chart:
            guard let chart, code == nil else { throw VideoError.invalid("图表层须且只能绑定图表数据") }
            try chart.validate()
        case .code:
            guard let code, chart == nil else { throw VideoError.invalid("代码层须且只能绑定展示代码") }
            try code.validate()
        default: throw VideoError.invalid("此元素类型不接受数据展示")
        }
    }
    public func sourceFrame(at sceneSourceFrame: Int) throws -> Int {
        let offset = sourceOffsetFrames ?? 0
        guard (0...54000).contains(offset), (0...54000).contains(sceneSourceFrame),
              sceneSourceFrame <= 54000 - offset else { throw VideoError.invalid("数据展示采样帧超出范围") }
        return offset + sceneSourceFrame
    }
    public func advancingSource(by frames: Int) throws -> Self {
        let next = try sourceFrame(at: frames)
        var copy = self; copy.sourceOffsetFrames = next; return copy
    }
}

public struct DataChart: Codable, Equatable, Sendable {
    public var title: String
    public var axisLabel: String
    public var minimum: Double
    public var maximum: Double
    public var series: [DataSeries]
    public init(title: String, axisLabel: String, minimum: Double, maximum: Double, series: [DataSeries]) {
        self.title = title; self.axisLabel = axisLabel; self.minimum = minimum; self.maximum = maximum; self.series = series
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case title, axisLabel, minimum, maximum, series }
    public init(from decoder: Decoder) throws {
        try DataPresentationCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title); axisLabel = try c.decode(String.self, forKey: .axisLabel)
        minimum = try c.decode(Double.self, forKey: .minimum); maximum = try c.decode(Double.self, forKey: .maximum)
        series = try c.decode([DataSeries].self, forKey: .series)
    }
    public func validate() throws {
        guard DataPresentationCoding.text(title, limit: 64), DataPresentationCoding.text(axisLabel, limit: 20),
              minimum.isFinite, maximum.isFinite, abs(minimum) <= 1e9, abs(maximum) <= 1e9,
              minimum < maximum, maximum - minimum >= 1e-6,
              (1...8).contains(series.count), Set(series.map(\.id)).count == series.count else {
            throw VideoError.invalid("图表标题、坐标范围或系列无效；最多8个不同系列")
        }
        for item in series {
            try item.validate()
            guard item.keyframes.allSatisfy({ (minimum...maximum).contains($0.value) }) else {
                throw VideoError.invalid("图表数值超出所声明坐标范围，不会裁掉数据冒充正确图形")
            }
        }
    }
    public func values(at frame: Int) throws -> [Double] {
        try validate(); return try series.map { try $0.value(at: frame) }
    }
}

public struct DataSeries: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var color: String
    public var keyframes: [DataValueKeyframe]
    public init(id: String, label: String, color: String, keyframes: [DataValueKeyframe]) {
        self.id = id; self.label = label; self.color = color; self.keyframes = keyframes
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case id, label, color, keyframes }
    public init(from decoder: Decoder) throws {
        try DataPresentationCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); label = try c.decode(String.self, forKey: .label)
        color = try c.decode(String.self, forKey: .color); keyframes = try c.decode([DataValueKeyframe].self, forKey: .keyframes)
    }
    public func validate() throws {
        guard DataPresentationCoding.text(id, limit: 64), DataPresentationCoding.text(label, limit: 20),
              color.range(of: "^[A-Fa-f0-9]{6}$", options: .regularExpression) != nil,
              (1...128).contains(keyframes.count) else { throw VideoError.invalid("图表系列名称、颜色或数值关键帧无效") }
        var previous = -1
        for key in keyframes {
            guard (0...54000).contains(key.frame), key.frame > previous,
                  key.value.isFinite, abs(key.value) <= 1e9 else {
                throw VideoError.invalid("图表帧须有序且不重复，数值须有限并在正负十亿内")
            }
            previous = key.frame
        }
    }
    public func value(at frame: Int) throws -> Double {
        try validate()
        guard (0...54000).contains(frame) else { throw VideoError.invalid("图表采样帧超出范围") }
        let first = keyframes[0]
        if frame <= first.frame { return first.value }
        guard let index = keyframes.firstIndex(where: { $0.frame >= frame }) else { return keyframes[keyframes.count-1].value }
        let a = keyframes[index-1], b = keyframes[index]
        let amount = Double(frame-a.frame) / Double(b.frame-a.frame)
        return a.value + (b.value-a.value)*amount
    }
}

public struct DataValueKeyframe: Codable, Equatable, Sendable {
    public var frame: Int
    public var value: Double
    public init(frame: Int, value: Double) { self.frame = frame; self.value = value }
    enum CodingKeys: String, CodingKey, CaseIterable { case frame, value }
    public init(from decoder: Decoder) throws {
        try DataPresentationCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Int.self, forKey: .frame); value = try c.decode(Double.self, forKey: .value)
    }
}

public struct CodePresentation: Codable, Equatable, Sendable {
    public var title: String
    public var lines: [String]
    public var highlights: [CodeHighlight]
    public init(title: String, lines: [String], highlights: [CodeHighlight] = []) {
        self.title = title; self.lines = lines; self.highlights = highlights
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case title, lines, highlights }
    public init(from decoder: Decoder) throws {
        try DataPresentationCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title); lines = try c.decode([String].self, forKey: .lines)
        highlights = try c.decode([CodeHighlight].self, forKey: .highlights)
    }
    public func validate() throws {
        guard DataPresentationCoding.text(title, limit: 64), (1...16).contains(lines.count),
              lines.allSatisfy({ DataPresentationCoding.text($0, limit: 120, allowEmpty: true) }),
              lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), highlights.count <= 64 else {
            throw VideoError.invalid("展示代码最多16行、每行120字；仅展示而不执行")
        }
        var end = 0
        for highlight in highlights {
            guard highlight.startFrame >= end, highlight.startFrame >= 0,
                  highlight.endFrame > highlight.startFrame, highlight.endFrame <= 54000,
                  lines.indices.contains(highlight.line) else { throw VideoError.invalid("代码高亮须有序不重叠，并绑定实际行和有效帧区间") }
            end = highlight.endFrame
        }
    }
    public func highlightedLine(at frame: Int) throws -> Int? {
        try validate()
        guard (0...54000).contains(frame) else { throw VideoError.invalid("代码展示采样帧超出范围") }
        return highlights.first(where: { $0.startFrame <= frame && $0.endFrame > frame })?.line
    }
}

public struct CodeHighlight: Codable, Equatable, Sendable {
    public var startFrame: Int
    public var endFrame: Int
    /// Zero based in the IR; Mac displays one-based line numbers.
    public var line: Int
    public init(startFrame: Int, endFrame: Int, line: Int) { self.startFrame = startFrame; self.endFrame = endFrame; self.line = line }
    enum CodingKeys: String, CodingKey, CaseIterable { case startFrame, endFrame, line }
    public init(from decoder: Decoder) throws {
        try DataPresentationCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startFrame = try c.decode(Int.self, forKey: .startFrame); endFrame = try c.decode(Int.self, forKey: .endFrame)
        line = try c.decode(Int.self, forKey: .line)
    }
}

private enum DataPresentationCoding {
    struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: Decoder, _ allowed: [String]) throws {
        let fields = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        guard Set(fields).isSubset(of: Set(allowed)) else { throw VideoError.invalid("数据展示包含当前版本不支持的字段") }
    }
    static func text(_ value: String, limit: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.trimmingCharacters(in: .whitespaces).isEmpty) && value.count <= limit &&
        value.utf8.count <= limit*4 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
