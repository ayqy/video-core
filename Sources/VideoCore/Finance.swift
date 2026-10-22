import Foundation
import CryptoKit

public struct Refund: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var amount: Decimal; public var at: Date
    public init(id: String, amount: Decimal, at: Date) { self.id = id; self.amount = amount; self.at = at }
}
public enum CustomerKind: String, Codable, CaseIterable, Sendable { case new = "新客", existing = "老客", upgrade = "升单", unknown = "未知" }
public struct Order: Codable, Identifiable, Sendable {
    public var tags: [String]?
    public var id: String; public var workspaceID: String; public var platform: String; public var buyer: String; public var sku: String; public var paidAt: Date; public var paid: Money; public var fee: Decimal?; public var refunds: [Refund]; public var sourceCode: String?; public var kind: CustomerKind; public var maturityDays: Int; public var importID: String
    public init(workspaceID: String, platform: String, rawOrderID: String, rawBuyerID: String, salt: String, sku: String, paidAt: Date, paid: Money, fee: Decimal?, refunds: [Refund] = [], sourceCode: String? = nil, kind: CustomerKind = .unknown, maturityDays: Int = 7, importID: String) throws {
        guard !rawOrderID.isEmpty, !platform.isEmpty, !sku.isEmpty else { throw VideoError.invalid("平台、订单ID与SKU不能为空") }
        func pseudonym(_ s: String) -> String { HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: SymmetricKey(data: Data(salt.utf8))).map { String(format: "%02x", $0) }.joined() }
        self.id = pseudonym(platform + "\u{0}" + rawOrderID); self.workspaceID = workspaceID; self.platform = platform; self.buyer = rawBuyerID.isEmpty ? "" : pseudonym(rawBuyerID); self.sku = sku; self.paidAt = paidAt; self.paid = paid; self.fee = fee; self.refunds = refunds; self.sourceCode = sourceCode; self.kind = kind; self.maturityDays = maturityDays; self.importID = importID
        try validate()
    }
    public var refunded: Decimal { refunds.reduce(0) { $0 + $1.amount } }
    public var net: Decimal? { fee.map { paid.amount - refunded - $0 } }
    public func mature(at now: Date) -> Bool { paidAt.addingTimeInterval(Double(maturityDays) * 86400) <= now }
    public func validate() throws {
        guard paid.amount >= 0, fee == nil || fee! >= 0, (0...3650).contains(maturityDays), refunds.allSatisfy({ $0.amount >= 0 }), Set(refunds.map(\.id)).count == refunds.count, refunded <= paid.amount else { throw VideoError.invalid("退款须按事件去重且累计不超过实付；费用与成熟窗口须有效") }
    }
}
public struct Metric: Codable, Identifiable, Sendable {
    public var id: String { "\(workspaceID)|\(platform)|\(contentID)|\(asOf.timeIntervalSince1970)|\(window)" }
    public var workspaceID: String; public var platform: String; public var contentID: String; public var asOf: Date; public var window: String; public var cumulative: Bool; public var views: Int64; public var arrivals: Int64?; public var definition: String; public var importID: String
    public init(workspaceID: String, platform: String, contentID: String, asOf: Date, window: String = "lifetime", cumulative: Bool = true, views: Int64, arrivals: Int64?, definition: String, importID: String) throws {
        guard views >= 0, arrivals == nil || arrivals! >= 0, !platform.isEmpty, !contentID.isEmpty, !definition.isEmpty else { throw VideoError.invalid("指标需平台、内容ID、非负值与口径") }
        self.workspaceID = workspaceID; self.platform = platform; self.contentID = contentID; self.asOf = asOf; self.window = window; self.cumulative = cumulative; self.views = views; self.arrivals = arrivals; self.definition = definition; self.importID = importID
    }
    public func validate()throws{guard views>=0,arrivals==nil || arrivals!>=0,!platform.isEmpty,!contentID.isEmpty,!definition.isEmpty,!window.isEmpty else{throw VideoError.invalid("指标需平台、内容ID、非负值与明确口径")}}
}
public struct Attribution: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var orderID: String; public var publicationID: String; public var weight: Decimal; public var method: String; public var confidence: String
    public init(orderID: String, publicationID: String, weight: Decimal, method: String, confidence: String) { self.orderID = orderID; self.publicationID = publicationID; self.weight = weight; self.method = method; self.confidence = confidence }
}
public enum RevenueKind: String, Codable, CaseIterable, Sendable { case course = "课程", incentive = "平台激励", tool = "工具", brand = "商单" }
public struct CashEntry: Codable, Identifiable, Sendable {
    public var id: String; public var workspaceID: String; public var kind: RevenueKind; public var label: String; public var received: Money; public var refunded: Decimal; public var at: Date; public var receipt: String; public var assumption: Bool; public var noncash: Bool
    public init(id: String = Codec.id(), workspaceID: String, kind: RevenueKind, label: String, received: Money, refunded: Decimal = 0, at: Date = Date(), receipt: String, assumption: Bool = false, noncash: Bool = false) { self.id = id; self.workspaceID = workspaceID; self.kind = kind; self.label = label; self.received = received; self.refunded = refunded; self.at = at; self.receipt = receipt; self.assumption = assumption; self.noncash = noncash }
}
public struct Expense: Codable, Identifiable, Sendable {
    public var id: String; public var workspaceID: String; public var label: String; public var money: Money?; public var hours: Decimal; public var development: Bool; public var allocation: [String: Decimal]; public var at: Date
    public init(id: String = Codec.id(), workspaceID: String, label: String, money: Money?, hours: Decimal = 0, development: Bool = false, allocation: [String: Decimal] = [:], at: Date = Date()) { self.id = id; self.workspaceID = workspaceID; self.label = label; self.money = money; self.hours = hours; self.development = development; self.allocation = allocation; self.at = at }
}
public struct Baseline: Codable, Sendable {
    public var contribution: Money; public var days: Int; public var comparable: Bool; public var description: String; public var from: Date; public var version: Int
    public init(contribution: Money, days: Int, comparable: Bool, description: String, from: Date, version: Int = 1) { self.contribution = contribution; self.days = days; self.comparable = comparable; self.description = description; self.from = from; self.version = version }
}
public struct FinanceReport: Codable, Sendable {
    public var currency: String; public var settledCourse: Decimal; public var provisionalCourse: Decimal; public var unknownFeeOrders: Int; public var attributedOrders: Int; public var unknownSourceOrders: Int; public var newCustomers: Int; public var matureOrders: Int
    public var actualOtherRevenue: [String: Decimal]; public var sharedCashCost: Decimal; public var unknownCosts: Int; public var hours: Decimal; public var developmentCost: Decimal; public var incrementalEstimate: Decimal?; public var assumptions: Decimal; public var netContribution: Decimal?
}
public enum Finance {
    public static func validateAttribution(_ links: [Attribution]) throws {
        for rows in Dictionary(grouping: links, by: \.orderID).values {
            guard rows.allSatisfy({ $0.weight >= 0 && $0.weight <= 1 }), rows.reduce(Decimal(0), { $0 + $1.weight }) <= 1, Set(rows.map(\.publicationID)).count == rows.count else { throw VideoError.invalid("同订单归因权重总和不得超过1，且内容不可重复") }
        }
    }
    public static func report(orders: [Order], cash: [CashEntry], expenses: [Expense], baseline: Baseline?, currency: String = "CNY", windowDays: Int = 30, now: Date = Date()) throws -> FinanceReport {
        guard windowDays > 0 else { throw VideoError.invalid("观察期必须为正数") }
        let start = now.addingTimeInterval(-Double(windowDays) * 86400)
        let os = orders.filter { $0.paid.currency == currency && $0.paidAt >= start && $0.paidAt <= now }
        let cs = cash.filter { $0.received.currency == currency && $0.at >= start && $0.at <= now }
        let es = expenses.filter { $0.at >= start && $0.at <= now }
        let mature = os.filter { $0.mature(at: now) }
        let settled = mature.compactMap(\.net).reduce(0,+)
        let provisional = os.filter { !$0.mature(at: now) }.compactMap(\.net).reduce(0,+)
        let actual = cs.filter { !$0.assumption && !$0.noncash && !$0.receipt.isEmpty && $0.kind != .course }
        var other: [String: Decimal] = [:]; for c in actual { other[c.kind.rawValue, default: 0] += c.received.amount - c.refunded }
        let running = es.filter { !$0.development }
        let costs = running.filter { $0.money?.currency == currency }.compactMap { $0.money?.amount }.reduce(0,+)
        let unknown = running.filter { $0.money == nil }.count
        let unknownFees = os.filter { $0.fee == nil }.count
        let net: Decimal? = unknown == 0 && unknownFees == 0 && (!os.isEmpty || !actual.isEmpty) ? settled + other.values.reduce(0,+) - costs : nil
        var increment: Decimal?
        if let b = baseline, b.comparable, b.days > 0, !b.description.isEmpty, b.contribution.currency == currency, unknown == 0, unknownFees == 0, os.allSatisfy({ $0.mature(at: now) }) { increment = settled - b.contribution.amount * Decimal(windowDays) / Decimal(b.days) - costs }
        return FinanceReport(currency: currency, settledCourse: settled, provisionalCourse: provisional, unknownFeeOrders: unknownFees, attributedOrders: os.filter { !($0.sourceCode ?? "").isEmpty }.count, unknownSourceOrders: os.filter { ($0.sourceCode ?? "").isEmpty }.count, newCustomers: Set(os.filter { $0.kind == .new && !$0.buyer.isEmpty }.map(\.buyer)).count, matureOrders: mature.count, actualOtherRevenue: other, sharedCashCost: costs, unknownCosts: unknown, hours: es.map(\.hours).reduce(0,+), developmentCost: es.filter { $0.development && $0.money?.currency == currency }.compactMap { $0.money?.amount }.reduce(0,+), incrementalEstimate: increment, assumptions: cs.filter(\.assumption).map { $0.received.amount - $0.refunded }.reduce(0,+), netContribution: net)
    }
}

