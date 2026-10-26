import XCTest
import VideoCore
@testable import VideoMedia

#if os(macOS)
final class ScriptJobsTests:XCTestCase {
    private func fixture()throws->(Repository,Job) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("script-jobs-"+Codec.id(),isDirectory:true)
        let repository=try Repository(root:root)
        var workspace=Workspace(name:"本机规则工作区",owner:"owner");workspace.id="w"
        var profile=ProviderProfile(name:"未联网规则配置",endpoint:"https://api.example.com/chat/completions",model:"declared-model",supportedParameters:[],allowsUpload:true,keyReference:"unread-opaque-reference")
        profile.capabilities=ProviderCapabilities(version:"declared-v1",source:"供应商文档占位，仅本地规则测试")
        let revision=try Planner.create(workspaceID:"w",name:"普通教学",aspect:.landscape,scenes:[Scene(title:"解释",body:"明确的本地内容")])
        let project=Project(workspaceID:"w",name:"普通教学",revision:revision)
        try repository.transaction{$0.workspaces=[workspace];$0.projects=[project];$0.providers=[profile]}
        let quote=try EstimateBreakdown(version:"rule-v1",specification:ScriptJobRules.specification(profile:profile,revision:revision,evidence:[],brief:"解释已选内容"),source:"本地规则夹具，不代表真实账单",validFrom:.distantPast,expiresAt:Date().addingTimeInterval(3600),lines:[RateLine(label:"规则预算",quantity:1,unit:"次",price:Money(3))],excluded:[]).quote(project:project,provider:profile.id,confirmed:true)
        let job=try repository.transaction{try ScriptJobRules.prepare(database:&$0,workspaceID:"w",projectID:project.id,profile:profile,evidence:[],brief:"解释已选内容",quote:quote,requestKey:"original-paid-intent",principal:"owner")}.job
        return(repository,job)
    }
    private func absent(_ url:URL)->Bool{!FileManager.default.fileExists(atPath:url.path)}
    func testCandidateCancellationAfterStagingPublishesNothingAndKeepsOldDraft()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"新候选原文",job:job,repository:repository,principal:"owner")
        let old=staged.parent.appendingPathComponent("previous.txt"),oldBytes=Data("以前的讲稿".utf8)
        try oldBytes.write(to:old)
        try repository.transaction{$0.jobs[0]=JobRules.cancel($0.jobs[0])}
        let before=try Codec.digest(repository.read())
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertTrue(absent(staged.final));XCTAssertTrue(absent(staged.staging));XCTAssertEqual(try Data(contentsOf:old),oldBytes)
        XCTAssertEqual(try Codec.digest(repository.read()),before)
        XCTAssertEqual(try repository.read().jobs[0].state,.cancelRequested)
    }
    func testRevokedOwnerAfterStagingCannotLeaveFormalCandidate()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"仍未授权发布的候选",job:job,repository:repository,principal:"owner")
        try repository.transaction{$0.workspaces[0].owner="new-owner"}
        let before=try Codec.digest(repository.read())
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertTrue(absent(staged.final));XCTAssertTrue(absent(staged.staging));XCTAssertEqual(try Codec.digest(repository.read()),before)
    }
    func testExistingFormalCandidateIsNeverReplacedOrRemoved()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"新返回的候选",job:job,repository:repository,principal:"owner"),old=Data("预存文件，不能覆盖".utf8)
        try old.write(to:staged.final)
        let before=try Codec.digest(repository.read())
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertEqual(try Data(contentsOf:staged.final),old);XCTAssertTrue(absent(staged.staging))
        XCTAssertEqual(try Codec.digest(repository.read()),before);XCTAssertTrue(try repository.read().jobs[0].artifacts.isEmpty)
    }
    func testNormalCandidatePublicationPreservesOriginalIDAndCanBeReadBack()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let text="四个人各出一枚硬币。三枚就能修路。",staged=try ScriptJobs.prepareDraft(text:text,job:job,repository:repository,principal:"owner")
        XCTAssertTrue(absent(staged.final))
        let completed=try ScriptJobs.publishDraft(staged,repository:repository)
        XCTAssertEqual(completed.id,job.id);XCTAssertEqual(completed.requestKey,job.requestKey);XCTAssertEqual(completed.quote.id,job.quote.id)
        XCTAssertEqual(completed.state,.billingPending);XCTAssertTrue(completed.billingUnknown);XCTAssertNil(completed.lease)
        XCTAssertTrue(absent(staged.staging));XCTAssertEqual(try Data(contentsOf:staged.final),Data(text.utf8))
        XCTAssertEqual(try ScriptJobs.draft(repository:repository,job:completed),text)
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertEqual(try repository.read().jobs.count,1)
    }
    func testTransactionWriteFailureAfterRenameReclaimsOnlyOwnCandidate()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"事务未提交，不能留下正式文件",job:job,repository:repository,principal:"owner")
        let before=try Codec.digest(repository.read()),process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3")
        process.arguments=[repository.root.appendingPathComponent("workspace.sqlite").path,"CREATE TRIGGER reject_candidate BEFORE INSERT ON snapshot BEGIN SELECT RAISE(ABORT, 'controlled local persistence failure'); END;"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertTrue(absent(staged.final));XCTAssertTrue(absent(staged.staging));XCTAssertEqual(try Codec.digest(repository.read()),before)
    }
    func testChangedTemporaryFileIsPreservedInsteadOfDeletingSomeoneElsesBytes()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let staged=try ScriptJobs.prepareDraft(text:"原暂存",job:job,repository:repository,principal:"owner"),changed=Data("已被其它操作替换".utf8)
        try changed.write(to:staged.temporary,options:.atomic)
        XCTAssertThrowsError(try ScriptJobs.publishDraft(staged,repository:repository))
        XCTAssertTrue(absent(staged.final));XCTAssertEqual(try Data(contentsOf:staged.temporary),changed)
        XCTAssertTrue(try repository.read().jobs[0].artifacts.isEmpty)
    }
    func testReadOnlyPreparationRejectsBeforeCreatingAnyStagingFile()throws {
        let(repository,job)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let readonly=try Repository(root:repository.root,readOnly:true)
        XCTAssertThrowsError(try ScriptJobs.prepareDraft(text:"不能写入",job:job,repository:readonly,principal:"owner"))
        XCTAssertTrue(absent(repository.root.appendingPathComponent("drafts")))
    }
    func testExpiredProviderDeadlineRefusesBeforeCredentialOrNetworkAccess()async throws {
        let(repository,_)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let database=try repository.read()
        do {
            _=try await ProviderClient.script(profile:database.providers[0],revision:database.projects[0].current,evidence:[],brief:"期限已过，不得发送",deadline:Date().addingTimeInterval(-1))
            XCTFail("expired request was allowed")
        }catch let error as VideoError {
            XCTAssertTrue(error.localizedDescription.contains("明确执行期限"))
        }
        XCTAssertEqual(try repository.read().jobs.count,1)
    }
    func testProviderCancellationRemainsCancellationBeforeCredentials()async throws {
        let(repository,_)=try fixture();defer{try? FileManager.default.removeItem(at:repository.root)}
        let database=try repository.read()
        let task=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return try await ProviderClient.script(profile:database.providers[0],revision:database.projects[0].current,evidence:[],brief:"已取消，不得发送")
        }
        do{_ = try await task.value;XCTFail("cancelled request was allowed")}catch{XCTAssertTrue(error is CancellationError)}
    }
}
#endif
