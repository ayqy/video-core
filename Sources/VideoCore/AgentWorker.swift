import Foundation

/// A finite worker never creates a job or submits a provider request. The original
/// job and its request key remain the only source of execution/billing identity.
public struct AgentWorkerPlan: Codable, Equatable, Sendable {
    public var workspaceID:String; public var jobIDs:[String]; public var maximumJobs:Int
    public var timeoutSeconds:Int; public var resumeInterrupted:Bool; public var queryRemote:Bool
    public init(workspaceID:String,jobIDs:[String]=[],maximumJobs:Int=5,timeoutSeconds:Int=300,resumeInterrupted:Bool=false,queryRemote:Bool=false) throws {
        guard !workspaceID.isEmpty,(1...25).contains(maximumJobs),(5...3600).contains(timeoutSeconds),jobIDs.count<=25,Set(jobIDs).count==jobIDs.count,jobIDs.allSatisfy({!$0.isEmpty && $0.utf8.count<=200 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)}) else{throw VideoError.invalid("worker批次须为1—25项，时限5—3600秒，原任务ID不可重复或含控制字符")}
        self.workspaceID=workspaceID;self.jobIDs=jobIDs;self.maximumJobs=maximumJobs;self.timeoutSeconds=timeoutSeconds;self.resumeInterrupted=resumeInterrupted;self.queryRemote=queryRemote
    }
    public func select(database:Database,principal:String,now:Date=Date()) throws->[String] {
        let workspace=try database.workspace(workspaceID);guard workspace.owner==principal else{throw VideoError.permission("本机worker仅限工作区所有者；不是远程认证入口")}
        for id in jobIDs {guard database.jobs.contains(where:{$0.id==id && $0.workspaceID==workspaceID}) else{throw VideoError.permission("批次原任务不存在或属于另一工作区")}}
        return Array(database.jobs.filter {job in
            guard job.workspaceID==workspaceID,(jobIDs.isEmpty || jobIDs.contains(job.id)) else{return false}
            if !jobIDs.isEmpty{return true}
            if job.quote.provider != "native" {return queryRemote && [.queued,.running,.unknownRemote,.cancelRequested,.billingPending].contains(job.state)}
            let recovered=JobOperations.recoverExpired(job,now:now)
            return recovered.state == .queued || (resumeInterrupted && [.interrupted,.failed].contains(recovered.state))
        }.sorted{$0.createdAt==$1.createdAt ? $0.id<$1.id:$0.createdAt<$1.createdAt}.prefix(maximumJobs).map(\.id))
    }
    public enum Action:Equatable,Sendable {case run,query,skip(String)}
    public func action(for job:Job,now:Date=Date())->Action {
        guard job.workspaceID==workspaceID else{return .skip("工作区不符")}
        if job.quote.provider != "native" {return queryRemote && [.queued,.running,.unknownRemote,.cancelRequested,.billingPending].contains(job.state) ? .query:.skip("远端仅可显式查询原ID，不重新提交")}
        let current=JobOperations.recoverExpired(job,now:now)
        if current.state == .queued{return .run}
        if resumeInterrupted && [.interrupted,.failed].contains(current.state){return .run}
        return .skip(current.state == .cancelled ? "已取消；worker不会恢复已取消任务":"原任务状态不允许认领")
    }
    public static func interruptOwned(database:inout Database,owner:String,now:Date=Date()) {
        for i in database.jobs.indices where database.jobs[i].state == .running && database.jobs[i].quote.provider=="native" && database.jobs[i].lease?.owner==owner {
            database.jobs[i].state = .interrupted;database.jobs[i].lease=nil;database.jobs[i].updatedAt=now;database.jobs[i].message="有限worker停止或超时；保留原任务与缓存，可显式续跑"
        }
    }
    /// Repository callers use this scoped form and commit only when it returns
    /// true. A shared worker request key never grants access to another workspace.
    public static func interruptOwned(database:inout Database,owner:String,workspaceID:String,principal:String,now:Date=Date())throws->Bool {
        let workspaces=database.workspaces.filter{$0.id==workspaceID}
        guard !owner.isEmpty,workspaces.count==1,workspaces.first?.owner==principal else{throw VideoError.permission("原worker工作区所有者权限已变化，未中断任何任务")}
        var changed=false
        for i in database.jobs.indices where database.jobs[i].workspaceID==workspaceID && database.jobs[i].state == .running && database.jobs[i].quote.provider=="native" && database.jobs[i].lease?.owner==owner {
            database.jobs[i].state = .interrupted;database.jobs[i].lease=nil;database.jobs[i].updatedAt=now;database.jobs[i].message="有限worker停止或超时；保留原任务与缓存，可显式续跑";changed=true
        }
        return changed
    }
}
