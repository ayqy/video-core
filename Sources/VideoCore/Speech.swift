import Foundation

/// The dictionary is frozen with the scene, rather than resolved from mutable global settings.
public struct SpeechTerm: Codable, Equatable, Sendable, Identifiable {
    public var id: String { term }
    public var term: String
    public var pronunciation: String
    public init(_ term: String, _ pronunciation: String) { self.term = term; self.pronunciation = pronunciation }
}

public struct SpeechMapping: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { sourceStart }
    /// UTF-16 offsets, matching NSString and Apple speech marker ranges.
    public var sourceStart: Int
    public var sourceLength: Int
    public var normalizedStart: Int
    public var normalizedLength: Int
    public var kind: String
    public init(sourceStart: Int, sourceLength: Int, normalizedStart: Int, normalizedLength: Int, kind: String) {
        self.sourceStart = sourceStart; self.sourceLength = sourceLength
        self.normalizedStart = normalizedStart; self.normalizedLength = normalizedLength; self.kind = kind
    }
}

public struct SpeechPlan: Codable, Equatable, Sendable {
    public var source: String
    public var normalized: String
    public var dictionary: [SpeechTerm]
    public var mappings: [SpeechMapping]
    public var voiceIdentifier: String?
    public var rate: Double
    public var confirmed: Bool
    public var notes: [String]
    public init(source: String, normalized: String, dictionary: [SpeechTerm] = [], mappings: [SpeechMapping] = [], voiceIdentifier: String? = nil, rate: Double = 0.5, confirmed: Bool = false, notes: [String] = []) {
        self.source = source; self.normalized = normalized; self.dictionary = dictionary
        self.mappings = mappings; self.voiceIdentifier = voiceIdentifier; self.rate = rate
        self.confirmed = confirmed; self.notes = notes
    }
    public func validate() throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf16.count <= 4000, normalized.utf16.count <= 8000,
              rate.isFinite, (0.2...0.65).contains(rate), dictionary.count <= 200 else {
            throw VideoError.invalid("原文/规范稿不能为空或过长，语速须在0.2—0.65之间")
        }
        guard Set(dictionary.map(\.term)).count == dictionary.count,
              dictionary.allSatisfy({ !$0.term.isEmpty && !$0.pronunciation.isEmpty && $0.term.utf16.count <= 100 && $0.pronunciation.utf16.count <= 200 }) else {
            throw VideoError.invalid("术语词典包含重复、空项或过长内容")
        }
        let sourceCount = source.utf16.count, normalizedCount = normalized.utf16.count
        var previousSource = 0, previousNormalized = 0
        for m in mappings {
            // Offsets are untrusted Codable Int values. Bound each start before
            // subtracting, so even Int.max lengths are rejected without addition.
            guard m.sourceStart >= previousSource, m.sourceStart <= sourceCount,
                  m.sourceLength > 0, m.sourceLength <= sourceCount - m.sourceStart,
                  m.normalizedStart >= previousNormalized, m.normalizedStart <= normalizedCount,
                  m.normalizedLength > 0, m.normalizedLength <= normalizedCount - m.normalizedStart else {
                throw VideoError.invalid("TN映射越界或顺序错误，请重新规范化")
            }
            previousSource = m.sourceStart + m.sourceLength
            previousNormalized = m.normalizedStart + m.normalizedLength
        }
    }
    public func manuallyRevised(_ text: String) -> SpeechPlan {
        var p = self; p.normalized = text; p.confirmed = false
        p.mappings = text.isEmpty || source.isEmpty ? [] : [SpeechMapping(sourceStart: 0, sourceLength: source.utf16.count, normalizedStart: 0, normalizedLength: text.utf16.count, kind: "manual_document")]
        p.notes = ["已人工修改规范稿，原自动词级映射失效；须重新试听并校正字幕。"]
        return p
    }
}

