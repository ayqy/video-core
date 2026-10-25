import Foundation

/// User-supplied operating facts. This is not a license grant or a pricing rule.
public struct UpstreamLicenseContext: Codable, Equatable, Sendable {
    public var organization: String
    public var teamSize: Int
    public var deploymentEntity: String
    public var usesRemotion: Bool
    public var freeCostAssumption: String

    public init(organization: String, teamSize: Int, deploymentEntity: String,
                usesRemotion: Bool = false, freeCostAssumption: String) {
        self.organization = organization; self.teamSize = teamSize
        self.deploymentEntity = deploymentEntity; self.usesRemotion = usesRemotion
        self.freeCostAssumption = freeCostAssumption
    }
}

public struct UpstreamLicenseContextRevision: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let number: Int
    public let context: UpstreamLicenseContext
    public let digest: String
    public let changedAt: Date
    public let changedBy: String
}

/// A local declaration that the user recorded a check for exactly one saved context.
/// It does not assert official authorization, purchase, or eligibility.
public struct UpstreamLicenseCheck: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let contextID: String
    public let contextDigest: String
    public let recordedAt: Date
    public let recordedBy: String
    public let note: String
}

public struct WorkspaceUpstreamLicense: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let contexts: [UpstreamLicenseContextRevision]
    public let checks: [UpstreamLicenseCheck]
    public var current: UpstreamLicenseContextRevision? { contexts.last }
}

public enum UpstreamLicenseCheckState: String, Codable, Sendable {
    case unconfigured, needsCheck, recorded
}

public struct UpstreamLicenseAssessment: Equatable, Sendable {
    public let state: UpstreamLicenseCheckState
    public let reason: String
    public let current: UpstreamLicenseContextRevision?
    public let currentCheck: UpstreamLicenseCheck?
}

public enum UpstreamLicenseRules {
    public static let pricingURL = URL(string: "https://www.remotion.dev/docs/license/pricing")!
    public static let sourceLicenseURL = URL(string: "https://github.com/remotion-dev/remotion/blob/main/LICENSE.md")!

    public static func normalized(_ context: UpstreamLicenseContext) throws -> UpstreamLicenseContext {
        // This is a storage/input bound, never a legal eligibility threshold.
        guard (1...1_000_000).contains(context.teamSize) else {
            throw VideoError.invalid("实际使用规模请填写 1 至 1000000 的整数；此范围只是输入限制，不是许可资格规则")
        }
        return UpstreamLicenseContext(
            organization: try text(context.organization, title: "组织或个人名称", limit: 200),
            teamSize: context.teamSize,
            deploymentEntity: try text(context.deploymentEntity, title: "实际部署与使用主体", limit: 500),
            usesRemotion: context.usesRemotion,
            freeCostAssumption: try text(context.freeCostAssumption, title: "免费成本假设与边界", limit: 2000))
    }

