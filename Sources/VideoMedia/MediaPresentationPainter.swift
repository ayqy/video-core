import CoreGraphics
import VideoCore

/// Explicit ordinary source pixels, without author/editor metadata around them.
/// Cropping is still an actual source crop; this never builds missing media.
enum MediaPresentationPainter {
    struct Layout {
        let visual: CGRect
        let caption: CGRect

        init(aspect: Aspect) {
            let width = CGFloat(aspect.width), height = CGFloat(aspect.height)
            caption = ScenePainter.FullFrameLayout(width: width, height: height).caption
            let margin: CGFloat = 24
            let bottom = max(margin, caption.maxY + margin)
            visual = CGRect(x: margin, y: bottom, width: width - margin * 2,
                            height: height - margin - bottom)
        }
    }

    static func draw(revision: Revision, scene: Scene, sourceFrame: Int,
                     media: CGImage?, layerImages: [String: CGImage], context c: CGContext) throws {
        guard let presentation = scene.mediaPresentation,
              scene.kind == .image || scene.kind == .video,
              let assetID = scene.assetID, !assetID.isEmpty else {
            throw VideoError.invalid("纯媒体呈现只能绑定实际图片或录屏源素材")
        }
        try presentation.validate()
        guard let media, media.width > 0, media.height > 0 else {
            throw VideoError.notFound("纯媒体呈现缺少已加载的实际源画面")
        }
        let source = try MediaFramingRenderer.crop(media, framing: scene.mediaFraming)
        let layout = Layout(aspect: revision.aspect)
        let authored = scene.layout(at: sourceFrame)
        guard authored.x.isFinite, authored.y.isFinite, authored.scale.isFinite,
              (0...1).contains(authored.x), (0...1).contains(authored.y),
              (0.1...4).contains(authored.scale) else {
            throw VideoError.invalid("纯媒体呈现的位置或缩放无效")
        }
        let width = CGFloat(revision.aspect.width), height = CGFloat(revision.aspect.height)
        c.setFillColor(color(presentation.backgroundColor))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Match the existing Scene.layout convention. The stable content window
        // clips explicit zoom/translation without ever painting into captions.
        let base = layout.visual
        let transformed = CGRect(
            x: base.midX + CGFloat(authored.x - 0.5) * base.width - base.width * CGFloat(authored.scale) / 2,
            y: base.midY + CGFloat(authored.y - 0.5) * base.height - base.height * CGFloat(authored.scale) / 2,
            width: base.width * CGFloat(authored.scale), height: base.height * CGFloat(authored.scale))
        let ratio = min(transformed.width / CGFloat(source.width), transformed.height / CGFloat(source.height))
        let fitted = CGRect(x: transformed.midX - CGFloat(source.width) * ratio / 2,
                            y: transformed.midY - CGFloat(source.height) * ratio / 2,
                            width: CGFloat(source.width) * ratio, height: CGFloat(source.height) * ratio)
        c.saveGState()
        c.clip(to: base)
        c.draw(source, in: fitted)
        c.restoreGState()

        let caption = scene.captions.first { $0.startFrame <= sourceFrame && sourceFrame < $0.endFrame }
        let fontName = scene.fontName ?? "PingFangSC-Medium"
        if caption != nil {
            try CinemaSubtitles.validateClearance(scene: scene, sourceFrame: sourceFrame,
                                                  aspect: revision.aspect, rect: layout.caption)
        }
        try LayerPainter.draw(scene: scene, sourceFrame: sourceFrame, aspect: revision.aspect,
                              images: layerImages, context: c, fontName: fontName)
        if let caption {
            try CinemaSubtitles.draw(caption.text, in: layout.caption, context: c, fontName: fontName)
        }
    }

    private static func color(_ hex: String) -> CGColor {
        // New profile hex colors are explicitly sRGB, like the output canvas.
        // An untagged DeviceRGB color would be color-managed to different RGB
        // bytes even though the caller supplied this exact hexadecimal value.
        let value = UInt32(hex, radix: 16)!
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
            CGFloat((value >> 16) & 255) / 255,
            CGFloat((value >> 8) & 255) / 255,
            CGFloat(value & 255) / 255, 1
        ])!
    }
}
