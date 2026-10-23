import Foundation
import VideoCore

/// Explicit adapter for a user-configured server implementing our job-status DTO.
/// A chat-completions URL is not silently treated as an asynchronous job API.
public enum RemoteJobs {
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
