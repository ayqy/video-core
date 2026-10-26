import Foundation
import Security
import VideoCore

public enum SecureCredentials {
    private static let service="com.ayqy.video.providers"
    public static func save(_ secret:String,reference:String) throws {
        guard !secret.isEmpty,!reference.isEmpty else{throw VideoError.invalid("服务凭据与引用不能为空")}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:reference]
        let values:[String:Any]=[kSecValueData as String:Data(secret.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let rc=SecItemUpdate(query as CFDictionary,values as CFDictionary)
        if rc==errSecItemNotFound {var add=query;for (k,v) in values{add[k]=v};guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else{throw VideoError.unavailable("系统凭据保存失败")}}
        else if rc != errSecSuccess{throw VideoError.unavailable("系统凭据更新失败")}
    }
    static func read(_ reference:String) throws -> String {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:reference,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var value:CFTypeRef?;guard SecItemCopyMatching(query as CFDictionary,&value)==errSecSuccess,let data=value as? Data,let secret=String(data:data,encoding:.utf8)else{throw VideoError.permission("模型凭据不可用，请在本机安全配置中重新绑定")};return secret
    }
    public static func revoke(_ reference:String)throws {let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:reference];let status=SecItemDelete(query as CFDictionary);guard status==errSecSuccess || status==errSecItemNotFound else{throw VideoError.permission("系统凭据未能撤销，请检查本机钥匙串权限；不会标记清除成功")}}
    public static func remove(_ reference:String){try? revoke(reference)}
    public static func contains(_ reference:String)->Bool { let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:reference,kSecReturnAttributes as String:true,kSecMatchLimit as String:kSecMatchLimitOne];return SecItemCopyMatching(query as CFDictionary,nil)==errSecSuccess }
}
public enum ProviderClient {
    /// Only a returned but malformed response may be repaired, and only within an explicitly frozen two-attempt quote.
    /// Transport uncertainty and HTTP failures never cause another paid POST.
    public static func script(profile:ProviderProfile,product:VideoCore.Product,evidence:[Evidence],brief:String,requestKey:String?=nil,quote:Quote?=nil,deadline:Date?=nil,onAttempt:(@Sendable (ProviderAttempt) async throws -> Void)?=nil) async throws -> String {
        try await execute(profile:profile,requestKey:requestKey,quote:quote,deadline:deadline,onAttempt:onAttempt){previous in try ProviderRules.body(profile:profile,product:product,evidence:evidence,brief:brief,previous:previous)}
    }
    public static func script(profile:ProviderProfile,revision:Revision,evidence:[Evidence],brief:String,requestKey:String?=nil,quote:Quote?=nil,deadline:Date?=nil,onAttempt:(@Sendable (ProviderAttempt) async throws -> Void)?=nil) async throws -> String {
        try await execute(profile:profile,requestKey:requestKey,quote:quote,deadline:deadline,onAttempt:onAttempt){previous in try ProviderRules.body(profile:profile,revision:revision,evidence:evidence,brief:brief,previous:previous)}
    }
    private static func execute(profile:ProviderProfile,requestKey:String?,quote:Quote?,deadline suppliedDeadline:Date?,onAttempt:(@Sendable (ProviderAttempt) async throws -> Void)?,makeBody:(String?)throws->Data) async throws -> String {
        let started=Date(),allowed=ScriptJobRules.executionAttempts(profile:profile,quote:quote,now:started)
        let deadline=min(suppliedDeadline ?? .distantFuture,ScriptJobRules.executionDeadline(profile:profile,quote:quote,now:started))
        func checkDeadline()throws {
            try Task.checkCancellation()
            guard deadline.timeIntervalSince1970.isFinite,Date()<deadline else {throw VideoError.unavailable("脚本请求已超过明确执行期限；保留原任务与费用，不继续付费或保存晚到结果")}
        }
        try checkDeadline()
        let initial=try makeBody(nil)
        let url=URL(string:profile.endpoint)!,credential=try SecureCredentials.read(profile.keyReference)
        let originalKey=requestKey ?? Codec.id()
        let config=URLSessionConfiguration.ephemeral;config.httpShouldSetCookies=false;config.httpCookieStorage=nil;config.urlCache=nil
        config.timeoutIntervalForRequest=ScriptJobRules.requestTimeoutSeconds
        config.timeoutIntervalForResource=ScriptJobRules.requestTimeoutSeconds
        let session=URLSession(configuration:config,delegate:SameOriginGuard(origin:url),delegateQueue:nil);defer{session.invalidateAndCancel()}
        let timer=Task {
            let remaining=max(0,deadline.timeIntervalSinceNow)
            do{try await Task.sleep(nanoseconds:UInt64(remaining * 1_000_000_000))}catch{return}
            session.invalidateAndCancel()
        }
        defer{timer.cancel()}
        var previous:String?
        for number in 1...allowed {
            try checkDeadline()
            let body=number==1 ? initial:try makeBody(previous)
            if number>1 {guard ProviderRules.mayRepair(profile:profile,quote:quote) else{throw VideoError.review("修复前报价已失效；已收到的结果与费用保留待核")}}
            var receipt=ProviderAttempt(id:originalKey+"-attempt-\(number)",number:number,inputDigest:Codec.hash(body),capabilityVersion:profile.capabilities?.version)
            try await onAttempt?(receipt)
            try checkDeadline()
            var request=URLRequest(url:url,timeoutInterval:min(ScriptJobRules.requestTimeoutSeconds,deadline.timeIntervalSinceNow));request.httpMethod="POST";request.setValue("Bearer "+credential,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=body
            if profile.idempotency {request.setValue(receipt.id,forHTTPHeaderField:"Idempotency-Key")}
            let data:Data,response:URLResponse
            do{(data,response)=try await session.data(for:request)}catch{try Task.checkCancellation();throw VideoError.unavailable("远端响应不确定，可能已消耗；先查询原任务或对账，不自动重交")}
            try checkDeadline()
            guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),data.count<=2*1024*1024 else{throw VideoError.unavailable("模型未返回有效响应，保留已占用预算待对账；不自动重交")}
            receipt.respondedAt=Date()
            let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let usage=result?["usage"] as? [String:Any]
            if let n=usage?["prompt_tokens"] as? Int,(0...100000000).contains(n) {receipt.inputTokens=n}
            if let n=usage?["completion_tokens"] as? Int,(0...100000000).contains(n) {receipt.outputTokens=n}
            try await onAttempt?(receipt)
            try checkDeadline()
            let first=(result?["choices"] as? [[String:Any]])?.first
            let message=first?["message"] as? [String:Any]
            let text=message?["content"] as? String ?? ""
            do {return try ProviderRules.responseText(text,finishReason:first?["finish_reason"] as? String,format:profile.capabilities?.outputFormat ?? .text)}
            catch {guard number<allowed,text.count<=30000 else{throw error};previous=text}
        }
        throw VideoError.review("有限结构修复未成功；不继续计费，结果和实际消耗待核")
    }
}
