import XCTest
import CoreGraphics
import CryptoKit
import VideoCore
@testable import VideoMedia

final class FrozenRenderRevisionTests: XCTestCase {
    private final class Authorization: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var denied = false
        func check() throws {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if denied { throw VideoError.permission("测试中的实时权限已撤销") }
        }
        func revoke() { lock.lock(); denied = true; lock.unlock() }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func revision(_ aspect: Aspect = .landscape) -> Revision {
        var scene = Scene(title: "冻结原文", body: "同一修订的真实画面", durationFrames: 82)
        scene.paperPresentation = PaperPresentation()
        var block = SceneLayer(kind: .rectangle, endFrame: 82)
        block.x = 0.2; block.y = 0.45; block.width = 0.16; block.height = 0.18; block.color = "E54B4B"
        block.keyframes = [Keyframe(frame: 0, x: 0.2, y: 0.45, scale: 1),
                           Keyframe(frame: 81, x: 0.8, y: 0.45, scale: 1)]
        scene.layers = [block]
        scene.captions = [Caption(text: "边界之前", startFrame: 0, endFrame: 30),
                          Caption(text: "边界之后", startFrame: 30, endFrame: 82)]
        return Revision(contentContext: ContentContext(workspaceID: "frozen-workspace", name: "绑定测试"),
                        aspect: aspect, scenes: [scene])
    }

    private func owner(_ revision: Revision, id: String = "same-public-id",
                       authorization: Authorization = Authorization(), cancellation: RenderCancellation = RenderCancellation(),
                       deadline: Date = Date().addingTimeInterval(300)) throws -> RenderInvocation {
        RenderInvocation(id: id, workspaceID: revision.workspaceID, projectID: "frozen-project",
                         revisionID: revision.id, revisionDigest: try revision.contentDigest(), jobID: "frozen-job",
                         budgetReference: "native-zero", budgetLimit: Money(0), deadline: deadline,
                         cancellation: cancellation, authorization: { try authorization.check() })
    }

    private func context(_ revision: Revision) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: revision.aspect.width, height: revision.aspect.height,
                              bitsPerComponent: 8, bytesPerRow: revision.aspect.width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func rgba(_ context: CGContext) throws -> Data {
        let bytes = try XCTUnwrap(context.data)
        return Data(bytes: bytes, count: context.bytesPerRow * context.height)
    }

    /// Synthetic Host/scoped-module fixture, never a private Game renderer or
    /// a production appearance assertion. No external model/media is loaded.
    private final class ModelModule: ScopedSceneRenderModule, @unchecked Sendable {
        let manifest: PluginManifest
        private let lock = NSLock()
        private var sourceFrames: [Int] = []
        init(_ manifest: PluginManifest) { self.manifest = manifest }
        var frames: [Int] { lock.lock(); defer { lock.unlock() }; return sourceFrames }
        func draw(scene: VideoCore.Scene, localFrame: Int, fps: Int, rect: CGRect, context: CGContext) throws {
            throw VideoError.permission("合成三维夹具只允许scoped绘制")
        }
        func draw(scene: VideoCore.Scene, localFrame: Int, fps: Int, rect: CGRect, context: CGContext,
                  resources: RenderResources, invocation: RenderInvocation) throws {
            try invocation.check()
            guard let model = scene.modelScene3D, let bank = resources.modelBank,
                  bank.manifest == (try PluginModelBankManifest(scene: model, durationFrames: scene.durationFrames)) else {
                throw VideoError.permission("合成三维夹具缺少当前源bank")
            }
            lock.lock(); sourceFrames.append(localFrame); lock.unlock()
            context.setFillColor(CGColor(srgbRed: localFrame < 30 ? 0.85 : 0.12,
                green: (30..<60).contains(localFrame) ? 0.85 : 0.12, blue: localFrame >= 60 ? 0.85 : 0.12, alpha: 1))
            context.fill(rect)
        }
        func close(invocationID: String) throws {}
    }

