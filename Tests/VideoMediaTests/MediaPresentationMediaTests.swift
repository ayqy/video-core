import XCTest
import Foundation
import CoreGraphics
import VideoCore
@testable import VideoMedia

/// Declared synthetic corner colors exercise real bitmap composition only.
/// They are not recordings, readability, human performance or film approval.
final class MediaPresentationMediaTests: XCTestCase {
    private struct Plane {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width; height = image.height
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            bytes = Array(UnsafeBufferPointer(start: pointer, count: width * height * 4))
        }

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let start = (y * width + x) * 4
            return Array(bytes[start..<(start + 4)])
        }

        func markers() -> (count: Int, rect: CGRect) {
            var count = 0, left = width, right = -1, top = height, bottom = -1
            for y in 0..<height {
                for x in 0..<width {
                    let start = (y * width + x) * 4
                    let r = bytes[start], g = bytes[start + 1], b = bytes[start + 2]
                    let marker = (r > 240 && g < 15 && b < 15) || (g > 240 && r < 15 && b < 15)
                        || (b > 240 && r < 15 && g < 15) || (r > 240 && g > 240 && b < 15)
                    if marker {
                        count += 1; left = min(left, x); right = max(right, x)
                        top = min(top, y); bottom = max(bottom, y)
                    }
                }
            }
            guard count > 0 else { return (0, .null) }
            return (count, CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
        }
    }

    private func sRGB(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
    }

    /// Independently color-manage a reference into the same explicit output
    /// space. Existing ordinary layers retain their DeviceRGB color behavior.
    private func referencePixel(_ color: CGColor) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        return try Plane(image).pixel(0, 0)
    }

    private func source(portrait: Bool = false) throws -> CGImage {
        let width = portrait ? 128 : 256, height = portrait ? 256 : 128
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (rect, color) in [
            (CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2), sRGB(1, 0, 0)),
            (CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2), sRGB(0, 1, 0)),
            (CGRect(x: 0, y: 0, width: width / 2, height: height / 2), sRGB(0, 0, 1)),
            (CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2), sRGB(1, 1, 0))
        ] {
            context.setFillColor(color); context.fill(rect)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func scene(kind: SceneKind = .video) -> Scene {
        var value = Scene(kind: kind, title: "编辑标题", body: "编辑正文", durationFrames: 60)
        value.assetID = "declared-synthetic-source"
        value.mediaPresentation = MediaPresentation()
        return value
    }

    private func revision(_ scene: Scene, _ aspect: Aspect = .landscape) -> Revision {
        Revision(contentContext: ContentContext(workspaceID: "test", name: "合成像素规则"),
                 aspect: aspect, scenes: [scene], cta: "不应画出的CTA")
    }

    private func hash(_ image: CGImage) throws -> String { Codec.hash(try ScenePainter.png(image)) }

    private func region(_ image: CGImage, _ canvas: CGRect) throws -> CGImage {
        try XCTUnwrap(image.cropping(to: CGRect(x: canvas.minX, y: CGFloat(image.height) - canvas.maxY,
                                               width: canvas.width, height: canvas.height)))
    }

    func testActualCornerPixelsGrowInBothAspectsAndMetadataNeverPaints() throws {
        for aspect in Aspect.allCases {
            let source = try source(portrait: aspect == .portrait)
            let expected = try Plane(source)
            let cornerPoints = [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)]
            let sourceColors = cornerPoints.map { expected.pixel(Int(Double(expected.width) * $0.0), Int(Double(expected.height) * $0.1)) }
            let primaryColors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
            XCTAssertEqual(Set(sourceColors.map { Data($0) }), Set(primaryColors.map { Data($0) }),
                           "合成源必须真实包含四种精确sRGB角标，不能只检测到半图")
            let value = scene()
            let image = try ScenePainter.image(revision: revision(value, aspect), frame: 0, media: source)
            let pixels = try Plane(image), marked = pixels.markers()
            XCTAssertEqual(image.width, aspect.width); XCTAssertEqual(image.height, aspect.height)
            XCTAssertGreaterThan(marked.count, aspect.width * aspect.height / 2,
                                 "匹配画幅的实际源应占画布过半，不能仍困在旧小卡片中")
            for (x, y) in cornerPoints {
                XCTAssertEqual(pixels.pixel(Int(marked.rect.minX + marked.rect.width * x), Int(marked.rect.minY + marked.rect.height * y)),
                               expected.pixel(Int(Double(expected.width) * x), Int(Double(expected.height) * y)))
            }
            var legacy = value; legacy.mediaPresentation = nil; legacy.mediaFraming = MediaFraming()
            let old = try Plane(ScenePainter.image(revision: revision(legacy, aspect), frame: 0, media: source)).markers()
            XCTAssertGreaterThan(marked.count, old.count * 5 / 2)
            var metadata = value
            metadata.title = "标题\u{10FFFF}"; metadata.body = "正文\u{10FFFF}"; metadata.showPrice = true
            var changed = revision(metadata, aspect); changed.cta = "CTA\u{10FFFF}"; changed.purpose = .brand
            XCTAssertEqual(try hash(image), try hash(ScenePainter.image(revision: changed, frame: 29, media: source)))
            var second = metadata; second.id = Codec.id(); changed.scenes.append(second)
            XCTAssertEqual(try hash(image), try hash(ScenePainter.image(revision: changed, frame: 60, media: source)),
                           "镜头序号、全片时间、目的和编辑文案不得进入纯媒体画面")
            var tinted = value; tinted.mediaPresentation = MediaPresentation(backgroundColor: "E8F0F8")
            let background = try Plane(ScenePainter.image(revision: revision(tinted, aspect), frame: 0, media: source))
            XCTAssertEqual(background.pixel(2, 2), [232, 240, 248, 255])
        }
    }

    func testCaptionBandIsIndependentAndExplicitZoomCannotEnterIt() throws {
        for aspect in Aspect.allCases {
            let source = try source(portrait: aspect == .portrait)
            var value = scene()
            value.captions = [Caption(text: "真实电影字幕", startFrame: 10, endFrame: 20, confirmed: false)]
            let r = revision(value, aspect)
            let before = try ScenePainter.image(revision: r, frame: 0, media: source)
            let active = try ScenePainter.image(revision: r, frame: 15, media: source)
            let after = try ScenePainter.image(revision: r, frame: 25, media: source)
            let band = ScenePainter.FullFrameLayout(width: CGFloat(aspect.width), height: CGFloat(aspect.height)).caption
            let content = CGRect(x: 0, y: band.maxY + 24, width: CGFloat(aspect.width), height: CGFloat(aspect.height) - band.maxY - 24)
            XCTAssertEqual(try hash(region(before, content)), try hash(region(active, content)))
            XCTAssertEqual(try hash(before), try hash(after))
            XCTAssertNotEqual(try hash(region(before, band)), try hash(region(active, band)))
            value.captions = []; value.scale = 4; value.y = 0
            let zoomed = try ScenePainter.image(revision: revision(value, aspect), frame: 0, media: source)
            let reserved = try Plane(region(zoomed, CGRect(x: 0, y: 0, width: CGFloat(aspect.width), height: band.maxY + 24)))
            XCTAssertEqual(reserved.markers().count, 0, "显式放大/移动的源像素不得越过固定字幕净空")
            XCTAssertTrue(stride(from: 0, to: reserved.bytes.count, by: 4).allSatisfy {
                reserved.bytes[$0] == 255 && reserved.bytes[$0 + 1] == 255 && reserved.bytes[$0 + 2] == 255
            })
        }
    }

    func testActualSourceCropPrecedesContainAndMissingSourceNeverFallsBack() throws {
        let source = try source()
        var selected = scene(kind: .image)
        selected.mediaFraming = MediaFraming(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let cropped = try XCTUnwrap(source.cropping(to: CGRect(x: 128, y: 0, width: 128, height: 64)))
        var direct = selected; direct.mediaFraming = nil
        for aspect in Aspect.allCases {
            XCTAssertEqual(try hash(ScenePainter.image(revision: revision(selected, aspect), frame: 0, media: source)),
                           try hash(ScenePainter.image(revision: revision(direct, aspect), frame: 0, media: cropped)))
        }
        XCTAssertThrowsError(try ScenePainter.image(revision: revision(selected), frame: 0))
        selected.assetID = nil
        XCTAssertThrowsError(try ScenePainter.image(revision: revision(selected), frame: 0, media: source))
        selected = scene(kind: .explanation)
        XCTAssertThrowsError(try ScenePainter.image(revision: revision(selected), frame: 0, media: source))
        selected = scene(); selected.mediaFraming = MediaFraming(x: 0.8, width: 0.5)
        XCTAssertThrowsError(try ScenePainter.image(revision: revision(selected), frame: 0, media: source))
        selected = scene(); selected.mediaPresentation?.version = 2
        XCTAssertThrowsError(try ScenePainter.image(revision: revision(selected), frame: 0, media: source))
    }

    func testSceneTransformUsesSourceClockAndPauseHoldsOnlyTheVisual() throws {
        let source = try source()
        var value = scene(); value.speed = 2; value.pauseFrames = 20
        value.sourceStartFrame = 100; value.sourceEndFrame = 160
        value.keyframes = [Keyframe(frame: 0, x: 0.3, y: 0.5, scale: 0.5), Keyframe(frame: 30, x: 0.7, y: 0.5, scale: 0.5)]
        value.captions = [Caption(text: "只在源帧三十之前", startFrame: 0, endFrame: 30, confirmed: false)]
        var fixed = value; fixed.keyframes = []; fixed.x = 0.7; fixed.scale = 0.5; fixed.captions = []
        let expected = try ScenePainter.image(revision: revision(fixed), frame: 0, media: source)
        let boundary = try ScenePainter.image(revision: revision(value), frame: 15, media: source)
        XCTAssertEqual(try hash(boundary), try hash(expected), "15帧的2倍播放应使用源帧30的位置与字幕结束边界")
        XCTAssertEqual(try hash(ScenePainter.image(revision: revision(value), frame: 35, media: source)), try hash(expected))
        let band = ScenePainter.FullFrameLayout(width: 1280, height: 720).caption
        let active = try ScenePainter.image(revision: revision(value), frame: 14, media: source)
        XCTAssertNotEqual(try hash(region(active, band)), try hash(region(expected, band)))
        var first = value; first.captions = []
        XCTAssertNotEqual(try hash(ScenePainter.image(revision: revision(first), frame: 0, media: source)), try hash(expected),
                          "显式位置/缩放不能被满幅模式忽略")
    }

    func testOrdinaryLayersOverlaySourceAndKeepSubtitleClearance() throws {
        let source = try source()
        var value = scene()
        var layer = SceneLayer(kind: .rectangle, endFrame: 60)
        layer.color = "FF00FF"; layer.x = 0.5; layer.y = 0.4; layer.width = 0.2; layer.height = 0.1
        value.layers = [layer]
        let image = try ScenePainter.image(revision: revision(value), frame: 15, media: source)
        let center = try Plane(region(image, CGRect(x: 640, y: 432, width: 1, height: 1)))
        XCTAssertEqual(center.pixel(0, 0), try referencePixel(CGColor(red: 1, green: 0, blue: 1, alpha: 1)))
        value.captions = [Caption(text: "字幕", startFrame: 0, endFrame: 60, confirmed: false)]
        let band = ScenePainter.FullFrameLayout(width: 1280, height: 720).caption
        var label = SceneLayer(kind: .text, text: "重叠标签", endFrame: 60)
        label.x = 0.5; label.y = 1 - Double(band.midY) / 720; label.width = 0.4; label.height = 0.08
        value.layers = [label]
        XCTAssertThrowsError(try ScenePainter.image(revision: revision(value), frame: 15, media: source))
    }

    func testLegacyNilWireKeepsFrameHashAndExistingFramingWindow() throws {
        for aspect in Aspect.allCases {
            let source = try source(portrait: aspect == .portrait)
            var value = scene(); value.mediaPresentation = nil; value.mediaFraming = MediaFraming()
            let original = try ScenePainter.image(revision: revision(value, aspect), frame: 0, media: source)
            var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Codec.data(value)) as? [String: Any])
            XCTAssertNil(old["mediaPresentation"])
            let absent = try JSONDecoder().decode(Scene.self, from: JSONSerialization.data(withJSONObject: old))
            old["mediaPresentation"] = NSNull()
            let null = try JSONDecoder().decode(Scene.self, from: JSONSerialization.data(withJSONObject: old))
            for decoded in [absent, null] {
                XCTAssertNil(decoded.mediaPresentation)
                XCTAssertEqual(try hash(original), try hash(ScenePainter.image(revision: revision(decoded, aspect), frame: 0, media: source)))
            }
            let measured = try Plane(original).markers()
            XCTAssertEqual(measured.rect.height, aspect == .landscape ? 306 : 542, accuracy: 2,
                           "旧nil媒体仍保原取景卡片，不得被新模式暗改")
            let unchangedCrop = try MediaFramingRenderer.crop(source, framing: MediaFraming())
            XCTAssertEqual(try hash(source), try hash(unchangedCrop))
        }
    }
}
