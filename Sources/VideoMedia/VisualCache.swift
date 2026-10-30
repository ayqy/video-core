import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import VideoToolbox
import VideoCore

enum VisualClipCache {
    private final class ExportControl: @unchecked Sendable {
        let session:AVAssetExportSession
        init(_ session:AVAssetExportSession) { self.session=session }
        // AVFoundation exposes cancellation concurrently with an asynchronous export.
        func cancel() { session.cancelExport() }
    }
    // Bump for drawing semantics; encoding settings and framework builds are bound separately.
    static let version="native-scene-cache-12"
    struct EncodingConfiguration: Encodable {
        struct FrameworkIdentity: Encodable {
            var expectedIdentifier: String
            var identifier: String?
            var shortVersion: String?
            var buildVersion: String?
            init(expectedIdentifier: String, bundle: Bundle?) {
                self.expectedIdentifier=expectedIdentifier
                identifier=bundle?.bundleIdentifier
                func version(_ key:String)->String? {
                    guard let value=bundle?.object(forInfoDictionaryKey:key) as? String,
                          !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return nil}
                    return value
                }
                shortVersion=version("CFBundleShortVersionString")
                buildVersion=version("CFBundleVersion")
            }
            var isIdentified: Bool { identifier==expectedIdentifier && buildVersion != nil }
        }
        var codec=AVVideoCodecType.h264.rawValue
        var width: Int; var height: Int; var fps: Int
        var averageBitRate=2_500_000
        var allowsFrameReordering=false
        var maximumKeyFrameInterval: Int
        var profileLevel=AVVideoProfileLevelH264HighAutoLevel
        var colorPrimaries=AVVideoColorPrimaries_ITU_R_709_2
        var transferFunction=AVVideoTransferFunction_ITU_R_709_2
        var ycbcrMatrix=AVVideoYCbCrMatrix_ITU_R_709_2
        var pixelFormat=kCVPixelFormatType_32ARGB
        var mediaTimeScale: Int32
        var fileType=AVFileType.mp4.rawValue
        var frameworks: [FrameworkIdentity]
        var encoderIdentity: NativeEncoderIdentity?
        init(aspect: Aspect, fps: Int) {
            width=aspect.width; height=aspect.height; self.fps=fps
            maximumKeyFrameInterval=fps*2; mediaTimeScale=Int32(fps*1000)
            frameworks=[("com.apple.avfoundation","AVFoundation"),("com.apple.VideoToolbox","VideoToolbox")].map { identifier,name in
                let bundle=Bundle(identifier:identifier) ?? Bundle(path:"/System/Library/Frameworks/"+name+".framework")
                return FrameworkIdentity(expectedIdentifier:identifier,bundle:bundle)
            }
        }
        static func capture(aspect:Aspect,fps:Int,selection:NativeEncoderSelection = .automatic) throws -> Self {
            var result=Self(aspect:aspect,fps:fps)
            result.encoderIdentity=try NativeEncoder.resolve(selection,width:result.width,height:result.height,fps:result.fps,
                averageBitRate:result.averageBitRate,allowsFrameReordering:result.allowsFrameReordering,
                maximumKeyFrameInterval:result.maximumKeyFrameInterval,profileLevel:result.profileLevel)
            return result
        }
        var canReusePersistentCache: Bool {
            encoderIdentity?.canReusePersistentCache==true && frameworks.count==2 && Set(frameworks.map(\.expectedIdentifier))==["com.apple.avfoundation","com.apple.VideoToolbox"] && frameworks.allSatisfy(\.isIdentified)
        }
        var writerSettings: [String:Any] {
            var result:[String:Any]=[AVVideoCodecKey:AVVideoCodecType(rawValue:codec),AVVideoWidthKey:width,AVVideoHeightKey:height,
             AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:colorPrimaries,AVVideoTransferFunctionKey:transferFunction,AVVideoYCbCrMatrixKey:ycbcrMatrix],
             AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:averageBitRate,AVVideoExpectedSourceFrameRateKey:fps,AVVideoAllowFrameReorderingKey:allowsFrameReordering,AVVideoMaxKeyFrameIntervalKey:maximumKeyFrameInterval,AVVideoProfileLevelKey:profileLevel]]
            #if os(macOS)
            if let encoderIdentity {result[AVVideoEncoderSpecificationKey]=encoderIdentity.specification}
            #endif
            return result
        }
        var pixelBufferAttributes: [String:Any] {
            [kCVPixelBufferPixelFormatTypeKey as String:pixelFormat,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true]
        }
    }
    struct Key: Encodable {
        var version: String; var cinemaSubtitleStyle: String; var os: String; var font: String; var scene: Scene
        var encoding: EncodingConfiguration
        var purpose: Purpose; var aspect: Aspect; var fps: Int; var index: Int; var sceneCount: Int; var startFrame: Int
        var price: Price?; var cta: String?; var sourceHash: String?; var layerHashes: [String:String];var moduleIdentity:String?; var artworkIdentity:String?
        var cartoonSpeechBinding:CartoonSpeechBinding?=nil
    }
    struct Entry: Codable { var key: String; var bytes: Int; var sha256: String; var frames: Int }
    // Checkpoint packaging does not change drawing semantics or the existing
    // complete-scene fingerprint. A completed legacy scene always wins.
    static let intervalFrames=120
    struct Interval: Codable, Equatable {
        var version="native-scene-interval-1"
        var sceneKey:String
        var lowerBound:Int
        var upperBound:Int
        var frames:Int {upperBound-lowerBound}
        var range:Range<Int> {lowerBound..<upperBound}
        var key:String {get throws {try Codec.digest(self)}}
    }
    struct IntervalEntry: Codable {var interval:Interval;var artifact:Entry}
    private static func valid(_ entry:Entry,key:String,frames:Int,clip:URL)->Bool {
        guard entry.key==key,entry.frames==frames,entry.bytes>0,
              let data=try? Data(contentsOf:clip),data.count==entry.bytes,Codec.hash(data)==entry.sha256 else{return false}
        return true
    }
    private static func touch(_ clip:URL) {try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:clip.path)}
    static func fingerprint(revision: Revision, index: Int, database: Database,modules:RenderModuleRegistry?, encoding:EncodingConfiguration?=nil) throws -> String {
        let encoding=try encoding ?? EncodingConfiguration.capture(aspect:revision.aspect,fps:revision.fps)
        var scene=revision.scenes[index]
        let cartoonSpeechBinding=try CartoonSpeechBinding.from(scene:scene,assets:database.assets.filter{$0.workspaceID==revision.workspaceID})
        scene.voice=nil; scene.speechPlan=nil; scene.voiceGain=1; scene.sourceGain=0; scene.musicGain=0; scene.muted=false
        scene.evidenceIDs=[]; scene.courseMappingIDs=nil; scene.narrativeSources=nil; scene.locked=false
        // Legacy mouth motion depends only on speech presence. New native rig
        // cues and their independently read source binding remain in the key.
        scene.narration=scene.narration.isEmpty ? "":"speech"
        let font=CTFontCreateWithName((scene.fontName ?? "PingFangSC-Medium") as CFString,32,nil)
        let table=CTFontCopyTable(font,0x68656164,[]) as Data? ?? Data() // OpenType 'head' includes font revision.
        let fontID=(CTFontCopyPostScriptName(font) as String)+Codec.hash(table)
        var moduleIdentity:String?
        if RenderModuleRegistry.capability(for:scene.kind) != nil {guard let modules else{throw VideoError.unavailable("需要独立高级模块与有效权益")};let status=try modules.validate(kind:scene.kind);moduleIdentity=status.pluginID+status.version+status.implementationDigest}
        // Only paper data/code changed its visual semantics. Keep the cache
        // identity of ordinary panels and authored drawing-only paper scenes.
        let paperData=scene.paperPresentation != nil && scene.layers?.contains(where:{$0.kind == .chart || $0.kind == .code}) == true
        // Earlier versions held data/entrance layers only. Separate the exact
        // scenes whose ordinary layer now remains visible beyond the source end;
        // unchanged clips keep their existing cache identity.
        let lastSourceFrame=scene.renderSourceFrame(atTimelineFrame:scene.timelineFrames-1)
        let heldFrame=LayerRules.renderSourceFrame(scene:scene,sourceFrame:lastSourceFrame)
        let layerHold=lastSourceFrame != heldFrame && scene.layers?.contains(where:{
            $0.kind != .chart && $0.kind != .code && $0.entrance == nil &&
            $0.startFrame<=heldFrame && $0.endFrame>heldFrame
        }) == true
        let fullFrame=scene.kind == .simulation || scene.kind == .cartoon
        let rendererVersion=version+(paperData ? "-paper-data-1":"")+(layerHold ? "-layer-tail-hold-1":"")+(fullFrame ? "-advanced-full-frame-1":"")
        return try Codec.digest(Key(version:rendererVersion+revision.toolchain,cinemaSubtitleStyle:CinemaSubtitles.styleVersion,os:ProcessInfo.processInfo.operatingSystemVersionString,font:fontID,scene:scene,encoding:encoding,purpose:revision.purpose,aspect:revision.aspect,fps:revision.fps,index:index,sceneCount:revision.scenes.count,startFrame:revision.scenes.prefix(index).reduce(0){$0+$1.timelineFrames},price:scene.showPrice ? try revision.product?.price(at:revision.createdAt):nil,cta:index==revision.scenes.count-1 ? revision.cta:nil,sourceHash:database.assets.first{$0.id==scene.assetID}?.hash,layerHashes:Dictionary(uniqueKeysWithValues:database.assets.filter { a in scene.layers?.contains(where:{$0.assetID==a.id})==true }.map{($0.id,$0.hash)}),moduleIdentity:moduleIdentity,artworkIdentity:try ClassicArtworkMedia.fingerprint(scene:scene,database:database),cartoonSpeechBinding:cartoonSpeechBinding))
    }
    static func compose(revision r: Revision, repository: Repository, database db: Database, output: URL,modules:RenderModuleRegistry?, invocation:RenderInvocation?=nil, encoding:EncodingConfiguration?=nil, videoEncoder:NativeEncoderSelection = .automatic, progress: @escaping @Sendable (Double) throws -> Void) async throws -> Int {
        try invocation?.verify(revision:r)
        // One captured value drives both the key and the actual writer for every scene.
        let encoding=try encoding ?? EncodingConfiguration.capture(aspect:r.aspect,fps:r.fps,selection:videoEncoder)
        guard encoding.width==r.aspect.width,encoding.height==r.aspect.height,encoding.fps==r.fps else {
            throw VideoError.invalid("编码尺寸或帧率与冻结工程不一致")
        }
        let persistent=encoding.canReusePersistentCache
        let directory=repository.root.appendingPathComponent(persistent ? "cache/visuals":"cache/visuals-transient-"+Codec.id())
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        // Missing framework identity must not become a shared "unknown" cache generation.
        defer { if !persistent { try? FileManager.default.removeItem(at:directory) } }
        let composition=AVMutableComposition()
        guard let track=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw VideoError.unavailable("无法建立画面时间轴") }
        var cursor=0, hits=0
        for (index,scene) in r.scenes.enumerated() {
            try Task.checkCancellation(); try invocation?.check()
            if let aid=scene.assetID,let asset=db.assets.first(where:{$0.id==aid}) { let data=try Data(contentsOf:repository.assetURL(asset)); guard data.count==asset.bytes,Codec.hash(data)==asset.hash else { throw VideoError.invalid("源素材摘要不符，拒绝复用缓存") } }
            _ = try ClassicArtworkMedia.load(scene:scene,workspaceID:r.workspaceID,repository:repository,database:db,commercial:r.purpose != .education)
            let key=try fingerprint(revision:r,index:index,database:db,modules:modules,encoding:encoding)
            let clip=directory.appendingPathComponent(key+".mp4"), metadata=directory.appendingPathComponent(key+".plist")
            if let bytes=try? Data(contentsOf:metadata),let entry=try? PropertyListDecoder().decode(Entry.self,from:bytes),
               valid(entry,key:key,frames:scene.timelineFrames,clip:clip) {
                try Task.checkCancellation();try invocation?.check()
                try await insert(clip,frames:scene.timelineFrames,at:cursor,fps:r.fps,into:track)
                try Task.checkCancellation();try invocation?.check()
                hits += 1;touch(clip);cursor += scene.timelineFrames
                try progress(Double(cursor)/Double(r.frames)*0.75)
                continue
            }
            var reusedScene=true
            for lower in stride(from:0,to:scene.timelineFrames,by:intervalFrames) {
                try Task.checkCancellation();try invocation?.check()
                let interval=Interval(sceneKey:key,lowerBound:lower,upperBound:min(lower+intervalFrames,scene.timelineFrames))
                let intervalKey=try interval.key
                let checkpoint=directory.appendingPathComponent(intervalKey+".mp4")
                let receipt=directory.appendingPathComponent(intervalKey+".plist")
                let existing=(try? Data(contentsOf:receipt)).flatMap{try? PropertyListDecoder().decode(IntervalEntry.self,from:$0)}
                if let existing,existing.interval==interval,valid(existing.artifact,key:intervalKey,frames:interval.frames,clip:checkpoint) {
                    touch(checkpoint)
                } else {
                    reusedScene=false
                    let temporary=directory.appendingPathComponent(Codec.id()+".mp4")
                    do {
                        try await renderClip(revision:r,index:index,startFrame:cursor,repository:repository,database:db,output:temporary,modules:modules,invocation:invocation,encoding:encoding,frameRange:interval.range) { local in
                            try progress((Double(cursor+interval.lowerBound)+Double(interval.frames)*local)/Double(r.frames)*0.75)
                        }
                        try Task.checkCancellation();try invocation?.check()
                        let bytes=try Data(contentsOf:temporary)
                        let entry=IntervalEntry(interval:interval,artifact:Entry(key:intervalKey,bytes:bytes.count,sha256:Codec.hash(bytes),frames:interval.frames))
                        let receiptBytes=try PropertyListEncoder().encode(entry)
                        if FileManager.default.fileExists(atPath:checkpoint.path) {try FileManager.default.removeItem(at:checkpoint)}
                        try FileManager.default.moveItem(at:temporary,to:checkpoint)
                        // Publication follows completed encoding and its byte hash.
                        // Interrupted or orphaned files without this atomic receipt
                        // are never eligible for reuse.
                        try receiptBytes.write(to:receipt,options:.atomic)
                    } catch {try? FileManager.default.removeItem(at:temporary);throw error}
                }
                try Task.checkCancellation();try invocation?.check()
                try await insert(checkpoint,frames:interval.frames,at:cursor+interval.lowerBound,fps:r.fps,into:track)
                try Task.checkCancellation();try invocation?.check()
                // A throw here retains the already published checkpoint. Next
                // invocation reports that exact completed range before drawing.
                try progress(Double(cursor+interval.upperBound)/Double(r.frames)*0.75)
            }
            if reusedScene {hits += 1}
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
    private static func insert(_ clip:URL,frames:Int,at frame:Int,fps:Int,into track:AVMutableCompositionTrack) async throws {
        let asset=AVURLAsset(url:clip)
        guard let source=try await asset.loadTracks(withMediaType:.video).first else {throw VideoError.invalid("缓存视频轨道缺失")}
        let duration=CMTime(value:Int64(frames),timescale:Int32(fps))
        let available=try await source.load(.timeRange)
        guard CMTimeCompare(available.start,.zero)==0,CMTimeCompare(available.duration,duration)==0 else {
            throw VideoError.invalid("缓存视频轨道帧区间不完整")
        }
        try track.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:source,at:CMTime(value:Int64(frame),timescale:Int32(fps)))
    }
    static func renderClip(revision r: Revision,index: Int,startFrame: Int,repository: Repository,database db: Database,output: URL,modules:RenderModuleRegistry?,invocation:RenderInvocation?=nil,encoding:EncodingConfiguration,frameRange:Range<Int>?=nil,progress: @escaping (Double) throws -> Void) async throws {
        let scene=r.scenes[index],range=frameRange ?? (0..<r.scenes[index].timelineFrames)
        guard !range.isEmpty,range.lowerBound>=0,range.upperBound<=scene.timelineFrames else {throw VideoError.invalid("镜头缓存区间超出原时间轴")}
        let writer=try AVAssetWriter(outputURL:output,fileType:AVFileType(rawValue:encoding.fileType))
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:encoding.writerSettings); input.mediaTimeScale=encoding.mediaTimeScale;input.expectsMediaDataInRealTime=false
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:encoding.pixelBufferAttributes)
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
            for local in range {
                try Task.checkCancellation(); try invocation?.check()
                while !input.isReadyForMoreMediaData { guard writer.status != .failed else { throw VideoError.unavailable("画面编码失败") };try await Task.sleep(nanoseconds:2_000_000);try Task.checkCancellation(); try invocation?.check() }
                var buffer:CVPixelBuffer?;guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)==kCVReturnSuccess,let buffer else { throw VideoError.unavailable("帧缓冲内存不足") }
                var media=picture
                if let g=generator { let sourceFrame=scene.sourceStartFrame+min(scene.durationFrames-1,Int(Double(local)*scene.speed));media=try g.copyCGImage(at:CMTime(value:Int64(sourceFrame),timescale:Int32(r.fps)),actualTime:nil) }
                CVPixelBufferLockBaseAddress(buffer,[])
                guard let context=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:r.aspect.width,height:r.aspect.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue) else { CVPixelBufferUnlockBaseAddress(buffer,[]);throw VideoError.unavailable("帧缓冲不可用") }
                do { try ScenePainter.draw(revision:r,frame:startFrame+local,in:context,media:media,layerImages:layerImages,resources:resources,modules:modules,invocation:invocation) } catch { CVPixelBufferUnlockBaseAddress(buffer,[]);throw error };CVPixelBufferUnlockBaseAddress(buffer,[])
                guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(local-range.lowerBound),timescale:Int32(r.fps))) else { throw VideoError.unavailable("帧写入失败") }
                if (local-range.lowerBound)%15==0 { try progress(Double(local-range.lowerBound)/Double(range.count)) }
            }
            input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:Int64(range.count),timescale:Int32(r.fps)))
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