    private func modelFixture(_ repository: Repository, workspace: Workspace) throws -> (Revision, RenderModuleRegistry, ModelModule) {
        let xml = """
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><created>2026-11-05T00:00:00Z</created><modified>2026-11-05T00:00:00Z</modified><unit name="meter" meter="1"/><up_axis>Y_UP</up_axis></asset>
        <library_geometries><geometry id="triangle"><mesh><source id="positions"><float_array id="position-array" count="9">0 0 0 1 0 0 0 1 0</float_array><technique_common><accessor source="#position-array" count="3" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source><vertices id="vertices"><input semantic="POSITION" source="#positions"/></vertices><triangles count="1"><input semantic="VERTEX" source="#vertices" offset="0"/><p>0 1 2</p></triangles></mesh></geometry></library_geometries>
        <library_visual_scenes><visual_scene id="stage"><node id="mesh"><instance_geometry url="#triangle"/></node></visual_scene></library_visual_scenes><scene><instance_visual_scene url="#stage"/></scene></COLLADA>
        """
        let bytes = Data(xml.utf8)
        var asset = try repository.ingest(bytes, name: "synthetic-binding-triangle.dae", workspaceID: workspace.id, mediaType: "model3d")
        let evidence = Evidence(workspaceID: workspace.id, title: "测试自制三角形", source: "synthetic bound revision fixture",
            claim: "authored triangle", owner: "tester", commercialAllowed: true, verified: true, assetID: asset.id)
        asset.evidenceID = evidence.id
        try repository.transaction { $0.assets = [asset]; $0.evidence = [evidence] }
        let resource = ModelDAEResource(model: .init(asset: asset), inspection: try DAEInspector.inspect(bytes), textures: [:])
        var scene = Scene(kind: .simulation, title: "合成源帧", body: "", durationFrames: 82)
        scene.modelScene3D = ModelScene3D(instances: [.init(id: "mesh", name: "合成三角形", resource: resource)],
            camera: .init(position: .init(x: 0, y: 2, z: 5), target: .init()), lights: [.init(id: "sun", kind: .directional)])
        try scene.validate(assets: [asset])
        let value = Revision(contentContext: ContentContext(workspaceID: workspace.id, name: "合成绑定验证"), aspect: .landscape, scenes: [scene])
        let key = Curve25519.Signing.PrivateKey(), registry = RenderModuleRegistry()
        let manifest = PluginManifest(id: "video.game", version: "isolated-binding-rule", capabilities: ["game.simulate"],
            inputSchema: 10, implementationDigest: try BuiltinExecutableIdentity.current().digest, permissions: [])
        let module = ModelModule(manifest)
        func signed<T: Encodable>(_ value: T) throws -> SignedDocument {
            let data = try Codec.data(value)
            return SignedDocument(payload: data, signature: try key.signature(for: data))
        }
        try registry.register(module, signedManifest: signed(manifest),
            signedPolicy: signed(CommercialPolicy(pluginID: manifest.id, version: 1, access: "free", updatedAt: Date(), sourceVisibility: "closed")),
            publicKey: key.publicKey.rawRepresentation)
        return (value, registry, module)
    }