public enum ChineseSpeech {
    private static let digits = Array("零一二三四五六七八九")
    public static func number(_ input: String, digitByDigit: Bool = false) -> String {
        var input = input; var sign = ""
        if input.hasPrefix("-") { sign = "负"; input.removeFirst() }
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return sign + input }
        let raw = String(parts[0])
        func readDigits(_ value: String) -> String { value.map { c in c.wholeNumberValue.map { String(digits[$0]) } ?? String(c) }.joined() }
        let whole: String
        if digitByDigit || raw.count > 12 || (raw.count > 1 && raw.hasPrefix("0")) { whole = readDigits(raw) }
        else if let n = Int64(raw) { whole = integer(n) }
        else { whole = readDigits(raw) }
        return sign + whole + (parts.count == 2 ? "点" + readDigits(String(parts[1])) : "")
    }
    private static func integer(_ n: Int64) -> String {
        if n == 0 { return "零" }
        func group(_ value: Int64) -> String {
            let units = ["", "十", "百", "千"]; var result = "", pendingZero = false
            for power in stride(from: 3, through: 0, by: -1) {
                let divisor = [Int64(1), 10, 100, 1000][power]
                let d = Int(value / divisor % 10)
                if d == 0 { if !result.isEmpty { pendingZero = true }; continue }
                if pendingZero { result += "零"; pendingZero = false }
                result += String(digits[d]) + units[power]
            }
            return result
        }
        var output = "", pendingZero = false
        let sections: [(Int64, String)] = [(100_000_000, "亿"), (10_000, "万"), (1, "")]
        var remaining = n
        for (unit, label) in sections {
            let value = remaining / unit; remaining %= unit
            if value == 0 { if !output.isEmpty && remaining > 0 { pendingZero = true }; continue }
            if !output.isEmpty && (pendingZero || value < 1000) { output += "零" }
            output += group(value) + label; pendingZero = false
        }
        if output.hasPrefix("一十") { output.removeFirst() }
        return output
    }
    public static func normalize(_ source: String, dictionary: [SpeechTerm] = []) throws -> SpeechPlan {
        struct Candidate { var range: NSRange; var text: String; var kind: String; var priority: Int }
        let ns = source as NSString; var candidates: [Candidate] = []
        func matches(_ pattern: String, kind: String, priority: Int, transform: (String) -> String?) throws {
            for match in try NSRegularExpression(pattern: pattern).matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let original = ns.substring(with: match.range)
                if let replacement = transform(original) { candidates.append(Candidate(range: match.range, text: replacement, kind: kind, priority: priority)) }
            }
        }
        for term in dictionary where !term.term.isEmpty {
            try matches(NSRegularExpression.escapedPattern(for: term.term), kind: "dictionary", priority: 0) { _ in term.pronunciation }
        }
        try matches(#"(?<!\d)\d{4}[-/]\d{1,2}[-/]\d{1,2}(?!\d)"#, kind: "date", priority: 1) { value in
            let pieces = value.split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
            guard pieces.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
            guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
            return number(String(pieces[0]), digitByDigit: true) + "年" + number(String(pieces[1])) + "月" + number(String(pieces[2])) + "日"
        }
        try matches(#"(?:CNY|RMB|USD|EUR|[¥￥$€])\s*-?\d+(?:\.\d+)?"#, kind: "currency", priority: 2) { value in
            let currency = value.hasPrefix("USD") || value.hasPrefix("$") ? "美元" : value.hasPrefix("EUR") || value.hasPrefix("€") ? "欧元" : "元"
            let numberText = value.filter { $0.isNumber || $0 == "." || $0 == "-" }
            return number(numberText) + currency
        }
        try matches(#"-?\d+(?:\.\d+)?[%％]"#, kind: "percentage", priority: 2) { "百分之" + number(String($0.dropLast())) }
        try matches(#"-?\d+(?:\.\d+)?"#, kind: "number", priority: 5) { number($0) }
        try matches(#"(?<![A-Za-z])[A-Z]{2,8}(?![A-Za-z])"#, kind: "acronym", priority: 6) { $0.map(String.init).joined(separator: " ") }
        candidates.sort { a, b in a.range.location == b.range.location ? (a.priority == b.priority ? a.range.length > b.range.length : a.priority < b.priority) : a.range.location < b.range.location }
        var accepted: [Candidate] = []
        // Priority determines overlapping rules, so a term beginning inside a date still wins.
        for c in candidates.sorted(by: { $0.priority == $1.priority ? ($0.range.length == $1.range.length ? $0.range.location < $1.range.location : $0.range.length > $1.range.length) : $0.priority < $1.priority }) {
            if !accepted.contains(where: { NSIntersectionRange($0.range, c.range).length > 0 }) { accepted.append(c) }
        }
        accepted.sort { $0.range.location < $1.range.location }
        var output = "", mappings: [SpeechMapping] = [], cursor = 0
        func append(_ text: String, range: NSRange, kind: String) {
            guard !text.isEmpty else { return }
            mappings.append(SpeechMapping(sourceStart: range.location, sourceLength: range.length, normalizedStart: output.utf16.count, normalizedLength: text.utf16.count, kind: kind)); output += text
        }
        for c in accepted {
            if c.range.location > cursor { let range = NSRange(location: cursor, length: c.range.location - cursor); append(ns.substring(with: range), range: range, kind: "unchanged") }
            append(c.text, range: c.range, kind: c.kind); cursor = NSMaxRange(c.range)
        }
        if cursor < ns.length { let range = NSRange(location: cursor, length: ns.length - cursor); append(ns.substring(with: range), range: range, kind: "unchanged") }
        let plan = SpeechPlan(source: source, normalized: output, dictionary: dictionary, mappings: mappings, notes: ["日期、币种、数字与缩写为可审校读法；品牌、多音字、电话号码及版本号请用术语词典覆盖。字幕保留原文，规范稿仅供配音。"])
        try plan.validate(); return plan
    }
}

public enum SpeechRules {
    /// Only the ordered, visible text and its timing change a subtitle rehearsal.
    /// IDs, alignment provenance and approval flags are editorial metadata.
    public static func captionContentDigest(_ captions: [Caption]) throws -> String {
        struct Content: Codable { var text: String; var start: Int; var end: Int }
        return try Codec.digest(captions.map { Content(text: $0.text, start: $0.startFrame, end: $0.endFrame) })
    }
    /// Compare actual audio inputs, not approval or mapping metadata. A draft
    /// pronunciation, voice, rate or dictionary cannot reuse a different take.
    public static func matchingVoice(in scene: Scene, plan: SpeechPlan) throws -> VoiceTake? {
        guard let take = scene.voice, take.textDigest == (try digest(scene)) else { return nil }
        var candidate = scene; candidate.speechPlan = plan
        return try digest(candidate) == take.textDigest ? take : nil
    }
    /// Save captions without manufacturing a fresh recording or a listening approval.
    /// The caller still applies the scene through its normal editor/permission path.
    public static func captionDraft(_ captions: [Caption], for scene: Scene) throws -> Scene {
        try validateCaptions(captions, durationFrames: scene.durationFrames)
        guard var take = scene.voice, take.textDigest == (try digest(scene)) else {
            throw VideoError.review("原配音与当前读法不匹配，请先重新生成或绑定真实音轨")
        }
        var result = scene
        take.listened = false; result.voice = take
        result.captions = captions.map { original in var cue = original; cue.confirmed = false; return cue }
        return result
    }
    public static func digest(_ scene: Scene) throws -> String {
        guard let plan = scene.speechPlan else { return try Codec.digest(scene.narration) }
        try plan.validate()
        guard plan.source == scene.narration else { throw VideoError.review("配音原文已变化，请更新规范稿和术语词典") }
        // Confirmation and editorial mapping notes do not alter the actual synthesized audio.
        struct AudioInput: Codable { var source: String; var normalized: String; var dictionary: [SpeechTerm]; var voice: String?; var rate: Double }
        return try Codec.digest(AudioInput(source: plan.source, normalized: plan.normalized, dictionary: plan.dictionary, voice: plan.voiceIdentifier, rate: plan.rate))
    }
    public static func captions(_ plan: SpeechPlan, durationFrames: Int) throws -> [Caption] {
        try plan.validate(); guard durationFrames > 0 else { throw VideoError.invalid("真实音频时长必须大于零") }
        let ns = plan.source as NSString
        let ranges = try NSRegularExpression(pattern: #"[^。！？!?；;\n]+[。！？!?；;]?"#).matches(in: plan.source, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard !ranges.isEmpty, ranges.count <= durationFrames else { throw VideoError.invalid("句段数量超出可用帧数，请合并字幕") }
        let total = ranges.reduce(0) { $0 + $1.length }; var cursor = 0, weight = 0
        return ranges.enumerated().map { index, range in
            weight += range.length
            let end = index == ranges.count - 1 ? durationFrames : min(durationFrames - (ranges.count - index - 1), max(cursor + 1, Int((Double(weight) / Double(total) * Double(durationFrames)).rounded())))
            defer { cursor = end }
            return Caption(text: ns.substring(with: range).trimmingCharacters(in: .whitespaces), startFrame: cursor, endFrame: end, alignment: "estimated_sentence_no_word_timestamps", confirmed: false)
        }
    }
    public static func validateCaptions(_ captions: [Caption], durationFrames: Int) throws {
        guard Set(captions.map(\.id)).count == captions.count, captions.allSatisfy({ !$0.id.isEmpty }) else {
            throw VideoError.invalid("同一镜头的字幕标识缺失或重复，请保留每段独立标识")
        }
        var previous = 0
        for caption in captions.sorted(by: { $0.startFrame < $1.startFrame }) {
            guard !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  caption.startFrame >= previous, caption.endFrame > caption.startFrame,
                  caption.endFrame <= durationFrames else { throw VideoError.invalid("字幕内容为空、相互重叠或超出真实音轨；请按试听调整") }
            previous = caption.endFrame
        }
    }
}

public struct AudioEnvelopePoint: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int; public var startSeconds: Double; public var durationSeconds: Double; public var peak: Double; public var rms: Double
    public init(index: Int, startSeconds: Double, durationSeconds: Double, peak: Double, rms: Double) { self.index = index; self.startSeconds = startSeconds; self.durationSeconds = durationSeconds; self.peak = peak; self.rms = rms }
}
public struct AudioDiagnostics: Codable, Equatable, Sendable {
    public var duration: Double; public var sampleRate: Double; public var channels: Int
    public var peakDBFS: Double; public var rmsDBFS: Double; public var clippedSamples: Int64
    public var leadingSilence: Double; public var trailingSilence: Double
    public var envelope: [AudioEnvelopePoint]
    public var loudness:LoudnessDiagnostics? = nil
    public var containerDuration:Double? = nil
    public var measurement: String { "sample_peak_and_unweighted_rms_dbfs_not_lufs" }
    public var warnings: [String] {
        var result: [String] = []
        if clippedSamples > 0 { result.append("检测到\(clippedSamples)个接近满幅采样，可能削波；请降低原音量并重新生成/混音、试听。") }
        if rmsDBFS > -10 { result.append("未加权平均电平高于-10 dBFS，可能过响；此检测不是LUFS测量。") }
        if peakDBFS < -50 { result.append("音轨接近静音，请核对素材和分轨音量。") }
        if leadingSilence > 0.3 || trailingSilence > 0.3 { result.append("音轨存在较长首尾静音，请试听停顿与片段边界。") }
        if let loudness {
            result += loudness.violations(policy:loudness.analysisPolicy)
            if !loudness.silenceRanges.isEmpty {result.append("检测到长静音区间，请对照真实音轨核对是否为有意停顿。")}
            if let unavailable=loudness.unavailableReason {result.append("综合响度暂无有效结果："+unavailable)}
        }
        if let declared=containerDuration,duration+0.1<declared {result.append("实际解码采样短于媒体声明时长，存在截断嫌疑，请核对原件与片段边界。")}
        return result
    }
}

/// Streaming, bounded-memory inspection of interleaved PCM samples. It never normalizes source audio.
public struct AudioMeter: Sendable {
    private var sampleRate: Double; private var channels: Int; private var windowFrames: Int
    private var totalSamples: Int64 = 0, totalFrames: Int64 = 0, clips: Int64 = 0
    private var sumSquares = 0.0, peak = 0.0, windowSquares = 0.0, windowPeak = 0.0
    private var windowSamples = 0, windowStart: Int64 = 0, firstAudible: Int64?, lastAudible: Int64?
    private var points: [AudioEnvelopePoint] = []
    public init(sampleRate: Double, channels: Int, windowSeconds: Double = 0.05) throws {
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate), (1...32).contains(channels), windowSeconds.isFinite, (0.02...1).contains(windowSeconds) else { throw VideoError.invalid("音频采样率、声道或波形窗口无效") }
        self.sampleRate = sampleRate; self.channels = channels; windowFrames = max(1, Int(sampleRate * windowSeconds))
    }
    public mutating func append(_ samples: [Float]) throws {
        guard samples.count % channels == 0 else { throw VideoError.invalid("PCM音频不包含完整声道帧") }
        for frame in stride(from: 0, to: samples.count, by: channels) {
            var audible = false
            for channel in 0..<channels {
                let value = Double(samples[frame + channel]); guard value.isFinite else { throw VideoError.invalid("音频包含非有限采样") }
                let absolute = abs(value); peak = max(peak, absolute); windowPeak = max(windowPeak, absolute)
                let square = value * value; sumSquares += square; windowSquares += square
                if absolute >= 0.999 { clips += 1 }; if absolute >= pow(10, -55.0 / 20) { audible = true }
                totalSamples += 1; windowSamples += 1
            }
            if audible { if firstAudible == nil { firstAudible = totalFrames }; lastAudible = totalFrames }
            totalFrames += 1
            guard totalFrames <= Int64(sampleRate * 3600) else { throw VideoError.invalid("音频检查上限为一小时") }
            if totalFrames - windowStart >= windowFrames { flush() }
        }
    }
    private mutating func flush() {
        guard windowSamples > 0 else { return }
        points.append(AudioEnvelopePoint(index: points.count, startSeconds: Double(windowStart) / sampleRate, durationSeconds: Double(totalFrames - windowStart) / sampleRate, peak: windowPeak, rms: sqrt(windowSquares / Double(windowSamples))))
        windowSquares = 0; windowPeak = 0; windowSamples = 0; windowStart = totalFrames
    }
    public mutating func finish() throws -> AudioDiagnostics {
        guard totalFrames > 0 else { throw VideoError.invalid("音轨没有可解码的真实采样") }; flush()
        let duration = Double(totalFrames) / sampleRate
        return AudioDiagnostics(duration: duration, sampleRate: sampleRate, channels: channels, peakDBFS: 20 * log10(max(peak, 1e-9)), rmsDBFS: 20 * log10(max(sqrt(sumSquares / Double(totalSamples)), 1e-9)), clippedSamples: clips, leadingSilence: firstAudible.map { Double($0) / sampleRate } ?? duration, trailingSilence: lastAudible.map { Double(totalFrames - $0 - 1) / sampleRate } ?? duration, envelope: points)
    }
}
