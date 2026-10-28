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
    func testKnowledgeSchemaUpgradeRequiresNewModuleVersionButNotNewAccessPolicy() throws {
        let original = entries(); var upgraded = original
        upgraded[0].manifest.inputSchema = 2
        XCTAssertThrowsError(try plan(upgraded, previous: original), "相同module版本不可由旧schema改为新知识语义")
        upgraded[0].policy.version += 1
        XCTAssertThrowsError(try plan(upgraded, previous: original), "只提高商业策略版本不能冒充模块升版")
        upgraded[0].manifest.version = "1.1.0"; upgraded[0].policy = original[0].policy
        let result = try plan(upgraded, previous: original)
        XCTAssertEqual(result[0].manifest.inputSchema, 2); XCTAssertEqual(result[0].manifest.version, "1.1.0")
        XCTAssertEqual(try Codec.data(result[0].policy), try Codec.data(original[0].policy), "新知识实现可保原商业权益，策略时间戳不伪造")
        var free = result; free[0].policy.version += 1; free[0].policy.access = "free"
        XCTAssertEqual(try plan(free, previous: result)[0].manifest, result[0].manifest, "paid/free切换仍不要求重写调用或模块实现")
    }
    func testMatrixAndPerformanceSchemasRequireRealModuleUpgradeAndRetainOriginalPolicy() throws {
        var original = entries(); original[0].manifest.inputSchema = 2
        var upgraded = original
        upgraded[0].manifest.inputSchema = try PluginInputCompatibility.publicationSchema(pluginID: "video.game", requested: "3")
        upgraded[1].manifest.inputSchema = try PluginInputCompatibility.publicationSchema(pluginID: "video.cartoon", requested: "4")
        XCTAssertThrowsError(try plan(upgraded, previous: original), "新协议不能覆盖同id/version")
        for index in upgraded.indices { upgraded[index].policy.version += 1 }
        XCTAssertThrowsError(try plan(upgraded, previous: original), "策略升版不能替代模块升版")
        for index in upgraded.indices {
            upgraded[index].manifest.version = "1.2.0"
            upgraded[index].policy = original[index].policy
        }
        let result = try plan(upgraded, previous: original)
        XCTAssertEqual(result.map { $0.manifest.inputSchema }, [3, 4])
        for index in result.indices {
            XCTAssertEqual(try Codec.data(result[index].policy), try Codec.data(original[index].policy))
        }
    }
    func testCurrentPublicationDefaultsStillRequireModuleUpgradeAndRetainPolicy() throws {
        let original = entries()
        var upgraded = original
        for index in upgraded.indices {
            upgraded[index].manifest.inputSchema = try PluginInputCompatibility.publicationSchema(pluginID: upgraded[index].manifest.id)
        }
        XCTAssertThrowsError(try plan(upgraded, previous: original), "默认新协议不能覆盖原模块版本")
        for index in upgraded.indices { upgraded[index].manifest.version = "1.3.0" }
        let result = try plan(upgraded, previous: original)
        XCTAssertEqual(result.map { $0.manifest.inputSchema }, [6, 4])
        for index in result.indices {
            XCTAssertEqual(try Codec.data(result[index].policy), try Codec.data(original[index].policy))
            XCTAssertEqual(result[index].manifest.id, original[index].manifest.id)
            XCTAssertEqual(result[index].manifest.abi, original[index].manifest.abi)
            XCTAssertEqual(result[index].manifest.implementationDigest, original[index].manifest.implementationDigest)
        }
    }
    private func sourceReview() throws -> (SourcePublicationReview,[SourcePublicationFile]) {
        func file(_ path:String,_ content:String)->SourcePublicationFile {
            let data=Data(content.utf8);return SourcePublicationFile(path:path,bytes:data.count,sha256:Codec.hash(data))
        }
        let sources=[file("Sources/VideoGame/GameModule.swift","isolated synthetic source"),file("Sources/VideoGame/LICENSE","isolated synthetic source-license grant")]
        let license=file("release/source-reviews/game-license.md","isolated source redistribution approval")
        let upstream=file("release/source-reviews/game-upstream.md","isolated upstream rights approval")
        let codeApproval=SourcePublicationApproval(document:license,approved:true,reference:"isolated-fixture-license",reviewedBy:"test-reviewer",reviewedAt:now)
        let rightsApproval=SourcePublicationApproval(document:upstream,approved:true,reference:"isolated-fixture-upstream",reviewedBy:"test-reviewer",reviewedAt:now)
        let module=ModuleSourcePublicationReview(pluginID:"video.game",version:"1.0.0",sourceFiles:sources,inventoryDigest:try ModuleCatalogPublicationRules.sourceInventoryDigest(sources),sourceLicense:codeApproval,upstreamRights:rightsApproval)
        return(SourcePublicationReview(modules:[module]),sources+[license,upstream])
    }
    func testApprovedSourcePublicationChangesVisibilitySeparatelyFromFreeAccess() throws {
        let(review,files)=try sourceReview()
        let decoded=try Codec.decoder().decode(SourcePublicationReview.self,from:Codec.data(review))
        let approved=try ModuleCatalogPublicationRules.approvedOpenSources(decoded,actualFiles:files,version:"1.0.0",now:now)
        XCTAssertEqual(approved,["video.game"])
        let original=entries(access:"free");var proposed=original
        proposed[0].manifest.sourceVisibility="open";proposed[0].policy.sourceVisibility="open"
        XCTAssertThrowsError(try plan(proposed,previous:original),"书面批准不能绕过策略升版")
        proposed[0].policy.version += 1
        let next=try plan(proposed,previous:original)
        XCTAssertEqual(next[0].manifest.id,original[0].manifest.id);XCTAssertEqual(next[0].manifest.abi,original[0].manifest.abi)
        XCTAssertEqual(next[0].manifest.implementationDigest,original[0].manifest.implementationDigest)
        XCTAssertEqual(next[0].policy.access,"free");XCTAssertEqual(next[0].policy.sourceVisibility,"open")
        XCTAssertEqual(next[1].policy.sourceVisibility,"closed","另一模块未被顺带开放")
    }
    func testSourcePublicationRequiresBothIndependentCurrentWrittenApprovals() throws {
        let(original,files)=try sourceReview()
        for mutation in 0..<7 {
            var review=original
            switch mutation {
            case 0:review.modules[0].sourceLicense.approved=false
            case 1:review.modules[0].upstreamRights.approved=false
            case 2:review.modules[0].sourceLicense.reference=" "
            case 3:review.modules[0].upstreamRights.reviewedBy=""
            case 4:review.modules[0].sourceLicense.reviewedAt=now.addingTimeInterval(301)
            case 5:review.modules[0].upstreamRights.document=review.modules[0].sourceLicense.document
            default:review.modules[0].upstreamRights.document.path="../unreviewed.md"
            }
            XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(review,actualFiles:files,version:"1.0.0",now:now))
        }
        XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(original,actualFiles:Array(files.dropLast()),version:"1.0.0",now:now))
    }
    func testSourcePublicationBindsExactActualInventoryDigestAndVersion() throws {
        let(review,files)=try sourceReview()
        XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(review,actualFiles:files,version:"1.0.1",now:now))
        var changed=files;changed[0].sha256=String(repeating:"f",count:64)
        XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(review,actualFiles:changed,version:"1.0.0",now:now))
        var declaration=review;declaration.modules[0].inventoryDigest=String(repeating:"f",count:64)
        XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(declaration,actualFiles:files,version:"1.0.0",now:now))
        declaration=review;declaration.modules[0].sourceFiles.removeLast()
        XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(declaration,actualFiles:files,version:"1.0.0",now:now))
        XCTAssertEqual(try ModuleCatalogPublicationRules.sourceInventoryDigest(files),try ModuleCatalogPublicationRules.sourceInventoryDigest(files.reversed()))
    }
    func testSourcePublicationRejectsUnsupportedModulesDuplicateOrExtraFilesAndBrokenDigests() throws {
        let(original,files)=try sourceReview()
        for mutation in 0..<4 {
            var review=original
            switch mutation {
            case 0:review.format=2
            case 1:review.modules.append(review.modules[0])
            case 2:review.modules[0].pluginID="video.private-other"
            default:review.modules[0].sourceFiles[0].sha256="bad-digest"
            }
            XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(review,actualFiles:files,version:"1.0.0",now:now))
        }
        XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(original,actualFiles:files+[files[0]],version:"1.0.0",now:now))
        let extra=SourcePublicationFile(path:"App/secret.swift",bytes:1,sha256:String(repeating:"a",count:64))
        XCTAssertThrowsError(try ModuleCatalogPublicationRules.approvedOpenSources(original,actualFiles:files+[extra],version:"1.0.0",now:now))
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
