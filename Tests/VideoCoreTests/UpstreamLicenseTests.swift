import XCTest
@testable import VideoCore

final class UpstreamLicenseTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)
    private func fixture() -> (Database, WorkspaceAccessContext) {
        var database = Database()
        let workspace = Workspace(name: "隔离许可规则工作区", owner: "author")
        database.workspaces = [workspace]
        return (database, WorkspaceAccessContext(workspaceID: workspace.id, principal: workspace.owner))
    }
    private func context(_ organization: String = "组织甲") -> UpstreamLicenseContext {
        UpstreamLicenseContext(organization: organization, teamSize: 1, deploymentEntity: "个人本机使用",
            freeCostAssumption: "只核对原生剪辑成本，不另用Remotion")
    }
    @discardableResult
    private func saveAndCheck(_ database: inout Database, access: WorkspaceAccessContext) throws -> UpstreamLicenseContextRevision {
        let revision = try UpstreamLicenseRules.update(context(), access: access, in: &database, now: time)
        _ = try UpstreamLicenseRules.recordCheck(contextID: revision.id, contextDigest: revision.digest,
            note: "按当前实际用途记录核对；不是授权凭证", access: access, in: &database, now: time)
        return revision
    }

    func testUnconfiguredLegacyDatabaseDecodesWithoutAddingEditingPrerequisite() throws {
        let (database, access) = fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Codec.data(database)) as? [String: Any])
        object.removeValue(forKey: "upstreamLicenseWorkspaces")
        let decoded = try Codec.decoder().decode(Database.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.upstreamLicenseWorkspaces)
        XCTAssertEqual(try UpstreamLicenseRules.assessment(access: access, in: decoded).state, .unconfigured)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testNormalizedConditionsAreExplicitlySavedBeforeAnyCheck() throws {
        var (database, access) = fixture()
        XCTAssertThrowsError(try UpstreamLicenseRules.recordCheck(contextID: "unsaved", contextDigest: "unsaved",
            note: "不能为尚未保存的条件核对", access: access, in: &database))
        var draft = context(); draft.organization = "  组织甲  "
        let revision = try UpstreamLicenseRules.update(draft, access: access, in: &database, now: time)
        XCTAssertEqual(revision.context.organization, "组织甲")
        XCTAssertFalse(revision.context.usesRemotion)
        XCTAssertEqual(try UpstreamLicenseRules.assessment(access: access, in: database).state, .needsCheck)
        XCTAssertTrue(database.toolSales.isEmpty)
        XCTAssertTrue(database.jobs.isEmpty)
    }

    func testEachOperatingConditionChangeInvalidatesPriorCheckAndKeepsHistory() throws {
        var (original, access) = fixture()
        let previous = try saveAndCheck(&original, access: access)
        var changed: [UpstreamLicenseContext] = []
        var value = context("组织乙"); changed.append(value)
        value = context(); value.teamSize = 12; changed.append(value)
        value = context(); value.deploymentEntity = "另一个部署主体"; changed.append(value)
        value = context(); value.usesRemotion = true; changed.append(value)
        value = context(); value.freeCostAssumption = "成本假设另行核算"; changed.append(value)
        for next in changed {
            var database = original
            let current = try UpstreamLicenseRules.update(next, access: access, in: &database, now: time)
            let result = try UpstreamLicenseRules.assessment(access: access, in: database)
            XCTAssertNotEqual(current.id, previous.id)
            XCTAssertNotEqual(current.digest, previous.digest)
            XCTAssertEqual(result.state, .needsCheck)
            XCTAssertNil(result.currentCheck)
            XCTAssertEqual(database.upstreamLicenseWorkspaces?[0].checks, original.upstreamLicenseWorkspaces?[0].checks)
            XCTAssertNoThrow(try database.validate())
        }
    }

    func testUnchangedNormalizedSavePreservesCurrentCheckWithoutCreatingRevision() throws {
        var (database, access) = fixture()
        let previous = try saveAndCheck(&database, access: access)
        var same = context(); same.organization = "  组织甲 "
        let saved = try UpstreamLicenseRules.update(same, access: access, in: &database)
        XCTAssertEqual(saved.id, previous.id)
        XCTAssertEqual(database.upstreamLicenseWorkspaces?[0].contexts.count, 1)
        XCTAssertEqual(try UpstreamLicenseRules.assessment(access: access, in: database).state, .recorded)
    }

    func testReturningFromAToBToADoesNotReviveOldAcknowledgement() throws {
        var (database, access) = fixture()
        let original = try saveAndCheck(&database, access: access)
        _ = try UpstreamLicenseRules.update(context("组织乙"), access: access, in: &database)
        let returned = try UpstreamLicenseRules.update(context(), access: access, in: &database)
        XCTAssertEqual(returned.digest, original.digest)
        XCTAssertNotEqual(returned.id, original.id)
        XCTAssertEqual(try UpstreamLicenseRules.assessment(access: access, in: database).state, .needsCheck)
        XCTAssertEqual(database.upstreamLicenseWorkspaces?[0].contexts.count, 3)
        XCTAssertEqual(database.upstreamLicenseWorkspaces?[0].checks.count, 1)
        XCTAssertThrowsError(try UpstreamLicenseRules.recordCheck(contextID: original.id, contextDigest: original.digest,
            note: "旧窗口不得重新确认", access: access, in: &database))
        _ = try UpstreamLicenseRules.recordCheck(contextID: returned.id, contextDigest: returned.digest,
            note: "回改后重新核对当前条件", access: access, in: &database)
        XCTAssertEqual(try UpstreamLicenseRules.assessment(access: access, in: database).state, .recorded)
        XCTAssertEqual(database.upstreamLicenseWorkspaces?[0].checks.count, 2)
    }

    func testNewContextCannotReceiveOldContextOrDigestConfirmation() throws {
        var (database, access) = fixture()
        let previous = try saveAndCheck(&database, access: access)
        let current = try UpstreamLicenseRules.update(context("新主体"), access: access, in: &database)
        let before = try Codec.data(database)
        for pair in [(previous.id, previous.digest), (current.id, previous.digest), (previous.id, current.digest)] {
            XCTAssertThrowsError(try UpstreamLicenseRules.recordCheck(contextID: pair.0, contextDigest: pair.1,
                note: "旧条件不能复制到新条件", access: access, in: &database))
            XCTAssertEqual(try Codec.data(database), before)
        }
    }

    func testOwnerOnlyAccessDoesNotAdoptCollaboratorOrReviewerGrants() throws {
        var (database, access) = fixture()
        let revision = try saveAndCheck(&database, access: access)
        for role in [Role.collaborator, .reviewer] {
            database.workspaces[0].grants.append(Grant(principal: "other", role: role,
                projectIDs: [], revisionIDs: [], expiresAt: time.addingTimeInterval(100)))
            let other = WorkspaceAccessContext(workspaceID: access.workspaceID, principal: "other")
            let before = try Codec.data(database)
            XCTAssertThrowsError(try UpstreamLicenseRules.ledger(access: other, in: database))
            XCTAssertThrowsError(try UpstreamLicenseRules.assessment(access: other, in: database))
            XCTAssertThrowsError(try UpstreamLicenseRules.update(context("越权"), access: other, in: &database))
            XCTAssertThrowsError(try UpstreamLicenseRules.recordCheck(contextID: revision.id, contextDigest: revision.digest,
                note: "越权确认", access: other, in: &database))
            XCTAssertEqual(try Codec.data(database), before)
        }
    }

    func testWorkspaceScopesDoNotShareChecksEvenForIdenticalConditions() throws {
        var (database, first) = fixture()
        let a = try saveAndCheck(&database, access: first)
        let workspace = Workspace(name: "另一个工作区", owner: first.principal)
        database.workspaces.append(workspace)
        let second = WorkspaceAccessContext(workspaceID: workspace.id, principal: first.principal)
        let b = try UpstreamLicenseRules.update(context(), access: second, in: &database)
        XCTAssertEqual(a.digest, b.digest)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(try UpstreamLicenseRules.assessment(access: second, in: database).state, .needsCheck)
        XCTAssertThrowsError(try UpstreamLicenseRules.recordCheck(contextID: a.id, contextDigest: a.digest,
            note: "不得复制其他工作区核对", access: second, in: &database))
        XCTAssertEqual(try UpstreamLicenseRules.assessment(access: first, in: database).state, .recorded)
    }

    func testInvalidBlankOversizedControlledAndScaleInputsAreRejectedAtomically() throws {
        var (database, access) = fixture()
        var invalid: [UpstreamLicenseContext] = []
        for count in [Int.min, -1, 0, 1_000_001, Int.max] {
            var value = context(); value.teamSize = count; invalid.append(value)
        }
        for text in ["", "   ", "含\n换行", "含\0字符", String(repeating: "长", count: 201)] {
            var value = context(); value.organization = text; invalid.append(value)
        }
        for text in ["", String(repeating: "长", count: 501)] {
            var value = context(); value.deploymentEntity = text; invalid.append(value)
        }
        for text in ["", String(repeating: "长", count: 2001)] {
            var value = context(); value.freeCostAssumption = text; invalid.append(value)
        }
        let before = try Codec.data(database)
        for value in invalid {
            XCTAssertThrowsError(try UpstreamLicenseRules.update(value, access: access, in: &database))
            XCTAssertEqual(try Codec.data(database), before)
        }
        var maximum = context(); maximum.teamSize = 1_000_000
        XCTAssertNoThrow(try UpstreamLicenseRules.normalized(maximum))
    }

    func testRecordRequiresBoundedNonemptyExplicitNoteAndDoesNotGrantToolRights() throws {
        var (database, access) = fixture()
        let revision = try UpstreamLicenseRules.update(context(), access: access, in: &database)
        let before = try Codec.data(database)
        for note in ["", "  ", "含\n换行", String(repeating: "长", count: 2001)] {
            XCTAssertThrowsError(try UpstreamLicenseRules.recordCheck(contextID: revision.id, contextDigest: revision.digest,
                note: note, access: access, in: &database))
            XCTAssertEqual(try Codec.data(database), before)
        }
        _ = try UpstreamLicenseRules.recordCheck(contextID: revision.id, contextDigest: revision.digest,
            note: "用户明确记录本次核对", access: access, in: &database)
        XCTAssertTrue(database.toolSales.isEmpty)
        XCTAssertTrue(database.jobs.isEmpty)
        XCTAssertTrue(database.workspaces[0].grants.isEmpty)
    }

    func testRepositoryGenerationCASProtectsBothContextAndAcknowledgement() throws {
        let (database, access) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upstream-cas-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root)
        try repository.transaction { $0.workspaces = database.workspaces }
        let generation = try repository.read().generation
        let revision = try repository.updateUpstreamLicenseContext(context(), access: access, expectedGeneration: generation)
        let otherConnection = try Repository(root: root)
        let before = try Codec.data(repository.read())
        XCTAssertThrowsError(try otherConnection.updateUpstreamLicenseContext(context("旧窗口"), access: access, expectedGeneration: generation))
        XCTAssertThrowsError(try otherConnection.recordUpstreamLicenseCheck(contextID: revision.id,
            contextDigest: revision.digest, note: "旧窗口确认", access: access, expectedGeneration: generation))
        XCTAssertEqual(try Codec.data(repository.read()), before)
        let current = try repository.read().generation
        _ = try repository.recordUpstreamLicenseCheck(contextID: revision.id, contextDigest: revision.digest,
            note: "当前窗口明确核对", access: access, expectedGeneration: current)
        XCTAssertEqual(try repository.upstreamLicenseAssessment(access: access).state, .recorded)
    }

    func testBackupRestoreKeepsAllConditionHistoryAndCurrentInvalidation() throws {
        var (database, access) = fixture()
        let original = try saveAndCheck(&database, access: access)
        _ = try UpstreamLicenseRules.update(context("部署主体乙"), access: access, in: &database, now: time.addingTimeInterval(1))
        _ = try UpstreamLicenseRules.update(context(), access: access, in: &database, now: time.addingTimeInterval(2))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upstream-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root.appendingPathComponent("original"))
        try repository.transaction { $0.workspaces = database.workspaces; $0.upstreamLicenseWorkspaces = database.upstreamLicenseWorkspaces }
        let restored = try Repository.restore(repository.backup(), to: root.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.read().upstreamLicenseWorkspaces, database.upstreamLicenseWorkspaces)
        let assessment = try restored.upstreamLicenseAssessment(access: access)
        XCTAssertEqual(assessment.state, .needsCheck)
        XCTAssertEqual(assessment.current?.digest, original.digest)
        XCTAssertNotEqual(assessment.current?.id, original.id)
        XCTAssertNil(assessment.currentCheck)
        XCTAssertNoThrow(try restored.read().validate())
    }

    func testMalformedStoredDigestAndMismatchedReviewCannotValidate() throws {
        var (database, access) = fixture()
        let revision = try saveAndCheck(&database, access: access)
        let ledger = try XCTUnwrap(database.upstreamLicenseWorkspaces?.first)
        let bad = UpstreamLicenseContextRevision(id: revision.id, number: 1, context: revision.context,
            digest: String(repeating: "a", count: 64), changedAt: time, changedBy: "author")
        database.upstreamLicenseWorkspaces = [WorkspaceUpstreamLicense(workspaceID: access.workspaceID, contexts: [bad], checks: ledger.checks)]
        XCTAssertThrowsError(try database.validate())
        let badCheck = UpstreamLicenseCheck(id: Codec.id(), contextID: revision.id, contextDigest: "other",
            recordedAt: time, recordedBy: "author", note: "错误绑定")
        database.upstreamLicenseWorkspaces = [WorkspaceUpstreamLicense(workspaceID: access.workspaceID, contexts: [revision], checks: [badCheck])]
        XCTAssertThrowsError(try database.validate())
        database.upstreamLicenseWorkspaces = [ledger, ledger]
        XCTAssertThrowsError(try database.validate())
    }
}
