import Foundation

public enum PublicationRules {
    public static func pendingChecks(_ publication: Publication, commercial: Bool) -> [String] {
        var missing: [String] = []
        if !publication.aiLabel { missing.append("AI制作标识尚未核对") }
        if commercial && !publication.commercialLabel { missing.append("商业属性标识尚未核对") }
        if !publication.rightsChecked { missing.append("素材、声音与使用权尚未核对") }
        if !publication.ctaPermitted { missing.append("本账号CTA/承接权限尚未核对") }
        if !publication.channelAuthorized { missing.append("尚未确认拥有当前账号的发布权限，只生成待人工发布包") }
        if publication.accountReference.isEmpty { missing.append("尚未填写发布账号引用") }
        return missing
    }
    /// Pure domain checks bind one immutable version and one completed render. The caller additionally
    /// verifies all four physical artifacts with Repository.verifyDelivery before persisting or sharing.
    public static func prepare(_ requested: Publication, project: Project, job: Job, database: Database, reviewer: String, now: Date = Date()) throws -> Publication {
        var publication = requested
        guard publication.workspaceID == project.workspaceID, publication.projectID == project.id, let revision = project.revisions.first(where: { $0.id == publication.revisionID }), job.workspaceID == project.workspaceID, job.projectID == project.id, job.revisionID == revision.id else { throw VideoError.permission("发布必须绑定本工作区的指定工程、不可变版本和制作任务") }
        let digest = try revision.contentDigest()
        guard publication.targetDigest == nil || publication.targetDigest == digest, publication.deliveryJobID == nil || publication.deliveryJobID == job.id, job.digest == digest, job.state == .succeeded, job.artifacts.count == 4, !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VideoError.review("发布包、审批摘要或制作任务不属于指定已审版本") }
        let issues = try Quality.inspect(revision, database: database, requireReview: true, now: now)
        guard issues.isEmpty else { throw VideoError.review(issues.map(\.message).joined(separator: "\n")) }
        let account = publication.accountReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.localizedCaseInsensitiveContains("bearer "), !account.contains("-----BEGIN"), account.range(of: "(?i)(password|cookie|authorization|access_token|api_key)\\s*[:=]", options: .regularExpression) == nil else { throw VideoError.permission("账号字段只能填写非敏感引用，不能填写登录或接口凭据") }
        publication.accountReference = account; publication.remoteContentID = publication.remoteContentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if publication.remoteContentID?.isEmpty == true { publication.remoteContentID = nil }
        publication.targetDigest = digest; publication.deliveryJobID = job.id; publication.checkedBy = reviewer; publication.preparedAt = publication.preparedAt ?? now
        if publication.trackingCode.isEmpty { publication.trackingCode = "video-" + String(publication.id.prefix(12)) }
        let checks = pendingChecks(publication, commercial: revision.purpose != .education)
        if publication.remoteContentID != nil {
            guard checks.isEmpty, let publishedAt = publication.publishedAt, publishedAt <= now, revision.review.at == nil || publishedAt >= revision.review.at! else { throw VideoError.review("真实发布须在该版本审核后发生，填写真实时间并完成全部账号/标签/版权/CTA检查") }
            publication.scheduledAt = nil
        } else { publication.publishedAt = nil }
        publication.validationWarnings = checks; try publication.validate(commercial: revision.purpose != .education)
        return publication
    }
    public static func awaitingManual(_ publications: [Publication], workspaceID: String) -> [Publication] {
        publications.filter { $0.workspaceID == workspaceID && ($0.remoteContentID ?? "").isEmpty }.sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
    }
}
public extension Database {
    mutating func recordPublication(_ requested: Publication, jobID: String, reviewer: String, now: Date = Date()) throws {
        let project = try self.project(requested.projectID)
        guard let job = jobs.first(where: { $0.id == jobID }) else { throw VideoError.notFound("发布包所需的制作任务缺失") }
        var publication = try PublicationRules.prepare(requested, project: project, job: job, database: self, reviewer: reviewer, now: now)
        if let original = publications.first(where: { $0.id == publication.id }) { guard original.workspaceID == publication.workspaceID, original.projectID == publication.projectID, original.revisionID == publication.revisionID, original.targetDigest == nil || original.targetDigest == publication.targetDigest else { throw VideoError.conflict("已有发布记录的目标版本不可替换，请为新版本创建独立记录") } }
        if let remote = publication.remoteContentID, let existing = publications.first(where: { $0.workspaceID == publication.workspaceID && $0.platform == publication.platform && $0.accountReference == publication.accountReference && $0.remoteContentID == remote }) {
            guard existing.projectID == publication.projectID, existing.revisionID == publication.revisionID, existing.targetDigest == nil || existing.targetDigest == publication.targetDigest else { throw VideoError.conflict("同一平台内容ID已绑定其他版本，不能伪装为本次发布") }
            publication.id = existing.id
        }
        publications.removeAll { $0.id == publication.id }; publications.append(publication)
    }
}
