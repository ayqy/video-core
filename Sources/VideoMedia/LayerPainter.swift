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
        let rect:CGRect
        if let path=layer.texturedPath {
            try layer.validateImagePresentation()
            guard !(scene.storyActions ?? []).contains(where:{$0.subjectID==layer.id && [.move,.transfer].contains($0.kind)}) else {
                throw VideoError.invalid("纹理路线不能叠加移动或交付位置动作")
            }
            rect=textureBounds(path,aspect:aspect)
        } else {
            rect=CGRect(x:(x-layer.width*authored.scale/2)*w,y:(1-y-layer.height*authored.scale/2)*h,width:layer.width*authored.scale*w,height:layer.height*authored.scale*h)
        }
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
            if layer.texturedPath == nil,sample.revealedFraction<1 {
                c.clip(to:CGRect(x:rect.minX,y:rect.minY,width:rect.width*CGFloat(sample.revealedFraction),height:rect.height))
            }
            let rgb=UInt32(layer.color,radix:16) ?? 0xFFFFFF;let color=CGColor(red:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
            try layer.validateImagePresentation()
            switch layer.kind {
            case .rectangle:c.setFillColor(color);c.fill(rect)
            case .image:
                guard let id=layer.assetID,let image=images[id] else { throw VideoError.notFound("元素图片未加载") }
                let sourceRect=try layer.imageSequence?.sourceRect(at:frame) ?? layer.sourceRect
                let cropped=try MediaFramingRenderer.crop(image,framing:sourceRect)
                if let path=layer.texturedPath {
                    // One composited layer applies opacity once even at a turn
                    // or a branch intersection. No extra SceneLayers are made.
                    c.beginTransparencyLayer(in:rect,auxiliaryInfo:nil)
                    drawTexture(cropped,path:path,fraction:sample.revealedFraction,aspect:aspect,context:c)
                    c.endTransparencyLayer()
                } else {
                    let ratio=min(rect.width/CGFloat(cropped.width),rect.height/CGFloat(cropped.height))
                    let fitted=CGRect(x:rect.midX-CGFloat(cropped.width)*ratio/2,y:rect.midY-CGFloat(cropped.height)*ratio/2,width:CGFloat(cropped.width)*ratio,height:CGFloat(cropped.height)*ratio)
                    if layer.imageFlipHorizontal == true {
                        // Reflect only the selected pose, after source cropping
                        // and fit. Existing stage clipping and placement stay.
                        c.translateBy(x:2*fitted.midX,y:0);c.scaleBy(x:-1,y:1)
                    }
                    c.draw(cropped,in:fitted)
                }
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

    private static func texturePoints(_ stroke:LayerTextureStroke,aspect:Aspect)->[CGPoint] {
        stroke.points.map{CGPoint(x:$0.x*Double(aspect.width),y:(1-$0.y)*Double(aspect.height))}
    }
    /// Subtitle clearance uses the real route extent, not the old image-fit box.
    private static func textureBounds(_ path:LayerTexturedPath,aspect:Aspect)->CGRect {
        var bounds=CGRect.null
        for stroke in path.paths {
            let radius=stroke.width*Double(aspect.width)/2
            for point in texturePoints(stroke,aspect:aspect) {
                bounds=bounds.union(CGRect(x:Double(point.x)-radius,y:Double(point.y)-radius,width:radius*2,height:radius*2))
            }
        }
        return bounds
    }
    /// Reveal is measured in output pixels across all authored strokes. Texture
    /// tiles retain their source aspect ratio instead of stretching to a route.
    private static func drawTexture(_ image:CGImage,path:LayerTexturedPath,fraction:Double,aspect:Aspect,context c:CGContext) {
        let routes=path.paths.map{texturePoints($0,aspect:aspect)}
        let lengths=routes.map{points in zip(points,points.dropFirst()).map{hypot($1.x-$0.x,$1.y-$0.y)}}
        var remaining=lengths.flatMap{$0}.reduce(0,+)*CGFloat(min(1,max(0,fraction)))
        var sourceDistance:CGFloat=0
        for index in routes.indices {
            let points=routes[index],segmentLengths=lengths[index]
            var visible:[CGPoint]=[points[0]]
            for segment in segmentLengths.indices {
                let length=segmentLengths[segment]
                guard remaining>0 else {break}
                let consumed=min(length,remaining),t=consumed/length
                let a=points[segment],b=points[segment+1]
                visible.append(CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))
                remaining-=consumed
                if consumed<length {break}
            }
            if visible.count>1 {
                let width=CGFloat(path.paths[index].width*Double(aspect.width))
                c.saveGState()
                let centerline=CGMutablePath();centerline.addLines(between:visible)
                // Authored endpoints and a partially built front delimit the
                // laid surface; rounded joins keep bends continuous inside it.
                c.beginPath();c.addPath(centerline.copy(strokingWithWidth:width,lineCap:.butt,lineJoin:.round,miterLimit:2));c.clip()
                let tileWidth=width*CGFloat(image.width)/CGFloat(image.height)
                var distance=sourceDistance
                for segment in 0..<(visible.count-1) {
                    let a=visible[segment],b=visible[segment+1]
                    let length=hypot(b.x-a.x,b.y-a.y),radius=width/2
                    c.saveGState();c.translateBy(x:a.x,y:a.y);c.rotate(by:atan2(b.y-a.y,b.x-a.x))
                    var tileX = -radius-(distance-radius).truncatingRemainder(dividingBy:tileWidth)
                    if tileX > -radius {tileX-=tileWidth}
                    while tileX<length+radius {
                        c.draw(image,in:CGRect(x:tileX,y:-radius,width:tileWidth,height:width))
                        tileX+=tileWidth
                    }
                    c.restoreGState();distance+=length
                }
                c.restoreGState()
            }
            sourceDistance+=segmentLengths.reduce(0,+)
        }
    }
}
