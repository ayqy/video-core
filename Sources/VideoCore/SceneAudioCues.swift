import Foundation

/// Independent Host audio events. Existing Classic artwork keeps its original
/// list; neither list is sent to a drawing plugin or inferred from an animation.
public enum SceneAudioCueRules {
    public static func combined(scene: Scene) -> [ClassicAudioCue] {
        (scene.classicArtwork?.audioCues ?? []) + (scene.audioCues ?? [])
    }

    /// With no new field, all historical Classic validation remains unchanged.
    /// Scene validation receives scoped assets; callers with an actual workspace
    /// can additionally require that scope before editing or mixing.
    public static func validate(scene: Scene, assets: [Asset], workspaceID: String? = nil) throws {
        guard let cues = scene.audioCues else { return }
        let all = combined(scene: scene)
        guard all.count <= 128, Set(all.map(\.id)).count == all.count,
              cues.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 200 && !$0.assetID.isEmpty && $0.assetID.utf8.count <= 200 }) else {
            throw VideoError.invalid("场景音效数量超界、标识重复或资产标识无效")
        }
        if !cues.isEmpty {
            guard (1...54000).contains(scene.durationFrames), scene.speed.isFinite, (0.25...4).contains(scene.speed),
                  (0...54000).contains(scene.pauseFrames) else {
                throw VideoError.invalid("场景音效的实际呈现速度、时长或留白无效")
            }
        }
        for cue in cues {
            guard let asset = assets.first(where: { $0.id == cue.assetID && (workspaceID == nil || $0.workspaceID == workspaceID) }),
                  asset.mediaType == "audio", asset.bytes > 0, let frames = asset.durationFrames, frames > 0,
                  cue.startFrame >= 0, cue.durationFrames > 0, cue.durationFrames <= frames,
                  cue.durationFrames <= scene.durationFrames, cue.startFrame <= scene.durationFrames - cue.durationFrames,
                  cue.gain.isFinite, (0...1).contains(cue.gain) else {
                throw VideoError.invalid("场景音效须引用本工作区真实音频，实长、位置和音量不得越界")
            }
            // Host event offset and length both follow source-frame / speed.
            // The encoded scene has a rounded active frame count plus its real
            // trailing hold. Keep even subframe cues, but never let rounding
            // place an event beyond that actual scene into the next one.
            // Use bounded Double arithmetic rather than adding untrusted Ints.
            let available = max(1, (Double(scene.durationFrames) / scene.speed).rounded()) + Double(scene.pauseFrames)
            let end = (Double(cue.startFrame) + Double(cue.durationFrames)) / scene.speed
            guard end.isFinite, end <= available else {
                throw VideoError.invalid("场景音效末端超过实际呈现时长；请调整事件或明确增加尾部留白，不能依成片自动截音")
            }
        }
    }

    public static func validateRights(scene: Scene, workspaceID: String, assets: [Asset], evidence: [Evidence],
                                      commercial: Bool, requireListening: Bool = false, now: Date = Date()) throws {
        try validate(scene: scene, assets: assets, workspaceID: workspaceID)
        guard let cues = scene.audioCues else { return }
        var pending: [String] = []
        for cue in cues {
            guard let asset = assets.first(where: { $0.id == cue.assetID && $0.workspaceID == workspaceID }),
                  let id = asset.evidenceID else {
                throw VideoError.permission("场景音效缺少具体原件的来源与权利记录")
            }
            pending.append(id)
        }
        var visited: Set<String> = []
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let proof = evidence.first(where: { $0.id == id && $0.workspaceID == workspaceID }),
                  proof.usable(commercial: commercial, now: now) else {
                throw VideoError.permission("场景音效来源、权利人或适用授权尚未核实、已过期或跨工作区")
            }
            if let id = proof.assetID {
                guard let asset = assets.first(where: { $0.id == id && $0.workspaceID == workspaceID }) else {
                    throw VideoError.permission("场景音效依赖的来源原件缺失或跨工作区")
                }
                if let next = asset.evidenceID { pending.append(next) }
                else if commercial { throw VideoError.permission("场景音效来源原件尚无适用权利记录") }
            }
        }
        if requireListening && cues.contains(where: { !$0.listened && $0.gain > 0 }) {
            throw VideoError.review("场景音效或原录音提示尚未实际试听确认")
        }
    }

    /// Binding an existing recording does not generate it or approve listening.
    /// Normal Agent edit apply can save the returned ordinary Scene revision.
    public static func addingCue(assetID: String, startFrame: Int, gain: Double, use: ClassicAudioCue.Use,
                                 to original: Scene, assets: [Asset], evidence: [Evidence], workspaceID: String) throws -> Scene {
        guard !original.locked,
              let asset = assets.first(where: { $0.id == assetID && $0.workspaceID == workspaceID && $0.mediaType == "audio" }),
              let frames = asset.durationFrames, frames > 0 else {
            throw VideoError.invalid("请选择未锁定镜头和本工作区已登记实长的真实音频")
        }
        _ = try ClassicSceneEditing.source(assetID: assetID, assets: assets, evidence: evidence, workspaceID: workspaceID)
        var scene = original
        scene.audioCues = (scene.audioCues ?? []) + [ClassicAudioCue(assetID: assetID, startFrame: startFrame, durationFrames: frames, gain: gain, use: use, listened: false)]
        try validate(scene: scene, assets: assets, workspaceID: workspaceID)
        return scene
    }

    /// Approval-only edits remain explicit declarations. A changed event or its
    /// actual presentation context cannot carry an earlier event's listening.
    static func invalidatingChangedEvents(old: Scene, scene: inout Scene) -> Bool {
        guard var cues = scene.audioCues else { return old.audioCues?.isEmpty == false }
        func identity(_ cue: ClassicAudioCue) -> ClassicAudioCue { var copy = cue; copy.listened = false; return copy }
        let previous = old.audioCues ?? []
        // Follow the editor's existing presentation changes: the same source
        // event can no longer retain listening when its visible action moves.
        let oldLayers = old.layers ?? [], newLayers = scene.layers ?? []
        let entrancesChanged = oldLayers.filter { $0.entrance != nil } != newLayers.filter { $0.entrance != nil }
        let sequencesChanged = oldLayers.filter { $0.imageSequence != nil || $0.sourceRect != nil || $0.imageFlipHorizontal != nil } !=
            newLayers.filter { $0.imageSequence != nil || $0.sourceRect != nil || $0.imageFlipHorizontal != nil }
        let dataChanged = oldLayers.filter { $0.dataPresentation != nil } != newLayers.filter { $0.dataPresentation != nil }
        let simulationWindowChanged = (old.kind == .simulation || scene.kind == .simulation) && old.simulationPresentation != scene.simulationPresentation
        let contextChanged = old.kind != scene.kind || old.durationFrames != scene.durationFrames || old.speed != scene.speed ||
            old.preservePitch != scene.preservePitch || old.pauseFrames != scene.pauseFrames || old.muted != scene.muted ||
            old.assetID != scene.assetID || old.sourceStartFrame != scene.sourceStartFrame || old.sourceEndFrame != scene.sourceEndFrame ||
            old.mediaPresentation != scene.mediaPresentation || old.mediaFraming != scene.mediaFraming ||
            old.paperPresentation != scene.paperPresentation || entrancesChanged || sequencesChanged || dataChanged ||
            old.modelScene3D != scene.modelScene3D || old.storyActions != scene.storyActions || old.storyCausality != scene.storyCausality ||
            old.gameWorld != scene.gameWorld || old.cartoonPerformance != scene.cartoonPerformance ||
            old.cartoonRig != scene.cartoonRig || old.cartoonPresenter != scene.cartoonPresenter ||
            old.simulation != scene.simulation || simulationWindowChanged
        let changed = previous.map(identity) != cues.map(identity) || (contextChanged && !cues.isEmpty)
        for index in cues.indices {
            if contextChanged || !previous.contains(where: { identity($0) == identity(cues[index]) }) { cues[index].listened = false }
        }
        scene.audioCues = cues
        return changed
    }
}