    private static func text(_ input: String, title: String, limit: Int) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VideoError.invalid("\(title)须为 1 至 \(limit) 字，不含换行或控制字符")
        }
        return value
    }

    private static func owner(_ access: WorkspaceAccessContext, in database: Database) throws {
        guard try database.workspace(access.workspaceID).owner == access.principal else {
            throw VideoError.permission("只有工作区作者可查看或记录上游许可复核")
        }
    }

    public static func ledger(access: WorkspaceAccessContext, in database: Database) throws -> WorkspaceUpstreamLicense? {
        try owner(access, in: database)
        return database.upstreamLicenseWorkspaces?.first { $0.workspaceID == access.workspaceID }
    }

    public static func assessment(access: WorkspaceAccessContext, in database: Database) throws -> UpstreamLicenseAssessment {
        let value = try ledger(access: access, in: database)
        guard let current = value?.current else {
            return UpstreamLicenseAssessment(state: .unconfigured,
                reason: "尚未保存许可上下文；基础原生剪辑不以此为前置。仅在另用 Remotion 时按实际条件核对其上游许可。",
                current: nil, currentCheck: nil)
        }
        let check = value?.checks.last { $0.contextID == current.id && $0.contextDigest == current.digest }
        if let check {
            return UpstreamLicenseAssessment(state: .recorded,
                reason: "已记录当前条件的本地核对；此记录不是官方授权、付款或许可资格证明。",
                current: current, currentCheck: check)
        }
        let reason = value?.checks.isEmpty == false
            ? "组织、规模、部署主体、Remotion 使用或免费成本假设已变化，旧核对不适用于当前条件；即使回改也须重新记录。"
            : "当前条件尚未记录核对。请核对官方许可与实际用途后明确记录，不自动判断免费资格。"
        return UpstreamLicenseAssessment(state: .needsCheck, reason: reason, current: current, currentCheck: nil)
    }

    @discardableResult
    public static func update(_ context: UpstreamLicenseContext, access: WorkspaceAccessContext,
                              in database: inout Database, now: Date = Date()) throws -> UpstreamLicenseContextRevision {
        try owner(access, in: database)
        let context = try normalized(context)
        let existing = try ledger(access: access, in: database)
        if let current = existing?.current, current.context == context { return current }
        let revision = UpstreamLicenseContextRevision(id: Codec.id(), number: (existing?.contexts.count ?? 0) + 1,
            context: context, digest: try Codec.digest(context), changedAt: now, changedBy: access.principal)
        let updated = WorkspaceUpstreamLicense(workspaceID: access.workspaceID,
            contexts: (existing?.contexts ?? []) + [revision], checks: existing?.checks ?? [])
        var entries = database.upstreamLicenseWorkspaces ?? []
        if let index = entries.firstIndex(where: { $0.workspaceID == access.workspaceID }) { entries[index] = updated }
        else { entries.append(updated) }
        database.upstreamLicenseWorkspaces = entries
        return revision
    }

    @discardableResult
    public static func recordCheck(contextID: String, contextDigest: String, note: String,
                                   access: WorkspaceAccessContext, in database: inout Database,
                                   now: Date = Date()) throws -> UpstreamLicenseCheck {
        try owner(access, in: database)
        guard let index = database.upstreamLicenseWorkspaces?.firstIndex(where: { $0.workspaceID == access.workspaceID }),
              let existing = database.upstreamLicenseWorkspaces?[index], let current = existing.current,
              current.id == contextID, current.digest == contextDigest else {
            throw VideoError.conflict("许可条件已变化或尚未保存，请刷新当前条件后重新核对；旧确认不会应用到新条件")
        }
        let check = UpstreamLicenseCheck(id: Codec.id(), contextID: current.id, contextDigest: current.digest,
            recordedAt: now, recordedBy: access.principal, note: try text(note, title: "核对依据与结论备注", limit: 2000))
        database.upstreamLicenseWorkspaces?[index] = WorkspaceUpstreamLicense(workspaceID: existing.workspaceID,
            contexts: existing.contexts, checks: existing.checks + [check])
        return check
    }

    public static func validate(database: Database) throws {
        let entries = database.upstreamLicenseWorkspaces ?? []
        guard Set(entries.map(\.workspaceID)).count == entries.count else { throw VideoError.invalid("上游许可工作区记录重复") }
        for entry in entries {
            _ = try database.workspace(entry.workspaceID)
            guard !entry.contexts.isEmpty, Set(entry.contexts.map(\.id)).count == entry.contexts.count,
                  Set(entry.checks.map(\.id)).count == entry.checks.count else { throw VideoError.invalid("许可条件或核对记录ID缺失、重复") }
            for (index, revision) in entry.contexts.enumerated() {
                guard !revision.id.isEmpty, revision.number == index + 1, !revision.changedBy.isEmpty,
                      revision.changedAt.timeIntervalSince1970.isFinite,
                      try normalized(revision.context) == revision.context,
                      try Codec.digest(revision.context) == revision.digest else { throw VideoError.invalid("许可条件版本或摘要不一致") }
            }
            for check in entry.checks {
                guard !check.id.isEmpty, !check.recordedBy.isEmpty, check.recordedAt.timeIntervalSince1970.isFinite,
                      let context = entry.contexts.first(where: { $0.id == check.contextID }),
                      context.digest == check.contextDigest,
                      try text(check.note, title: "核对备注", limit: 2000) == check.note else {
                    throw VideoError.invalid("许可核对与保存的条件版本不一致")
                }
            }
        }
    }
}

public extension Repository {
    func upstreamLicenseAssessment(access: WorkspaceAccessContext) throws -> UpstreamLicenseAssessment {
        try UpstreamLicenseRules.assessment(access: access, in: read())
    }
    @discardableResult
    func updateUpstreamLicenseContext(_ context: UpstreamLicenseContext, access: WorkspaceAccessContext,
                                      expectedGeneration: Int) throws -> UpstreamLicenseContextRevision {
        try transaction(expectedGeneration: expectedGeneration) {
            try UpstreamLicenseRules.update(context, access: access, in: &$0)
        }
    }
    @discardableResult
    func recordUpstreamLicenseCheck(contextID: String, contextDigest: String, note: String,
                                    access: WorkspaceAccessContext, expectedGeneration: Int) throws -> UpstreamLicenseCheck {
        try transaction(expectedGeneration: expectedGeneration) {
            try UpstreamLicenseRules.recordCheck(contextID: contextID, contextDigest: contextDigest,
                note: note, access: access, in: &$0)
        }
    }
}
