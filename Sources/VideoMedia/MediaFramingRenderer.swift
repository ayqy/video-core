import CoreGraphics
import VideoCore

enum MediaFramingRenderer {
    static func crop(_ image: CGImage, framing: MediaFraming?) throws -> CGImage {
        guard let framing else { return image }
        try framing.validate()
        let w=CGFloat(image.width), h=CGFloat(image.height)
        guard w > 0, h > 0 else { throw VideoError.invalid("源画面没有有效像素") }
        // CGImage.cropping uses the source raster's top-left origin. Round outward
        // to keep every source pixel touched by a valid normalized window.
        let left=max(0,min(w-1,floor(CGFloat(framing.x)*w)))
        let top=max(0,min(h-1,floor(CGFloat(framing.y)*h)))
        let right=max(left+1,min(w,ceil(CGFloat(framing.x+framing.width)*w)))
        let bottom=max(top+1,min(h,ceil(CGFloat(framing.y+framing.height)*h)))
        guard let result=image.cropping(to:CGRect(x:left,y:top,width:right-left,height:bottom-top)) else {
            throw VideoError.unavailable("源画面局部取景失败")
        }
        return result
    }
}
