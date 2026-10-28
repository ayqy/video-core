import XCTest
import CoreGraphics
import CoreText
import VideoCore
@testable import VideoMedia

final class CinemaSubtitleTests: XCTestCase {
    private func context(width: Int = 1280, height: Int = 720, color: CGColor = CGColor(red: 0.7, green: 0.2, blue: 0.4, alpha: 1)) throws -> CGContext {
        let c = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(color); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return c
    }
    private func region(_ image: CGImage, _ rect: CGRect) throws -> Data {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height)))
        let c = try context(width: crop.width, height: crop.height)
        c.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return Data(bytes: try XCTUnwrap(c.data), count: crop.width * crop.height * 4)
    }
    private func revision(_ scene: Scene, aspect: Aspect) -> Revision {
        Revision(contentContext: ContentContext(workspaceID: "w", name: "电影字幕规则材料"), aspect: aspect, scenes: [scene], cta: "")
    }

    private func srtCues(_ value: String) throws -> [(start: Int, end: Int, text: String)] {
        func milliseconds(_ value: String) throws -> Int {
            let fields = value.split { $0 == ":" || $0 == "," }
            XCTAssertEqual(fields.count, 4)
            let numbers = try fields.map { try XCTUnwrap(Int($0)) }
            guard numbers.count == 4 else { throw VideoError.invalid("规则材料的SRT时间无效") }
            return ((numbers[0] * 60 + numbers[1]) * 60 + numbers[2]) * 1000 + numbers[3]
        }
        return try value.components(separatedBy: "\n\n").filter { !$0.isEmpty }.enumerated().map { index, block in
            let lines = block.components(separatedBy: "\n")
            XCTAssertGreaterThanOrEqual(lines.count, 3)
            guard lines.count >= 3 else { throw VideoError.invalid("规则材料的SRT句段无效") }
            XCTAssertEqual(lines[0], String(index + 1))
            let bounds = lines[1].components(separatedBy: " --> ")
            guard bounds.count == 2 else { throw VideoError.invalid("规则材料的SRT区间无效") }
            let start = try milliseconds(bounds[0]), end = try milliseconds(bounds[1])
            XCTAssertLessThan(start, end, "不能导出零时长句段")
            return (start, end, lines.dropFirst(2).joined(separator: "\n"))
        }
    }

    private func assertSRTMatchesPainterFramePTS(_ r: Revision) throws {
        let cues = try srtCues(MediaRenderer.subtitles(r))
        XCTAssertEqual(cues.map(\.start), cues.map(\.start).sorted())
        for frame in 0..<r.frames {
            let (scene, local, _) = ScenePainter.scene(revision: r, frame: frame)
            let source = scene.renderSourceFrame(atTimelineFrame: local)
            let expected = scene.captions.first { $0.startFrame <= source && source < $0.endFrame }
            // Compare rational video PTS against serialized milliseconds with
            // integer cross-products, without a floating timestamp tolerance.
            let actual = cues.filter { frame * 1000 >= $0.start * r.fps && frame * 1000 < $0.end * r.fps }
            XCTAssertEqual(actual.map(\.text), expected.map { [$0.text] } ?? [], "输出帧\(frame)，fps=\(r.fps)")
        }
    }

    func testSRTMatchesActualFramePTSForRetimedGapsUnorderedCuesRoundedTailAndPause() throws {
        let prefix = Scene(title: "封面", body: "封面没有字幕", durationFrames: 3)
        var fractional = Scene(title: "句段", body: "保持中间停顿", durationFrames: 90)
        fractional.speed = 1.5
        fractional.captions = [Caption(text: "后一句。", startFrame: 31, endFrame: 62),
                               Caption(text: "前一句。", startFrame: 0, endFrame: 20)]
        var tail = Scene(title: "句尾", body: "保留最后一帧", durationFrames: 123)
        tail.speed = 2
        tail.captions = [Caption(text: "最后一句。", startFrame: 56, endFrame: 123)]
        var pause = Scene(title: "停顿", body: "沿用已有源映射", durationFrames: 9)
        pause.speed = 4; pause.pauseFrames = 2
        pause.captions = [Caption(text: "末帧。", startFrame: 8, endFrame: 9)]
        let r = Revision(contentContext: ContentContext(workspaceID: "w", name: "字幕输出窗"),
                         aspect: .landscape, scenes: [prefix, fractional, tail, pause])
        try assertSRTMatchesPainterFramePTS(r)
        XCTAssertEqual(try srtCues(MediaRenderer.subtitles(r)).map(\.text), ["前一句。", "后一句。", "最后一句。", "末帧。"])
        XCTAssertEqual(fractional.captions.map(\.text), ["后一句。", "前一句。"], "输出不重排作者原数组")
    }

    func testSRTMillisecondQuantizationPreservesFrameMembershipAtEverySupportedFPS() throws {
        let prefix = Scene(title: "前景", body: "累计帧偏移", durationFrames: 5)
        var scene = Scene(title: "逐帧字幕", body: "相邻句段与空隙", durationFrames: 14)
        scene.captions = [Caption(text: "第一句。", startFrame: 2, endFrame: 4),
                          Caption(text: "第二句。", startFrame: 4, endFrame: 7),
                          Caption(text: "第三句。", startFrame: 10, endFrame: 14)]
        for fps in 1...120 {
            var r = Revision(contentContext: ContentContext(workspaceID: "w", name: "毫秒序列化"),
                             aspect: .landscape, scenes: [prefix, scene])
            r.fps = fps
            try assertSRTMatchesPainterFramePTS(r)
            if fps == 30 {
                XCTAssertTrue(try MediaRenderer.subtitles(r).contains("00:00:00,233 --> 00:00:00,300"))
            }
        }
    }

    func testRetimedSRTBoundariesMatchVisibleInkInBothPainterEntrypoints() throws {
        for aspect in Aspect.allCases { for paper in [false, true] {
            for (speed, start, end, expectedStart, expectedEnd) in [(2.0, 31, 61, 16, 31), (1.5, 31, 62, 21, 42)] {
                var scene = Scene(title: "四个邻居修路", body: "凑够三枚开工", durationFrames: 90)
                scene.speed = speed
                if paper { scene.paperPresentation = PaperPresentation() }
                scene.captions = [Caption(text: "小陈把自己那枚收了回去。", startFrame: start, endFrame: end)]
                let r = revision(scene, aspect: aspect)
                var without = r; without.scenes[0].captions = []
                let band = paper ? PaperPresentationPainter.Layout(aspect: aspect, mode: .explanation, showPrice: false, showAction: false).caption : ScenePainter.OverlayLayout(width: CGFloat(aspect.width), height: CGFloat(aspect.height), showPrice: false, separateBody: false).captionText
                let cues = try srtCues(MediaRenderer.subtitles(r))
                for frame in [expectedStart - 1, expectedStart, expectedEnd - 1, expectedEnd] {
                    let image = try ScenePainter.image(revision: r, frame: frame)
                    let empty = try ScenePainter.image(revision: without, frame: frame)
                    let inkVisible = try region(image, band) != region(empty, band)
                    let srtVisible = cues.contains { frame * 1000 >= $0.start * r.fps && frame * 1000 < $0.end * r.fps }
                    XCTAssertEqual(inkVisible, frame >= expectedStart && frame < expectedEnd)
                    XCTAssertEqual(srtVisible, inkVisible, "外置SRT与实际电影字幕首末帧必须一致")
                }
            }
        }}
    }

    func testInvisibleCueAndInvalidTimingFailBeforeDirectRendererTouchesExistingOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-no-write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try Repository(root: root)
        let output = root.appendingPathComponent("existing-output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["video.mp4", "working.mp4", "captions.srt", "cover.png", "publication.txt"] {
            try Data(("prior-" + name).utf8).write(to: output.appendingPathComponent(name))
        }
        func outputBytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: output.path).map {
                ($0, try Data(contentsOf: output.appendingPathComponent($0)))
            })
        }
        let before = try outputBytes()
        var scene = Scene(title: "不可见字幕", body: "先调整时间", durationFrames: 90)
        scene.speed = 4
        scene.captions = [Caption(text: "这句不能省略。", startFrame: 1, endFrame: 2)]
        let invisible = revision(scene, aspect: .landscape)
        XCTAssertThrowsError(try MediaRenderer.subtitles(invisible))
        var invalid = invisible; invalid.scenes[0].speed = .nan
        for r in [invisible, invalid] {
            do {
                _ = try await MediaRenderer().render(revision: r, repository: repo, output: output)
                XCTFail("不可见字幕或非法速度不能开始制作")
            } catch {
                XCTAssertTrue(error is VideoError)
            }
            XCTAssertEqual(try outputBytes(), before, "直接SDK入口也不能先删除或写出旧四件")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
        }
    }

    func testMeasuredChineseAndEnglishLinesAreCenteredAndBottomAnchoredInBothAspects() throws {
        for aspect in Aspect.allCases {
            let rect = PaperPresentationPainter.Layout(aspect: aspect, mode: .explanation, showPrice: false, showAction: false).caption
            let short = try CinemaSubtitles.compose("小陈收回一枚。", in: rect)
            let sentence = String(repeating: "邻居想修路，", count: aspect == .portrait ? 4 : 8)
            let wrapped = try CinemaSubtitles.compose(sentence, in: rect)
            XCTAssertEqual(short.lines.count, 1)
            XCTAssertEqual(wrapped.lines.count, 2)
            XCTAssertEqual(short.origins[0].y, wrapped.origins[1].y, accuracy: 0.01)
            let last = CTLineGetStringRange(try XCTUnwrap(wrapped.lines.last))
            XCTAssertEqual(last.location + last.length, sentence.utf16.count, "不裁句尾或用省略号代替原文")
            for value in [short, wrapped, try CinemaSubtitles.compose("Three coins build the road.", in: rect)] {
                for bounds in value.bounds {
                    XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.01)
                    XCTAssertTrue(rect.contains(bounds))
                }
            }
        }
    }

    func testShapedAccentsAndDescendersUseTheirRealGlyphBounds() throws {
        let band = CGRect(x: 80, y: 26, width: 1120, height: 84)
        for text in ["ÉTÈ ÀNĪ gjpq", "中文 ÉTÈ\n第二行 gjpq", "他说：API 也能用。"] {
            let layout = try CinemaSubtitles.compose(text, in: band)
            for index in layout.lines.indices {
                let bounds = layout.bounds[index], origin = layout.origins[index]
                let actual = CTLineGetBoundsWithOptions(layout.lines[index], [.useGlyphPathBounds]).offsetBy(dx: origin.x, dy: origin.y)
                XCTAssertEqual(actual, bounds)
                XCTAssertEqual(bounds.midX, band.midX, accuracy: 0.01)
                XCTAssertTrue(band.contains(bounds.insetBy(dx: -1.04, dy: -1.04)))
            }
        }
        XCTAssertThrowsError(try CinemaSubtitles.compose("字幕", in: CGRect(x: CGFloat.infinity, y: 0, width: 600, height: 84)))
    }

    func testWhiteFillAndBlackOutlineStayReadableWithoutPaintingAFullWidthPanel() throws {
        let band = CGRect(x: 80, y: 26, width: 1120, height: 84)
        for background in [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.06, alpha: 1), CGColor(red: 0.7, green: 0.2, blue: 0.4, alpha: 1)] {
            let c = try context(color: background), before = try XCTUnwrap(c.makeImage())
            try CinemaSubtitles.draw("他没出钱，为什么也能走？", in: band, context: c)
            let image = try XCTUnwrap(c.makeImage()), bytes = Array(try region(image, band))
            var white = 0, black = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                if bytes[index] > 245 && bytes[index + 1] > 245 && bytes[index + 2] > 245 { white += 1 }
                if bytes[index] < 12 && bytes[index + 1] < 12 && bytes[index + 2] < 12 { black += 1 }
            }
            XCTAssertGreaterThan(white, 50); XCTAssertGreaterThan(black, 50)
            for x in [band.minX, band.maxX - 8] {
                XCTAssertEqual(try region(before, CGRect(x: x, y: band.minY, width: 8, height: band.height)), try region(image, CGRect(x: x, y: band.minY, width: 8, height: band.height)), "字幕保留带两侧透明，不能再铺整块正文面板")
            }
            for rect in [CGRect(x: 0, y: 0, width: 1280, height: 26), CGRect(x: 0, y: 110, width: 1280, height: 610)] {
                XCTAssertEqual(try region(before, rect), try region(image, rect), "黑描边和阴影也只能留在字幕安全带")
            }
        }
    }

    func testThirdLineMissingGlyphMissingFontAndOffCanvasAreRejectedWithoutShrinking() throws {
        let rect = CGRect(x: 56, y: 36, width: 608, height: 84)
        XCTAssertThrowsError(try CinemaSubtitles.compose(String(repeating: "完整字幕不能裁掉", count: 20), in: rect))
        XCTAssertThrowsError(try CinemaSubtitles.compose("第一行\n第二行\n第三行", in: rect))
        XCTAssertThrowsError(try CinemaSubtitles.compose("\u{10FFFF}", in: rect))
        XCTAssertThrowsError(try CinemaSubtitles.compose("完整字幕", in: rect, fontName: "NoSuchFont-FF1480"))
        let c = try context()
        XCTAssertThrowsError(try CinemaSubtitles.draw("字幕", in: CGRect(x: -1, y: 26, width: 600, height: 84), context: c))
        XCTAssertEqual(CinemaSubtitles.fontSize, 26)
        XCTAssertEqual(try CinemaSubtitles.compose(" \n ", in: rect).lines.count, 0)
    }

    func testPaperInkChangesBodyButCannotRecolorCinemaCaptions() throws {
        for aspect in Aspect.allCases {
            var scene = Scene(title: "谁少出了一枚？", body: "还差一枚", durationFrames: 60)
            scene.paperPresentation = PaperPresentation()
            scene.captions = [Caption(text: "这时，小陈补上一枚，路就能修好。", startFrame: 0, endFrame: 60, confirmed: false)]
            var changed = scene; changed.paperPresentation?.inkColor = "C21B51"
            let first = try ScenePainter.image(revision: revision(scene, aspect: aspect), frame: 0)
            let second = try ScenePainter.image(revision: revision(changed, aspect: aspect), frame: 0)
            let layout = PaperPresentationPainter.Layout(aspect: aspect, mode: .explanation, showPrice: false, showAction: false)
            XCTAssertEqual(try region(first, layout.caption), try region(second, layout.caption))
            XCTAssertNotEqual(try region(first, layout.body), try region(second, layout.body))
            XCTAssertLessThan(CinemaSubtitles.fontSize, layout.bodySize)
        }
    }

    func testBothPainterEntrypointsKeepSourceFrameCaptionWindowsAndDoNotMoveContent() throws {
        for aspect in Aspect.allCases { for paper in [false, true] {
            var scene = Scene(title: "四个邻居修路", body: "凑够三枚开工", durationFrames: 90)
            scene.speed = 2
            if paper { scene.paperPresentation = PaperPresentation() }
            scene.captions = [Caption(text: "小陈把自己那枚收了回去。", startFrame: 30, endFrame: 60, confirmed: false)]
            let r = revision(scene, aspect: aspect)
            var without = r; without.scenes[0].captions = []
            let band = paper ? PaperPresentationPainter.Layout(aspect: aspect, mode: .explanation, showPrice: false, showAction: false).caption : ScenePainter.OverlayLayout(width: CGFloat(aspect.width), height: CGFloat(aspect.height), showPrice: false, separateBody: false).captionText
            for frame in [14, 15, 29, 30] {
                let actual = try ScenePainter.image(revision: r, frame: frame), empty = try ScenePainter.image(revision: without, frame: frame)
                if frame == 15 || frame == 29 { XCTAssertNotEqual(try region(actual, band), try region(empty, band)) }
                else { XCTAssertEqual(try region(actual, band), try region(empty, band)) }
                XCTAssertEqual(try region(actual, CGRect(x: 0, y: band.maxY, width: CGFloat(aspect.width), height: CGFloat(aspect.height) - band.maxY)), try region(empty, CGRect(x: 0, y: band.maxY, width: CGFloat(aspect.width), height: CGFloat(aspect.height) - band.maxY)))
            }
        }}
    }

    func testNamedTextAndDataBoundsCannotCoverActiveCaptionsWhileBackgroundsAreAllowed() throws {
        for aspect in Aspect.allCases {
            let band = PaperPresentationPainter.Layout(aspect: aspect, mode: .explanation, showPrice: false, showAction: false).caption
            for kind in [SceneLayer.Kind.text, .chart, .code] {
                var label = SceneLayer(kind: kind, text: "小陈", endFrame: 30)
                label.startFrame = 10
                label.x = Double(band.midX) / Double(aspect.width)
                label.y = 1 - Double(band.midY) / Double(aspect.height)
                label.width = 0.2; label.height = 0.08
                var scene = Scene(title: "场景", body: "关键动作", durationFrames: 60); scene.layers = [label]
                XCTAssertNoThrow(try CinemaSubtitles.validateClearance(scene: scene, sourceFrame: 0, aspect: aspect, rect: band))
                XCTAssertThrowsError(try CinemaSubtitles.validateClearance(scene: scene, sourceFrame: 15, aspect: aspect, rect: band))
                label.y = 0.4; scene.layers = [label]
                XCTAssertNoThrow(try CinemaSubtitles.validateClearance(scene: scene, sourceFrame: 15, aspect: aspect, rect: band))
            }
            var background = SceneLayer(kind: .image, assetID: "background", endFrame: 60)
            background.width = 1; background.height = 1
            var scene = Scene(title: "场景", body: "关键动作", durationFrames: 60); scene.layers = [background]
            XCTAssertNoThrow(try CinemaSubtitles.validateClearance(scene: scene, sourceFrame: 15, aspect: aspect, rect: band), "不能把整幅背景位图误判为人物姓名")
        }
    }

    func testInvisibleEntranceIsAllowedUntilTextActuallyBecomesVisible() throws {
        let aspect = Aspect.landscape
        let band = PaperPresentationPainter.Layout(aspect: aspect, mode: .explanation, showPrice: false, showAction: false).caption
        for kind in LayerEntrance.Kind.allCases {
            var label = SceneLayer(kind: .text, text: "小陈", endFrame: 60)
            label.x = Double(band.midX) / Double(aspect.width)
            label.y = 1 - Double(band.midY) / Double(aspect.height)
            label.width = 0.2; label.height = 0.08
            label.entrance = LayerEntrance(kind: kind, startFrame: 0, endFrame: 30)
            var scene = Scene(title: "场景", body: "关键动作", durationFrames: 60)
            scene.layers = [label]
            XCTAssertNoThrow(try CinemaSubtitles.validateClearance(scene: scene, sourceFrame: 0, aspect: aspect, rect: band))
            XCTAssertThrowsError(try CinemaSubtitles.validateClearance(scene: scene, sourceFrame: 15, aspect: aspect, rect: band))
            label.opacity = 0; scene.layers = [label]
            XCTAssertNoThrow(try CinemaSubtitles.validateClearance(scene: scene, sourceFrame: 15, aspect: aspect, rect: band))
        }
    }

    func testHeldPlainTextUsesTheSameClearanceFrameWhileCaptionsEndNaturally() throws {
        for aspect in Aspect.allCases {
            let band=PaperPresentationPainter.Layout(aspect:aspect,mode:.explanation,showPrice:false,showAction:false).caption
            var label=SceneLayer(kind:.text,text:"结果",endFrame:90)
            label.x=Double(band.midX)/Double(aspect.width);label.y=1-Double(band.midY)/Double(aspect.height)
            label.width=0.2;label.height=0.08
            var scene=Scene(title:"保留最后画面",body:"等观众看清结果",durationFrames:90)
            scene.speed=2;scene.pauseFrames=15;scene.layers=[label]
            XCTAssertThrowsError(try CinemaSubtitles.validateClearance(scene:scene,sourceFrame:118,aspect:aspect,rect:band),"净空检查必须看见实际持画的普通文字")
            scene.layers?[0].endFrame=60
            XCTAssertNoThrow(try CinemaSubtitles.validateClearance(scene:scene,sourceFrame:118,aspect:aspect,rect:band),"提前结束的提示不复活")
            scene.layers?[0].endFrame=90;scene.layers?[0].y=0.5
            scene.captions=[Caption(text:"路修好了。",startFrame:0,endFrame:90)]
            for paper in [false,true] {
                scene.paperPresentation=paper ? PaperPresentation():nil
                let r=revision(scene,aspect:aspect)
                var without=r;without.scenes[0].captions=[]
                let captionBand=paper ? band:ScenePainter.OverlayLayout(width:CGFloat(aspect.width),height:CGFloat(aspect.height),showPrice:false,separateBody:false).captionText
                XCTAssertEqual(try region(ScenePainter.image(revision:r,frame:59),captionBand),try region(ScenePainter.image(revision:without,frame:59),captionBand),"画面持留不能把电影字幕延长")
                XCTAssertEqual(try srtCues(MediaRenderer.subtitles(r)).last?.end,1500)
                try assertSRTMatchesPainterFramePTS(r)
            }
        }
    }
}
