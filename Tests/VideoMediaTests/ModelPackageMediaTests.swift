import XCTest
import SceneKit
import CoreGraphics
import ImageIO
import Darwin
#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
        XCTAssertThrowsError(try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false), "冻结原件不能跳过正常来源权利")
        var asset = db.assets[0]
        let proof = Evidence(workspaceID: "local", title: "Test mesh authored in this test", source: "test fixture source", claim: "authored triangle", owner: "test", commercialAllowed: true, verified: true, assetID: asset.id)
        asset.evidenceID = proof.id; db.assets = [asset]; db.evidence = [proof]
        let databaseBefore = try Codec.data(db)
        let frozen = try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false)
        XCTAssertEqual(frozen, [asset.id: Data(triangle.utf8)])
        XCTAssertEqual(try Codec.data(db), databaseBefore, "冻结字节不能新增或改写Asset/Evidence")
        XCTAssertThrowsError(try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "other", repository: repo, database: db, commercial: false))
        XCTAssertThrowsError(try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "", repository: repo, database: db, commercial: false))
        var cancellationChecks = 0
        XCTAssertThrowsError(try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false, cancellation: {
            cancellationChecks += 1
            if cancellationChecks == 2 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(cancellationChecks, 2, "取消须在读取原件阶段进入显式回调")
        let loaded = try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false)
        var actualMesh = false
        loaded.scene.rootNode.enumerateChildNodes { node, _ in actualMesh = actualMesh || node.geometry != nil }
        XCTAssertTrue(actualMesh)
        var draft=VideoCore.Scene(kind:.simulation,title:"模型草稿",body:"")
        draft.modelScene3D=ModelScene3D(instances:[.init(id:"mesh",name:"已入库网格",resource:imported.resource)],camera:.init(position:.init(x:0,y:1,z:4),target:.init()),lights:[.init(id:"sun",kind:.directional)])
        let revision=Revision(contentContext:.init(workspaceID:"local",name:"模型草稿"),aspect:.landscape,scenes:[draft])
        XCTAssertThrowsError(try ScenePainter.image(revision:revision,frame:0,modules:RenderModuleRegistry())) { error in
            XCTAssertEqual((error as? VideoError)?.code,"unavailable")
            XCTAssertTrue(error.localizedDescription.contains("三维模型场景") && error.localizedDescription.contains("schema9"),"正常绘制入口缺少受信schema9模块时须精确拒绝，不能退回旧二维图集")
        }
        XCTAssertThrowsError(try ModelPackageMedia.load(imported.resource, workspaceID: "other", repository: repo, database: db, commercial: false))
        try Data("changed".utf8).write(to: repo.assetURL(asset))
        XCTAssertThrowsError(try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false))
        XCTAssertThrowsError(try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "local", repository: repo, database: db, commercial: false))
        XCTAssertEqual(frozen[asset.id], Data(triangle.utf8), "后续CAS改动不能改变已经冻结的实际字节")
        XCTAssertEqual(try Codec.data(db), databaseBefore)
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

    func testExplicitCrossGroupBindingPreservesOriginalBytesAndNativeTexture() throws {
        let fixture = try BindingFixture()
        let xml = texturedTriangle(aliases: ["textures/body.png"])
        let original = Data(xml.utf8), png = try Self.png(red: 0.8, green: 0.2, blue: 0.1)
        let model = try fixture.put(original, at: "models/mesh.dae")
        let shared = try fixture.put(png, at: "shared-group/original.png")
        let imported = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
            textureBindings: ["textures/body.png": .init(url: shared, sha256: Codec.hash(png))])
        XCTAssertEqual(imported.resource.model.sha256, Codec.hash(original))
        XCTAssertEqual(imported.resource.inspection, try DAEInspector.inspect(original))
        XCTAssertEqual(Set(imported.resource.textures.keys), ["textures/body.png"])
        XCTAssertEqual(imported.resource.textures["textures/body.png"]?.sha256, Codec.hash(png))
        XCTAssertEqual(try Data(contentsOf: model), original)
        XCTAssertEqual(try Data(contentsOf: shared), png)
        for asset in imported.assets {
            XCTAssertEqual(try Data(contentsOf: fixture.repository.assetURL(asset)), asset.ext == "dae" ? original : png)
        }
        var withoutRights = Database(); withoutRights.assets = imported.assets
        XCTAssertThrowsError(try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: withoutRights, commercial: false), "显式绑定不自动授予来源确认")
        XCTAssertThrowsError(try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "local", repository: fixture.repository, database: withoutRights, commercial: false))
        let authorizedDatabase = authorized(imported)
        let authorizedBefore = try Codec.data(authorizedDatabase)
        let bank = try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "local", repository: fixture.repository, database: authorizedDatabase, commercial: false)
        XCTAssertEqual(Set(bank.keys), imported.resource.assetIDs, "Host冻结须包含完整DAE和每个实际PNG")
        XCTAssertEqual(bank[imported.resource.model.assetID], original)
        let textureReference = try XCTUnwrap(imported.resource.textures["textures/body.png"])
        XCTAssertEqual(bank[textureReference.assetID], png)
        XCTAssertEqual(try Codec.data(authorizedDatabase), authorizedBefore)
        // A byte-only technical decoder is deliberately not a source-right
        // authorization API: it receives no DB and creates no synthetic proof.
        let unapprovedBefore = try Codec.data(withoutRights), inventoryBefore = try Self.inventory(fixture.repository)
        let byteLoaded = try ModelPackageMedia.loadByteClosure(imported.resource, assets: bank)
        XCTAssertEqual(byteLoaded.resource, imported.resource)
        XCTAssertEqual(Set(byteLoaded.materialsBySourceID.keys), ["SkinMaterial"])
        let byteMaterial = try XCTUnwrap(byteLoaded.materialsBySourceID["SkinMaterial"]?.first)
        XCTAssertTrue(Self.materials(byteLoaded.scene).contains { $0 === byteMaterial }, "原material.id映射须指向真实字节加载产生的网格材质")
        XCTAssertEqual(try Self.nativePixels(byteMaterial.diffuse), try Self.pixels(Self.image(png)))
        XCTAssertEqual(try Codec.data(withoutRights), unapprovedBefore)
        XCTAssertTrue(withoutRights.evidence.isEmpty, "技术解码不代表来源、商用或媒体效果通过")
        XCTAssertEqual(try Self.inventory(fixture.repository), inventoryBefore)
        for id in imported.resource.assetIDs {
            var missing = bank; missing.removeValue(forKey: id)
            XCTAssertThrowsError(try ModelPackageMedia.loadByteClosure(imported.resource, assets: missing), "原DAE或任一PNG缺失须拒绝，不能落到磁盘同名素材")
            var corrupted = bank
            var changed = try XCTUnwrap(corrupted[id]); changed[changed.startIndex] ^= 1; corrupted[id] = changed
            XCTAssertThrowsError(try ModelPackageMedia.loadByteClosure(imported.resource, assets: corrupted), "保持长度但改变实际字节也须拒绝")
        }
        var forged = imported.resource
        forged.inspection.geometryIDs.append("fabricated-geometry")
        XCTAssertThrowsError(try ModelPackageMedia.loadByteClosure(forged, assets: bank), "合法形状的伪造inspection仍须与实际DAE重解析结果逐项一致")
        XCTAssertThrowsError(try ModelPackageMedia.loadByteClosure(imported.resource, assets: bank, cancellation: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Codec.data(withoutRights), unapprovedBefore)
        XCTAssertEqual(try Self.inventory(fixture.repository), inventoryBefore)
        let loaded = try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: authorized(imported), commercial: false)
        XCTAssertEqual(loaded.resource, imported.resource, "临时材质name投影不得回写原资源或inspection")
        XCTAssertEqual(Self.materials(loaded.scene).map(\.name), ["SkinMaterial"], "实际无name源材质须以唯一原material.id映射")
        XCTAssertEqual(Set(loaded.materialsBySourceID.keys), ["SkinMaterial"])
        XCTAssertEqual(loaded.materialsBySourceID["SkinMaterial"]?.map(ObjectIdentifier.init), Self.materials(loaded.scene).map(ObjectIdentifier.init), "映射必须指向实际网格对象而非独立SceneSource副本")
        XCTAssertEqual(Self.geometrySignature(loaded.scene), try Self.geometrySignature(Self.rawScene(original)), "仅投影材质名称，全部实际顶点/法线/UV及索引须保留")
        var textures = 0
        var nativeProperties: [SCNMaterialProperty] = []
        loaded.scene.rootNode.enumerateChildNodes { node, _ in
            for material in node.geometry?.materials ?? [] {
                XCTAssertEqual(material.lightingModel, .lambert)
                nativeProperties.append(material.diffuse)
            }
        }
        for property in nativeProperties {
            XCTAssertEqual(try Self.nativePixels(property), try Self.pixels(Self.image(png))); textures += 1
        }
        XCTAssertGreaterThan(textures, 0, "实际原生材质须持有完整原PNG像素，不能只加载无纹理网格")

        // Both aliases are actually used by different native material slots.
        // A second unused library_image would not expose basename collisions.
        let dualOriginal = Data(dualTexturedTriangle().utf8)
        let dualModel = try fixture.put(dualOriginal, at: "models/two-materials.dae")
        let secondPNG = try Self.png(red: 0.1, green: 0.3, blue: 0.9)
        let firstSource = try fixture.put(png, at: "groups/one/body.png")
        let secondSource = try fixture.put(secondPNG, at: "groups/two/body.png")
        let expected = ["one/body.png": Codec.hash(png), "two/body.png": Codec.hash(secondPNG)]
        let dual = try ModelPackageMedia.importPackage(modelURL: dualModel, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
            textureBindings: ["one/body.png": .init(url: firstSource, sha256: Codec.hash(png)),
                              "two/body.png": .init(url: secondSource, sha256: Codec.hash(secondPNG))])
        XCTAssertEqual(dual.resource.model.sha256, Codec.hash(dualOriginal))
        XCTAssertEqual(dual.resource.inspection.materials.count, 2)
        XCTAssertEqual(Set(dual.resource.textures.keys), Set(expected.keys))
        for (alias, hash) in expected { XCTAssertEqual(dual.resource.textures[alias]?.sha256, hash) }
        let native = try ModelPackageMedia.load(dual.resource, workspaceID: "local", repository: fixture.repository, database: authorized(dual), commercial: false)
        var materials: [SCNMaterial] = []
        native.scene.rootNode.enumerateChildNodes { node, _ in materials += node.geometry?.materials ?? [] }
        XCTAssertEqual(materials.count, 2, "两份effect/material必须都进入实际原生网格材质槽")
        XCTAssertEqual(Set(materials.compactMap(\.name)), ["SkinMaterial", "AlreadyNamedMaterial"], "已有name原样保留，只补缺失name")
        XCTAssertEqual(Set(native.materialsBySourceID.keys), ["SkinMaterial", "SecondMaterial"])
        XCTAssertNil(native.materialsBySourceID["AlreadyNamedMaterial"], "display name不能被猜成原material.id")
        let named = try XCTUnwrap(native.materialsBySourceID["SecondMaterial"]?.first)
        XCTAssertEqual(named.name, "AlreadyNamedMaterial")
        XCTAssertTrue(materials.contains { $0 === named })
        let mapped = native.materialsBySourceID.values.flatMap { $0 }.map(ObjectIdentifier.init)
        XCTAssertEqual(Set(mapped).count, mapped.count, "同一实际材质只归属一个原ID且不重复")
        // Direct CGImage binding has no dynamic URL resolution. Compare every
        // actual material's complete RGBA against each independently decoded
        // source, retaining the two distinct material/alias/CAS SHA assertions.
        let pixelHashes = try materials.map { material -> String in
            XCTAssertEqual(material.lightingModel, .lambert)
            return Codec.hash(try Self.nativePixels(material.diffuse))
        }
        let expectedPixels = [Codec.hash(try Self.pixels(Self.image(png))), Codec.hash(try Self.pixels(Self.image(secondPNG)))]
        XCTAssertEqual(pixelHashes.sorted(), expectedPixels.sorted(), "两份实际材质必须分别得到各自选定PNG的全部RGBA，不能混成同一同名图")
        XCTAssertEqual(Set(pixelHashes).count, 2)
        XCTAssertEqual(try Data(contentsOf: dualModel), dualOriginal)
        XCTAssertEqual(try Data(contentsOf: firstSource), png)
        XCTAssertEqual(try Data(contentsOf: secondSource), secondPNG)
        let textureAsset = try XCTUnwrap(imported.assets.first { $0.id == textureReference.assetID })
        let textureCAS = fixture.repository.assetURL(textureAsset)
        var badCAS = png; badCAS[badCAS.startIndex] ^= 1
        try badCAS.write(to: textureCAS)
        defer { try? png.write(to: textureCAS) }
        XCTAssertThrowsError(try ModelPackageMedia.verifiedByteClosure(imported.resource, workspaceID: "local", repository: fixture.repository, database: authorizedDatabase, commercial: false), "同大小CAS原件被改动仍须在原SHA核验阶段拒绝")
        XCTAssertEqual(bank[textureReference.assetID], png)
        XCTAssertEqual(try Codec.data(authorizedDatabase), authorizedBefore)
    }

    func testExplicitBindingOverridesSameNameAndNeverFallsBack() throws {
        let fixture = try BindingFixture()
        let model = try fixture.put(Data(texturedTriangle(aliases: ["body.png"]).utf8), at: "models/mesh.dae")
        let red = try Self.png(red: 1, green: 0, blue: 0), blue = try Self.png(red: 0, green: 0, blue: 1)
        _ = try fixture.put(blue, at: "models/body.png")
        let selected = try fixture.put(red, at: "shared-group/body.png")
        let legacy = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository)
        XCTAssertEqual(legacy.resource.textures["body.png"]?.sha256, Codec.hash(blue), "旧调用继续只使用原模型旁的纹理")
        let imported = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
            textureBindings: ["body.png": .init(url: selected, sha256: Codec.hash(red))])
        XCTAssertEqual(imported.resource.textures["body.png"]?.sha256, Codec.hash(red))
        XCTAssertNotEqual(imported.resource.textures["body.png"]?.sha256, Codec.hash(blue))
        try rejected(fixture, model: model, bindings: ["body.png": .init(url: selected, sha256: Codec.hash(blue))])
        try rejected(fixture, model: model, bindings: ["body.png": .init(url: fixture.sources.appendingPathComponent("missing/body.png"), sha256: Codec.hash(red))])
        try rejected(fixture, model: model, bindings: ["body.png": .init(url: selected, sha256: String(repeating: "g", count: 64))])
    }

    func testRepeatedAliasesShareTheExplicitOriginalPNGClosure() throws {
        let fixture = try BindingFixture()
        let model = try fixture.put(Data(texturedTriangle(aliases: ["one/body.png", "two/body.png", "one/body.png"]).utf8), at: "models/mesh.dae")
        let png = try Self.png(red: 0.2, green: 0.7, blue: 0.3)
        let source = try fixture.put(png, at: "shared-group/body.png")
        let binding = ModelTextureBinding(url: source, sha256: Codec.hash(png))
        let imported = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
            textureBindings: ["one/body.png": binding, "two/body.png": binding])
        XCTAssertEqual(imported.resource.inspection.images.count, 3)
        XCTAssertEqual(Set(imported.resource.textures.keys), ["one/body.png", "two/body.png"])
        XCTAssertTrue(imported.resource.textures.values.allSatisfy { $0.sha256 == Codec.hash(png) })
        XCTAssertEqual(try Self.inventory(fixture.repository).count, 2, "不同DAE别名复用同一PNG实际字节，CAS只有原模型和一份PNG")
        try imported.resource.validate(assets: imported.assets)
        _ = try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: authorized(imported), commercial: false)
    }

    func testInvalidBindingsAndLastDependencyFailBeforeAnyCASWrite() throws {
        let fixture = try BindingFixture()
        _ = try fixture.repository.ingest(Data("existing unrelated asset".utf8), name: "keep.txt", workspaceID: "local", mediaType: "text")
        let xml = texturedTriangle(aliases: ["a.png", "z.png"])
        let model = try fixture.put(Data(xml.utf8), at: "models/mesh.dae")
        let png = try Self.png(red: 0.5, green: 0.4, blue: 0.3)
        _ = try fixture.put(png, at: "models/a.png")
        let shared = try fixture.put(png, at: "shared-group/z.png")
        let binding = ModelTextureBinding(url: shared, sha256: Codec.hash(png))
        for key in ["hidden.png", "%61.png", "../a.png"] { try rejected(fixture, model: model, bindings: [key: binding]) }
        let outside = fixture.base.appendingPathComponent("outside.png"); try png.write(to: outside)
        let leaf = fixture.sources.appendingPathComponent("leaf.png")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: shared)
        let linkedParent = fixture.sources.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: shared.deletingLastPathComponent())
        let bad = try fixture.put(Data("not a PNG".utf8), at: "shared-group/bad.png")
        for (url, hash) in [(outside, Codec.hash(png)), (leaf, Codec.hash(png)),
                            (linkedParent.appendingPathComponent("z.png"), Codec.hash(png)), (bad, Codec.hash(Data("not a PNG".utf8)))] {
            try rejected(fixture, model: model, bindings: ["z.png": .init(url: url, sha256: hash)])
        }
        let hardlink = fixture.sources.appendingPathComponent("hardlink.png")
        XCTAssertEqual(Darwin.link(shared.path, hardlink.path), 0)
        try rejected(fixture, model: model, bindings: ["z.png": .init(url: hardlink, sha256: Codec.hash(png))])
        let large = fixture.sources.appendingPathComponent("large.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: 33 * 1024 * 1024); try handle.close()
        try rejected(fixture, model: model, bindings: ["z.png": .init(url: large, sha256: String(repeating: "a", count: 64))])
        let noID = try fixture.put(Data(xml.replacingOccurrences(of: "<image id=\"Image0\">", with: "<image>").utf8), at: "models/no-image-id.dae")
        try rejected(fixture, model: noID, bindings: ["z.png": binding])
        let fifo = fixture.sources.appendingPathComponent("fifo.png")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        let before = try Self.inventory(fixture.repository)
        try Self.assertFIFORejected(path: fifo.path) {
            _ = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
                textureBindings: ["z.png": .init(url: fifo, sha256: Codec.hash(png))])
        }
        XCTAssertEqual(try Self.inventory(fixture.repository), before)
    }

    func testBadExistingCASIsPreflightedAndLoadRejectsUnsafeStoredFiles() throws {
        do {
            let fixture = try BindingFixture()
            let original = Data(texturedTriangle(aliases: ["a.png", "z.png"]).utf8)
            let model = try fixture.put(original, at: "models/mesh.dae")
            let first = try Self.png(red: 1, green: 0, blue: 0), last = try Self.png(red: 0, green: 0, blue: 1)
            _ = try fixture.put(first, at: "models/a.png")
            let selected = try fixture.put(last, at: "shared-group/z.png")
            let assets = fixture.repository.root.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
            let existing = assets.appendingPathComponent(Codec.hash(last) + ".png")
            var damaged = last; damaged[damaged.count - 1] ^= 1
            try damaged.write(to: existing)
            try rejected(fixture, model: model, bindings: ["z.png": .init(url: selected, sha256: Codec.hash(last))])
            XCTAssertFalse(FileManager.default.fileExists(atPath: assets.appendingPathComponent(Codec.hash(original) + ".dae").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: assets.appendingPathComponent(Codec.hash(first) + ".png").path))
            try FileManager.default.removeItem(at: existing)
            try FileManager.default.createSymbolicLink(at: existing, withDestinationURL: selected)
            try rejected(fixture, model: model, bindings: ["z.png": .init(url: selected, sha256: Codec.hash(last))])
        }
        do {
            let fixture = try BindingFixture()
            let model = try fixture.put(Data(texturedTriangle(aliases: ["body.png"]).utf8), at: "models/mesh.dae")
            let png = try Self.png(red: 0.3, green: 0.6, blue: 0.8)
            let selected = try fixture.put(png, at: "shared-group/body.png")
            let imported = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
                textureBindings: ["body.png": .init(url: selected, sha256: Codec.hash(png))])
            let database = authorized(imported)
            _ = try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: database, commercial: false)
            let textureID = try XCTUnwrap(imported.resource.textures["body.png"]?.assetID)
            let asset = try XCTUnwrap(imported.assets.first { $0.id == textureID })
            let stored = fixture.repository.assetURL(asset)
            try FileManager.default.removeItem(at: stored)
            try FileManager.default.createSymbolicLink(at: stored, withDestinationURL: selected)
            XCTAssertThrowsError(try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: database, commercial: false))
            try FileManager.default.removeItem(at: stored)
            XCTAssertEqual(Darwin.mkfifo(stored.path, 0o600), 0)
            try Self.assertFIFORejected(path: stored.path) {
                _ = try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: database, commercial: false)
            }
        }
        do {
            let fixture = try BindingFixture()
            let model = try fixture.put(Data(texturedTriangle(aliases: ["body.png"]).utf8), at: "models/mesh.dae")
            let png = try Self.png(red: 0.3, green: 0.6, blue: 0.8)
            let selected = try fixture.put(png, at: "shared-group/body.png")
            let outside = fixture.base.appendingPathComponent("outside-cas")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let assets = fixture.repository.root.appendingPathComponent("assets")
            try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: outside)
            XCTAssertThrowsError(try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
                textureBindings: ["body.png": .init(url: selected, sha256: Codec.hash(png))]))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "目标CAS父目录链接不得导入到工作区外")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: assets.path), outside.path)
        }
    }

    func testActualTextureSlotsNormalUVOneAndSamplerWrapArePreserved() throws {
        let fixture = try BindingFixture()
        let xml = try textureSlotFixture()
        let body = try Self.png(red: 0.8, green: 0.2, blue: 0.1, width: 16, height: 8)
        let normal = try Self.png(red: 0.5, green: 0.5, blue: 1, width: 16, height: 8)
        let model = try fixture.put(Data(xml.utf8), at: "models/slots.dae")
        let first = try fixture.put(body, at: "group/body.png"), second = try fixture.put(normal, at: "group/normal.png")
        let imported = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
            textureBindings: ["body.png": .init(url: first, sha256: Codec.hash(body)), "normal.png": .init(url: second, sha256: Codec.hash(normal))])
        let loaded = try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: authorized(imported), commercial: false)
        let material = try XCTUnwrap(Self.materials(loaded.scene).first)
        let original = try XCTUnwrap(Self.materials(Self.rawScene(Data(xml.utf8))).first)
        XCTAssertEqual(material.lightingModel, .phong)
        for property in [material.emission, material.ambient, material.diffuse, material.specular, material.reflective, material.transparent] {
            XCTAssertEqual(try Self.nativePixels(property), try Self.pixels(Self.image(body)))
            XCTAssertEqual(property.mappingChannel, 1)
            XCTAssertEqual(property.wrapS, .mirror); XCTAssertEqual(property.wrapT, .clamp)
        }
        XCTAssertEqual(try Self.nativePixels(material.normal), try Self.pixels(Self.image(normal)))
        XCTAssertEqual(material.normal.mappingChannel, 1)
        XCTAssertEqual(material.normal.wrapS, .repeat); XCTAssertEqual(material.normal.wrapT, .clampToBorder)
        XCTAssertEqual(material.transparency, original.transparency)
        XCTAssertEqual(material.transparencyMode, original.transparencyMode)
        XCTAssertEqual(material.diffuse.contentsTransform.m22, original.diffuse.contentsTransform.m22, "不另做UV T翻转")
        var channels: [SCNGeometrySource] = [], rawChannels: [SCNGeometrySource] = []
        loaded.scene.rootNode.enumerateChildNodes { node, _ in if channels.isEmpty { channels = node.geometry?.sources(for: .texcoord) ?? [] } }
        let raw = try Self.rawScene(Data(xml.utf8))
        raw.rootNode.enumerateChildNodes { node, _ in if rawChannels.isEmpty { rawChannels = node.geometry?.sources(for: .texcoord) ?? [] } }
        XCTAssertEqual(channels.count, 2); XCTAssertEqual(rawChannels.count, 2)
        guard channels.count == 2, rawChannels.count == 2 else { return }
        XCTAssertEqual(try Self.uv(channels[1]), try Self.uv(rawChannels[1]), "适配不得重写原网格的第二套UV")
        XCTAssertNotEqual(try Self.uv(channels[0]), try Self.uv(channels[1]), "UV1对照须实际区别于UV0")
    }

    func testAmbiguousMaterialSamplerAndConflictingUVChainsAreRejected() throws {
        let base = texturedTriangle(aliases: ["body.png"])
        let variants = [
            base.replacingOccurrences(of: "</library_materials>", with: "<material id=\"UnusedMaterial\" name=\"SkinMaterial\"><instance_effect url=\"#SkinEffect\"/></material></library_materials>"),
            base.replacingOccurrences(of: "texture=\"sampler\"", with: "texture=\"unknownSampler\""),
            base.replacingOccurrences(of: "</visual_scene>", with: "<node id=\"SecondMesh\"><instance_geometry url=\"#triangle\"><bind_material><technique_common><instance_material symbol=\"SkinSymbol\" target=\"#SkinMaterial\"><bind_vertex_input semantic=\"UVSET0\" input_semantic=\"TEXCOORD\" input_set=\"1\"/></instance_material></technique_common></bind_material></instance_geometry></node></visual_scene>"),
            base.replacingOccurrences(of: "<instance_effect url=\"#SkinEffect\"/>", with: "<instance_effect url=\"#SkinEffect\"><setparam ref=\"sampler\"><float>1</float></setparam></instance_effect>"),
            base.replacingOccurrences(of: " set=\"0\"", with: " set=\"2\""),
            base.replacingOccurrences(of: "</sampler2D>", with: "<minfilter>NEAREST</minfilter></sampler2D>")
        ]
        for (index, xml) in variants.enumerated() {
            let fixture = try BindingFixture()
            let model = try fixture.put(Data(xml.utf8), at: "models/rejected-\(index).dae")
            let png = try Self.png(red: 0.2, green: 0.4, blue: 0.8)
            let selected = try fixture.put(png, at: "group/body.png")
            let imported = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
                textureBindings: ["body.png": .init(url: selected, sha256: Codec.hash(png))])
            let before = try Self.inventory(fixture.repository)
            XCTAssertThrowsError(try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: authorized(imported), commercial: false), "多义或未支持材质链必须明确拒绝，case=\(index)")
            XCTAssertEqual(try Self.inventory(fixture.repository), before, "加载阶段拒绝不得改动已入库原件；不冒称导入阶段零写入")
        }
    }

    func testTextureAdapterKeepsOtherMaterialConstantsAndLightingUnchanged() throws {
        let fixture = try BindingFixture()
        var xml = dualTexturedTriangle()
        let start = try XCTUnwrap(xml.range(of: "<effect id=\"SecondEffect\">"))
        let end = try XCTUnwrap(xml.range(of: "</effect>", range: start.upperBound..<xml.endIndex))
        let constant = """
        <effect id="SecondEffect"><profile_COMMON><technique sid="common"><phong>
        <emission><color>0.1 0.2 0.3 1</color></emission><ambient><color>0.2 0.3 0.4 1</color></ambient>
        <diffuse><color>0.3 0.4 0.5 1</color></diffuse><specular><color>0.4 0.5 0.6 1</color></specular><shininess><float>17</float></shininess>
        <reflective><color>0.05 0.06 0.07 1</color></reflective><reflectivity><float>0.3</float></reflectivity>
        <transparent opaque="A_ONE"><color>1 1 1 0.7</color></transparent><transparency><float>0.6</float></transparency>
        <index_of_refraction><float>1.2</float></index_of_refraction></phong></technique></profile_COMMON></effect>
        """
        xml.replaceSubrange(start.lowerBound..<end.upperBound, with: constant)
        let data = Data(xml.utf8), model = try fixture.put(data, at: "models/constants.dae")
        let png = try Self.png(red: 0.7, green: 0.1, blue: 0.3)
        let source = try fixture.put(png, at: "group/body.png")
        let binding = ModelTextureBinding(url: source, sha256: Codec.hash(png))
        let imported = try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository,
            textureBindings: ["one/body.png": binding, "two/body.png": binding])
        let loaded = try ModelPackageMedia.load(imported.resource, workspaceID: "local", repository: fixture.repository, database: authorized(imported), commercial: false)
        let raw = try Self.rawScene(data)
        let old = try XCTUnwrap(Self.materials(raw).first { $0.name == "AlreadyNamedMaterial" })
        let current = try XCTUnwrap(Self.materials(loaded.scene).first { $0.name == "AlreadyNamedMaterial" })
        XCTAssertTrue(loaded.materialsBySourceID["SecondMaterial"]?.contains { $0 === current } == true)
        XCTAssertEqual(current.name, old.name, "源材质已有name时不得改成id或effect名")
        XCTAssertEqual(current.lightingModel, old.lightingModel)
        XCTAssertEqual(current.shininess, old.shininess); XCTAssertEqual(current.transparency, old.transparency)
        XCTAssertEqual(current.fresnelExponent, old.fresnelExponent); XCTAssertEqual(current.transparencyMode, old.transparencyMode)
        let previous = [old.emission, old.ambient, old.diffuse, old.specular, old.reflective, old.transparent]
        let actual = [current.emission, current.ambient, current.diffuse, current.specular, current.reflective, current.transparent]
        for (before, after) in zip(previous, actual) {
            XCTAssertEqual(try Self.color(before), try Self.color(after))
            XCTAssertEqual(before.mappingChannel, after.mappingChannel)
            XCTAssertEqual(before.wrapS, after.wrapS); XCTAssertEqual(before.wrapT, after.wrapT)
        }
        let textured = try XCTUnwrap(Self.materials(loaded.scene).first { ["SkinMaterial", "SkinEffect"].contains($0.name ?? "") })
        XCTAssertEqual(try Self.nativePixels(textured.diffuse), try Self.pixels(Self.image(png)))
        XCTAssertEqual(try Data(contentsOf: model), data)

        // A genuinely untextured original still has exact ID attribution; no
        // UV or PNG may be invented merely to expose a constant material.
        let plainXML = triangle.replacingOccurrences(of: "<library_geometries>", with:
            "<library_effects>" + constant + "</library_effects><library_materials><material id=\"OnlyConstant\" name=\"ConstantDisplayName\"><instance_effect url=\"#SecondEffect\"/></material></library_materials><library_geometries>")
            .replacingOccurrences(of: "<triangles count=\"1\">", with: "<triangles count=\"1\" material=\"ConstantSymbol\">")
            .replacingOccurrences(of: "<instance_geometry url=\"#triangle\"/>", with: "<instance_geometry url=\"#triangle\"><bind_material><technique_common><instance_material symbol=\"ConstantSymbol\" target=\"#OnlyConstant\"/></technique_common></bind_material></instance_geometry>")
        let plainData = Data(plainXML.utf8), plainURL = try fixture.put(plainData, at: "models/untextured-constant.dae")
        let plain = try ModelPackageMedia.importPackage(modelURL: plainURL, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository)
        XCTAssertTrue(plain.resource.textures.isEmpty)
        let plainNative = try ModelPackageMedia.load(plain.resource, workspaceID: "local", repository: fixture.repository, database: authorized(plain), commercial: false)
        let plainMaterial = try XCTUnwrap(plainNative.materialsBySourceID["OnlyConstant"]?.first)
        let plainOriginal = try XCTUnwrap(Self.materials(Self.rawScene(plainData)).first)
        XCTAssertEqual(Set(plainNative.materialsBySourceID.keys), ["OnlyConstant"])
        XCTAssertEqual(plainMaterial.name, "ConstantDisplayName")
        XCTAssertNil(plainNative.materialsBySourceID["ConstantDisplayName"])
        XCTAssertEqual(plainMaterial.lightingModel, plainOriginal.lightingModel)
        XCTAssertEqual(try Self.color(plainMaterial.diffuse), try Self.color(plainOriginal.diffuse))
        XCTAssertEqual(plainMaterial.transparency, plainOriginal.transparency)
        XCTAssertEqual(try Data(contentsOf: plainURL), plainData)
    }

    private func rejected(_ fixture: BindingFixture, model: URL, bindings: [String: ModelTextureBinding]) throws {
        let before = try Self.inventory(fixture.repository)
        XCTAssertThrowsError(try ModelPackageMedia.importPackage(modelURL: model, sourceRoot: fixture.sources, workspaceID: "local", repository: fixture.repository, textureBindings: bindings))
        XCTAssertEqual(try Self.inventory(fixture.repository), before, "前置绑定/素材/已存CAS校验失败不得新增或改动任何CAS文件")
    }

    private func authorized(_ imported: ImportedModelPackage) -> Database {
        var database = Database()
        for var asset in imported.assets {
            let proof = Evidence(workspaceID: "local", title: "明确自造的纹理模型夹具", source: "ModelPackageMediaTests authored bytes", claim: "authored mesh and PNG", owner: "test", commercialAllowed: true, verified: true, assetID: asset.id)
            asset.evidenceID = proof.id; database.assets.append(asset); database.evidence.append(proof)
        }
        return database
    }

    private func texturedTriangle(aliases: [String]) -> String {
        let images = aliases.enumerated().map { "<image id=\"Image\($0.offset)\"><init_from>\($0.element)</init_from></image>" }.joined()
        let materials = """
        <library_images>\(images)</library_images>
        <library_effects><effect id="SkinEffect"><profile_COMMON>
        <newparam sid="surface"><surface type="2D"><init_from>Image0</init_from></surface></newparam>
        <newparam sid="sampler"><sampler2D><source>surface</source></sampler2D></newparam>
        <technique sid="common"><lambert><emission><color>0 0 0 1</color></emission><diffuse><texture texture="sampler" texcoord="UVSET0"/></diffuse></lambert></technique>
        </profile_COMMON></effect></library_effects>
        <library_materials><material id="SkinMaterial"><instance_effect url="#SkinEffect"/></material></library_materials>
        """
        let uv = """
        <source id="uv"><float_array id="uv-array" count="6">0 0 1 0 0 1</float_array><technique_common><accessor source="#uv-array" count="3" stride="2"><param name="S" type="float"/><param name="T" type="float"/></accessor></technique_common></source>
        """
        return triangle.replacingOccurrences(of: "<library_geometries>", with: materials + "<library_geometries>")
            .replacingOccurrences(of: "<vertices id=\"vertices\">", with: uv + "<vertices id=\"vertices\">")
            .replacingOccurrences(of: "<triangles count=\"1\">", with: "<triangles count=\"1\" material=\"SkinSymbol\">")
            .replacingOccurrences(of: "<p>0 1 2</p>", with: "<input semantic=\"TEXCOORD\" source=\"#uv\" offset=\"1\" set=\"0\"/><p>0 0 1 1 2 2</p>")
            .replacingOccurrences(of: "<instance_geometry url=\"#triangle\"/>", with: "<instance_geometry url=\"#triangle\"><bind_material><technique_common><instance_material symbol=\"SkinSymbol\" target=\"#SkinMaterial\"><bind_vertex_input semantic=\"UVSET0\" input_semantic=\"TEXCOORD\" input_set=\"0\"/></instance_material></technique_common></bind_material></instance_geometry>")
    }

    private func dualTexturedTriangle() -> String {
        let effect = """
        <effect id="SecondEffect"><profile_COMMON>
        <newparam sid="secondSurface"><surface type="2D"><init_from>Image1</init_from></surface></newparam>
        <newparam sid="secondSampler"><sampler2D><source>secondSurface</source></sampler2D></newparam>
        <technique sid="secondCommon"><lambert><emission><color>0 0 0 1</color></emission><diffuse><texture texture="secondSampler" texcoord="UVSET0"/></diffuse></lambert></technique>
        </profile_COMMON></effect>
        """
        let element = """
        <triangles count="1" material="SecondSymbol"><input semantic="VERTEX" source="#vertices" offset="0"/><input semantic="TEXCOORD" source="#uv" offset="1" set="0"/><p>0 0 1 1 2 2</p></triangles>
        """
        let binding = """
        <instance_material symbol="SecondSymbol" target="#SecondMaterial"><bind_vertex_input semantic="UVSET0" input_semantic="TEXCOORD" input_set="0"/></instance_material>
        """
        return texturedTriangle(aliases: ["one/body.png", "two/body.png"])
            .replacingOccurrences(of: "</library_effects>", with: effect + "</library_effects>")
            .replacingOccurrences(of: "</library_materials>", with: "<material id=\"SecondMaterial\" name=\"AlreadyNamedMaterial\"><instance_effect url=\"#SecondEffect\"/></material></library_materials>")
            .replacingOccurrences(of: "</mesh>", with: element + "</mesh>")
            .replacingOccurrences(of: "</technique_common></bind_material>", with: binding + "</technique_common></bind_material>")
    }

    private func textureSlotFixture() throws -> String {
        var xml = texturedTriangle(aliases: ["body.png", "normal.png"])
        let old = "<lambert><emission><color>0 0 0 1</color></emission><diffuse><texture texture=\"sampler\" texcoord=\"UVSET0\"/></diffuse></lambert>"
        let fields = ["emission", "ambient", "diffuse", "specular", "reflective", "transparent"].map { slot in
            "<\(slot)\(slot == "transparent" ? " opaque=\"A_ONE\"" : "")><texture texture=\"sampler\" texcoord=\"UVSET1\"/></\(slot)>"
        }.joined()
        let shader = "<phong>" + fields + "<transparency><float>0.6</float></transparency></phong><extra><technique profile=\"FCOLLADA\"><bump bumptype=\"NORMALMAP\"><texture texture=\"normalSampler\" texcoord=\"UVSET1\"/></bump></technique></extra>"
        XCTAssertTrue(xml.contains(old)); xml = xml.replacingOccurrences(of: old, with: shader)
        xml = xml.replacingOccurrences(of: "<sampler2D><source>surface</source></sampler2D>", with: "<sampler2D><source>surface</source><wrap_s>MIRROR</wrap_s><wrap_t>CLAMP</wrap_t></sampler2D>")
        let normal = "<newparam sid=\"normalSurface\"><surface type=\"2D\"><init_from>Image1</init_from></surface></newparam><newparam sid=\"normalSampler\"><sampler2D><source>normalSurface</source><wrap_s>WRAP</wrap_s><wrap_t>BORDER</wrap_t></sampler2D></newparam>"
        xml = xml.replacingOccurrences(of: "<technique sid=\"common\">", with: normal + "<technique sid=\"common\">")
        let uv = "<source id=\"uvSecond\"><float_array id=\"uvSecondArray\" count=\"6\">1 1 0 1 1 0</float_array><technique_common><accessor source=\"#uvSecondArray\" count=\"3\" stride=\"2\"><param name=\"S\" type=\"float\"/><param name=\"T\" type=\"float\"/></accessor></technique_common></source>"
        xml = xml.replacingOccurrences(of: "<vertices id=\"vertices\">", with: uv + "<vertices id=\"vertices\">")
        xml = xml.replacingOccurrences(of: "<p>0 0 1 1 2 2</p>", with: "<input semantic=\"TEXCOORD\" source=\"#uvSecond\" offset=\"2\" set=\"1\"/><p>0 0 0 1 1 1 2 2 2</p>")
        xml = xml.replacingOccurrences(of: "</instance_material>", with: "<bind_vertex_input semantic=\"UVSET1\" input_semantic=\"TEXCOORD\" input_set=\"1\"/></instance_material>")
        return xml
    }

    private static func image(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
    }
    private static func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
    private static func nativePixels(_ property: SCNMaterialProperty) throws -> Data {
        let contents = try XCTUnwrap(property.contents)
        #if os(macOS)
        if let image = contents as? NSImage { return try pixels(XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))) }
        #else
        if let image = contents as? UIImage { return try pixels(XCTUnwrap(image.cgImage)) }
        #endif
        guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { throw VideoError.invalid("实际纹理须直接持有原PNG图像，不能以URL或常量冒充") }
        return try pixels(contents as! CGImage)
    }
    private static func materials(_ scene: SCNScene) -> [SCNMaterial] {
        var result: [SCNMaterial] = [], seen = Set<ObjectIdentifier>()
        scene.rootNode.enumerateChildNodes { node, _ in
            for material in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(material)).inserted { result.append(material) }
        }
        return result
    }
    private static func geometrySignature(_ scene: SCNScene) -> [String] {
        var result: [String] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for semantic in [SCNGeometrySource.Semantic.vertex, .normal, .texcoord] {
                for source in geometry.sources(for: semantic) {
                    result.append("\(semantic.rawValue)|\(source.vectorCount)|\(source.componentsPerVector)|\(source.bytesPerComponent)|\(source.dataOffset)|\(source.dataStride)|\(source.usesFloatComponents)|\(Codec.hash(source.data))")
                }
            }
            for element in geometry.elements { result.append("indices|\(element.primitiveType.rawValue)|\(element.primitiveCount)|\(element.bytesPerIndex)|\(Codec.hash(element.data))") }
        }
        return result.sorted()
    }
    private static func rawScene(_ data: Data) throws -> SCNScene {
        let source = try XCTUnwrap(SCNSceneSource(data: data, options: nil))
        return try source.scene(options: [.checkConsistency: true, .convertToYUp: true, .convertUnitsToMeters: 1.0,
            .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay])
    }
    private static func uv(_ source: SCNGeometrySource) throws -> [[Double]] {
        guard source.usesFloatComponents, [4, 8].contains(source.bytesPerComponent), source.componentsPerVector == 2 else { throw VideoError.invalid("测试实际UV须是可核对的浮点二维坐标") }
        let stride = source.dataStride > 0 ? source.dataStride : source.bytesPerComponent * source.componentsPerVector
        return try source.data.withUnsafeBytes { bytes in
            try (0..<source.vectorCount).map { index in
                try (0..<2).map { component in
                    let offset = source.dataOffset + index * stride + component * source.bytesPerComponent
                    guard offset >= 0, offset + source.bytesPerComponent <= bytes.count else { throw VideoError.invalid("实际UV数据越界") }
                    return source.bytesPerComponent == 4 ? Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)) : bytes.loadUnaligned(fromByteOffset: offset, as: Double.self)
                }
            }
        }
    }
    private static func color(_ property: SCNMaterialProperty) throws -> [Double] {
        #if os(macOS)
        let value = try XCTUnwrap((property.contents as? NSColor)?.usingColorSpace(.sRGB))
        return [Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent), Double(value.alphaComponent), Double(property.intensity)]
        #else
        let value = try XCTUnwrap(property.contents as? UIColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard value.getRed(&r, green: &g, blue: &b, alpha: &a) else { throw VideoError.invalid("无法核对原生常量色") }
        return [Double(r), Double(g), Double(b), Double(a), Double(property.intensity)]
        #endif
    }

    private static func png(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 8, height: Int = 8) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: red * 0.5, green: green * 0.5, blue: blue * 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: max(1, width / 2), height: max(1, height / 2)))
        return try ScenePainter.png(XCTUnwrap(context.makeImage()))
    }

    private static func inventory(_ repository: Repository) throws -> [String: String] {
        let root = repository.root.appendingPathComponent("assets")
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        var result: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            var status = stat(); guard lstat(file.path, &status) == 0 else { throw VideoError.unavailable("无法核对测试CAS清单") }
            if (status.st_mode & S_IFMT) == S_IFREG { result[file.lastPathComponent] = Codec.hash(try Data(contentsOf: file)) }
            else if (status.st_mode & S_IFMT) == S_IFLNK { result[file.lastPathComponent] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: file.path)) }
            else { result[file.lastPathComponent] = "mode:\(status.st_mode & S_IFMT)" }
        }
        return result
    }

    private final class FailureOutcome: @unchecked Sendable {
        private let lock = NSLock(); private var failure: Error?; private var succeeded = false
        func finish(_ error: Error?) { lock.lock(); failure = error; succeeded = error == nil; lock.unlock() }
        func get() -> (Error?, Bool) { lock.lock(); defer { lock.unlock() }; return (failure, succeeded) }
    }
    private static func assertFIFORejected(path: String, operation: @escaping () throws -> Void) throws {
        let done = DispatchSemaphore(value: 0), outcome = FailureOutcome()
        DispatchQueue.global().async {
            do { try operation(); outcome.finish(nil) } catch { outcome.finish(error) }
            done.signal()
        }
        let timely = done.wait(timeout: .now() + 1)
        if timely == .timedOut {
            let endpoint = Darwin.open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            let joined = done.wait(timeout: .now() + 5)
            if endpoint >= 0 { Darwin.close(endpoint) }
            XCTAssertEqual(joined, .success, "FIFO失败回归必须有界解除并收束线程")
            guard joined == .success else { return }
        }
        XCTAssertEqual(timely, .success, "FIFO必须在文件类型检查前用O_NONBLOCK避免阻塞")
        let (error, succeeded) = outcome.get()
        XCTAssertFalse(succeeded); XCTAssertNotNil(error)
        XCTAssertTrue(error?.localizedDescription.contains("普通文件") == true, "必须由实际文件类型门禁拒绝，不能误以父目录缺失或其他失败通过")
    }

    private final class BindingFixture {
        let base: URL; let sources: URL; let repository: Repository
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            sources = base.appendingPathComponent("sources")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            repository = try Repository(root: base.appendingPathComponent("workspace"))
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func put(_ data: Data, at path: String) throws -> URL {
            let file = sources.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file); return file
        }
    }
}
