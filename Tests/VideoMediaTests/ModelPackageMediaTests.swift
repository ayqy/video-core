import XCTest
import SceneKit
@testable import VideoMedia
import VideoCore

final class ModelPackageMediaTests: XCTestCase {
    private var triangle: String { """
    <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
    <asset><created>2026-11-04T00:00:00Z</created><modified>2026-11-04T00:00:00Z</modified><unit name="meter" meter="1"/><up_axis>Y_UP</up_axis></asset>
    <library_geometries><geometry id="triangle"><mesh>
      <source id="positions"><float_array id="position-array" count="9">0 0 0 1 0 0 0 1 0</float_array><technique_common><accessor source="#position-array" count="3" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
      <vertices id="vertices"><input semantic="POSITION" source="#positions"/></vertices>
      <triangles count="1"><input semantic="VERTEX" source="#vertices" offset="0"/><p>0 1 2</p></triangles>
    </mesh></geometry></library_geometries>
    <library_visual_scenes><visual_scene id="Scene"><node id="Mesh"><instance_geometry url="#triangle"/></node></visual_scene></library_visual_scenes>
    <scene><instance_visual_scene url="#Scene"/></scene></COLLADA>
    """ }

    func testOriginalModelImportRightsAndNativeMesh() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("triangle.dae")
        try Data(triangle.utf8).write(to: file)
        let repo = try Repository(root: base.appendingPathComponent("workspace"))
        let imported = try ModelPackageMedia.importPackage(modelURL: file, sourceRoot: base, workspaceID: "local", repository: repo)
        XCTAssertEqual(imported.assets.count, 1)
        XCTAssertEqual(imported.resource.inspection.geometryIDs, ["triangle"])
        XCTAssertEqual(imported.resource.model.sha256, Codec.hash(Data(triangle.utf8)))
        var db = Database(); db.assets = imported.assets
        XCTAssertThrowsError(try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false))
        var asset = db.assets[0]
        let proof = Evidence(workspaceID: "local", title: "Test mesh authored in this test", source: "test fixture source", claim: "authored triangle", owner: "test", commercialAllowed: true, verified: true, assetID: asset.id)
        asset.evidenceID = proof.id; db.assets = [asset]; db.evidence = [proof]
        let loaded = try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false)
        var actualMesh = false
        loaded.scene.rootNode.enumerateChildNodes { node, _ in actualMesh = actualMesh || node.geometry != nil }
        XCTAssertTrue(actualMesh)
        XCTAssertThrowsError(try ModelPackageMedia.load(imported.resource, workspaceID: "other", repository: repo, database: db, commercial: false))
        try Data("changed".utf8).write(to: repo.assetURL(asset))
        XCTAssertThrowsError(try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false))
    }

    func testMalformedAndExternalModelDependenciesAreRejected() throws {
        for xml in [triangle.replacingOccurrences(of: "0 0 0 1 0 0 0 1 0", with: "nan 0 0 1 0 0 0 1 0"),
                    triangle.replacingOccurrences(of: "url=\"#triangle\"", with: "url=\"https://example.invalid/mesh\""),
                    triangle.replacingOccurrences(of: "id=\"Mesh\"", with: "id=\"triangle\""),
                    "<!DOCTYPE COLLADA [<!ENTITY xx SYSTEM 'file:///tmp/secret'>]>" + triangle] {
            XCTAssertThrowsError(try DAEInspector.inspect(Data(xml.utf8)))
        }
        for path in ["../a.png", "%2e%2e/a.png", "/a.png", "https://example.invalid/a.png", "sub/../../a.png", "a.jpg"] {
            XCTAssertThrowsError(try DAEInspector.relativeTexturePath(path))
        }
        XCTAssertEqual(try DAEInspector.relativeTexturePath("textures/body.png"), "textures/body.png")
        let withChannel = triangle.replacingOccurrences(of: "<library_geometries>", with: "<library_animations><animation id=\"anim\"><sampler id=\"sampler\"/><channel source=\"#sampler\" target=\"Mesh/transform\"/></animation></library_animations><library_geometries>")
        XCTAssertEqual(try DAEInspector.inspect(Data(withChannel.utf8)).animationCount, 1)
    }

    func testTextureClosureAndSymlinkAreRejectedBeforeIngest() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let xml = triangle.replacingOccurrences(of: "<library_geometries>", with: "<library_images><image id=\"body\"><init_from>missing.png</init_from></image></library_images><library_geometries>")
        let file = base.appendingPathComponent("mesh.dae"); try Data(xml.utf8).write(to: file)
        let repo = try Repository(root: base.appendingPathComponent("workspace"))
        XCTAssertThrowsError(try ModelPackageMedia.importPackage(modelURL: file, sourceRoot: base, workspaceID: "local", repository: repo))
        let assetDirectory = base.appendingPathComponent("workspace/assets").path
        if FileManager.default.fileExists(atPath: assetDirectory) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: assetDirectory).isEmpty)
        }
        let alias = base.appendingPathComponent("alias.dae")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        XCTAssertThrowsError(try ModelPackageMedia.importPackage(modelURL: alias, sourceRoot: base, workspaceID: "local", repository: repo))
        let fact = try DAEInspector.inspect(Data(triangle.utf8))
        let ref = ModelAssetReference(assetID: "model", sha256: fact.sha256, bytes: fact.bytes, fileExtension: "dae")
        let extra = ModelAssetReference(assetID: "hidden", sha256: String(repeating: "a", count: 64), bytes: 10, fileExtension: "png")
        XCTAssertThrowsError(try ModelDAEResource(model: ref, inspection: fact, textures: ["hidden.png": extra]).validate())
    }
}
