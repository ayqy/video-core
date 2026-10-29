import Foundation
import ImageIO
import VideoCore

public struct MotaWorldFileDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int
    public let sha256: String
    public let mediaType: String
    public let width: Int?
    public let height: Int?
    public var assetName: String { path == "mota/LICENSE.md" ? "LICENSE.mota.md" : URL(fileURLWithPath: path).lastPathComponent }
    /// Shared originals retain the exact legacy source identity in either import order.
    private var legacyShared: Bool {
        ["mota/LICENSE.md", "mota/project/images/hero.png", "mota/project/materials/terrains.png",
         "mota/project/materials/animates.png", "mota/project/materials/npcs.png", "mota/project/materials/npc48.png"].contains(path)
    }
    public var sourceURL: String {
        if path == "mota/LICENSE.md" { return MotaWorldAssets.upstream + "LICENSE.md#FF-1480-imagegen-" + sha256 }
        if path.hasPrefix("mota/") { return MotaWorldAssets.upstream + String(path.dropFirst(5)) }
        return MotaWorldAssets.upstream + "LICENSE.md#FF-1480-world-source-" + sha256
    }
    public var evidenceOwner: String {
        path == "mota/LICENSE.md" ? "ckcz123（原件）；FF-1480项目素材整理及模型派生" : (path.hasPrefix("mota/") ? "ckcz123" : "FF-1480项目素材整理")
    }
    public var evidenceClaim: String {
        if legacyShared {
            return "固定上游BSD3许可及完整原文已保留。" +
                (path == "mota/LICENSE.md" ? "本次为实际image_gen派生或其提示/许可文档；原件、四图SHA及过程见本组README/prompts。" : "本次为固定上游下载原件。") +
                "仅登记来源与本任务非商业教学用途；不授高级权益、试听、字幕或整片审核。当前文件SHA256 " + sha256
        }
        return (path.hasPrefix("mota/") ? "固定mota-js样板0层相关被动原件；BSD3原文保留；不执行任何JS或事件。" : "本任务固定原件区域、用途及缺项说明；不是上游原文。") +
            "仅登记本地非商业教学来源；不授商用、上传、高级权益、声音、字幕、规则或整片审核。当前文件SHA256 " + sha256
    }
    public func evidenceTitle(assetName name: String) -> String {
        (legacyShared ? "魔塔具体原件或Q派生来源：" : "魔塔完整地图固定原件来源：") + name
    }
    public func acceptsAssetName(_ name: String) -> Bool {
        name == assetName || (path == "mota/LICENSE.md" && name == "LICENSE.md")
    }
}

/// An actual rectangular region in an unmodified source PNG; coordinates are top-left pixels.
public struct MotaWorldSpriteDescriptor: Codable, Equatable, Sendable {
    public let role: String
    public let sourcePath: String
    public let iconID: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}

public struct MotaWorldImportedPack: Sendable {
    public let artwork: ClassicArtwork
    public let assetsByPath: [String: Asset]
    public let sample0Map: [[Int]]
    public let mapRolesByNumber: [Int: String]
    public var sample0Tiles: [String] { sample0Map.flatMap { $0.map { mapRolesByNumber[$0]! } } }
}

