import Foundation
import VideoCore

/// User-initiated adapter for an existing Baidu account. No retries, invented
/// idempotency/cancel endpoint, purchase, free quota, or automatic publication.
public enum BaiduVideoProvider {
    public static func submit(repository:Repository,workspaceID:String,projectID:String,profileID:String,input:BaiduVideoInput,quote:Quote,requestID:String,principal:String) async throws->Job {
        let snapshot=try repository.read();guard try snapshot.workspace(workspaceID).owner==principal,let profile=snapshot.providers.first(where:{$0.id==profileID}) else{throw VideoError.permission("当前本机所有者或百度配置不可用")}
        try BaiduVideoRules.validate(profile:profile);let body=try BaiduVideoRules.requestBody(input:input)
        // A known replay needs no credential access and can never create a new request.
        if let old=snapshot.jobs.first(where:{$0.workspaceID==workspaceID && $0.requestKey==requestID}) {guard old.projectID==projectID,old.quote.id==quote.id,old.videoGeneration?.inputDigest==(try input.digest()) else{throw VideoError.conflict("原request_id与此次生成内容不符")};return try RemoteJobs.checkedTarget(original:old,profile:profile,database:snapshot,principal:principal,command:"baidu submit",ownerOnly:true)}
        let token=try SecureCredentials.read(profile.keyReference)
        let prepared=try repository.transaction {db->(job:Job,shouldSubmit:Bool) in
            guard let live=db.providers.first(where:{$0.id==profileID}),try RemoteJobs.profileIdentity(live)==RemoteJobs.profileIdentity(profile) else{throw VideoError.conflict("百度服务配置已变化，请重新核对上传范围与报价")}
            return try BaiduVideoRules.prepare(database:&db,workspaceID:workspaceID,projectID:projectID,profile:live,input:input,quote:quote,requestID:requestID,principal:principal)
        }
        guard prepared.shouldSubmit else{return prepared.job}
        do {
            _ = try RemoteJobs.checkedTarget(original:prepared.job,profile:profile,database:repository.read(),principal:principal,command:"baidu submit",ownerOnly:true)
            let data=try await api(path:BaiduVideoRules.materialPath,body:body,token:token)
            let result=try BaiduVideoRules.createResponse(data)
            return try update(repository:repository,original:prepared.job,profile:profile,principal:principal,command:"baidu submit"){job,_ in job=try BaiduVideoRules.applyCreated(result,to:job)}
        } catch {
            _ = try? update(repository:repository,original:prepared.job,profile:profile,principal:principal,command:"baidu submit"){job,_ in
                guard job.remoteID==nil else{throw VideoError.conflict("原百度任务已绑定远端ID，未覆盖原结果")}
                job.state = .unknownRemote;job.videoGeneration?.phase = .unknown;job.message="百度创建响应未确认，可能已接单或扣点；保留预算，禁止重复提交，需从供应商记录核对原ID/账单";job.updatedAt=Date()
            }
            // Never expose URLSession's URL/userInfo: its query contains access_token.
            throw VideoError.unavailable("百度创建结果不确定；保留原任务和预算，不重交。请在官方账户核对原任务及账单")
        }
    }
    public static func refresh(repository:Repository,workspaceID:String,jobID:String,principal:String) async throws->Job {
        let context=try authorized(repository:repository,workspaceID:workspaceID,jobID:jobID,principal:principal,command:"baidu query")
        let response=try await query(profile:context.profile,job:context.job)
        return try update(repository:repository,original:context.job,profile:context.profile,principal:principal,command:"baidu query"){job,_ in job=try BaiduVideoRules.applyQuery(response,to:job)}
    }
    public static func querySnapshot(profile:ProviderProfile,job:Job) async throws->RemoteSnapshot {try await query(profile:profile,job:job).snapshot(job:job)}
    /// Only query requests repeat. material POST is never reached by this method.
    public static func query(profile:ProviderProfile,job:Job) async throws->BaiduQueryResponse {
        try BaiduVideoRules.validate(profile:profile)
        guard job.quote.provider==profile.id,job.videoGeneration?.contractVersion==BaiduVideoRules.version,let id=job.remoteID else{throw VideoError.unavailable("缺少原百度字符串ID；未知创建结果不能用数字或新请求替代")}
        let token=try SecureCredentials.read(profile.keyReference),body=try BaiduVideoRules.queryBody(remoteID:id)
        let data=try await api(path:BaiduVideoRules.queryPath,body:body,token:token)
        return try BaiduVideoRules.queryResponse(data)
    }
    /// Recovers the actual MP4 into ordinary local CAS. This job creates a source
    /// clip, not the four-part final deliverable; editing and rights review follow.
    public static func collect(repository:Repository,workspaceID:String,jobID:String,principal:String) async throws->Job {
        let context=try authorized(repository:repository,workspaceID:workspaceID,jobID:jobID,principal:principal,command:"baidu collect")
        if let ids=context.job.outputAssetIDs,!ids.isEmpty {
            let database=try repository.read(),current=try RemoteJobs.checkedTarget(original:context.job,profile:context.profile,database:database,principal:principal,command:"baidu collect",ownerOnly:true)
            try verifyCollected(job:current,database:database,repository:repository);return current
        }
        let response=try await query(profile:context.profile,job:context.job)
        guard response.state == .ready,let address=response.videoAddress else{_ = try update(repository:repository,original:context.job,profile:context.profile,principal:principal,command:"baidu collect"){job,_ in job=try BaiduVideoRules.applyQuery(response,to:job)};throw VideoError.unavailable("百度原任务尚无可回收的有效MP4；未创建新请求")}
        let token=Codec.id(),now=Date()
        let claimed=try update(repository:repository,original:context.job,profile:context.profile,principal:principal,command:"baidu collect"){job,_ in
            guard var receipt=job.videoGeneration else{throw VideoError.permission("原任务生成凭据不可用")}
            guard job.outputAssetIDs?.isEmpty ?? true else{throw VideoError.conflict("原任务已回收，请读取已有素材")}
            guard receipt.collectionToken==nil || (receipt.collectionExpiresAt ?? .distantPast)<=now else{throw VideoError.unavailable("原成片已有回收进程，等待原结果，不能重复下载")}
            job=try BaiduVideoRules.applyQuery(response,to:job);receipt=job.videoGeneration!;receipt.collectionToken=token;receipt.collectionExpiresAt=now.addingTimeInterval(240);job.videoGeneration=receipt
        }
        defer{try? releaseCollection(repository:repository,original:claimed,profile:context.profile,principal:principal,token:token)}
        let url=try BaiduVideoRules.safeHTTPS(address,allowQuery:true),maximum=256*1024*1024
        let configuration=URLSessionConfiguration.ephemeral;configuration.httpShouldSetCookies=false;configuration.httpCookieStorage=nil;configuration.urlCache=nil;configuration.timeoutIntervalForResource=180
        let guardrail=BaiduDownloadGuard(origin:url,maximumBytes:Int64(maximum)),session=URLSession(configuration:configuration,delegate:guardrail,delegateQueue:nil);defer{session.invalidateAndCancel()}
        var request=URLRequest(url:url,timeoutInterval:60);request.httpMethod="GET"
        let downloaded:URL,responseHeader:URLResponse
        do{(downloaded,responseHeader)=try await session.download(for:request,delegate:guardrail)}catch{throw VideoError.unavailable("原百度成片下载未完成；可查询原ID后再次回收，不重新生成")}
        defer{try? FileManager.default.removeItem(at:downloaded)}
        guard let http=responseHeader as? HTTPURLResponse,(200..<300).contains(http.statusCode),(responseHeader.expectedContentLength<=Int64(maximum) || responseHeader.expectedContentLength<0) else{throw VideoError.unavailable("原成片地址失效或超过本地256MiB素材上限；需核对原结果")}
        let attrs=try FileManager.default.attributesOfItem(atPath:downloaded.path);guard let size=attrs[.size] as? NSNumber,size.intValue>0,size.intValue<=maximum else{throw VideoError.invalid("原成片为空或超出素材大小上限")}
        let directory=repository.root.appendingPathComponent("cache/baidu",isDirectory:true),staged=directory.appendingPathComponent(jobID+"-"+token+".mp4")
        try PluginHost.validateOutput(path:staged,root:repository.root);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try FileManager.default.moveItem(at:downloaded,to:staged);defer{try? FileManager.default.removeItem(at:staged)}
        _ = try RemoteJobs.checkedTarget(original:claimed,profile:context.profile,database:repository.read(),principal:principal,command:"baidu collect",ownerOnly:true)
        var asset=try await MaterialImporter.importFile(staged,workspaceID:workspaceID,repository:repository)
        guard asset.mediaType=="video",let frames=asset.durationFrames,frames>0,let receipt=claimed.videoGeneration else{throw VideoError.invalid("下载内容不能解析为具有真实时长的视频素材")}
        asset.name="百度AI成片-"+jobID+".mp4";asset.generatedSource=GeneratedAssetSource(job:claimed,receipt:receipt)
        let evidence=Evidence(workspaceID:workspaceID,title:"百度生成素材权利待核",source:BaiduVideoRules.documentation,claim:"原生成任务及输入摘要已保留；需人工检查声音、内容与第三方素材权利，不证明商业授权或事实正确",owner:"用户自带百度账户（权利待核）",commercialAllowed:false,uploadConsent:false,verified:false,assetID:asset.id)
        asset.evidenceID=evidence.id
        return try update(repository:repository,original:claimed,profile:context.profile,principal:principal,command:"baidu collect"){job,db in
            guard job.videoGeneration?.collectionToken==token,(job.videoGeneration?.collectionExpiresAt ?? .distantPast)>Date(),job.outputAssetIDs?.isEmpty ?? true else{throw VideoError.conflict("原任务回收权已变化或过期，未覆盖已有结果")}
            db.assets.append(asset);db.evidence.append(evidence);job.outputAssetIDs=[asset.id];job.videoGeneration?.phase = .collected;job.videoGeneration?.collectionToken=nil;job.videoGeneration?.collectionExpiresAt=nil;job.state = .billingPending;job.updatedAt=Date();job.message="真实MP4已回收为本地待核素材；可在普通编辑器与精确文字混合。现金须对账，尚未通过权利/声音/整片审核"
        }
    }
    private static func verifyCollected(job:Job,database:Database,repository:Repository)throws {
        for id in job.outputAssetIDs ?? [] {guard let asset=database.assets.first(where:{$0.id==id && $0.workspaceID==job.workspaceID}),asset.generatedSource?.sourceJobID==job.id,asset.generatedSource?.promptDigest==job.videoGeneration?.inputDigest else{throw VideoError.review("已有回收素材的作用域或来源摘要不符")};let bytes=try Data(contentsOf:repository.assetURL(asset),options:.mappedIfSafe);guard bytes.count==asset.bytes,Codec.hash(bytes)==asset.hash else{throw VideoError.review("已有回收素材缺失或摘要变化；先核对原素材")}}
    }
    private static func authorized(repository:Repository,workspaceID:String,jobID:String,principal:String,command:String)throws->(job:Job,profile:ProviderProfile) {
        let db=try repository.read();guard let job=db.jobs.first(where:{$0.id==jobID && $0.workspaceID==workspaceID}),let profile=db.providers.first(where:{$0.id==job.quote.provider}),job.videoGeneration != nil else{throw VideoError.permission("百度原任务或本机所有者权限不可用")}
        let current=try RemoteJobs.checkedTarget(original:job,profile:profile,database:db,principal:principal,command:command,ownerOnly:true)
        try BaiduVideoRules.validate(profile:profile);return(current,profile)
    }
    /// All remote-response and late-cleanup writes use the current authorized
    /// target in the same transaction; rejected callbacks leave generation intact.
    static func update(repository:Repository,original:Job,profile:ProviderProfile,principal:String,command:String,mutation:(inout Job,inout Database)throws->Void)throws->Job {
        guard ["baidu submit","baidu query","baidu collect"].contains(command) else{throw VideoError.permission("此入口只接受原百度任务操作")}
        return try repository.transaction{db in
            var current=try RemoteJobs.checkedTarget(original:original,profile:profile,database:db,principal:principal,command:command,ownerOnly:true)
            guard let index=db.jobs.firstIndex(where:{$0.id==current.id && $0.workspaceID==current.workspaceID}) else{throw VideoError.notFound("原百度任务不存在")}
            try mutation(&current,&db)
            db.jobs[index]=current
            return current
        }
    }
    static func releaseCollection(repository:Repository,original:Job,profile:ProviderProfile,principal:String,token:String)throws {
        _ = try update(repository:repository,original:original,profile:profile,principal:principal,command:"baidu collect"){job,_ in
            guard job.videoGeneration?.collectionToken==token else{throw VideoError.conflict("原回收租约已变化，未清理其它执行端的租约")}
            job.videoGeneration?.collectionToken=nil;job.videoGeneration?.collectionExpiresAt=nil
        }
    }
    private static func api(path:String,body:Data,token:String) async throws->Data {
        guard [BaiduVideoRules.materialPath,BaiduVideoRules.queryPath].contains(path) else{throw VideoError.invalid("百度接口路径不在固定合同内")}
        var components=URLComponents(string:BaiduVideoRules.origin+path)!;components.queryItems=[URLQueryItem(name:"access_token",value:token)]
        var request=URLRequest(url:components.url!,timeoutInterval:60);request.httpMethod="POST";request.httpBody=body;request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        // Official contract has no Idempotency-Key or Authorization header.
        let config=URLSessionConfiguration.ephemeral;config.httpShouldSetCookies=false;config.httpCookieStorage=nil;config.urlCache=nil;config.timeoutIntervalForResource=70
        let session=URLSession(configuration:config,delegate:BaiduNoRedirect(),delegateQueue:nil);defer{session.invalidateAndCancel()}
        do{let(data,response)=try await session.data(for:request);guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),data.count<=1_048_576 else{throw VideoError.unavailable("百度响应未确认，原任务保留，不自动重交")};return data}
        catch{throw VideoError.unavailable("百度网络或响应未确认；不输出请求地址或凭据，不自动重交")}
    }
}
private final class BaiduNoRedirect:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
private final class BaiduDownloadGuard:NSObject,URLSessionDownloadDelegate,@unchecked Sendable {
    let origin:URL;let maximumBytes:Int64
    init(origin:URL,maximumBytes:Int64){self.origin=origin;self.maximumBytes=maximumBytes}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL){}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64){if totalBytesWritten>maximumBytes || totalBytesExpectedToWrite>maximumBytes{downloadTask.cancel()}}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){guard let url=request.url,url.scheme=="https",url.host==origin.host,url.port==origin.port,url.user==nil,url.password==nil else{completionHandler(nil);return};completionHandler(request)}
}
