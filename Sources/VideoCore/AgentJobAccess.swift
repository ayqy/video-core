import Foundation

/// No quote, billing, provider/remote reference, request key, message, filesystem
/// path or revision history is present in this collaborative read model.
public struct ScopedJobDTO:Codable,Sendable {
    public var id:String;public var projectID:String;public var revisionID:String
    public var state:JobState;public var progress:Double;public var artifacts:[ScopedArtifact]
}
public enum AgentJobStatusResult:Sendable {
    case owner(Job),restricted(ScopedJobDTO)
    public func value()throws->AgentValue {switch self{case .owner(let job):return try Codec.decoder().decode(AgentValue.self,from:Codec.data(job));case .restricted(let dto):return try Codec.decoder().decode(AgentValue.self,from:Codec.data(dto))}}
}
public enum AgentJobAccess {
    /// The permission is checked anew for the job's actual immutable revision,
    /// rather than the project's latest revision or a caller-supplied scope.
    public static func status(jobID:String,workspaceID:String,database:Database,principal:String,now:Date=Date())throws->AgentJobStatusResult {
        let workspace=try database.workspace(workspaceID),owner=workspace.owner==principal
        guard let job=database.jobs.first(where:{$0.id==jobID && $0.workspaceID==workspaceID}) else{if owner{throw VideoError.notFound("原任务不属于此工作区或不存在")};throw VideoError.permission("没有指定原任务与版本的有效读取权限")}
        try AgentContract.authorize(command:"jobs status",workspace:workspace,principal:principal,projectID:job.projectID,revisionID:job.revisionID,now:now)
        guard let project=database.projects.first(where:{$0.id==job.projectID && $0.workspaceID==workspaceID}),let revision=project.revisions.first(where:{$0.id==job.revisionID}),try revision.contentDigest()==job.digest else{throw VideoError.conflict("原任务的指定版本或摘要不一致，未返回其他版本")}
        if owner{return .owner(job)}
        let outputTypes:Set<String>=["video/mp4","image/png","application/x-subrip","text/plain"]
        guard job.progress.isFinite,(0...1).contains(job.progress),job.artifacts.allSatisfy({$0.revision==job.revisionID && outputTypes.contains($0.mime) && ($0.bytes>0 || ($0.bytes==0 && $0.mime=="application/x-subrip")) && $0.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}) else{throw VideoError.permission("原任务或产物未绑定获准版本，或产物摘要格式无效；未返回其他版本内容")}
        let artifacts=job.artifacts.map{ScopedArtifact(id:job.id+":"+$0.sha256,jobID:job.id,mime:$0.mime,sha256:$0.sha256,bytes:$0.bytes)}
        return .restricted(ScopedJobDTO(id:job.id,projectID:job.projectID,revisionID:job.revisionID,state:job.state,progress:job.progress,artifacts:artifacts))
    }
}
