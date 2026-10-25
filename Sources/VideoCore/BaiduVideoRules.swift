import Foundation

/// Fixed official AI成片 contract, captured 2026-01-05. Availability and account
/// pricing must be checked by the caller; this is not a claim that sales remain open.
public struct BaiduVideoInput:Codable,Equatable,Sendable {
    public struct Media:Codable,Equatable,Sendable {public var type:Int=3;public var url:String;public init(url:String){self.url=url}}
    public struct Segment:Codable,Equatable,Sendable {
        public enum Kind:String,Codable,Sendable {case text,image,video}
        public var type:Kind;public var text:String?;public var mediaSource:Media?
        public init(text:String){type = .text;self.text=text}
        public init(type:Kind,url:String){self.type=type;mediaSource=Media(url:url)}
    }
    public struct Source:Codable,Equatable,Sendable {public var structs:[Segment];public init(_ segments:[Segment]){structs=segments}}
    public struct MediaSetting:Codable,Equatable,Sendable {public var mediaSource:Media;public init(url:String){mediaSource=Media(url:url)}}
    public struct Captions:Codable,Equatable,Sendable {
        public var marginBottom:Int?;public var fontColor:String?;public var fontAlpha:Int?;public var bgColor:String?;public var bgAlpha:Int?
        public init(marginBottom:Int?=nil,fontColor:String?=nil,fontAlpha:Int?=nil,bgColor:String?=nil,bgAlpha:Int?=nil){self.marginBottom=marginBottom;self.fontColor=fontColor;self.fontAlpha=fontAlpha;self.bgColor=bgColor;self.bgAlpha=bgAlpha}
    }
    public struct Logo:Codable,Equatable,Sendable {
        public var mediaSource:Media;public var location:String?;public var margin:Int?
        public init(url:String,location:String?=nil,margin:Int?=nil){mediaSource=Media(url:url);self.location=location;self.margin=margin}
    }
    public struct Config:Codable,Equatable,Sendable {
        public var productType:String="video";public var resolution:[Int];public var ttsPer:Int?;public var templateId:String?
        public var bgMusic:MediaSetting?;public var videoBegin:MediaSetting?;public var videoEnd:MediaSetting?
        public var caption:Captions?;public var videoLogo:Logo?;public var withVoiceBroadcast:Bool?;public var withCaptions:Bool?
        public init(resolution:[Int]=[720,1280]){self.resolution=resolution}
    }
    public var source:Source;public var config:Config
    public init(segments:[Segment],config:Config = Config()){source=Source(segments);self.config=config}
    public func digest()throws->String {try Codec.digest(self)}
}

public struct VideoGenerationReceipt:Codable,Equatable,Sendable {
    public enum Phase:String,Codable,Sendable {case submissionStarted="submission_started",accepted,unknown,failed,collected}
    public var contractVersion:String;public var model:String;public var inputDigest:String;public var phase:Phase
    public var startedAt:Date;public var acceptedAt:Date?;public var checkedAt:Date?
    public var points:Decimal?;public var basicDurationMilliseconds:Int64?;public var digitalHumanDurationMilliseconds:Int64?
    public var collectionToken:String?;public var collectionExpiresAt:Date?
    public init(inputDigest:String,now:Date=Date()){contractVersion=BaiduVideoRules.version;model=BaiduVideoRules.model;self.inputDigest=inputDigest;phase = .submissionStarted;startedAt=now}
}
public struct GeneratedAssetSource:Codable,Equatable,Sendable {
    public var sourceJobID:String;public var providerID:String;public var model:String;public var promptDigest:String;public var contractVersion:String;public var collectedAt:Date
    public init(job:Job,receipt:VideoGenerationReceipt,at:Date=Date()){sourceJobID=job.id;providerID=job.quote.provider;model=receipt.model;promptDigest=receipt.inputDigest;contractVersion=receipt.contractVersion;collectedAt=at}
}
public enum BaiduCreateResponse:Equatable,Sendable {case accepted(String),rejected(Int)}
public struct BaiduQueryResponse:Equatable,Sendable {
    public enum State:Equatable,Sendable {case queued,running,ready,failed,expired,unknown}
    public var state:State;public var progress:Double;public var videoAddress:String?
    public var points:Decimal?;public var basicDurationMilliseconds:Int64?;public var digitalHumanDurationMilliseconds:Int64?
    public var errorCode:Int?
    public init(state:State,progress:Double=0,videoAddress:String?=nil,points:Decimal?=nil,basicDurationMilliseconds:Int64?=nil,digitalHumanDurationMilliseconds:Int64?=nil,errorCode:Int?=nil){self.state=state;self.progress=progress;self.videoAddress=videoAddress;self.points=points;self.basicDurationMilliseconds=basicDurationMilliseconds;self.digitalHumanDurationMilliseconds=digitalHumanDurationMilliseconds;self.errorCode=errorCode}
    public func snapshot(job:Job,now:Date=Date())throws->RemoteSnapshot {
        guard let id=job.remoteID else{throw VideoError.unavailable("百度创建结果未知，缺少原字符串ID；不能重新提交")}
        let mapped:RemoteSnapshot.State
        switch state{case .queued:mapped = .queued;case .running:mapped = .running;case .ready:mapped = .succeeded;case .failed,.expired:mapped = .failed;case .unknown:mapped = .unknown}
        return RemoteSnapshot(remoteID:id,requestKey:job.requestKey,state:mapped,progress:progress,checkedAt:now)
    }
}

