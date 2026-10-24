import Foundation
import CoreGraphics
import VideoCore

/// A clear paper stage for authored bitmap drawings. This layout does not
/// generate illustrations, infer a pencil stroke order, or rewrite the script.
enum PaperPresentationPainter {
    struct Layout {
        let title:CGRect
        let body:CGRect
        let visual:CGRect
        let caption:CGRect
        let price:CGRect
        let action:CGRect
        let titleSize:CGFloat
        let bodySize:CGFloat
        init(aspect:Aspect,mode:PaperPresentation.Layout,showPrice:Bool,showAction:Bool) {
            if aspect == .portrait {
                title=CGRect(x:56,y:1030,width:608,height:180)
                body=CGRect(x:56,y:showAction ? 198:162,width:608,height:showAction ? 66:102)
                visual=CGRect(x:56,y:308,width:608,height:682)
                caption=CGRect(x:56,y:44,width:608,height:80)
                price=CGRect(x:56,y:270,width:608,height:38)
                action=CGRect(x:56,y:132,width:608,height:52)
                titleSize=mode == .cover ? 54:46
                bodySize=30
            } else {
                title=CGRect(x:80,y:mode == .cover ? 520:580,width:1120,height:mode == .cover ? 140:76)
                body=CGRect(x:80,y:112,width:showPrice ? 820:1120,height:70)
                visual=CGRect(x:80,y:206,width:1120,height:mode == .cover ? 294:342)
                caption=CGRect(x:80,y:30,width:1120,height:58)
                price=CGRect(x:940,y:112,width:260,height:70)
                action=CGRect(x:80,y:88,width:1120,height:24)
                titleSize=mode == .cover ? 60:48
                bodySize=30
            }
        }
    }

    static func draw(revision:Revision,scene:Scene,sourceFrame:Int,isLast:Bool,layerImages:[String:CGImage],context c:CGContext)throws {
        guard let presentation=scene.paperPresentation,scene.kind == .explanation else {throw VideoError.invalid("纸面分镜仅适用于普通知识讲解镜头")}
        try presentation.validate()
        let width=CGFloat(revision.aspect.width),height=CGFloat(revision.aspect.height)
        let showAction=isLast && !revision.cta.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        let layout=Layout(aspect:revision.aspect,mode:presentation.layout,showPrice:scene.showPrice,showAction:showAction)
        let fontName=scene.fontName ?? "PingFangSC-Medium"
        c.setFillColor(color(presentation.paperColor));c.fill(CGRect(x:0,y:0,width:width,height:height))
        // Draw the author's actual source assets and timed layers. No fixed path,
        // decoration, placeholder paragraph, or synthetic pencil image is added.
        try LayerPainter.draw(scene:scene,sourceFrame:sourceFrame,aspect:revision.aspect,images:layerImages,context:c,fontName:fontName)
        try ScenePainter.checkedText(scene.title,in:layout.title,size:layout.titleSize,color:presentation.inkColor,context:c,fontName:fontName)
        try ScenePainter.checkedText(scene.body,in:layout.body,size:layout.bodySize,color:presentation.inkColor,context:c,fontName:fontName)
        if scene.showPrice {
            guard let product=revision.product else {throw VideoError.review("没有关联产品事实，不能绘制产品价格")}
            let price=try product.price(at:revision.createdAt)
            try ScenePainter.checkedText(price.money.display,in:layout.price,size:30,color:presentation.inkColor,context:c,fontName:fontName)
        }
        if showAction {try ScenePainter.checkedText(revision.cta,in:layout.action,size:revision.aspect == .portrait ? 20:16,color:presentation.inkColor,context:c,fontName:fontName)}
        if let caption=scene.captions.first(where:{$0.startFrame<=sourceFrame && $0.endFrame>sourceFrame}) {
            try ScenePainter.checkedText(caption.text,in:layout.caption,size:26,color:presentation.inkColor,context:c,fontName:fontName)
        }
    }

    private static func color(_ hex:String)->CGColor {
        let n=UInt32(hex,radix:16)!
        return CGColor(red:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:1)
    }
}