/// Independent passive world bank. No old Mota pack entry, upstream script,
/// model rule, module identity or review is changed or executed by this import.
public enum MotaWorldAssets {
    public static let upstream = "https://raw.githubusercontent.com/ckcz123/mota-js/3efb548e407ad2b8007b498cb98401e2012a0b55/"
    public static let licence = "BSD 3-Clause固定原件；保留版权、条款及免责，不背书；仅本任务本地非商业教学，其他用途另核"
    public static let missingOriginalRoles = ["道路施工进度", "货车/货物售卖", "完整货运建筑", "掏钱递钱肢体", "口型/夸张表情"]
    public static let fileDescriptors: [MotaWorldFileDescriptor] = [
        .init(path: "mota/LICENSE.md", bytes: 1507, sha256: "70440d45a4b311814f59845d60ac747e4f0a90202f9ea1e4b43330b3b057d49f", mediaType: "text", width: nil, height: nil),
        .init(path: "mota/project/maps.js", bytes: 15152, sha256: "c1cce589a42e367e07c84cbeff6493d29d7f9834f984403c7983d1bcdbb816eb", mediaType: "text", width: nil, height: nil),
        .init(path: "mota/project/icons.js", bytes: 4620, sha256: "81f7331c52a3cc9058e622c38eb0962d2d69a120b8ed22e4dac4b1f6ad9f1d68", mediaType: "text", width: nil, height: nil),
        .init(path: "mota/project/floors/sample0.js", bytes: 13361, sha256: "53052dc60619778459dff8922746cb3ac450f27600a68aac24bac7e206c8236c", mediaType: "text", width: nil, height: nil),
        .init(path: "mota/project/images/hero.png", bytes: 5393, sha256: "07f2035a5f1c2321e974b234720db9872fe7cd7fd97e9e932ab4d53abd5d886f", mediaType: "image", width: 128, height: 192),
        .init(path: "mota/project/images/winskin.png", bytes: 6242, sha256: "ee52ff0a163e08758e4ad8e8d725a47d4a4bb871221b2d64558f571a6ea58a42", mediaType: "image", width: 192, height: 128),
        .init(path: "mota/project/materials/terrains.png", bytes: 9272, sha256: "82ae3d5ceeaffa89117c2376efde8f741e4bb552f9b4f37a9d5846b29f8ea4de", mediaType: "image", width: 32, height: 1120),
        .init(path: "mota/project/materials/animates.png", bytes: 35724, sha256: "03f6e3eb92249b7303cf196f3ff7d3846398a87ad24f40086e8c2929fcf436d4", mediaType: "image", width: 128, height: 928),
        .init(path: "mota/project/materials/npcs.png", bytes: 12971, sha256: "a664d6551a8ddbde58535f8787851baa66913b170338c222d1c1ac7c4bd514f1", mediaType: "image", width: 64, height: 448),
        .init(path: "mota/project/materials/npc48.png", bytes: 22189, sha256: "e4cca94e94dba40aaf8d50bd5baea64e8bed3351aece0a5405a76b29dc72acd1", mediaType: "image", width: 128, height: 480),
        .init(path: "mota/project/materials/items.png", bytes: 18696, sha256: "c46113999752a4d7d592561a520452cf3ee459618adeb46d752645288ca012be", mediaType: "image", width: 32, height: 1984),
        .init(path: "mota/project/materials/enemys.png", bytes: 51283, sha256: "cc44cc393ea86e4ff82db3778bc95611172f26d3f8971cea14ce3bee35df1769", mediaType: "image", width: 64, height: 2336),
        .init(path: "mota/project/materials/enemy48.png", bytes: 39006, sha256: "8bfb6f2d64006af20506b0a9ae371154bd32e9a0cfffb27bbefae444437b4169", mediaType: "image", width: 128, height: 384),
        .init(path: "mota/project/autotiles/autotile.png", bytes: 3476, sha256: "4d40dd995b14780e228950e4aeb90d6889d5bae8e5fe52dbfbbee2d86d0ba69b", mediaType: "image", width: 96, height: 128),
        .init(path: "mota-world77/source.md", bytes: 16750, sha256: "0ae7facea574a9c8334633354e59f629212db6d5352ed8ea539bb9c3944dc144", mediaType: "text", width: nil, height: nil)
    ]
    public static let spriteDescriptors: [MotaWorldSpriteDescriptor] = [
        .init(role: "yellowWall", sourcePath: "mota/project/materials/animates.png", iconID: "yellowWall", x: 0, y: 320, width: 32, height: 32),
        .init(role: "whiteWall", sourcePath: "mota/project/materials/animates.png", iconID: "whiteWall", x: 0, y: 352, width: 32, height: 32),
        .init(role: "blueWall", sourcePath: "mota/project/materials/animates.png", iconID: "blueWall", x: 0, y: 384, width: 32, height: 32),
        .init(role: "star", sourcePath: "mota/project/materials/animates.png", iconID: "star", x: 0, y: 0, width: 32, height: 32),
        .init(role: "lava", sourcePath: "mota/project/materials/animates.png", iconID: "lava", x: 0, y: 32, width: 32, height: 32),
        .init(role: "ice", sourcePath: "mota/project/materials/animates.png", iconID: "ice", x: 0, y: 864, width: 32, height: 32),
        .init(role: "lavaNet", sourcePath: "mota/project/materials/animates.png", iconID: "lavaNet", x: 0, y: 608, width: 32, height: 32),
        .init(role: "poisonNet", sourcePath: "mota/project/materials/animates.png", iconID: "poisonNet", x: 0, y: 640, width: 32, height: 32),
        .init(role: "weakNet", sourcePath: "mota/project/materials/animates.png", iconID: "weakNet", x: 0, y: 672, width: 32, height: 32),
        .init(role: "curseNet", sourcePath: "mota/project/materials/animates.png", iconID: "curseNet", x: 0, y: 704, width: 32, height: 32),
        .init(role: "autotile", sourcePath: "mota/project/autotiles/autotile.png", iconID: "autotile", x: 32, y: 64, width: 32, height: 32),
        .init(role: "yellowKey", sourcePath: "mota/project/materials/items.png", iconID: "yellowKey", x: 0, y: 0, width: 32, height: 32),
        .init(role: "blueKey", sourcePath: "mota/project/materials/items.png", iconID: "blueKey", x: 0, y: 32, width: 32, height: 32),
        .init(role: "redKey", sourcePath: "mota/project/materials/items.png", iconID: "redKey", x: 0, y: 64, width: 32, height: 32),
        .init(role: "greenKey", sourcePath: "mota/project/materials/items.png", iconID: "greenKey", x: 0, y: 96, width: 32, height: 32),
        .init(role: "bigKey", sourcePath: "mota/project/materials/items.png", iconID: "bigKey", x: 0, y: 192, width: 32, height: 32),
        .init(role: "redGem", sourcePath: "mota/project/materials/items.png", iconID: "redGem", x: 0, y: 512, width: 32, height: 32),
        .init(role: "blueGem", sourcePath: "mota/project/materials/items.png", iconID: "blueGem", x: 0, y: 544, width: 32, height: 32),
        .init(role: "greenGem", sourcePath: "mota/project/materials/items.png", iconID: "greenGem", x: 0, y: 576, width: 32, height: 32),
        .init(role: "yellowGem", sourcePath: "mota/project/materials/items.png", iconID: "yellowGem", x: 0, y: 608, width: 32, height: 32),
        .init(role: "redPotion", sourcePath: "mota/project/materials/items.png", iconID: "redPotion", x: 0, y: 640, width: 32, height: 32),
        .init(role: "sword1", sourcePath: "mota/project/materials/items.png", iconID: "sword1", x: 0, y: 1600, width: 32, height: 32),
        .init(role: "shield1", sourcePath: "mota/project/materials/items.png", iconID: "shield1", x: 0, y: 1760, width: 32, height: 32),
        .init(role: "sword5", sourcePath: "mota/project/materials/items.png", iconID: "sword5", x: 0, y: 1728, width: 32, height: 32),
        .init(role: "shield5", sourcePath: "mota/project/materials/items.png", iconID: "shield5", x: 0, y: 1888, width: 32, height: 32),
        .init(role: "book", sourcePath: "mota/project/materials/items.png", iconID: "book", x: 0, y: 288, width: 32, height: 32),
        .init(role: "fly", sourcePath: "mota/project/materials/items.png", iconID: "fly", x: 0, y: 384, width: 32, height: 32),
        .init(role: "pickaxe", sourcePath: "mota/project/materials/items.png", iconID: "pickaxe", x: 0, y: 1440, width: 32, height: 32),
        .init(role: "icePickaxe", sourcePath: "mota/project/materials/items.png", iconID: "icePickaxe", x: 0, y: 1408, width: 32, height: 32),
        .init(role: "bomb", sourcePath: "mota/project/materials/items.png", iconID: "bomb", x: 0, y: 1376, width: 32, height: 32),
        .init(role: "centerFly", sourcePath: "mota/project/materials/items.png", iconID: "centerFly", x: 0, y: 416, width: 32, height: 32),
        .init(role: "upFly", sourcePath: "mota/project/materials/items.png", iconID: "upFly", x: 0, y: 480, width: 32, height: 32),
        .init(role: "downFly", sourcePath: "mota/project/materials/items.png", iconID: "downFly", x: 0, y: 448, width: 32, height: 32),
        .init(role: "coin", sourcePath: "mota/project/materials/items.png", iconID: "coin", x: 0, y: 352, width: 32, height: 32),
        .init(role: "freezeBadge", sourcePath: "mota/project/materials/items.png", iconID: "freezeBadge", x: 0, y: 1312, width: 32, height: 32),
        .init(role: "cross", sourcePath: "mota/project/materials/items.png", iconID: "cross", x: 0, y: 1280, width: 32, height: 32),
        .init(role: "superPotion", sourcePath: "mota/project/materials/items.png", iconID: "superPotion", x: 0, y: 928, width: 32, height: 32),
        .init(role: "earthquake", sourcePath: "mota/project/materials/items.png", iconID: "earthquake", x: 0, y: 256, width: 32, height: 32),
        .init(role: "poisonWine", sourcePath: "mota/project/materials/items.png", iconID: "poisonWine", x: 0, y: 768, width: 32, height: 32),
        .init(role: "weakWine", sourcePath: "mota/project/materials/items.png", iconID: "weakWine", x: 0, y: 800, width: 32, height: 32),
        .init(role: "curseWine", sourcePath: "mota/project/materials/items.png", iconID: "curseWine", x: 0, y: 864, width: 32, height: 32),
        .init(role: "superWine", sourcePath: "mota/project/materials/items.png", iconID: "superWine", x: 0, y: 896, width: 32, height: 32),
        .init(role: "pack", sourcePath: "mota/project/materials/items.png", iconID: "pack", x: 0, y: 1472, width: 32, height: 32),
        .init(role: "amulet", sourcePath: "mota/project/materials/items.png", iconID: "amulet", x: 0, y: 1504, width: 32, height: 32),
        .init(role: "lifeWand", sourcePath: "mota/project/materials/items.png", iconID: "lifeWand", x: 0, y: 1056, width: 32, height: 32),
        .init(role: "jumpShoes", sourcePath: "mota/project/materials/items.png", iconID: "jumpShoes", x: 0, y: 1568, width: 32, height: 32),
        .init(role: "skill1", sourcePath: "mota/project/materials/items.png", iconID: "skill1", x: 0, y: 960, width: 32, height: 32),
        .init(role: "yellowDoor", sourcePath: "mota/project/materials/animates.png", iconID: "yellowDoor", x: 0, y: 128, width: 32, height: 32),
        .init(role: "blueDoor", sourcePath: "mota/project/materials/animates.png", iconID: "blueDoor", x: 0, y: 160, width: 32, height: 32),
        .init(role: "redDoor", sourcePath: "mota/project/materials/animates.png", iconID: "redDoor", x: 0, y: 192, width: 32, height: 32),
        .init(role: "greenDoor", sourcePath: "mota/project/materials/animates.png", iconID: "greenDoor", x: 0, y: 224, width: 32, height: 32),
        .init(role: "specialDoor", sourcePath: "mota/project/materials/animates.png", iconID: "specialDoor", x: 0, y: 256, width: 32, height: 32),
        .init(role: "steelDoor", sourcePath: "mota/project/materials/animates.png", iconID: "steelDoor", x: 0, y: 288, width: 32, height: 32),
        .init(role: "upFloor", sourcePath: "mota/project/materials/terrains.png", iconID: "upFloor", x: 0, y: 192, width: 32, height: 32),
        .init(role: "downFloor", sourcePath: "mota/project/materials/terrains.png", iconID: "downFloor", x: 0, y: 160, width: 32, height: 32),
        .init(role: "portal", sourcePath: "mota/project/materials/animates.png", iconID: "portal", x: 0, y: 544, width: 32, height: 32),
        .init(role: "starPortal", sourcePath: "mota/project/materials/animates.png", iconID: "starPortal", x: 0, y: 480, width: 32, height: 32),
        .init(role: "upPortal", sourcePath: "mota/project/materials/animates.png", iconID: "upPortal", x: 0, y: 832, width: 32, height: 32),
        .init(role: "leftPortal", sourcePath: "mota/project/materials/animates.png", iconID: "leftPortal", x: 0, y: 768, width: 32, height: 32),
        .init(role: "downPortal", sourcePath: "mota/project/materials/animates.png", iconID: "downPortal", x: 0, y: 736, width: 32, height: 32),
        .init(role: "rightPortal", sourcePath: "mota/project/materials/animates.png", iconID: "rightPortal", x: 0, y: 800, width: 32, height: 32),
        .init(role: "man", sourcePath: "mota/project/materials/npcs.png", iconID: "man", x: 0, y: 0, width: 32, height: 32),
        .init(role: "trader", sourcePath: "mota/project/materials/npcs.png", iconID: "trader", x: 0, y: 32, width: 32, height: 32),
        .init(role: "fairy", sourcePath: "mota/project/materials/npcs.png", iconID: "fairy", x: 0, y: 96, width: 32, height: 32),
        .init(role: "wizard", sourcePath: "mota/project/materials/npcs.png", iconID: "wizard", x: 0, y: 128, width: 32, height: 32),
        .init(role: "npc0", sourcePath: "mota/project/materials/npc48.png", iconID: "npc0", x: 0, y: 0, width: 32, height: 48),
        .init(role: "greenSlime", sourcePath: "mota/project/materials/enemys.png", iconID: "greenSlime", x: 0, y: 0, width: 32, height: 32),
        .init(role: "bat", sourcePath: "mota/project/materials/enemys.png", iconID: "bat", x: 0, y: 128, width: 32, height: 32),
        .init(role: "vampire", sourcePath: "mota/project/materials/enemys.png", iconID: "vampire", x: 0, y: 224, width: 32, height: 32),
        .init(role: "ghostSoldier", sourcePath: "mota/project/materials/enemys.png", iconID: "ghostSoldier", x: 0, y: 352, width: 32, height: 32),
        .init(role: "rock", sourcePath: "mota/project/materials/enemys.png", iconID: "rock", x: 0, y: 448, width: 32, height: 32),
        .init(role: "slimeman", sourcePath: "mota/project/materials/enemys.png", iconID: "slimeman", x: 0, y: 480, width: 32, height: 32),
        .init(role: "bluePriest", sourcePath: "mota/project/materials/enemys.png", iconID: "bluePriest", x: 0, y: 512, width: 32, height: 32),
        .init(role: "brownWizard", sourcePath: "mota/project/materials/enemys.png", iconID: "brownWizard", x: 0, y: 576, width: 32, height: 32),
        .init(role: "redWizard", sourcePath: "mota/project/materials/enemys.png", iconID: "redWizard", x: 0, y: 608, width: 32, height: 32),
        .init(role: "swordsman", sourcePath: "mota/project/materials/enemys.png", iconID: "swordsman", x: 0, y: 736, width: 32, height: 32),
        .init(role: "redKnight", sourcePath: "mota/project/materials/enemys.png", iconID: "redKnight", x: 0, y: 832, width: 32, height: 32),
        .init(role: "poisonSkeleton", sourcePath: "mota/project/materials/enemys.png", iconID: "poisonSkeleton", x: 0, y: 1056, width: 32, height: 32),
        .init(role: "blueKing", sourcePath: "mota/project/materials/enemys.png", iconID: "blueKing", x: 0, y: 1440, width: 32, height: 32),
        .init(role: "magicMaster", sourcePath: "mota/project/materials/enemys.png", iconID: "magicMaster", x: 0, y: 1472, width: 32, height: 32),
        .init(role: "silverSlime", sourcePath: "mota/project/materials/enemys.png", iconID: "silverSlime", x: 0, y: 1504, width: 32, height: 32),
        .init(role: "evilPrincess", sourcePath: "mota/project/materials/enemys.png", iconID: "evilPrincess", x: 0, y: 1600, width: 32, height: 32),
        .init(role: "poisonZombie", sourcePath: "mota/project/materials/enemys.png", iconID: "poisonZombie", x: 0, y: 1760, width: 32, height: 32),
        .init(role: "steelGuard", sourcePath: "mota/project/materials/enemy48.png", iconID: "steelGuard", x: 0, y: 96, width: 32, height: 48),
        .init(role: "devilKnight", sourcePath: "mota/project/materials/enemys.png", iconID: "devilKnight", x: 0, y: 2176, width: 32, height: 32),
        .init(role: "tallYellowDoor", sourcePath: "mota/project/materials/npc48.png", iconID: "tallYellowDoor", x: 0, y: 192, width: 32, height: 48),
        .init(role: "ground", sourcePath: "mota/project/materials/terrains.png", iconID: "ground", x: 0, y: 0, width: 32, height: 32),
        .init(role: "ground2", sourcePath: "mota/project/materials/terrains.png", iconID: "ground2", x: 0, y: 96, width: 32, height: 32),
        .init(role: "ground3", sourcePath: "mota/project/materials/terrains.png", iconID: "ground3", x: 0, y: 128, width: 32, height: 32),
        .init(role: "grass", sourcePath: "mota/project/materials/terrains.png", iconID: "grass", x: 0, y: 32, width: 32, height: 32),
        .init(role: "grass2", sourcePath: "mota/project/materials/terrains.png", iconID: "grass2", x: 0, y: 64, width: 32, height: 32),
        .init(role: "blueShopLeft", sourcePath: "mota/project/materials/terrains.png", iconID: "blueShopLeft", x: 0, y: 224, width: 32, height: 32),
        .init(role: "pinkShopLeft", sourcePath: "mota/project/materials/terrains.png", iconID: "pinkShopLeft", x: 0, y: 256, width: 32, height: 32),
        .init(role: "blueShopRight", sourcePath: "mota/project/materials/terrains.png", iconID: "blueShopRight", x: 0, y: 288, width: 32, height: 32),
        .init(role: "pinkShopRight", sourcePath: "mota/project/materials/terrains.png", iconID: "pinkShopRight", x: 0, y: 320, width: 32, height: 32),
        .init(role: "sign", sourcePath: "mota/project/materials/npcs.png", iconID: "sign", x: 0, y: 256, width: 32, height: 32),
        .init(role: "moneyShop", sourcePath: "mota/project/materials/npcs.png", iconID: "moneyShop", x: 0, y: 320, width: 32, height: 32),
        .init(role: "expShop", sourcePath: "mota/project/materials/npcs.png", iconID: "expShop", x: 0, y: 288, width: 32, height: 32),
        .init(role: "greenMan", sourcePath: "mota/project/materials/npcs.png", iconID: "greenMan", x: 0, y: 384, width: 32, height: 32),
        .init(role: "blueTrader", sourcePath: "mota/project/materials/npcs.png", iconID: "blueTrader", x: 0, y: 416, width: 32, height: 32),
        .init(role: "steelKey", sourcePath: "mota/project/materials/items.png", iconID: "steelKey", x: 0, y: 128, width: 32, height: 32),
        .init(role: "hero_down", sourcePath: "mota/project/images/hero.png", iconID: "hero.down.stop", x: 0, y: 0, width: 32, height: 48),
        .init(role: "hero_down_leftFoot", sourcePath: "mota/project/images/hero.png", iconID: "hero.down.leftFoot", x: 32, y: 0, width: 32, height: 48),
        .init(role: "hero_down_rightFoot", sourcePath: "mota/project/images/hero.png", iconID: "hero.down.rightFoot", x: 96, y: 0, width: 32, height: 48),
        .init(role: "hero_left", sourcePath: "mota/project/images/hero.png", iconID: "hero.left.stop", x: 0, y: 48, width: 32, height: 48),
        .init(role: "hero_left_leftFoot", sourcePath: "mota/project/images/hero.png", iconID: "hero.left.leftFoot", x: 32, y: 48, width: 32, height: 48),
        .init(role: "hero_left_rightFoot", sourcePath: "mota/project/images/hero.png", iconID: "hero.left.rightFoot", x: 96, y: 48, width: 32, height: 48),
        .init(role: "hero_right", sourcePath: "mota/project/images/hero.png", iconID: "hero.right.stop", x: 0, y: 96, width: 32, height: 48),
        .init(role: "hero_right_leftFoot", sourcePath: "mota/project/images/hero.png", iconID: "hero.right.leftFoot", x: 32, y: 96, width: 32, height: 48),
        .init(role: "hero_right_rightFoot", sourcePath: "mota/project/images/hero.png", iconID: "hero.right.rightFoot", x: 96, y: 96, width: 32, height: 48),
        .init(role: "hero_up", sourcePath: "mota/project/images/hero.png", iconID: "hero.up.stop", x: 0, y: 144, width: 32, height: 48),
        .init(role: "hero_up_leftFoot", sourcePath: "mota/project/images/hero.png", iconID: "hero.up.leftFoot", x: 32, y: 144, width: 32, height: 48),
        .init(role: "hero_up_rightFoot", sourcePath: "mota/project/images/hero.png", iconID: "hero.up.rightFoot", x: 96, y: 144, width: 32, height: 48),
        .init(role: "hero", sourcePath: "mota/project/images/hero.png", iconID: "hero.down.stop", x: 0, y: 0, width: 32, height: 48),
        .init(role: "floor", sourcePath: "mota/project/materials/terrains.png", iconID: "ground", x: 0, y: 0, width: 32, height: 32),
        .init(role: "yellowDoor_frame1", sourcePath: "mota/project/materials/animates.png", iconID: "yellowDoor", x: 32, y: 128, width: 32, height: 32),
        .init(role: "yellowDoor_frame2", sourcePath: "mota/project/materials/animates.png", iconID: "yellowDoor", x: 64, y: 128, width: 32, height: 32),
        .init(role: "yellowDoor_frame3", sourcePath: "mota/project/materials/animates.png", iconID: "yellowDoor", x: 96, y: 128, width: 32, height: 32),
        .init(role: "man_alternate", sourcePath: "mota/project/materials/npcs.png", iconID: "man", x: 32, y: 0, width: 32, height: 32),
        .init(role: "trader_alternate", sourcePath: "mota/project/materials/npcs.png", iconID: "trader", x: 32, y: 32, width: 32, height: 32),
        .init(role: "fairy_alternate", sourcePath: "mota/project/materials/npcs.png", iconID: "fairy", x: 32, y: 96, width: 32, height: 32),
        .init(role: "wizard_alternate", sourcePath: "mota/project/materials/npcs.png", iconID: "wizard", x: 32, y: 128, width: 32, height: 32),
        .init(role: "dialogue_skin", sourcePath: "mota/project/images/winskin.png", iconID: "WindowSkin", x: 0, y: 0, width: 192, height: 128)
    ]
    /// The unmodified 169 numeric cells of upstream sample0. No event is evaluated.
    public static let sample0Map: [[Int]] = [
        [0, 0, 220, 0, 0, 20, 87, 3, 58, 59, 60, 61, 64],
        [0, 246, 0, 246, 0, 20, 0, 3, 57, 72, 63, 43, 44],
        [219, 0, 0, 0, 219, 20, 0, 3, 53, 54, 55, 56, 69],
        [20, 20, 125, 20, 20, 20, 0, 3, 49, 50, 51, 52, 68],
        [251, 247, 256, 234, 248, 6, 0, 3, 35, 36, 46, 47, 48],
        [6, 6, 125, 6, 6, 6, 0, 3, 0, 0, 0, 0, 0],
        [208, 227, 212, 216, 278, 5, 0, 1, 1, 1, 319, 1, 1],
        [201, 205, 217, 215, 224, 5, 0, 1, 27, 28, 29, 30, 31],
        [5, 5, 125, 5, 5, 5, 0, 1, 21, 22, 23, 24, 26],
        [0, 0, 263, 0, 0, 0, 45, 1, 1, 1, 121, 1, 1],
        [4, 4, 133, 4, 4, 4, 0, 0, 0, 0, 0, 85, 124],
        [87, 11, 12, 13, 14, 4, 4, 2, 2, 122, 2, 2, 2],
        [88, 89, 90, 91, 92, 93, 94, 2, 81, 82, 83, 84, 86]
    ]
    public static let mapRolesByNumber: [Int: String] = [
        0: "ground",
        1: "yellowWall",
        2: "whiteWall",
        3: "blueWall",
        4: "star",
        5: "lava",
        6: "ice",
        11: "lavaNet",
        12: "poisonNet",
        13: "weakNet",
        14: "curseNet",
        20: "autotile",
        21: "yellowKey",
        22: "blueKey",
        23: "redKey",
        24: "greenKey",
        26: "bigKey",
        27: "redGem",
        28: "blueGem",
        29: "greenGem",
        30: "yellowGem",
        31: "redPotion",
        35: "sword1",
        36: "shield1",
        43: "sword5",
        44: "shield5",
        45: "book",
        46: "fly",
        47: "pickaxe",
        48: "icePickaxe",
        49: "bomb",
        50: "centerFly",
        51: "upFly",
        52: "downFly",
        53: "coin",
        54: "freezeBadge",
        55: "cross",
        56: "superPotion",
        57: "earthquake",
        58: "poisonWine",
        59: "weakWine",
        60: "curseWine",
        61: "superWine",
        63: "pack",
        64: "amulet",
        68: "lifeWand",
        69: "jumpShoes",
        72: "skill1",
        81: "yellowDoor",
        82: "blueDoor",
        83: "redDoor",
        84: "greenDoor",
        85: "specialDoor",
        86: "steelDoor",
        87: "upFloor",
        88: "downFloor",
        89: "portal",
        90: "starPortal",
        91: "upPortal",
        92: "leftPortal",
        93: "downPortal",
        94: "rightPortal",
        121: "man",
        122: "trader",
        124: "fairy",
        125: "wizard",
        133: "npc0",
        201: "greenSlime",
        205: "bat",
        208: "vampire",
        212: "ghostSoldier",
        215: "rock",
        216: "slimeman",
        217: "bluePriest",
        219: "brownWizard",
        220: "redWizard",
        224: "swordsman",
        227: "redKnight",
        234: "poisonSkeleton",
        246: "blueKing",
        247: "magicMaster",
        248: "silverSlime",
        251: "evilPrincess",
        256: "poisonZombie",
        263: "steelGuard",
        278: "devilKnight",
        319: "tallYellowDoor"
    ]

