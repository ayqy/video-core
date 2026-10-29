import CoreGraphics
import CoreText
import ImageIO
import VideoCore
import Foundation

enum LayerPainter {
    struct Sample {
        let rect:CGRect
        let opacity:Double
        let revealedFraction:Double
    }
    /// Drawing and subtitle clearance consume this one source-frame sample.
    /// The story process adds positions/visibility to the existing layer IR;
    /// its renderer never guesses who paid or recalculates a result.
    static func sample(layer:SceneLayer,scene:Scene,sourceFrame:Int,aspect:Aspect)throws->Sample {
        let frame=LayerRules.renderSourceFrame(scene:scene,sourceFrame:sourceFrame)
        let authored=layer.layout(at:frame)
        let action=StoryActionRules.presentation(subjectID:layer.id,actions:scene.storyActions ?? [],frame:frame)
        let x=action.position?.x ?? authored.x,y=action.position?.y ?? authored.y
        let w=Double(aspect.width),h=Double(aspect.height)
        let rect=CGRect(x:(x-layer.width*authored.scale/2)*w,y:(1-y-layer.height*authored.scale/2)*h,width:layer.width*authored.scale*w,height:layer.height*authored.scale*h)
        let entrance=try layer.entrance?.progress(at:frame) ?? 1
        return Sample(rect:rect,opacity:layer.opacity*action.opacity*(layer.entrance?.kind == .fade ? entrance:1),
                      revealedFraction:min(action.progress,layer.entrance?.kind == .revealLeft ? entrance:1))
    }
    static func draw(scene:Scene,sourceFrame:Int,aspect:Aspect,images:[String:CGImage],context c:CGContext,fontName:String="PingFangSC-Medium") throws {
        let frame=LayerRules.renderSourceFrame(scene:scene,sourceFrame:sourceFrame)
        for layer in scene.layers ?? [] {
            guard layer.startFrame<=frame,layer.endFrame>frame else{continue}
            let sample=try sample(layer:layer,scene:scene,sourceFrame:frame,aspect:aspect),rect=sample.rect
            c.saveGState();defer { c.restoreGState() }
            c.setAlpha(CGFloat(sample.opacity))
            if sample.revealedFraction<1 {
                c.clip(to:CGRect(x:rect.minX,y:rect.minY,width:rect.width*CGFloat(sample.revealedFraction),height:rect.height))
            }
            let rgb=UInt32(layer.color,radix:16) ?? 0xFFFFFF;let color=CGColor(red:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
            switch layer.kind {
            case .rectangle:c.setFillColor(color);c.fill(rect)
            case .image:
                guard let id=layer.assetID,let image=images[id] else { throw VideoError.notFound("元素图片未加载") }
                let ratio=min(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height));c.draw(image,in:CGRect(x:rect.midX-CGFloat(image.width)*ratio/2,y:rect.midY-CGFloat(image.height)*ratio/2,width:CGFloat(image.width)*ratio,height:CGFloat(image.height)*ratio))
            case .text:
                guard CGRect(x:24,y:24,width:CGFloat(aspect.width-48),height:CGFloat(aspect.height-48)).contains(rect) else{throw VideoError.review("文字元素越出画面安全区，请调整位置、尺寸或关键帧")}
                let font=CTFontCreateWithName(fontName as CFString,CGFloat(aspect == .portrait ? 30:32),nil)
                let string=NSAttributedString(string:layer.text,attributes:[.init(kCTFontAttributeName as String):font,.init(kCTForegroundColorAttributeName as String):color])
                let setter=CTFramesetterCreateWithAttributedString(string),frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:rect,transform:nil),nil)
                guard (CTFontCopyPostScriptName(font) as String)==fontName,TextGlyphInspection.hasSupportedGlyphs(frame),CTFrameGetVisibleStringRange(frame).length==string.length else { throw VideoError.review("文字元素超出区域，请扩大元素或拆分文案") };c.textMatrix = .identity;CTFrameDraw(frame,c)
            case .chart,.code:
                try DataPresentationPainter.draw(layer:layer,sourceFrame:frame,rect:rect,context:c,fontName:fontName,paperPresentation:scene.paperPresentation)
            }
        }
    }
}
