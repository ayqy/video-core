import Foundation
import CoreGraphics
import CoreText
import VideoCore

/// Native adaptation of yanstu/animal-island-ui-vue's actual Modal/Popover
/// styles and design tokens. Upstream package.json declares MIT; the upstream
/// root LICENSE is absent. Original selected sources and the exact declaration
/// are retained in ThirdParty/UI/AnimalIslandUI. Content and timing belong to IR.
public enum IslandTheme {
    public static let styleVersion = "animal-island-ui-0.1.0-chillroundf3-v2"
    public static let ink = "725D42"
    public static let canvas = "F8F8F0"
    public static let panel = "F7F3DF"
    public static let popup = "FFFAF0"
    public static let border = "D4C9B4"
    public static let mint = "19C8B9"
    public static let mintWash = "E6F9F6"
    public static let yellow = "FFCC00"
    public static let secondaryInk = "8A7B66"

    public static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let value = UInt32(hex,radix:16) ?? 0x725D42
        return CGColor(red:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,
                       blue:CGFloat(value&255)/255,alpha:alpha)
    }

    /// The real upstream Modal.vue normalized clip path, rather than a screenshot.
    public static func panelPath(in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        p.move(to:CGPoint(x:0.501,y:0.005))
        p.addLine(to:CGPoint(x:0.523,y:0.005));p.addLine(to:CGPoint(x:0.549,y:0.006))
        p.addCurve(to:CGPoint(x:0.825,y:0.027),control1:CGPoint(x:0.704,y:0.010),control2:CGPoint(x:0.796,y:0.017))
        p.addLine(to:CGPoint(x:0.827,y:0.028))
        p.addCurve(to:CGPoint(x:0.978,y:0.170),control1:CGPoint(x:0.872,y:0.045),control2:CGPoint(x:0.939,y:0.044))
        p.addCurve(to:CGPoint(x:0.990,y:0.505),control1:CGPoint(x:1,y:0.254),control2:CGPoint(x:1,y:0.365))
        p.addLine(to:CGPoint(x:0.988,y:0.513))
        p.addCurve(to:CGPoint(x:0.965,y:0.633),control1:CGPoint(x:0.979,y:0.558),control2:CGPoint(x:0.971,y:0.598))
        p.addCurve(to:CGPoint(x:0.964,y:0.865),control1:CGPoint(x:0.956,y:0.689),control2:CGPoint(x:0.979,y:0.770))
        p.addCurve(to:CGPoint(x:0.869,y:0.979),control1:CGPoint(x:0.953,y:0.928),control2:CGPoint(x:0.921,y:0.966))
        p.addCurve(to:CGPoint(x:0.726,y:0.995),control1:CGPoint(x:0.821,y:0.986),control2:CGPoint(x:0.773,y:0.992))
        p.addLine(to:CGPoint(x:0.712,y:0.996));p.addLine(to:CGPoint(x:0.694,y:0.997))
        p.addCurve(to:CGPoint(x:0.507,y:1),control1:CGPoint(x:0.648,y:1),control2:CGPoint(x:0.586,y:1))
        p.addLine(to:CGPoint(x:0.501,y:1));p.addLine(to:CGPoint(x:0.464,y:1))
        p.addCurve(to:CGPoint(x:0.283,y:0.995),control1:CGPoint(x:0.385,y:1),control2:CGPoint(x:0.325,y:0.998))
        p.addCurve(to:CGPoint(x:0.133,y:0.979),control1:CGPoint(x:0.234,y:0.992),control2:CGPoint(x:0.184,y:0.987))
        p.addCurve(to:CGPoint(x:0.039,y:0.865),control1:CGPoint(x:0.081,y:0.966),control2:CGPoint(x:0.050,y:0.928))
        p.addCurve(to:CGPoint(x:0.037,y:0.633),control1:CGPoint(x:0.023,y:0.770),control2:CGPoint(x:0.047,y:0.689))
        p.addCurve(to:CGPoint(x:0.013,y:0.505),control1:CGPoint(x:0.031,y:0.595),control2:CGPoint(x:0.023,y:0.552))
        p.addCurve(to:CGPoint(x:0.024,y:0.170),control1:CGPoint(x:-0.006,y:0.365),control2:CGPoint(x:-0.002,y:0.254))
        p.addCurve(to:CGPoint(x:0.174,y:0.028),control1:CGPoint(x:0.064,y:0.045),control2:CGPoint(x:0.130,y:0.045))
        p.addLine(to:CGPoint(x:0.175,y:0.028))
        p.addCurve(to:CGPoint(x:0.474,y:0.005),control1:CGPoint(x:0.204,y:0.017),control2:CGPoint(x:0.303,y:0.009))
        p.addLine(to:CGPoint(x:0.501,y:0.005));p.closeSubpath()
        var transform = CGAffineTransform(a:rect.width,b:0,c:0,d:-rect.height,tx:rect.minX,ty:rect.maxY)
        return p.copy(using:&transform)!
    }

    public static func drawPanel(in rect: CGRect, context c: CGContext) {
        c.saveGState();defer {c.restoreGState()}
        c.setShadow(offset:CGSize(width:0,height:-3),blur:10,color:color("3D3428",alpha:0.10))
        c.setFillColor(color(panel));c.addPath(panelPath(in:rect));c.fillPath()
    }

    /// One outline contains the tail; no border runs through its attachment.
    public static func popoverPath(in rect: CGRect, tail: [CGPoint] = [], scale: CGFloat = 1) -> CGPath {
        let p = CGMutablePath()
        let points = tail.count == 3 ? tail:[]
        let below = points.count == 3 && abs(points[0].y-rect.minY)<0.01
        let above = points.count == 3 && abs(points[0].y-rect.maxY)<0.01
        let left = points.isEmpty ? rect.maxX: min(points[0].x,points[2].x)
        let right = points.isEmpty ? rect.minX: max(points[0].x,points[2].x)
        let tailRoom = points.isEmpty ? rect.width:min(left-rect.minX,rect.maxX-right)
        let r = max(1,min(18*scale,rect.width/2,rect.height/2,tailRoom))
        p.move(to:CGPoint(x:rect.minX+r,y:rect.minY))
        if below {
            p.addLine(to:CGPoint(x:left,y:rect.minY));p.addLine(to:points[1]);p.addLine(to:CGPoint(x:right,y:rect.minY))
        }
        p.addLine(to:CGPoint(x:rect.maxX-r,y:rect.minY))
        p.addQuadCurve(to:CGPoint(x:rect.maxX,y:rect.minY+r),control:CGPoint(x:rect.maxX,y:rect.minY))
        p.addLine(to:CGPoint(x:rect.maxX,y:rect.maxY-r))
        p.addQuadCurve(to:CGPoint(x:rect.maxX-r,y:rect.maxY),control:CGPoint(x:rect.maxX,y:rect.maxY))
        if above {
            p.addLine(to:CGPoint(x:right,y:rect.maxY));p.addLine(to:points[1]);p.addLine(to:CGPoint(x:left,y:rect.maxY))
        }
        p.addLine(to:CGPoint(x:rect.minX+r,y:rect.maxY))
        p.addQuadCurve(to:CGPoint(x:rect.minX,y:rect.maxY-r),control:CGPoint(x:rect.minX,y:rect.maxY))
        p.addLine(to:CGPoint(x:rect.minX,y:rect.minY+r))
        p.addQuadCurve(to:CGPoint(x:rect.minX+r,y:rect.minY),control:CGPoint(x:rect.minX,y:rect.minY))
        p.closeSubpath();return p
    }

    public static func drawPopover(in rect: CGRect, tail: [CGPoint] = [], scale: CGFloat = 1, context c: CGContext) {
        c.saveGState();defer {c.restoreGState()}
        let path = popoverPath(in:rect,tail:tail,scale:scale)
        c.setShadow(offset:CGSize(width:0,height:-3*scale),blur:10*scale,color:color("3D3428",alpha:0.10))
        c.setFillColor(color(popup));c.addPath(path);c.fillPath()
        c.setShadow(offset:.zero,blur:0,color:nil)
        c.setStrokeColor(color(border));c.setLineWidth(2*scale);c.addPath(path);c.strokePath()
    }

    public static func drawPill(in rect: CGRect, fill: String = IslandTheme.mint, context c: CGContext) {
        c.saveGState();defer {c.restoreGState()}
        c.setFillColor(color(fill));c.addPath(CGPath(roundedRect:rect,cornerWidth:rect.height/2,
            cornerHeight:rect.height/2,transform:nil));c.fillPath()
    }

    public static func drawSelectedRow(in rect: CGRect, context c: CGContext) {
        c.saveGState();defer {c.restoreGState()}
        c.setFillColor(color(mintWash));c.addPath(CGPath(roundedRect:rect,cornerWidth:12,cornerHeight:12,transform:nil));c.fillPath()
        c.setFillColor(color(mint));c.addPath(CGPath(roundedRect:CGRect(x:rect.minX+4,y:rect.minY+6,width:4,height:rect.height-12),
            cornerWidth:2,cornerHeight:2,transform:nil));c.fillPath()
    }

    private static func paragraph(alignment: CTTextAlignment, lineHeight: CGFloat?) -> CTParagraphStyle {
        var selected=alignment, height=lineHeight ?? 0
        return withUnsafePointer(to:&selected) { alignmentPointer in
            withUnsafePointer(to:&height) { heightPointer in
                var settings=[CTParagraphStyleSetting(spec:.alignment,valueSize:MemoryLayout<CTTextAlignment>.size,value:alignmentPointer)]
                if lineHeight != nil {
                    settings.append(CTParagraphStyleSetting(spec:.minimumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:heightPointer))
                    settings.append(CTParagraphStyleSetting(spec:.maximumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:heightPointer))
                }
                return settings.withUnsafeBufferPointer {CTParagraphStyleCreate($0.baseAddress,$0.count)}
            }
        }
    }

    public static func measureText(_ text: String, width: CGFloat, size: CGFloat, lineHeight: CGFloat? = nil) throws -> CGSize {
        guard width.isFinite,width>0,lineHeight == nil || lineHeight!.isFinite && lineHeight! >= size else {
            throw VideoError.invalid("岛屿主题文字需要有效宽度和完整行高")
        }
        let font = try IslandTypeface.font(size:size)
        let value = NSAttributedString(string:text,attributes:[.init(kCTFontAttributeName as String):font,
            .init(kCTParagraphStyleAttributeName as String):paragraph(alignment:.left,lineHeight:lineHeight)])
        let setter = CTFramesetterCreateWithAttributedString(value)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:0),nil,
            CGSize(width:width,height:CGFloat.greatestFiniteMagnitude),nil)
        return CGSize(width:ceil(measured.width),height:ceil(measured.height))
    }

    public static func drawText(_ text: String, in rect: CGRect, size: CGFloat, color hex: String = IslandTheme.ink,
                                alignment: CTTextAlignment = .left, lineHeight: CGFloat? = nil, context c: CGContext) throws {
        guard !text.isEmpty else {return}
        guard rect.minX.isFinite,rect.minY.isFinite,rect.width.isFinite,rect.height.isFinite,
              rect.width>0,rect.height>0,CGRect(x:0,y:0,width:CGFloat(c.width),height:CGFloat(c.height)).contains(rect) else {
            throw VideoError.review("岛屿主题文字区域越出实际画布，请调整布局")
        }
        guard lineHeight == nil || lineHeight!.isFinite && lineHeight! >= size else {
            throw VideoError.invalid("岛屿主题行高须完整容纳当前字号")
        }
        let font = try IslandTypeface.font(size:size)
        let value = NSAttributedString(string:text,attributes:[.init(kCTFontAttributeName as String):font,
            .init(kCTForegroundColorAttributeName as String):color(hex),
            .init(kCTParagraphStyleAttributeName as String):paragraph(alignment:alignment,lineHeight:lineHeight)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value),CFRange(location:0,length:0),
            CGPath(rect:rect,transform:nil),nil)
        guard TextGlyphInspection.hasSupportedGlyphs(frame),CTFrameGetVisibleStringRange(frame).length == value.length else {
            throw VideoError.review("岛屿主题文字无法完整绘制，请扩大区域、缩短文案或拆分镜头")
        }
        c.saveGState();defer {c.restoreGState()}
        c.textMatrix = .identity;CTFrameDraw(frame,c)
    }
}
