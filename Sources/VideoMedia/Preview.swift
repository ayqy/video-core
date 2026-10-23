import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import VideoCore

public enum MediaPreview {
    /// Uses the same scene selection, media timestamp and layer painter as final encoding.
    public static func image(revision:Revision,frame:Int,repository:Repository,modules:RenderModuleRegistry?=nil,invocation:RenderInvocation?=nil,finishInvocation:Bool=true) throws -> CGImage {
        do {
            try invocation?.verify(revision:revision)
            let result = try draw(revision:revision,frame:frame,repository:repository,modules:modules,invocation:invocation)
            try invocation?.check()
            if finishInvocation, let invocation { try modules?.close(invocationID:invocation.id) }
            return result
        } catch {
            if finishInvocation, let invocation { invocation.cancellation.cancel(); try? modules?.close(invocationID:invocation.id) }
            throw error
        }
    }
    private static func draw(revision:Revision,frame:Int,repository:Repository,modules:RenderModuleRegistry?,invocation:RenderInvocation?) throws -> CGImage {
        guard !revision.scenes.isEmpty,(0..<revision.frames).contains(frame) else { throw VideoError.invalid("预览帧超出版本范围") }
        let db=try repository.read(),(scene,local,_)=ScenePainter.scene(revision:revision,frame:frame)
        var media:CGImage?,layers:[String:CGImage]=[:]
        if let id=scene.assetID,let asset=db.assets.first(where:{$0.id==id && $0.workspaceID==revision.workspaceID}) {
            let url=repository.assetURL(asset)
            if scene.kind == .video { let g=AVAssetImageGenerator(asset:AVURLAsset(url:url));g.appliesPreferredTrackTransform=true;g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter=CMTime(value:1,timescale:Int32(revision.fps));let mapped=scene.sourceStartFrame+min(scene.durationFrames-1,Int(Double(local)*scene.speed));media=try g.copyCGImage(at:CMTime(value:Int64(mapped),timescale:Int32(revision.fps)),actualTime:nil) }
            else if let source=CGImageSourceCreateWithURL(url as CFURL,nil) { media=CGImageSourceCreateImageAtIndex(source,0,nil) }
        }
        for layer in scene.layers ?? [] { if let id=layer.assetID,let asset=db.assets.first(where:{$0.id==id && $0.workspaceID==revision.workspaceID}),let source=CGImageSourceCreateWithURL(repository.assetURL(asset) as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) { layers[id]=image } }
        let resources=try ClassicArtworkMedia.load(scene:scene,workspaceID:revision.workspaceID,repository:repository,database:db,commercial:revision.purpose != .education)
        return try ScenePainter.image(revision:revision,frame:frame,media:media,layerImages:layers,resources:resources,modules:modules,invocation:invocation)
    }
}
