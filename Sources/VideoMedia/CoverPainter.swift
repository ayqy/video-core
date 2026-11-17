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
            case .presenter:(paper,ink,accent,secondary)=("082A78","FFFFFF","FF985D","1678EC")
            case .pencil:(paper,ink,accent,secondary)=("C52654","FFFFFF","63F0E4","F76788")
            case .game:(paper,ink,accent,secondary)=("F7F3DF","725D42","117E70","E6F9F6")
            case .cartoon:(paper,ink,accent,secondary)=("F2E9FF","38274F","C63B67","A6E8E1")
            case .media:(paper,ink,accent,secondary)=("101B28","FFFFFF","F7A56F","417F8B")
            case .chart:(paper,ink,accent,secondary)=("F1F3FE","21305B","6B3EB5","6386D9")
            case .code:(paper,ink,accent,secondary)=("F8F8F0","725D42","117E70","E6F9F6")
            default:(paper,ink,accent,secondary)=("F6F3EF","24384F","BB4024","EB755B")
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
        let hero=try selected(cover.hero).map { image in
            let visible=try visibleArtwork(image)
            return cover.style == .presenter ? try presenterArtwork(visible):visible
        }
        let explicitBackground=try selected(cover.background)
        // A dedicated IP never reveals an unrelated face or movie subtitles.
        let background=explicitBackground ?? (hero == nil ? source:nil)
        let canvas=CGRect(x:0,y:0,width:w,height:h),p=Palette(cover.style),side=CGFloat(min(w,h))
        let square=CGRect(x:canvas.midX-side/2,y:canvas.midY-side/2,width:side,height:side)
        let variant=cover.template == .editorial ? 1:(cover.template == .contrast ? 2:0)
        let composition=try composeTitle(cover:cover,width:canvas.width,height:canvas.height)
        let placement=presenterPlacement(square:square,variant:variant,titleBounds:composition.visibleBounds,
            pointing:cover.hero?.pointing,imageAspect:hero.map{CGFloat($0.width)/CGFloat($0.height)})
        c.setFillColor(color(p.paper));c.fill(canvas)
        switch cover.style {
        case .pencil:try pencil(background,hero:hero,square:square,canvas:canvas,variant:variant,titleBounds:composition.visibleBounds,p:p,c:c)
case .presenter:presenter(background,hero:hero,placement:placement,square:square,canvas:canvas,variant:variant,titleBounds:composition.visibleBounds,p:p,c:c)
        case .game:try game(background,hero:hero,square:square,canvas:canvas,variant:variant,titleBounds:composition.visibleBounds,p:p,c:c)
        case .cartoon:cartoon(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .media:media(background,hero:hero,square:square,canvas:canvas,variant:variant,p:p,c:c)
        case .chart:try chart(background,hero:hero,square:square,canvas:canvas,variant:variant,revision:revision,p:p,c:c)
        case .code:try code(background,hero:hero,square:square,canvas:canvas,variant:variant,revision:revision,quantity:cover.quantityGraphic,p:p,c:c)
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
        let commonSafe=titleSafeRect(width:width,height:height),side=min(width,height),p=Palette(cover.style)
        // Keep the complete title on the admitted board's large paper, even
        // inside a portrait channel crop. The center remains the shared center.
        let safe=cover.style == .game ? commonSafe.insetBy(dx:commonSafe.width*0.10,dy:0):commonSafe
        let display=titleDisplay(cover.title,style:cover.style),value=display.text,original=cover.title as NSString
        var ranges:[NSRange]=[]
        for keyword in cover.emphasis {
            var search=NSRange(location:0,length:original.length)
            while search.length>0 {
                let range=original.range(of:keyword,options:[],range:search);if range.location==NSNotFound {break}
                let start=display.indices[range.location],end=display.indices[range.location+range.length]
                if end>start {ranges.append(NSRange(location:start,length:end-start))}
                search=NSRange(location:range.location+range.length,length:original.length-range.location-range.length)
            }
        }
        // A bold source font already supplies its intended strokes. Added
        // inside strokes/extruded copies close the counters of dense Chinese
        // glyphs such as 境, especially in a channel's reduced thumbnail.
        let depth:CGFloat=0,outline:CGFloat=0,margin=side*0.004
        let kern=side*0.001
        let shortGameTitle=cover.style == .game && value.count<=9 && !value.contains("\n")
            && value.rangeOfCharacter(from:CharacterSet(charactersIn:"，,、：:；;。")) == nil
        let phraseArrangements=titleArrangements(value,emphasis:ranges)
        let singleLine:[(ranges:[NSRange],penalty:CGFloat)]=[([NSRange(location:0,length:(value as NSString).length)],0)]
        let passes=shortGameTitle ? [singleLine,phraseArrangements]:[phraseArrangements]
        // A programming-topic cover has no character portrait to carry the
        // subject. Let its short headline lead; long copy still shrinks only
        // after shaping into complete phrases in the shared preview-safe area.
        let baseSize:CGFloat=cover.style == .code ? 0.14:0.112
        // Preserve readable single-line short topics whenever the complete
        // artwork fits; only then try legal phrase breaks for a tight crop.
        for arrangements in passes {
        var size=side*(shortGameTitle ? 0.09:baseSize)
        while size>=side*0.042 {
            let rounded=cover.style == .game || cover.style == .code
            let normal=try (rounded ? IslandTypeface.font(size:size):CoverTypeface.displayFont(size:size))
            let emphasized=try (rounded ? IslandTypeface.font(size:size*1.17):CoverTypeface.displayFont(size:size*1.17))
            let title=NSMutableAttributedString(string:value,attributes:[.init(kCTFontAttributeName as String):normal,.init(kCTKernAttributeName as String):kern,.init(kCTForegroundColorAttributeName as String):color(p.ink)])
            // Keep the existing host attribution readable, while giving the
            // actual subject the first visual read. The title stays centered
            // and the emphasized topic keeps its existing width, so the real
            // pointing portrait is not pushed farther beyond the canvas edge.
            if cover.style == .presenter,value.hasPrefix("豆子姐讲") {
                let attribution=try CoverTypeface.displayFont(size:size*0.75)
                title.addAttribute(.init(kCTFontAttributeName as String),value:attribution,
                                   range:NSRange(location:0,length:("豆子姐讲" as NSString).length))
            }
            let keywordInk=cover.style == .presenter ? color("071638"):color(p.accent)
            for range in ranges {title.addAttributes([.init(kCTFontAttributeName as String):emphasized,.init(kCTForegroundColorAttributeName as String):keywordInk],range:range)}
            let typesetter=CTTypesetterCreateWithAttributedString(title)
            var candidates:[(lines:[CTLine],score:CGFloat)]=[]
            for arrangement in arrangements {
                let lines=arrangement.ranges.map{CTTypesetterCreateLine(typesetter,CFRange(location:$0.location,length:$0.length))}
                let widths=lines.map{CGFloat(CTLineGetTypographicBounds($0,nil,nil,nil))}
                guard !lines.isEmpty,widths.allSatisfy({$0<=safe.width-margin*2}),supported(lines,requiredFont:rounded ? "ChillRoundF":CoverTypeface.displayPostScriptName) else {continue}
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
                if (effects+highlights).allSatisfy({safe.contains($0)}) {
                    let composed=TitleComposition(lines:lines,origins:origins,bounds:bounds,highlights:highlights,safeRect:safe,effects:effects,outline:outline,depth:depth)
                    if cover.style == .game {
                        let canvas=CGRect(x:0,y:0,width:width,height:height)
                        let square=CGRect(x:canvas.midX-side/2,y:canvas.midY-side/2,width:side,height:side)
                        let variant=cover.template == .editorial ? 1:(cover.template == .contrast ? 2:0)
                        let artwork=gameNoticeBoardImageFrame(square:square,canvas:canvas,variant:variant,titleBounds:composed.visibleBounds)
                        guard canvas.insetBy(dx:side*0.02,dy:side*0.02).contains(artwork) else {continue}
                    }
                    return composed
                }
            }
            size-=2
        }
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
    private static func paintTitle(_ value:TitleComposition,style:CoverStyle,p:Palette,c:CGContext) {
        c.saveGState();c.setShouldAntialias(true)
        // Presenter topics use a high-contrast advertising color field. Keep
        // the original glyphs and title geometry: no added strokes close the
        // counters, and the existing title/gesture relationship stays intact.
        if style == .presenter {
            c.setFillColor(color(p.accent))
            for rect in value.highlights {
                let radius=rect.height*0.075
                c.addPath(CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil));c.fillPath()
            }
        }
        if style == .code {
            for rect in value.highlights {IslandTheme.drawPill(in:rect,fill:p.secondary,context:c)}
        }
        for (line,origin) in zip(value.lines,value.origins) {
            c.textMatrix = .identity;c.textPosition=origin;CTLineDraw(line,c)
        }
        c.restoreGState()
    }
    static func displayTitle(_ value:String,style:CoverStyle)->String {
        titleDisplay(value,style:style).text
    }
    private static func titleDisplay(_ value:String,style:CoverStyle)->(text:String,indices:[Int]) {
        let prefix="豆子姐讲",prefixLength=(prefix as NSString).length
        let separate=style == .presenter && value.hasPrefix(prefix) && !value.hasPrefix(prefix+"\n")
        var text="",indices=[Int](repeating:0,count:(value as NSString).length+1),original=0,displayed=0,didSeparate=false
        for character in value {
            if separate,!didSeparate,original>=prefixLength {
                text+="\n";displayed+=1;didSeparate=true
            }
            let scalar=String(character),length=(scalar as NSString).length
            for index in original..<(original+length) {indices[index]=displayed}
            if !"「」『』".contains(character) {text+=scalar;displayed+=(scalar as NSString).length}
            original+=length;indices[original]=displayed
        }
        return(text,indices)
    }
    private static func explanation(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width,shift=CGFloat(variant-1)*d*0.035
        // Large opposing color fields and real objects form an explanatory
        // poster. There is no paper fold, floating window or decorative arrow.
        c.setFillColor(color(p.accent,alpha:0.60))
        c.fillEllipse(in:CGRect(x:-d*0.40,y:s.minY-d*0.28,width:d*1.30,height:d*1.30))
        c.setFillColor(color(p.secondary,alpha:0.50))
        c.fillEllipse(in:CGRect(x:canvas.width-d*0.78,y:s.minY+d*0.34,width:d*1.10,height:d*1.10))
        let left=CGRect(x:max(8,s.minX-d*0.35),y:s.minY+d*0.025+shift,width:min(d*0.65,canvas.width*0.46),height:d*0.49)
        let right=CGRect(x:min(canvas.width-d*0.62-8,s.maxX-d*0.24),y:s.minY+d*0.52-shift,width:d*0.62,height:d*0.47)
        pairedArtwork(image,leading:left,trailing:right,c:c)
        if variant == 2 {c.setFillColor(color(p.accent,alpha:0.22));c.fillEllipse(in:CGRect(x:canvas.midX-d*0.33,y:s.minY+d*0.77,width:d*0.66,height:d*0.20))}
        auxiliary(hero,square:s,variant:variant,c:c)
    }
    static func pencilArtworkRect(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,imageAspect:CGFloat)->CGRect {
        let d=s.width,shift=CGFloat(variant-1)*d*0.055,gap=d*0.065,edge=d*0.025
        let width:CGFloat,height:CGFloat
        if canvas.width>=canvas.height {
            width=min(d*0.66,max(d*0.08,titleBounds.minX-gap-edge),(d*0.92)*imageAspect)
            height=width/imageAspect
            return CGRect(x:max(edge,titleBounds.minX-gap-width),y:s.midY-height/2+shift*0.14,width:width,height:height)
        }
        height=min(d*0.86,max(d*0.08,canvas.maxY-edge-titleBounds.maxY-gap),(d*0.76)/imageAspect)
        width=height*imageAspect
        return CGRect(x:canvas.midX-width/2+shift*0.30,y:titleBounds.maxY+gap,width:width,height:height)
    }
    static func pencilCounterpartRect(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,primary:CGRect,imageAspect:CGFloat)throws->CGRect {
        guard imageAspect.isFinite,imageAspect>0 else {throw VideoError.invalid("彩铅第二主体须有有效完整原图比例")}
        let d=s.width,shift=CGFloat(variant-1)*d*0.055,gap=d*0.065,edge=d*0.025
        let width:CGFloat,height:CGFloat,rect:CGRect
        if canvas.width>canvas.height {
            let available=canvas.maxX-edge-titleBounds.maxX-gap
            height=min(d*0.92,available/imageAspect);width=height*imageAspect
            rect=CGRect(x:titleBounds.maxX+gap,y:s.midY-height/2+shift*0.14,width:width,height:height)
        } else {
            height=min(d*0.86,titleBounds.minY-gap-edge,(d*0.76)/imageAspect);width=height*imageAspect
            rect=CGRect(x:canvas.midX-width/2-shift*0.30,y:titleBounds.minY-gap-height,width:width,height:height)
        }
        guard width.isFinite,height.isFinite,width>=d*0.08,height>=d*0.08,
              canvas.contains(primary),canvas.contains(rect),!primary.intersects(titleBounds),
              !rect.intersects(titleBounds),!rect.intersects(primary) else {
            throw VideoError.invalid("彩铅双主体没有完整且清楚的独立空间，请缩短标题或调整画幅")
        }
        return rect
    }
    private static func pencil(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,p:Palette,c:CGContext)throws {
        let d=s.width,shift=CGFloat(variant-1)*d*0.055
        gradient(canvas,colors:[color("291329"),color("64243F"),color("24152F")],locations:[0,0.49,1],c:c)
        // A lit subject and a quiet headline occupy separate parts of an
        // advertising composition. Do not leave detailed bars or object edges
        // behind the centered title, or crop a connected original to clear it.
        let landscape=canvas.width>=canvas.height
        c.saveGState()
        let plane:[CGPoint]=landscape
            ? [CGPoint(x:0,y:0),CGPoint(x:max(0,titleBounds.minX-d*0.15+shift*0.20),y:0),
               CGPoint(x:max(0,titleBounds.minX-d*0.035+shift*0.20),y:canvas.height),CGPoint(x:0,y:canvas.height)]
            : [CGPoint(x:0,y:canvas.height*0.64),CGPoint(x:canvas.width,y:canvas.height*0.77),
               CGPoint(x:canvas.width,y:canvas.height),CGPoint(x:0,y:canvas.height)]
        c.addLines(between:plane);c.closePath();c.clip()
        gradient(canvas,colors:[color("8E3D58"),color("E7A18A"),color("A14B62")],locations:[0,0.64,1],c:c)
        c.restoreGState()
        guard let artwork=hero ?? image else{return}
        let aspect=CGFloat(artwork.width)/CGFloat(artwork.height)
        let subject=pencilArtworkRect(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds,imageAspect:aspect)
        glow(canvas,center:CGPoint(x:subject.midX,y:subject.midY),radius:max(subject.width,subject.height)*0.72,ink:"F4B7A0",alpha:0.23,c:c)
        c.setFillColor(color("230C24",alpha:0.38))
        c.fillEllipse(in:CGRect(x:subject.minX-d*0.025,y:subject.minY-d*0.018,width:subject.width+d*0.05,height:d*0.035))
        c.saveGState();c.setShadow(offset:CGSize(width:d*0.018,height:-d*0.014),blur:d*0.024,color:color("230C24",alpha:0.55))
        draw(artwork,in:subject,fill:false,context:c);c.restoreGState()
        if hero != nil,let image {
            // An explicitly authored second original participates as pixels,
            // not as an inferred emotion or an unrelated full-canvas wash.
            // Trimming only transparent gutters preserves every visible part.
            let counterpart=try visibleArtwork(image)
            let rect=try pencilCounterpartRect(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds,
                primary:subject,imageAspect:CGFloat(counterpart.width)/CGFloat(counterpart.height))
            c.saveGState();c.clip(to:rect.insetBy(dx:-d*0.025,dy:-d*0.025))
            c.setFillColor(color("230C24",alpha:0.38))
            c.fillEllipse(in:CGRect(x:rect.minX-d*0.025,y:rect.minY-d*0.018,width:rect.width+d*0.05,height:d*0.035))
            c.setShadow(offset:CGSize(width:d*0.018,height:-d*0.014),blur:d*0.024,color:color("230C24",alpha:0.55))
            draw(counterpart,in:rect,fill:false,context:c);c.restoreGState()
        }
    }
    static func presenterSubjectPlacement(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,heroPlacement:HeroPlacement,imageAspect:CGFloat)->CGRect {
        let d=s.width
        let propX=variant == 1 ? min(canvas.width-d*0.43,s.maxX+d*0.09):max(d*0.035,s.minX-d*0.27)
        let original=CGRect(x:propX,y:s.minY+d*0.055,width:d*0.43,height:d*0.65)
        // Only wide canvases have a useful separate subject corridor. Keep
        // square/portrait compositions and tight headlines unchanged instead
        // of shrinking a full original into a new postage-stamp placement.
        guard canvas.width>=d*1.35,imageAspect.isFinite,imageAspect>0,
              !titleBounds.isEmpty,!titleBounds.isInfinite else{return original}
        let edge=d*0.025,gap=d*0.05,heroOnLeft=heroPlacement.rect.midX<canvas.midX
        let left=heroOnLeft ? max(titleBounds.maxX,heroPlacement.rect.maxX)+gap:canvas.minX+edge
        let right=heroOnLeft ? canvas.maxX-edge:min(titleBounds.minX,heroPlacement.rect.minX)-gap
        let width=right-left
        guard width>0 else{return original}
        let previousHeight=min(original.height,original.width/imageAspect)
        let baseline=original.minY+(original.height-previousHeight)/2
        let height=min(d*0.86,canvas.maxY-edge-baseline,width/imageAspect)
        guard height>previousHeight+0.5 else{return original}
        let fittedWidth=height*imageAspect
        let candidate=CGRect(x:heroOnLeft ? left:right-fittedWidth,y:baseline,width:fittedWidth,height:height)
        guard canvas.contains(candidate),!candidate.intersects(titleBounds),!candidate.intersects(heroPlacement.rect) else{return original}
        return candidate
    }
    private static func presenter(_ image:CGImage?,hero:CGImage?,placement:HeroPlacement,square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,p:Palette,c:CGContext) {
        let d=s.width
        gradient(canvas,colors:[color("030A25"),color("10236A"),color("243C8C")],locations:[0,0.58,1],c:c)
        // Broad lit planes are a studio backdrop, with a warm key behind the
        // presenter and a cool fill behind the actual subject. Their diagonal
        // overlap gives depth without adding a frame, wiring or extra copy.
        let heroOnLeft=placement.rect.midX<canvas.midX
        c.saveGState()
        if heroOnLeft {c.translateBy(x:canvas.width,y:0);c.scaleBy(x:-1,y:1)}
        let tilt=CGFloat(variant-1)*0.035
        let plane=[CGPoint(x:canvas.width*(0.63+tilt),y:0),CGPoint(x:canvas.width,y:0),
                   CGPoint(x:canvas.width,y:canvas.height),CGPoint(x:canvas.width*(0.87-tilt),y:canvas.height)]
        c.addLines(between:plane);c.closePath();c.clip()
        gradient(canvas,colors:[color("9E355C"),color("F17F79"),color("FFBC9D")],locations:[0,0.60,1],c:c)
        c.restoreGState()
        glow(canvas,center:CGPoint(x:placement.rect.midX,y:s.minY+d*0.68),radius:d*0.63,ink:"FC968B",alpha:0.28,c:c)
        let aspect=image.map{CGFloat($0.width)/CGFloat($0.height)} ?? 1
        let originalProp=presenterSubjectPlacement(square:s,canvas:canvas,variant:variant,titleBounds:.zero,heroPlacement:placement,imageAspect:aspect)
        let prop=hero == nil ? originalProp
            :presenterSubjectPlacement(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds,heroPlacement:placement,imageAspect:aspect)
        // Preserve the original studio fill under the title and teaching IP.
        // Only the original story pixels and their ground shadow move.
        glow(canvas,center:CGPoint(x:originalProp.midX,y:originalProp.midY),radius:d*0.57,ink:"296ADE",alpha:0.78,c:c)
        c.setFillColor(color("030A25",alpha:0.66))
        c.fillEllipse(in:CGRect(x:prop.minX-d*0.04,y:prop.minY-d*0.024,width:prop.width+d*0.08,height:d*0.038))
        if let image {
            c.saveGState();c.setAlpha(0.84);c.setShadow(offset:CGSize(width:d*0.018,height:-d*0.018),blur:d*0.022,color:color("000000",alpha:0.70))
            draw(image,in:prop,fill:false,context:c);c.restoreGState()
        }
        glow(canvas,center:CGPoint(x:canvas.midX,y:canvas.midY),radius:d*0.49,ink:"06102E",alpha:0.82,c:c)
        if let hero {c.saveGState();c.setShadow(offset:CGSize(width:d*0.012,height:-d*0.012),blur:d*0.020,color:color("000000",alpha:0.64));draw(hero,in:placement.rect,fill:false,mirrored:placement.mirrored,context:c);c.restoreGState()}
    }
    static func gameDepthLayout(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,heroAspect:CGFloat=0.75)->GameDepthLayout {
        let d=s.width,bubble=gameDialogueBubble(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds)
        // A tight original character stands across the topic plane. Its upper
        // body occupies the clear space above the bubble, rather than placing
        // the face behind the centered headline. Fit the actual source aspect.
        let overlap:CGFloat=variant == 2 ? 0.36:0.30
        let headroom=max(d*0.04,s.maxY-d*0.035-bubble.maxY)
        let aspect=max(0.1,min(4,heroAspect))
        let height=min(d*0.66,headroom/(1-overlap),(canvas.width-d*0.05)/aspect)
        let width=height*aspect
        let left=max(d*0.025,bubble.minX-width*0.72)
        let right=min(canvas.width-width-d*0.025,bubble.maxX-width*(variant == 2 ? 0.36:0.28))
        let rect=CGRect(x:variant == 1 ? left:right,y:bubble.maxY-height*overlap,width:width,height:height)
        return GameDepthLayout(aperture:canvas,hero:rect,frontLip:.zero)
    }
    static func gameNoticeBoardImageFrame(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect)->CGRect {
        let paper=CommunityNoticeBoardArtwork.paper
        let pad=s.width*([0.08,0.10,0.12][min(2,max(0,variant))])
        let minimum=max((titleBounds.width+pad)/paper.width,
                        (titleBounds.height+s.width*0.08)/paper.height*CommunityNoticeBoardArtwork.width/CommunityNoticeBoardArtwork.height)
        let width=max(s.width*0.82,minimum)
        let height=width*CommunityNoticeBoardArtwork.height/CommunityNoticeBoardArtwork.width
        return CGRect(x:titleBounds.midX-paper.midX*width,y:titleBounds.midY-paper.midY*height,width:width,height:height)
    }
    private static func noticeRegion(_ region:CGRect,in image:CGRect)->CGRect {
        CGRect(x:image.minX+region.minX*image.width,y:image.minY+region.minY*image.height,
               width:region.width*image.width,height:region.height*image.height)
    }
    static func gameDialogueBubble(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect)->CGRect {
        noticeRegion(CommunityNoticeBoardArtwork.paper,
                     in:gameNoticeBoardImageFrame(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds))
    }
    static func gameNoticeBoardFrame(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect)->CGRect {
        noticeRegion(CommunityNoticeBoardArtwork.backing,
                     in:gameNoticeBoardImageFrame(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds))
    }
    private static func gameNoticeBoard(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,p:Palette,c:CGContext)throws {
        let imageFrame=gameNoticeBoardImageFrame(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds)
        let paper=gameDialogueBubble(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds)
        guard paper.contains(titleBounds) else {throw VideoError.review("标题超出社区公告栏纸面")}
        // One complete transparent artwork is the final foreground unit.
        // Glyphs are drawn only afterwards; no character can enter this layer.
        // The generated original has gently translucent paper pixels. Keep
        // its bytes intact, and place an opaque paper surface underneath so
        // a fist or sleeve can never show through the headline's own board.
        c.setFillColor(color("F7F3DF"));c.fill(paper)
        c.draw(try CommunityNoticeBoardArtwork.image(),in:imageFrame)
    }
    static func gameContactShadowRect(artwork image:CGImage,placement:CGRect)throws->CGRect {
        let width=image.width,height=image.height
        guard width>0,height>0,width*height<=64*1024*1024,
              !placement.isInfinite,!placement.isNull,!placement.isEmpty,
              placement.width>0,placement.height>0,placement.width.isFinite,placement.height.isFinite,
              placement.minX.isFinite,placement.minY.isFinite,
              let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes=context.data?.assumingMemoryBound(to:UInt8.self) else {throw VideoError.review("游戏封面足底透明轮廓无法读取")}
        context.setBlendMode(.copy);context.interpolationQuality = .none
        context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));context.flush()
        var bottom = -1,left=width,right = -1
        for y in stride(from:height-1,through:0,by:-1) {
            if (0..<width).contains(where:{bytes[y*context.bytesPerRow+$0*4+3]>0}) {bottom=y;break}
        }
        guard bottom>=0 else {throw VideoError.review("游戏封面角色完全透明，不能生成没有主体的接触影")}
        let rows=max(1,Int((CGFloat(height)*0.14).rounded(.up)))
        for y in max(0,bottom-rows+1)...bottom {for x in 0..<width where bytes[y*context.bytesPerRow+x*4+3]>0 {
            left=min(left,x);right=max(right,x)
        }}
        guard right>=left else {throw VideoError.review("游戏封面角色没有实际足底范围")}
        let scale=min(placement.width/CGFloat(width),placement.height/CGFloat(height))
        let imageX=placement.midX-CGFloat(width)*scale/2,imageY=placement.midY-CGFloat(height)*scale/2
        let footprintWidth=CGFloat(right-left+1)*scale,shadowWidth=footprintWidth*1.10
        let shadowHeight=max(2,min(CGFloat(height)*scale*0.075,shadowWidth*0.22))
        let footX=imageX+CGFloat(left+right+1)*scale/2,footY=imageY+CGFloat(height-bottom-1)*scale
        return CGRect(x:footX-shadowWidth/2,y:footY-shadowHeight*0.58,width:shadowWidth,height:shadowHeight)
    }
    private static func gameContactShadow(in rect:CGRect,c:CGContext) {
        let colors=[color("173C34",alpha:0.32),color("173C34",alpha:0.18),color("173C34",alpha:0)]
        guard let gradient=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors as CFArray,locations:[0,0.48,1]) else{return}
        c.saveGState();c.clip(to:rect)
        c.translateBy(x:rect.midX,y:rect.midY);c.scaleBy(x:rect.width/2,y:rect.height/2)
        c.drawRadialGradient(gradient,startCenter:.zero,startRadius:0,endCenter:.zero,endRadius:1,options:[])
        c.restoreGState()
    }
    private static func game(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,p:Palette,c:CGContext)throws {
        let aspect=hero.map{CGFloat($0.width)/CGFloat($0.height)} ?? 0.75
        let layout=gameDepthLayout(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds,heroAspect:aspect)
        // The actual set is the whole cover, as in a normal game screenshot.
        // Volume comes from its original scene/materials/characters, not a
        // second photograph standing in a fabricated portal or paper frame.
        if let image {draw(image,in:canvas,fill:true,context:c)}
        else {gradient(canvas,colors:[color("BEE3AC"),color("6BAF72")],locations:[0,1],c:c)}
        if let hero {
            gameContactShadow(in:try gameContactShadowRect(artwork:hero,placement:layout.hero),c:c)
            draw(hero,in:layout.hero,fill:false,context:c)
        }
        // Complete the scene and IP first. Backing and notice are the final
        // foreground unit; the only later drawing is the shared title text.
        // An arm must never be repainted between its paper and its glyphs.
        try gameNoticeBoard(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds,p:p,c:c)
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
    private static func code(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,revision:Revision,quantity:CoverQuantityGraphic?,p:Palette,c:CGContext)throws {
        let d=s.width,shift=CGFloat(variant-1)*d*0.035
        c.setFillColor(color(IslandTheme.canvas));c.fill(canvas)
        // Use the same published Animal Island Panel/Popover vocabulary as
        // the ordinary code video. No source pixels or invented code text.
        let panel=CGRect(x:canvas.midX-d*0.58,y:canvas.midY-d*0.40,width:d*1.16,height:d*0.80)
        IslandTheme.drawPanel(in:panel,context:c)
        if let quantity {
            try quantity.validate()
            let cover=try CoverRules.resolved(revision:revision)
            let title=try composeTitle(cover:cover,width:canvas.width,height:canvas.height)
            let slots=try quantitySlots(square:s,titleBounds:title.visibleBounds,required:quantity.required,variant:variant)
            let focus=try quantitySpotlightFocus(slots:slots,available:quantity.available)
            let highlight=try quantitySpotlightEnvelope(focus:focus,square:s,titleBounds:title.visibleBounds)
            c.saveGState()
            // The shortfall panel may change with the available count, while
            // existing coins retain identical base pixels at their soft edge.
            for coin in slots.prefix(quantity.available) {
                let side=coin.offsetBy(dx:coin.width*0.012,dy:-coin.width*0.055)
                for face in [coin,side] {
                    c.addRect(canvas);c.addEllipse(in:face.insetBy(dx:-2,dy:-2));c.clip(using:.evenOdd)
                }
            }
            IslandTheme.drawPill(in:highlight,fill:IslandTheme.mintWash,context:c)
            c.restoreGState()
            quantityStage(slots,square:s,canvas:canvas,c:c)
            for (index,rect) in slots.enumerated() {
                quantityCoin(in:rect,present:index<quantity.available,c:c)
            }
            return
        }
        let symbolWidth=d*(variant == 2 ? 0.23:0.20)
        let symbolHeight=d*(variant == 1 ? 0.60:0.66)
        let symbolY=s.midY-symbolHeight/2
        let left=CGRect(x:max(d*0.07,s.minX-d*0.17+shift),y:symbolY,width:symbolWidth,height:symbolHeight)
        let right=CGRect(x:min(canvas.width-symbolWidth-d*0.06,s.maxX-d*0.03+shift),y:symbolY,width:symbolWidth,height:symbolHeight)
        for (index,rect) in [left,right].enumerated() {
            c.saveGState();c.setLineCap(.round);c.setLineJoin(.round);c.setLineWidth(d*0.045)
            c.setStrokeColor(color(index == 0 ? IslandTheme.mint:IslandTheme.ink))
            c.addPath(codeBrace(in:rect,opening:index==0));c.strokePath();c.restoreGState()
        }
    }
    /// Light follows the author-declared shortfall, rather than title words.
    /// A fully funded group has no missing object, so the whole group leads.
    static func quantitySpotlightFocus(slots:[CGRect],available:Int)throws->CGRect {
        guard (1...8).contains(slots.count),(0...slots.count).contains(available),
              slots.allSatisfy({!$0.isNull && !$0.isInfinite && $0.width>0 && $0.height>0
                  && $0.minX.isFinite && $0.minY.isFinite && $0.maxX.isFinite && $0.maxY.isFinite}) else {
            throw VideoError.invalid("数量聚光须使用完整且有效的实际对象位置与数量")
        }
        let selected=available<slots.count ? slots.dropFirst(available):slots[...]
        guard selected.count>1 else{return selected.first!}
        let left=selected.map(\.minX).min()!,bottom=selected.map(\.minY).min()!
        let right=selected.map(\.maxX).max()!,top=selected.map(\.maxY).max()!
        // Subtracting and rebuilding a floating-point extent can otherwise
        // lose the outer edge. Enclose it conservatively by one representable
        // step, many orders of magnitude smaller than an output pixel.
        return CGRect(x:left,y:bottom,width:(right-left).nextUp,height:(top-bottom).nextUp)
    }
    static func quantitySpotlightEnvelope(focus:CGRect,square s:CGRect,titleBounds:CGRect)throws->CGRect {
        let d=s.width,upper=titleBounds.minY-d*0.035
        let width=max(focus.width+d*0.48,d*0.82)
        let halfHeight=min(max((focus.height+d*0.54)/2,d*0.39),upper-focus.midY)
        guard d>0,halfHeight>=focus.height/2,halfHeight.isFinite else {
            throw VideoError.review("当前标题未给数量聚光留下完整且分离的空间")
        }
        // The radial gradient reaches zero alpha before the title. Limiting
        // its ellipse avoids a visible rectangular notch in the light field.
        return CGRect(x:focus.midX-width/2,y:focus.midY-halfHeight,width:width,height:halfHeight*2)
    }
    private static func quantitySpotlight(_ focus:CGRect,protectedCoins:ArraySlice<CGRect>,square s:CGRect,canvas:CGRect,titleBounds:CGRect,c:CGContext)throws {
        let envelope=try quantitySpotlightEnvelope(focus:focus,square:s,titleBounds:titleBounds)
        // A broad cyan falloff reveals the actual empty place. It stays behind
        // the unchanged metal objects and never supplies an extra contribution.
        // Its natural zero-alpha upper edge keeps the title's backdrop dark.
        c.saveGState();c.clip(to:canvas)
        // Light belongs to the backdrop. Keep the existing coins' front and
        // thickness silhouettes on an unchanged base, including two physical
        // pixels around their antialiased edges. Successive clips subtract
        // their union even where the two silhouettes overlap.
        for coin in protectedCoins {
            let side=coin.offsetBy(dx:coin.width*0.012,dy:-coin.width*0.055)
            for face in [coin,side] {
                c.addRect(canvas);c.addEllipse(in:face.insetBy(dx:-2,dy:-2));c.clip(using:.evenOdd)
            }
        }
        c.translateBy(x:envelope.midX,y:envelope.midY)
        c.scaleBy(x:envelope.width/2,y:envelope.height/2)
        if let light=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),
            colors:[color("1BAFAE",alpha:0.68),color("116C89",alpha:0.30),color("07143E",alpha:0)] as CFArray,
            locations:[0,0.48,1]) {
            c.drawRadialGradient(light,startCenter:.zero,startRadius:0,endCenter:.zero,endRadius:1,options:[])
        }
        c.restoreGState()
    }
    private static func quantityStage(_ slots:[CGRect],square s:CGRect,canvas:CGRect,c:CGContext) {
        // A single physical surface supports only a shared baseline. Keep
        // editorial rows and contrast steps in their original graphic layout.
        guard let baseline=slots.first?.minY,
              slots.allSatisfy({abs($0.minY-baseline)<=s.width*0.0001}) else{return}
        let d=s.width,objects=slots.reduce(CGRect.null){$0.union($1)}
        let left=max(d*0.025,objects.minX-d*0.075),right=min(canvas.width-d*0.025,objects.maxX+d*0.075)
        let front=max(s.minY+d*0.040,objects.minY-d*0.042)
        let back=max(front+d*0.030,objects.minY+d*0.028)
        c.saveGState();c.setShadow(offset:CGSize(width:0,height:-d*0.022),blur:d*0.040,color:color("000000",alpha:0.72))
        c.setFillColor(color("030C29"))
        polygon([CGPoint(x:left,y:front),CGPoint(x:right,y:front),CGPoint(x:right,y:front-d*0.034),CGPoint(x:left,y:front-d*0.034)],c:c)
        c.restoreGState()
        let top=[CGPoint(x:left,y:front),CGPoint(x:right,y:front),CGPoint(x:right-d*0.040,y:back),CGPoint(x:left+d*0.040,y:back)]
        c.saveGState();c.addLines(between:top);c.closePath();c.clip()
        gradient(CGRect(x:left,y:front,width:right-left,height:back-front),colors:[color("204979"),color("457D9E")],locations:[0,1],c:c)
        c.restoreGState()
        // The real objects sit on this surface; empty slots get no gold fill.
        for slot in slots {
            c.setFillColor(color("010719",alpha:0.52))
            c.fillEllipse(in:CGRect(x:slot.minX-d*0.008,y:slot.minY-d*0.028,width:slot.width+d*0.016,height:d*0.036))
        }
    }
    static func quantitySlots(square s:CGRect,titleBounds:CGRect,required:Int,variant:Int=0)throws->[CGRect] {
        guard (1...8).contains(required) else {throw VideoError.invalid("封面数量图范围无效")}
        guard (0...2).contains(variant) else {throw VideoError.invalid("数量图模板无效")}
        let d=s.width
        // Spotlight is a direct row; editorial groups the count in two rows;
        // contrast ascends toward the final slot. Objects never overlap, and
        // these remain different layouts without changing the declared data.
        let columns=variant == 1 ? min(4,max(1,(required+1)/2)):min(4,required)
        let rows=(required+columns-1)/columns,stagger:CGFloat=variant == 2 ? 0.22:0
        let gap=d*0.035,availableWidth=d*0.86
        let upper=titleBounds.minY-d*0.055,lower=s.minY+d*0.04
        let maximum=d*(variant == 1 ? 0.215:(variant == 2 ? 0.245:0.235))
        let diameter=min(maximum,(availableWidth-gap*CGFloat(columns-1))/CGFloat(columns),
                         (upper-lower-gap*CGFloat(rows-1))/(CGFloat(rows)+stagger*CGFloat(columns-1)))
        guard diameter>=d*0.06 else {throw VideoError.review("当前标题未给真实数量图留下足够空间")}
        let height=diameter*(CGFloat(rows)+stagger*CGFloat(columns-1))+gap*CGFloat(rows-1),bottom=upper-height
        return (0..<required).map { index in
            let row=index/columns,column=index%columns,rowCount=min(columns,required-row*columns)
            let width=diameter*CGFloat(rowCount)+gap*CGFloat(rowCount-1)
            return CGRect(x:s.midX-width/2+CGFloat(column)*(diameter+gap),
                          y:bottom+CGFloat(rows-row-1)*(diameter+gap)+CGFloat(column)*diameter*stagger,width:diameter,height:diameter)
        }
    }
    private static func quantityCoin(in rect:CGRect,present:Bool,c:CGContext) {
        let diameter=rect.width
        c.saveGState()
        if !present {
            // A recessed, unfilled place remains visibly different from the
            // real metal objects. Its broken cool rim never invents gold for
            // a contribution which the author has not declared available.
            c.setShadow(offset:CGSize(width:0,height:-diameter*0.035),blur:diameter*0.07,color:color("010615",alpha:0.65))
            c.setFillColor(color("031023"));c.fillEllipse(in:rect)
            c.setShadow(offset:.zero,blur:0,color:nil)
            c.saveGState();c.addEllipse(in:rect);c.clip()
            gradient(rect,colors:[color("0D5668"),color("092541"),color("02091D")],locations:[0,0.38,1],c:c)
            c.restoreGState()
            c.setFillColor(color("030D24"));c.fillEllipse(in:rect.insetBy(dx:diameter*0.07,dy:diameter*0.07))
            c.setStrokeColor(color("68F1E9",alpha:0.96));c.setLineWidth(diameter*0.036)
            c.setLineDash(phase:0,lengths:[diameter*0.045,diameter*0.065])
            c.strokeEllipse(in:rect.insetBy(dx:diameter*0.018,dy:diameter*0.018))
            c.setLineDash(phase:0,lengths:[])
            c.setStrokeColor(color("BEFFFF",alpha:0.72));c.setLineWidth(diameter*0.014)
            c.addArc(center:CGPoint(x:rect.midX,y:rect.midY),radius:diameter*0.425,startAngle:.pi*0.15,endAngle:.pi*0.86,clockwise:false);c.strokePath()
            c.restoreGState();return
        }
        c.setShadow(offset:CGSize(width:diameter*0.035,height:-diameter*0.055),blur:diameter*0.075,color:color("000000",alpha:0.56))
        let side=rect.offsetBy(dx:diameter*0.012,dy:-diameter*0.055)
        c.setFillColor(color("8F430B"));c.fillEllipse(in:side)
        c.setShadow(offset:.zero,blur:0,color:nil)
        c.saveGState();c.addEllipse(in:side);c.clip()
        gradient(side,colors:[color("7B3005"),color("D27F1C"),color("A04B08")],locations:[0,0.56,1],c:c)
        c.restoreGState()
        // Broad opposing reflections on the bevel and face describe metal,
        // rather than a flat yellow disk with an outline resembling a zero.
        c.saveGState();c.addEllipse(in:rect);c.clip()
        gradient(rect,colors:[color("A85B10"),color("FFD06B"),color("FFF1B6")],locations:[0,0.47,1],c:c)
        c.restoreGState()
        let inner=rect.insetBy(dx:diameter*0.105,dy:diameter*0.105)
        c.saveGState();c.addEllipse(in:inner);c.clip()
        gradient(inner,colors:[color("FFE8A1"),color("F1B33F"),color("AD5B0C")],locations:[0,0.45,1],c:c)
        c.restoreGState()
        c.setStrokeColor(color("87420A",alpha:0.72));c.setLineWidth(diameter*0.015);c.strokeEllipse(in:inner)
        c.setStrokeColor(color("FFF6D1",alpha:0.94));c.setLineWidth(diameter*0.026)
        c.addArc(center:CGPoint(x:rect.midX,y:rect.midY),radius:diameter*0.455,startAngle:.pi*0.08,endAngle:.pi*0.81,clockwise:false);c.strokePath()
        c.setStrokeColor(color("FFEAB0",alpha:0.88));c.setLineWidth(diameter*0.012)
        c.addArc(center:CGPoint(x:rect.midX,y:rect.midY),radius:diameter*0.387,startAngle:.pi*1.08,endAngle:.pi*1.86,clockwise:false);c.strokePath()
        // A neutral geometric relief supplies surface detail without adding
        // numerals, currency symbols, a logo or any new cover copy.
        let mark=rect.insetBy(dx:diameter*0.32,dy:diameter*0.32)
        let relief=[CGPoint(x:mark.midX,y:mark.maxY),CGPoint(x:mark.maxX,y:mark.midY),
                    CGPoint(x:mark.midX,y:mark.minY),CGPoint(x:mark.minX,y:mark.midY)]
        c.setFillColor(color("B76A13",alpha:0.62));polygon(relief,c:c)
        c.setStrokeColor(color("FFF0BB",alpha:0.83));c.setLineWidth(diameter*0.017)
        c.move(to:relief[2]);c.addLine(to:relief[3]);c.addLine(to:relief[0]);c.strokePath()
        c.setStrokeColor(color("85400A",alpha:0.74));c.move(to:relief[0]);c.addLine(to:relief[1]);c.addLine(to:relief[2]);c.strokePath()
        c.restoreGState()
    }
    private static func codeBrace(in rect:CGRect,opening:Bool)->CGPath {
        func point(_ x:CGFloat,_ y:CGFloat)->CGPoint {
            CGPoint(x:rect.minX+(opening ? x:1-x)*rect.width,y:rect.minY+y*rect.height)
        }
        let path=CGMutablePath();path.move(to:point(0.90,1))
        path.addCurve(to:point(0.40,0.82),control1:point(0.43,1),control2:point(0.40,0.97))
        path.addCurve(to:point(0.04,0.50),control1:point(0.40,0.62),control2:point(0.34,0.54))
        path.addCurve(to:point(0.40,0.18),control1:point(0.34,0.46),control2:point(0.40,0.38))
        path.addCurve(to:point(0.90,0),control1:point(0.40,0.03),control2:point(0.43,0))
        return path
    }
    private static func paletteColor(_ image:CGImage)->CGColor? {
        guard let context=CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let bytes=context.data?.assumingMemoryBound(to:UInt8.self) else{return nil}
        context.interpolationQuality = .high;context.draw(image,in:CGRect(x:0,y:0,width:1,height:1));context.flush()
        guard bytes[3]>0 else{return nil}
        let alpha=CGFloat(bytes[3])/255
        return CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[CGFloat(bytes[0])/255/alpha,CGFloat(bytes[1])/255/alpha,CGFloat(bytes[2])/255/alpha,1])
    }
    static func presenterPlacement(square s:CGRect,variant:Int,titleBounds:CGRect,pointing:CoverPointing?,imageAspect:CGFloat?=nil)->HeroPlacement {
        let d=s.width,canvasWidth=d+s.minX*2,bleed=max(2,d*0.015)
        let aspect=imageAspect.flatMap{$0.isFinite && $0>0 ? $0:nil} ?? (0.70/0.98)
        let height=imageAspect == nil ? d*0.98:min(d*0.98,d*0.70/aspect)
        let width=imageAspect == nil ? d*0.70:height*aspect
        // hero is trimmed to its nonzero-alpha silhouette. Its exact aspect
        // prevents fit-letterboxing below a cropped torso or at the outer arm.
        // Slight bleed hides the cut edge while the gesture points inward.
        let onLeft=variant == 1
        let rect=CGRect(x:onLeft ? -bleed:canvasWidth-width+bleed,y:-bleed,width:width,height:height)
        let target:CoverPointing=onLeft ? .right:.left
        return HeroPlacement(rect:rect,target:target,mirrored:pointing.map{$0 != target} ?? false)
    }

    /// Fit the actual silhouette, not the transparent generation canvas. This
    /// is an in-memory composition crop; source bytes and CAS identity stay
    /// untouched, and every nonzero-alpha pixel remains included.
    static func visibleArtwork(_ image:CGImage)throws->CGImage {
        let width=image.width,height=image.height
        guard width>0,height>0,width*height<=64*1024*1024,
              let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes=context.data?.assumingMemoryBound(to:UInt8.self) else {throw VideoError.review("封面人物透明轮廓无法读取")}
        context.setBlendMode(.copy);context.interpolationQuality = .none
        context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));context.flush()
        var left=width,right = -1,top=height,bottom = -1
        for y in 0..<height {for x in 0..<width where bytes[y*context.bytesPerRow+x*4+3]>0 {
            left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
        }}
        guard right>=left,bottom>=top else {throw VideoError.review("封面人物原图完全透明，不能作为可见IP")}
        if left==0,right==width-1,top==0,bottom==height-1 {return image}
        guard let canonical=context.makeImage(),let cropped=canonical.cropping(to:CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1)) else {throw VideoError.review("封面人物透明边界裁区无效")}
        return cropped
    }
    /// Keep the authored head, comparison hands and upper body prominent.
    /// Only portrait standing poses use this composition crop; wide actions
    /// remain complete. Original source bytes and authored direction stay exact.
    static func presenterArtwork(_ image:CGImage)throws->CGImage {
        guard image.height>image.width else{return image}
        let height=max(1,Int((CGFloat(image.height)*0.72).rounded(.up)))
        guard let upper=image.cropping(to:CGRect(x:0,y:0,width:image.width,height:height)) else {
            throw VideoError.review("封面解说员上半身构图无法读取")
        }
        return try visibleArtwork(upper)
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
