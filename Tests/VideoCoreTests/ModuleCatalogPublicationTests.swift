import XCTest
import Darwin
import VideoCore

final class ModuleCatalogPublicationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let digest = String(repeating: "a", count: 64)
    private let expected = ["video.game": "game.simulate", "video.cartoon": "cartoon.animate"]
    private func entries(gameVersion: Int = 2, cartoonVersion: Int = 5, access: String = "paid") -> [ModuleCatalogPublication] {
        ["video.game", "video.cartoon"].map { id in
            ModuleCatalogPublication(
                manifest: PluginManifest(id: id, version: "1.0.0", capabilities: [expected[id]!], implementationDigest: digest, permissions: []),
                policy: CommercialPolicy(pluginID: id, version: id == "video.game" ? gameVersion : cartoonVersion, access: access, updatedAt: now))
        }
    }
    private func plan(_ proposed: [ModuleCatalogPublication], previous: [ModuleCatalogPublication]? = nil, code: String? = nil) throws -> [ModuleCatalogPublication] {
        try ModuleCatalogPublicationRules.reconcile(previous: previous, proposed: proposed, expectedCapabilities: expected, implementationDigest: code ?? digest, now: now)
    }
    func testInitialCompleteCatalogAndIndependentModulePolicyVersions() throws {
        let original = entries(), result = try plan(original)
        XCTAssertEqual(result.map { $0.policy.version }, [2, 5])
        var next = original; next[0].policy.version = 3; next[0].policy.access = "free"
        let updated = try plan(next, previous: original)
        XCTAssertEqual(updated.map { $0.policy.version }, [3, 5])
        XCTAssertEqual(updated.map { $0.policy.access }, ["free", "paid"])
    }
    func testPaidToFreeChangesOnlyNewerPolicyAndRetainsManifestABIAndIdentity() throws {
        let original = entries(), updated = try plan(entries(gameVersion: 3, cartoonVersion: 6, access: "free"), previous: original)
        XCTAssertEqual(updated.map(\.manifest), original.map(\.manifest))
        XCTAssertEqual(updated.map { $0.policy.access }, ["free", "free"])
        XCTAssertEqual(updated.map { $0.policy.sourceVisibility }, ["closed", "closed"])
    }
    func testSameVersionRetryReusesEntireOldPolicyAndIsByteIdentical() throws {
        let original = entries(); var retry = original
        for index in retry.indices { retry[index].policy.updatedAt = now.addingTimeInterval(60) }
        let result = try plan(retry, previous: original)
        for index in result.indices {
            XCTAssertEqual(try Codec.data(result[index].policy), try Codec.data(original[index].policy))
            XCTAssertEqual(result[index].manifest, original[index].manifest)
        }
    }
    func testRelinkMayRetainPolicyVersionAndOriginalPolicyTimestamp() throws {
        let original = entries(), newDigest = String(repeating: "b", count: 64); var relinked = original
        for index in relinked.indices {
            relinked[index].manifest.implementationDigest = newDigest
            relinked[index].manifest.version = "1.0.1"
            relinked[index].policy.updatedAt = now.addingTimeInterval(10)
        }
        let result = try plan(relinked, previous: original, code: newDigest)
        XCTAssertEqual(result.map { $0.manifest.implementationDigest }, [newDigest, newDigest])
        for index in result.indices { XCTAssertEqual(try Codec.data(result[index].policy), try Codec.data(original[index].policy)) }
    }
    func testRollbackAndSameVersionDifferentAccessAreRejectedPerModule() throws {
        let original = entries(); var rollback = original
        rollback[0].policy.version -= 1
        XCTAssertThrowsError(try plan(rollback, previous: original))
        var ambiguous = original; ambiguous[1].policy.access = "free"
        XCTAssertThrowsError(try plan(ambiguous, previous: original))
    }
    func testSourceVisibilityChangeNeedsNewPolicyVersion() throws {
        let original = entries(); var changed = original
        changed[0].manifest.sourceVisibility = "open"; changed[0].policy.sourceVisibility = "open"
        XCTAssertThrowsError(try plan(changed, previous: original))
        changed[0].policy.version += 1
        XCTAssertEqual(try plan(changed, previous: original)[0].policy.sourceVisibility, "open")
    }
    func testIncompleteDuplicateExtraAndMixedTargetCatalogsAreRejected() throws {
        let complete = entries()
        XCTAssertThrowsError(try plan([complete[0]]))
        XCTAssertThrowsError(try plan([complete[0], complete[0]]))
        XCTAssertThrowsError(try plan(complete + [complete[0]]))
        var mixed = complete; mixed[1].manifest.implementationDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try plan(mixed))
        XCTAssertThrowsError(try plan(complete, previous: [complete[0]]))
    }
    func testUntrustedABIIdentityPermissionsAndPolicyDeclarationsAreRejected() throws {
        var wrongABI = entries(); wrongABI[0].manifest.abi = 2
        XCTAssertThrowsError(try plan(wrongABI))
        var permissions = entries(); permissions[0].manifest.permissions = ["network"]
        XCTAssertThrowsError(try plan(permissions))
        var mismatch = entries(); mismatch[0].policy.pluginID = "video.cartoon"
        XCTAssertThrowsError(try plan(mismatch))
        var visibility = entries(); visibility[0].policy.sourceVisibility = "open"
        XCTAssertThrowsError(try plan(visibility))
        var future = entries(); future[0].policy.updatedAt = now.addingTimeInterval(301)
        XCTAssertThrowsError(try plan(future))
        XCTAssertThrowsError(try plan(entries(), code: String(repeating: "b", count: 64)))
    }
    private func temporaryHistoryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("video-policy-" + Codec.id())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testLegacyVersionHistoryLearnsOnlyVerifiedDeclarationAndV2RejectsLegacyDecoder() throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let legacy = try ModulePolicyHistory.decode(encoder.encode(["video.game": 2]))
        XCTAssertTrue(legacy.declarations.isEmpty)
        XCTAssertThrowsError(try legacy.observing([entries(gameVersion: 1)[0].policy], now: now))
        let learned = try legacy.observing([entries()[0].policy], now: now)
        XCTAssertEqual(learned.declarations["video.game"]?.access, "paid")
        XCTAssertThrowsError(try PropertyListDecoder().decode([String: Int].self, from: learned.encoded()))
        XCTAssertEqual(try ModulePolicyHistory.decode(learned.encoded()), learned)
    }
    func testRestartRetainsSameVersionSemanticsAndAllowsOnlyNewerPaidToFree() throws {
        let root = try temporaryHistoryRoot(), file = root.appendingPathComponent(ModulePolicyHistoryFileStore.fileName)
        let policy = entries()[0].policy
        try ModulePolicyHistoryFileStore(root: root).observe([policy])
        let saved = try Data(contentsOf: file), restarted = ModulePolicyHistoryFileStore(root: root)
        var changed = policy; changed.access = "free"
        XCTAssertThrowsError(try restarted.observe([changed]))
        changed = policy; changed.sourceVisibility = "open"
        XCTAssertThrowsError(try restarted.observe([changed]))
        XCTAssertEqual(try Data(contentsOf: file), saved)
        changed = policy; changed.version += 1; changed.access = "free"
        let updated = try restarted.observe([changed])
        XCTAssertEqual(updated.versions[policy.pluginID], 3)
        XCTAssertEqual(updated.declarations[policy.pluginID]?.sourceVisibility, "closed")
        XCTAssertThrowsError(try restarted.observe([policy]))
    }
    func testReadAndDryObservationNeverWriteAndRefreshedTimestampRetainsOriginal() throws {
        let root = try temporaryHistoryRoot(), store = ModulePolicyHistoryFileStore(root: root)
        let policy = entries()[0].policy
        let empty = try store.read()
        _ = try empty.observing([policy], now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let known = try store.observe([policy]), saved = try Data(contentsOf: root.appendingPathComponent(ModulePolicyHistoryFileStore.fileName))
        var refresh = policy; refresh.updatedAt = now.addingTimeInterval(30)
        XCTAssertEqual(try store.read().observing([refresh], now: now), known)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ModulePolicyHistoryFileStore.fileName)), saved)
    }
    func testConcurrentWriterLockAndStaleReadCannotReplaceHigherSemantics() throws {
        let root = try temporaryHistoryRoot(), store = ModulePolicyHistoryFileStore(root: root), policy = entries()[0].policy
        try store.observe([policy])
        let stale = try store.read(), saved = try Data(contentsOf: root.appendingPathComponent(ModulePolicyHistoryFileStore.fileName))
        let descriptor = open(root.appendingPathComponent(".video-advanced-policy.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0); defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        var newer = policy; newer.version += 1; newer.access = "disabled"
        XCTAssertThrowsError(try store.observe([newer]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ModulePolicyHistoryFileStore.fileName)), saved)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        _ = try stale.observing([policy], now: now)
        try store.observe([newer])
        XCTAssertThrowsError(try store.observe([policy]))
        XCTAssertEqual(try store.read().declarations[policy.pluginID]?.access, "disabled")
    }
    func testCorruptOrLinkedHistoryFailsClosedWithoutResettingBytes() throws {
        let root = try temporaryHistoryRoot(), store = ModulePolicyHistoryFileStore(root: root), file = root.appendingPathComponent(ModulePolicyHistoryFileStore.fileName)
        let corrupt = Data("preserve unreadable history".utf8); try corrupt.write(to: file)
        XCTAssertThrowsError(try store.read()); XCTAssertThrowsError(try store.observe([entries()[0].policy]))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: root.appendingPathComponent("absent").path)
        XCTAssertThrowsError(try store.read()); XCTAssertThrowsError(try store.observe([entries()[0].policy]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
    }
    func testMergePreservesNewestSemanticsAndDoesNotInventUnknownLegacySemantics() throws {
        let old = try ModulePolicyHistory().observing([entries()[0].policy], now: now)
        var paid = entries()[0].policy; paid.version = 5
        let newest = try ModulePolicyHistory().observing([paid], now: now)
        XCTAssertEqual(try old.merging(newest), newest)
        XCTAssertEqual(try newest.merging(old), newest)
        var conflicting = paid; conflicting.access = "free"
        XCTAssertThrowsError(try newest.merging(ModulePolicyHistory().observing([conflicting], now: now)))
        let unknown = try newest.merging(ModulePolicyHistory(legacyVersions: [paid.pluginID: 6]))
        XCTAssertEqual(unknown.versions[paid.pluginID], 6)
        XCTAssertNil(unknown.declarations[paid.pluginID])
    }
    func testSharedAppHistoryPreventsWorkspaceSwitchFromReestablishingDifferentSemantics() throws {
        let first=ModulePolicyHistoryFileStore(root:try temporaryHistoryRoot()),secondRoot=try temporaryHistoryRoot(),second=ModulePolicyHistoryFileStore(root:secondRoot)
        let paid=entries()[0].policy,global=try ModulePolicyHistory.decode(first.observe([paid]).encoded())
        var conflicting=paid;conflicting.access="free"
        XCTAssertThrowsError(try second.observe([conflicting],additionalHistory:global))
        XCTAssertFalse(FileManager.default.fileExists(atPath:secondRoot.appendingPathComponent(ModulePolicyHistoryFileStore.fileName).path))
        XCTAssertEqual(try second.read(additionalHistory:global).declarations[paid.pluginID]?.access,"paid")
        XCTAssertEqual(try second.observe([paid],additionalHistory:global).versions[paid.pluginID],paid.version)
    }
}