    public static func importPack(bundle: Bundle = .main, workspaceID: String, repository: Repository) async throws -> MotaWorldImportedPack {
        guard let resources=bundle.resourceURL else { throw VideoError.notFound("魔塔世界固定原件未安装") }
        return try await importPack(from: resources.appendingPathComponent("Mota", isDirectory: true), workspaceID: workspaceID, repository: repository)
    }

    public static func importPack(from directory: URL, workspaceID: String, repository: Repository) async throws -> MotaWorldImportedPack {
        guard try repository.read().workspaces.contains(where: { $0.id == workspaceID }) else { throw VideoError.permission("固定世界原件只能导入已有工作区") }
        let prepared=try prepare(directory)
        let before=try repository.read()
        let existing=try checkExisting(workspaceID: workspaceID, prepared: prepared, database: before, repository: repository)
        if existing.count == fileDescriptors.count { return try pack(existing, database: before) }
        try Task.checkCancellation()
        var staged: [String: Asset]=[:]
        for file in fileDescriptors where existing[file.path] == nil {
            try Task.checkCancellation()
            var asset=try repository.ingest(prepared[file.path]!, name: file.assetName, workspaceID: workspaceID, mediaType: file.mediaType)
            if file.mediaType == "text" { asset.pages=[CoursePage(number: 1, text: String(data: prepared[file.path]!, encoding: .utf8)!)] }
            staged[file.path]=asset
        }
        return try repository.transaction { database in
            var result=try checkExisting(workspaceID: workspaceID, prepared: prepared, database: database, repository: repository)
            for file in fileDescriptors where result[file.path] == nil {
                guard var asset=staged[file.path] else { throw VideoError.conflict("世界素材在导入期间变化，请刷新重试") }
                let proof=Evidence(workspaceID: workspaceID, title: file.evidenceTitle(assetName: asset.name),
                                   source: file.sourceURL, claim: file.evidenceClaim, owner: file.evidenceOwner,
                                   commercialAllowed: false, uploadConsent: false, verified: true, assetID: asset.id)
                asset.evidenceID=proof.id
                database.assets.append(asset); database.evidence.append(proof); result[file.path]=asset
            }
            return try pack(result, database: database)
        }
    }

