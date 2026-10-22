import Foundation
import CryptoKit

public enum VideoError: Error, LocalizedError, Codable, Equatable {
    case invalid(String), conflict(String), notFound(String), permission(String), budget(String), review(String), unavailable(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .conflict(let s), .notFound(let s), .permission(let s), .budget(let s), .review(let s), .unavailable(let s): return s }
    }
    public var code: String {
        switch self { case .invalid: return "invalid_input"; case .conflict: return "revision_conflict"; case .notFound: return "not_found"; case .permission: return "permission_required"; case .budget: return "budget_exceeded"; case .review: return "needs_review"; case .unavailable: return "unavailable" }
    }
    public var exitCode: Int32 { switch self { case .invalid, .notFound: return 2; case .permission: return 3; case .budget: return 4; case .review: return 5; case .conflict: return 6; case .unavailable: return 8 } }
}

public enum Codec {
    public static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
    public static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    public static func data<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func digest<T: Encodable>(_ value: T) throws -> String { hash(try data(value)) }
    public static func id() -> String { UUID().uuidString.lowercased() }
}

public struct Money: Codable, Equatable, Sendable {
    public var amount: Decimal
    public var currency: String
    public init(_ amount: Decimal, _ currency: String = "CNY") { self.amount = amount; self.currency = currency.uppercased() }
    public init(text: String, currency: String = "CNY") throws {
        guard text.range(of:"^(0|[1-9][0-9]*)(\\.[0-9]+)?$",options:.regularExpression) != nil,text.filter({$0.isNumber}).count<=38,let n = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !n.isNaN, n >= 0 else { throw VideoError.invalid("金额必须是完整的非负十进制数，不含单位或其他文字") }
        guard currency.range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil else { throw VideoError.invalid("请填写三位币种代码") }
        self.init(n, currency)
    }
    public func adding(_ other: Money) throws -> Money { guard currency == other.currency else { throw VideoError.invalid("币种不同，请分别核算") }; return Money(amount + other.amount, currency) }
    public var display: String { let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = currency; f.locale = Locale(identifier: "zh_CN"); return f.string(from: amount as NSDecimalNumber) ?? "\(amount) \(currency)" }
}

public enum BeijingTime {
    public static func string(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd HH:mm '北京时间'"; return f.string(from: date) }
}

public enum Purpose: String, Codable, CaseIterable, Sendable { case course = "课程推广", tool = "工具推广", brand = "品牌合作", education = "非商业教学" }
public enum SceneKind: String, Codable, CaseIterable, Sendable { case explanation = "图文讲解", simulation = "规则模拟", cartoon = "原创卡通", image = "图片", video = "真实录屏" }
public enum Aspect: String, Codable, CaseIterable, Sendable {
    case landscape = "16:9", portrait = "9:16"
    public var width: Int { self == .landscape ? 1280 : 720 }
    public var height: Int { self == .landscape ? 720 : 1280 }
}
public enum Role: String, Codable, Sendable { case owner, collaborator, reviewer }
public struct Grant: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var principal: String; public var role: Role; public var projectIDs: Set<String>; public var revisionIDs: Set<String>; public var expiresAt: Date; public var revoked = false
    public init(principal: String, role: Role, projectIDs: Set<String>, revisionIDs: Set<String>, expiresAt: Date) { self.principal = principal; self.role = role; self.projectIDs = projectIDs; self.revisionIDs = revisionIDs; self.expiresAt = expiresAt }
}
public struct Workspace: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var name: String; public var owner: String; public var salt = Codec.id(); public var grants: [Grant] = []
    public init(name: String, owner: String) { self.name = name; self.owner = owner }
    public func authorize(principal: String, project: String? = nil, revision: String? = nil, financial: Bool = false, write: Bool = false, now: Date = Date()) throws {
        if principal == owner { return }
        guard !financial, let p = project, let g = grants.first(where: { !$0.revoked && $0.principal == principal && $0.expiresAt > now && $0.projectIDs.contains(p) && (revision == nil || $0.revisionIDs.contains(revision!)) }), !write || g.role == .collaborator else { throw VideoError.permission("无此工作区或版本的访问权限") }
    }
}
