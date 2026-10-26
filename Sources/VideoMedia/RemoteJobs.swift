import Foundation
import VideoCore

/// Explicit adapter for a user-configured server implementing our job-status DTO.
/// A chat-completions URL is not silently treated as an asynchronous job API.
public enum RemoteJobs {
    /// Repository-backed callers recheck the current grant and immutable target
    /// inside the same transaction that accepts the remote response.
    public static func query(repository:Repository,workspaceID:String,jobID:String,principal:String,authorizationCommand:String="jobs query",ownerOnly:Bool=false) async throws -> Job {
        guard ["jobs query","worker run"].contains(authorizationCommand) else{throw VideoError.invalid("远端查询调用身份无效")}
        return try await operate(repository:repository,workspaceID:workspaceID,jobID:jobID,principal:principal,command:authorizationCommand,cancel:false,ownerOnly:ownerOnly)
    }
    public static func cancel(repository:Repository,workspaceID:String,jobID:String,principal:String,ownerOnly:Bool=false) async throws -> Job {
        return try await operate(repository:repository,workspaceID:workspaceID,jobID:jobID,principal:principal,command:"jobs remote-cancel",cancel:true,ownerOnly:ownerOnly)
    }
    private static func operate(repository:Repository,workspaceID:String,jobID:String,principal:String,command:String,cancel:Bool,ownerOnly:Bool) async throws -> Job {
        try Task.checkCancellation()
        let database=try repository.read()
        guard let original=database.jobs.first(where:{$0.id==jobID && $0.workspaceID==workspaceID}),
              let profile=database.providers.first(where:{$0.id==original.quote.provider}) else{throw VideoError.notFound("原任务或服务配置不可用")}
        _ = try checkedTarget(original:original,profile:profile,database:database,principal:principal,command:command,ownerOnly:ownerOnly)
        let prepared:Job
        if cancel {
            try requireCancellationSupport(profile:profile)
            prepared=try repository.transaction{db in
                let current=try checkedTarget(original:original,profile:profile,database:db,principal:principal,command:command,ownerOnly:ownerOnly)
                let changed=JobRules.cancel(current)
                db.jobs[db.jobs.firstIndex(where:{$0.id==current.id && $0.workspaceID==workspaceID})!]=changed
                return changed
            }
        }else{prepared=original}
        try Task.checkCancellation()
        if !cancel,profile.kind==BaiduVideoRules.kind {
            // The common Mac/CLI/worker query must retain the supplier's original
            // units and receipt lifecycle, not narrow the response to status only.
            let response=try await BaiduVideoProvider.query(profile:profile,job:prepared)
            try Task.checkCancellation()
            return try acceptBaiduQuery(response,original:prepared,profile:profile,repository:repository,principal:principal,command:command,ownerOnly:ownerOnly)
        }
        let snapshot=try await (cancel ? self.cancel(profile:profile,job:prepared):self.query(profile:profile,job:prepared))
        try Task.checkCancellation()
        return try accept(snapshot,original:prepared,profile:profile,repository:repository,principal:principal,command:command,ownerOnly:ownerOnly)
    }
    static func checkedTarget(original:Job,profile:ProviderProfile,database:Database,principal:String,command:String,ownerOnly:Bool=false)throws->Job {
        if ownerOnly {guard try database.workspace(original.workspaceID).owner==principal else{throw VideoError.permission("原任务操作仅限当前工作区所有者")}}
        let current=try AgentJobAccess.remoteTarget(original:original,database:database,principal:principal,command:command)
        guard let live=database.providers.first(where:{$0.id==profile.id}),try profileIdentity(live)==profileIdentity(profile) else{throw VideoError.conflict("原服务配置已变化，未写入旧响应")}
        return current
    }
    static func profileIdentity(_ profile:ProviderProfile)throws->String {
        try ProviderRules.profileIdentity(profile)
    }
    static func accept(_ snapshot:RemoteSnapshot,original:Job,profile:ProviderProfile,repository:Repository,principal:String,command:String,ownerOnly:Bool=false)throws->Job {
        try repository.transaction{db in
            let current=try checkedTarget(original:original,profile:profile,database:db,principal:principal,command:command,ownerOnly:ownerOnly)
            let changed=try JobOperations.applyRemote(snapshot,to:current)
            db.jobs[db.jobs.firstIndex(where:{$0.id==current.id && $0.workspaceID==current.workspaceID})!]=changed
            return changed
        }
    }
    static func acceptBaiduQuery(_ response:BaiduQueryResponse,original:Job,profile:ProviderProfile,repository:Repository,principal:String,command:String,ownerOnly:Bool=false)throws->Job {
        guard ["jobs query","worker run"].contains(command),profile.kind==BaiduVideoRules.kind else{throw VideoError.permission("完整百度回执仅供原任务查询，不作为取消或其它协议响应")}
        return try repository.transaction{db in
            let current=try checkedTarget(original:original,profile:profile,database:db,principal:principal,command:command,ownerOnly:ownerOnly)
            let changed=try BaiduVideoRules.applyQuery(response,to:current,observing:original)
            db.jobs[db.jobs.firstIndex(where:{$0.id==current.id && $0.workspaceID==current.workspaceID})!]=changed
            return changed
        }
    }
    public static func query(profile: ProviderProfile, job: Job) async throws -> RemoteSnapshot {
        if profile.kind==BaiduVideoRules.kind {return try await BaiduVideoProvider.querySnapshot(profile:profile,job:job)}
        return try await request(profile:profile,job:job,cancel:false)
    }
    public static func cancel(profile: ProviderProfile, job: Job) async throws -> RemoteSnapshot {
        try requireCancellationSupport(profile:profile)
        return try await request(profile:profile,job:job,cancel:true)
    }
    public static func requireCancellationSupport(profile:ProviderProfile)throws {
        if profile.kind==BaiduVideoRules.kind {throw VideoError.unavailable("百度2026-01-05成片合同无取消接口；未发送取消请求，费用与原任务保留待核")}
        guard profile.kind=="video-job-v1",profile.cancelPath != nil else{throw VideoError.unavailable("此服务未配置已核实的远端取消接口；未发送取消，不代表退款或停止计费")}
    }
    private static func request(profile: ProviderProfile, job: Job, cancel: Bool) async throws -> RemoteSnapshot {
        try profile.validate()
        guard profile.kind=="video-job-v1",job.quote.provider==profile.id else { throw VideoError.unavailable("此服务未声明知幕任务查询协议；保留原任务，按官方账单人工对账，不能重交不确定请求") }
        guard let path=cancel ? profile.cancelPath:profile.statusPath, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?"), !path.contains("#"), !path.contains(".."), !path.contains("\\"), let base=URL(string:profile.endpoint), let url=URL(string:path,relativeTo:base)?.absoluteURL, url.scheme==base.scheme,url.host==base.host,url.port==base.port else { throw VideoError.invalid("查询/取消路径必须是原服务同源的绝对路径") }
        var components=URLComponents(url:url,resolvingAgainstBaseURL:false)!
        components.queryItems=[URLQueryItem(name:"request_key",value:job.requestKey)]
        if let id=job.remoteID { components.queryItems?.append(URLQueryItem(name:"remote_id",value:id)) }
        var request=URLRequest(url:components.url!,timeoutInterval:30); request.httpMethod=cancel ? "POST":"GET"
        request.setValue("Bearer "+(try SecureCredentials.read(profile.keyReference)),forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue(job.requestKey,forHTTPHeaderField:"Idempotency-Key")
        let config=URLSessionConfiguration.ephemeral; config.httpShouldSetCookies=false; config.httpCookieStorage=nil; config.urlCache=nil
        let session=URLSession(configuration:config,delegate:SameOriginGuard(origin:base),delegateQueue:nil); defer { session.invalidateAndCancel() }
        let data:Data,response:URLResponse
        do{(data,response)=try await session.data(for:request)}catch{throw VideoError.unavailable("原任务查询未确认，请检查连接或重新绑定本机凭据；未创建新请求，费用仍待核")}
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),data.count<=65536 else { throw VideoError.unavailable("远端查询未确认原任务状态，继续保留预算占用，不创建新请求") }
        guard let snapshot=try? Codec.decoder().decode(RemoteSnapshot.self,from:data) else{throw VideoError.unavailable("原服务的任务状态格式未核实；保留原任务与预算，不自动重交")}
        _ = try JobOperations.applyRemote(snapshot,to:job)
        return snapshot
    }
}
final class SameOriginGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin=origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url=request.url
        completionHandler(url?.scheme==origin.scheme && url?.host==origin.host && url?.port==origin.port ? request:nil)
    }
}