    func testBindingRejectsDistinctOwnerEvenWithEveryPublicScopeFieldEqualButAcceptsValueCopy() throws {
        let value = revision(), firstCalls = Authorization(), secondCalls = Authorization()
        let deadline = Date().addingTimeInterval(300), cancellation = RenderCancellation()
        let first = try owner(value, authorization: firstCalls, cancellation: cancellation, deadline: deadline)
        let second = try owner(value, authorization: secondCalls, cancellation: cancellation, deadline: deadline)
        let binding = try first.bind(revision: value)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.revisionDigest, second.revisionDigest)
        XCTAssertEqual(first.deadline, second.deadline)
        XCTAssertTrue(first.cancellation === second.cancellation)
        XCTAssertThrowsError(try second.verify(binding: binding)) {
            XCTAssertEqual(($0 as? VideoError)?.code, "revision_conflict")
        }
        XCTAssertEqual(secondCalls.calls, 1, "不缓存或跳过候选owner的实时授权检查")
        let originalCopy = first
        XCTAssertNoThrow(try originalCopy.verify(binding: binding))
        XCTAssertEqual(firstCalls.calls, 2)
    }

    func testExternalNestedValueEditsCannotChangeBoundPixels() throws {
        let original = revision(), invocation = try owner(original)
        let binding = try invocation.bind(revision: original)
        var external = original
        external.scenes[0].title = "外部已经改写"
        external.scenes[0].layers?[0].keyframes[0].x = 0.85
        external.scenes[0].captions[0].text = "替换的字幕"
        external.contentContext?.name = "替换的上下文"
        XCTAssertNotEqual(try original.contentDigest(), try external.contentDigest())
        XCTAssertThrowsError(try invocation.verify(revision: external))
        XCTAssertThrowsError(try invocation.bind(revision: external))
        let before = try context(original), frozen = try context(original)
        try ScenePainter.draw(revision: original, frame: 0, in: before, invocation: invocation)
        try ScenePainter.draw(binding: binding, frame: 0, in: frozen)
        XCTAssertTrue(try rgba(before) == rgba(frozen), "外部嵌套集合修改不能改变绑定内值或像素")
    }

    func testEveryHotFrameChecksAuthorityAndRevocationPrecedesAnyPixelWrite() throws {
        let value = revision(), authorization = Authorization()
        let invocation = try owner(value, authorization: authorization), binding = try invocation.bind(revision: value)
        let canvas = try context(value)
        XCTAssertEqual(authorization.calls, 1)
        for (index, frame) in [0, 29, 30].enumerated() {
            try ScenePainter.draw(binding: binding, frame: frame, in: canvas)
            XCTAssertEqual(authorization.calls, index + 2)
        }
        canvas.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        let sentinel = try rgba(canvas)
        authorization.revoke()
        XCTAssertThrowsError(try ScenePainter.draw(binding: binding, frame: 31, in: canvas))
        XCTAssertEqual(authorization.calls, 5)
        XCTAssertTrue(try rgba(canvas) == sentinel, "撤权必须在绘制任何像素之前生效")
    }

    func testBoundFrameStillHonorsCancellationAndActualDeadline() throws {
        let value = revision(), cancellation = RenderCancellation()
        let invocation = try owner(value, cancellation: cancellation), binding = try invocation.bind(revision: value)
        cancellation.cancel()
        let canvas = try context(value), sentinel = try rgba(canvas)
        XCTAssertThrowsError(try ScenePainter.draw(binding: binding, frame: 0, in: canvas)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(try rgba(canvas) == sentinel)

        let deadline = Date().addingTimeInterval(1)
        let expiring = try owner(value, deadline: deadline), expiringBinding = try expiring.bind(revision: value)
        // This is an expiry behavior check, never a performance threshold.
        while Date() < deadline { Thread.sleep(forTimeInterval: max(0, min(0.01, deadline.timeIntervalSinceNow))) }
        XCTAssertThrowsError(try ScenePainter.draw(binding: expiringBinding, frame: 0, in: canvas)) {
            XCTAssertEqual(($0 as? VideoError)?.code, "unavailable")
        }
        XCTAssertTrue(try rgba(canvas) == sentinel)
    }

    func testOriginalVerifyAndBindingKeepUnicodeAndSignedZeroByteDigestBoundary() throws {
        var unicode = revision(); unicode.scenes[0].title = "\u{00E9}"
        var decomposed = unicode; decomposed.scenes[0].title = "e\u{0301}"
        XCTAssertEqual(unicode.scenes[0].title, decomposed.scenes[0].title, "普通String相等不能代替原字节摘要")
        var positive = revision(); positive.scenes[0].x = 0.0
        var negative = positive; negative.scenes[0].x = -0.0
        XCTAssertEqual(positive.scenes[0].x, negative.scenes[0].x)
        for (original, changed) in [(unicode, decomposed), (positive, negative)] {
            XCTAssertNotEqual(try original.contentDigest(), try changed.contentDigest())
            let invocation = try owner(original)
            XCTAssertNoThrow(try invocation.verify(revision: original))
            XCTAssertThrowsError(try invocation.verify(revision: changed))
            XCTAssertThrowsError(try invocation.bind(revision: changed))
        }
    }

    func testOriginalAndBoundPainterHaveExactRGBAAcrossCheckpointsAndBothAspects() throws {
        for aspect in Aspect.allCases {
            let value = revision(aspect), invocation = try owner(value), binding = try invocation.bind(revision: value)
            for frame in [0, 29, 30, 59, 60, 81] {
                let original = try context(value), bound = try context(value)
                try ScenePainter.draw(revision: value, frame: frame, in: original, invocation: invocation)
                try ScenePainter.draw(binding: binding, frame: frame, in: bound)
                XCTAssertTrue(try rgba(original) == rgba(bound), "原入口与绑定入口必须逐字节RGBA相同：\(aspect) frame=\(frame)")
            }
        }
    }

    func testBoundPainterKeepsScopedModelPixelsAndStillRejectsMissingSourceBank() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-frozen-model-" + Codec.id())
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root), workspace = Workspace(name: "合成绑定验证", owner: "tester")
        try repository.transaction { $0.workspaces = [workspace] }
        let (value, registry, module) = try modelFixture(repository, workspace: workspace)
        let invocation = try owner(value), binding = try invocation.bind(revision: value)
        defer { try? registry.close(invocationID: invocation.id) }
        let resources = try ClassicArtworkMedia.load(scene: value.scenes[0], workspaceID: value.workspaceID,
            repository: repository, database: repository.read(), commercial: false)
        let frames = [0, 29, 30, 59, 60, 81]
        for frame in frames {
            let original = try context(value), bound = try context(value)
            try ScenePainter.draw(revision: value, frame: frame, in: original, resources: resources, modules: registry, invocation: invocation)
            try ScenePainter.draw(binding: binding, frame: frame, in: bound, resources: resources, modules: registry)
            XCTAssertTrue(try rgba(original) == rgba(bound), "scoped三维源轴的Host画布必须逐字节相同")
        }
        XCTAssertEqual(module.frames, frames.flatMap { [$0, $0] })
        XCTAssertThrowsError(try ScenePainter.draw(binding: binding, frame: 0, in: context(value), modules: registry))
        XCTAssertEqual(module.frames, frames.flatMap { [$0, $0] }, "binding不得替代逐帧原模型字节库核验")
    }
}
