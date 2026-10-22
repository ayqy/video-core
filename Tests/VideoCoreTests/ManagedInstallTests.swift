#if os(macOS)
import XCTest
import CryptoKit
import VideoCore

/// Engine tests use isolated data and ephemeral signatures. The fixture bytes are deliberately
/// not executable code; only the shipping video-install supplies codesign/Gatekeeper/native probes.
final class ManagedInstallTests:XCTestCase {
    private let fm=FileManager.default
    private let key=Curve25519.Signing.PrivateKey()
    private var temporary:[URL]=[]
    override func tearDown(){for url in temporary{try? fm.removeItem(at:url)};temporary=[];super.tearDown()}
    private func directory()->URL {let url=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("video-managed-test-"+Codec.id());temporary.append(url);return url}
    private func write<T:Encodable>(_ value:T,to url:URL)throws {let encoder=PropertyListEncoder();encoder.outputFormat = .binary;try encoder.encode(value).write(to:url,options:.atomic)}
    private func signed<T:Encodable>(_ value:T)throws->SignedDocument {let data=try Codec.data(value);return SignedDocument(payload:data,signature:try key.signature(for:data))}
    private func package(build:Int,floor:Int=1)throws->URL {
        let root=directory(),payload=root.appendingPathComponent("payload"),binary=payload.appendingPathComponent("bin/video")
        try fm.createDirectory(at:binary.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("isolated fixture build \(build), never execute".utf8).write(to:binary)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:binary.path)
        let manifest=ManagedReleaseManifest(product:.coreCLI,version:"1.0.\(build)",build:build,architecture:"x86_64",minimumRollbackBuild:floor,publisherKeySHA256:Codec.hash(key.publicKey.rawRepresentation),appleTeamID:"TESTTEAM",files:try ManagedReleaseRules.inventory(payload))
        try write(signed(manifest),to:root.appendingPathComponent(ManagedReleaseRules.documentName));return root
    }
    private func source()throws->Repository {
        let repo=try Repository(root:directory()),workspace=Workspace(name:"更新前数据",owner:"owner")
        let asset=try repo.ingest(Data("不可丢失的真实源内容".utf8),name:"course.txt",workspaceID:workspace.id,mediaType:"text")
        try repo.transaction{$0.workspaces=[workspace];$0.assets=[asset]};return repo
    }
    private func installer(probe:ManagedReleaseInstaller.CandidateProbe?=nil)->ManagedReleaseInstaller {
        ManagedReleaseInstaller(publicKey:key.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,teamID:"TESTTEAM",probe:probe ?? {program,data,manifest in
            try ManagedReleaseRules.verifyFiles(manifest,root:program)
            let repo=try Repository(root:data,readOnly:true);let database=try repo.read();try database.validate();try repo.verifyAssets(database)
        })
    }
    private func root(_ result:ManagedInstallResult)->URL {URL(fileURLWithPath:result.data,isDirectory:true)}
    private struct Licence:Encodable {var id="license-test";var subject="isolated-test";var pluginIDs:Set<String>=["video.game"];var issuedAt=Date().addingTimeInterval(-1000);var expiresAt:Date?=Date().addingTimeInterval(1000);var revoked:Bool}

