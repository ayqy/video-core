import XCTest
import CSQLite
@testable import VideoCore

final class RepositorySnapshotCodecTests: XCTestCase {
    private struct Fixture { let root: URL; let repository: Repository; let database: Database }
    private func fixture(histories: Int = 3, scenes: Int = 3) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-snapshot-" + Codec.id())
        let repository = try Repository(root: root.appendingPathComponent("source"))
        let workspace = Workspace(name: "保留原版整岛", owner: "owner")
        let retainedNodes = (0..<48).map { "<node id=\"original-canonical-resource-node-with-complete-retained-geometry-identity-\($0)\"/>" }.joined()
        let xml = """
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1"><asset><unit meter="1"/><up_axis>Y_UP</up_axis></asset><library_geometries><geometry id="triangle"><mesh><source id="position"><float_array id="positions" count="9">0 0 0 1 0 0 0 1 0</float_array></source></mesh></geometry></library_geometries><library_visual_scenes><visual_scene id="stage"><node id="hip" sid="hip" type="JOINT"/><node id="mesh"><instance_geometry url="#triangle"/></node>\(retainedNodes)</visual_scene></library_visual_scenes><scene><instance_visual_scene url="#stage"/></scene></COLLADA>
        """
        let source = Data(xml.utf8)
        let asset = try repository.ingest(source, name: "原件.dae", workspaceID: workspace.id, mediaType: "model3d")
        let resource = ModelDAEResource(model: .init(asset: asset), inspection: try DAEInspector.inspect(source), textures: [:])
        let model = ModelScene3D(instances: [.init(id: "original", name: "原始树木与家具", resource: resource,
            transform: .init(translation: .init(x: 0.10000000000000002, y: -0.0, z: Double.leastNonzeroMagnitude)))],
            camera: .init(position: .init(x: 0, y: 2, z: 5), target: .init()), lights: [.init(id: "sun", kind: .directional)],
            transformTracks: [.init(instanceID: "original", keyframes: [.init(frame: 0, transform: .init()), .init(frame: 20, transform: .init(translation: .init(x: 1.0000000000000002)))])],
            jointTracks: [.init(instanceID: "original", jointName: "hip", keyframes: [.init(frame: 0, transform: .init()), .init(frame: 20, transform: .init())])])
        var scene = Scene(kind: .simulation, title: "中文／原件", body: "保留色彩与接地。", durationFrames: 21)
        scene.modelScene3D = model; scene.sourceGain = -0.0
        var revision = Revision(contentContext: .init(workspaceID: workspace.id, name: "同一完整地图"), aspect: .landscape, scenes: (0..<scenes).map { index in
            var value = scene; value.id = Codec.id(); value.title += "\(index)"; value.modelScene3D!.camera.position.x = Double(index); return value
        })
        var project = Project(workspaceID: workspace.id, name: "全历史保留", revision: revision)
        if histories > 1 { for index in 2...histories {
            revision.parentID = revision.id; revision.id = Codec.id(); revision.number = index
            revision.change = "原样保留第\(index)份历史"; revision.review.reviewer = "人工回读\(index)"
            project.revisions.append(revision)
        } }
        try repository.transaction { $0.workspaces = [workspace]; $0.projects = [project]; $0.assets = [asset] }
        return Fixture(root: root, repository: repository, database: try repository.read())
    }
    private func object(_ bytes: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func wire(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func raw(_ repository: Repository) throws -> Data {
        var db: OpaquePointer?, stmt: OpaquePointer?
        guard sqlite3_open_v2(repository.root.appendingPathComponent("workspace.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw VideoError.invalid("fixture read failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, "SELECT payload FROM snapshot WHERE id=1", -1, &stmt, nil) == SQLITE_OK else { throw VideoError.invalid("fixture query failed") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw VideoError.invalid("fixture payload absent") }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
    }
    private func modifyModel(_ value: inout [String: Any], _ body: (inout [String: Any]) -> Void) throws {
        var projects = try XCTUnwrap(value["projects"] as? [[String: Any]])
        var revisions = try XCTUnwrap(projects[0]["revisions"] as? [[String: Any]])
        var scenes = try XCTUnwrap(revisions[0]["scenes"] as? [[String: Any]])
        var model = try XCTUnwrap(scenes[0]["modelScene3D"] as? [String: Any]); body(&model)
        scenes[0]["modelScene3D"] = model; revisions[0]["scenes"] = scenes; projects[0]["revisions"] = revisions; value["projects"] = projects
    }

    func testSharedStoragePreservesAll26HistoriesPublicIRDigestsAndFloatBits() throws {
        let f = try fixture(histories: 26, scenes: 34); defer { try? FileManager.default.removeItem(at: f.root) }
        let canonical = try Codec.data(f.database), stored = try raw(f.repository), decoded = try RepositorySnapshotCodec.decode(stored)
        XCTAssertLessThan(stored.count, canonical.count / 3)
        XCTAssertEqual(try Codec.data(decoded), canonical)
        XCTAssertEqual(try RepositorySnapshotCodec.encode(decoded), stored, "同一业务状态使用确定性池顺序")
        for (before, after) in zip(f.database.projects[0].revisions, decoded.projects[0].revisions) {
            XCTAssertEqual(try Codec.data(before), try Codec.data(after)); XCTAssertEqual(try before.contentDigest(), try after.contentDigest())
        }
        let transform = try XCTUnwrap(decoded.projects[0].current.scenes[0].modelScene3D?.instances[0].transform)
        XCTAssertEqual(transform.translation.x.bitPattern, Double(0.10000000000000002).bitPattern)
        XCTAssertEqual(transform.translation.y.bitPattern, Double(-0.0).bitPattern)
        XCTAssertEqual(transform.translation.z.bitPattern, Double.leastNonzeroMagnitude.bitPattern)
        let value = try object(stored), pool = try XCTUnwrap(value["modelArrayPool"] as? [String: Any])
        for kind in ["instances", "transformTracks", "jointTracks"] { XCTAssertEqual((pool[kind] as? [Any])?.count, 1) }
        XCTAssertEqual(value["schema"] as? Int, 2); XCTAssertEqual(value["repositoryEncoding"] as? String, RepositorySnapshotCodec.encoding)
        XCTAssertThrowsError(try Codec.decoder().decode(Database.self, from: stored), "旧默认IR decoder不接受引用替代数组")
    }

    func testLegacySnapshotsAndOrdinaryPublicEncodingRemainUnchanged() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let canonical = try Codec.data(f.database)
        XCTAssertEqual(try Codec.data(RepositorySnapshotCodec.decode(canonical)), canonical)
        let publicValue = try object(canonical)
        XCTAssertNil(publicValue["repositoryEncoding"]); XCTAssertNil(publicValue["modelArrayPool"])
        var single = f.database
        single.projects[0].revisions = [single.projects[0].current]
        single.projects[0].revisions[0].scenes = [single.projects[0].revisions[0].scenes[0]]
        XCTAssertEqual(try RepositorySnapshotCodec.encode(single), try Codec.data(single), "单次数组没有共享收益时保留原表示")
        let empty = Database(), emptyBytes = try Codec.data(empty)
        XCTAssertEqual(try RepositorySnapshotCodec.encode(empty), emptyBytes)
        var changed = try object(emptyBytes); changed["schema"] = 2; changed["repositoryEncoding"] = "future"; changed["modelArrayPool"] = [:]
        XCTAssertThrowsError(try RepositorySnapshotCodec.decode(wire(changed)))
        changed["repositoryEncoding"] = RepositorySnapshotCodec.encoding
        changed["modelArrayPool"] = ["instances": [], "transformTracks": [], "jointTracks": []]
        XCTAssertThrowsError(try RepositorySnapshotCodec.decode(wire(changed)), "没有模型引用的共享壳不能假装新格式")
        XCTAssertThrowsError(try Codec.decoder().decode(Database.self, from: wire(changed)).validate(), "旧reader即使没有三维数组，也因schema2拒绝")
        changed["schema"] = 1; XCTAssertThrowsError(try RepositorySnapshotCodec.decode(wire(changed)))
        XCTAssertThrowsError(try RepositorySnapshotCodec.decode(Data()))
    }

    func testMissingWrongTypeNestedExtraAndUnknownReferencesAreRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try object(raw(f.repository)), pool = try XCTUnwrap(original["modelArrayPool"] as? [String: Any])
        let trackEntry = try XCTUnwrap((pool["transformTracks"] as? [[String: Any]])?.first)
        let wrongType = try XCTUnwrap(trackEntry["digest"] as? String)
        let invalid: [Any] = [["ref": String(repeating: "a", count: 64)], ["ref": wrongType], ["ref": ["ref": wrongType]], ["ref": wrongType, "extra": 1], [], NSNull()]
        for reference in invalid {
            var changed = original; try modifyModel(&changed) { $0["instances"] = reference }
            XCTAssertThrowsError(try RepositorySnapshotCodec.decode(wire(changed)))
        }
        var future = original; future["repositoryEncoding"] = "model-array-pool-v2"
        XCTAssertThrowsError(try RepositorySnapshotCodec.decode(wire(future)))
    }

    func testDuplicateOrphanCorruptNoncanonicalAndOversizedPoolEntriesAreRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try object(raw(f.repository)), pool = try XCTUnwrap(original["modelArrayPool"] as? [String: Any])
        let entries = try XCTUnwrap(pool["instances"] as? [[String: Any]])
        for mutation in ["duplicate", "orphan", "digest", "bytes", "noncanonical", "oversized", "undersized", "nested", "extra"] {
            var changed = original, updatedPool = pool, updatedEntries = entries
            switch mutation {
            case "duplicate": updatedEntries.append(entries[0])
            case "orphan":
                let bytes = Data("[]".utf8)
                var tracks = try XCTUnwrap(pool["transformTracks"] as? [[String: Any]])
                tracks.append(["digest": RepositorySnapshotCodec.digest(bytes, kind: "transformTracks"), "json": bytes.base64EncodedString()])
                updatedPool["transformTracks"] = tracks
            case "digest": updatedEntries[0]["digest"] = String(repeating: "f", count: 64)
            case "bytes": updatedEntries[0]["json"] = Data("broken".utf8).base64EncodedString()
            case "extra": updatedEntries[0]["extra"] = true
            default:
                let bytes: Data
                if mutation == "noncanonical" {
                    let text = try XCTUnwrap(entries[0]["json"] as? String)
                    bytes = Data(" ".utf8) + (try XCTUnwrap(Data(base64Encoded: text)))
                }
                else if mutation == "undersized" { bytes = Data("[]".utf8) }
                else if mutation == "nested" { bytes = Data("{\"ref\":\"\(entries[0]["digest"]!)\"}".utf8) }
                else { bytes = Data(("[" + Array(repeating: "{}", count: 129).joined(separator: ",") + "]").utf8) }
                updatedEntries[0] = ["digest": RepositorySnapshotCodec.digest(bytes, kind: "instances"), "json": bytes.base64EncodedString()]
            }
            updatedPool["instances"] = updatedEntries; changed["modelArrayPool"] = updatedPool
            XCTAssertThrowsError(try RepositorySnapshotCodec.decode(wire(changed)), mutation)
        }
    }

    func testSharedRepositoryNativePatchColdOpenAndBothBackupsKeepTheEntireHistory() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let project = f.database.projects[0], revision = project.current
        let quote = Quote(projectID: project.id, revisionID: revision.id, digest: try revision.contentDigest(), upper: Money(0), unit: "CNY", provider: "native", expiresAt: Date().addingTimeInterval(300), confirmed: true)
        let job = try JobRules.submit(workspaceID: project.workspaceID, project: project, quote: quote, requestKey: "shared-native", existing: [], budget: BudgetPolicy())
        try f.repository.transaction { $0.jobs = [job] }
        let before = try f.repository.read(), beforePool = try object(raw(f.repository))["modelArrayPool"]
        try f.repository.nativeJobTransaction { _, jobs in jobs[0] = try JobOperations.claim(jobs[0], owner: "original-worker") }
        let after = try f.repository.read(), cold = try Repository(root: f.repository.root, readOnly: true).read()
        XCTAssertEqual(after.generation, before.generation + 1); XCTAssertEqual(after.jobs[0].state, .running)
        XCTAssertEqual(try Codec.data(after.projects), try Codec.data(before.projects)); XCTAssertEqual(try Codec.data(cold), try Codec.data(after))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(beforePool), options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: XCTUnwrap(object(raw(f.repository))["modelArrayPool"]), options: [.sortedKeys]))
        let legacy = try Repository.restore(f.repository.backup(), to: f.root.appendingPathComponent("legacy-cold"))
        XCTAssertEqual(try Codec.data(legacy.read().projects), try Codec.data(after.projects))
        let backup = f.root.appendingPathComponent("complete.videobackup")
        _ = try f.repository.backup(to: backup)
        let restored = try Repository.restore(from: backup, to: f.root.appendingPathComponent("stream-cold"))
        XCTAssertEqual(try Codec.data(restored.read().projects), try Codec.data(after.projects))
        XCTAssertEqual(try f.repository.backupSemanticDigest(), try Repository.backupSemanticDigest(from: backup))
        XCTAssertEqual(try f.repository.backupSemanticDigest(), try restored.backupSemanticDigest())
    }
}
