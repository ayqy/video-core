import XCTest
@testable import VideoCore

final class ProviderRulesTests:XCTestCase {
    private func product()->Product {Product(workspaceID:"w",sku:"existing",name:"上下文课",checkout:"https://example.com/course",audience:"初学者",task:"比较真实上下文",outcome:"可复现容量限制",prerequisite:"无",scope:"真实演示",prices:[Price(money:Money(99),from:.distantPast,source:"已有购买页",verified:true)])}
    private func profile()->ProviderProfile {var p=ProviderProfile(name:"自带服务",endpoint:"https://example.com/chat/completions",model:"configured-model",supportedParameters:["max_tokens"],allowsUpload:true,keyReference:"local-reference");p.capabilities=ProviderCapabilities(version:"document-v1",source:"用户核对的官方能力文档");return p}
    func testUnsupportedSamplingParameterIsAbsentAndInputShapeIsFinite() throws {
        let p=profile(),body=try ProviderRules.body(profile:p,product:product(),evidence:[],brief:"请写真实教学草稿")
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any])
        XCTAssertNil(json["temperature"]);XCTAssertNil(json["max_completion_tokens"]);XCTAssertNotNil(json["max_tokens"])
        var bad=p;bad.supportedParameters.insert("unknown_sampling");XCTAssertThrowsError(try ProviderRules.body(profile:bad,product:product(),evidence:[],brief:"合法目标"))
        bad=p;bad.supportedParameters.insert("max_completion_tokens");XCTAssertThrowsError(try ProviderRules.validate(profile:bad))
        bad=p;bad.capabilities?.maximumInputCharacters=1000
        XCTAssertThrowsError(try ProviderRules.body(profile:bad,product:product(),evidence:[],brief:String(repeating:"字",count:1001)))
    }
    func testUploadedEvidenceCannotCrossWorkspaceOrUseExpiredRights() throws {
        var evidence=Evidence(workspaceID:"w",title:"原件",source:"核对记录",claim:"真实演示",owner:"作者",commercialAllowed:false,uploadConsent:true,verified:true)
        _=try ProviderRules.body(profile:profile(),product:product(),evidence:[evidence],brief:"教学")
        evidence.workspaceID="other";XCTAssertThrowsError(try ProviderRules.body(profile:profile(),product:product(),evidence:[evidence],brief:"教学"))
        evidence.workspaceID="w";evidence.expiresAt=Date().addingTimeInterval(-1);XCTAssertThrowsError(try ProviderRules.body(profile:profile(),product:product(),evidence:[evidence],brief:"教学"))
        evidence.expiresAt=nil;evidence.checkedAt=Date().addingTimeInterval(86400);XCTAssertFalse(evidence.usable(commercial:false))
    }
    func testStructuredResponseMustBeCompleteWithoutInventedFields() throws {
        let valid="{\"hook\":\"为什么受限\",\"knowledge\":\"上下文有限\",\"demonstration\":\"比较原始记录\",\"cta\":\"亲手复现\"}"
        XCTAssertTrue(try ProviderRules.responseText(valid,finishReason:"stop",format:.teachingV1).contains("真实演示建议"))
        XCTAssertThrowsError(try ProviderRules.responseText(valid,finishReason:"length",format:.teachingV1))
        XCTAssertThrowsError(try ProviderRules.responseText("{\"hook\":\"缺失字段\"}",finishReason:"stop",format:.teachingV1))
        XCTAssertThrowsError(try ProviderRules.responseText(valid,finishReason:nil,format:.text))
        XCTAssertThrowsError(try ProviderRules.responseText("```json\n"+valid+"\n```",finishReason:"stop",format:.teachingV1))
    }
    func testRepairNeedsEveryBillingLineBudgetedForSecondRequest() throws {
        var p=profile();p.capabilities?.repairLimit=1
        let project=Project(workspaceID:"w",name:"课",revision:Revision(product:product(),purpose:.education,aspect:.portrait,scenes:[Scene(title:"解释",body:"事实")],cta:"复现"))
        var details=EstimateBreakdown(version:"v1",specification:"输入及输出最大数量",source:"官方单价",validFrom:.distantPast,expiresAt:Date().addingTimeInterval(60),lines:[RateLine(label:"输入",quantity:10000,unit:"token",price:Money(1),per:10000,attempts:2),RateLine(label:"输出",quantity:4096,unit:"token",price:Money(1),per:1000,attempts:1)],excluded:["税费未包括"])
        var quote=try details.quote(project:project,provider:p.id,confirmed:true)
        XCTAssertFalse(ProviderRules.mayRepair(profile:p,quote:quote))
        details.lines[1].attempts=2;quote=try details.quote(project:project,provider:p.id,confirmed:true)
        XCTAssertTrue(ProviderRules.mayRepair(profile:p,quote:quote))
        quote.upper=Money(0);XCTAssertFalse(ProviderRules.mayRepair(profile:p,quote:quote))
        XCTAssertFalse(ProviderRules.mayRepair(profile:p,quote:nil))
    }
}
