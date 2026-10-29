import Foundation
import CoreGraphics
import ImageIO
import VideoCore

/// CGImage is immutable. The bank is built only after file hashes, workspace and rights are checked.
public struct RenderResources: @unchecked Sendable {
    private let images: [String:CGImage]
    private let encoded: [String:Data]
    public let speechBinding:CartoonSpeechBinding?
    public static let empty = RenderResources(images:[:])
    fileprivate init(images:[String:CGImage],encoded:[String:Data]=[:],speechBinding:CartoonSpeechBinding?=nil) { self.images=images;self.encoded=encoded;self.speechBinding=speechBinding }
    /// RPC image-bank reuse never retains a previous frame's audio identity.
    /// This metadata grants no file/audio access; the Host reads its source
    /// binding independently from the current workspace before transport.
    func bindingSpeech(_ value:CartoonSpeechBinding?)->RenderResources {RenderResources(images:images,encoded:encoded,speechBinding:value)}
    public func sprite(_ role:String,artwork:ClassicArtwork) throws -> CGImage {
        guard let cell=artwork.sprites.first(where:{$0.role==role}),let image=images[cell.assetID] else { throw VideoError.notFound("外部图集角色未加载："+role) }
        let rect=CGRect(x:cell.x*Double(image.width),y:cell.y*Double(image.height),width:cell.width*Double(image.width),height:cell.height*Double(image.height)).integral
        guard rect.width>0,rect.height>0,rect.minX>=0,rect.minY>=0,rect.maxX<=CGFloat(image.width),rect.maxY<=CGFloat(image.height),let cropped=image.cropping(to:rect) else { throw VideoError.invalid("外部图块无法按已保存区域裁切") }
        return cropped
    }
    /// Snapshot only the already rights/hash-validated image bank. No source documents or audio.
    public func pluginRasterAssets(props:PluginVisualProps)throws->[PluginRasterAsset] {
        guard let artwork=props.artwork else{
            guard props.cartoonRig != nil,images.isEmpty,encoded.isEmpty else{throw VideoError.review("高级插件缺少实际图集；仅独立原生卡通可使用空图片库")}
            return []
        }
        let ids=Set(artwork.sprites.map(\.assetID))
        guard ids==Set(images.keys) else{throw VideoError.permission("插件快照与已核实际图集集合不符")}
        var result:[PluginRasterAsset]=[],total=0
        for id in ids.sorted() {
            guard let image=images[id] else{throw VideoError.notFound("实际图集缺失")}
            // Keep the validated single-PNG original; re-encoding every frame
            // can inflate a valid atlas beyond the unchanged transport budget.
            let bytes=try encoded[id] ?? ScenePainter.png(image);total+=bytes.count
            guard bytes.count<=PluginProtocolRules.maximumAssetBytes,total<=PluginProtocolRules.maximumTotalAssetBytes else{throw VideoError.unavailable("实际图集超过插件有界传输预算，请缩小真实图集后重新核验")}
            result.append(PluginRasterAsset(assetID:id,data:bytes,sha256:Codec.hash(bytes),width:image.width,height:image.height))
        }
        return result
    }
    /// Byte-only capability input, not a rights grant. Host must validate original rights first.
    public static func pluginResources(assets:[PluginRasterAsset])throws->RenderResources {
        guard assets.count<=32,Set(assets.map(\.assetID)).count==assets.count else{throw VideoError.invalid("插件图集数量或标识不合法")}
        var result:[String:CGImage]=[:],total=0,pixels=0
        for asset in assets {
            total+=asset.data.count
            guard !asset.data.isEmpty,asset.data.count<=PluginProtocolRules.maximumAssetBytes,total<=PluginProtocolRules.maximumTotalAssetBytes,Codec.hash(asset.data)==asset.sha256,
                  let source=CGImageSourceCreateWithData(asset.data as CFData,nil),CGImageSourceGetType(source) as String? == "public.png",CGImageSourceGetCount(source)==1,
                  let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=properties[kCGImagePropertyPixelWidth] as? Int,let h=properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...8192).contains(w),(1...8192).contains(h),w==asset.width,h==asset.height,w*h<=PluginProtocolRules.maximumImagePixels else{throw VideoError.invalid("插件图集真实字节、格式、摘要或像素无效")}
            pixels+=w*h;guard pixels<=PluginProtocolRules.maximumTotalImagePixels,let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw VideoError.invalid("插件图片总像素超界或解码失败")}
            result[asset.assetID]=image
        }
        return RenderResources(images:result)
    }
}
public enum ClassicArtworkMedia {
    public static func load(scene:VideoCore.Scene,workspaceID:String,repository:Repository,database:Database,commercial:Bool,now:Date=Date()) throws -> RenderResources {
        let speechBinding=try CartoonSpeechBinding.from(scene:scene,assets:database.assets.filter{$0.workspaceID==workspaceID})
        guard let artwork=scene.classicArtwork else { return RenderResources(images:[:],speechBinding:speechBinding) }
        try ClassicArtworkRules.validateRights(scene:scene,workspaceID:workspaceID,assets:database.assets,evidence:database.evidence,commercial:commercial,now:now)
        var images:[String:CGImage]=[:],encoded:[String:Data]=[:]
        let imageIDs=Set(artwork.sprites.map(\.assetID))
        let referenced=references(artwork:artwork,database:database).assets
        for id in referenced {
            guard let asset=database.assets.first(where:{$0.id==id && $0.workspaceID==workspaceID}),asset.bytes>0,asset.bytes<=256*1024*1024 else { throw VideoError.permission("经典素材缺失、跨工作区或大小不合法") }
            let data=try Data(contentsOf:repository.assetURL(asset),options:.mappedIfSafe)
            guard data.count==asset.bytes,Codec.hash(data)==asset.hash else { throw VideoError.review("经典游戏原件、图集或录音摘要不符，请重新导入并审核") }
            if imageIDs.contains(id) {
                guard let source=CGImageSourceCreateWithData(data as CFData,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=properties[kCGImagePropertyPixelWidth] as? Int,let h=properties[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=8192,h<=8192,w*h<=24_000_000,let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw VideoError.invalid("经典游戏图集损坏或分辨率超过安全上限") }
                images[id]=image
                // Other image formats retain the existing canonical PNG path.
                // An original is eligible only after the full source hash,
                // rights, actual dimensions and single-image PNG are verified.
                if CGImageSourceGetType(source) as String? == "public.png",CGImageSourceGetCount(source)==1 {
                    let frozen=data.withUnsafeBytes{Data(bytes:$0.baseAddress!,count:$0.count)}
                    guard Codec.hash(frozen)==asset.hash else{throw VideoError.review("已核图集在冻结传输字节时变化，请从原件恢复后重做")}
                    encoded[id]=frozen
                }
                else{encoded[id]=try ScenePainter.png(image)}
            }
        }
        return RenderResources(images:images,encoded:encoded,speechBinding:speechBinding)
    }
    private static func references(artwork:ClassicArtwork,database:Database)->(assets:Set<String>,evidence:Set<String>) {
        var assets=artwork.assetIDs,evidence:Set<String>=[],pending=Array(artwork.evidenceIDs)
        while let id=pending.popLast() {
            guard evidence.insert(id).inserted,let proof=database.evidence.first(where:{$0.id==id}) else{continue}
            if let assetID=proof.assetID {
                assets.insert(assetID)
                if let next=database.assets.first(where:{$0.id==assetID})?.evidenceID{pending.append(next)}
            }
        }
        return(assets,evidence)
    }
    public static func fingerprint(scene:VideoCore.Scene,database:Database) throws -> String? {
        guard let artwork=scene.classicArtwork else { return nil }
        struct Value:Encodable {var artwork:ClassicArtwork;var assets:[Asset];var evidence:[String]}
        let referenced=references(artwork:artwork,database:database)
        let assets=database.assets.filter{referenced.assets.contains($0.id)}.sorted{$0.id<$1.id}
        let evidence=try database.evidence.filter{referenced.evidence.contains($0.id)}.sorted{$0.id<$1.id}.map{try $0.contentDigest()}
        return try Codec.digest(Value(artwork:artwork,assets:assets,evidence:evidence))
    }
}
public enum ClassicSpritePainter {
    public enum ContentMode { case fit, fill }
    public static func draw(_ role:String,artwork:ClassicArtwork,resources:RenderResources,in rect:CGRect,context:CGContext,flip:Bool=false,rotation:CGFloat=0,contentMode:ContentMode = .fit) throws {
        let image=try resources.sprite(role,artwork:artwork)
        context.saveGState();defer{context.restoreGState()}
        // Backgrounds may crop their already validated source viewport to cover
        // a stage. Character and legacy sprite calls retain complete-image fit.
        if contentMode == .fill { context.clip(to:rect) }
        context.translateBy(x:rect.midX,y:rect.midY);context.rotate(by:rotation)
        if flip {context.scaleBy(x:-1,y:1)}
        context.interpolationQuality = artwork.derivation == .original ? .none:.high
        let horizontal=rect.width/CGFloat(image.width),vertical=rect.height/CGFloat(image.height)
        let ratio=contentMode == .fill ? max(horizontal,vertical):min(horizontal,vertical)
        context.draw(image,in:CGRect(x:-CGFloat(image.width)*ratio/2,y:-CGFloat(image.height)*ratio/2,width:CGFloat(image.width)*ratio,height:CGFloat(image.height)*ratio))
    }
}
