import Foundation

/// The free walkthrough is a declared synthetic exercise, never a purchased entitlement.
/// A user-editable isExample flag by itself does not authorize arbitrary real projects.
public enum EditorPracticeRules {
    public static let sourceText="基础编辑与本地输出练习；不含真实商品或经营数据。"
    public static func allows(project:Project,assets:[Asset]) -> Bool {
        guard let original=project.revisions.first,let originalProduct=original.product,let currentProduct=project.current.product,originalProduct.isExample==true,originalProduct.assetIDs.count==1,
              let source=assets.first(where:{$0.id==originalProduct.assetIDs[0] && $0.workspaceID==project.workspaceID}),
              source.hash==Codec.hash(Data(sourceText.utf8)),source.bytes==Data(sourceText.utf8).count,source.mediaType=="text",
              var expected=try? LearningExample.project(workspaceID:project.workspaceID,asset:source).current.product,
              originalProduct.prices.count==1 else{return false}
        expected.id=originalProduct.id;expected.prices[0].id=originalProduct.prices[0].id
        guard originalProduct.hasSameFacts(as:expected),currentProduct.hasSameFacts(as:originalProduct),project.current.purpose == .education,
              project.current.cta=="换成真实资料，再创建自己的作品" else{return false}
        // Tutorial text/timing/layout changes are allowed. It cannot quietly become a real-media customer project.
        var references=Set(project.current.scenes.compactMap(\.assetID)+project.current.scenes.compactMap{$0.voice?.assetID}+project.current.scenes.flatMap{$0.layers ?? []}.compactMap(\.assetID)+project.current.scenes.flatMap{$0.narrativeSources ?? []}.map(\.assetID))
        for artwork in project.current.scenes.compactMap(\.classicArtwork) {references.formUnion(artwork.assetIDs)}
        if let music=project.current.musicAssetID{references.insert(music)}
        for character in project.current.scenes.compactMap(\.characterProfile){if let voice=character.voiceAssetID{references.insert(voice)}}
        return references.isSubset(of:[source.id])
    }
}
