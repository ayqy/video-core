// Standalone SDK contract regression; link against the built free VideoCore.
// No account, Keychain read, network request or billed operation occurs.
import Foundation
import VideoCore

func require(_ condition:Bool,_ message:String)throws {if !condition{throw VideoError.invalid("合同回归失败："+message)}}
let exact="1717153286267015037"
try require(try BaiduVideoRules.createResponse(Data("{\"data\":{\"jobId\":1717153286267015037,\"id\":\"1717153286267015037\"}}".utf8)) == .accepted(exact),"字符串ID精度")
var numericRejected=false
do{_ = try BaiduVideoRules.createResponse(Data("{\"data\":{\"jobId\":1717153286267015037}}".utf8))}catch{numericRejected=true}
try require(numericRejected,"不可回退至数字jobId")
let input=BaiduVideoInput(segments:[.init(text:"输入和输出共同占用上下文容量，请在真实界面对照复现并理解边界。"),.init(type:.image,url:"https://example.com/owned.png")])
try BaiduVideoRules.validate(input:input)
let root=FileManager.default.temporaryDirectory.appendingPathComponent("baidu-contract-"+Codec.id())
defer{try? FileManager.default.removeItem(at:root)}
let repository=try Repository(root:root),workspace=Workspace(name:"无网络合同夹具",owner:"tester")
let product=Product(workspaceID:workspace.id,sku:"one",name:"课程",checkout:"https://example.com/course",audience:"初学者",task:"复现",outcome:"理解",prerequisite:"",scope:"上下文",prices:[Price(money:Money(1),from:Date(timeIntervalSince1970:0),source:"产品页",verified:true)])
let revision=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"知识",body:"内容")],cta:"复现"),project=Project(workspaceID:workspace.id,name:"合同项目",revision:revision),profile=BaiduVideoRules.profile(keyReference:"not-read-contract-reference",allowsUpload:true)
let details=EstimateBreakdown(version:BaiduVideoRules.version,specification:try BaiduVideoRules.specification(input:input),source:"隔离合同测试报价，不实际下单",validFrom:Date().addingTimeInterval(-60),expiresAt:Date().addingTimeInterval(600),lines:[RateLine(label:"一次请求现金上界",quantity:1,unit:"本次请求",price:Money(2))],excluded:["点数不是现金"])
let quote=try details.quote(project:project,provider:profile.id,confirmed:true)
try repository.transaction{$0.workspaces=[workspace];$0.products=[product];$0.projects=[project];$0.providers=[profile]}
let first=try repository.transaction {try BaiduVideoRules.prepare(database:&$0,workspaceID:workspace.id,projectID:project.id,profile:profile,input:input,quote:quote,requestID:"one",principal:"tester")}
try require(first.shouldSubmit && first.job.state == .unknownRemote && first.job.remoteID==nil,"请求前原子记未知状态")
let repeated=try repository.transaction {try BaiduVideoRules.prepare(database:&$0,workspaceID:workspace.id,projectID:project.id,profile:profile,input:input,quote:quote,requestID:"one",principal:"tester")}
try require(!repeated.shouldSubmit && repeated.job.id==first.job.id && (try repository.read().jobs.count)==1,"未知请求不能重交")
var changed=input;changed.config.withCaptions=false
var conflict=false
do{_ = try repository.transaction{try BaiduVideoRules.prepare(database:&$0,workspaceID:workspace.id,projectID:project.id,profile:profile,input:changed,quote:quote,requestID:"one",principal:"tester")}}catch{conflict=true}
try require(conflict && (try repository.read().jobs.count)==1,"不同输入复用请求ID须冲突且不写新任务")
let accepted=try BaiduVideoRules.applyCreated(.accepted(exact),to:first.job)
let ready=try BaiduVideoRules.queryResponse(Data("{\"error_code\":0,\"data\":{\"statusCode\":\"1\",\"progress\":1,\"videoAddr\":\"https://cdn.example.com/original.mp4\",\"points\":12.25,\"basicDuration\":60000}}".utf8))
let result=try BaiduVideoRules.applyQuery(ready,to:accepted)
try require(result.state == .billingPending && result.actual==nil && result.billingUnknown && result.artifacts.isEmpty && result.outputAssetIDs==nil,"MP4就绪不等于已回收或商业交付")
try require(result.videoGeneration?.points==Decimal(string:"12.25") && result.videoGeneration?.basicDurationMilliseconds==60000,"点数与毫秒保留原单位")
try require(!profile.idempotency && profile.cancelPath==nil,"无虚构幂等或取消合同")
print("百度SDK合同回归通过：字符串ID、真实字段、原子提交意图、未知不重交、输入冲突、原单位用量与待核交付；无账号或网络调用。")
