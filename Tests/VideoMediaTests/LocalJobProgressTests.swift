import XCTest
import VideoCore
@testable import VideoMedia

final class LocalJobProgressTests: XCTestCase {
    private final class Callbacks: @unchecked Sendable {
        private let lock=NSLock()
        private var recorded:[Double]=[]
        var values:[Double] {lock.lock();defer{lock.unlock()};return recorded}
        func record(_ value:Double) {lock.lock();recorded.append(value);lock.unlock()}
    }
    private struct Fixture {
        let repository:Repository
        let job:Job
        let invocation:RenderInvocation
        var token:String {job.lease!.token}
        func report(_ value:Double,token:String?=nil,callbacks:Callbacks) throws {
            try LocalJobExecutor.reportProgress(value,repository:repository,jobID:job.id,token:token ?? self.token,invocation:invocation,progress:{callbacks.record($0)})
        }
    }
    private func fixture(root:URL?=nil) throws -> Fixture {
        let root=root ?? FileManager.default.temporaryDirectory.appendingPathComponent("local-progress-"+Codec.id())
        let repository=try Repository(root:root)
        let workspace=Workspace(name:"本地制作进度",owner:"owner")
        let revision=try Planner.create(workspaceID:workspace.id,name:"冻结工程",scenes:[Scene(title:"比较",body:"比较选择前后的结果",durationFrames:30)])
        let project=Project(workspaceID:workspace.id,name:"冻结工程",revision:revision)
        let quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(300),confirmed:true)
        let queued=try JobRules.submit(workspaceID:workspace.id,project:project,quote:quote,requestKey:"original-progress-job",existing:[],budget:BudgetPolicy())
        var job=try JobOperations.claim(queued,owner:"local-worker")
        job.progress=0.6
        try repository.transaction {$0.workspaces=[workspace];$0.projects=[project];$0.jobs=[job]}
        let invocation=try RenderInvocation.job(repository:repository,claimed:job,revision:revision,token:job.lease!.token,cancellation:RenderCancellation())
        return Fixture(repository:repository,job:job,invocation:invocation)
    }
    private func withFixture(_ body:(Fixture)throws->Void) throws {
        let f=try fixture()
        defer {try? FileManager.default.removeItem(at:f.repository.root)}
        try body(f)
    }
    private func assertRejected(_ mutate:(Repository,Fixture)throws->Void,file:StaticString=#filePath,line:UInt=#line) throws {
        try withFixture { f in
            // A separate connection must revoke a previously cached snapshot.
            let external=try Repository(root:f.repository.root)
            try mutate(external,f)
            let before=try external.read(),callbacks=Callbacks()
            XCTAssertThrowsError(try f.report(0.2,callbacks:callbacks),file:file,line:line)
            let after=try external.read()
            XCTAssertEqual(after.generation,before.generation,file:file,line:line)
            XCTAssertEqual(try Codec.digest(after.jobs),try Codec.digest(before.jobs),file:file,line:line)
            XCTAssertTrue(callbacks.values.isEmpty,file:file,line:line)
        }
    }

    func testRepeatedAndRegressingProgressPreserveRawCallbackOrderWithoutWriting() throws {
        try withFixture { f in
            let before=try f.repository.read(),callbacks=Callbacks()
            let values:[Double]=[0.6,0.2,0,0.6,0.59]
            for value in values {try f.report(value,callbacks:callbacks)}
            let after=try f.repository.read()
            XCTAssertEqual(callbacks.values,values)
            XCTAssertEqual(after.generation,before.generation)
            XCTAssertEqual(try Codec.digest(after.jobs),try Codec.digest(before.jobs))
        }
    }

    func testIncreasingProgressPersistsOnceAndKeepsOriginalTaskAndLease() throws {
        try withFixture { f in
            let before=try f.repository.read(),callbacks=Callbacks()
            try f.report(0.7,callbacks:callbacks)
            let advanced=try f.repository.read(),job=try XCTUnwrap(advanced.jobs.first)
            XCTAssertEqual(advanced.generation,before.generation+1)
            XCTAssertEqual(job.progress,0.7)
            XCTAssertEqual(job.id,f.job.id)
            XCTAssertEqual(job.attempt,f.job.attempt)
            XCTAssertEqual(try Codec.digest(job.quote),try Codec.digest(f.job.quote))
            XCTAssertEqual(job.revisionID,f.job.revisionID)
            XCTAssertEqual(job.lease?.token,f.token)
            try f.report(0.7,callbacks:callbacks)
            try f.report(0.65,callbacks:callbacks)
            XCTAssertEqual(try f.repository.read().generation,advanced.generation)
            XCTAssertEqual(callbacks.values,[0.7,0.7,0.65])
        }
    }

    func testExternalPersistedProgressIsUsedInsteadOfALocalWatermark() throws {
        try withFixture { f in
            let external=try Repository(root:f.repository.root),callbacks=Callbacks()
            try external.transaction {$0.jobs[0]=try JobOperations.heartbeat($0.jobs[0],token:f.token,progress:0.8)}
            let before=try external.read()
            try f.report(0.7,callbacks:callbacks)
            XCTAssertEqual(try external.read().generation,before.generation)
            XCTAssertEqual(try external.read().jobs[0].progress,0.8)
            XCTAssertEqual(callbacks.values,[0.7])
        }
    }

    func testInvalidRawProgressFailsWithoutWritingOrCallingTheObserver() throws {
        try withFixture { f in
            let before=try f.repository.read(),callbacks=Callbacks()
            for value in [Double.nan,Double.infinity,-Double.infinity,-0.01,1.01] {
                XCTAssertThrowsError(try f.report(value,callbacks:callbacks))
            }
            XCTAssertEqual(try f.repository.read().generation,before.generation)
            XCTAssertEqual(try Codec.digest(f.repository.read().jobs),try Codec.digest(before.jobs))
            XCTAssertTrue(callbacks.values.isEmpty)
        }
    }

    func testCancelledInvocationRejectsRepeatedProgress() throws {
        try assertRejected {_,f in f.invocation.cancellation.cancel()}
    }
    func testCancelledJobRejectsRepeatedProgress() throws {
        try assertRejected {repo,_ in try repo.transaction {$0.jobs[0]=JobRules.cancel($0.jobs[0])}}
    }
    func testExpiredLeaseRejectsRepeatedProgress() throws {
        try assertRejected {repo,_ in try repo.transaction {$0.jobs[0].lease?.expiresAt=Date().addingTimeInterval(-1)}}
    }
    func testReplacedTokenRejectsRepeatedProgress() throws {
        try assertRejected {repo,_ in try repo.transaction {$0.jobs[0].lease?.token=Codec.id()}}
    }
    func testWrongSinkTokenRejectsRepeatedProgress() throws {
        try withFixture { f in
            let before=try f.repository.read(),callbacks=Callbacks()
            XCTAssertThrowsError(try f.report(0.2,token:"other-worker",callbacks:callbacks))
            XCTAssertEqual(try f.repository.read().generation,before.generation)
            XCTAssertTrue(callbacks.values.isEmpty)
        }
    }
    func testChangedBudgetRejectsRepeatedProgress() throws {
        try assertRejected {repo,_ in try repo.transaction {$0.jobs[0].quote.upper=Money(1)}}
    }
    func testChangedBudgetReferenceRejectsRepeatedProgress() throws {
        try assertRejected {repo,_ in try repo.transaction {$0.jobs[0].quote.id=Codec.id()}}
    }
    func testChangedFrozenRevisionRejectsRepeatedProgress() throws {
        try assertRejected {repo,_ in try repo.transaction {$0.projects[0].revisions[0].scenes[0].body="另一个连接改了冻结内容"}}
    }

    func testCancellationFromTheOriginalCallbackIsRecheckedBeforeReturning() throws {
        try withFixture { f in
            let before=try f.repository.read(),callbacks=Callbacks()
            XCTAssertThrowsError(try LocalJobExecutor.reportProgress(0.2,repository:f.repository,jobID:f.job.id,token:f.token,invocation:f.invocation,progress:{value in
                callbacks.record(value)
                f.invocation.cancellation.cancel()
            })) {error in XCTAssertTrue(error is CancellationError)}
            XCTAssertEqual(callbacks.values,[0.2])
            XCTAssertEqual(try f.repository.read().generation,before.generation)
        }
    }

    func testManagedGenerationSwitchRejectsRepeatedProgressWithoutWriting() throws {
        let fm=FileManager.default
        let slot=fm.temporaryDirectory.appendingPathComponent("local-progress-slot-"+Codec.id())
        defer {try? fm.removeItem(at:slot)}
        let id="gen-"+Codec.id(),generation=slot.appendingPathComponent("generations/"+id)
        let f=try fixture(root:generation.appendingPathComponent("data"))
        try Data("managed slot".utf8).write(to:slot.appendingPathComponent(ManagedInstallRules.slotMarker))
        let marker=ManagedInstallGeneration(id:id,product:.coreCLI,previousGeneration:nil,manifestDigest:"fixture",rollbackFloor:1,dataDigest:"fixture")
        try PropertyListEncoder().encode(marker).write(to:generation.appendingPathComponent(ManagedInstallRules.markerName))
        let current=slot.appendingPathComponent("current"),callbacks=Callbacks()
        try fm.createSymbolicLink(atPath:current.path,withDestinationPath:"generations/"+id)
        try f.report(0.2,callbacks:callbacks)
        let before=try f.repository.read()
        try fm.removeItem(at:current)
        try fm.createSymbolicLink(atPath:current.path,withDestinationPath:"generations/gen-"+Codec.id())
        XCTAssertThrowsError(try f.report(0.2,callbacks:callbacks))
        XCTAssertEqual(try f.repository.read().generation,before.generation)
        XCTAssertEqual(callbacks.values,[0.2])
    }
}
