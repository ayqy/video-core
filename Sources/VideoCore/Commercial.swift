import Foundation
import CryptoKit

public struct Publication: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var workspaceID: String; public var projectID: String; public var revisionID: String; public var platform: String; public var accountReference: String; public var remoteContentID: String?; public var scheduledAt: Date?; public var publishedAt: Date?; public var aiLabel: Bool; public var commercialLabel: Bool; public var rightsChecked: Bool; public var ctaPermitted: Bool; public var channelAuthorized: Bool; public var trackingCode: String; public var stale = false; public var eligibility: String; public var title: String; public var description: String
    public var targetDigest: String?; public var deliveryJobID: String?; public var preparedAt: Date?; public var checkedBy: String?; public var validationWarnings: [String]?
    public init(workspaceID: String, projectID: String, revisionID: String, platform: String, accountReference: String, aiLabel: Bool, commercialLabel: Bool, rightsChecked: Bool, ctaPermitted: Bool, channelAuthorized: Bool, trackingCode: String, eligibility: String = "未知", title: String, description: String) { self.workspaceID = workspaceID; self.projectID = projectID; self.revisionID = revisionID; self.platform = platform; self.accountReference = accountReference; self.aiLabel = aiLabel; self.commercialLabel = commercialLabel; self.rightsChecked = rightsChecked; self.ctaPermitted = ctaPermitted; self.channelAuthorized = channelAuthorized; self.trackingCode = trackingCode; self.eligibility = eligibility; self.title = title; self.description = description }
    public var state: String { remoteContentID?.isEmpty == false ? (stale ? "已发布·材料待复核" : "已发布·已回填ID") : (validationWarnings?.isEmpty == false ? "待核对·待人工发布" : "待人工发布") }
    public func validate(commercial: Bool) throws {
        guard !platform.isEmpty, !title.isEmpty else { throw VideoError.invalid("发布记录须填写平台与标题") }
        if remoteContentID?.isEmpty == false { guard aiLabel, rightsChecked, ctaPermitted, !commercial || commercialLabel else { throw VideoError.review("真实发布记录须逐项核对AI/商业标识、版权与CTA") }; guard channelAuthorized, publishedAt != nil, !accountReference.isEmpty else { throw VideoError.permission("回填已发布状态需要账号权限、账号引用与真实发布时间") } }
    }
}
public struct ToolSale: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var workspaceID: String; public var buyerReference: String; public var plan: String; public var paid: Money?; public var refunded: Decimal; public var paidAt: Date?; public var expiresAt: Date?; public var supportUntil: Date?; public var supportScope: String; public var license: String; public var receipt: String; public var subscription: Bool; public var cancelled: Bool; public var bringOwnAccount: Bool
    public var orderReference: String?; public var renewalOf: String?; public var trialScope: String?; public var hostedAllowance: String?; public var thirdPartyCosts: String?; public var autoRenew: Bool?; public var cancellationReason: String?
    public init(workspaceID: String, buyerReference: String, plan: String, paid: Money?, refunded: Decimal = 0, paidAt: Date? = nil, expiresAt: Date? = nil, supportUntil: Date? = nil, supportScope: String, license: String, receipt: String, subscription: Bool, cancelled: Bool = false, bringOwnAccount: Bool = true) { self.workspaceID = workspaceID; self.buyerReference = buyerReference; self.plan = plan; self.paid = paid; self.refunded = refunded; self.paidAt = paidAt; self.expiresAt = expiresAt; self.supportUntil = supportUntil; self.supportScope = supportScope; self.license = license; self.receipt = receipt; self.subscription = subscription; self.cancelled = cancelled; self.bringOwnAccount = bringOwnAccount }
    public func active(at now: Date) -> Bool { paid != nil && paid!.amount > 0 && paidAt != nil && paidAt! <= now && !receipt.isEmpty && refunded < paid!.amount && !cancelled && (!subscription || expiresAt != nil) && (expiresAt == nil || expiresAt! > now) }
    public func validate() throws { guard !supportScope.isEmpty, !license.isEmpty, refunded >= 0, refunded <= (paid?.amount ?? 0), paid == nil || (paid!.amount >= 0 && paidAt != nil && !receipt.isEmpty), expiresAt == nil || paidAt == nil || expiresAt! > paidAt!, renewalOf != id else { throw VideoError.invalid("工具实付需付款凭证、时间、有效退款与许可/支持范围") } }
}
public enum Settlement: String, Codable, CaseIterable, Sendable { case production = "制作费", distribution = "分发费", cps = "CPS", fixedLicense = "固定授权费", adShare = "广告消耗分成" }
public struct BrandDeal: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var workspaceID: String; public var client: String; public var brief: String; public var vertical: String; public var checklist: [String: Bool]; public var projectID: String?; public var approvedRevisionID: String?; public var revisionsAllowed: Int; public var revisionsUsed: Int = 0; public var usage: String; public var expiresAt: Date; public var exclusivity: String; public var settlements: Set<Settlement>; public var quote: Money; public var received: Money?; public var receipt: String; public var noncash: String; public var rate: Decimal; public var validGMV: Decimal; public var actualAdSpend: Decimal; public var shareCap: Decimal?
    public var settlementRecords: [BrandSettlement]?; public var authorizations: [CommercialAuthorization]?; public var approvals: [BrandApproval]?; public var checklistTemplate: VerticalChecklistTemplate?; public var checklistEvidence: [String: [String]]?; public var revisionNotes: [String]?; public var legacyCash: CashEntry?
    public init(workspaceID: String, client: String, brief: String, vertical: String, checklist: [String: Bool], revisionsAllowed: Int, usage: String, expiresAt: Date, exclusivity: String, settlements: Set<Settlement>, quote: Money, received: Money? = nil, receipt: String = "", noncash: String = "", rate: Decimal = 0, validGMV: Decimal = 0, actualAdSpend: Decimal = 0, shareCap: Decimal? = nil) { self.workspaceID = workspaceID; self.client = client; self.brief = brief; self.vertical = vertical; self.checklist = checklist; self.revisionsAllowed = revisionsAllowed; self.usage = usage; self.expiresAt = expiresAt; self.exclusivity = exclusivity; self.settlements = settlements; self.quote = quote; self.received = received; self.receipt = receipt; self.noncash = noncash; self.rate = rate; self.validGMV = validGMV; self.actualAdSpend = actualAdSpend; self.shareCap = shareCap }
    public func validate() throws {
        guard !client.isEmpty, !brief.isEmpty, !usage.isEmpty, revisionsAllowed >= 0, revisionsUsed >= 0, revisionsUsed <= revisionsAllowed, rate >= 0, rate <= 1, validGMV >= 0, actualAdSpend >= 0, shareCap == nil || shareCap! >= 0, quote.amount >= 0, received == nil || (received!.amount >= 0 && !receipt.isEmpty) else { throw VideoError.invalid("商单brief、用途、修改限额、分成率或回款凭证不完整") }
        guard !(settlements.contains(.fixedLicense) && settlements.contains(.adShare)) else { throw VideoError.invalid("固定授权费与广告消耗分成互斥") }
        if let records = settlementRecords { guard Set(records.map(\.id)).count == records.count, Set(records.map { $0.kind.rawValue + "|" + $0.receipt }).count == records.count else { throw VideoError.invalid("商单结算记录ID或同类型结算凭证重复") }; for record in records { try record.validate(); guard settlements.contains(record.kind), record.received.currency == quote.currency else { throw VideoError.invalid("实收分账须属于已选结算方式和报价币种") } } }
        if let template = checklistTemplate { try template.validate() }
    }
    public var cpsEstimate: Decimal { validGMV * rate }
    public var adShareEstimate: Decimal { min(actualAdSpend * rate, shareCap ?? actualAdSpend * rate) }
    public static func checklist(for vertical: String) -> [String] { switch vertical { case "留学": return ["当期政策来源", "院校事实", "结果不保证"]; case "美妆": return ["功效实证", "成分与适用人群", "禁用医疗承诺"]; case "数码": return ["真机记录", "型号版本", "参数证据"]; default: return ["经营凭证", "主张来源", "素材与声音授权"] } }
}
public struct FunnelEvent: Codable, Identifiable, Sendable {
    public var id: String; public var workspaceID: String; public var subject: String; public var stage: String; public var at: Date
    public var evidenceReference: String?; public var source: String?
    public init(id: String = Codec.id(), workspaceID: String, subject: String, stage: String, at: Date = Date()) { self.id = id; self.workspaceID = workspaceID; self.subject = subject; self.stage = stage; self.at = at }
}
public struct PluginManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var version: String; public var abi: Int; public var minimumCore: Int; public var capabilities: [String]; public var inputSchema: Int; public var outputSchema: Int; public var implementationDigest: String; public var permissions: Set<String>; public var sourceVisibility: String
    public init(id: String, version: String, abi: Int = 1, minimumCore: Int = 1, capabilities: [String], inputSchema: Int = 1, outputSchema: Int = 1, implementationDigest: String, permissions: Set<String>, sourceVisibility: String = "closed") { self.id = id; self.version = version; self.abi = abi; self.minimumCore = minimumCore; self.capabilities = capabilities; self.inputSchema = inputSchema; self.outputSchema = outputSchema; self.implementationDigest = implementationDigest; self.permissions = permissions; self.sourceVisibility = sourceVisibility }
}
public struct CommercialPolicy: Codable, Sendable {
    public var pluginID: String; public var version: Int; public var access: String; public var updatedAt: Date; public var sourceVisibility: String
    public init(pluginID: String, version: Int, access: String, updatedAt: Date = Date(), sourceVisibility: String = "closed") { self.pluginID = pluginID; self.version = version; self.access = access; self.updatedAt = updatedAt; self.sourceVisibility = sourceVisibility }
}
public struct SignedDocument: Codable, Sendable {
    public var payload: Data; public var signature: Data
    public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }
    public func verified<T: Decodable>(as type: T.Type, publicKey: Data) throws -> T {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signature, for: payload) else { throw VideoError.permission("签名无效") }
        return try Codec.decoder().decode(type, from: payload)
    }
}
public enum PluginHost {
    public static func validate(manifest: PluginManifest, policy: CommercialPolicy, installedDigest: String, entitlements: Set<String>, grantedPermissions: Set<String>) throws {
        guard manifest.abi == 1, manifest.inputSchema == 1, manifest.outputSchema == 1, manifest.minimumCore <= 1 else { throw VideoError.unavailable("插件ABI或schema不兼容") }
        guard manifest.implementationDigest == installedDigest, !installedDigest.isEmpty else { throw VideoError.permission("插件实现摘要不匹配") }
        guard manifest.permissions.isSubset(of: grantedPermissions) else { throw VideoError.permission("插件请求越权") }
        guard policy.pluginID == manifest.id, ["free", "paid", "disabled"].contains(policy.access), ["open", "closed"].contains(policy.sourceVisibility) else { throw VideoError.invalid("插件策略不合法") }
        guard policy.access != "disabled", policy.access == "free" || entitlements.contains(manifest.id) else { throw VideoError.permission("需要该高级插件的独立权益，编辑器权益不代替插件权益") }
    }
    public static func validateOutput(path: URL, root: URL) throws { let p = path.standardizedFileURL.resolvingSymlinksInPath().path; let r = root.standardizedFileURL.resolvingSymlinksInPath().path; guard p.hasPrefix(r + "/"), p != r else { throw VideoError.permission("插件输出路径越界") } }
}
