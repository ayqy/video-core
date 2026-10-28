import Foundation

extension JobRules {
    /// Resume an existing local job inside the repository transaction. This is
    /// an owner operation on its frozen input, not a new edit or submission.
    public static func resumeLocal(observing original: Job, in database: inout Database,
                                   workspaceID: String, projectID: String, revisionID: String,
                                   principal: String, now: Date = Date()) throws -> Job {
        let workspace = try database.workspace(workspaceID)
        guard !principal.isEmpty, workspace.owner == principal else {
            throw VideoError.permission("原本机任务恢复仅限当前工作区所有者")
        }
        guard let project = database.projects.first(where: { $0.id == projectID && $0.workspaceID == workspaceID }),
              project.current.id == revisionID, project.current.workspaceID == workspaceID,
              let index = database.jobs.firstIndex(where: { $0.id == original.id && $0.workspaceID == workspaceID }) else {
            throw VideoError.conflict("目标工程、当前版本或原本机任务已变化，请刷新原任务")
        }
        let current = database.jobs[index]
        let digest = try project.current.contentDigest()
        guard current.projectID == projectID, current.revisionID == revisionID, current.digest == digest,
              current.quote.projectID == projectID, current.quote.revisionID == revisionID,
              current.quote.digest == digest, current.quote.provider == "native", current.quote.confirmed,
              !current.requestKey.isEmpty, current.remoteID == nil, current.videoGeneration == nil,
              original.id == current.id, original.workspaceID == current.workspaceID,
              original.projectID == current.projectID, original.revisionID == current.revisionID,
              original.digest == current.digest, original.requestKey == current.requestKey,
              original.remoteID == current.remoteID, original.videoGeneration == nil,
              try Codec.digest(original.createdAt) == Codec.digest(current.createdAt),
              try Codec.digest(original.quote) == Codec.digest(current.quote) else {
            throw VideoError.conflict("原任务身份、冻结输入或完整报价已变化；未创建替代任务")
        }
        guard [.queued, .failed, .interrupted].contains(current.state), current.state == original.state,
              current.attempt == original.attempt, current.progress == original.progress,
              try Codec.digest(current.updatedAt) == Codec.digest(original.updatedAt),
              try Codec.digest(current.lease) == Codec.digest(original.lease),
              try Codec.digest(current.artifacts) == Codec.digest(original.artifacts),
              (current.outputAssetIDs ?? []) == (original.outputAssetIDs ?? []),
              current.lease == nil || current.lease!.expiresAt <= now else {
            throw VideoError.conflict("原任务已有较新执行、取消、完成或租约状态，请读取当前结果")
        }
        if current.state == .queued { return current }
        let resumed = try recover(current)
        database.jobs[index] = resumed
        return resumed
    }
}
