import XCTest
import VideoCore
import VideoMedia
import AVFoundation

final class BubbleArtworkMediaTests:XCTestCase {
    private var roots:[URL]=[]
    override func tearDownWithError()throws {for root in roots{try? FileManager.default.removeItem(at:root)}}
    private var resources:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Resources/Bubble")}
    private func directory()throws->URL {let root=FileManager.default.temporaryDirectory.appendingPathComponent("bubble-shared-"+Codec.id());try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);roots.append(root);return root}
    private func repo()throws->(Repository,Workspace) {let repo=try Repository(root:directory());let workspace=Workspace(name:"共享经典素材规则",owner:"rules");try repo.transaction{$0.workspaces.append(workspace)};return(repo,workspace)}
    func testMacAndSDKImportSameHashPinnedFamiliarQArtAndRealDownloadedAudio()throws {
        let (repo,w)=try repo();let pack=try BubbleBuiltinAssets.importPack(from:resources,workspaceID:w.id,repository:repo);let db=try repo.read()
        XCTAssertEqual(pack.characters.map(\.name),["皮蛋","胖墩","蓝蓝","葱头"])
        XCTAssertEqual(pack.audioAssets.count,3)
        for character in pack.characters {
            let art=character.artwork
            XCTAssertEqual(art.derivation,.qStyle);XCTAssertEqual(art.originalAssetIDs.count,9)
            let hashes=Set(db.assets.filter{art.originalAssetIDs.contains($0.id)}.map(\.hash))
            for sprite in art.sprites {XCTAssertFalse(hashes.contains(try XCTUnwrap(db.assets.first{$0.id==sprite.assetID}).hash))}
            var scene=VideoCore.Scene(kind:.simulation,title:"隔离教学演绎",body:"不冒充原作规则");scene.classicArtwork=art
            XCTAssertNoThrow(try ClassicArtworkRules.validateRights(scene:scene,workspaceID:w.id,assets:db.assets,evidence:db.evidence,commercial:false))
            XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:scene,workspaceID:w.id,assets:db.assets,evidence:db.evidence,commercial:true))
        }
        for asset in pack.audioAssets {let format=try AVAudioFile(forReading:repo.assetURL(asset));XCTAssertGreaterThan(format.length,0);XCTAssertGreaterThan(asset.durationFrames ?? 0,0);XCTAssertTrue(asset.warnings.contains{$0.contains("未试听")})}
        try repo.verifyAssets(db)
    }
    func testRepeatedImportKeepsSourcesAndRightsUnchanged()throws {
        let (repo,w)=try repo();let first=try BubbleBuiltinAssets.importPack(from:resources,workspaceID:w.id,repository:repo);let before=try repo.read()
        let second=try BubbleBuiltinAssets.importPack(from:resources,workspaceID:w.id,repository:repo);let after=try repo.read()
        XCTAssertEqual(first.characters.map(\.artwork),second.characters.map(\.artwork))
        XCTAssertEqual(Set(before.assets.map(\.id)),Set(after.assets.map(\.id)))
        XCTAssertEqual(Set(before.evidence.map(\.id)),Set(after.evidence.map(\.id)))
        XCTAssertTrue(after.evidence.allSatisfy{$0.verified && !$0.commercialAllowed})
        XCTAssertEqual(after.assets.count,16)
    }
    func testChangedQAtlasIsRejectedBeforeAnySourceOrDatabaseWrite()throws {
        let (repo,w)=try repo();let folder=try directory()
        for name in try FileManager.default.contentsOfDirectory(atPath:resources.path) {try FileManager.default.copyItem(at:resources.appendingPathComponent(name),to:folder.appendingPathComponent(name))}
        let url=folder.appendingPathComponent("bubble-q-characters-v1.png");var bytes=try Data(contentsOf:url);bytes[bytes.count-1] ^= 1;try bytes.write(to:url)
        let old=try Codec.digest(repo.read())
        XCTAssertThrowsError(try BubbleBuiltinAssets.importPack(from:folder,workspaceID:w.id,repository:repo))
        XCTAssertEqual(try Codec.digest(repo.read()),old)
        let assets=repo.root.appendingPathComponent("assets")
        XCTAssertFalse(FileManager.default.fileExists(atPath:assets.path))
    }
}
