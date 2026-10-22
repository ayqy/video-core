import XCTest
@testable import VideoCore

final class NativeAgentTests:XCTestCase {
    private func repository() throws -> (Repository,Workspace,Product) {
        let repository=try Repository(root:FileManager.default.temporaryDirectory.appendingPathComponent("native-agent-"+UUID().uuidString))
        let workspace=Workspace(name:"真实本机空间",owner:NativeAgent.principal)
        let product=Product(workspaceID:workspace.id,sku:"existing-course",name:"已有课程",checkout:"https://example.com/course",audience:"初学者",task:"理解上下文",outcome:"对照真实输入输出",prerequisite:"会使用聊天界面",scope:"上下文容量",prices:[Price(money:Money(99),from:Date(timeIntervalSince1970:0),source:"已有产品页",verified:true)])
        try repository.transaction{$0.workspaces=[workspace];$0.products=[product]}
        return(repository,workspace,product)
    }
    private func input(workspace:Workspace,product:Product,request:String="request-1")->[String:AgentValue] {
        ["workspace_id":.string(workspace.id),"product_id":.string(product.id),"knowledge":.string("输入和输出共同占用上下文容量"),"demonstration":.string("在已有聊天界面逐项核对输入与输出占用"),"hook":.string("为什么输出也会占用容量"),"request_id":.string(request)]
    }
    func testNativeDraftCreationReplaysSameRequestAndNeverCreatesPaidJob() throws {
        let(repository,workspace,product)=try repository();defer{try? FileManager.default.removeItem(at:repository.root)}
        let values=input(workspace:workspace,product:product)
        let first=try XCTUnwrap(NativeAgent.execute(command:"script create",input:values,repository:repository).object)
        let second=try XCTUnwrap(NativeAgent.execute(command:"script create",input:values,repository:repository).object)
        XCTAssertEqual(first["ok"],.boolean(true));XCTAssertEqual(first["state"],.string("needs_review"))
        XCTAssertEqual(first["project_id"],second["project_id"]);XCTAssertEqual(first["revision"],second["revision"])
        let stored=try repository.read();XCTAssertEqual(stored.projects.count,1);XCTAssertEqual(stored.intentReceipts?.count,1)
        XCTAssertTrue(stored.jobs.isEmpty);XCTAssertTrue(stored.publications.isEmpty);XCTAssertTrue(stored.projects[0].current.scenes.allSatisfy{$0.kind == .explanation && $0.voice==nil});XCTAssertFalse(stored.projects[0].current.review.complete)
        var changed=values;changed["hook"] = .string("不同内容必须使用新请求ID")
        let conflict=try XCTUnwrap(NativeAgent.execute(command:"script create",input:changed,repository:repository).object)
        XCTAssertEqual(conflict["error"]?.object?["code"],.string("revision_conflict"));XCTAssertEqual(try repository.read().projects.count,1)
    }
    func testNativeDraftNeedsStableRequestAndRejectsAdvancedKindOrOtherIdentity() throws {
        let(repository,workspace,product)=try repository();defer{try? FileManager.default.removeItem(at:repository.root)}
        var values=input(workspace:workspace,product:product);values.removeValue(forKey:"request_id")
        XCTAssertEqual(NativeAgent.execute(command:"script create",input:values,repository:repository).object?["ok"],.boolean(false))
        values=input(workspace:workspace,product:product);values["kind"] = .string(SceneKind.cartoon.rawValue)
        XCTAssertEqual(NativeAgent.execute(command:"script create",input:values,repository:repository).object?["error"]?.object?["code"],.string("permission_required"))
        values=input(workspace:workspace,product:product);values["principal"] = .string("other-user")
        XCTAssertEqual(NativeAgent.execute(command:"script create",input:values,repository:repository).object?["error"]?.object?["code"],.string("permission_required"))
        XCTAssertTrue(try repository.read().projects.isEmpty)
    }
    func testNativeDiscoveryAndListAreRedactedAndLimitedToLocalOwner() throws {
        let(repository,workspace,product)=try repository();defer{try? FileManager.default.removeItem(at:repository.root)}
        let foreign=Workspace(name:"PRIVATE_CUSTOMER",owner:"other-principal")
        try repository.transaction{database in database.workspaces.append(foreign);database.providers=[ProviderProfile(name:"PRIVATE_PROVIDER",endpoint:"https://example.com/api",model:"PRIVATE_MODEL",supportedParameters:[],keyReference:"PRIVATE_KEYCHAIN_REFERENCE")]}
        let catalog=NativeAgent.execute(command:"capabilities",input:[:],repository:repository)
        let json=try XCTUnwrap(String(data:Codec.data(catalog),encoding:.utf8))
        XCTAssertTrue(json.contains(product.id));XCTAssertTrue(json.contains(workspace.id))
        for forbidden in ["PRIVATE_CUSTOMER","PRIVATE_PROVIDER","PRIVATE_MODEL","PRIVATE_KEYCHAIN_REFERENCE",workspace.salt] {XCTAssertFalse(json.contains(forbidden))}
        let denial=NativeAgent.execute(command:"projects list",input:["workspace_id":.string(foreign.id)],repository:repository)
        XCTAssertEqual(denial.object?["error"]?.object?["code"],.string("permission_required"))
        let envelope=try XCTUnwrap(catalog.object)
        for field in ["project_id","revision","job_id","error"] {XCTAssertEqual(envelope[field],.null)}
    }
    func testNativeQueryChecksOriginalJobScopeAndDoesNotSubmitMissingJob() throws {
        let(repository,workspace,_)=try repository();defer{try? FileManager.default.removeItem(at:repository.root)}
        let result=NativeAgent.execute(command:"jobs status",input:["workspace_id":.string(workspace.id),"job_id":.string("missing-original-job")],repository:repository)
        XCTAssertEqual(result.object?["error"]?.object?["code"],.string("not_found"));XCTAssertTrue(try repository.read().jobs.isEmpty)
    }
}
