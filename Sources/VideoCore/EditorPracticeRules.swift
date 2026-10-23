import Foundation

/// The free walkthrough is a declared synthetic exercise, never a purchased entitlement.
/// A user-editable isExample flag by itself does not authorize arbitrary real projects.
public enum EditorPracticeRules {
    public static let sourceText="基础编辑与本地输出练习；不含真实商品或经营数据。"
    public static func allows(project:Project,assets:[Asset]) -> Bool {
        guard let original=project.revisions.first else{return false}
        if original.schemaVersion==2 || original.contentContext != nil {
            return allowsContent(project:project,assets:assets)
        }
        return allowsLegacy(project:project,assets:assets)
    }
    private static func allowsContent(project:Project,assets:[Asset])->Bool {
        guard let original=project.revisions.first,original.schemaVersion==2,original.product==nil,
              let context=original.contentContext,context.assetIDs.count==1,
              (try? context.validate()) != nil,
              let source=assets.first(where:{$0.id==context.assetIDs[0] && $0.workspaceID==project.workspaceID}),
              let expected=try? LearningExample.contentProject(workspaceID:project.workspaceID,asset:source) else{return false}
        var expectedContext=expected.current.contentContext!
        expectedContext.id=context.id // Context IDs are legitimately random, never a credential.
        guard context==expectedContext,original.scenes.count==expected.current.scenes.count,
              original.fps==expected.current.fps,original.toolchain==expected.current.toolchain,
              original.aspect==expected.current.aspect else{return false}
        for (scene,expectedScene) in zip(original.scenes,expected.current.scenes) {
            var exact=expectedScene;exact.id=scene.id
            guard scene==exact else{return false}
        }
        let sceneIDs=Set(original.scenes.map(\.id))
        guard sceneIDs.count==2 else{return false}
        // Check saved history as well as the current revision. A synthetic last revision
        // must not authorize inserting a real-media version earlier in the same project.
        for revision in project.revisions {
            guard revision.schemaVersion==2,revision.product==nil,revision.contentContext==context,
                  revision.workspaceID==project.workspaceID,revision.purpose == .education,revision.cta.isEmpty,
                  revision.productionBrief==nil,revision.musicAssetID==nil,revision.audioQuality==nil,
                  revision.fps==original.fps,revision.toolchain==original.toolchain,
                  revision.scenes.count==2,Set(revision.scenes.map(\.id))==sceneIDs else{return false}
            for scene in revision.scenes {
                guard let first=original.scenes.first(where:{$0.id==scene.id}),
                      (try? scene.validate(assets:[source])) != nil,
                      (scene.layers ?? []).allSatisfy({$0.assetID==nil && $0.kind != .image}) else{return false}
                // Permit only text, timing and layout controls on these two tutorial scenes.
                // Everything else (media, voices, mappings, narrative sources, characters,
                // simulation/recordings and hidden evidence) must retain its empty original.
                var permitted=first
                permitted.title=scene.title;permitted.body=scene.body;permitted.captions=scene.captions
                permitted.durationFrames=scene.durationFrames;permitted.speed=scene.speed;permitted.pauseFrames=scene.pauseFrames
                permitted.x=scene.x;permitted.y=scene.y;permitted.scale=scene.scale;permitted.keyframes=scene.keyframes
                permitted.color=scene.color;permitted.fontName=scene.fontName;permitted.locked=scene.locked;permitted.layers=scene.layers
                guard permitted==scene else{return false}
            }
        }
        return true
    }
    private static func allowsLegacy(project:Project,assets:[Asset])->Bool {
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
