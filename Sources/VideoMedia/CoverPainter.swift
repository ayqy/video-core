import Foundation
import CoreGraphics
import CoreText
import ImageIO
import VideoCore

/// Code templates combine real imported artwork and a frame of the same final
/// movie. No image-generation service or advanced render scope is re-entered.
public enum CoverPainter {
    struct Palette {
        let paper:String;let ink:String;let accent:String;let secondary:String;let label:String
        init(_ style:CoverStyle) {
            switch style {
            case .presenter:(paper,ink,accent,secondary,label)=("FFF2C9","302A43","ED5270","A5DAC8","角色故事开讲")
            case .pencil:(paper,ink,accent,secondary,label)=("FFF7E5","263F3B","EF694B","B9D7BE","画里有故事")
            case .game:(paper,ink,accent,secondary,label)=("F4F5CB","24463C","F5A348","80BDA0","在游戏里看懂")
            case .cartoon:(paper,ink,accent,secondary,label)=("F0E7FF","332549","EC5D92","C4DE65","角色来演给你看")
            case .media:(paper,ink,accent,secondary,label)=("131D2D","FFFFFF","F5C64B","39BDB1","现场 · 发现")
            case .chart:(paper,ink,accent,secondary,label)=("152544","FFFFFF","F3D459","6CB5EA","让数据说清楚")
            case .code:(paper,ink,accent,secondary,label)=("172A27","E7FAE9","A9E46D","4DB8A4","一步一步拆解")
            default:(paper,ink,accent,secondary,label)=("EBF0FF","213354","F67548","9FC8E8","换个角度看懂")
            }
        }
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
                  let source=CGImageSourceCreateWithData(raw as CFData,nil),
                  let image=CGImageSourceCreateImageAtIndex(source,0,nil),
                  image.width>0,image.height>0,image.width<=16384,image.height<=16384,
                  image.width*image.height<=64*1024*1024 else {throw VideoError.review("封面原图摘要、路径或实际像素无效")}
            result[reference.assetID]=image
        }
        return result
    }
    public static func image(revision:Revision,source:CGImage,images:[String:CGImage]=[:])throws->CGImage {
        let cover=try CoverRules.resolved(revision:revision),w=revision.aspect.width,h=revision.aspect.height
        guard source.width==w,source.height==h,
              let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                             space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VideoError.invalid("封面底图须来自当前画幅的同版成片")
        }
        func selected(_ reference:CoverImage?)throws->CGImage? {
            guard let reference else{return nil}
            guard let original=images[reference.assetID] else {throw VideoError.notFound("封面模板引用的实际图片未加载")}
            return try MediaFramingRenderer.crop(original,framing:reference.sourceRect)
        }
        let background=try selected(cover.background) ?? source,hero=try selected(cover.hero)
        let drawBackground=cover.background != nil || hero==nil
        let width=CGFloat(w),height=CGFloat(h),portrait=h>w,p=Palette(cover.style)
        let canvas=CGRect(x:0,y:0,width:width,height:height),margin=width*(portrait ? 0.07:0.052)
        let wide=hero==nil && !portrait && background.width>background.height
        c.setFillColor(color(p.paper));c.fill(canvas)
        let editorial=cover.template == .editorial
        if editorial && drawBackground && !wide {
            draw(background,in:canvas,fill:true,context:c)
            c.setFillColor(color(p.paper,alpha:0.9));c.fill(canvas)
        }
        let visual:CGRect,title:CGRect,subtitle:CGRect,label:CGRect
        if wide {
            // Keep the complete authored frame below a separate headline. Fit
            // the actual selected pixels, including an explicit background crop.
            let area=CGRect(x:margin,y:height*0.055,width:width-margin*2,height:height*(cover.subtitle.isEmpty ? 0.67:0.62))
            let factor=min((area.width-32)/CGFloat(background.width),(area.height-32)/CGFloat(background.height))
            let size=CGSize(width:CGFloat(background.width)*factor+32,height:CGFloat(background.height)*factor+32)
            visual=CGRect(x:(width-size.width)/2,y:area.midY-size.height/2,width:size.width,height:size.height)
            title=CGRect(x:margin,y:height*0.76,width:width-margin*2,height:height*0.135)
            subtitle=CGRect(x:margin,y:height*0.69,width:width-margin*2,height:height*0.05)
            label=CGRect(x:margin,y:height*0.925,width:width*0.44,height:height*0.05)
        } else if portrait {
            visual=CGRect(x:margin,y:height*0.055,width:width-margin*2,height:height*0.50)
            title=CGRect(x:margin,y:height*0.665,width:width-margin*2,height:height*0.20)
            subtitle=CGRect(x:margin,y:height*0.555,width:width-margin*2,height:height*0.065)
            label=CGRect(x:margin,y:height*0.905,width:width-margin*2,height:height*0.052)
        } else {
            visual=CGRect(x:width*0.535,y:height*0.07,width:width*0.425,height:height*0.83)
            title=CGRect(x:margin,y:height*0.30,width:width*0.445,height:height*0.43)
            subtitle=CGRect(x:margin,y:height*0.11,width:width*0.43,height:height*0.14)
            label=CGRect(x:margin,y:height*0.82,width:width*0.44,height:height*0.075)
        }
        // Large asymmetric geometry provides contrast and repetition. Actual
        // characters always come from imported pixels, never these decorations.
        c.setFillColor(color(p.secondary));c.fillEllipse(in:visual.insetBy(dx:-margin*0.2,dy:-margin*0.15))
        let card=editorial ? visual.insetBy(dx:margin*0.16,dy:margin*0.2):visual
        c.saveGState();c.setShadow(offset:CGSize(width:7,height:-9),blur:0,color:color(p.ink,alpha:0.16))
        c.setFillColor(color(p.paper));c.addPath(CGPath(roundedRect:card,cornerWidth:28,cornerHeight:28,transform:nil));c.fillPath();c.restoreGState()
        c.saveGState();c.addPath(CGPath(roundedRect:card.insetBy(dx:8,dy:8),cornerWidth:22,cornerHeight:22,transform:nil));c.clip()
        if drawBackground {
            // The additional wide-frame inset keeps even its corner labels
            // inside the rounded card; a complete frame must never fill-crop.
            draw(background,in:card.insetBy(dx:wide ? 16:8,dy:wide ? 16:8),fill:hero==nil && !wide,context:c)
            if hero != nil {c.setFillColor(color(p.paper,alpha:0.52));c.fill(card)}
        }
        c.restoreGState()
        if let hero {
            let heroRect=card.insetBy(dx:margin*0.12,dy:margin*0.04)
            c.saveGState();c.setShadow(offset:CGSize(width:0,height:-8),blur:18,color:color(p.ink,alpha:0.2))
            draw(hero,in:heroRect,fill:false,context:c);c.restoreGState()
        }
        // A slanted ribbon changes the silhouette between the two templates.
        c.saveGState();c.translateBy(x:label.midX,y:label.midY);c.rotate(by:editorial ? -0.035:0.022)
        let pill=CGRect(x:-label.width/2,y:-label.height/2,width:label.width,height:label.height)
        c.setFillColor(color(p.accent));c.addPath(CGPath(roundedRect:pill,cornerWidth:9,cornerHeight:9,transform:nil));c.fillPath();c.restoreGState()
        let font=revision.scenes.first?.fontName ?? "PingFangSC-Medium"
        let labelText=cover.style == .presenter && cover.title.hasPrefix("豆子姐讲") ? "豆子姐开讲":p.label
        let labelInk=(cover.style == .code || cover.style == .media) ? p.paper:p.ink
        try text(labelText,in:label.insetBy(dx:12,dy:2),maximum:portrait ? 31:28,minimum:18,color:labelInk,font:font,context:c)
        // A high-contrast underline anchors the title without inventing facts.
        c.setFillColor(color(p.accent));c.fill(CGRect(x:title.minX,y:title.minY-9,width:title.width*0.33,height:9))
        try text(displayTitle(cover.title,style:cover.style),in:title,maximum:portrait ? 78:82,minimum:22,color:p.ink,font:font,context:c)
        if !cover.subtitle.isEmpty {try text(cover.subtitle,in:subtitle,maximum:portrait ? 30:30,minimum:18,color:p.ink,font:font,context:c)}
        decoration(style:cover.style,rect:canvas,accent:p.accent,context:c)
        guard let image=c.makeImage() else {throw VideoError.unavailable("模板封面合成失败")}
        return image
    }
    static func displayTitle(_ value:String,style:CoverStyle)->String {
        guard style == .presenter,value.hasPrefix("豆子姐讲"),let quote=value.firstIndex(of:"「") else{return value}
        let prefix=value[..<quote].trimmingCharacters(in:.whitespacesAndNewlines)
        return prefix+"\n"+String(value[quote...])
    }
    private static func draw(_ image:CGImage,in rect:CGRect,fill:Bool,context c:CGContext) {
        let factor=fill ? max(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height)):min(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height))
        let box=CGRect(x:rect.midX-CGFloat(image.width)*factor/2,y:rect.midY-CGFloat(image.height)*factor/2,width:CGFloat(image.width)*factor,height:CGFloat(image.height)*factor)
        c.saveGState();c.clip(to:rect);c.interpolationQuality = .high;c.draw(image,in:box);c.restoreGState()
    }
    private static func text(_ value:String,in rect:CGRect,maximum:CGFloat,minimum:CGFloat,color hex:String,font:String,context c:CGContext)throws {
        guard !value.isEmpty else{return}
        var size=maximum
        while size>=minimum {
            let typeface=CTFontCreateWithName(font as CFString,size,nil)
            guard CTFontCopyPostScriptName(typeface) as String == font else {throw VideoError.unavailable("封面字体未安装")}
            let string=NSAttributedString(string:value,attributes:[.init(kCTFontAttributeName as String):typeface,.init(kCTForegroundColorAttributeName as String):color(hex)])
            let setter=CTFramesetterCreateWithAttributedString(string)
            let frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:rect,transform:nil),nil)
            if CTFrameGetVisibleStringRange(frame).length==string.length && TextGlyphInspection.hasSupportedGlyphs(frame) {
                c.textMatrix = .identity;CTFrameDraw(frame,c);return
            }
            size-=2
        }
        throw VideoError.review("封面标题或副标题过长、缺字或超出模板安全区，请缩短后重新制作")
    }
    private static func decoration(style:CoverStyle,rect:CGRect,accent:String,context c:CGContext) {
        c.saveGState();defer{c.restoreGState()};c.setStrokeColor(color(accent,alpha:0.55));c.setLineWidth(3)
        let x=rect.width*0.965,y=rect.height*0.95
        switch style {
        case .game:
            for index in 0..<3 {c.stroke(CGRect(x:x-CGFloat(index)*18,y:y-18,width:12,height:12))}
        case .pencil,.presenter:
            for index in 0..<3 {c.move(to:CGPoint(x:x-55,y:y-CGFloat(index)*6));c.addLine(to:CGPoint(x:x,y:y-CGFloat(index)*6+9));c.strokePath()}
        case .chart:
            for index in 0..<4 {c.setFillColor(color(accent,alpha:0.65));c.fill(CGRect(x:x-70+CGFloat(index)*20,y:y-30,width:12,height:CGFloat(index+1)*9))}
        case .code:
            c.move(to:CGPoint(x:x-55,y:y));c.addLine(to:CGPoint(x:x-65,y:y-12));c.addLine(to:CGPoint(x:x-55,y:y-24));c.strokePath()
            c.move(to:CGPoint(x:x-15,y:y));c.addLine(to:CGPoint(x:x-5,y:y-12));c.addLine(to:CGPoint(x:x-15,y:y-24));c.strokePath()
        default:
            c.strokeEllipse(in:CGRect(x:x-35,y:y-24,width:24,height:24));c.strokeEllipse(in:CGRect(x:x-55,y:y-17,width:10,height:10))
        }
    }
    private static func color(_ hex:String,alpha:CGFloat=1)->CGColor {
        let value=UInt32(hex,radix:16) ?? 0
        return CGColor(red:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:alpha)
    }
}
