import XCTest
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
}
