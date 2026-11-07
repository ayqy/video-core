import XCTest
import VideoCore
@testable import VideoMedia
@preconcurrency import AVFoundation
import CoreMedia

/// These are disposable real AVFoundation files. They exercise portable cache
/// reuse, not the production game's appearance or any listening approval.
final class VisualCacheBackupTests: XCTestCase {
    private enum Interrupted: Error { case checkpoint }
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        let stop: Double?
        init(stop: Double? = nil) { self.stop = stop }
        func record(_ value: Double) throws {
            lock.lock(); storage.append(value); lock.unlock()
            if let stop, value >= stop { throw Interrupted.checkpoint }
        }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func pair(_ revision: Revision, repo: Repository,
                      encoding: VisualClipCache.EncodingConfiguration,
                      range: Range<Int>) throws -> (URL, URL) {
        let sceneKey = try VisualClipCache.fingerprint(revision: revision, index: 0,
            database: repo.read(), modules: nil, encoding: encoding)
        let interval = VisualClipCache.Interval(sceneKey: sceneKey,
            lowerBound: range.lowerBound, upperBound: range.upperBound)
        let directory = repo.root.appendingPathComponent("cache/visuals"), key = try interval.key
        return (directory.appendingPathComponent(key + ".mp4"),
                directory.appendingPathComponent(key + ".plist"))
    }

    private func compose(_ revision: Revision, repo: Repository,
                         encoding: VisualClipCache.EncodingConfiguration,
                         output: URL, progress: Progress) async throws -> Int {
        try await VisualClipCache.compose(revision: revision, repository: repo,
            database: repo.read(), output: output, modules: nil, encoding: encoding,
            progress: { try progress.record($0) })
    }

