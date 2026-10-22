import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import Vision
import UniformTypeIdentifiers
import VideoCore

public struct PageOCRDraft: Sendable {
    public var assetID: String
    public var pageNumber: Int
    public var sourceHash: String
    public var text: String
    public var minimumConfidence: Float
    public var observationCount: Int
    public var recognitionRevision: Int
}

/// All processing stays on-device and reads the original CAS file. OCR is a draft, never approval.
public enum CoursePreview {
    public static func thumbnail(asset: Asset, pageNumber: Int, repository: Repository, maxPixel: Int = 900) async throws -> Data {
        try await Task.detached(priority:.userInitiated) {
            let image=try image(asset:asset,pageNumber:pageNumber,repository:repository,maxPixel:maxPixel)
            let data=NSMutableData()
            guard let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw VideoError.unavailable("无法创建课程页缩略图") }
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else { throw VideoError.unavailable("课程页缩略图编码失败") }
            return data as Data
        }.value
    }
    public static func recognizePage(asset: Asset, pageNumber: Int, repository: Repository) async throws -> PageOCRDraft {
        try await Task.detached(priority:.userInitiated) {
            let image=try image(asset:asset,pageNumber:pageNumber,repository:repository,maxPixel:1800)
            let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=true
            let supported=try request.supportedRecognitionLanguages()
            request.recognitionLanguages=["zh-Hans","en-US"].filter{supported.contains($0)}
            guard !request.recognitionLanguages.isEmpty else { throw VideoError.unavailable("当前系统没有可用的中英文OCR语言，请手工校对录入") }
            try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
            let observations=request.results ?? []
            // Vision returns normalized coordinates; stable reading order follows top to bottom, left to right.
            let ordered=observations.sorted { left,right in abs(left.boundingBox.midY-right.boundingBox.midY)>0.012 ? left.boundingBox.midY>right.boundingBox.midY:left.boundingBox.minX<right.boundingBox.minX }
            let candidates=ordered.compactMap{$0.topCandidates(1).first}
            let text=candidates.map(\.string).joined(separator:"\n")
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VideoError.review("此页未识别到可靠文字，请对照原页手工录入；页面没有被标记为空内容") }
            return PageOCRDraft(assetID:asset.id,pageNumber:pageNumber,sourceHash:asset.hash,text:text,minimumConfidence:candidates.map(\.confidence).min() ?? 0,observationCount:candidates.count,recognitionRevision:request.revision)
        }.value
    }
    private static func image(asset: Asset, pageNumber: Int, repository: Repository, maxPixel: Int) throws -> CGImage {
        guard asset.ext.lowercased()=="pdf",pageNumber>=1,(200...2048).contains(maxPixel) else { throw VideoError.invalid("逐页缩略图与本地OCR仅接受有效PDF页面，像素边长须为200–2048") }
        let data=try Data(contentsOf:repository.assetURL(asset),options:.mappedIfSafe)
        guard data.count==asset.bytes,Codec.hash(data)==asset.hash else { throw VideoError.invalid("原始课程文件已缺失或哈希不符，未继续OCR") }
        guard let document=PDFDocument(data:data),!document.isLocked,pageNumber<=document.pageCount,let page=document.page(at:pageNumber-1) else { throw VideoError.invalid("PDF已加密、损坏或页码超出范围") }
        let bounds=page.bounds(for:.cropBox)
        guard bounds.width.isFinite,bounds.height.isFinite,bounds.width>0,bounds.height>0 else { throw VideoError.invalid("PDF页面尺寸无效") }
        let scale=Double(maxPixel)/max(bounds.width,bounds.height)
        let width=max(1,Int(ceil(bounds.width*scale))),height=max(1,Int(ceil(bounds.height*scale)))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VideoError.unavailable("无法分配课程页图像内存") }
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height));context.scaleBy(x:scale,y:scale);context.translateBy(x:-bounds.minX,y:-bounds.minY);page.draw(with:.cropBox,to:context)
        guard let image=context.makeImage() else { throw VideoError.unavailable("课程页渲染失败") };return image
    }
}
