import Foundation

/// Editing the optional visual door family never changes the knowledge model,
/// its recorded result, a character's expressions, or any listening approval.
public enum ClassicGateEditing {
    public static let roles = ["obstacle", "door_narrow", "door_opening", "door_open"]

    /// Apply one complete group from the artwork's existing, registered Q image
    /// sources. New source files must first be imported and bound with their own
    /// provenance; this operation grants neither a derivation nor a permission.
    public static func setting(_ sprites: [ClassicSprite], to original: Scene,
                               assets: [Asset], evidence: [Evidence], workspaceID: String,
                               commercial: Bool, now: Date = Date()) throws -> Scene {
        guard !original.locked, original.kind == .simulation,
              let knowledge = original.simulation.knowledge, knowledge.version == 1,
              var artwork = original.classicArtwork, artwork.derivation == .qStyle else {
            throw VideoError.permission("请先选择未锁定、已绑定实际Q版来源的共享通路知识镜头")
        }
        try knowledge.validate()
        guard sprites.count == roles.count, Set(sprites.map(\.role)) == Set(roles) else {
            throw VideoError.invalid("请一次提交关闭、窄缝、开启和全开四个门态；角色标识不得缺失、重复或混入其他图块")
        }
        let scoped = assets.filter { $0.workspaceID == workspaceID }
        let sources = Set(artwork.sources.map(\.assetID))
        let originals = Set(scoped.filter { artwork.originalAssetIDs.contains($0.id) }.map(\.hash))
        for sprite in sprites {
            guard sources.contains(sprite.assetID),
                  let image = scoped.first(where: { $0.id == sprite.assetID && $0.mediaType.hasPrefix("image") }),
                  !originals.contains(image.hash) else {
                throw VideoError.review("门态须选择当前素材绑定中有具体来源的实际Q版图集，不能使用原件或未绑定的图片")
            }
        }
        // Preserve existing role order and every non-door sprite. A historical
        // partial group can be repaired in one edit without rewriting its model.
        for role in roles {
            guard let sprite = sprites.first(where: { $0.role == role }) else { continue }
            if let index = artwork.sprites.firstIndex(where: { $0.role == role }) {
                artwork.sprites[index] = sprite
            } else {
                artwork.sprites.append(sprite)
            }
        }
        var scene = original
        scene.classicArtwork = artwork
        // Reuse current source, crop, complete-group, duplicate-region and rights
        // checks. Pixel decoding remains the renderer's independent boundary.
        try ClassicArtworkRules.validateRights(scene: scene, workspaceID: workspaceID,
            assets: scoped, evidence: evidence, commercial: commercial, now: now)
        return scene
    }
}
