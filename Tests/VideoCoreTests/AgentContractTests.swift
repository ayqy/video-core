import XCTest
@testable import VideoCore

final class AgentContractTests: XCTestCase {
    private func data(_ value: AgentValue) throws -> Data { try Codec.data(value) }
    func testFactImpactIsStrictOwnerOnlyReadWithoutNetworkOrMutation() throws {
        let command="projects facts-impact",descriptor=try AgentContract.describe(command)
        XCTAssertFalse(descriptor.writes);XCTAssertFalse(descriptor.network)
        XCTAssertEqual(descriptor.permission,.workspaceOwner);XCTAssertEqual(descriptor.idempotency,"read_only")
        let input:AgentValue = .object(["workspace_id":.string("w"),"project_id":.string("p")])
        XCTAssertNoThrow(try AgentContract.validate(command:command,data:data(input)))
        XCTAssertThrowsError(try AgentContract.validate(command:command,data:data(.object(["workspace_id":.string("w")]))))
        XCTAssertThrowsError(try AgentContract.validate(command:command,data:data(.object(["workspace_id":.string("w"),"project_id":.string("p"),"now":.string("future")]))))
        let workspace=Workspace(name:"本地资料",owner:"owner")
        XCTAssertNoThrow(try AgentContract.authorize(command:command,workspace:workspace,principal:"owner"))
        XCTAssertThrowsError(try AgentContract.authorize(command:command,workspace:workspace,principal:"reader",projectID:"p"))
    }
    func testRequiredCommandFieldsAreCheckedBeforeDryRunCanSucceed() throws {
        XCTAssertThrowsError(try AgentContract.validate(command: "render submit", data: Data("{}".utf8)))
        XCTAssertThrowsError(try AgentContract.validate(command: "products list", data: Data("{\"workspace_id\":\"w\",\"typo\":1}".utf8)))
        XCTAssertThrowsError(try AgentContract.validate(command: "edit apply", data: Data("{\"workspace_id\":\"w\",\"project_id\":\"p\",\"base_revision\":\"r\",\"edits\":[]}".utf8)))
        let input = Data("{\"workspace_id\":\"w\",\"project_id\":\"p\",\"base_revision\":\"r\",\"edits\":[{\"removeScene\":{\"_0\":\"s\"}}]}".utf8)
        XCTAssertNoThrow(try AgentContract.validate(command: "edit apply", data: input))
    }
    func testProtocolRejectsNestedCredentialsRatherThanEchoingTheirValues() throws {
        let input = try data(.object(["workspace_id": .string("w"), "product": .object(["name": .string("real"), "api_key": .string("sensitive-never-echo")])]))
        do { _ = try AgentContract.validate(command: "products import", data: input); XCTFail("secret field was accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("sensitive-never-echo")) }
        let safe = try data(.object(["workspace_id": .string("w"), "evidence": .object(["claim": .string("API key lesson uses a safe reference")])]))
        XCTAssertNoThrow(try AgentContract.validate(command: "evidence add", data: safe))
    }
    func testCanonicalReplayAndConflictingReuseCannotCreateSecondOperation() throws {
        let a = Data("{\"request_id\":\"req\",\"name\":\"真实空间\",\"principal\":\"owner\"}".utf8)
        let b = Data("{\"principal\":\"owner\",\"name\":\"真实空间\",\"request_id\":\"req\"}".utf8)
        let fingerprint = try AgentContract.fingerprint(command: "workspaces create", data: a)
        XCTAssertEqual(fingerprint, try AgentContract.fingerprint(command: "workspaces create", data: b))
        let response = AgentValue.object(["workspace_id": .string("one-and-only")])
        let record = AgentReplayRecord(requestID: "req", command: "workspaces create", fingerprint: fingerprint, response: response)
        XCTAssertEqual(try AgentContract.replay(command: "workspaces create", data: b, records: [record]), .replay(response))
        XCTAssertThrowsError(try AgentContract.replay(command: "workspaces create", data: Data("{\"request_id\":\"req\",\"name\":\"不同空间\"}".utf8), records: [record]))
        XCTAssertThrowsError(try AgentContract.replay(command: "workspaces create", data: b, records: [record, record]))
    }
    func testReviewerScopeAndRevocationAreEnforcedWithoutFinancialLeakage() throws {
        let now = Date(); var workspace = Workspace(name: "客户甲", owner: "owner")
        XCTAssertNoThrow(try AgentContract.authorize(command: "render estimate", workspace: workspace, principal: "owner", now: now))
        workspace.grants = [Grant(principal: "reviewer", role: .reviewer, projectIDs: ["p"], revisionIDs: ["r"], expiresAt: now.addingTimeInterval(60))]
        XCTAssertNoThrow(try AgentContract.authorize(command: "review record", workspace: workspace, principal: "reviewer", projectID: "p", revisionID: "r", now: now))
        XCTAssertThrowsError(try AgentContract.authorize(command: "edit apply", workspace: workspace, principal: "reviewer", projectID: "p", revisionID: "r", now: now))
        XCTAssertThrowsError(try AgentContract.authorize(command: "jobs status", workspace: workspace, principal: "reviewer", projectID: "p", revisionID: "other", now: now))
        XCTAssertThrowsError(try AgentContract.authorize(command: "reports contribution", workspace: workspace, principal: "reviewer", projectID: "p", revisionID: "r", now: now))
        workspace.grants[0].revoked = true
        XCTAssertThrowsError(try AgentContract.authorize(command: "review record", workspace: workspace, principal: "reviewer", projectID: "p", revisionID: "r", now: now))
    }
    func testHostRoutesDoNotInventShellFromModelOrUnconfiguredConnector() throws {
        let apiOnly = AgentHostRoute(ecosystem: "DeepSeek", host: "API", surface: .chatOnly, source: "official")
        XCTAssertThrowsError(try apiOnly.requireExecution(shellAvailable: true, authenticatedConnector: false, compatibleRuntime: true))
        let shell = AgentHostRoute(ecosystem: "DeepSeek", host: "Codex", surface: .localShell, source: "official")
        XCTAssertNoThrow(try shell.requireExecution(shellAvailable: true, authenticatedConnector: false, compatibleRuntime: true))
        XCTAssertThrowsError(try shell.requireExecution(shellAvailable: true, authenticatedConnector: false, compatibleRuntime: false))
        let remote = AgentHostRoute(ecosystem: "ChatGPT", host: "web", surface: .remoteConnector, source: "official")
        XCTAssertThrowsError(try remote.requireExecution(shellAvailable: false, authenticatedConnector: false, compatibleRuntime: false))
    }
    func testCatalogHasExecutableSchemasAndTruthfulIdempotency() throws {
        let catalog = try AgentContract.catalog()
        XCTAssertEqual(catalog.object?["schema_version"], .string("1.0"))
        let schema = try AgentContract.inputSchema("render submit")
        XCTAssertEqual(schema.object?["additionalProperties"], .boolean(false))
        XCTAssertEqual(try AgentContract.describe("render submit").idempotency, "frozen_job_request_key")
        XCTAssertEqual(try AgentContract.describe("script create").idempotency, "atomic_database_request_receipt")
    }
    func testReconciliationAcceptsAnOrdinaryBillWithoutVideoGenerationInput() throws {
        let record = BillingRecord(id: "unit-bill", kind: .charge, money: Money(12), source: "unit-test receipt")
        let value = try Codec.decoder().decode(AgentValue.self, from: Codec.data(record))
        let input: [String: AgentValue] = ["workspace_id": .string("w"), "job_id": .string("original-job"), "billing_record": value]
        XCTAssertNoThrow(try AgentContract.validate(command: "jobs reconcile", data: data(.object(input))))
        var unrelated = input; unrelated["baidu_input"] = .object([:])
        XCTAssertThrowsError(try AgentContract.validate(command: "jobs reconcile", data: data(.object(unrelated))))
        unrelated = input; unrelated["typo"] = .string("unsupported")
        XCTAssertThrowsError(try AgentContract.validate(command: "jobs reconcile", data: data(.object(unrelated))))
        var missing = input; missing.removeValue(forKey: "billing_record")
        XCTAssertThrowsError(try AgentContract.validate(command: "jobs reconcile", data: data(.object(missing))))
        let schema = try XCTUnwrap(AgentContract.inputSchema("jobs reconcile").object)
        XCTAssertEqual(schema["required"], .array([.string("workspace_id"), .string("job_id"), .string("billing_record")]))
        XCTAssertNil(schema["properties"]?.object?["baidu_input"])
        XCTAssertEqual(schema["additionalProperties"], .boolean(false))
        XCTAssertTrue(try AgentContract.describe("baidu submit").required.contains("baidu_input"))
    }
    func testReconciliationKeepsOwnerPermissionAndBillingEventIdempotency() throws {
        let descriptor = try AgentContract.describe("jobs reconcile")
        XCTAssertEqual(descriptor.permission, .workspaceOwner)
        XCTAssertEqual(descriptor.idempotency, "billing_record_id")
        XCTAssertTrue(descriptor.writes)
        XCTAssertFalse(descriptor.network)
        let now = Date(); var workspace = Workspace(name: "账单所属空间", owner: "owner")
        workspace.grants = [Grant(principal: "collaborator", role: .collaborator, projectIDs: ["p"], revisionIDs: ["r"], expiresAt: now.addingTimeInterval(60))]
        XCTAssertNoThrow(try AgentContract.authorize(command: "jobs reconcile", workspace: workspace, principal: "owner", now: now))
        XCTAssertThrowsError(try AgentContract.authorize(command: "jobs reconcile", workspace: workspace, principal: "collaborator", projectID: "p", revisionID: "r", now: now))
    }
}
