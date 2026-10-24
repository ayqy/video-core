import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import VideoCore

enum VisualClipCache {
    private final class ExportControl: @unchecked Sendable {
        let session:AVAssetExportSession
        init(_ session:AVAssetExportSession) { self.session=session }
        // AVFoundation exposes cancellation concurrently with an asynchronous export.
        func cancel() { session.cancelExport() }
    }
    // Bump whenever layout/codec semantics change. Font bytes and OS are also fingerprinted.
    static let version="native-scene-cache-9"
    struct Key: Encodable {
        var version: String; var os: String; var font: String; var scene: Scene
        var purpose: Purpose; var aspect: Aspect; var fps: Int; var index: Int; var sceneCount: Int; var startFrame: Int
        var price: Price?; var cta: String?; var sourceHash: String?; var layerHashes: [String:String];var moduleIdentity:String?; var artworkIdentity:String?
    }
    struct Entry: Codable { var key: String; var bytes: Int; var sha256: String; var frames: Int }
    static func fingerprint(revision: Revision, index: Int, database: Database,modules:RenderModuleRegistry?) throws -> String {
        var scene=revision.scenes[index]
        scene.voice=nil; scene.speechPlan=nil; scene.voiceGain=1; scene.sourceGain=0; scene.musicGain=0; scene.muted=false
        scene.evidenceIDs=[]; scene.courseMappingIDs=nil; scene.narrativeSources=nil; scene.locked=false
        // Mouth motion only depends on whether speech exists, never on the wording.
        scene.narration=scene.narration.isEmpty ? "":"speech"
        let font=CTFontCreateWithName((scene.fontName ?? "PingFangSC-Medium") as CFString,32,nil)
        let table=CTFontCopyTable(font,0x68656164,[]) as Data? ?? Data() // OpenType 'head' includes font revision.
        let fontID=(CTFontCopyPostScriptName(font) as String)+Codec.hash(table)
        var moduleIdentity:String?
        if RenderModuleRegistry.capability(for:scene.kind) != nil {guard let modules else{throw VideoError.unavailable("需要独立高级模块与有效权益")};let status=try modules.validate(kind:scene.kind);moduleIdentity=status.pluginID+status.version+status.implementationDigest}
        return try Codec.digest(Key(version:version+revision.toolchain,os:ProcessInfo.processInfo.operatingSystemVersionString,font:fontID,scene:scene,purpose:revision.purpose,aspect:revision.aspect,fps:revision.fps,index:index,sceneCount:revision.scenes.count,startFrame:revision.scenes.prefix(index).reduce(0){$0+$1.timelineFrames},price:scene.showPrice ? try revision.product?.price(at:revision.createdAt):nil,cta:index==revision.scenes.count-1 ? revision.cta:nil,sourceHash:database.assets.first{$0.id==scene.assetID}?.hash,layerHashes:Dictionary(uniqueKeysWithValues:database.assets.filter { a in scene.layers?.contains(where:{$0.assetID==a.id})==true }.map{($0.id,$0.hash)}),moduleIdentity:moduleIdentity,artworkIdentity:try ClassicArtworkMedia.fingerprint(scene:scene,database:database)))
    }
    static func compose(revision r: Revision, repository: Repository, database db: Database, output: URL,modules:RenderModuleRegistry?, invocation:RenderInvocation?=nil, progress: @escaping @Sendable (Double) throws -> Void) async throws -> Int {
        try invocation?.verify(revision:r)
        let directory=repository.root.appendingPathComponent("cache/visuals")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let composition=AVMutableComposition()
        guard let track=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw VideoError.unavailable("无法建立画面时间轴") }
        var cursor=0, hits=0
        for (index,scene) in r.scenes.enumerated() {
            try Task.checkCancellation(); try invocation?.check()
            if let aid=scene.assetID,let asset=db.assets.first(where:{$0.id==aid}) { let data=try Data(contentsOf:repository.assetURL(asset)); guard data.count==asset.bytes,Codec.hash(data)==asset.hash else { throw VideoError.invalid("源素材摘要不符，拒绝复用缓存") } }
            _ = try ClassicArtworkMedia.load(scene:scene,workspaceID:r.workspaceID,repository:repository,database:db,commercial:r.purpose != .education)
            let key=try fingerprint(revision:r,index:index,database:db,modules:modules)
            let clip=directory.appendingPathComponent(key+".mp4"), metadata=directory.appendingPathComponent(key+".plist")
            var valid=false
            if let bytes=try? Data(contentsOf:metadata), let entry=try? PropertyListDecoder().decode(Entry.self,from:bytes), entry.key==key,entry.frames==scene.timelineFrames,let data=try? Data(contentsOf:clip),data.count==entry.bytes,Codec.hash(data)==entry.sha256 { valid=true; hits += 1; try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:clip.path) }
            if !valid {
                let temporary=directory.appendingPathComponent(Codec.id()+".mp4")
                do {
                    try await renderClip(revision:r,index:index,startFrame:cursor,repository:repository,database:db,output:temporary,modules:modules,invocation:invocation) { local in try progress((Double(cursor)+Double(scene.timelineFrames)*local)/Double(r.frames)*0.75) }
                    try invocation?.check()
                    let bytes=try Data(contentsOf:temporary); let entry=Entry(key:key,bytes:bytes.count,sha256:Codec.hash(bytes),frames:scene.timelineFrames)
                    if FileManager.default.fileExists(atPath:clip.path) { try FileManager.default.removeItem(at:clip) }
                    try FileManager.default.moveItem(at:temporary,to:clip); try PropertyListEncoder().encode(entry).write(to:metadata,options:.atomic)
                } catch { try? FileManager.default.removeItem(at:temporary); throw error }
            }
            let asset=AVURLAsset(url:clip)
            guard let source=try await asset.loadTracks(withMediaType:.video).first else { throw VideoError.invalid("缓存视频轨道缺失") }
            try track.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(value:Int64(scene.timelineFrames),timescale:Int32(r.fps))),of:source,at:CMTime(value:Int64(cursor),timescale:Int32(r.fps)))
            cursor += scene.timelineFrames
        }
        guard let exporter=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else { throw VideoError.unavailable("无法建立镜头合成器") }
        exporter.outputURL=output; exporter.outputFileType = .mp4; exporter.timeRange=CMTimeRange(start:.zero,duration:CMTime(value:Int64(r.frames),timescale:Int32(r.fps)))
        let control=ExportControl(exporter)
        await withTaskCancellationHandler(operation:{ await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in exporter.exportAsynchronously { c.resume() } } },onCancel:{ control.cancel() })
        try Task.checkCancellation(); try invocation?.check(); guard exporter.status == .completed else { throw VideoError.unavailable("镜头合成未完成") }
        trim(directory:directory,limit:256*1024*1024)
        return hits
    }
    static func renderClip(revision r: Revision,index: Int,startFrame: Int,repository: Repository,database db: Database,output: URL,modules:RenderModuleRegistry?,invocation:RenderInvocation?=nil,progress: @escaping (Double) throws -> Void) async throws {
        let scene=r.scenes[index]; let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
        let settings:[String:Any]=[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:r.aspect.width,AVVideoHeightKey:r.aspect.height,AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2],AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:2_500_000,AVVideoExpectedSourceFrameRateKey:r.fps,AVVideoAllowFrameReorderingKey:false,AVVideoMaxKeyFrameIntervalKey:r.fps*2,AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel]]
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:settings); input.mediaTimeScale=Int32(r.fps*1000);input.expectsMediaDataInRealTime=false
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:r.aspect.width,kCVPixelBufferHeightKey as String:r.aspect.height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        guard writer.canAdd(input) else { throw VideoError.unavailable("当前设备不支持H.264输出") };writer.add(input);guard writer.startWriting() else { throw VideoError.unavailable("画面编码无法启动") };writer.startSession(atSourceTime:.zero)
        var generator:AVAssetImageGenerator?, picture:CGImage?
        let resources=try ClassicArtworkMedia.load(scene:scene,workspaceID:r.workspaceID,repository:repository,database:db,commercial:r.purpose != .education)
        var layerImages:[String:CGImage]=[:]
        for layer in scene.layers ?? [] { if let id=layer.assetID,let a=db.assets.first(where:{$0.id==id}),let source=CGImageSourceCreateWithURL(repository.assetURL(a) as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil){layerImages[id]=image} }
        if let aid=scene.assetID, let asset=db.assets.first(where:{$0.id==aid}) {
            let url=repository.assetURL(asset)
            if scene.kind == .video { let g=AVAssetImageGenerator(asset:AVURLAsset(url:url));g.appliesPreferredTrackTransform=true;g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter=CMTime(value:1,timescale:Int32(r.fps));generator=g }
            else if let source=CGImageSourceCreateWithURL(url as CFURL,nil) { picture=CGImageSourceCreateImageAtIndex(source,0,nil) }
        }
        do {
            for local in 0..<scene.timelineFrames {
                try Task.checkCancellation(); try invocation?.check()
                while !input.isReadyForMoreMediaData { guard writer.status != .failed else { throw VideoError.unavailable("画面编码失败") };try await Task.sleep(nanoseconds:2_000_000);try Task.checkCancellation(); try invocation?.check() }
                var buffer:CVPixelBuffer?;guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)==kCVReturnSuccess,let buffer else { throw VideoError.unavailable("帧缓冲内存不足") }
                var media=picture
                if let g=generator { let sourceFrame=scene.sourceStartFrame+min(scene.durationFrames-1,Int(Double(local)*scene.speed));media=try g.copyCGImage(at:CMTime(value:Int64(sourceFrame),timescale:Int32(r.fps)),actualTime:nil) }
                CVPixelBufferLockBaseAddress(buffer,[])
                guard let context=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:r.aspect.width,height:r.aspect.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue) else { CVPixelBufferUnlockBaseAddress(buffer,[]);throw VideoError.unavailable("帧缓冲不可用") }
                do { try ScenePainter.draw(revision:r,frame:startFrame+local,in:context,media:media,layerImages:layerImages,resources:resources,modules:modules,invocation:invocation) } catch { CVPixelBufferUnlockBaseAddress(buffer,[]);throw error };CVPixelBufferUnlockBaseAddress(buffer,[])
                guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(local),timescale:Int32(r.fps))) else { throw VideoError.unavailable("帧写入失败") }
                if local%15==0 { try progress(Double(local)/Double(scene.timelineFrames)) }
            }
            input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:Int64(scene.timelineFrames),timescale:Int32(r.fps)))
            await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in writer.finishWriting { c.resume() } };guard writer.status == .completed else { throw VideoError.unavailable("镜头画面未完成") }
        } catch { writer.cancelWriting();throw error }
    }
    static func trim(directory: URL, limit: Int) {
        let fm=FileManager.default
        guard let files=try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey]) else { return }
        let clips=files.filter{$0.pathExtension=="mp4"}.compactMap { url -> (URL,Int,Date)? in guard let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]),let size=values.fileSize else { return nil };return(url,size,values.contentModificationDate ?? .distantPast) }.sorted{$0.2<$1.2}
        var total=clips.reduce(0){$0+$1.1};for (url,size,_) in clips where total>limit { try? fm.removeItem(at:url);try? fm.removeItem(at:url.deletingPathExtension().appendingPathExtension("plist"));total-=size }
    }
}