    private static func safeDirectory(_ url: URL) throws {
        let values=try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw VideoError.invalid("世界固定输入目录不能是链接") }
    }
    private static func prepare(_ root: URL) throws -> [String: Data] {
        try safeDirectory(root)
        var captured: [String: Data]=[:]
        for file in fileDescriptors {
            try Task.checkCancellation()
            var parent=root
            for part in file.path.split(separator: "/").dropLast() {
                parent.appendPathComponent(String(part), isDirectory: true); try safeDirectory(parent)
            }
            let location=root.appendingPathComponent(file.path)
            let values=try location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.bytes,
                  (1...1_048_576).contains(file.bytes) else { throw VideoError.invalid("世界固定输入大小、文件或链接无效：" + file.path) }
            let bytes=try Data(contentsOf: location)
            guard bytes.count == file.bytes, Codec.hash(bytes) == file.sha256 else { throw VideoError.review("世界原件或来源字节SHA256不符：" + file.path) }
            if file.mediaType == "image" {
                guard let source=CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetType(source) as String? == "public.png",
                      CGImageSourceGetCount(source) == 1,
                      let props=CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width=props[kCGImagePropertyPixelWidth] as? Int, let height=props[kCGImagePropertyPixelHeight] as? Int,
                      width == file.width, height == file.height,
                      CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                    throw VideoError.invalid("世界原图PNG实际尺寸或完整解码失败：" + file.path)
                }
            } else { guard String(data: bytes, encoding: .utf8) != nil else { throw VideoError.invalid("世界被动来源不是UTF8：" + file.path) } }
            captured[file.path]=bytes
        }
        return captured // All fixed inputs pass before the first CAS write.
    }
    private static func checkExisting(workspaceID: String, prepared: [String: Data], database: Database, repository: Repository) throws -> [String: Asset] {
        guard database.workspaces.contains(where: { $0.id == workspaceID }) else { throw VideoError.permission("世界导入工作区已撤销") }
        var result: [String: Asset]=[:]
        for file in fileDescriptors {
            let matches=database.assets.filter { $0.workspaceID == workspaceID && $0.hash == file.sha256 }
            guard matches.count <= 1 else { throw VideoError.conflict("世界同源资产重复，未自动挑选或覆盖：" + file.path) }
            guard let asset=matches.first else { continue }
            guard file.acceptsAssetName(asset.name), asset.bytes == file.bytes, asset.ext == URL(fileURLWithPath: file.path).pathExtension,
                  asset.mediaType == file.mediaType, asset.durationFrames == nil, asset.generatedSource == nil, asset.warnings.isEmpty,
                  let id=asset.evidenceID, let proof=database.evidence.first(where: { $0.id == id && $0.workspaceID == workspaceID }),
                  proof.assetID == asset.id, proof.title == file.evidenceTitle(assetName: asset.name),
                  proof.source == file.sourceURL, proof.owner == file.evidenceOwner, proof.claim == file.evidenceClaim,
                  proof.usable(commercial: false), !proof.commercialAllowed, !proof.uploadConsent else {
                throw VideoError.conflict("世界原件来源、用途或媒体记录变化，未改写旧记录：" + file.path)
            }
            if file.mediaType == "text" {
                guard asset.pages.count == 1, asset.pages[0].number == 1, !asset.pages[0].requiresOCR,
                      asset.pages[0].text == String(data: prepared[file.path]!, encoding: .utf8) else { throw VideoError.conflict("世界来源被动原文的解析记录变化") }
            } else if !asset.pages.isEmpty { throw VideoError.conflict("世界图片带有不符的文本解析记录") }
            let bytes=try Data(contentsOf: repository.assetURL(asset))
            guard bytes.count == file.bytes, Codec.hash(bytes) == file.sha256 else { throw VideoError.review("世界已登记CAS原件损坏或缺失：" + file.path) }
            result[file.path]=asset
        }
        return result
    }
    private static func pack(_ assets: [String: Asset], database: Database) throws -> MotaWorldImportedPack {
        let sources=try fileDescriptors.map { file -> ClassicSource in
            guard let asset=assets[file.path], let id=asset.evidenceID, let proof=database.evidence.first(where: { $0.id == id }) else { throw VideoError.notFound("世界具体源或证据缺失") }
            return ClassicSource(assetID: asset.id, hash: asset.hash, source: proof.source, owner: proof.owner, license: licence, evidenceID: id)
        }
        let sprites=try spriteDescriptors.map { item -> ClassicSprite in
            guard let asset=assets[item.sourcePath], let file=fileDescriptors.first(where: { $0.path == item.sourcePath }),
                  let width=file.width, let height=file.height, item.x>=0, item.y>=0, item.width>0, item.height>0,
                  item.x+item.width<=width, item.y+item.height<=height else { throw VideoError.invalid("固定世界图块区域超出实际原图") }
            return ClassicSprite(role: item.role, assetID: asset.id, x: Double(item.x)/Double(width), y: Double(item.y)/Double(height),
                                 width: Double(item.width)/Double(width), height: Double(item.height)/Double(height))
        }
        guard Set(sprites.map(\.role)).count == sprites.count, sprites.count<=128,
              sample0Map.count == 13, sample0Map.allSatisfy({ $0.count == 13 && $0.allSatisfy({ mapRolesByNumber[$0] != nil }) }) else { throw VideoError.invalid("固定世界图块或原地图对应不完整") }
        let originals=fileDescriptors.filter { $0.mediaType == "image" }.map { assets[$0.path]!.id }
        let artwork=ClassicArtwork(gameplay: .sokoban, sprites: sprites, sources: sources, derivation: .original,
            transformation: "固定mota-js 3efb548原件图块，样板0层完整13×13拓扑供参考；23×13由作者明确改编。autotile只取中心实区域，未移植自适应四分块或上游JS。不是经典50层截图、游戏运行时或独立原创卡通。", originalAssetIDs: originals)
        return MotaWorldImportedPack(artwork: artwork, assetsByPath: assets, sample0Map: sample0Map, mapRolesByNumber: mapRolesByNumber)
    }
}
