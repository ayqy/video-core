import Foundation
import CoreGraphics
import CoreText
import VideoCore

/// Burned-in sentence captions share one style across ordinary and paper shots.
/// Authored content/time ranges remain unchanged; overflow requires an edit.
enum CinemaSubtitles {
    static let styleVersion = "cinema-subtitles-2"
    static let styleIdentity = "cinema-subtitles-2-white-fill-after-outline-two-lines"
    static let fontSize: CGFloat = 26
    private static let strokePercent: CGFloat = 8
    private static let shadowBlur: CGFloat = 2
    private static let shadowDrop: CGFloat = 1.5
    struct Composition {
        let lines: [CTLine]
        let origins: [CGPoint]
        let bounds: [CGRect]
    }

    /// Text and data have explicit semantic bounds in the current IR. A bitmap
    /// may be a full-frame background, so its content is left to authored layout
    /// and the normal final review rather than guessed from its outer rectangle.
    static func validateClearance(scene: Scene, sourceFrame: Int, aspect: Aspect, rect: CGRect) throws {
        let frame = LayerRules.renderSourceFrame(scene: scene, sourceFrame: sourceFrame)
        for layer in scene.layers ?? [] where layer.kind == .text || layer.kind == .chart || layer.kind == .code {
            guard layer.startFrame <= frame, layer.endFrame > frame else { continue }
            let progress = try layer.entrance?.progress(at: frame) ?? 1
            // Match LayerPainter's actual visibility. An element whose entrance
            // has not started cannot obscure the subtitle at this frame.
            guard layer.opacity > 0,
                  layer.entrance?.kind != .fade || progress > 0,
                  layer.entrance?.kind != .revealLeft || progress > 0 else { continue }
            let layout = layer.layout(at: frame)
            let width = Double(aspect.width), height = Double(aspect.height)
            let bounds = CGRect(x: (layout.x - layer.width * layout.scale / 2) * width,
                                y: (1 - layout.y - layer.height * layout.scale / 2) * height,
                                width: layer.width * layout.scale * width,
                                height: layer.height * layout.scale * height)
            guard !bounds.intersects(rect) else {
                throw VideoError.review("画面文字或数值与电影字幕安全区重叠，请移动图层或调整关键帧")
            }
        }
    }

    static func compose(_ value: String, in rect: CGRect, fontName: String = "PingFangSC-Medium") throws -> Composition {
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 16, rect.height > 16 else {
            throw VideoError.review("字幕没有可用的画面安全区，请调整布局")
        }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Composition(lines: [], origins: [], bounds: [])
        }
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        guard (CTFontCopyPostScriptName(font) as String) == fontName else {
            throw VideoError.unavailable("指定字体未安装或名称不准确，请改用可用中文系统字体")
        }
        // Extra room below the glyphs contains the black outline and shadow.
        let available = CGRect(x: rect.minX + 8, y: rect.minY + 6, width: rect.width - 16, height: rect.height - 10)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            .init(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let string = NSAttributedString(string: value, attributes: attributes)
        guard string.length <= 2048 else { throw VideoError.review("字幕超过两行安全区，请按实际口播拆分字幕句段") }
        let setter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: available, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty, lines.count <= 2,
              CTFrameGetVisibleStringRange(frame).length == string.length,
              TextGlyphInspection.hasSupportedGlyphs(frame) else {
            throw VideoError.review("字幕超过两行安全区或含无法绘制的字形，请按实际口播拆分句段或更换字体")
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = ceil(ascent + descent + CTFontGetLeading(font))
        var origins: [CGPoint] = [], bounds: [CGRect] = []
        for (index, line) in lines.enumerated() {
            // Typographic advances alone do not contain accents, italic
            // overhangs, or fallback glyphs. Measure the shaped glyph paths.
            let glyphs = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard !glyphs.isNull, !glyphs.isInfinite,
                  glyphs.minX.isFinite, glyphs.minY.isFinite,
                  glyphs.width.isFinite, glyphs.height.isFinite else {
                throw VideoError.review("字幕字形无法完整量测，请更换字体或拆分句段")
            }
            let origin = CGPoint(x: available.midX - glyphs.midX,
                                 y: available.minY + descent + lineHeight * CGFloat(lines.count - index - 1))
            let bound = glyphs.offsetBy(dx: origin.x, dy: origin.y)
            // Stroke widths are a percentage of the text point size. Include
            // the outline and shadow around the real glyphs before drawing;
            // clipping is a final containment guard, not overflow handling.
            let outline = fontSize * strokePercent / 100 / 2
            let ink = bound.insetBy(dx: -outline, dy: -outline)
            let shadow = ink.offsetBy(dx: 0, dy: -shadowDrop).insetBy(dx: -shadowBlur * 2, dy: -shadowBlur * 2)
            guard rect.contains(ink.union(shadow)) else {
                throw VideoError.review("字幕超过两行安全区，请按实际口播拆分字幕句段")
            }
            origins.append(origin); bounds.append(bound)
        }
        return Composition(lines: lines, origins: origins, bounds: bounds)
    }

    static func draw(_ value: String, in rect: CGRect, context c: CGContext, fontName: String = "PingFangSC-Medium") throws {
        guard CGRect(x: 0, y: 0, width: CGFloat(c.width), height: CGFloat(c.height)).contains(rect) else {
            throw VideoError.review("字幕安全区越出实际画布，请调整布局")
        }
        let composition = try compose(value, in: rect, fontName: fontName)
        c.saveGState(); defer { c.restoreGState() }
        c.clip(to: rect)
        c.textMatrix = .identity
        c.setStrokeColor(CGColor(gray: 0, alpha: 1))
        c.setLineWidth(fontSize * strokePercent / 100)
        c.setLineJoin(.round)
        c.setShadow(offset: CGSize(width: 0, height: -shadowDrop), blur: shadowBlur, color: CGColor(gray: 0, alpha: 0.8))
        // A combined fill/stroke pass can cover the entire white stem of a
        // small Chinese glyph. Paint the outline first, then restore its solid
        // white interior with the very same shaped lines and positions.
        c.setTextDrawingMode(.stroke)
        for (line, origin) in zip(composition.lines, composition.origins) {
            c.textPosition = origin
            CTLineDraw(line, c)
        }
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.setTextDrawingMode(.fill)
        for (line, origin) in zip(composition.lines, composition.origins) {
            c.textPosition = origin
            CTLineDraw(line, c)
        }
    }
}