public enum CSV {
    /// RFC4180 quoting, CRLF, embedded newlines and BOM; never evaluates cells as code.
    public static func parse(_ text: String) throws -> [[String: String]] {
        guard text.utf8.count <= 10 * 1024 * 1024 else { throw VideoError.invalid("导入表格超过10MiB") }
        let normalized = text.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of:"\r\n",with:"\n")
        let chars = Array(normalized); var rows: [[String]] = []; var row: [String] = []; var cell = ""; var quoted = false; var closed = false; var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted { if c == "\"" { if i+1 < chars.count && chars[i+1] == "\"" { cell.append("\""); i += 1 } else { quoted = false; closed = true } } else { cell.append(c) } }
            else if c == "\"" { guard cell.isEmpty && !closed else { throw VideoError.invalid("CSV引号位置不合法") }; quoted = true }
            else if c == "," { row.append(cell); cell = ""; closed = false }
            else if c == "\n" || c == "\r" { row.append(cell); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = []; cell = ""; closed = false; if c == "\r" && i+1 < chars.count && chars[i+1] == "\n" { i += 1 } }
            else { guard !closed else { throw VideoError.invalid("CSV引号后有多余字符") }; cell.append(c) }
            i += 1
        }
        guard !quoted else { throw VideoError.invalid("CSV引号未闭合") }
        row.append(cell); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        guard let header = rows.first, !header.isEmpty, Set(header).count == header.count, header.allSatisfy({ !$0.isEmpty }), rows.count <= 50001 else { throw VideoError.invalid("CSV表头缺失、重复或行数超过50000") }
        return try rows.dropFirst().enumerated().map { index, values in guard values.count == header.count else { throw VideoError.invalid("CSV第\(index+2)行列数不一致") }; return Dictionary(uniqueKeysWithValues: zip(header, values)) }
    }
    public static func safeCell(_ value: String) -> String { let s = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value; return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
