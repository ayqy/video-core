import Foundation
import CoreGraphics
import CoreText
import VideoCore

/// Uses only the normal IR's typed values. Displayed code is never evaluated.
enum DataPresentationPainter {
    struct Bar {
        let rect: CGRect
        let value: Double
        let label: String
        let color: String
        let slot: CGRect
    }
    struct ChartGeometry {
        let plot: CGRect
        let zeroY: CGFloat
        let bars: [Bar]
    }
    static func chartGeometry(_ chart: DataChart, frame: Int, rect: CGRect) throws -> ChartGeometry {
        try chart.validate()
        guard rect.width.isFinite, rect.height.isFinite, rect.width >= 280, rect.height >= 200 else {
            throw VideoError.review("数据图表区域过小，请扩大到至少280×200像素或减少同屏内容")
        }
        let plot = CGRect(x: rect.minX+64, y: rect.minY+62, width: rect.width-84, height: rect.height-118)
        func y(_ value: Double) -> CGFloat { plot.minY + CGFloat((value-chart.minimum)/(chart.maximum-chart.minimum))*plot.height }
        let zero = y(min(max(0,chart.minimum),chart.maximum))
        let values = try chart.values(at: frame), slotWidth = plot.width / CGFloat(chart.series.count)
        let bars = zip(chart.series,values).enumerated().map { index, pair -> Bar in
            let slot = CGRect(x:plot.minX+CGFloat(index)*slotWidth,y:plot.minY,width:slotWidth,height:plot.height)
            let end = y(pair.1)
            return Bar(rect:CGRect(x:slot.minX+slotWidth*0.2,y:min(zero,end),width:slotWidth*0.6,height:abs(end-zero)),
                       value:pair.1,label:pair.0.label,color:pair.0.color,slot:slot)
        }
        return ChartGeometry(plot:plot,zeroY:zero,bars:bars)
    }
    static func draw(layer: SceneLayer, sourceFrame: Int, rect: CGRect, context c: CGContext, fontName: String) throws {
        guard let data=layer.dataPresentation else {throw VideoError.invalid("数据展示内容缺失")}
        try data.validate(kind:layer.kind,endFrame:layer.endFrame)
        let frame=try data.sourceFrame(at:sourceFrame)
        let canvas=CGRect(x:24,y:24,width:CGFloat(c.width)-48,height:CGFloat(c.height)-48)
        guard rect.minX.isFinite,rect.minY.isFinite,rect.width.isFinite,rect.height.isFinite,
              canvas.contains(rect) else {throw VideoError.review("数据/代码元素越出画面安全区，请调整位置、尺寸或关键帧")}
        c.setFillColor(color("111C31"));c.fill(rect)
        if let chart=data.chart {
            let geometry=try chartGeometry(chart,frame:frame,rect:rect)
            try text(chart.title,rect:CGRect(x:rect.minX+12,y:rect.maxY-42,width:rect.width-24,height:34),size:23,font:fontName,context:c)
            for tick in 0...4 {
                let fraction=Double(tick)/4,value=chart.minimum+(chart.maximum-chart.minimum)*fraction
                let y=geometry.plot.minY+CGFloat(fraction)*geometry.plot.height
                c.setStrokeColor(color("334155"));c.setLineWidth(1)
                c.move(to:CGPoint(x:geometry.plot.minX,y:y));c.addLine(to:CGPoint(x:geometry.plot.maxX,y:y));c.strokePath()
                try text(number(value),rect:CGRect(x:rect.minX+4,y:y-11,width:54,height:22),size:15,font:fontName,context:c)
            }
            c.setStrokeColor(color("94A3B8"));c.setLineWidth(1.5)
            c.move(to:CGPoint(x:geometry.plot.minX,y:geometry.zeroY));c.addLine(to:CGPoint(x:geometry.plot.maxX,y:geometry.zeroY));c.strokePath()
            for bar in geometry.bars {
                c.setFillColor(color(bar.color));c.fill(bar.rect)
                let labelY=min(geometry.plot.maxY-28,max(geometry.plot.minY+4,bar.rect.maxY+5))
                try text(number(bar.value),rect:CGRect(x:bar.slot.minX+2,y:labelY,width:bar.slot.width-4,height:28),size:19,font:fontName,context:c)
                try text(bar.label,rect:CGRect(x:bar.slot.minX+2,y:geometry.plot.minY-33,width:bar.slot.width-4,height:28),size:19,font:fontName,context:c)
            }
            try text(chart.axisLabel,rect:CGRect(x:rect.minX+12,y:rect.minY+6,width:rect.width-24,height:24),size:17,font:fontName,context:c)
        } else if let code=data.code {
            let usable=rect.height-58,row=usable/CGFloat(code.lines.count)
            guard rect.width>=280,row>=32 else{throw VideoError.review("代码区无法完整可读地容纳各行，请扩大区域或拆分镜头")}
            try text(code.title,rect:CGRect(x:rect.minX+12,y:rect.maxY-40,width:rect.width-24,height:32),size:22,font:fontName,context:c)
            let active=try code.highlightedLine(at:frame)
            for (index,line) in code.lines.enumerated() {
                let box=CGRect(x:rect.minX+8,y:rect.maxY-52-CGFloat(index+1)*row,width:rect.width-16,height:row)
                if active==index {c.setFillColor(color("244A61"));c.fill(box)}
                try text("\(index+1)",rect:CGRect(x:box.minX+4,y:box.minY+3,width:28,height:24),size:17,font:fontName,context:c)
                if !line.isEmpty {try text(line,rect:CGRect(x:box.minX+38,y:box.minY+3,width:box.width-42,height:29),size:20,font:fontName,context:c)}
            }
        }
    }
    static func number(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value.rounded() == value,abs(value)<1e6 {return String(format:"%.0f",locale:Locale(identifier:"en_US_POSIX"),value)}
        // At most six significant digits, or five for compact small-value
        // scientific labels. Curves retain the original Double; mark any loss.
        let negative=value < 0 ? "-":""
        let precision=abs(value)<0.01 ? 5:6
        let raw=String(format:"%.\(precision)g",locale:Locale(identifier:"en_US_POSIX"),abs(value)).lowercased()
        let approximate=Double(negative+raw) == value ? "":"≈"
        if let marker=raw.firstIndex(of:"e"),let exponent=Int(raw[raw.index(after:marker)...]) {
            return approximate+negative+raw[..<marker]+"e"+String(exponent)
        }
        if abs(value)<0.01,raw.hasPrefix("0.") {
            let fraction=Array(raw.dropFirst(2))
            if let first=fraction.firstIndex(where:{$0 != "0"}) {
                let digits=String(fraction[first...])
                let rest=digits.dropFirst()
                return approximate+negative+String(digits.first!)+(rest.isEmpty ? "":"."+rest)+"e-"+String(first+1)
            }
        }
        return approximate+negative+raw
    }
    private static func color(_ hex: String) -> CGColor {
        let rgb=UInt32(hex,radix:16) ?? 0xFFFFFF
        return CGColor(red:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
    }
    private static func text(_ value: String,rect: CGRect,size: CGFloat,font name: String,context c: CGContext) throws {
        let font=CTFontCreateWithName(name as CFString,size,nil)
        let string=NSAttributedString(string:value,attributes:[.init(kCTFontAttributeName as String):font,.init(kCTForegroundColorAttributeName as String):color("F1F5F9")])
        let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string),CFRange(location:0,length:0),CGPath(rect:rect,transform:nil),nil)
        guard (CTFontCopyPostScriptName(font) as String)==name,TextGlyphInspection.hasSupportedGlyphs(frame),
              CTFrameGetVisibleStringRange(frame).length==string.length else {
            throw VideoError.review("数据/代码文字无法完整绘制，请扩大区域、缩短标签或拆分镜头")
        }
        c.textMatrix = .identity;CTFrameDraw(frame,c)
    }
}
