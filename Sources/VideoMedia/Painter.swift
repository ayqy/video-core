import Foundation
import CoreGraphics
import CoreText
import ImageIO
import VideoCore

public enum ScenePainter {
    /// Reserve distinct areas for the snapshot price, captions, final CTA and
    /// playback footer. CoreText uses bottom-left canvas coordinates here.
    struct OverlayLayout {
        let price:CGRect
        let captionBackground:CGRect
        let captionText:CGRect
        let cta:CGRect
        let footer:CGRect
        let mediaBody:CGRect
        let visual:CGRect
        init(width:CGFloat,height:CGFloat,showPrice:Bool,separateBody:Bool) {
            let portrait=height>width,margin:CGFloat=portrait ? 64:80
            let contentWidth=width-margin*2
            footer=CGRect(x:margin,y:24,width:contentWidth,height:26)
            if portrait {
                cta=CGRect(x:margin,y:62,width:contentWidth,height:48)
                captionBackground=CGRect(x:margin,y:122,width:contentWidth,height:66)
                price=CGRect(x:margin,y:200,width:contentWidth,height:58)
                mediaBody=CGRect(x:margin,y:270,width:contentWidth,height:128)
                visual=CGRect(x:margin,y:410,width:contentWidth,height:560)
            } else {
                // The wide canvas has room for price and CTA side by side.
                let priceWidth:CGFloat=240,gap:CGFloat=20
                price=CGRect(x:margin,y:62,width:priceWidth,height:58)
                cta=CGRect(x:margin+(showPrice ? priceWidth+gap:0),y:62,width:contentWidth-(showPrice ? priceWidth+gap:0),height:58)
                captionBackground=CGRect(x:margin,y:132,width:contentWidth,height:66)
                mediaBody=CGRect(x:margin,y:210,width:contentWidth,height:72)
                let bottom:CGFloat=separateBody ? 294:210
                visual=CGRect(x:margin,y:bottom,width:contentWidth,height:504-bottom)
            }
            captionText=captionBackground.insetBy(dx:12,dy:8)
        }
    }
    public static func image(revision: Revision, frame: Int, media: CGImage? = nil, layerImages: [String:CGImage] = [:], resources:RenderResources = .empty, modules: RenderModuleRegistry? = nil, invocation: RenderInvocation? = nil) throws -> CGImage {
        let w = revision.aspect.width, h = revision.aspect.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VideoError.unavailable("无法创建画布") }
        try draw(revision: revision, frame: frame, in: context, media: media, layerImages:layerImages, resources:resources, modules:modules, invocation:invocation)
        guard let result = context.makeImage() else { throw VideoError.unavailable("无法生成画面") }; return result
    }
    public static func scene(revision: Revision, frame: Int) -> (Scene, Int, Int) {
        var cursor = 0
        for (i,s) in revision.scenes.enumerated() { if frame < cursor+s.timelineFrames { return (s, max(0,frame-cursor), i) }; cursor += s.timelineFrames }
        return (revision.scenes.last!, max(0, revision.scenes.last!.timelineFrames-1), revision.scenes.count-1)
    }
    public static func draw(revision: Revision, frame: Int, in c: CGContext, media: CGImage? = nil, layerImages: [String:CGImage] = [:], resources:RenderResources = .empty, modules: RenderModuleRegistry? = nil, invocation: RenderInvocation? = nil) throws {
        try invocation?.verify(revision:revision)
        guard !revision.scenes.isEmpty else { throw VideoError.invalid("没有场景") }
        let w = CGFloat(revision.aspect.width), h = CGFloat(revision.aspect.height), portrait = h > w
        let (s, local, index) = scene(revision: revision, frame: frame)
        let mapped = s.renderSourceFrame(atTimelineFrame: local)
        c.saveGState(); defer { c.restoreGState() }
        c.setFillColor(color("0B1020")); c.fill(CGRect(x: 0,y: 0,width: w,height: h))
        c.setFillColor(color(s.color, alpha: 0.12)); c.fillEllipse(in: CGRect(x: w*0.58,y: h*0.45,width: w*0.7,height: w*0.7))
        let margin: CGFloat = portrait ? 64 : 80
        text("VIDEO  /  \(revision.purpose.rawValue)", in: CGRect(x: margin,y: h-84,width: w-margin*2,height: 30), size: 21, color: "A5B4FC", context: c,fontName:s.fontName ?? "PingFangSC-Medium")
        try checkedText(s.title, in: CGRect(x: margin,y: h-(portrait ? 240:200),width: w-margin*2,height: portrait ? 125:100), size: portrait ? 45:48, color: "FFFFFF", context: c,fontName:s.fontName ?? "PingFangSC-Medium")
        let separateBody=s.kind == .simulation || s.kind == .cartoon || media != nil
        let overlay=OverlayLayout(width:w,height:h,showPrice:s.showPrice,separateBody:separateBody)
        let base=overlay.visual
        let layout=s.layout(at:mapped)
        let visual=CGRect(x:base.midX+CGFloat(layout.x-0.5)*base.width-base.width*CGFloat(layout.scale)/2,y:base.midY+CGFloat(layout.y-0.5)*base.height-base.height*CGFloat(layout.scale)/2,width:base.width*CGFloat(layout.scale),height:base.height*CGFloat(layout.scale))
        if let media { c.saveGState(); c.addPath(CGPath(roundedRect: visual, cornerWidth: 28, cornerHeight: 28, transform: nil)); c.clip(); let ratio = min(visual.width/CGFloat(media.width),visual.height/CGFloat(media.height)); let rect = CGRect(x: visual.midX-CGFloat(media.width)*ratio/2,y: visual.midY-CGFloat(media.height)*ratio/2,width: CGFloat(media.width)*ratio,height: CGFloat(media.height)*ratio); c.draw(media,in: rect); c.restoreGState() }
        else if RenderModuleRegistry.capability(for:s.kind) != nil {
            guard let modules else { throw VideoError.unavailable("此镜头需要独立高级模块，请核对已安装模块与权益；免费图文、图片和录屏继续可用") }
            try modules.draw(scene:s,localFrame:mapped,fps:revision.fps,rect:visual,context:c,resources:resources,invocation:invocation)
        } else if media == nil {
            c.setFillColor(color(s.color,alpha:0.14)); c.addPath(CGPath(roundedRect:visual,cornerWidth:28,cornerHeight:28,transform:nil)); c.fillPath()
            try checkedText(s.body,in:visual.insetBy(dx:28,dy:26),size:portrait ? 32:34,color:"E2E8F0",context:c,fontName:s.fontName ?? "PingFangSC-Medium")
        }
        if separateBody { try checkedText(s.body,in:overlay.mediaBody,size:portrait ? 26:25,color:"E2E8F0",context:c,fontName:s.fontName ?? "PingFangSC-Medium") }
        try LayerPainter.draw(scene:s,sourceFrame:mapped,aspect:revision.aspect,images:layerImages,context:c,fontName:s.fontName ?? "PingFangSC-Medium")
        if s.showPrice { guard let product=revision.product else{throw VideoError.review("没有关联产品事实，不能绘制产品价格")};let price = try product.price(at:revision.createdAt); try checkedText(price.money.display,in:overlay.price,size:40,color:"A5F3FC",context:c,fontName:s.fontName ?? "PingFangSC-Medium") }
        if let caption = s.captions.first(where: { $0.startFrame <= mapped && $0.endFrame > mapped }) { c.setFillColor(color("000000",alpha:0.75)); c.fill(overlay.captionBackground); try checkedText(caption.text,in:overlay.captionText,size:28,color:"FFFFFF",context:c,fontName:s.fontName ?? "PingFangSC-Medium") }
        if index==revision.scenes.count-1 {
            try checkedText(revision.cta,in:overlay.cta,size:portrait ? 19:18,color:"A5F3FC",context:c,fontName:s.fontName ?? "PingFangSC-Medium")
        }
        try checkedText("\(index+1) / \(revision.scenes.count)  ·  \(String(format:"%.1fs",Double(frame)/Double(revision.fps)))",in:overlay.footer,size:18,color:"94A3B8",context:c,fontName:s.fontName ?? "PingFangSC-Medium")
    }
    public static func png(_ image: CGImage) throws -> Data { let data = NSMutableData(); guard let target = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else { throw VideoError.unavailable("无法生成封面") }; CGImageDestinationAddImage(target,image,nil); guard CGImageDestinationFinalize(target) else { throw VideoError.unavailable("保存封面失败") }; return data as Data }
    private static func checkedText(_ value:String,in rect:CGRect,size:CGFloat,color:String,context:CGContext,fontName:String="PingFangSC-Medium") throws { guard CGRect(x:0,y:0,width:CGFloat(context.width),height:CGFloat(context.height)).contains(rect) else{throw VideoError.review("画面文字区域越出实际画布，请调整位置、缩放或拆分镜头")};let font=CTFontCreateWithName(fontName as CFString,size,nil);guard (CTFontCopyPostScriptName(font) as String)==fontName else{throw VideoError.unavailable("指定字体未安装或名称不准确，请改用可用中文系统字体")};if !text(value,in:rect,size:size,color:color,context:context,fontName:fontName) { throw VideoError.review("画面文字超出安全区或缺少实际可绘制字形，请更换字体、缩短或拆分镜头") } }
    @discardableResult private static func text(_ value:String,in rect:CGRect,size:CGFloat,color hex:String,context c:CGContext,fontName:String="PingFangSC-Medium") -> Bool {
        let font = CTFontCreateWithName(fontName as CFString,size,nil)
        let attributes: [NSAttributedString.Key:Any] = [.init(kCTFontAttributeName as String):font,.init(kCTForegroundColorAttributeName as String):color(hex)]
        let string = NSAttributedString(string:value,attributes:attributes); let setter = CTFramesetterCreateWithAttributedString(string); let path = CGPath(rect:rect,transform:nil); let frame = CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),path,nil); guard TextGlyphInspection.hasSupportedGlyphs(frame) else{return false};c.textMatrix = .identity; CTFrameDraw(frame,c); return CTFrameGetVisibleStringRange(frame).length == string.length
    }
    private static func color(_ hex:String,alpha:CGFloat=1) -> CGColor { let n = UInt32(hex,radix:16) ?? 0x6366F1; return CGColor(red:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:alpha) }
}

/// Validate shaped fallback runs too; accepting a font name does not prove every glyph exists.
public enum TextGlyphInspection {
    public static func hasSupportedGlyphs(_ frame:CTFrame)->Bool {
        for line in CTFrameGetLines(frame) as! [CTLine] {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes=CTRunGetAttributes(run) as NSDictionary
                if let font=attributes[kCTFontAttributeName] as! CTFont?,(CTFontCopyPostScriptName(font) as String).localizedCaseInsensitiveContains("lastresort") {return false}
                let count=CTRunGetGlyphCount(run)
                var glyphs=[CGGlyph](repeating:0,count:count),advances=[CGSize](repeating:.zero,count:count)
                CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs);CTRunGetAdvances(run,CFRange(location:0,length:0),&advances)
                if glyphs.indices.contains(where:{glyphs[$0]==0 && (abs(advances[$0].width)>0.001 || abs(advances[$0].height)>0.001)}) {return false}
            }
        }
        return true
    }
}
