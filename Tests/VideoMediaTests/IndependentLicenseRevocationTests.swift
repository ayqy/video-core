import XCTest
import CryptoKit
import CoreGraphics
import Darwin
import VideoCore
@testable import VideoMedia

final class IndependentLicenseRevocationTests: XCTestCase {
    private var directories: [URL] = []
    private func root() throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = source.appendingPathComponent(".build-licence18/test-data/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directories.append(parent)
        return parent.appendingPathComponent("revocations")
    }
    override func tearDownWithError() throws { for path in directories { try FileManager.default.removeItem(at: path) } }
    private func signed(_ value: ModuleLicense, key: Curve25519.Signing.PrivateKey) throws -> SignedDocument {
        let data = try Codec.data(value)
        return SignedDocument(payload: data, signature: try key.signature(for: data))
    }
    private func license(id: String = "isolated-original") -> ModuleLicense {
        ModuleLicense(id: id, subject: "isolated-test-only", pluginIDs: ["video.game"], issuedAt: Date().addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(3600))
    }
    private func revoked(_ value: ModuleLicense, key: Curve25519.Signing.PrivateKey) throws -> SignedDocument {
        try signed(IndependentLicenseRevocationStore.revoking(signed(value, key: key), publicKey: key.publicKey.rawRepresentation), key: key)
    }
    func testRevokingPreservesOriginalIdentityScopeDatesEvenAfterExpiry() throws {
        let key = Curve25519.Signing.PrivateKey()
        var original = license(); original.expiresAt = Date().addingTimeInterval(-1)
        let document = try signed(original, key: key)
        let value = try IndependentLicenseRevocationStore.revoking(document, publicKey: key.publicKey.rawRepresentation)
        // Compare to the actual signed wire value, not pre-serialization subsecond precision.
        var expected = try document.verified(as: ModuleLicense.self, publicKey: key.publicKey.rawRepresentation); expected.revoked = true
        XCTAssertEqual(value, expected)
        XCTAssertThrowsError(try value.validate(now: Date()))
        XCTAssertThrowsError(try IndependentLicenseRevocationStore.revoking(signed(value, key: key), publicKey: key.publicKey.rawRepresentation))
    }
    func testWrongPublisherOrUnsignedMutationCannotCreateHistory() throws {
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey(), directory = try root()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        XCTAssertThrowsError(try store.remember(revoked(license(), key: other)))
        XCTAssertThrowsError(try store.remember(signed(license(), key: key)))
        var bytes = try revoked(license(), key: key); bytes.payload.append(0)
        XCTAssertThrowsError(try store.remember(bytes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testObservedOriginalIDCannotReplayAcrossNewStoreButNewIDCanRenew() throws {
        let key = Curve25519.Signing.PrivateKey(), directory = try root(), original = license()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        XCTAssertNoThrow(try store.check(original)); XCTAssertFalse(try store.hasRevocations())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.remember(revoked(original, key: key))
        let state = directory.appendingPathComponent(IndependentLicenseRevocationStore.stateName)
        let before = try Data(contentsOf: state)
        try store.remember(revoked(original, key: key))
        XCTAssertEqual(before, try Data(contentsOf: state))
        XCTAssertThrowsError(try store.check(original))
        let restarted = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        XCTAssertTrue(try restarted.hasRevocations()); XCTAssertThrowsError(try restarted.check(original))
        XCTAssertNoThrow(try restarted.check(license(id: "new-renewal-id")))
        XCTAssertThrowsError(try restarted.check(original))
    }
    func testRestrictedFreeIssuerCannotRewriteOrClearOriginalRevocationHistory()throws {
        let originalKey=Curve25519.Signing.PrivateKey(),newIssuer=Curve25519.Signing.PrivateKey(),directory=try root(),original=license()
        let store=try IndependentLicenseRevocationStore(root:directory,publicKey:originalKey.publicKey.rawRepresentation)
        try store.remember(revoked(original,key:originalKey))
        let state=directory.appendingPathComponent(IndependentLicenseRevocationStore.stateName),before=try Data(contentsOf:state)
        var changed=original;changed.revoked=true
        let payload=try Codec.data(changed),issuer=Codec.hash(newIssuer.publicKey.rawRepresentation),pair=String(repeating:"a",count:64)
        let context=try VendorFreeModuleTrust.signingPayload(purpose:VendorFreeModuleTrust.policyPurpose,issuerKeySHA256:issuer,pairSHA256:pair,payload:payload)
        let restricted=RestrictedFreeModuleDocument(purpose:VendorFreeModuleTrust.policyPurpose,issuerKeySHA256:issuer,pairSHA256:pair,payload:payload,signature:try newIssuer.signature(for:context))
        let encoder=PropertyListEncoder();encoder.outputFormat = .binary
        let downgraded=try PropertyListDecoder().decode(SignedDocument.self,from:encoder.encode(restricted))
        XCTAssertThrowsError(try downgraded.verified(as:ModuleLicense.self,publicKey:newIssuer.publicKey.rawRepresentation))
        XCTAssertThrowsError(try store.remember(downgraded))
        XCTAssertThrowsError(try IndependentLicenseRevocationStore(root:directory,publicKey:newIssuer.publicKey.rawRepresentation).hasRevocations())
        XCTAssertEqual(before,try Data(contentsOf:state))
        let restarted=try IndependentLicenseRevocationStore(root:directory,publicKey:originalKey.publicKey.rawRepresentation)
        XCTAssertTrue(try restarted.hasRevocations());XCTAssertThrowsError(try restarted.check(original))
    }
    func testOriginalLicenceSignaturesKeepTheirOriginalRootAndRevokedSemantics()throws {
        let original=Curve25519.Signing.PrivateKey(),newIssuer=Curve25519.Signing.PrivateKey(),now=Date()
        var value=license(),active=try signed(value,key:original)
        XCTAssertNoThrow(try active.verified(as:ModuleLicense.self,publicKey:original.publicKey.rawRepresentation).validate(now:now))
        XCTAssertThrowsError(try active.verified(as:ModuleLicense.self,publicKey:newIssuer.publicKey.rawRepresentation))
        value.revoked=true
        active=try signed(value,key:original)
        XCTAssertThrowsError(try active.verified(as:ModuleLicense.self,publicKey:original.publicKey.rawRepresentation).validate(now:now))
    }
    func testDryRunDoesNotInitializeAndKnownStateCannotDisappearOrResetToEmpty() throws {
        let key = Curve25519.Signing.PrivateKey(), directory = try root(), original = license()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        let record = try revoked(original, key: key)
        try store.validateImport(record); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.remember(record)
        let state = directory.appendingPathComponent(IndependentLicenseRevocationStore.stateName)
        let before = try Data(contentsOf: state)
        try FileManager.default.removeItem(at: state)
        XCTAssertThrowsError(try store.check(original)); XCTAssertThrowsError(try store.remember(record))
        try before.write(to: state); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        var object = try PropertyListSerialization.propertyList(from: before, format: nil) as! [String: Any]
        object["records"] = [String: Any]()
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0).write(to: state)
        XCTAssertThrowsError(try store.check(original)); XCTAssertThrowsError(try store.remember(record))
    }
    func testCorruptionUnknownVersionWrongRootAndOversizeFailClosed() throws {
        let key = Curve25519.Signing.PrivateKey(), directory = try root(), original = license()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        try store.remember(revoked(original, key: key))
        let state = directory.appendingPathComponent(IndependentLicenseRevocationStore.stateName), before = try Data(contentsOf: state)
        XCTAssertThrowsError(try IndependentLicenseRevocationStore(root: directory, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation).hasRevocations())
        for mutation in 0..<4 {
            var object = try PropertyListSerialization.propertyList(from: before, format: nil) as! [String: Any]
            if mutation == 0 { object["format"] = 2 }
            if mutation == 1 { object["unknown"] = "not accepted" }
            let bytes = mutation == 2 ? Data("corrupt".utf8) : mutation == 3 ? Data(repeating: 0, count: IndependentLicenseRevocationStore.maximumBytes + 1) : try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            try bytes.write(to: state)
            XCTAssertThrowsError(try store.check(license(id: "other-id")))
        }
    }
    func testLinkHardlinkAndWorldReadableStateCannotBypassHistory() throws {
        let key = Curve25519.Signing.PrivateKey(), directory = try root()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        try store.remember(revoked(license(), key: key))
        let state = directory.appendingPathComponent(IndependentLicenseRevocationStore.stateName), saved = directory.deletingLastPathComponent().appendingPathComponent("saved")
        try FileManager.default.moveItem(at: state, to: saved)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: saved)
        XCTAssertThrowsError(try store.hasRevocations())
        try FileManager.default.removeItem(at: state); XCTAssertEqual(link(saved.path, state.path), 0)
        XCTAssertThrowsError(try store.hasRevocations())
        try FileManager.default.removeItem(at: state); try FileManager.default.moveItem(at: saved, to: state)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: state.path)
        XCTAssertThrowsError(try store.hasRevocations())
    }
    func testExclusiveLockRefusesConcurrentReadAndWriteWithoutClearingState() throws {
        let key = Curve25519.Signing.PrivateKey(), directory = try root(), original = license()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        try store.remember(revoked(original, key: key))
        let file = directory.appendingPathComponent(IndependentLicenseRevocationStore.stateName), before = try Data(contentsOf: file)
        let descriptor = open(directory.appendingPathComponent(IndependentLicenseRevocationStore.lockName).path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0); defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.hasRevocations()); XCTAssertThrowsError(try store.remember(revoked(license(id: "second-id"), key: key)))
        XCTAssertEqual(before, try Data(contentsOf: file))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertThrowsError(try store.check(original))
    }
    func testMultipleRevocationsAccumulateWithoutRestoringEarlierIDs() throws {
        let key = Curve25519.Signing.PrivateKey(), directory = try root()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        for id in ["first", "second", "third"] { try store.remember(revoked(license(id: id), key: key)) }
        let restarted = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        for id in ["first", "second", "third"] { XCTAssertThrowsError(try restarted.check(license(id: id))) }
        XCTAssertNoThrow(try restarted.check(license(id: "fourth-new-grant")))
    }
    private struct Module: SceneRenderModule {
        var manifest: PluginManifest
        func draw(scene: Scene, localFrame: Int, fps: Int, rect: CGRect, context: CGContext) throws {}
    }
    func testAlreadyRegisteredPaidModuleRechecksPersistentRevocationAtUse() throws {
        let key = Curve25519.Signing.PrivateKey(), directory = try root(), original = license()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        let registry = RenderModuleRegistry(independentLicenseCheck: { value, now in try store.check(value, now: now) })
        let manifest = PluginManifest(id: "video.game", version: "1.0.0", capabilities: ["game.simulate"], implementationDigest: try BuiltinExecutableIdentity.current().digest, permissions: [])
        func sign<T: Encodable>(_ value: T) throws -> SignedDocument { let bytes = try Codec.data(value); return SignedDocument(payload: bytes, signature: try key.signature(for: bytes)) }
        try registry.register(Module(manifest: manifest), signedManifest: sign(manifest), signedPolicy: sign(CommercialPolicy(pluginID: manifest.id, version: 1, access: "paid")), signedLicense: signed(original, key: key), publicKey: key.publicKey.rawRepresentation)
        XCTAssertNoThrow(try registry.validate(kind: .simulation))
        try store.remember(revoked(original, key: key))
        XCTAssertThrowsError(try registry.validate(kind: .simulation))
        XCTAssertEqual(registry.status().first?.access, "expired")
        XCTAssertThrowsError(try registry.register(Module(manifest: manifest), signedManifest: sign(manifest), signedPolicy: sign(CommercialPolicy(pluginID: manifest.id, version: 1, access: "paid")), signedLicense: signed(original, key: key), publicKey: key.publicKey.rawRepresentation))
        // A separately signed new-ID renewal can restore this capability, but not the old ID.
        let renewal = license(id: "separately-signed-renewal")
        try registry.register(Module(manifest: manifest), signedManifest: sign(manifest), signedPolicy: sign(CommercialPolicy(pluginID: manifest.id, version: 1, access: "paid")), signedLicense: signed(renewal, key: key), publicKey: key.publicKey.rawRepresentation)
        XCTAssertNoThrow(try registry.validate(kind: .simulation))
        XCTAssertThrowsError(try store.check(original))
    }
    func testManagedCandidateABIIsRequiredOnlyAfterObservedRevocationAndNeverGrantsRights() throws {
        XCTAssertNoThrow(try IndependentLicenseRevocationABI.validate(nil, required: false))
        XCTAssertNoThrow(try IndependentLicenseRevocationABI.validate(NSNumber(value: 1), required: true))
        for value: Any? in [nil, "1", true, 1.5, 2, -1, NSNull()] {
            XCTAssertThrowsError(try IndependentLicenseRevocationABI.validate(value, required: true))
        }
    }
    func testManagedRollbackRejectsUnsupportedOldCandidateAndRetainsCurrentData() throws {
        // Real installation engine with ephemeral signed data and a deliberately injected
        // probe; fixture files are never executable code or a production trust override.
        let key = Curve25519.Signing.PrivateKey(), directory = try root(), original = license()
        let store = try IndependentLicenseRevocationStore(root: directory, publicKey: key.publicKey.rawRepresentation)
        func package(_ build: Int) throws -> URL {
            let output = try root(), payload = output.appendingPathComponent("payload")
            for name in ManagedPayloadRules.requiredPaths(for: .advancedCLI) {
                let path = payload.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (name == "publisher.pub" ? key.publicKey.rawRepresentation : Data("isolated non-executable fixture \(build) \(name)".utf8)).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: name == "bin/video-advanced" ? 0o700 : 0o600], ofItemAtPath: path.path)
            }
            let manifest = ManagedReleaseManifest(product: .advancedCLI, version: "1.0.\(build)", build: build, architecture: "x86_64", minimumRollbackBuild: 1, publisherKeySHA256: Codec.hash(key.publicKey.rawRepresentation), appleTeamID: "ISOLATED", files: try ManagedReleaseRules.inventory(payload))
            let bytes = try Codec.data(manifest), document = SignedDocument(payload: bytes, signature: try key.signature(for: bytes))
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try encoder.encode(document).write(to: output.appendingPathComponent(ManagedReleaseRules.documentName))
            return output
        }
        let installer = ManagedReleaseInstaller(publicKey: key.publicKey.rawRepresentation, architecture: "x86_64", osMajor: 14, teamID: "ISOLATED", probe: { program, data, manifest in
            try ManagedReleaseRules.verifyFiles(manifest, root: program)
            try Repository(root: data, readOnly: true).read().validate()
            try IndependentLicenseRevocationABI.validate(manifest.build >= 2 ? NSNumber(value: 1) : nil, required: store.hasRevocations())
        })
        let slot = try root()
        _ = try installer.install(package: package(1), slot: slot)
        let current = try installer.update(package: package(2), slot: slot)
        let before = try Repository(root: URL(fileURLWithPath: current.data), readOnly: true).backup()
        try store.remember(revoked(original, key: key))
        XCTAssertThrowsError(try installer.rollback(slot: slot))
        let retained = try installer.status(slot: slot)
        XCTAssertEqual(retained.generation, current.generation); XCTAssertEqual(retained.build, 2)
        XCTAssertEqual(before, try Repository(root: URL(fileURLWithPath: retained.data), readOnly: true).backup())
        XCTAssertThrowsError(try store.check(original))
    }
}