public enum BaiduVideoRules {
    public static let kind="baidu-ttv"
    public static let version="2026-01-05"
    public static let model="baidu-ai-ttv-material-2026-01-05"
    public static let documentation="https://ai.baidu.com/ai-doc/NLP/Zk7ylspjv"
    public static let origin="https://aip.baidubce.com"
    public static let materialPath="/rpc/2.0/brain/creative/ttv/material"
    public static let queryPath="/rpc/2.0/brain/creative/ttv/query"
    public static func profile(keyReference:String,allowsUpload:Bool=false)->ProviderProfile {
        var p=ProviderProfile(name:"百度AI成片（已有账户）",endpoint:origin,model:model,supportedParameters:[],allowsUpload:allowsUpload,keyReference:keyReference,kind:kind,statusPath:queryPath,idempotency:false)
        p.capabilities=ProviderCapabilities(version:version,source:documentation,maximumInputCharacters:1000,repairLimit:0)
        return p
    }
    public static func validate(profile:ProviderProfile)throws {
        try profile.validate()
        guard profile.kind==kind,profile.model==model,profile.endpoint==origin,profile.capabilities?.version==version,!profile.idempotency,profile.cancelPath==nil else{throw VideoError.invalid("百度适配仅支持已核对的2026-01-05官方AI成片合同；不支持自定义端点、伪幂等或取消")}
    }
    /// User-controlled URLs must not contain credentials or private/local destinations.
    /// Actual media dimensions and rights remain vendor/user checks, not inferred here.
    public static func safeHTTPS(_ text:String,allowQuery:Bool=false)throws->URL {
        guard text.utf8.count<=8192,let url=URL(string:text),url.scheme=="https",let raw=url.host,url.user==nil,url.password==nil,url.fragment==nil,(allowQuery || url.query==nil),url.port==nil || url.port==443 else{throw VideoError.invalid("素材地址须为不含账号、片段或令牌参数的公网HTTPS地址")}
        let host=raw.lowercased();guard host.contains("."),!host.hasSuffix(".local"),!host.hasSuffix(".localhost"),!host.hasSuffix(".internal"),host != "localhost",host.range(of:"^[0-9.]+$",options:.regularExpression)==nil,!host.contains(":") else{throw VideoError.permission("拒绝本机、内网或数字IP素材地址")};return url
    }
    public static func validate(input:BaiduVideoInput)throws {
        let segments=input.source.structs,media=segments.filter{$0.type != .text},characters=segments.compactMap(\.text).joined().unicodeScalars.count
        guard (20...800).contains(characters),!media.isEmpty,media.count<=20,segments.count<=100 else{throw VideoError.invalid("百度合同要求20—800个文字字符及1—20个图片/视频公开地址")}
        for segment in segments {if segment.type == .text{guard let text=segment.text,!text.isEmpty,segment.mediaSource==nil else{throw VideoError.invalid("文字段只接受text内容")}}else{guard segment.text==nil,let source=segment.mediaSource,source.type==3 else{throw VideoError.invalid("图片/视频段须使用type=3的URL来源")};_ = try safeHTTPS(source.url)}}
        let c=input.config,allowed=[[1920,1080],[1280,720],[1024,576],[1080,1920],[720,1280],[576,1024]]
        guard c.productType=="video",allowed.contains(c.resolution) else{throw VideoError.invalid("此适配只回收真实MP4视频；分辨率须使用合同列出的六种规格")}
        if let voice=c.ttsPer{guard [0,1,3,4,5,103,106,110,111,5003,5118,4003,4100,4103,4105,4106,4115,4117,4119,4144,4140,4143,4129,4278,4254,4149].contains(voice) else{throw VideoError.invalid("音库ID不在固定合同范围")}}
        if let template=c.templateId {
            let horizontal:[String]=["30","41","42","43","44","45","46","47","48","49"]
            let middleVertical:[String]=(31...39).map { value in String(value) }
            let lastVertical:[String]=(50...71).map { value in String(value) }
            var vertical:[String]=["40","28","29"]
            vertical.append(contentsOf:middleVertical)
            vertical.append(contentsOf:lastVertical)
            let allowedTemplates:[String]=c.resolution[0]>c.resolution[1] ? horizontal:vertical
            guard allowedTemplates.contains(template) else{throw VideoError.invalid("模板ID与横竖屏合同不符")}
        }
        for setting in [c.bgMusic,c.videoBegin,c.videoEnd].compactMap({$0}){guard setting.mediaSource.type==3 else{throw VideoError.invalid("辅助媒体须使用URL类型3")};_ = try safeHTTPS(setting.mediaSource.url)}
        if let caption=c.caption{guard caption.marginBottom.map({(0...500).contains($0)}) ?? true,[caption.fontAlpha,caption.bgAlpha].compactMap({$0}).allSatisfy({(0...100).contains($0)}),[caption.fontColor,caption.bgColor].compactMap({$0}).allSatisfy({$0.range(of:"^[a-fA-F0-9]{6}$",options:.regularExpression) != nil}) else{throw VideoError.invalid("字幕位置、透明度或十六进制颜色超出合同")}}
        if let logo=c.videoLogo{guard logo.mediaSource.type==3,logo.location.map({["top-left","top-right"].contains($0)}) ?? true,logo.margin.map({(0...100).contains($0)}) ?? true else{throw VideoError.invalid("角标位置或边距超出合同")};_ = try safeHTTPS(logo.mediaSource.url)}
    }
    public static func specification(input:BaiduVideoInput)throws->String {try validate(input:input);return kind+"/"+version+"/input-sha256="+(try input.digest())}
    public static func requestBody(input:BaiduVideoInput)throws->Data {try validate(input:input);return try Codec.data(input)}
    public static func queryBody(remoteID:String)throws->Data {try validateID(remoteID);return try Codec.data(AgentValue.object(["jobId":.string(remoteID),"includeTimeline":.boolean(false)]))}
    public static func validateID(_ id:String)throws {guard id.range(of:"^[0-9]{1,128}$",options:.regularExpression) != nil else{throw VideoError.invalid("百度任务ID须保留官方字符串id，不将jobId转为Double")}}
    public static func createResponse(_ data:Data)throws->BaiduCreateResponse {
        struct Envelope:Decodable {struct Result:Decodable{var id:String?};var error_code:Int?;var data:Result?}
        guard data.count<=1_048_576,let response=try? Codec.decoder().decode(Envelope.self,from:data) else{throw VideoError.unavailable("百度创建响应格式未确认；可能已接单，禁止重交")}
        if let code=response.error_code,code != 0{return .rejected(code)}
        guard let id=response.data?.id else{throw VideoError.unavailable("百度未返回可确认的字符串id；保留未知状态，不使用数字jobId猜测")};try validateID(id);return .accepted(id)
    }
    public static func queryResponse(_ data:Data)throws->BaiduQueryResponse {
        struct Envelope:Decodable {struct Result:Decodable{var statusCode:String;var progress:Double;var videoAddr:String?;var points:Decimal?;var basicDuration:Int64?;var digitalHumanDuration:Int64?};var error_code:Int;var data:Result?}
        guard data.count<=1_048_576,let response=try? Codec.decoder().decode(Envelope.self,from:data) else{throw VideoError.unavailable("百度查询响应合同不符；不改变原任务或重复提交")}
        if response.error_code != 0{return BaiduQueryResponse(state:response.error_code==31001 ? .expired:.failed,errorCode:response.error_code)}
        guard let result=response.data,result.progress.isFinite,(0...1).contains(result.progress),result.points.map({!$0.isNaN && $0>=0}) ?? true,[result.basicDuration,result.digitalHumanDuration].compactMap({$0}).allSatisfy({$0>=0}) else{throw VideoError.unavailable("百度进度或原单位用量未确认，保留原任务待核")}
        let state:BaiduQueryResponse.State
        switch result.statusCode{case "0":state = .queued;case "3":state = .running;case "1":state = .ready;case "15","30701","30702","30703","282000","30901":state = .failed;case "31001":state = .expired;default:state = .unknown}
        if state == .ready{guard result.progress==1,let url=result.videoAddr,!url.isEmpty else{throw VideoError.unavailable("百度完成状态缺少完整视频地址；不可标记已回收")};_ = try safeHTTPS(url,allowQuery:true)}
        return BaiduQueryResponse(state:state,progress:result.progress,videoAddress:state == .ready ? result.videoAddr:nil,points:result.points,basicDurationMilliseconds:result.basicDuration,digitalHumanDurationMilliseconds:result.digitalHumanDuration)
    }
    /// Persist intent BEFORE the sole potentially billed request. A returned false is
    /// a receipt replay and must never trigger another material POST.
    public static func prepare(database:inout Database,workspaceID:String,projectID:String,profile:ProviderProfile,input:BaiduVideoInput,quote:Quote,requestID:String,principal:String,now:Date=Date())throws->(job:Job,shouldSubmit:Bool) {
        guard try database.workspace(workspaceID).owner==principal else{throw VideoError.permission("百度成片仅限本机工作区所有者")};try validate(profile:profile);try validate(input:input)
        guard !requestID.isEmpty,requestID.utf8.count<=200,!requestID.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),database.providers.contains(where:{$0.id==profile.id}) else{throw VideoError.invalid("需有效原request_id及工程中已有的百度配置")}
        let digest=try input.digest()
        if let old=database.jobs.first(where:{$0.workspaceID==workspaceID && $0.requestKey==requestID}) {guard old.projectID==projectID,old.quote.id==quote.id,old.videoGeneration?.inputDigest==digest else{throw VideoError.conflict("原request_id已绑定其他生成输入或报价")};return(old,false)}
        guard !database.jobs.contains(where:{$0.workspaceID==workspaceID && $0.projectID==projectID && $0.quote.provider==profile.id && $0.remoteID==nil && $0.videoGeneration?.inputDigest==digest && [.submissionStarted,.unknown].contains($0.videoGeneration!.phase)}) else{throw VideoError.conflict("相同输入已有结果未知的原创建；新报价或新request_id也不能绕过，须先在官方账号核对原任务/账单")}
        guard profile.allowsUpload,let details=quote.breakdown,details.version==version,details.specification==(try specification(input:input)),quote.provider==profile.id,quote.attempts==1,details.lines.allSatisfy({$0.attempts==1}),!database.jobs.contains(where:{$0.quote.id==quote.id && $0.quote.provider==profile.id}) else{throw VideoError.review("需已确认上传、当前输入摘要与一次尝试的独立官方报价；已提交报价不可重用")}
        let project=try database.project(projectID);try BatchRules.validateSubmission(project:project,quote:quote,batches:database.topicBatches ?? [],existingJobs:database.jobs,requestKey:requestID)
        try TeachingBatchRules.validateSubmission(project:project,quote:quote,batches:database.teachingBatches ?? [],existingJobs:database.jobs,requestKey:requestID)
        var job=try JobRules.submit(workspaceID:workspaceID,project:project,quote:quote,requestKey:requestID,existing:database.jobs,budget:database.budget,now:now)
        job.videoGeneration=VideoGenerationReceipt(inputDigest:digest,now:now);job.state = .unknownRemote;job.attempt=1;job.message="百度创建调用已登记，结果可能未知；没有幂等/取消合同，不自动重交";database.jobs.append(job);return(job,true)
    }
    public static func applyCreated(_ response:BaiduCreateResponse,to job:Job,now:Date=Date())throws->Job {
        guard var receipt=job.videoGeneration,receipt.contractVersion==version else{throw VideoError.conflict("原任务不是此百度合同")};var result=job
        switch response{case .accepted(let id):try validateID(id);guard job.remoteID==nil || job.remoteID==id else{throw VideoError.conflict("返回的百度ID与原任务不符")};result.remoteID=id;result.state = job.state == .cancelRequested ? .cancelRequested:.queued;receipt.phase = .accepted;receipt.acceptedAt=now;result.message="原字符串id已保存；此合同无取消接口，须查询和回收原成片，现金以实际账单为准"
        case .rejected(let code):receipt.phase = .failed;result.state = .failed;result.message="百度明确返回错误码\(code)；未自动重试，费用仍待账单核对"}
        result.videoGeneration=receipt;result.updatedAt=now;return result
    }
    public static func applyQuery(_ response:BaiduQueryResponse,to job:Job,now:Date=Date())throws->Job {
        guard var receipt=job.videoGeneration else{throw VideoError.conflict("原任务缺少百度生成凭据")};var result=try JobOperations.applyRemote(response.snapshot(job:job,now:now),to:job,now:now)
        receipt.checkedAt=now;receipt.points=response.points ?? receipt.points;receipt.basicDurationMilliseconds=response.basicDurationMilliseconds ?? receipt.basicDurationMilliseconds;receipt.digitalHumanDurationMilliseconds=response.digitalHumanDurationMilliseconds ?? receipt.digitalHumanDurationMilliseconds
        if response.state == .failed || response.state == .expired{receipt.phase = .failed}
        result.videoGeneration=receipt;result.message=response.state == .ready ? "远端MP4就绪，须显式回收为待核素材；点数不是现金实耗":"已查询原百度ID，未重新提交；原单位用量和现金账单分开核对";return result
    }
}