    /// Decode every sample and its PTS; selected actual pixels allow us to
    /// compare restored cached pictures against the original encoded segment.
    private func decode(_ url: URL, frames: Int, fps: Int) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        XCTAssertTrue(reader.canAdd(output)); reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),
                CMTime(value: Int64(samples.count), timescale: Int32(fps))), 0,
                "冷恢复合成每一帧都必须保持原时间轴，不能重播缓存或漏掉尾帧")
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            guard let address = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                throw VideoError.invalid("缓存恢复测试没有实际解码像素")
            }
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            var pixels: [UInt8] = []
            for x in [width / 5, width / 2, width * 4 / 5] {
                let offset = height / 2 * rowBytes + x * 4
                pixels.append(contentsOf: [bytes[offset], bytes[offset + 1], bytes[offset + 2]])
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            samples.append(pixels)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(samples.count, frames)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeCompare(duration, CMTime(value: Int64(frames), timescale: Int32(fps))), 0)
        return samples
    }

    func testRealEncodedCheckpointSurvivesBackupAndColdRestoreAndResumesActualComposition() async throws {
        let fm = FileManager.default
        let sourceRoot = fm.temporaryDirectory.appendingPathComponent("visual-cache-backup-source-" + UUID().uuidString)
        let restoredRoot = fm.temporaryDirectory.appendingPathComponent("visual-cache-backup-restored-" + UUID().uuidString)
        defer { try? fm.removeItem(at: sourceRoot); try? fm.removeItem(at: restoredRoot) }
        let repository = try Repository(root: sourceRoot)
        let workspace = Workspace(name: "实际片段冷恢复", owner: "tester")
        var scene = Scene(title: "同一镜头继续", body: "完成片段随工程备份。", durationFrames: 121)
        scene.paperPresentation = PaperPresentation()
        var block = SceneLayer(kind: .rectangle, endFrame: 121)
        block.x = 0.2; block.y = 0.45; block.width = 0.16; block.height = 0.18; block.color = "E54B4B"
        block.keyframes = [Keyframe(frame: 0, x: 0.2, y: 0.45, scale: 1),
                           Keyframe(frame: 120, x: 0.8, y: 0.45, scale: 1)]
        scene.layers = [block]
        let revision = Revision(contentContext: ContentContext(workspaceID: workspace.id, name: "恢复原轴"),
                                aspect: .landscape, scenes: [scene])
        let project = Project(workspaceID: workspace.id, name: "冷恢复规则", revision: revision)
        try repository.transaction { $0.workspaces = [workspace]; $0.projects = [project] }
        let encoding = try VisualClipCache.EncodingConfiguration.capture(aspect: revision.aspect, fps: revision.fps)
        guard encoding.canReusePersistentCache else {
            throw XCTSkip("此机器缺少完整编码器或框架身份，不能声称持久缓存实际复用")
        }
        let checkpointProgress = Double(120) / Double(revision.frames) * 0.75
        do {
            _ = try await compose(revision, repo: repository, encoding: encoding,
                output: sourceRoot.appendingPathComponent("interrupted.mp4"),
                progress: Progress(stop: checkpointProgress))
            XCTFail("首120帧封口后必须按正常进度回调中断")
        } catch Interrupted.checkpoint {}
        let (sourceClip, sourceReceipt) = try pair(revision, repo: repository, encoding: encoding, range: 0..<120)
        let originalClip = try Data(contentsOf: sourceClip), originalReceipt = try Data(contentsOf: sourceReceipt)
        let originalPixels = try await decode(sourceClip, frames: 120, fps: revision.fps)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: sourceClip.deletingLastPathComponent().path).count, 2,
                       "只备份已封口首段，不能保临时视频或未完成尾段")
        let businessBefore = try Codec.data(repository.read().projects)
        let backup = try repository.backup()
        let envelope = try PropertyListDecoder().decode(Repository.Backup.self, from: backup)
        let files = try XCTUnwrap(envelope.visualCache)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.first(where: { $0.key.hasSuffix(sourceClip.lastPathComponent) })?.value, originalClip)
        XCTAssertEqual(files.first(where: { $0.key.hasSuffix(sourceReceipt.lastPathComponent) })?.value, originalReceipt)
        let restored = try Repository.restore(backup, to: restoredRoot)
        XCTAssertEqual(try Codec.data(restored.read().projects), businessBefore)
        let restoredRevision = try XCTUnwrap(restored.read().projects.first).current
        XCTAssertEqual(restoredRevision.id, revision.id)
        let (restoredClip, restoredReceipt) = try pair(restoredRevision, repo: restored,
            encoding: encoding, range: 0..<120)
        let (tailClip, tailReceipt) = try pair(restoredRevision, repo: restored,
            encoding: encoding, range: 120..<121)
        XCTAssertEqual(try Data(contentsOf: restoredClip), originalClip)
        XCTAssertEqual(try Data(contentsOf: restoredReceipt), originalReceipt)
        XCTAssertFalse(fm.fileExists(atPath: tailClip.path)); XCTAssertFalse(fm.fileExists(atPath: tailReceipt.path))
        // Remove the original root entirely: no accidental same-root hit or
        // pointer back to the former worktree may satisfy the acceptance.
        try fm.removeItem(at: sourceRoot)
        let past = Date(timeIntervalSince1970: 1_000)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: restoredClip.path)
        let inode = (try fm.attributesOfItem(atPath: restoredClip.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        let progress = Progress(), output = restoredRoot.appendingPathComponent("actual-cold-resume.mp4")
        let hits = try await compose(restoredRevision, repo: restored, encoding: encoding, output: output, progress: progress)
        XCTAssertEqual(hits, 0, "部分区间命中不能冒称整个镜头命中")
        XCTAssertEqual(try XCTUnwrap(progress.values.first), checkpointProgress, accuracy: 0.0000001,
                       "真实合成先报告恢复的120帧，再生成尾帧")
        let attributes = try fm.attributesOfItem(atPath: restoredClip.path)
        XCTAssertEqual((attributes[.systemFileNumber] as? NSNumber)?.uint64Value, inode,
                       "复用缓存不能删除重绘后冒充命中")
        XCTAssertGreaterThan(try XCTUnwrap(attributes[.modificationDate] as? Date), past)
        XCTAssertEqual(try Data(contentsOf: restoredClip), originalClip)
        XCTAssertEqual(try Data(contentsOf: restoredReceipt), originalReceipt)
        let tail = try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,
                                                   from: Data(contentsOf: tailReceipt))
        XCTAssertEqual(tail.interval.lowerBound, 120); XCTAssertEqual(tail.interval.upperBound, 121)
        XCTAssertEqual(tail.artifact.frames, 1)
        XCTAssertEqual(tail.artifact.sha256, Codec.hash(try Data(contentsOf: tailClip)))
        let resumedPixels = try await decode(output, frames: 121, fps: revision.fps)
        let tailPixels = try await decode(tailClip, frames: 1, fps: revision.fps)
        XCTAssertEqual(Array(resumedPixels.prefix(120)), originalPixels,
                       "完整合成前120帧须来自恢复原片，不能重播或插空")
        XCTAssertEqual(Array(resumedPixels.suffix(1)), tailPixels,
                       "完整合成最后一帧须来自新生成的尾区间")
        XCTAssertEqual(try Codec.data(restored.read().projects), businessBefore,
                       "媒体缓存恢复不授予内容、声音或效果审查，也不改工程历史")
    }
}
