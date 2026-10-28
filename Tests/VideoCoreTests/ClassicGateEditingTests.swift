import XCTest
@testable import VideoCore

/// Isolated metadata tests; no artwork, editor purchase or human approval is inferred.
final class ClassicGateEditingTests: XCTestCase {
    private let workspace = "gate-editing"
    private func fixture() throws -> (Scene, [Asset], [Evidence], [ClassicSprite]) {
        let proof = Evidence(workspaceID: workspace, title: "隔离门图来源", source: "isolated-gate-atlas",
            claim: "仅验证编辑和来源规则", owner: "test", commercialAllowed: true, verified: true)
        var original = Asset(workspaceID: workspace, name: "original.png", hash: String(repeating: "a", count: 64), ext: "png", bytes: 8, mediaType: "image")
        original.evidenceID = proof.id
        var atlas = original; atlas.id = Codec.id(); atlas.name = "derived.png"; atlas.hash = String(repeating: "b", count: 64)
        let sources = [original, atlas].map { ClassicSource(assetID: $0.id, hash: $0.hash, source: proof.source, owner: proof.owner, license: "isolated", evidenceID: proof.id) }
        let sprites = ClassicArtworkRules.requiredRoles(knowledge: true, cartoon: false).sorted().map { ClassicSprite(role: $0, assetID: atlas.id) }
        var scene = Scene(kind: .simulation, title: "共享通路", body: "实际达到门槛才通行", durationFrames: 180)
        scene.narration = "两人先作选择，再核对实际结果。"
        scene.character = "两位参与者"
        scene.characterProfile = CharacterProfile(name: scene.character, expressions: ["好奇", "开心"], actions: ["行走", "出力"], evidenceIDs: [proof.id], original: false)
        scene.simulation.knowledge = KnowledgeSimulation(knowledgeLabel: "共享通路", participants: [
            .init(id: "a", name: "甲", strategy: .contribute), .init(id: "b", name: "乙", strategy: .freeRide)], rounds: 1)
        scene.classicArtwork = ClassicArtwork(gameplay: .platformer, sprites: sprites, sources: sources,
            derivation: .qStyle, transformation: "隔离规则中的派生来源绑定", originalAssetIDs: [original.id])
        scene.simulationRecording = try SimulationReplay.record(scene: scene)
        scene.simulationRecordingConfirmed = true
        let gates = ClassicGateEditing.roles.enumerated().map { ClassicSprite(role: $0.element, assetID: atlas.id, x: Double($0.offset) / 4, width: 0.25) }
        return (scene, [original, atlas], [proof], gates)
    }
    private func set(_ sprites: [ClassicSprite], scene: Scene, assets: [Asset], evidence: [Evidence], commercial: Bool = false) throws -> Scene {
        try ClassicGateEditing.setting(sprites, to: scene, assets: assets, evidence: evidence, workspaceID: workspace, commercial: commercial)
    }
    func testCompleteGroupChangesOnlyDoorSpritesAndPreservesActualModelRecordingAndCharacter() throws {
        let (scene, assets, evidence, gates) = try fixture()
        let edited = try set(gates, scene: scene, assets: assets, evidence: evidence)
        var expected = scene
        expected.classicArtwork?.sprites.removeAll { ClassicGateEditing.roles.contains($0.role) }
        expected.classicArtwork?.sprites += gates
        XCTAssertEqual(Set(edited.classicArtwork!.sprites.map(\.role)), Set(expected.classicArtwork!.sprites.map(\.role)))
        var restored = edited; restored.classicArtwork = scene.classicArtwork
        XCTAssertEqual(try Codec.data(restored), try Codec.data(scene))
        XCTAssertEqual(edited.classicArtwork?.sources, scene.classicArtwork?.sources)
        XCTAssertEqual(edited.classicArtwork?.audioCues, scene.classicArtwork?.audioCues)
        XCTAssertEqual(edited.characterProfile, scene.characterProfile)
        XCTAssertEqual(edited.simulationRecording, scene.simulationRecording)
        XCTAssertTrue(edited.simulationRecordingConfirmed == true)
        XCTAssertEqual(try SimulationReplay.record(scene: edited), scene.simulationRecording)
        for sprite in scene.classicArtwork!.sprites where !ClassicGateEditing.roles.contains(sprite.role) {
            XCTAssertEqual(edited.classicArtwork?.sprites.first { $0.role == sprite.role }, sprite)
        }
        XCTAssertEqual(edited.classicArtwork?.sprites.first?.role, scene.classicArtwork?.sprites.first?.role)
    }
    func testHistoricalPartialGroupCanBeRepairedWithOneNormalRevisionAndOldBytesRemain() throws {
        var (scene, assets, evidence, gates) = try fixture()
        scene.classicArtwork?.sprites.append(gates[1])
        let revision = Revision(contentContext: ContentContext(workspaceID: workspace, name: "旧门组"), aspect: .landscape, scenes: [scene])
        let project = Project(workspaceID: workspace, name: "旧门组", revision: revision)
        let bytes = try Codec.data(project)
        let repaired = try set(gates, scene: scene, assets: assets, evidence: evidence)
        let saved = try Editor.apply([.replaceScene(scene.id, repaired)], to: project, baseRevision: revision.id, assets: assets, message: "补全实际门组")
        XCTAssertEqual(saved.revisions.count, 2)
        XCTAssertEqual(try Codec.data(saved.revisions[0]), try Codec.data(revision))
        XCTAssertEqual(try Codec.data(project), bytes)
        XCTAssertNoThrow(try ClassicArtworkRules.validateGateSources(scene: XCTUnwrap(saved.current.scenes.first), assets: assets))
    }
    func testMissingDuplicateOrForeignRolesRejectWithoutChangingOriginalScene() throws {
        let (scene, assets, evidence, gates) = try fixture()
        let bytes = try Codec.data(scene)
        var duplicate = gates; duplicate[3].role = duplicate[2].role
        var foreign = gates; foreign[3].role = "开心"
        for input in [Array(gates.dropLast()), gates + [gates[0]], duplicate, foreign] {
            XCTAssertThrowsError(try set(input, scene: scene, assets: assets, evidence: evidence))
            XCTAssertEqual(try Codec.data(scene), bytes)
        }
    }
    func testDuplicateSourceRegionAliasesRejectButDifferentActualRegionsRemainValid() throws {
        let (scene, assets, evidence, gates) = try fixture()
        var alias = assets[1]; alias.id = Codec.id()
        var source = try XCTUnwrap(scene.classicArtwork?.sources.last); source.assetID = alias.id
        var withAlias = scene; withAlias.classicArtwork?.sources.append(source)
        var duplicate = gates; duplicate[3] = duplicate[0]; duplicate[3].role = "door_open"; duplicate[3].assetID = alias.id
        XCTAssertThrowsError(try set(duplicate, scene: withAlias, assets: assets + [alias], evidence: evidence))
        duplicate[3].x = 0.75
        XCTAssertNoThrow(try set(duplicate, scene: withAlias, assets: assets + [alias], evidence: evidence))
    }
    func testEveryDoorRejectsOriginalAliasesUnboundImagesAndForeignWorkspace() throws {
        let (scene, assets, evidence, gates) = try fixture()
        for index in gates.indices {
            var changed = gates; changed[index].assetID = assets[0].id
            XCTAssertThrowsError(try set(changed, scene: scene, assets: assets, evidence: evidence))
        }
        var alias = assets[0]; alias.id = Codec.id()
        var aliasSource = try XCTUnwrap(scene.classicArtwork?.sources.first); aliasSource.assetID = alias.id
        var aliasScene = scene; aliasScene.classicArtwork?.sources.append(aliasSource)
        var changed = gates; changed[3].assetID = alias.id
        XCTAssertThrowsError(try set(changed, scene: aliasScene, assets: assets + [alias], evidence: evidence))
        var unbound = assets[1]; unbound.id = Codec.id(); unbound.hash = String(repeating: "c", count: 64)
        changed = gates; changed[3].assetID = unbound.id
        XCTAssertThrowsError(try set(changed, scene: scene, assets: assets + [unbound], evidence: evidence))
        var foreign = assets; foreign[1].workspaceID = "another-workspace"
        XCTAssertThrowsError(try set(gates, scene: scene, assets: foreign, evidence: evidence))
    }
    func testInvalidCropAndChangedSourceOrRightsCannotBeApplied() throws {
        let (scene, assets, evidence, gates) = try fixture()
        for region in [ClassicSprite(role: "door_open", assetID: assets[1].id, x: -0.1),
                       ClassicSprite(role: "door_open", assetID: assets[1].id, width: 0),
                       ClassicSprite(role: "door_open", assetID: assets[1].id, x: 0.8, width: 0.3),
                       ClassicSprite(role: "door_open", assetID: assets[1].id, y: .infinity)] {
            var changed = gates; changed[3] = region
            XCTAssertThrowsError(try set(changed, scene: scene, assets: assets, evidence: evidence))
        }
        var tampered = assets; tampered[1].hash = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try set(gates, scene: scene, assets: tampered, evidence: evidence))
        var revoked = evidence; revoked[0].verified = false
        XCTAssertThrowsError(try set(gates, scene: scene, assets: assets, evidence: revoked))
        var privateOnly = evidence; privateOnly[0].commercialAllowed = false
        XCTAssertNoThrow(try set(gates, scene: scene, assets: assets, evidence: privateOnly))
        XCTAssertThrowsError(try set(gates, scene: scene, assets: assets, evidence: privateOnly, commercial: true))
    }
    func testLockedNonQCartoonAndOtherKnowledgeMechanismsKeepTheirMeaning() throws {
        let (scene, assets, evidence, gates) = try fixture()
        var locked = scene; locked.locked = true
        var original = scene; original.classicArtwork?.derivation = .original
        var cartoon = scene; cartoon.kind = .cartoon
        var matrix = scene; matrix.simulation.knowledge?.version = 2; matrix.simulation.knowledge?.payoffMatrix = .prisonersDilemma()
        var legacy = scene; legacy.simulation.knowledge = nil
        for value in [locked, original, cartoon, matrix, legacy] {
            let bytes = try Codec.data(value)
            XCTAssertThrowsError(try set(gates, scene: value, assets: assets, evidence: evidence))
            XCTAssertEqual(try Codec.data(value), bytes)
        }
        XCTAssertNoThrow(try ClassicArtworkRules.validateGateSources(scene: scene, assets: assets))
    }
}
