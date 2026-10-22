import Foundation
import CoreGraphics
import ImageIO
import VideoCore

/// CGImage is immutable. The bank is built only after file hashes, workspace and rights are checked.
public struct RenderResources: @unchecked Sendable {
    private let images: [String:CGImage]
    public static let empty = RenderResources(images:[:])
    fileprivate init(images:[String:CGImage]) { self.images=images }
    public func sprite(_ role:String,artwork:ClassicArtwork) throws -> CGImage {
        guard let cell=artwork.sprites.first(where:{$0.role==role}),let image=images[cell.assetID] else { throw VideoError.notFound("外部图集角色未加载："+role) }
        let rect=CGRect(x:cell.x*Double(image.width),y:cell.y*Double(image.height),width:cell.width*Double(image.width),height:cell.height*Double(image.height)).integral
        guard rect.width>0,rect.height>0,rect.minX>=0,rect.minY>=0,rect.maxX<=CGFloat(image.width),rect.maxY<=CGFloat(image.height),let cropped=image.cropping(to:rect) else { throw VideoError.invalid("外部图块无法按已保存区域裁切") }
        return cropped
    }
}
public enum ClassicArtworkMedia {
    public static func load(scene:VideoCore.Scene,workspaceID:String,repository:Repository,database:Database,commercial:Bool,now:Date=Date()) throws -> RenderResources {
        guard let artwork=scene.classicArtwork else { return .empty }
        try ClassicArtworkRules.validateRights(scene:scene,workspaceID:workspaceID,assets:database.assets,evidence:database.evidence,commercial:commercial,now:now)
        var images:[String:CGImage]=[:]
        let imageIDs=Set(artwork.sprites.map(\.assetID))
        let referenced=references(artwork:artwork,database:database).assets
        for id in referenced {
            guard let asset=database.assets.first(where:{$0.id==id && $0.workspaceID==workspaceID}),asset.bytes>0,asset.bytes<=256*1024*1024 else { throw VideoError.permission("经典素材缺失、跨工作区或大小不合法") }
            let data=try Data(contentsOf:repository.assetURL(asset),options:.mappedIfSafe)
            guard data.count==asset.bytes,Codec.hash(data)==asset.hash else { throw VideoError.review("经典游戏原件、图集或录音摘要不符，请重新导入并审核") }
            if imageIDs.contains(id) {
                guard let source=CGImageSourceCreateWithData(data as CFData,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=properties[kCGImagePropertyPixelWidth] as? Int,let h=properties[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=8192,h<=8192,w*h<=24_000_000,let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw VideoError.invalid("经典游戏图集损坏或分辨率超过安全上限") }
                images[id]=image
            }
        }
        return RenderResources(images:images)
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
    public static func draw(_ role:String,artwork:ClassicArtwork,resources:RenderResources,in rect:CGRect,context:CGContext,flip:Bool=false,rotation:CGFloat=0) throws {
        let image=try resources.sprite(role,artwork:artwork)
        context.saveGState();defer{context.restoreGState()}
        context.translateBy(x:rect.midX,y:rect.midY);context.rotate(by:rotation)
        if flip {context.scaleBy(x:-1,y:1)}
        context.interpolationQuality = artwork.derivation == .original ? .none:.high
        let ratio=min(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height))
        context.draw(image,in:CGRect(x:-CGFloat(image.width)*ratio/2,y:-CGFloat(image.height)*ratio/2,width:CGFloat(image.width)*ratio,height:CGFloat(image.height)*ratio))
    }
}
