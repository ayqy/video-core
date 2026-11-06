import Foundation
import CoreGraphics
import CoreText
import ImageIO
import VideoCore

/// Independent layouts share title shaping and verified pixels, not one card.
/// Legacy subtitles remain in the project but never become extra cover copy.
public enum CoverPainter {
    struct Palette {
        let paper:String;let ink:String;let accent:String;let secondary:String
        init(_ style:CoverStyle) {
            switch style {
            case .presenter:(paper,ink,accent,secondary)=("261A3A","FFF6ED","FFE45E","E84791")
            case .pencil:(paper,ink,accent,secondary)=("FFF9ED","294D43","F6BD8A","82AF91")
            case .game:(paper,ink,accent,secondary)=("DDEFE0","173C34","FFE27B","71AD91")
            case .cartoon:(paper,ink,accent,secondary)=("F9DA5A","38274F","FFE56D","ED6393")
            case .media:(paper,ink,accent,secondary)=("101B28","FFFFFF","F5D75E","417F8B")
            case .chart:(paper,ink,accent,secondary)=("F1F3FE","21305B","BDF176","6386D9")
            case .code:(paper,ink,accent,secondary)=("142823","ECFAEF","C4FA80","46A897")
            default:(paper,ink,accent,secondary)=("F6F3EF","24384F","F7C251","EB755B")
            }
        }
    }
    struct TitleComposition {
        var lines:[CTLine];var origins:[CGPoint];var bounds:[CGRect];var highlights:[CGRect];var safeRect:CGRect
        var visibleBounds:CGRect {(bounds+highlights).reduce(CGRect.null){$0.union($1)}}
    }
    public static func loadImages(revision:Revision,repository:Repository,database:Database)throws->[String:CGImage] {
        try CoverRules.validate(revision:revision,assets:database.assets)
        let cover=try CoverRules.resolved(revision:revision)
        var result:[String:CGImage]=[:]
        for reference in [cover.hero,cover.background].compactMap({$0}) where result[reference.assetID]==nil {
            guard let asset=database.assets.first(where:{$0.id==reference.assetID && $0.workspaceID==revision.workspaceID}) else {throw VideoError.permission("封面原图缺失")}
            guard asset.hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
                  asset.ext.range(of:"^[a-z0-9]{1,12}$",options:.regularExpression) != nil else {throw VideoError.review("封面原图CAS路径元数据无效")}
            let url=repository.assetURL(asset),attributes=try FileManager.default.attributesOfItem(atPath:repository.assetURL(asset).path)
            guard url.resolvingSymlinksInPath().path==url.standardizedFileURL.path,
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  asset.bytes>0,asset.bytes<=256*1024*1024,(attributes[.size] as? NSNumber)?.intValue==asset.bytes else {throw VideoError.review("封面原图摘要、路径或实际像素无效")}
            let raw=try Data(contentsOf:url)
            guard raw.count==asset.bytes,Codec.hash(raw)==asset.hash,
                  let source=CGImageSourceCreateWithData(raw as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),
                  image.width>0,image.height>0,image.width<=16384,image.height<=16384,image.width*image.height<=64*1024*1024 else {throw VideoError.review("封面原图摘要、路径或实际像素无效")}
            result[reference.assetID]=image
        }
        return result
    }
    public static func image(revision:Revision,source:CGImage,images:[String:CGImage]=[:])throws->CGImage {
        let cover=try CoverRules.resolved(revision:revision),w=revision.aspect.width,h=revision.aspect.height
        guard source.width==w,source.height==h,
              let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw VideoError.invalid("封面底图须来自当前画幅的同版成片")}
        func selected(_ reference:CoverImage?)throws->CGImage? {
            guard let reference else{return nil}
            guard let original=images[reference.assetID] else {throw VideoError.notFound("封面模板引用的实际图片未加载")}
            return try MediaFramingRenderer.crop(original,framing:reference.sourceRect)
        }
        let hero=try selected(cover.hero),explicitBackground=try selected(cover.background)
        // A dedicated IP never reveals an unrelated face or movie subtitles.
        let background=explicitBackground ?? (hero == nil ? source:nil)
        let canvas=CGRect(x:0,y:0,width:w,height:h),p=Palette(cover.style),side=CGFloat(min(w,h))
        let square=CGRect(x:canvas.midX-side/2,y:canvas.midY-side/2,width:side,height:side)
        let variant=cover.template == .editorial ? 1:(cover.template == .contrast ? 2:0)
        c.setFillColor(color(p.paper));c.fill(canvas)
        switch cover.style {
        case .pencil:pencil(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .presenter:presenter(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .game:game(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .cartoon:cartoon(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .media:media(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .chart:chart(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .code:code(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        default:explanation(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        }
        let composition=try composeTitle(cover:cover,width:canvas.width,height:canvas.height)
        // No label, ribbon, subtitle, timestamp or explanation is painted.
        c.setFillColor(color(p.accent));for rect in composition.highlights {c.fill(rect)}
        c.textMatrix = .identity
        c.saveGState()
        if cover.style == .media {c.setShadow(offset:CGSize(width:0,height:-1),blur:4,color:color("000000",alpha:0.65))}
        for (line,origin) in zip(composition.lines,composition.origins) {c.textPosition=origin;CTLineDraw(line,c)}
        c.restoreGState()
        guard let image=c.makeImage() else {throw VideoError.unavailable("模板封面合成失败")};return image
    }
    /// Intersection of centered square and centered 16:9 previews, with margin.
    static func titleSafeRect(width:CGFloat,height:CGFloat)->CGRect {
        let side=min(width,height),square=CGRect(x:(width-side)/2,y:(height-side)/2,width:side,height:side)
        let ww=min(width,height*16/9),hh=min(height,width*9/16),wide=CGRect(x:(width-ww)/2,y:(height-hh)/2,width:ww,height:hh)
        return square.intersection(wide).insetBy(dx:side*0.065,dy:side*0.065)
    }
    static func composeTitle(cover:ResolvedCover,width:CGFloat,height:CGFloat)throws->TitleComposition {
        let safe=titleSafeRect(width:width,height:height),side=min(width,height),p=Palette(cover.style)
        let value=displayTitle(cover.title,style:cover.style),string=value as NSString,original=cover.title as NSString
        let oldQuote=original.range(of:"「").location,newQuote=string.range(of:"「").location
        func displayIndex(_ index:Int)->Int {
            guard value != cover.title,oldQuote != NSNotFound,newQuote != NSNotFound else{return index}
            return index>=oldQuote ? index+newQuote-oldQuote:min(index,newQuote-1)
        }
        var ranges:[NSRange]=[]
        for keyword in cover.emphasis {
            var search=NSRange(location:0,length:original.length)
            while search.length>0 {
                let range=original.range(of:keyword,options:[],range:search);if range.location==NSNotFound {break}
                let start=displayIndex(range.location),end=displayIndex(range.location+range.length)
                if end>start {ranges.append(NSRange(location:start,length:end-start))}
                search=NSRange(location:range.location+range.length,length:original.length-range.location-range.length)
            }
        }
        var size=side*0.085
        while size>=side*0.042 {
            let normal=try CoverTypeface.font(size:size),emphasized=try CoverTypeface.font(size:size*1.24)
            let title=NSMutableAttributedString(string:value,attributes:[.init(kCTFontAttributeName as String):normal,.init(kCTForegroundColorAttributeName as String):color(p.ink)])
            let keywordInk=(cover.style == .code || cover.style == .media) ? p.paper:(cover.style == .game ? "1E5C3F":"992B45")
            for range in ranges {title.addAttributes([.init(kCTFontAttributeName as String):emphasized,.init(kCTForegroundColorAttributeName as String):color(keywordInk)],range:range)}
            let setter=CTFramesetterCreateWithAttributedString(title),frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:CGRect(x:0,y:0,width:safe.width,height:safe.height),transform:nil),nil)
            let lines=CTFrameGetLines(frame) as! [CTLine]
            if !lines.isEmpty,lines.count<=3,CTFrameGetVisibleStringRange(frame).length==title.length,TextGlyphInspection.hasSupportedGlyphs(frame) {
                var origins:[CGPoint]=[],bounds:[CGRect]=[],highlights:[CGRect]=[]
                for (index,line) in lines.enumerated() {
                    let glyphs=CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
                    guard !glyphs.isNull,!glyphs.isInfinite,glyphs.width.isFinite,glyphs.height.isFinite else {throw VideoError.review("封面标题字形无法量测")}
                    let origin=CGPoint(x:safe.midX-glyphs.midX,y:-CGFloat(index)*size*1.52)
                    origins.append(origin);bounds.append(glyphs.offsetBy(dx:origin.x,dy:origin.y))
                    let range=CTLineGetStringRange(line),lineRange=NSRange(location:range.location,length:range.length)
                    for keyword in ranges {
                        let clipped=NSIntersectionRange(keyword,lineRange);if clipped.length==0 {continue}
                        let a=CTLineGetOffsetForStringIndex(line,clipped.location,nil),b=CTLineGetOffsetForStringIndex(line,clipped.location+clipped.length,nil)
                        highlights.append(CGRect(x:origin.x+min(a,b)-size*0.09,y:origin.y-size*0.17,width:abs(b-a)+size*0.18,height:size*1.25))
                    }
                }
                let union=(bounds+highlights).reduce(CGRect.null){$0.union($1)},shift=safe.midY-union.midY
                origins=origins.map{CGPoint(x:$0.x,y:$0.y+shift)};bounds=bounds.map{$0.offsetBy(dx:0,dy:shift)};highlights=highlights.map{$0.offsetBy(dx:0,dy:shift)}
                if (bounds+highlights).allSatisfy({safe.contains($0)}) {return TitleComposition(lines:lines,origins:origins,bounds:bounds,highlights:highlights,safeRect:safe)}
            }
            size-=2
        }
        throw VideoError.review("封面标题过长、缺字或超出横版和方形共同安全区，请精简标题后重新制作")
    }
    static func displayTitle(_ value:String,style:CoverStyle)->String {
        guard style == .presenter,value.hasPrefix("豆子姐讲"),let quote=value.firstIndex(of:"「") else{return value}
        return value[..<quote].trimmingCharacters(in:.whitespacesAndNewlines)+"\n"+String(value[quote...])
    }
    private static func explanation(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width,wing=min(d*0.52,canvas.width*0.40),rise=CGFloat(variant)*d*0.025
        let left=CGRect(x:max(12,s.minX-d*0.34),y:s.minY+d*0.035+rise,width:wing,height:d*0.47)
        let right=CGRect(x:min(canvas.width-wing-12,s.maxX-d*0.13),y:s.minY+d*0.48-rise,width:wing,height:d*0.47)
        // The real two-sided content surrounds the question instead of becoming
        // a postage stamp under it. The route connects cause and consequence.
        c.setStrokeColor(color(p.secondary,alpha:0.30));c.setLineWidth(d*0.016)
        c.move(to:CGPoint(x:left.midX,y:left.midY));c.addCurve(to:CGPoint(x:right.midX,y:right.midY),control1:CGPoint(x:canvas.midX-d*0.30,y:s.minY+d*0.82),control2:CGPoint(x:canvas.midX+d*0.24,y:s.minY+d*0.14));c.strokePath()
        c.setFillColor(color(p.accent));c.fillEllipse(in:CGRect(x:left.midX-d*0.06,y:left.maxY-d*0.05,width:d*0.12,height:d*0.12))
        c.fillEllipse(in:CGRect(x:right.midX-d*0.04,y:right.minY-d*0.04,width:d*0.08,height:d*0.08))
        pairedArtwork(image,leading:left,trailing:right,c:c)
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func pencil(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        for i in 0..<40 {c.setStrokeColor(color(p.secondary,alpha:0.09));c.setLineWidth(1);c.move(to:CGPoint(x:0,y:canvas.height*CGFloat(i)/40));c.addLine(to:CGPoint(x:canvas.width,y:canvas.height*CGFloat(i)/40+6));c.strokePath()}
        // A broad paper landscape holds the actual artwork. Hand-drawn arcs
        // continue its story silhouette; they do not form another photo card.
        c.setFillColor(color("FFFFFF",alpha:0.72))
        polygon([CGPoint(x:0,y:s.minY),CGPoint(x:canvas.width,y:s.minY),CGPoint(x:canvas.width,y:s.minY+d*0.30),CGPoint(x:canvas.midX+d*0.2,y:s.minY+d*0.25),CGPoint(x:canvas.midX-d*0.28,y:s.minY+d*0.36),CGPoint(x:0,y:s.minY+d*0.29)],c:c)
        material(image,in:CGRect(x:canvas.midX-d*0.69,y:s.minY-d*0.11,width:d*1.38,height:d*0.68),c:c)
        c.setStrokeColor(color(p.secondary));c.setLineWidth(d*0.010)
        for i in 0..<4 {
            let y=s.minY+d*(0.79+Double(i)*0.027)
            c.move(to:CGPoint(x:canvas.midX-d*0.48,y:y));c.addQuadCurve(to:CGPoint(x:canvas.midX+d*0.48,y:y+d*0.015),control:CGPoint(x:canvas.midX+d*CGFloat(variant-1)*0.08,y:y+d*0.12));c.strokePath()
        }
        c.setFillColor(color(p.accent,alpha:0.32));c.fillEllipse(in:CGRect(x:max(0,s.minX-d*0.24),y:s.minY+d*0.51,width:d*0.30,height:d*0.30))
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func presenter(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        if let image {
            // With an independent hero, image can only be the author's explicit
            // background. It must participate rather than be silently ignored.
            draw(image,in:canvas,fill:true,context:c)
            gradient(canvas,colors:[color(p.paper,alpha:0.84),color(p.paper,alpha:0.94),color(p.paper,alpha:0.78)],locations:[0,0.5,1],c:c)
        } else {
            gradient(canvas,colors:[color("6D346A",alpha:0.85),color(p.paper,alpha:0.05),color("6A3A72",alpha:0.65)],locations:[0,0.5,1],c:c)
        }
        // The large, legible action leans toward the central topic. A theatrical
        // soft spotlight replaces the unmotivated yellow block and header strip.
        c.saveGState();c.setShadow(offset:.zero,blur:d*0.07,color:color(p.secondary,alpha:0.55));c.setFillColor(color(p.secondary,alpha:0.12))
        let light=CGRect(x:variant == 1 ? s.minX-d*0.30:s.maxX-d*0.16,y:s.minY+d*0.02,width:d*0.48,height:d*0.52)
        c.fillEllipse(in:light);c.restoreGState()
        if variant == 2 {c.setStrokeColor(color(p.secondary,alpha:0.26));c.setLineWidth(d*0.006);c.strokeEllipse(in:light.insetBy(dx:-d*0.05,dy:-d*0.05))}
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func game(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width,ratio=image.map{CGFloat($0.width)/CGFloat($0.height)} ?? 16/9
        let height=d*(variant == 2 ? 0.33:0.36),width=min(canvas.width*0.86,height*ratio)
        let window=CGRect(x:canvas.midX-width/2+CGFloat(variant-1)*d*0.025,y:s.minY+d*0.035,width:width,height:height)
        // The complete original 3D scene is below the headline. No opaque title
        // panel can hide the character's face. The scene supplies real volume;
        // the frame adds a low plinth and a contact shadow, never a fake actor.
        c.setFillColor(color(p.secondary,alpha:0.16));c.fillEllipse(in:CGRect(x:canvas.midX-d*0.62,y:s.minY+d*0.02,width:d*1.24,height:d*0.10))
        c.setFillColor(color(p.secondary));polygon([CGPoint(x:window.minX-d*0.045,y:window.minY),CGPoint(x:window.maxX+d*0.045,y:window.minY),CGPoint(x:window.maxX+d*0.085,y:window.minY-d*0.015),CGPoint(x:window.minX+d*0.005,y:window.minY-d*0.015)],c:c)
        c.setFillColor(color("FFF9E7"));c.fill(window.insetBy(dx:-8,dy:-8))
        if let image {draw(image,in:window,fill:false,context:c)}
        c.setStrokeColor(color(p.secondary,alpha:0.35));c.setLineWidth(d*0.004);c.stroke(window.insetBy(dx:-8,dy:-8))
        // Perspective rays continue the original set's floor without painting a
        // new game world or forcing text over the actor in the imported frame.
        c.setStrokeColor(color(p.secondary,alpha:0.20));c.setLineWidth(d*0.003)
        for x in [0.08,0.30,0.70,0.92] {c.move(to:CGPoint(x:canvas.width*x,y:s.minY));c.addLine(to:CGPoint(x:canvas.midX+(canvas.width*x-canvas.midX)*0.46,y:s.minY+d*0.16));c.strokePath()}
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func cartoon(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        c.setFillColor(color(p.secondary));polygon([CGPoint(x:0,y:0),CGPoint(x:canvas.width*0.42,y:0),CGPoint(x:canvas.width*0.25,y:canvas.height*0.42),CGPoint(x:0,y:canvas.height*0.72)],c:c)
        for row in 0..<7 {for column in 0..<8 {c.setFillColor(color(p.ink,alpha:0.10));c.fillEllipse(in:CGRect(x:CGFloat(column)*d*0.055+12,y:canvas.height-d*0.055*CGFloat(row)-18,width:7,height:7))}}
        let left=CGRect(x:max(0,s.minX-d*0.32),y:s.minY-d*0.03,width:d*0.68,height:d*0.61)
        let right=CGRect(x:min(canvas.width-d*0.58,s.maxX-d*0.12),y:s.minY+d*0.48,width:d*0.58,height:d*0.54)
        pairedArtwork(image,leading:left,trailing:right,c:c)
        // This type alone uses a comic burst. The real artwork crosses its
        // frame; there is no shared rectangular title backing.
        var burst:[CGPoint]=[]
        for i in 0..<24 {
            let angle=CGFloat(i)*CGFloat.pi/12,outer=i%2==0
            let rx=d*(outer ? 0.58:0.49),ry=d*(outer ? 0.19:0.145)
            burst.append(CGPoint(x:canvas.midX+cos(angle)*rx,y:canvas.midY+sin(angle)*ry+CGFloat(variant-1)*d*0.008))
        }
        c.setFillColor(color("FFFFFF"));polygon(burst,c:c)
        c.setStrokeColor(color(p.ink));c.setLineWidth(d*0.004);c.addLines(between:burst);c.closePath();c.strokePath()
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func media(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        if let image {draw(image,in:canvas,fill:true,context:c)}
        // A genuine image fills the cover; a continuous cinematic exposure mask
        // creates title contrast without reducing the image to a small strip.
        gradient(canvas,colors:[color(p.paper,alpha:0.20),color(p.paper,alpha:0.86),color(p.paper,alpha:0.18)],locations:[0,0.50,1],c:c)
        c.setStrokeColor(color(p.accent,alpha:0.84));c.setLineWidth(d*0.006)
        let inset=d*(variant == 1 ? 0.065:0.035),edge=d*0.10
        for (x,y,sx,sy) in [(inset,inset,1.0,1.0),(canvas.maxX-inset,inset,-1.0,1.0),(inset,canvas.maxY-inset,1.0,-1.0),(canvas.maxX-inset,canvas.maxY-inset,-1.0,-1.0)] {c.move(to:CGPoint(x:x,y:y+edge*sy));c.addLine(to:CGPoint(x:x,y:y));c.addLine(to:CGPoint(x:x+edge*sx,y:y));c.strokePath()}
        if variant == 2 {c.setFillColor(color(p.paper,alpha:0.88));c.fill(CGRect(x:0,y:0,width:canvas.width,height:d*0.045));c.fill(CGRect(x:0,y:canvas.height-d*0.045,width:canvas.width,height:d*0.045))}
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func chart(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        c.setStrokeColor(color(p.secondary,alpha:0.10));c.setLineWidth(1)
        for i in 1..<12 {let x=canvas.width*CGFloat(i)/12;c.move(to:CGPoint(x:x,y:0));c.addLine(to:CGPoint(x:x,y:canvas.height));c.strokePath()}
        // Large rising structures on both wings form the poster itself. Every
        // column ends inside the canvas; these are unnumbered design shapes.
        let barWidth=min(d*0.12,canvas.width*0.075)
        for i in 0..<3 {
            let height=d*(0.27+Double(i)*0.13+Double(variant)*0.015)
            let lx=max(0,s.minX-d*0.34)+CGFloat(i)*barWidth*1.28
            c.setFillColor(color(i%2==0 ? p.secondary:p.accent));c.fill(CGRect(x:lx,y:s.minY,width:barWidth,height:height))
            let rx=canvas.width-barWidth*1.10-CGFloat(i)*barWidth*1.28
            c.setFillColor(color(i%2==0 ? p.accent:p.secondary));c.fill(CGRect(x:rx,y:s.minY,width:barWidth,height:d*0.73-height*0.65))
        }
        c.setStrokeColor(color(p.secondary));c.setLineWidth(d*0.008);c.move(to:CGPoint(x:0,y:s.minY+d*0.66));c.addCurve(to:CGPoint(x:canvas.width,y:s.minY+d*0.84),control1:CGPoint(x:canvas.width*0.32,y:s.minY+d*0.96),control2:CGPoint(x:canvas.width*0.70,y:s.minY+d*0.62));c.strokePath()
        material(image,in:CGRect(x:canvas.midX-d*0.48,y:s.minY-d*0.05,width:d*0.96,height:d*0.50),c:c)
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func code(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        let rear=CGRect(x:max(10,s.minX-d*0.32),y:s.minY+d*0.22,width:d*0.48,height:d*0.69)
        let front=CGRect(x:min(canvas.width-d*0.53-10,s.maxX-d*0.14),y:s.minY+d*0.045,width:d*0.53,height:d*0.43)
        c.setFillColor(color("1C3D35"));c.fill(rear)
        c.setStrokeColor(color(p.secondary,alpha:0.70));c.setLineWidth(d*0.003);c.stroke(rear)
        for i in 0..<7 {c.setFillColor(color(i%3==0 ? p.accent:p.secondary,alpha:0.38));c.fill(CGRect(x:rear.minX+d*0.035+CGFloat(i%2)*d*0.025,y:rear.maxY-d*(0.08+Double(i)*0.075),width:rear.width*difference(i,variant)*0.68,height:d*0.012))}
        c.setStrokeColor(color(p.accent,alpha:0.74));c.setLineWidth(d*0.006)
        let junction=CGPoint(x:canvas.midX,y:s.minY+d*0.25)
        c.move(to:CGPoint(x:rear.maxX,y:rear.midY));c.addLine(to:CGPoint(x:junction.x-d*0.16,y:rear.midY));c.addLine(to:junction);c.addLine(to:CGPoint(x:front.minX-d*0.06,y:junction.y));c.addLine(to:CGPoint(x:front.minX,y:front.midY));c.strokePath()
        c.setFillColor(color(p.accent));c.fillEllipse(in:CGRect(x:junction.x-8,y:junction.y-8,width:16,height:16))
        c.setFillColor(color("21463D"));c.fill(front.offsetBy(dx:12,dy:-12));c.setFillColor(color("19372F"));c.fill(front);c.setStrokeColor(color(p.secondary));c.stroke(front)
        material(image,in:front.insetBy(dx:10,dy:10),c:c)
        if variant==2 {c.setStrokeColor(color(p.secondary,alpha:0.36));c.stroke(rear.offsetBy(dx:10,dy:10))}
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func difference(_ value:Int,_ variant:Int)->CGFloat {CGFloat(0.50+Double((value+variant)%4)*0.14)}
    static func auxiliaryRect(square s:CGRect,variant:Int)->CGRect {
        let width=s.width*0.34,canvasWidth=s.width+s.minX*2
        let x=variant == 1 ? max(s.width*0.025,s.minX-s.width*0.25):min(canvasWidth-width-s.width*0.025,s.maxX-s.width*0.10)
        return CGRect(x:x,y:s.minY+s.height*0.015,width:width,height:s.height*0.38)
    }
    private static func auxiliary(_ image:CGImage?,square:CGRect,variant:Int,c:CGContext) {
        guard let image else{return};c.saveGState();c.setShadow(offset:CGSize(width:0,height:-5),blur:10,color:color("102A24",alpha:0.22));draw(image,in:auxiliaryRect(square:square,variant:variant),fill:false,context:c);c.restoreGState()
    }
    /// Split only through a completely transparent source column between actual
    /// artwork on both sides. A connected or opaque image remains one image.
    static func separatedArtwork(_ image:CGImage)->(CGImage,CGImage)? {
        let width=image.width,height=image.height
        guard width>=4,height>0,width*height<=64*1024*1024,
              let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data=context.data?.assumingMemoryBound(to:UInt8.self) else{return nil}
        context.setBlendMode(.copy);context.interpolationQuality = .none
        context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));context.flush()
        var occupied=[Bool](repeating:false,count:width)
        for x in 0..<width {for y in 0..<height where data[y*context.bytesPerRow+x*4+3] != 0 {occupied[x]=true;break}}
        guard let first=occupied.firstIndex(of:true),let last=occupied.lastIndex(of:true),last-first>=4 else{return nil}
        let center=width/2
        let empty=(first+1..<last).filter{!occupied[$0]}.min {a,b in
            abs(a-center)==abs(b-center) ? a<b:abs(a-center)<abs(b-center)
        }
        guard let split=empty,
              let leading=image.cropping(to:CGRect(x:0,y:0,width:split,height:height)),
              let trailing=image.cropping(to:CGRect(x:split,y:0,width:width-split,height:height)) else{return nil}
        return (leading,trailing)
    }
    private static func pairedArtwork(_ image:CGImage?,leading:CGRect,trailing:CGRect,c:CGContext) {
        guard let image else{return}
        if let pair=separatedArtwork(image) {draw(pair.0,in:leading,fill:false,context:c);draw(pair.1,in:trailing,fill:false,context:c)}
        else {draw(image,in:leading,fill:false,context:c)}
    }
    private static func gradient(_ rect:CGRect,colors:[CGColor],locations:[CGFloat],c:CGContext) {
        guard let gradient=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors as CFArray,locations:locations) else{return}
        c.saveGState();c.clip(to:rect);c.drawLinearGradient(gradient,start:CGPoint(x:rect.midX,y:rect.minY),end:CGPoint(x:rect.midX,y:rect.maxY),options:[]);c.restoreGState()
    }
    private static func material(_ image:CGImage?,in rect:CGRect,c:CGContext) {if let image {draw(image,in:rect,fill:false,context:c)}}
    private static func polygon(_ points:[CGPoint],c:CGContext) {guard let first=points.first else{return};c.move(to:first);for point in points.dropFirst(){c.addLine(to:point)};c.closePath();c.fillPath()}
    private static func draw(_ image:CGImage,in rect:CGRect,fill:Bool,context c:CGContext) {
        let factor=fill ? max(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height)):min(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height))
        let box=CGRect(x:rect.midX-CGFloat(image.width)*factor/2,y:rect.midY-CGFloat(image.height)*factor/2,width:CGFloat(image.width)*factor,height:CGFloat(image.height)*factor)
        c.saveGState();c.clip(to:rect);c.interpolationQuality = .high;c.draw(image,in:box);c.restoreGState()
    }
    private static func color(_ hex:String,alpha:CGFloat=1)->CGColor {
        let v=UInt32(hex,radix:16) ?? 0
        return CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[CGFloat((v>>16)&255)/255,CGFloat((v>>8)&255)/255,CGFloat(v&255)/255,alpha])!
    }
}
