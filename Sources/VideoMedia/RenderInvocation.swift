import Foundation
import VideoCore

/// Cancellation must also cross synchronous drawing queues, where Task.isCancelled
/// alone does not describe the task which originally requested the frame.
public final class RenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// A Host-only capability. Its authorization closure and database never cross IPC.
/// The child receives the bounded visual projection and these opaque scope IDs.
public struct RenderInvocation: @unchecked Sendable {
    public let id: String
    public let workspaceID: String
    public let projectID: String
    public let revisionID: String
    public let revisionDigest: String
    public let jobID: String?
    public let budgetReference: String
    public let budgetLimit: Money
    public var currency: String { budgetLimit.currency }
    public let deadline: Date
    public let cancellation: RenderCancellation
    private let authorize: @Sendable () throws -> Void

    public init(id: String = Codec.id(), workspaceID: String, projectID: String, revisionID: String, revisionDigest: String, jobID: String?, budgetReference: String, budgetLimit: Money, deadline: Date, cancellation: RenderCancellation = RenderCancellation(), authorization: @escaping @Sendable () throws -> Void) {
        self.id=id; self.workspaceID=workspaceID; self.projectID=projectID; self.revisionID=revisionID; self.revisionDigest=revisionDigest; self.jobID=jobID; self.budgetReference=budgetReference; self.budgetLimit=budgetLimit; self.deadline=deadline; self.cancellation=cancellation; authorize=authorization
    }

    public func check(now: Date = Date()) throws {
        guard [id,workspaceID,projectID,revisionID,budgetReference].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }), jobID == nil || (!jobID!.isEmpty && jobID!.utf8.count <= 256), revisionDigest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil, currency.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil, !budgetLimit.amount.isNaN, budgetLimit.amount >= 0, deadline.timeIntervalSince1970.isFinite else { throw VideoError.permission("插件任务范围、版本摘要或预算凭据不合法") }
        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
        guard deadline > now else { throw VideoError.unavailable("插件任务已到截止时间，未接受迟到结果") }
        try authorize()
        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
    }

    public func verify(revision: Revision) throws {
        try check()
        guard revision.workspaceID == workspaceID, revision.id == revisionID, try revision.contentDigest() == revisionDigest else { throw VideoError.conflict("插件任务不属于当前冻结版本") }
    }

    /// A preview is a local zero-supplier-cash operation. Recheck the caller's
    /// current grant on every use, including after an in-flight reply arrives.
    public static func preview(repository: Repository, projectID: String, revision: Revision, access: WorkspaceAccessContext, cancellation: RenderCancellation = RenderCancellation(), deadline: Date = Date().addingTimeInterval(30)) throws -> RenderInvocation {
        let digest = try revision.contentDigest(), database = try repository.read()
        let nonce = Codec.id()
        let scope = RenderInvocation(id: nonce, workspaceID: access.workspaceID, projectID: projectID, revisionID: revision.id, revisionDigest: digest, jobID: nil, budgetReference: "preview:"+nonce, budgetLimit: Money(0,database.budget.project.currency), deadline: deadline, cancellation: cancellation) {
            let (_, stored) = try WorkspaceAccessRules.revision(projectID:projectID,revisionID:revision.id,access:access,in:repository.read())
            guard try stored.contentDigest() == digest else { throw VideoError.conflict("预览版本已改变，请重新选择当前版本") }
        }
        try scope.verify(revision:revision)
        return scope
    }

    /// Only an already-claimed native job can create this scope. Lease recovery,
    /// cancellation, workspace changes and version edits revoke it immediately.
    static func job(repository: Repository, claimed: Job, revision: Revision, token: String, cancellation: RenderCancellation) throws -> RenderInvocation {
        let scope = RenderInvocation(workspaceID:claimed.workspaceID,projectID:claimed.projectID,revisionID:claimed.revisionID,revisionDigest:claimed.digest,jobID:claimed.id,budgetReference:claimed.quote.id,budgetLimit:claimed.quote.upper,deadline:Date().addingTimeInterval(4*60*60),cancellation:cancellation) {
            let database = try repository.read()
            guard let current = database.jobs.first(where:{$0.id == claimed.id}), current.state == .running, current.lease?.token == token, let expires = current.lease?.expiresAt, expires > Date(), current.workspaceID == claimed.workspaceID, current.projectID == claimed.projectID, current.revisionID == claimed.revisionID, current.digest == claimed.digest, current.quote.id == claimed.quote.id, current.quote.upper == claimed.quote.upper, current.quote.provider == "native" else { throw VideoError.permission("制作任务已取消、租约失效或预算凭据改变，插件结果未接受") }
            let project = try database.project(current.projectID)
            guard project.workspaceID == current.workspaceID, let stored = project.revisions.first(where:{$0.id == current.revisionID}), try stored.contentDigest() == current.digest else { throw VideoError.conflict("制作任务的冻结版本已变化") }
        }
        try scope.verify(revision:revision)
        return scope
    }
}
