import XCTest
import VideoCore
@testable import VideoMedia

final class RenderInvocationTests:XCTestCase {
    private func fixture(_ body:(Repository,Workspace,Project)throws->Void)throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("render-scope-"+Codec.id())
        defer { try? FileManager.default.removeItem(at:root) }
        let repository=try Repository(root:root)
        var workspace=Workspace(name:"制作权限",owner:"owner")
        let revision=try Planner.create(workspaceID:workspace.id,name:"冻结制作",scenes:[Scene(title:"观察",body:"比较操作前后状态",durationFrames:30)])
        let project=Project(workspaceID:workspace.id,name:"冻结制作",revision:revision)
        workspace.grants=[Grant(principal:"reviewer",role:.reviewer,projectIDs:[project.id],revisionIDs:[revision.id],expiresAt:Date().addingTimeInterval(300))]
        try repository.transaction { $0.workspaces=[workspace];$0.projects=[project] }
        try body(repository,workspace,project)
    }
    func testInFlightPreviewRejectsRevokedGrantAndChangedRevision()throws {
        try fixture { repo,workspace,project in
            let access=WorkspaceAccessContext(workspaceID:workspace.id,principal:"reviewer")
            let invocation=try RenderInvocation.preview(repository:repo,projectID:project.id,revision:project.current,access:access)
            try invocation.check()
            try repo.transaction { $0.workspaces[0].grants[0].revoked=true }
            XCTAssertThrowsError(try invocation.check())
            try repo.transaction { $0.workspaces[0].grants[0].revoked=false;$0.projects[0].revisions[0].scenes[0].body="内容已改变" }
            XCTAssertThrowsError(try invocation.check())
        }
    }
    func testJobScopeDoesNotSurviveCancellationOrLeaseReplacement()throws {
        try fixture { repo,workspace,project in
            let revision=project.current
            let quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(300),confirmed:true)
            var job=try JobRules.submit(workspaceID:workspace.id,project:project,quote:quote,requestKey:"lease",existing:[],budget:BudgetPolicy())
            job=try JobOperations.claim(job,owner:"worker")
            try repo.transaction { $0.jobs=[job] }
            let cancellation=RenderCancellation(),token=try XCTUnwrap(job.lease?.token)
            let invocation=try RenderInvocation.job(repository:repo,claimed:job,revision:revision,token:token,cancellation:cancellation)
            try invocation.check()
            try repo.transaction { $0.jobs[0].lease?.token=Codec.id() }
            XCTAssertThrowsError(try invocation.check())
            try repo.transaction { $0.jobs[0].lease?.token=token;$0.jobs[0]=JobRules.cancel($0.jobs[0]) }
            XCTAssertThrowsError(try invocation.check())
        }
    }
    func testExternalCommitsImmediatelyRevokePreviewAndClaimedJobScope()throws {
        try fixture { repo,workspace,project in
            let external=try Repository(root:repo.root)
            let revision=project.current
            let preview=try RenderInvocation.preview(repository:repo,projectID:project.id,revision:revision,access:WorkspaceAccessContext(workspaceID:workspace.id,principal:"reviewer"))
            try preview.check()
            try external.transaction{$0.workspaces[0].grants[0].revoked=true}
            XCTAssertThrowsError(try preview.check()) {error in XCTAssertEqual((error as? VideoError)?.code,"permission_required")}
            try external.transaction{$0.workspaces[0].grants[0].revoked=false}
            try preview.check()

            let quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(300),confirmed:true)
            let submitted=try JobRules.submit(workspaceID:workspace.id,project:project,quote:quote,requestKey:"external-lease",existing:[],budget:BudgetPolicy())
            let job=try JobOperations.claim(submitted,owner:"worker")
            try repo.transaction{$0.jobs=[job]}
            let token=try XCTUnwrap(job.lease?.token)
            let invocation=try RenderInvocation.job(repository:repo,claimed:job,revision:revision,token:token,cancellation:RenderCancellation())
            try invocation.check()
            try external.transaction{$0.jobs[0].lease?.token=Codec.id()}
            XCTAssertThrowsError(try invocation.check()) {error in XCTAssertEqual((error as? VideoError)?.code,"permission_required")}
            try external.transaction{$0.jobs[0].lease?.token=token}
            try invocation.check()
            try external.transaction{$0.jobs[0]=JobRules.cancel($0.jobs[0])}
            XCTAssertThrowsError(try invocation.check()) {error in XCTAssertEqual((error as? VideoError)?.code,"permission_required")}
            try external.transaction{$0.projects[0].revisions[0].scenes[0].body="另一个连接修改了冻结内容"}
            XCTAssertThrowsError(try preview.check()) {error in XCTAssertEqual((error as? VideoError)?.code,"revision_conflict")}
        }
    }
    func testSynchronousQueueSeesCancellationAndExactDeadline()throws {
        try fixture { repo,workspace,project in
            let cancellation=RenderCancellation()
            let invocation=try RenderInvocation.preview(repository:repo,projectID:project.id,revision:project.current,access:WorkspaceAccessContext(workspaceID:workspace.id,principal:"owner"),cancellation:cancellation)
            XCTAssertThrowsError(try invocation.check(now:invocation.deadline))
            cancellation.cancel()
            let result=DispatchQueue(label:"render-scope-test").sync { Result {try invocation.check()} }
            guard case .failure(let error)=result else {return XCTFail("取消后仍返回画面")}
            XCTAssertTrue(error is CancellationError)
        }
    }
}