    func testInstallUpdateAndRollbackMoveProgramAndDataTogetherAndOldHandleCannotWrite()throws {
        let source=try source(),slot=directory(),engine=installer()
        let initial=try engine.install(package:package(build:1),slot:slot,data:source.root)
        let oldHandle=try Repository(root:root(initial));try oldHandle.transaction{$0.workspaces[0].name="更新前最后一次保存"}
        let updated=try engine.update(package:package(build:2),slot:slot)
        XCTAssertNotEqual(updated.generation,initial.generation);XCTAssertEqual(updated.previousGeneration,initial.generation)
        XCTAssertEqual(try Repository(root:root(updated),readOnly:true).read().workspaces[0].name,"更新前最后一次保存")
        XCTAssertThrowsError(try oldHandle.transaction{$0.workspaces[0].name="旧进程不应覆盖"})
        XCTAssertEqual(try oldHandle.read().workspaces[0].name,"更新前最后一次保存")
        let current=try Repository(root:root(updated));try current.transaction{$0.workspaces[0].name="新版本编辑"}
        let rolledBack=try engine.rollback(slot:slot)
        XCTAssertEqual(rolledBack.build,1);XCTAssertEqual(try Repository(root:root(rolledBack),readOnly:true).read().workspaces[0].name,"更新前最后一次保存")
        XCTAssertEqual(try current.read().workspaces[0].name,"新版本编辑");XCTAssertThrowsError(try current.transaction{$0.workspaces=[]})
        let restored=try Repository(root:root(rolledBack),readOnly:true);try restored.verifyAssets(restored.read())
        XCTAssertTrue(rolledBack.program.contains("current/program/bin/video"));XCTAssertEqual(try engine.status(slot:slot).generation,rolledBack.generation)
    }
    func testPreflightFailureNeverPublishesAndPostSwitchFailureRestoresBothPointers()throws {
        let source=try source(),slot=directory(),first=try installer().install(package:package(build:1),slot:slot,data:source.root)
        let saved=try fm.destinationOfSymbolicLink(atPath:slot.appendingPathComponent("current").path)
        let preflight=installer{_,_,_ in throw VideoError.unavailable("isolated preflight failure")}
        XCTAssertThrowsError(try preflight.update(package:package(build:2),slot:slot))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath:slot.appendingPathComponent("current").path),saved)
        var calls=0
        let postSwitch=installer{program,data,manifest in
            calls+=1;try ManagedReleaseRules.verifyFiles(manifest,root:program)
            if calls==2 {
                XCTAssertNotEqual(try self.fm.destinationOfSymbolicLink(atPath:slot.appendingPathComponent("current").path),saved)
                throw VideoError.unavailable("isolated post-switch failure")
            }
            try Repository(root:data,readOnly:true).read().validate()
        }
        XCTAssertThrowsError(try postSwitch.update(package:package(build:2),slot:slot));XCTAssertEqual(calls,2)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath:slot.appendingPathComponent("current").path),saved)
        XCTAssertEqual(try installer().status(slot:slot).generation,first.generation)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath:slot.appendingPathComponent("generations").path).count,1)
        XCTAssertEqual(try Repository(root:root(first),readOnly:true).read().workspaces[0].name,"更新前数据")
    }
    func testFailedInitialSelfCheckKeepsOriginalAndNoCurrent()throws {
        let source=try source(),slot=directory(),engine=installer{_,_,_ in throw VideoError.unavailable("isolated failure")}
        XCTAssertThrowsError(try engine.install(package:package(build:1),slot:slot,data:source.root))
        XCTAssertFalse(fm.fileExists(atPath:slot.appendingPathComponent("current").path))
        XCTAssertEqual(try source.read().workspaces[0].name,"更新前数据")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath:slot.appendingPathComponent("generations").path),[])
    }
    func testRollbackKeepsLatestRevokedLicenceAndPolicyHighWater()throws {
        let source=try source(),slot=directory(),engine=installer()
        let originalLicence=try signed(Licence(revoked:false));try write(originalLicence,to:source.root.appendingPathComponent("independent.videolicense"))
        try write(["video.game":2],to:source.root.appendingPathComponent(".video-advanced-policy.plist"))
        _=try engine.install(package:package(build:1),slot:slot,data:source.root)
        let updated=try engine.update(package:package(build:2),slot:slot),updatedRoot=root(updated)
        let revoked=try signed(Licence(revoked:true));try write(revoked,to:updatedRoot.appendingPathComponent("independent.videolicense"))
        try write(["video.game":5,"video.cartoon":3],to:updatedRoot.appendingPathComponent(".video-advanced-policy.plist"))
        let expected=try Data(contentsOf:updatedRoot.appendingPathComponent("independent.videolicense"))
        let result=try engine.rollback(slot:slot),restoredRoot=root(result)
        XCTAssertEqual(try Data(contentsOf:restoredRoot.appendingPathComponent("independent.videolicense")),expected)
        let highest=try PropertyListDecoder().decode([String:Int].self,from:Data(contentsOf:restoredRoot.appendingPathComponent(".video-advanced-policy.plist")))
        XCTAssertEqual(highest,["video.game":5,"video.cartoon":3])
    }
    func testRollbackDoesNotResurrectRemovedLicenceOrCopyOldCatalogIntoData()throws {
        let source=try source(),slot=directory(),engine=installer()
        try write(signed(Licence(revoked:false)),to:source.root.appendingPathComponent("independent.videolicense"))
        try Data("old untrusted directory".utf8).write(to:source.root.appendingPathComponent("render-catalog.videomodules"))
        _=try engine.install(package:package(build:1),slot:slot,data:source.root)
        let updated=try engine.update(package:package(build:2),slot:slot)
        try fm.removeItem(at:root(updated).appendingPathComponent("independent.videolicense"))
        let result=try engine.rollback(slot:slot)
        XCTAssertFalse(fm.fileExists(atPath:root(result).appendingPathComponent("independent.videolicense").path))
        XCTAssertFalse(fm.fileExists(atPath:root(result).appendingPathComponent("render-catalog.videomodules").path))
    }
    func testSignedRollbackFloorBlocksUnsafeOlderBuildAndDowngradeUpdate()throws {
        let source=try source(),slot=directory(),engine=installer()
        _=try engine.install(package:package(build:1),slot:slot,data:source.root)
        let updated=try engine.update(package:package(build:2,floor:2),slot:slot)
        XCTAssertThrowsError(try engine.rollback(slot:slot));XCTAssertThrowsError(try engine.update(package:package(build:1),slot:slot))
        XCTAssertEqual(try engine.status(slot:slot).generation,updated.generation)
    }
    func testCandidateCannotSilentlyChangeDataOrPolicyDuringReadOnlyProbe()throws {
        let source=try source(),slot=directory(),initial=try installer().install(package:package(build:1),slot:slot,data:source.root)
        let changing=installer{_,data,_ in try Repository(root:data).transaction{$0.workspaces[0].name="unexpected"}}
        XCTAssertThrowsError(try changing.update(package:package(build:2),slot:slot))
        let policyChanging=installer{_,data,_ in try self.write(["video.game":1],to:data.appendingPathComponent(".video-advanced-policy.plist"))}
        XCTAssertThrowsError(try policyChanging.update(package:package(build:2),slot:slot))
        XCTAssertEqual(try installer().status(slot:slot).generation,initial.generation)
    }
    func testTamperedPackageOrWrongPublisherIsRejectedBeforeProbe()throws {
        let package=try package(build:1),slot=directory();var probed=false
        let bytes=package.appendingPathComponent("payload/bin/video");try Data("tampered".utf8).write(to:bytes)
        XCTAssertThrowsError(try installer{_,_,_ in probed=true}.install(package:package,slot:slot));XCTAssertFalse(probed)
        let other=Curve25519.Signing.PrivateKey(),wrong=ManagedReleaseInstaller(publicKey:other.publicKey.rawRepresentation,architecture:"x86_64",osMajor:14,teamID:"TESTTEAM",probe:{_,_,_ in probed=true})
        XCTAssertThrowsError(try wrong.install(package:self.package(build:2),slot:slot));XCTAssertFalse(probed)
        XCTAssertFalse(fm.fileExists(atPath:slot.path))
    }
    func testUnsafeInventoryRejectsSymlinksHardLinksAndTraversal()throws {
        for path in ["../escape","bin//video","/bin/video","bin/./video","secrets/key.p8",".git/config"]{XCTAssertThrowsError(try ManagedReleaseRules.relativePath(path))}
        let outside=directory();try fm.createDirectory(at:outside,withIntermediateDirectories:true);let source=outside.appendingPathComponent("outside.txt");try Data("outside".utf8).write(to:source)
        let links=directory();try fm.createDirectory(at:links,withIntermediateDirectories:true)
        let link=links.appendingPathComponent("outside.txt");try fm.createSymbolicLink(at:link,withDestinationURL:source)
        XCTAssertThrowsError(try ManagedReleaseRules.inventory(links));try fm.removeItem(at:link)
        try fm.linkItem(at:source,to:link);XCTAssertThrowsError(try ManagedReleaseRules.inventory(links))
    }
    func testSystemTemporaryAliasIsSupportedButArbitraryParentAliasIsRejected()throws {
        try ManagedReleaseRules.safeDirectory(fm.temporaryDirectory.appendingPathComponent("unpublished-safe-slot"))
        try ManagedReleaseRules.safeDirectory(URL(fileURLWithPath:"/tmp/unpublished-safe-slot",isDirectory:true))
        let original=directory(),alias=directory();try fm.createDirectory(at:original,withIntermediateDirectories:true)
        try fm.createSymbolicLink(at:alias,withDestinationURL:original)
        XCTAssertThrowsError(try ManagedReleaseRules.safeDirectory(alias.appendingPathComponent("slot")))
    }
    func testMissingSourceAssetRefusesUpdateWithoutDiscardingOriginalData()throws {
        let source=try source(),slot=directory(),initial=try installer().install(package:package(build:1),slot:slot,data:source.root)
        let active=try Repository(root:root(initial)),asset=try XCTUnwrap(active.read().assets.first)
        try fm.removeItem(at:active.assetURL(asset));XCTAssertThrowsError(try installer().update(package:package(build:2),slot:slot))
        XCTAssertEqual(try installer().status(slot:slot).generation,initial.generation)
        XCTAssertEqual(try active.read().assets.count,1);XCTAssertEqual(try source.read().assets.count,1)
    }
}
#endif
