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
            case .presenter:(paper,ink,accent,secondary)=("101C43","FFF9E9","FFDF42","4278F3")
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
        var effects:[CGRect];var outline:CGFloat;var depth:CGFloat
        var visibleBounds:CGRect {(effects+highlights).reduce(CGRect.null){$0.union($1)}}
    }
    struct HeroPlacement {
        var rect:CGRect;var target:CoverPointing;var mirrored:Bool
        func renderedDirection(_ source:CoverPointing)->CoverPointing {mirrored ? (source == .left ? .right:.left):source}
    }
    struct GameDepthLayout {
        var aperture:CGRect;var hero:CGRect;var frontLip:CGRect
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
        let composition=try composeTitle(cover:cover,width:canvas.width,height:canvas.height)
        let placement=presenterPlacement(square:square,variant:variant,titleBounds:composition.visibleBounds,pointing:cover.hero?.pointing)
        c.setFillColor(color(p.paper));c.fill(canvas)
        switch cover.style {
        case .pencil:pencil(background,hero:hero,square:square,canvas:canvas,variant:variant,titleBounds:composition.visibleBounds,p:p,c:c)
        case .presenter:presenter(background,hero:hero,placement:placement,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .game:game(background,hero:hero,square:square,canvas:canvas,variant:variant,titleBounds:composition.visibleBounds,p:p,c:c)
        case .cartoon:cartoon(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .media:media(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .chart:try chart(background,hero:hero,square:square,canvas:canvas,variant:variant,revision:revision,p:p,c:c)
        case .code:try code(background,hero:hero,square:square,canvas:canvas,variant:variant,revision:revision,p:p,c:c)
        default:explanation(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        }
        // No label, ribbon, subtitle, timestamp or explanation is painted.
        paintTitle(composition,style:cover.style,p:p,c:c)
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
        let relief:[CoverStyle:CGFloat]=[.presenter:0.007,.game:0.006,.cartoon:0.005,.code:0.003,.chart:0.002,.media:0.002,.pencil:0.001,.explanation:0.003]
        let depth=side*(relief[cover.style] ?? 0.003),outline=side*(cover.style == .pencil ? 0.001:0.003)
        let margin=depth+outline
        let kern=side*(cover.style == .presenter || cover.style == .cartoon ? -0.0015:0.0003)
        let arrangements=titleArrangements(value,emphasis:ranges)
        var size=side*0.112
        while size>=side*0.042 {
            let normal=try CoverTypeface.displayFont(size:size),emphasized=try CoverTypeface.displayFont(size:size*1.17)
            let title=NSMutableAttributedString(string:value,attributes:[.init(kCTFontAttributeName as String):normal,.init(kCTKernAttributeName as String):kern,.init(kCTForegroundColorAttributeName as String):color(p.ink)])
            let keywordInk=(cover.style == .code || cover.style == .media || cover.style == .presenter) ? p.paper:(cover.style == .game ? "1E5C3F":"7F2040")
            for range in ranges {title.addAttributes([.init(kCTFontAttributeName as String):emphasized,.init(kCTForegroundColorAttributeName as String):color(keywordInk)],range:range)}
            let typesetter=CTTypesetterCreateWithAttributedString(title)
            var candidates:[(lines:[CTLine],score:CGFloat)]=[]
            for arrangement in arrangements {
                let lines=arrangement.ranges.map{CTTypesetterCreateLine(typesetter,CFRange(location:$0.location,length:$0.length))}
                let widths=lines.map{CGFloat(CTLineGetTypographicBounds($0,nil,nil,nil))}
                guard !lines.isEmpty,widths.allSatisfy({$0<=safe.width-margin*2}),supported(lines,requiredFont:CoverTypeface.displayPostScriptName) else {continue}
                let widest=widths.max() ?? 0,narrowest=widths.min() ?? 0
                let score=(widest-narrowest)/safe.width+arrangement.penalty
                candidates.append((lines,score))
            }
            for candidate in candidates.sorted(by:{$0.score<$1.score}) {
                let lines=candidate.lines
                var origins:[CGPoint]=[],bounds:[CGRect]=[],highlights:[CGRect]=[]
                for (index,line) in lines.enumerated() {
                    let glyphs=CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
                    guard !glyphs.isNull,!glyphs.isInfinite,glyphs.width.isFinite,glyphs.height.isFinite else {throw VideoError.review("封面标题字形无法量测")}
                    let origin=CGPoint(x:safe.midX-glyphs.midX,y:-CGFloat(index)*size*1.48)
                    origins.append(origin);bounds.append(glyphs.offsetBy(dx:origin.x,dy:origin.y))
                    let range=CTLineGetStringRange(line),lineRange=NSRange(location:range.location,length:range.length)
                    for keyword in ranges {
                        let clipped=NSIntersectionRange(keyword,lineRange);if clipped.length==0 {continue}
                        let a=CTLineGetOffsetForStringIndex(line,clipped.location,nil),b=CTLineGetOffsetForStringIndex(line,clipped.location+clipped.length,nil)
                        highlights.append(CGRect(x:origin.x+min(a,b)-size*0.09,y:origin.y-size*0.17,width:abs(b-a)+size*0.18,height:size*1.25))
                    }
                }
                var effects=(bounds+highlights).map{$0.insetBy(dx:-margin,dy:-margin)}
                let union=(effects+highlights).reduce(CGRect.null){$0.union($1)},shift=safe.midY-union.midY
                origins=origins.map{CGPoint(x:$0.x,y:$0.y+shift)};bounds=bounds.map{$0.offsetBy(dx:0,dy:shift)};highlights=highlights.map{$0.offsetBy(dx:0,dy:shift)}
                effects=effects.map{$0.offsetBy(dx:0,dy:shift)}
                if (effects+highlights).allSatisfy({safe.contains($0)}) {return TitleComposition(lines:lines,origins:origins,bounds:bounds,highlights:highlights,safeRect:safe,effects:effects,outline:outline,depth:depth)}
            }
            size-=2
        }
        throw VideoError.review("封面标题过长、缺字或超出横版和方形共同安全区，请精简标题后重新制作")
    }
    /// Keep original UTF16 ranges so emphasis and stored wording never change.
    /// Punctuation is a strong phrase boundary; negation and keyword interiors
    /// are never sacrificed just to fill a greedy text column.
    static func titleArrangements(_ value:String,emphasis:[NSRange]=[])->[(ranges:[NSRange],penalty:CGFloat)] {
        let text=value as NSString
        if value.contains("\n") {
            var at=0,ranges:[NSRange]=[]
            for paragraph in value.components(separatedBy:"\n") {
                let count=(paragraph as NSString).length
                if count>0 {ranges.append(NSRange(location:at,length:count))}
                at+=count+1
            }
            return ranges.count<=3 ? [(ranges,0)]:[]
        }
        guard text.length>0 else{return []}
        var result:[(ranges:[NSRange],penalty:CGFloat)]=[]
        if text.length>6 {
            for boundary in 1..<text.length {
                if text.rangeOfComposedCharacterSequence(at:boundary).location != boundary {continue}
                let left=text.substring(with:NSRange(location:boundary-1,length:1)),right=text.substring(with:NSRange(location:boundary,length:1))
                if "不没无别未「『（《【".contains(left) || "，。、？！：；」』）》】".contains(right) {continue}
                if emphasis.contains(where:{$0.location<boundary && boundary<NSMaxRange($0)}) {continue}
                func latinWord(_ v:String)->Bool {v.utf16.allSatisfy{(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==95}}
                if latinWord(left) && latinWord(right) {continue}
                let punctuation="，、：；。？！".contains(left)
                result.append(([NSRange(location:0,length:boundary),NSRange(location:boundary,length:text.length-boundary)],punctuation ? -0.60:0))
            }
        }
        result.append(([NSRange(location:0,length:text.length)],text.length>6 ? 0.35:0))
        return result
    }
    private static func supported(_ lines:[CTLine],requiredFont:String?=nil)->Bool {
        for line in lines {for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes=CTRunGetAttributes(run) as NSDictionary
            guard let font=attributes[kCTFontAttributeName] as! CTFont? else {return false}
            let name=CTFontCopyPostScriptName(font) as String
            if name.localizedCaseInsensitiveContains("lastresort") || requiredFont.map({$0 != name}) == true {return false}
            let count=CTRunGetGlyphCount(run)
            var glyphs=[CGGlyph](repeating:0,count:count)
            CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs)
            if glyphs.contains(0) {return false}
        }}
        return true
    }
    private static func glyphPath(_ line:CTLine,origin:CGPoint)->CGPath {
        let path=CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes=CTRunGetAttributes(run) as NSDictionary
            guard let font=attributes[kCTFontAttributeName] as! CTFont? else {continue}
            let count=CTRunGetGlyphCount(run)
            var glyphs=[CGGlyph](repeating:0,count:count),positions=[CGPoint](repeating:.zero,count:count)
            CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs);CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
            for index in 0..<count {
                guard let glyph=CTFontCreatePathForGlyph(font,glyphs[index],nil) else {continue}
                path.addPath(glyph,transform:CGAffineTransform(translationX:origin.x+positions[index].x,y:origin.y+positions[index].y))
            }
        }
        return path
    }
    private static func paintTitle(_ value:TitleComposition,style:CoverStyle,p:Palette,c:CGContext) {
        c.saveGState();c.setLineJoin(.round)
        // The topic marker is attached to actual glyphs, never a blank panel.
        for rect in value.highlights {
            c.saveGState();c.setShadow(offset:CGSize(width:value.depth,height:-value.depth),blur:0,color:color(p.ink,alpha:0.30));c.setFillColor(color(p.accent))
            if style == .pencil {polygon([CGPoint(x:rect.minX-1,y:rect.minY+2),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX+1,y:rect.maxY-2),CGPoint(x:rect.minX,y:rect.maxY)],c:c)}
            else if style == .game {c.addPath(CGPath(roundedRect:rect,cornerWidth:rect.height*0.15,cornerHeight:rect.height*0.15,transform:nil));c.fillPath()}
            else {c.fill(rect)}
            c.restoreGState()
        }
        let edge=(style == .presenter || style == .media || style == .code) ? "071025":"FFFFFF"
        for (line,origin) in zip(value.lines,value.origins) {
            let path=glyphPath(line,origin:origin)
            for step in stride(from:3,through:1,by:-1) {
                let distance=value.depth*CGFloat(step)/3
                c.saveGState();c.translateBy(x:distance,y:-distance);c.addPath(path);c.setFillColor(color(edge));c.fillPath();c.restoreGState()
            }
            c.addPath(path);c.setStrokeColor(color(edge));c.setLineWidth(value.outline*2);c.strokePath()
            c.textMatrix = .identity;c.textPosition=origin;CTLineDraw(line,c)
        }
        c.restoreGState()
    }
    static func displayTitle(_ value:String,style:CoverStyle)->String {
        guard style == .presenter,value.hasPrefix("豆子姐讲"),let quote=value.firstIndex(of:"「") else{return value}
        return value[..<quote].trimmingCharacters(in:.whitespacesAndNewlines)+"\n"+String(value[quote...])
    }
    private static func explanation(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width,shift=CGFloat(variant-1)*d*0.035
        // Two broad folded leaves reveal real subject matter around the title.
        // Their hinge is a page fold, not an unexplained causal arrow.
        c.setFillColor(color(p.accent,alpha:0.30))
        polygon([CGPoint(x:0,y:0),CGPoint(x:canvas.midX-d*0.10,y:0),CGPoint(x:canvas.midX-d*0.32,y:s.minY+d*0.43),CGPoint(x:0,y:s.minY+d*0.83)],c:c)
        c.setFillColor(color(p.secondary,alpha:0.16))
        polygon([CGPoint(x:canvas.width,y:canvas.height),CGPoint(x:canvas.midX+d*0.09,y:canvas.height),CGPoint(x:canvas.midX+d*0.32,y:s.minY+d*0.62),CGPoint(x:canvas.width,y:s.minY+d*0.18)],c:c)
        let left=CGRect(x:max(8,s.minX-d*0.35),y:s.minY+d*0.025+shift,width:min(d*0.65,canvas.width*0.46),height:d*0.49)
        let right=CGRect(x:min(canvas.width-d*0.62-8,s.maxX-d*0.24),y:s.minY+d*0.52-shift,width:d*0.62,height:d*0.47)
        pairedArtwork(image,leading:left,trailing:right,c:c)
        c.setStrokeColor(color(p.ink,alpha:0.16));c.setLineWidth(d*0.003)
        c.move(to:CGPoint(x:0,y:s.minY+d*0.83));c.addLine(to:CGPoint(x:canvas.midX-d*0.32,y:s.minY+d*0.43));c.strokePath()
        if variant == 2 {c.setFillColor(color(p.accent,alpha:0.22));c.fillEllipse(in:CGRect(x:canvas.midX-d*0.33,y:s.minY+d*0.77,width:d*0.66,height:d*0.20))}
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func pencil(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,p:Palette,c:CGContext) {
        let d=s.width,shift=CGFloat(variant-1)*d*0.04
        gradient(canvas,colors:[color("F0D0AE"),color("F9EACF"),color("DBE8D4")],locations:[0,0.53,1],c:c)
        // Broad colored sheets and dry-pencil grain form a paper stage. The
        // actual illustration is a large subject even when supplied as hero.
        c.setFillColor(color("D29E7B",alpha:0.45))
        polygon([CGPoint(x:0,y:0),CGPoint(x:canvas.width,y:0),CGPoint(x:canvas.width,y:s.minY+d*0.22),CGPoint(x:canvas.midX+d*0.28,y:s.minY+d*0.34),CGPoint(x:0,y:s.minY+d*0.16)],c:c)
        c.setFillColor(color(p.secondary,alpha:0.38))
        polygon([CGPoint(x:0,y:canvas.height),CGPoint(x:canvas.width,y:canvas.height),CGPoint(x:canvas.width,y:s.minY+d*0.83+shift),CGPoint(x:canvas.midX-d*0.23,y:s.minY+d*0.74),CGPoint(x:0,y:s.minY+d*0.87)],c:c)
        paperGrain(canvas,ink:p.ink,c:c)
        let subject=CGRect(x:canvas.midX-d*0.58+shift,y:s.minY-d*0.14,width:d*1.16,height:d*1.14)
        c.saveGState();c.setShadow(offset:CGSize(width:d*0.025,height:-d*0.025),blur:d*0.024,color:color("74533A",alpha:0.25))
        material(hero ?? image,in:subject,c:c);c.restoreGState()
        if hero != nil,let image {
            c.saveGState();c.setAlpha(0.30);draw(image,in:canvas,fill:true,context:c);c.restoreGState()
        }
        // A deckled strip is this style's physical paper foreground. Its shape
        // follows the centered title instead of becoming a shared opaque card.
        let top=titleBounds.maxY+d*0.025,bottom=titleBounds.minY-d*0.025
        c.saveGState();c.setShadow(offset:CGSize(width:0,height:-d*0.008),blur:d*0.008,color:color("6C4F39",alpha:0.17));c.setFillColor(color("FFF9E9",alpha:0.96))
        polygon([CGPoint(x:0,y:bottom+d*0.035),CGPoint(x:canvas.width*0.23,y:bottom-d*0.008),CGPoint(x:canvas.midX,y:bottom+d*0.004),CGPoint(x:canvas.width*0.76,y:bottom-d*0.020),CGPoint(x:canvas.width,y:bottom+d*0.025),CGPoint(x:canvas.width,y:top-d*0.025),CGPoint(x:canvas.width*0.72,y:top+d*0.010),CGPoint(x:canvas.midX,y:top),CGPoint(x:canvas.width*0.21,y:top+d*0.025),CGPoint(x:0,y:top-d*0.015)],c:c);c.restoreGState()
        for i in 0..<23 {
            let x=CGFloat(i)*canvas.width/22
            c.setStrokeColor(color(i%3==0 ? p.secondary:p.accent,alpha:0.42));c.setLineWidth(d*(i%2==0 ? 0.002:0.001))
            c.move(to:CGPoint(x:x-d*0.045,y:s.minY+d*0.94+CGFloat(i%4)*d*0.008));c.addLine(to:CGPoint(x:x+d*0.06,y:s.minY+d*0.98));c.strokePath()
        }
    }
    private static func presenter(_ image:CGImage?,hero:CGImage?,placement:HeroPlacement,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        gradient(canvas,colors:[color("03091D"),color("172F6A"),color("07112D")],locations:[0,0.55,1],c:c)
        glow(canvas,center:CGPoint(x:canvas.midX+CGFloat(variant-1)*d*0.19,y:s.minY+d*0.63),radius:d*0.85,ink:"4988D1",alpha:0.35,c:c)
        c.saveGState();c.setShadow(offset:.zero,blur:d*0.05,color:color("6297D5",alpha:0.18));c.setFillColor(color("27477C",alpha:0.55))
        c.fillEllipse(in:CGRect(x:canvas.midX-d*0.92,y:s.minY-d*0.28,width:d*1.84,height:d*0.49));c.restoreGState()
        if let image {
            let propX=variant == 1 ? canvas.midX+d*0.16:canvas.midX-d*0.82
            c.saveGState();c.setShadow(offset:CGSize(width:d*0.018,height:-d*0.018),blur:d*0.022,color:color("000000",alpha:0.70))
            draw(image,in:CGRect(x:propX,y:s.minY+d*0.035,width:d*0.66,height:d*0.93),fill:false,context:c);c.restoreGState()
        }
        glow(canvas,center:CGPoint(x:canvas.midX,y:canvas.midY),radius:d*0.53,ink:"0A183C",alpha:0.82,c:c)
        if let hero {c.saveGState();c.setShadow(offset:CGSize(width:d*0.012,height:-d*0.012),blur:d*0.016,color:color("000000",alpha:0.6));draw(hero,in:placement.rect,fill:false,mirrored:placement.mirrored,context:c);c.restoreGState()}
    }
    static func gameDepthLayout(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect)->GameDepthLayout {
        let d=s.width,available=max(d*0.18,titleBounds.minY-s.minY-d*0.025)
        let height=min(d*0.40,available),heroWidth=d*0.36
        let aperture=CGRect(x:canvas.midX-d*0.85+CGFloat(variant-1)*d*0.012,y:s.minY+d*0.075,width:d*1.70,height:d*0.86)
        let x=variant == 1 ? max(d*0.04,s.minX-d*0.16):min(canvas.width-heroWidth-d*0.04,s.maxX-d*0.18)
        let hero=CGRect(x:x,y:s.minY+d*0.025,width:heroWidth,height:height)
        return GameDepthLayout(aperture:aperture,hero:hero,frontLip:CGRect(x:aperture.minX-d*0.035,y:aperture.minY,width:aperture.width+d*0.07,height:d*0.026))
    }
    private static func game(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,p:Palette,c:CGContext) {
        let d=s.width,layout=gameDepthLayout(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds),a=layout.aperture
        gradient(canvas,colors:[color("B9DAD0"),color(p.paper),color("F6FAE8")],locations:[0,0.54,1],c:c)
        let inset=d*(variant == 2 ? 0.025:0.012)
        let opening=[CGPoint(x:a.minX,y:a.minY),CGPoint(x:a.maxX,y:a.minY),CGPoint(x:a.maxX-inset,y:a.maxY),CGPoint(x:a.minX+inset,y:a.maxY)]
        c.saveGState();c.setShadow(offset:CGSize(width:0,height:-d*0.022),blur:d*0.025,color:color("254E40",alpha:0.32));c.setFillColor(color("F8F7D8"));polygon(opening,c:c);c.restoreGState()
        // A flat-design aperture contains the real set. The independent original
        // character crosses it; no photographic card or replacement IP is drawn.
        c.saveGState();c.addLines(between:opening);c.closePath();c.clip()
        if let image {draw(image,in:a.insetBy(dx:inset+d*0.012,dy:d*0.012),fill:false,context:c)}
        c.restoreGState()
        c.setStrokeColor(color("FCFFF1"));c.setLineWidth(d*0.012);c.addLines(between:opening);c.closePath();c.strokePath()
        if let hero {
            c.setFillColor(color("173C34",alpha:0.25));c.fillEllipse(in:CGRect(x:layout.hero.midX-d*0.18,y:s.minY+d*0.005,width:d*0.36,height:d*0.055))
            c.saveGState();c.setShadow(offset:CGSize(width:d*0.015,height:-d*0.015),blur:d*0.012,color:color("173C34",alpha:0.24));draw(hero,in:layout.hero,fill:false,context:c);c.restoreGState()
        }
        // This foreground lip is intentionally painted AFTER the actor. One
        // body part comes forward while another passes behind a real plane.
        c.setFillColor(color(p.secondary));c.fill(layout.frontLip)
        c.setFillColor(color("E7F3CC"));polygon([CGPoint(x:layout.frontLip.minX,y:layout.frontLip.maxY),CGPoint(x:layout.frontLip.maxX,y:layout.frontLip.maxY),CGPoint(x:layout.frontLip.maxX-d*0.035,y:layout.frontLip.maxY+d*0.014),CGPoint(x:layout.frontLip.minX+d*0.035,y:layout.frontLip.maxY+d*0.014)],c:c)
        if variant == 2 {c.setStrokeColor(color("FFFFFF",alpha:0.60));c.setLineWidth(d*0.003);c.strokeEllipse(in:layout.frontLip.insetBy(dx:-d*0.06,dy:-d*0.045))}
    }
    private static func cartoon(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        c.setFillColor(color(p.secondary));polygon([CGPoint(x:0,y:0),CGPoint(x:canvas.width*0.44,y:0),CGPoint(x:canvas.width*0.32,y:canvas.height),CGPoint(x:0,y:canvas.height)],c:c)
        for row in 0..<9 {for column in 0..<11 {c.setFillColor(color(p.ink,alpha:0.12));c.fillEllipse(in:CGRect(x:CGFloat(column)*d*0.070+12,y:canvas.height-d*0.070*CGFloat(row)-18,width:d*0.009,height:d*0.009))}}
        c.setStrokeColor(color(p.ink,alpha:0.18));c.setLineWidth(d*0.005)
        for index in 0..<14 {
            let angle=CGFloat(index)*CGFloat.pi/7+CGFloat(variant)*0.08
            c.move(to:CGPoint(x:canvas.midX+cos(angle)*d*0.46,y:canvas.midY+sin(angle)*d*0.32));c.addLine(to:CGPoint(x:canvas.midX+cos(angle)*d,y:canvas.midY+sin(angle)*d));c.strokePath()
        }
        let left=CGRect(x:max(0,s.minX-d*0.30),y:s.minY-d*0.015,width:d*0.68,height:d*0.62)
        let right=CGRect(x:min(canvas.width-d*0.65,s.maxX-d*0.28),y:s.minY+d*0.48,width:d*0.65,height:d*0.53)
        pairedArtwork(image,leading:left,trailing:right,c:c)
        var burst:[CGPoint]=[]
        for i in 0..<24 {
            let angle=CGFloat(i)*CGFloat.pi/12,outer=i%2==0
            let rx=d*(outer ? 0.56:0.48),ry=d*(outer ? 0.22:0.175)
            burst.append(CGPoint(x:canvas.midX+cos(angle)*rx,y:canvas.midY+sin(angle)*ry+CGFloat(variant-1)*d*0.008))
        }
        c.setFillColor(color("FFFFFF"));polygon(burst,c:c)
        c.setStrokeColor(color(p.ink));c.setLineWidth(d*0.004);c.addLines(between:burst);c.closePath();c.strokePath()
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func media(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        if let image {draw(image,in:canvas,fill:true,context:c)}
        // Photography owns this canvas. Exposure and a restrained colored edge
        // create a film still, not a fake camera interface or editor window.
        gradient(canvas,colors:[color(p.paper,alpha:0.20),color(p.paper,alpha:0.80),color(p.paper,alpha:0.14)],locations:[0,0.50,1],c:c)
        if variant == 1 {
            let edge=canvas.width*0.24
            c.setFillColor(color(p.accent,alpha:0.14));polygon([CGPoint(x:0,y:0),CGPoint(x:edge,y:0),CGPoint(x:edge+d*0.18,y:canvas.height),CGPoint(x:0,y:canvas.height)],c:c)
        } else if variant == 2 {
            c.setFillColor(color(p.paper,alpha:0.90));c.fill(CGRect(x:0,y:0,width:canvas.width,height:d*0.065));c.fill(CGRect(x:0,y:canvas.height-d*0.065,width:canvas.width,height:d*0.065))
        } else {c.setFillColor(color(p.accent,alpha:0.35));c.fill(CGRect(x:0,y:canvas.height-d*0.012,width:canvas.width,height:d*0.012))}
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func chart(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,revision:Revision,p:Palette,c:CGContext)throws {
        let d=s.width
        c.setStrokeColor(color(p.secondary,alpha:0.10));c.setLineWidth(1)
        for i in 1..<12 {let x=canvas.width*CGFloat(i)/12;c.move(to:CGPoint(x:x,y:0));c.addLine(to:CGPoint(x:x,y:canvas.height));c.strokePath()}
        let actual=revision.scenes.flatMap{$0.layers ?? []}.compactMap{$0.dataPresentation?.chart}.first
        // Values come only from actual editable chart data. Missing data uses a
        // large author illustration, never invented bars or invented trends.
        if let actual {
            try actual.validate()
            let series=actual.series,span=max(0.000001,actual.maximum-actual.minimum)
            let left=max(d*0.04,s.minX-d*0.28),bottom=s.minY+d*0.04,width=min(canvas.width-d*0.08,d*1.48)
            let step=width/CGFloat(max(1,series.count)),barWidth=min(d*0.22,step*0.65)
            for (index,series) in series.enumerated() {
                guard let value=series.keyframes.last?.value else {continue}
                let normalized=CGFloat((value-actual.minimum)/span),height=d*0.28*normalized
                let x=left+step*(CGFloat(index)+0.5)-barWidth/2
                c.setFillColor(color(series.color));c.fill(CGRect(x:x,y:bottom,width:barWidth,height:height))
                if variant != 1 {c.setFillColor(color(p.ink,alpha:0.16));polygon([CGPoint(x:x+barWidth,y:bottom),CGPoint(x:x+barWidth+d*0.02,y:bottom+d*0.015),CGPoint(x:x+barWidth+d*0.02,y:bottom+height+d*0.015),CGPoint(x:x+barWidth,y:bottom+height)],c:c)}
            }
            material(image,in:CGRect(x:canvas.midX-d*0.48,y:s.minY+d*0.67,width:d*0.96,height:d*0.31),c:c)
        } else {
            c.setFillColor(color(p.accent,alpha:0.38));c.fillEllipse(in:CGRect(x:canvas.midX-d*(0.64-Double(variant)*0.025),y:s.minY+d*0.02,width:d*1.28,height:d*0.35))
            material(image,in:CGRect(x:canvas.midX-d*0.70,y:s.minY+d*0.005,width:d*1.40,height:d*0.39),c:c)
        }
        c.setStrokeColor(color(p.ink,alpha:0.35));c.setLineWidth(d*0.004)
        c.move(to:CGPoint(x:0,y:s.minY+d*0.04));c.addLine(to:CGPoint(x:canvas.width,y:s.minY+d*0.04));c.strokePath()
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    private static func code(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,revision:Revision,p:Palette,c:CGContext)throws {
        let d=s.width
        gradient(canvas,colors:[color("041B1B"),color("123D35"),color("061C24")],locations:[0,0.52,1],c:c)
        glow(canvas,center:CGPoint(x:canvas.midX+CGFloat(variant-1)*d*0.21,y:s.minY+d*0.70),radius:d*0.83,ink:"286B5D",alpha:0.60,c:c)
        let stage=CGRect(x:canvas.midX-d*0.75,y:s.minY+d*0.025,width:d*1.50,height:d*0.30)
        let actual=revision.scenes.flatMap{$0.layers ?? []}.compactMap{$0.dataPresentation?.code}.first
        if let actual {
            try actual.validate()
            let lines=try codeLines(actual,in:stage,maximumSize:d*0.058)
            let runs=lines.flatMap{CTLineGetGlyphRuns($0) as! [CTRun]}
            guard let run=runs.first,let font=(CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont? else {throw VideoError.review("实际代码前三行没有可见文字")}
            let size=CTFontGetSize(font)
            let step=size*1.65,total=step*CGFloat(lines.count-1)
            for (index,line) in lines.enumerated() {
                let width=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
                c.textMatrix = .identity
                c.textPosition=CGPoint(x:stage.midX-width/2,y:stage.midY+total/2-size*0.32-CGFloat(index)*step)
                CTLineDraw(line,c)
            }
        } else {
            // An actual subject image remains the single content object. The
            // multiply blend removes its white-document appearance without
            // inventing code, UI controls, arrows or a second source window.
            c.setFillColor(color("BDE0C2"))
            polygon([CGPoint(x:0,y:0),CGPoint(x:canvas.width,y:0),CGPoint(x:canvas.width,y:stage.maxY-d*0.045),CGPoint(x:canvas.midX+d*0.36,y:stage.maxY+d*0.015),CGPoint(x:0,y:stage.maxY-d*0.010)],c:c)
            c.saveGState();c.setBlendMode(.multiply);material(hero ?? image,in:stage,c:c);c.restoreGState()
            if image != nil,hero != nil {
                c.saveGState();c.setAlpha(0.22);c.setBlendMode(.multiply);material(image,in:stage,c:c);c.restoreGState()
            }
        }
    }
    static func codeLines(_ actual:CodePresentation,in rect:CGRect,maximumSize:CGFloat)throws->[CTLine] {
        try actual.validate()
        let values=Array(actual.lines.prefix(3))
        guard values.contains(where:{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else {throw VideoError.review("实际代码前三行没有可见文字")}
        var size=maximumSize
        while size>=12 {
            let font=CTFontCreateWithName("Menlo-Bold" as CFString,size,nil)
            guard CTFontCopyPostScriptName(font) as String == "Menlo-Bold" else {throw VideoError.review("代码封面需要实际等宽字体")}
            var lines:[CTLine]=[]
            for value in values {
                let text=NSMutableAttributedString(string:value,attributes:[.init(kCTFontAttributeName as String):font,.init(kCTForegroundColorAttributeName as String):color("E2F6E9")])
                let patterns=[("(?<![A-Za-z0-9_])(if|else|elif|for|while|return|def|let|var|func|true|false|True|False|None|in)(?![A-Za-z0-9_])","FFB884"),("[0-9]+(?:\\.[0-9]+)?","FFE88E"),("\"[^\"]*\"|'[^']*'","9DE2C5")]
                for (pattern,ink) in patterns {
                    let regex=try NSRegularExpression(pattern:pattern)
                    for match in regex.matches(in:value,range:NSRange(location:0,length:(value as NSString).length)) {text.addAttribute(.init(kCTForegroundColorAttributeName as String),value:color(ink),range:match.range)}
                }
                lines.append(CTLineCreateWithAttributedString(text))
            }
            if supported(lines),lines.allSatisfy({CGFloat(CTLineGetTypographicBounds($0,nil,nil,nil))<=rect.width}),size*1.65*CGFloat(lines.count)<=rect.height {return lines}
            size-=1
        }
        throw VideoError.review("实际代码前三行无法完整放入封面，请选择更简短的真实代码素材")
    }
    static func presenterPlacement(square s:CGRect,variant:Int,titleBounds:CGRect,pointing:CoverPointing?)->HeroPlacement {
        let d=s.width,canvasWidth=d+s.minX*2,width=d*0.40
        let height=min(d*0.42,max(d*0.18,titleBounds.minY-s.minY-d*0.035))
        let x=variant == 1 ? max(d*0.025,s.minX-d*0.24):min(canvasWidth-width-d*0.025,s.maxX-d*0.16)
        let rect=CGRect(x:x,y:s.minY+d*0.01,width:width,height:height)
        let target:CoverPointing=rect.midX<titleBounds.midX ? .right:.left
        return HeroPlacement(rect:rect,target:target,mirrored:pointing.map{$0 != target} ?? false)
    }
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
        var empty:Int?
        var bestDistance=Int.max
        for column in (first+1)..<last where !occupied[column] {
            let distance=abs(column-center)
            if distance<bestDistance {
                empty=column
                bestDistance=distance
            }
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
    private static func glow(_ rect:CGRect,center:CGPoint,radius:CGFloat,ink:String,alpha:CGFloat,c:CGContext) {
        guard let gradient=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:[color(ink,alpha:alpha),color(ink,alpha:0)] as CFArray,locations:[0,1]) else{return}
        c.saveGState();c.clip(to:rect);c.drawRadialGradient(gradient,startCenter:center,startRadius:0,endCenter:center,endRadius:radius,options:[]);c.restoreGState()
    }
    private static func paperGrain(_ rect:CGRect,ink:String,c:CGContext) {
        c.saveGState();c.setStrokeColor(color(ink,alpha:0.055));c.setLineWidth(0.6)
        for row in 0..<33 {for column in 0..<49 {
            let seed=(row*37+column*19)%23
            let x=rect.minX+CGFloat(column)*rect.width/48+CGFloat(seed%5)-2
            let y=rect.minY+CGFloat(row)*rect.height/32+CGFloat(seed%7)-3
            c.move(to:CGPoint(x:x,y:y));c.addLine(to:CGPoint(x:x+CGFloat(2+seed%7),y:y+CGFloat(seed%3)-1));c.strokePath()
        }}
        c.restoreGState()
    }
    private static func material(_ image:CGImage?,in rect:CGRect,c:CGContext) {if let image {draw(image,in:rect,fill:false,context:c)}}
    private static func polygon(_ points:[CGPoint],c:CGContext) {guard let first=points.first else{return};c.move(to:first);for point in points.dropFirst(){c.addLine(to:point)};c.closePath();c.fillPath()}
    private static func draw(_ image:CGImage,in rect:CGRect,fill:Bool,mirrored:Bool=false,context c:CGContext) {
        let factor=fill ? max(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height)):min(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height))
        let box=CGRect(x:rect.midX-CGFloat(image.width)*factor/2,y:rect.midY-CGFloat(image.height)*factor/2,width:CGFloat(image.width)*factor,height:CGFloat(image.height)*factor)
        c.saveGState();c.clip(to:rect)
        if mirrored {c.translateBy(x:rect.midX*2,y:0);c.scaleBy(x:-1,y:1)}
        c.interpolationQuality = .high;c.draw(image,in:box);c.restoreGState()
    }
    private static func color(_ hex:String,alpha:CGFloat=1)->CGColor {
        let v=UInt32(hex,radix:16) ?? 0
        return CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[CGFloat((v>>16)&255)/255,CGFloat((v>>8)&255)/255,CGFloat(v&255)/255,alpha])!
    }
}
