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
            case .game:(paper,ink,accent,secondary)=("FFFBE8","555448","008E9B","EB83B1")
            case .cartoon:(paper,ink,accent,secondary)=("F2E9FF","38274F","C63B67","A6E8E1")
            case .media:(paper,ink,accent,secondary)=("101B28","FFFFFF","F7A56F","417F8B")
            case .chart:(paper,ink,accent,secondary)=("F1F3FE","21305B","6B3EB5","6386D9")
            case .code:(paper,ink,accent,secondary)=("071A47","FFFFFF","50E3DA","1681EE")
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
        var arrangements=titleArrangements(value,emphasis:ranges)
        if shortGameTitle {arrangements=[([NSRange(location:0,length:(value as NSString).length)],0)]}
        var size=side*(shortGameTitle ? 0.09:0.112)
        while size>=side*0.042 {
            let normal=try CoverTypeface.displayFont(size:size),emphasized=try CoverTypeface.displayFont(size:size*1.17)
            let title=NSMutableAttributedString(string:value,attributes:[.init(kCTFontAttributeName as String):normal,.init(kCTKernAttributeName as String):kern,.init(kCTForegroundColorAttributeName as String):color(p.ink)])
            for range in ranges {title.addAttributes([.init(kCTFontAttributeName as String):emphasized,.init(kCTForegroundColorAttributeName as String):color(p.accent)],range:range)}
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
    private static func paintTitle(_ value:TitleComposition,style:CoverStyle,p:Palette,c:CGContext) {
        c.saveGState();c.setShouldAntialias(true)
        // Contrast belongs to the actual topic glyphs. No yellow/black marker
        // block or secondary copy competes with the white/orange/cyan title.
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
    private static func pencil(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,p:Palette,c:CGContext) {
        let d=s.width,shift=CGFloat(variant-1)*d*0.055
        gradient(canvas,colors:[color("3A103C"),color(p.paper),color("F14D76")],locations:[0,0.56,1],c:c)
        c.setFillColor(color(p.secondary,alpha:0.72));c.fillEllipse(in:CGRect(x:canvas.midX-d*0.86+shift,y:s.minY-d*0.22,width:d*1.42,height:d*1.42))
        c.setFillColor(color(p.secondary,alpha:0.70));c.fillEllipse(in:CGRect(x:canvas.midX+d*0.32-shift,y:s.minY+d*0.55,width:d*0.92,height:d*0.92))
        let subject=CGRect(x:canvas.midX-d*0.63+shift,y:s.minY+d*0.03,width:d*0.82,height:d*0.94)
        c.saveGState();c.setShadow(offset:CGSize(width:d*0.02,height:-d*0.02),blur:d*0.018,color:color("381029",alpha:0.35))
        material(hero ?? image,in:subject,c:c);c.restoreGState()
        if hero != nil,let image {
            c.saveGState();c.setAlpha(0.18);draw(image,in:canvas,fill:true,context:c);c.restoreGState()
        }
        glow(canvas,center:CGPoint(x:titleBounds.midX,y:titleBounds.midY),radius:d*0.62,ink:"23132D",alpha:0.86,c:c)
    }
    private static func presenter(_ image:CGImage?,hero:CGImage?,placement:HeroPlacement,square s:CGRect,canvas:CGRect,variant:Int,p:Palette,c:CGContext) {
        let d=s.width
        gradient(canvas,colors:[color("03113E"),color(p.paper),color("125EC3")],locations:[0,0.55,1],c:c)
        glow(canvas,center:CGPoint(x:canvas.midX+CGFloat(variant-1)*d*0.19,y:s.minY+d*0.63),radius:d*0.85,ink:"2589EF",alpha:0.58,c:c)
        c.saveGState();c.setShadow(offset:.zero,blur:d*0.05,color:color("6297D5",alpha:0.18));c.setFillColor(color("27477C",alpha:0.55))
        c.fillEllipse(in:CGRect(x:canvas.midX-d*0.92,y:s.minY-d*0.28,width:d*1.84,height:d*0.49));c.restoreGState()
        if let image {
            let propX=variant == 1 ? canvas.midX+d*0.30:canvas.midX-d*0.65
            c.saveGState();c.setAlpha(0.42);c.setShadow(offset:CGSize(width:d*0.018,height:-d*0.018),blur:d*0.022,color:color("000000",alpha:0.70))
            draw(image,in:CGRect(x:propX,y:s.minY+d*0.10,width:d*0.35,height:d*0.52),fill:false,context:c);c.restoreGState()
        }
        glow(canvas,center:CGPoint(x:canvas.midX,y:canvas.midY),radius:d*0.53,ink:"0A183C",alpha:0.82,c:c)
        if let hero {c.saveGState();c.setShadow(offset:CGSize(width:d*0.012,height:-d*0.012),blur:d*0.016,color:color("000000",alpha:0.6));draw(hero,in:placement.rect,fill:false,mirrored:placement.mirrored,context:c);c.restoreGState()}
    }
    static func gameDepthLayout(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect)->GameDepthLayout {
        let d=s.width,width=d*0.48,height=d*0.64
        let x=variant == 1 ? max(d*0.025,s.minX-width*0.56):min(canvas.width-width-d*0.025,s.maxX-width*0.10)
        return GameDepthLayout(aperture:canvas,hero:CGRect(x:x,y:s.minY+d*0.04,width:width,height:height),frontLip:.zero)
    }
    static func gameDialogueBubble(square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect)->CGRect {
        let width=min(canvas.width-s.width*0.04,titleBounds.width+s.width*(variant == 2 ? 0.14:0.10))
        let height=titleBounds.height+s.width*(variant == 2 ? 0.05:0.035)
        return CGRect(x:canvas.midX-width/2,y:titleBounds.midY-height/2,width:width,height:height)
    }
    private static func game(_ image:CGImage?,hero:CGImage?,square s:CGRect,canvas:CGRect,variant:Int,titleBounds:CGRect,p:Palette,c:CGContext) {
        let d=s.width,layout=gameDepthLayout(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds)
        // The actual set is the whole cover, as in a normal game screenshot.
        // Volume comes from its original scene/materials/characters, not a
        // second photograph standing in a fabricated portal or paper frame.
        if let image {draw(image,in:canvas,fill:true,context:c)}
        else {gradient(canvas,colors:[color("BEE3AC"),color("6BAF72")],locations:[0,1],c:c)}
        if let hero {
            c.saveGState();c.setShadow(offset:CGSize(width:d*0.012,height:-d*0.012),blur:d*0.018,color:color("173C34",alpha:0.22));draw(hero,in:layout.hero,fill:false,context:c);c.restoreGState()
        }
        // A broad cream dialogue shape carries ONLY the topic, with native
        // dark lettering and colored keywords. No game-name label is added.
        let bubble=gameDialogueBubble(square:s,canvas:canvas,variant:variant,titleBounds:titleBounds)
        let radius=bubble.height*(variant == 1 ? 0.12:(variant == 2 ? 0.30:0.22))
        c.saveGState();c.setShadow(offset:CGSize(width:0,height:-d*0.006),blur:d*0.010,color:color("364F32",alpha:0.16));c.setFillColor(color(p.paper))
        c.addPath(CGPath(roundedRect:bubble,cornerWidth:radius,cornerHeight:radius,transform:nil));c.fillPath();c.restoreGState()
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
        let d=s.width,shift=CGFloat(variant-1)*d*0.035
        gradient(canvas,colors:[color("03061E"),color(p.paper),color("103D83")],locations:[0,0.52,1],c:c)
        // Input art may influence the broad color mood, but no spatial source
        // pixels, code lines, editor controls or document text enter the cover.
        if let image=hero ?? image,let wash=paletteColor(image),let translucent=wash.copy(alpha:0.16) {c.setFillColor(translucent);c.fill(canvas)}
        glow(canvas,center:CGPoint(x:canvas.midX+d*0.50,y:s.minY+d*0.74),radius:d*0.82,ink:"176AA5",alpha:0.62,c:c)
        // A pair of large source-code braces is a graphic programming symbol,
        // not fabricated source text, UI windows or unexplained flow wiring.
        // Position limits can consume the horizontal shift in a portrait
        // canvas. Real symbol proportions still distinguish all templates.
        let symbolWidth=d*(variant == 2 ? 0.27:0.24)
        let symbolHeight=d*(variant == 1 ? 0.76:0.84)
        let symbolY=s.midY-symbolHeight/2
        let left=CGRect(x:max(d*0.07,s.minX-d*0.28+shift),y:symbolY,width:symbolWidth,height:symbolHeight)
        let right=CGRect(x:min(canvas.width-symbolWidth-d*0.06,s.maxX+d*0.10+shift),y:symbolY,width:symbolWidth,height:symbolHeight)
        for (index,rect) in [left,right].enumerated() {
            let path=codeBrace(in:rect,opening:index==0)
            c.saveGState();c.setLineCap(.round);c.setLineJoin(.round);c.setLineWidth(d*0.065)
            c.setShadow(offset:CGSize(width:d*0.016,height:-d*0.014),blur:d*0.018,color:color("000000",alpha:0.65))
            c.setStrokeColor(color(index == 0 ? "177A90":"A04C2F"));c.addPath(path);c.strokePath()
            c.translateBy(x:-d*0.009,y:d*0.009)
            c.setStrokeColor(color(index == 0 ? "50E3DA":"FF985D"));c.addPath(path);c.strokePath();c.restoreGState()
        }
        glow(canvas,center:CGPoint(x:canvas.midX,y:canvas.midY),radius:d*0.57,ink:"060E30",alpha:0.78,c:c)
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
    static func presenterPlacement(square s:CGRect,variant:Int,titleBounds:CGRect,pointing:CoverPointing?)->HeroPlacement {
        let d=s.width,canvasWidth=d+s.minX*2,width=d*0.74,height=d*0.98
        // The IP can share background space with the title; the title itself
        // is painted last. Never shrink a person to the empty strip below it.
        let left=max(d*0.02,titleBounds.minX-width+d*0.06)
        let right=min(canvasWidth-width-d*0.02,titleBounds.maxX-d*0.06)
        let rect=CGRect(x:variant == 1 ? left:right,y:s.minY+d*0.005,width:width,height:height)
        let target:CoverPointing=rect.midX<titleBounds.midX ? .right:.left
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
