import XCTest
import VideoCore
@testable import VideoMedia
@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics
import CryptoKit

final class VisualCacheResumeTests:XCTestCase {
    private enum Interrupted:Error {case checkpoint}
    private final class Progress:@unchecked Sendable {
        private let lock=NSLock()
        private var storage:[Double]=[]
        let stop:Double?
        init(stop:Double?=nil) {self.stop=stop}
        func record(_ value:Double)throws {
            lock.lock();storage.append(value);lock.unlock()
            if let stop,value>=stop {throw Interrupted.checkpoint}
        }
        var values:[Double] {lock.lock();defer{lock.unlock()};return storage}
    }
    private func repository()throws->(URL,Repository,Workspace) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("visual-checkpoints-"+UUID().uuidString)
        let repo=try Repository(root:root),workspace=Workspace(name:"完整区间恢复",owner:"tester")
        try repo.transaction{$0.workspaces=[workspace]}
        return(root,repo,workspace)
    }
    private func configuration(_ revision:Revision)throws->VisualClipCache.EncodingConfiguration {
        let result=try VisualClipCache.EncodingConfiguration.capture(aspect:revision.aspect,fps:revision.fps)
        guard result.canReusePersistentCache else {throw XCTSkip("此机器没有完整可识别的编码器与框架，原有transient测试覆盖此分支")}
        return result
    }
    private func revision(_ workspace:Workspace,frames:Int=247)->Revision {
        var scene=Scene(title:"分段恢复",body:"同一时间轴，完成区间保留。",durationFrames:frames)
        scene.paperPresentation=PaperPresentation()
        var block=SceneLayer(kind:.rectangle,endFrame:frames)
        block.x=0.2;block.y=0.45;block.width=0.16;block.height=0.18;block.color="E54B4B"
        block.keyframes=[Keyframe(frame:0,x:0.2,y:0.45,scale:1),Keyframe(frame:frames-1,x:0.8,y:0.45,scale:1)]
        scene.layers=[block]
        scene.captions=[Caption(text:"上一段动作持续",startFrame:0,endFrame:120),Caption(text:"跨过边界继续",startFrame:120,endFrame:frames)]
        return Revision(contentContext:ContentContext(workspaceID:workspace.id,name:"同一源轴"),aspect:.landscape,scenes:[scene])
    }
    private func interval(_ revision:Revision,index:Int=0,range:Range<Int>,repo:Repository,
                          encoding:VisualClipCache.EncodingConfiguration,modules:RenderModuleRegistry?=nil)throws->(VisualClipCache.Interval,URL,URL) {
        let key=try VisualClipCache.fingerprint(revision:revision,index:index,database:repo.read(),modules:modules,encoding:encoding)
        let interval=VisualClipCache.Interval(sceneKey:key,lowerBound:range.lowerBound,upperBound:range.upperBound)
        let directory=repo.root.appendingPathComponent("cache/visuals"),name=try interval.key
        return(interval,directory.appendingPathComponent(name+".mp4"),directory.appendingPathComponent(name+".plist"))
    }
    private func compose(_ revision:Revision,repo:Repository,encoding:VisualClipCache.EncodingConfiguration,
                         name:String,progress:Progress=Progress(),modules:RenderModuleRegistry?=nil,
                         invocation:RenderInvocation?=nil)async throws->(Int,URL) {
        let output=repo.root.appendingPathComponent(name+".mp4")
        let hits=try await VisualClipCache.compose(revision:revision,repository:repo,database:repo.read(),output:output,
            modules:modules,invocation:invocation,encoding:encoding,progress:{try progress.record($0)})
        return(hits,output)
    }
    private struct Pixels {var points:[[Int]]}
    private func decode(_ url:URL,frames:Int,fps:Int=30)async throws->[Pixels] {
        let asset=AVURLAsset(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.video),track=try XCTUnwrap(tracks.first)
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData=false;reader.add(output);XCTAssertTrue(reader.startReading())
        var result:[Pixels]=[]
        while let sample=output.copyNextSampleBuffer() {
            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value:Int64(result.count),timescale:Int32(fps))),0,
                           "每一帧PTS必须连续，区间边界不能重播、漏帧或插入空隙")
            let buffer=try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            guard let address=CVPixelBufferGetBaseAddress(buffer) else {CVPixelBufferUnlockBaseAddress(buffer,.readOnly);throw VideoError.invalid("测试解码没有像素")}
            let bytes=address.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(buffer)
            let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer)
            var points:[[Int]]=[]
            for y in [height/5,height/2,height*4/5] {for x in [width/5,width/2,width*4/5] {
                var rgb=[0,0,0]
                for dy in -2...2 {for dx in -2...2 {
                    let offset=(y+dy)*stride+(x+dx)*4
                    rgb[0]+=Int(bytes[offset+2]);rgb[1]+=Int(bytes[offset+1]);rgb[2]+=Int(bytes[offset])
                }}
                points.append(rgb.map{$0/25})
            }}
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly);result.append(Pixels(points:points))
        }
        XCTAssertEqual(reader.status,.completed);XCTAssertEqual(result.count,frames)
        let duration=try await asset.load(.duration)
        XCTAssertEqual(CMTimeCompare(duration,CMTime(value:Int64(frames),timescale:Int32(fps))),0)
        return result
    }

    func testHostAudioChangesAndListeningDoNotChangeVisualFingerprint()throws {
        let workspace=Workspace(name:"Host音效画面缓存边界",owner:"rules")
        let original=revision(workspace)
        let encoding=try VisualClipCache.EncodingConfiguration.capture(aspect:original.aspect,fps:original.fps)
        let first=Asset(workspaceID:workspace.id,name:"first-rule.wav",hash:String(repeating:"a",count:64),ext:"wav",bytes:100,mediaType:"audio",durationFrames:30)
        let second=Asset(workspaceID:workspace.id,name:"second-rule.wav",hash:String(repeating:"b",count:64),ext:"wav",bytes:100,mediaType:"audio",durationFrames:30)
        var database=Database();database.assets=[first,second]
        func key(_ value:Revision)throws->String {
            try VisualClipCache.fingerprint(revision:value,index:0,database:database,modules:nil,encoding:encoding)
        }
        let baseline=try key(original)
        var withCue=original
        withCue.scenes[0].audioCues=[ClassicAudioCue(assetID:first.id,startFrame:30,durationFrames:30,gain:0.25)]
        try withCue.scenes[0].validate(assets:database.assets)
        XCTAssertNotEqual(try Codec.data(original.scenes[0]),try Codec.data(withCue.scenes[0]),"工程确有新增音效输入")
        XCTAssertEqual(try key(withCue),baseline)
        for edit in 0..<5 {
            var changed=withCue
            switch edit {
            case 0:changed.scenes[0].audioCues?[0].assetID=second.id
            case 1:changed.scenes[0].audioCues?[0].startFrame=60
            case 2:changed.scenes[0].audioCues?[0].durationFrames=15
            case 3:changed.scenes[0].audioCues?[0].gain=0.8
            default:changed.scenes[0].audioCues?[0].listened=true
            }
            try changed.scenes[0].validate(assets:database.assets)
            XCTAssertNotEqual(try Codec.data(changed.scenes[0]),try Codec.data(withCue.scenes[0]))
            XCTAssertEqual(try key(changed),baseline,"只改真实音效来源、时窗、音量或试听声明不能重绘画面")
        }
        var visualChange=withCue;visualChange.scenes[0].layers?[0].color="2563EB"
        XCTAssertNotEqual(try key(visualChange),baseline,"画面图层变化仍须使画面缓存失效")
    }

    /// Isolated metadata authority; a fingerprint test must never draw a model
    /// or substitute this fixture for the installed trusted production Host.
    private struct FingerprintOnlyModule:ScopedSceneRenderModule {
        let manifest:PluginManifest
        func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext)throws {
            throw VideoError.unavailable("指纹规则夹具禁止实际绘图")
        }
        func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext,resources:RenderResources,invocation:RenderInvocation)throws {
            throw VideoError.unavailable("指纹规则夹具禁止实际绘图")
        }
        func close(invocationID:String)throws {}
    }

    /// The existing scoped-model and solid-painter rule-fixture pattern: verify
    /// the real Host-frozen source bank and actually paint every requested frame.
    /// This isolates cache/cadence behavior, not production SceneKit appearance.
    private final class ModelFrameModule:ScopedSceneRenderModule,@unchecked Sendable {
        let manifest:PluginManifest
        private let lock=NSLock()
        private var storage:[Int]=[]
        init(_ manifest:PluginManifest){self.manifest=manifest}
        var frames:[Int] {lock.lock();defer{lock.unlock()};return storage}
        func reset(){lock.lock();storage.removeAll();lock.unlock()}
        func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext)throws {
            throw VideoError.permission("三维缓存夹具必须使用真实scoped绘制入口")
        }
        func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext,
                  resources:RenderResources,invocation:RenderInvocation)throws {
            try invocation.check()
            guard let model=scene.modelScene3D,let bank=resources.modelBank,
                  bank.manifest == (try PluginModelBankManifest(scene:model,durationFrames:scene.durationFrames)) else {
                throw VideoError.permission("三维缓存夹具缺少当前完整原模型字节库")
            }
            lock.lock();storage.append(localFrame);lock.unlock()
            // Widely separated absolute-source markers survive normal color
            // conversion without assuming decoded RGB equals input RGB *255.
            let colors:[[CGFloat]]=[[0.85,0.12,0.12,1],[0.12,0.85,0.12,1],[0.12,0.12,0.85,1]]
            let selected=localFrame<30 ? 0:localFrame<60 ? 1:2
            guard let space=CGColorSpace(name:CGColorSpace.sRGB),let color=CGColor(colorSpace:space,components:colors[selected]) else {
                throw VideoError.invalid("无法构造测试源帧的显式sRGB标记")
            }
            context.setFillColor(color);context.fill(rect)
        }
        func close(invocationID:String)throws {}
    }

    private func modelFixture(_ repo:Repository,_ workspace:Workspace)throws->(Revision,RenderModuleRegistry,ModelFrameModule,RenderInvocation) {
        let xml="""
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><created>2026-11-05T00:00:00Z</created><modified>2026-11-05T00:00:00Z</modified><unit name="meter" meter="1"/><up_axis>Y_UP</up_axis></asset>
        <library_geometries><geometry id="triangle"><mesh><source id="positions"><float_array id="position-array" count="9">0 0 0 1 0 0 0 1 0</float_array><technique_common><accessor source="#position-array" count="3" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source><vertices id="vertices"><input semantic="POSITION" source="#positions"/></vertices><triangles count="1"><input semantic="VERTEX" source="#vertices" offset="0"/><p>0 1 2</p></triangles></mesh></geometry></library_geometries>
        <library_visual_scenes><visual_scene id="stage"><node id="mesh"><instance_geometry url="#triangle"/></node></visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#stage"/></scene></COLLADA>
        """
        let bytes=Data(xml.utf8)
        var asset=try repo.ingest(bytes,name:"checkpoint-triangle.dae",workspaceID:workspace.id,mediaType:"model3d")
        let evidence=Evidence(workspaceID:workspace.id,title:"本测试自制三角网格",source:"isolated cache rule fixture",claim:"authored triangle",owner:"tester",commercialAllowed:true,verified:true,assetID:asset.id)
        asset.evidenceID=evidence.id
        try repo.transaction{$0.assets=[asset];$0.evidence=[evidence]}
        let resource=ModelDAEResource(model:.init(asset:asset),inspection:try DAEInspector.inspect(bytes),textures:[:])
        var scene=Scene(kind:.simulation,title:"三维分片源轴",body:"隔离绘制规则",durationFrames:82)
        scene.modelScene3D=ModelScene3D(instances:[.init(id:"mesh",name:"自制规则网格",resource:resource)],
            camera:.init(position:.init(x:0,y:2,z:5),target:.init()),lights:[.init(id:"sun",kind:.directional)])
        try scene.validate(assets:[asset])
        let r=Revision(contentContext:ContentContext(workspaceID:workspace.id,name:"三维30帧恢复"),aspect:.landscape,scenes:[scene])
        let key=Curve25519.Signing.PrivateKey(),registry=RenderModuleRegistry()
        let manifest=PluginManifest(id:"video.game",version:"isolated-cache-rule",capabilities:["game.simulate"],inputSchema:10,
            implementationDigest:try BuiltinExecutableIdentity.current().digest,permissions:[])
        let module=ModelFrameModule(manifest),policy=CommercialPolicy(pluginID:manifest.id,version:1,access:"free",updatedAt:Date(),sourceVisibility:"closed")
        func signed<T:Encodable>(_ value:T)throws->SignedDocument {let raw=try Codec.data(value);return SignedDocument(payload:raw,signature:try key.signature(for:raw))}
        try registry.register(module,signedManifest:signed(manifest),signedPolicy:signed(policy),publicKey:key.publicKey.rawRepresentation)
        let scope=RenderInvocation(workspaceID:workspace.id,projectID:"isolated-cache-rules",revisionID:r.id,
            revisionDigest:try r.contentDigest(),jobID:nil,budgetReference:"isolated-cache-rules",budgetLimit:Money(0),
            deadline:Date().addingTimeInterval(300),authorization:{})
        return(r,registry,module,scope)
    }

    func testNativeVisualChangesStillInvalidateFingerprintWithHostAudioCues()throws {
        let workspace=Workspace(name:"三维画面指纹",owner:"rules")
        let xml="""
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><unit meter="1"/><up_axis>Y_UP</up_axis></asset>
        <library_geometries><geometry id="triangle"><mesh><source id="positions"><float_array id="position-array" count="9">0 0 0 1 0 0 0 1 0</float_array></source></mesh></geometry></library_geometries>
        <library_visual_scenes><visual_scene id="stage"><node id="mesh"><instance_geometry url="#triangle"/></node></visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#stage"/></scene></COLLADA>
        """
        let bytes=Data(xml.utf8)
        let mesh=Asset(workspaceID:workspace.id,name:"authored-fingerprint.dae",hash:Codec.hash(bytes),ext:"dae",bytes:bytes.count,mediaType:"model3d")
        let resource=ModelDAEResource(model:.init(asset:mesh),inspection:try DAEInspector.inspect(bytes),textures:[:])
        let audio=Asset(workspaceID:workspace.id,name:"rule-event.wav",hash:String(repeating:"c",count:64),ext:"wav",bytes:100,mediaType:"audio",durationFrames:30)
        var scene=Scene(kind:.simulation,title:"真实三维IR指纹",body:"只检查输入键，不画图或审批。",durationFrames:60)
        scene.modelScene3D=ModelScene3D(instances:[.init(id:"mesh",name:"自制规则网格",resource:resource)],camera:.init(position:.init(x:0,y:2,z:5),target:.init()),lights:[.init(id:"sun",kind:.directional)])
        scene.audioCues=[ClassicAudioCue(assetID:audio.id,startFrame:0,durationFrames:30,gain:0.25)]
        try scene.validate(assets:[mesh,audio])
        let original=Revision(contentContext:ContentContext(workspaceID:workspace.id,name:"三维画面指纹"),aspect:.landscape,scenes:[scene])
        let encoding=try VisualClipCache.EncodingConfiguration.capture(aspect:original.aspect,fps:original.fps)
        let authority=Curve25519.Signing.PrivateKey(),registry=RenderModuleRegistry()
        let manifest=PluginManifest(id:"video.game",version:"fingerprint-rule",capabilities:["game.simulate"],inputSchema:10,implementationDigest:try BuiltinExecutableIdentity.current().digest,permissions:[])
        let policy=CommercialPolicy(pluginID:manifest.id,version:1,access:"free",updatedAt:Date(),sourceVisibility:"closed")
        func signed<T:Encodable>(_ value:T)throws->SignedDocument {let raw=try Codec.data(value);return SignedDocument(payload:raw,signature:try authority.signature(for:raw))}
        try registry.register(FingerprintOnlyModule(manifest:manifest),signedManifest:signed(manifest),signedPolicy:signed(policy),publicKey:authority.publicKey.rawRepresentation)
        var database=Database();database.assets=[mesh,audio]
        func key(_ value:Revision)throws->String {
            try VisualClipCache.fingerprint(revision:value,index:0,database:database,modules:registry,encoding:encoding)
        }
        let baseline=try key(original)
        var heard=original;heard.scenes[0].audioCues?[0].listened=true
        XCTAssertEqual(try key(heard),baseline)
        for edit in 0..<3 {
            var changed=original
            switch edit {
            case 0:changed.scenes[0].modelScene3D?.camera.target.x=0.3
            case 1:changed.scenes[0].modelScene3D?.instances[0].transform.translation.x=0.3
            default:changed.scenes[0].modelScene3D?.lights[0].intensity=0.4
            }
            try changed.scenes[0].validate(assets:database.assets)
            XCTAssertNotEqual(try key(changed),baseline,"相机、原生实例或光照变化仍须使缓存失效")
        }
    }

    func testInterruptedSecondIntervalRetainsAndReusesTheFirstCompleteCheckpoint()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let r=revision(workspace),encoding=try configuration(r)
        let stop=Progress(stop:Double(120+15)/Double(r.frames)*0.75)
        do {_=try await compose(r,repo:repo,encoding:encoding,name:"interrupted",progress:stop);XCTFail("应在第二个区间中断")}
        catch Interrupted.checkpoint {}
        let(_,first,receipt)=try interval(r,range:0..<120,repo:repo,encoding:encoding)
        let saved=try Data(contentsOf:first),savedReceipt=try Data(contentsOf:receipt)
        let inode=(try FileManager.default.attributesOfItem(atPath:first.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        let files=try FileManager.default.contentsOfDirectory(at:first.deletingLastPathComponent(),includingPropertiesForKeys:nil)
        XCTAssertEqual(files.filter{$0.pathExtension=="mp4"}.count,1,"未完成的第二区间须删除，已完成首区间须保留")
        XCTAssertEqual(files.filter{$0.pathExtension=="plist"}.count,1)
        let progress=Progress(),(hits,resumed)=try await compose(r,repo:repo,encoding:encoding,name:"resumed",progress:progress)
        XCTAssertEqual(hits,0,"部分区间命中不能冒称整个scene命中")
        XCTAssertEqual(try XCTUnwrap(progress.values.first),Double(120)/Double(r.frames)*0.75,accuracy:0.0000001,
                       "恢复须先报告已有完整区间，不能重新绘制帧零")
        XCTAssertEqual(try Data(contentsOf:first),saved);XCTAssertEqual(try Data(contentsOf:receipt),savedReceipt)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:first.path)[.systemFileNumber] as? NSNumber)?.uint64Value,inode)
        _=try await decode(resumed,frames:r.frames)
        let(cached,again)=try await compose(r,repo:repo,encoding:encoding,name:"all-cached")
        XCTAssertEqual(cached,1);_=try await decode(again,frames:r.frames)
    }

    func testModelThirtyFrameCheckpointResumesWithContinuousSourceFramesAndTwentyTwoFrameTail()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let(r,registry,module,scope)=try modelFixture(repo,workspace),encoding=try configuration(r)
        defer{try? registry.close(invocationID:scope.id)}
        let stop=Progress(stop:Double(30+15)/Double(r.frames)*0.75)
        do {_=try await compose(r,repo:repo,encoding:encoding,name:"model-interrupted",progress:stop,modules:registry,invocation:scope);XCTFail("应在第二个三维30帧区间中断")}
        catch Interrupted.checkpoint {}
        XCTAssertEqual(module.frames,Array(0...45),"实际draw必须先连续到达第二个区间；不能用只算指纹的夹具代替")
        let(_,first,receipt)=try interval(r,range:0..<30,repo:repo,encoding:encoding,modules:registry)
        let saved=try Data(contentsOf:first),savedReceipt=try Data(contentsOf:receipt)
        let inode=(try FileManager.default.attributesOfItem(atPath:first.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        let directory=first.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).count,2,"只保留完成首30帧及原子清单，未完成第二段必须清理")
        module.reset();let progress=Progress()
        let(hits,resumed)=try await compose(r,repo:repo,encoding:encoding,name:"model-resumed",progress:progress,modules:registry,invocation:scope)
        XCTAssertEqual(hits,0);XCTAssertEqual(module.frames,Array(30..<82),"复用首30帧后，剩余真实源帧必须逐帧连续且不重播零帧")
        XCTAssertEqual(try XCTUnwrap(progress.values.first),Double(30)/Double(r.frames)*0.75,accuracy:0.0000001)
        XCTAssertEqual(try Data(contentsOf:first),saved);XCTAssertEqual(try Data(contentsOf:receipt),savedReceipt)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:first.path)[.systemFileNumber] as? NSNumber)?.uint64Value,inode)
        let pixels=try await decode(resumed,frames:82)
        for frame in [0,29,30,59,60,81] {
            let rgb=pixels[frame].points[4]
            let dominant=frame<30 ? 0:frame<60 ? 1:2
            for channel in 0..<3 where channel != dominant {
                XCTAssertGreaterThanOrEqual(rgb[dominant]-rgb[channel],60,"绝对源帧\(frame)须属于自己的RGB色段；不能重播前段、错位或回到零帧")
            }
        }
        let(_,last,tailReceipt)=try interval(r,range:60..<82,repo:repo,encoding:encoding,modules:registry)
        let tail=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:tailReceipt))
        XCTAssertEqual(tail.interval.lowerBound,60);XCTAssertEqual(tail.interval.upperBound,82);XCTAssertEqual(tail.artifact.frames,22)
        _=try await decode(last,frames:22)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).count,6)
        module.reset();let(cached,_)=try await compose(r,repo:repo,encoding:encoding,name:"model-all-cached",modules:registry,invocation:scope)
        XCTAssertEqual(cached,1);XCTAssertTrue(module.frames.isEmpty)
    }

    func testModelCorruptThirtyFrameCheckpointRedrawsOnlyItsRangeAndLegacyWholeStillWins()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let(r,registry,module,scope)=try modelFixture(repo,workspace),encoding=try configuration(r)
        defer{try? registry.close(invocationID:scope.id)}
        _=try await compose(r,repo:repo,encoding:encoding,name:"model-original",modules:registry,invocation:scope)
        let(_,first,receipt)=try interval(r,range:0..<30,repo:repo,encoding:encoding,modules:registry)
        let(_,second,_)=try interval(r,range:30..<60,repo:repo,encoding:encoding,modules:registry)
        let(_,tail,_)=try interval(r,range:60..<82,repo:repo,encoding:encoding,modules:registry)
        let secondBytes=try Data(contentsOf:second),tailBytes=try Data(contentsOf:tail)
        try Data("truncated".utf8).write(to:first,options:.atomic);module.reset()
        let(hits,repaired)=try await compose(r,repo:repo,encoding:encoding,name:"model-repaired",modules:registry,invocation:scope)
        XCTAssertEqual(hits,0);XCTAssertEqual(module.frames,Array(0..<30),"坏三维分片必须实际重绘，邻接完成分片不能重画")
        XCTAssertEqual(try Data(contentsOf:second),secondBytes);XCTAssertEqual(try Data(contentsOf:tail),tailBytes)
        let repairedEntry=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt))
        XCTAssertEqual(repairedEntry.artifact.frames,30);XCTAssertEqual(repairedEntry.artifact.sha256,Codec.hash(try Data(contentsOf:first)))
        _=try await decode(repaired,frames:82)
        let key=try VisualClipCache.fingerprint(revision:r,index:0,database:repo.read(),modules:registry,encoding:encoding)
        let directory=first.deletingLastPathComponent(),whole=directory.appendingPathComponent(key+".mp4"),bytes=try Data(contentsOf:repaired)
        try bytes.write(to:whole,options:.atomic)
        let entry=VisualClipCache.Entry(key:key,bytes:bytes.count,sha256:Codec.hash(bytes),frames:82)
        try PropertyListEncoder().encode(entry).write(to:directory.appendingPathComponent(key+".plist"),options:.atomic)
        try Data("invalid obsolete interval".utf8).write(to:receipt,options:.atomic);module.reset()
        let progress=Progress(),(wholeHit,output)=try await compose(r,repo:repo,encoding:encoding,name:"model-whole-hit",progress:progress,modules:registry,invocation:scope)
        XCTAssertEqual(wholeHit,1);XCTAssertTrue(module.frames.isEmpty);XCTAssertEqual(progress.values,[0.75])
        XCTAssertEqual(try Data(contentsOf:whole),bytes);_=try await decode(output,frames:82)
    }

    func testCorruptMissingAndWrongRangeReceiptsCannotAuthorizeReuse()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let r=revision(workspace),encoding=try configuration(r)
        _=try await compose(r,repo:repo,encoding:encoding,name:"original")
        let(_,first,receipt)=try interval(r,range:0..<120,repo:repo,encoding:encoding)
        let(_,second,_)=try interval(r,range:120..<240,repo:repo,encoding:encoding)
        let secondBytes=try Data(contentsOf:second)
        let originalReceipt=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt))
        for damage in 0..<5 {
            if damage==0 {try Data("truncated".utf8).write(to:first,options:.atomic)}
            if damage==1 {try FileManager.default.removeItem(at:first)}
            if damage==2 {var bad=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt));bad.artifact.frames-=1;try PropertyListEncoder().encode(bad).write(to:receipt,options:.atomic)}
            if damage==3 {var bad=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt));bad.interval.lowerBound=1;try PropertyListEncoder().encode(bad).write(to:receipt,options:.atomic)}
            if damage==4 {try FileManager.default.removeItem(at:receipt)}
            let(hits,video)=try await compose(r,repo:repo,encoding:encoding,name:"repaired-"+String(damage))
            XCTAssertEqual(hits,0);XCTAssertEqual(try Data(contentsOf:second),secondBytes,"修复坏块不得重绘相邻完整区间")
            let repaired=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt))
            XCTAssertEqual(repaired.interval,originalReceipt.interval);XCTAssertEqual(repaired.artifact.frames,120)
            XCTAssertEqual(repaired.artifact.sha256,Codec.hash(try Data(contentsOf:first)))
            _=try await decode(video,frames:r.frames)
        }
    }

    func testLegacyCompleteSceneIsPreferredWithoutCreatingIntervals()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let r=revision(workspace),encoding=try configuration(r)
        let directory=root.appendingPathComponent("cache/visuals")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let key=try VisualClipCache.fingerprint(revision:r,index:0,database:repo.read(),modules:nil,encoding:encoding)
        let clip=directory.appendingPathComponent(key+".mp4")
        try await VisualClipCache.renderClip(revision:r,index:0,startFrame:0,repository:repo,database:repo.read(),output:clip,modules:nil,encoding:encoding,progress:{_ in})
        let bytes=try Data(contentsOf:clip)
        let entry=VisualClipCache.Entry(key:key,bytes:bytes.count,sha256:Codec.hash(bytes),frames:r.frames)
        try PropertyListEncoder().encode(entry).write(to:directory.appendingPathComponent(key+".plist"),options:.atomic)
        let progress=Progress(),(hits,output)=try await compose(r,repo:repo,encoding:encoding,name:"legacy-hit",progress:progress)
        XCTAssertEqual(hits,1);XCTAssertEqual(progress.values,[0.75])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).count,2)
        XCTAssertEqual(try Data(contentsOf:clip),bytes);_=try await decode(output,frames:r.frames)
    }

    private func sourceVideo(_ url:URL,encoding:VisualClipCache.EncodingConfiguration)async throws {
        let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:encoding.writerSettings)
        input.mediaTimeScale=encoding.mediaTimeScale;input.expectsMediaDataInRealTime=false
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:encoding.pixelBufferAttributes)
        writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
        for frame in 0..<128 {
            while !input.isReadyForMoreMediaData {guard writer.status != .failed else{throw VideoError.unavailable("测试源编码失败")};try await Task.sleep(nanoseconds:1_000_000)}
            var optional:CVPixelBuffer?
            let pool=try XCTUnwrap(adaptor.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil,pool,&optional),kCVReturnSuccess)
            let buffer=try XCTUnwrap(optional);CVPixelBufferLockBaseAddress(buffer,[])
            let context=try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:encoding.width,height:encoding.height,bitsPerComponent:8,
                bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue))
            let colors:[[CGFloat]]=[[0.9,0.15,0.15],[0.15,0.85,0.15],[0.15,0.2,0.9],[0.9,0.85,0.15]]
            let c=colors[frame<45 ? 0:frame<75 ? 1:frame<105 ? 2:3]
            context.setFillColor(CGColor(red:c[0],green:c[1],blue:c[2],alpha:1));context.fill(CGRect(x:0,y:0,width:encoding.width,height:encoding.height))
            CVPixelBufferUnlockBaseAddress(buffer,[])
            XCTAssertTrue(adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30)))
        }
        input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:128,timescale:30))
        await withCheckedContinuation{(continuation:CheckedContinuation<Void,Never>)in writer.finishWriting{continuation.resume()}}
        XCTAssertEqual(writer.status,.completed)
    }

    func testSourceOffsetSpeedCaptionsAndPauseKeepExactCadenceAcrossIntervalBoundaries()async throws {
        let(root,repo,workspace)=try repository();defer{try? FileManager.default.removeItem(at:root)}
        let encoding=try configuration(revision(workspace))
        let source=root.appendingPathComponent("source.mp4");try await sourceVideo(source,encoding:encoding)
        let bytes=try Data(contentsOf:source)
        let asset=Asset(workspaceID:workspace.id,name:"带绝对源帧的测试视频",hash:Codec.hash(bytes),ext:"mp4",bytes:bytes.count,mediaType:"video/mp4",durationFrames:128)
        let storedSource=repo.assetURL(asset)
        try FileManager.default.createDirectory(at:storedSource.deletingLastPathComponent(),withIntermediateDirectories:true)
        try bytes.write(to:storedSource);try repo.transaction{$0.assets=[asset]}
        let prelude=Scene(title:"另一个原镜头",body:"全局时间轴前移17帧。",durationFrames:17)
        var scene=Scene(kind:.video,title:"原源轴持续",body:"偏移17帧、半速和最后持画。",durationFrames:96)
        scene.assetID=asset.id;scene.sourceStartFrame=17;scene.speed=0.5;scene.pauseFrames=55
        scene.captions=[Caption(text:"边界前",startFrame:0,endFrame:60),Caption(text:"边界后仍连续",startFrame:60,endFrame:96)]
        let r=Revision(contentContext:ContentContext(workspaceID:workspace.id,name:"源轴比较"),aspect:.landscape,scenes:[prelude,scene])
        XCTAssertEqual(scene.timelineFrames,247);XCTAssertEqual(r.frames,264)
        let whole=root.appendingPathComponent("whole-reference.mp4")
        try await VisualClipCache.renderClip(revision:r,index:1,startFrame:17,repository:repo,database:repo.read(),output:whole,modules:nil,encoding:encoding,progress:{_ in})
        let(_,composed)=try await compose(r,repo:repo,encoding:encoding,name:"intervals")
        let reference=try await decode(whole,frames:247),segmented=try await decode(composed,frames:264)
        let selected=[0,55,56,115,116,119,120,121,175,176,191,192,239,240,246]
        for frame in selected {
            for (actual,expected) in zip(segmented[17+frame].points,reference[frame].points) {
                for (a,b) in zip(actual,expected) {XCTAssertLessThanOrEqual(abs(a-b),16,"同一原源帧的语义区域应一致；H.264区间GOP允许小压缩差异")}
            }
            // The center of the actual media viewport is one of the sampled
            // points. Distinct original source colors expose a source reset.
            let rgb=segmented[17+frame].points[4]
            if frame<56 {XCTAssertGreaterThan(rgb[0]-max(rgb[1],rgb[2]),60)}
            else if frame<116 {XCTAssertGreaterThan(rgb[1]-max(rgb[0],rgb[2]),60)}
            else if frame<176 {XCTAssertGreaterThan(rgb[2]-max(rgb[0],rgb[1]),60)}
            else {XCTAssertGreaterThan(min(rgb[0],rgb[1])-rgb[2],60)}
        }
        let(_,last,receipt)=try interval(r,index:1,range:240..<247,repo:repo,encoding:encoding)
        let tail=try PropertyListDecoder().decode(VisualClipCache.IntervalEntry.self,from:Data(contentsOf:receipt))
        XCTAssertEqual(tail.artifact.frames,7);_=try await decode(last,frames:7)
        // A valid checkpoint never authorizes changed source bytes.
        try Data("changed actual source".utf8).write(to:repo.assetURL(asset),options:.atomic)
        do {_=try await compose(r,repo:repo,encoding:encoding,name:"bad-source");XCTFail("源字节改变后不能复用任何区间")}
        catch let error as VideoError {XCTAssertEqual(error.code,"invalid_input")}
    }
}
