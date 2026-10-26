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
    /// Revalidate the original remote target at the point of use or commit.
    /// State, progress and billing may legitimately change while a request waits;
    /// its authority, immutable input and provider binding may not.
    public static func remoteTarget(original:Job,database:Database,principal:String,command:String,now:Date=Date())throws->Job {
        let commands:Set<String>=["jobs query","jobs remote-cancel","worker run","baidu submit","baidu query","baidu collect"]
        guard commands.contains(command) else{throw VideoError.permission("此命令不支持远端任务权限复核")}
        let workspaces=database.workspaces.filter{$0.id==original.workspaceID}
        let jobs=database.jobs.filter{$0.id==original.id}
        guard workspaces.count==1,jobs.count==1,let workspace=workspaces.first,let current=jobs.first,
              current.workspaceID==original.workspaceID,current.projectID==original.projectID,
              current.revisionID==original.revisionID,current.digest==original.digest,
              current.requestKey==original.requestKey,
              let originalCreated=try? Codec.digest(original.createdAt),let currentCreated=try? Codec.digest(current.createdAt),originalCreated==currentCreated,
              current.remoteID==original.remoteID,
              let originalQuote=try? Codec.digest(original.quote),let currentQuote=try? Codec.digest(current.quote),originalQuote==currentQuote,
              current.quote.projectID==current.projectID,current.quote.revisionID==current.revisionID,
              current.quote.digest==current.digest,current.quote.provider != "native" else {
            throw VideoError.conflict("原远端任务的工作区、版本、请求或报价绑定已变化")
        }
        try AgentContract.authorize(command:command,workspace:workspace,principal:principal,projectID:current.projectID,revisionID:current.revisionID,now:now)
        let projects=database.projects.filter{$0.id==current.projectID && $0.workspaceID==current.workspaceID}
        guard projects.count==1,let project=projects.first else{throw VideoError.conflict("原远端任务的工程不可用或绑定不唯一")}
        let revisions=project.revisions.filter{$0.id==current.revisionID}
        guard revisions.count==1,let revision=revisions.first,let digest=try? revision.contentDigest(),digest==current.digest else{throw VideoError.conflict("原远端任务的指定版本或内容摘要已变化")}
        let providers=database.providers.filter{$0.id==current.quote.provider}
        guard providers.count==1,let provider=providers.first,(try? provider.validate()) != nil else{throw VideoError.permission("原远端任务的服务配置不可用或绑定不唯一")}
        switch (original.videoGeneration,current.videoGeneration) {
        case (nil,nil):
            guard !command.hasPrefix("baidu ") else{throw VideoError.conflict("原百度任务缺少生成输入凭据")}
        case (.some(let before),.some(let live)):
            guard before.contractVersion==live.contractVersion,before.model==live.model,
                  before.inputDigest==live.inputDigest,
                  let beforeStarted=try? Codec.digest(before.startedAt),let liveStarted=try? Codec.digest(live.startedAt),beforeStarted==liveStarted,
                  live.contractVersion==BaiduVideoRules.version,live.model==provider.model,
                  live.inputDigest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
                  (try? BaiduVideoRules.validate(profile:provider)) != nil else{throw VideoError.conflict("原生成任务的输入、合同或服务绑定已变化")}
        default:throw VideoError.conflict("原生成任务的输入凭据已变化")
        }
        return current
    }
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
