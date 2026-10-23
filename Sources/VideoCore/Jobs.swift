import Foundation

public enum JobState: String, Codable, Sendable {
    case queued, running, needsReview = "needs_review", succeeded, failed, interrupted, cancelRequested = "cancel_requested", cancelled, unknownRemote = "unknown_remote", billingPending = "billing_pending"
    public var label: String { switch self { case .queued: return "排队中"; case .running: return "制作中"; case .needsReview: return "待看听审核"; case .succeeded: return "已生成"; case .failed: return "失败"; case .interrupted: return "已中断，可恢复"; case .cancelRequested: return "取消请求中"; case .cancelled: return "已取消，费用独立核对"; case .unknownRemote: return "远端状态未知，先查询"; case .billingPending: return "费用待对账" } }
}
public struct Quote: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var projectID: String; public var revisionID: String; public var digest: String; public var upper: Money; public var unit: String; public var provider: String; public var expiresAt: Date; public var attempts: Int; public var confirmed: Bool; public var createdAt = Date()
    public var breakdown: EstimateBreakdown?
    public init(projectID: String, revisionID: String, digest: String, upper: Money, unit: String, provider: String, expiresAt: Date, attempts: Int = 1, confirmed: Bool = false) { self.projectID = projectID; self.revisionID = revisionID; self.digest = digest; self.upper = upper; self.unit = unit; self.provider = provider; self.expiresAt = expiresAt; self.attempts = attempts; self.confirmed = confirmed }
}
public struct Artifact: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var path: String; public var mime: String; public var bytes: Int; public var sha256: String; public var revision: String
    public init(path: String, mime: String, bytes: Int, sha256: String, revision: String) { self.path = path; self.mime = mime; self.bytes = bytes; self.sha256 = sha256; self.revision = revision }
}
public struct Job: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var workspaceID: String; public var projectID: String; public var revisionID: String; public var digest: String; public var requestKey: String; public var quote: Quote; public var state: JobState = .queued; public var remoteID: String?; public var progress: Double = 0; public var actual: Money?; public var billingUnknown: Bool; public var refundPending: Money?; public var artifacts: [Artifact] = []; public var message = ""; public var createdAt = Date(); public var updatedAt = Date(); public var attempt = 0; public var cacheHit = false
    public var lease: WorkerLease?; public var billing: [BillingRecord]?; public var remoteCheckedAt: Date?
    public var providerAttempts:[ProviderAttempt]?
    public var videoGeneration:VideoGenerationReceipt?
    public var outputAssetIDs:[String]?
    public init(workspaceID: String, projectID: String, revisionID: String, digest: String, requestKey: String, quote: Quote) { self.workspaceID = workspaceID; self.projectID = projectID; self.revisionID = revisionID; self.digest = digest; self.requestKey = requestKey; self.quote = quote; self.billingUnknown = quote.provider != "native" }
    public var exposure: Money { actual ?? quote.upper }
}
public struct BudgetPolicy: Codable, Sendable {
    public var project: Money; public var month: Money
    public init(project: Money = Money(50), month: Money = Money(200)) { self.project = project; self.month = month }
}
public enum JobRules {
    public static func submit(workspaceID: String, project: Project, quote: Quote, requestKey: String, existing: [Job], budget: BudgetPolicy, now: Date = Date()) throws -> Job {
        guard project.workspaceID==workspaceID,project.current.workspaceID==workspaceID else{throw VideoError.permission("任务、工程和产品必须属于同一工作区")}
        let digest = try project.current.contentDigest()
        if let old = existing.first(where: { $0.workspaceID == workspaceID && $0.requestKey == requestKey }) { guard old.projectID == project.id, old.digest == digest, old.quote.id == quote.id else { throw VideoError.conflict("同幂等键已绑定不同输入或报价") }; return old }
        guard !requestKey.isEmpty, quote.confirmed, quote.expiresAt > now, quote.projectID == project.id, quote.revisionID == project.current.id, quote.digest == digest, quote.attempts > 0, quote.upper.amount >= 0 else { throw VideoError.review("报价过期、未确认或与当前版本不一致，请重新核对") }
        if let details = quote.breakdown { try details.validate(now: now); guard try details.total() == quote.upper, details.maximumAttempts == quote.attempts else { throw VideoError.review("费用明细、尝试次数与确认上界不一致") } }
        guard quote.upper.currency == budget.project.currency, quote.upper.currency == budget.month.currency, quote.unit == quote.upper.currency else { throw VideoError.budget("预算币种/计费单位不一致；不自动换算") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier:"Asia/Shanghai")!; let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let active = existing.filter { $0.workspaceID == workspaceID && $0.quote.upper.currency == quote.upper.currency }
        let p = active.filter { $0.projectID == project.id }.map { $0.exposure.amount }.reduce(0,+)
        let m = active.filter { $0.createdAt >= monthStart }.map { $0.exposure.amount }.reduce(0,+)
        guard p + quote.upper.amount <= budget.project.amount, m + quote.upper.amount <= budget.month.amount else { throw VideoError.budget("项目或月现金上界已超限；取消不抹掉已发生费用") }
        return Job(workspaceID: workspaceID, projectID: project.id, revisionID: project.current.id, digest: digest, requestKey: requestKey, quote: quote)
    }
    public static func cancel(_ job: Job) -> Job { var j = job; j.updatedAt = Date(); if j.videoGeneration != nil { j.message = "百度合同无取消接口，尚未发送远端取消；原任务继续查询，预算和实耗待核对"; return j }; if j.remoteID != nil || j.state == .unknownRemote { j.state = .cancelRequested; j.message = "须查询远端取消结果；已花费不自动归零" } else { j.state = .cancelled; if j.quote.provider == "native" { j.actual = Money(0, j.quote.upper.currency); j.billingUnknown = false } }; return j }
    public static func recover(_ job: Job) throws -> Job { var j = job; guard [.interrupted, .failed, .unknownRemote].contains(j.state) else { throw VideoError.invalid("此作业无需恢复") }; if j.quote.provider != "native" { j.state = .unknownRemote; j.message = "先查询原remote_task_id，禁止重新付费提交" } else { j.state = .queued; j.message = "沿用原任务ID恢复" }; j.lease=nil; j.updatedAt = Date(); return j }
}
public struct ProviderProfile: Codable, Identifiable, Sendable {
    public var capabilities: ProviderCapabilities?
    public var id = Codec.id(); public var name: String; public var endpoint: String; public var model: String; public var supportedParameters: Set<String>; public var maxOutput: Int; public var allowsUpload: Bool; public var keyReference: String; public var kind: String; public var statusPath: String?; public var cancelPath: String?; public var idempotency: Bool
    public init(name: String, endpoint: String, model: String, supportedParameters: Set<String>, maxOutput: Int = 4096, allowsUpload: Bool = false, keyReference: String, kind: String = "chat", statusPath: String? = nil, cancelPath: String? = nil, idempotency: Bool = false) { self.name = name; self.endpoint = endpoint; self.model = model; self.supportedParameters = supportedParameters; self.maxOutput = maxOutput; self.allowsUpload = allowsUpload; self.keyReference = keyReference; self.kind = kind; self.statusPath = statusPath; self.cancelPath = cancelPath; self.idempotency = idempotency }
    public func validate() throws { guard let u = URL(string: endpoint), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil, !model.isEmpty, (1...1000000).contains(maxOutput), !keyReference.isEmpty else { throw VideoError.invalid("服务仅接受不含凭据的HTTPS端点、模型名和Keychain引用") } }
}
