import XCTest
import CryptoKit
import CoreGraphics
import ImageIO
@testable import VideoMedia
import VideoCore

final class PluginProcessTests:XCTestCase {
    final class Scoped:ScopedSceneRenderModule,@unchecked Sendable {
        let manifest:PluginManifest;var draws=0;var closes=0;var failClose=false;var closeAction:(@Sendable ()throws->Void)?
        init(_ manifest:PluginManifest){self.manifest=manifest}
        func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext)throws{XCTFail("unscoped method must not execute")}
        func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext,resources:RenderResources,invocation:RenderInvocation)throws{try invocation.check();draws+=1}
        func close(invocationID:String)throws{closes+=1;try closeAction?();if failClose{throw VideoError.unavailable("fixture close failure")}}
    }
    func fixture()throws->(RenderModuleRegistry,Scoped,RenderInvocation){
        let key=Curve25519.Signing.PrivateKey(),manifest=PluginManifest(id:"video.game",version:"1.0.0",capabilities:["game.simulate"],implementationDigest:try BuiltinExecutableIdentity.current().digest,permissions:[])
        let module=Scoped(manifest),policy=CommercialPolicy(pluginID:manifest.id,version:1,access:"free")
        func signed<T:Encodable>(_ value:T)throws->SignedDocument{let data=try Codec.data(value);return SignedDocument(payload:data,signature:try key.signature(for:data))}
        let registry=RenderModuleRegistry();try registry.register(module,signedManifest:signed(manifest),signedPolicy:signed(policy),publicKey:key.publicKey.rawRepresentation)
        let scope=RenderInvocation(workspaceID:"w",projectID:"p",revisionID:"r",revisionDigest:String(repeating:"a",count:64),jobID:nil,budgetReference:"q",budgetLimit:Money(0),deadline:Date().addingTimeInterval(30),authorization:{})
        return(registry,module,scope)
    }
    func draw(_ registry:RenderModuleRegistry,_ scope:RenderInvocation?)throws{
        let context=CGContext(data:nil,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        try registry.draw(scene:Scene(kind:.simulation,title:"",body:"",narration:"",durationFrames:1),localFrame:0,fps:30,rect:CGRect(x:0,y:0,width:8,height:8),context:context,invocation:scope)
    }
    func test_scoped_module_never_uses_unscoped_draw()throws{
        let(registry,module,scope)=try fixture();XCTAssertThrowsError(try draw(registry,nil));XCTAssertEqual(module.draws,0)
        try draw(registry,scope);XCTAssertEqual(module.draws,1);try registry.close(invocationID:scope.id);XCTAssertEqual(module.closes,1)
        XCTAssertThrowsError(try draw(registry,scope));XCTAssertEqual(module.draws,1)
    }
    func test_unregister_keeps_scope_reference_for_physical_cleanup()throws{
        let(registry,module,scope)=try fixture();try draw(registry,scope);registry.unregister(module.manifest.id)
        try registry.close(invocationID:scope.id);try registry.close(invocationID:scope.id);XCTAssertEqual(module.closes,1)
    }
    func test_failed_close_is_preserved_and_never_retried()throws{
        let(registry,module,scope)=try fixture();try draw(registry,scope);module.failClose=true;registry.unregister(module.manifest.id)
        XCTAssertThrowsError(try registry.close(invocationID:scope.id));XCTAssertThrowsError(try registry.close(invocationID:scope.id));XCTAssertEqual(module.closes,1)
    }
    final class CloseResults:@unchecked Sendable {
        let lock=NSLock();private var values=[String?](repeating:nil,count:2)
        func set(_ index:Int,_ value:String){lock.lock();values[index]=value;lock.unlock()}
        func snapshot()->[String?]{lock.lock();defer{lock.unlock()};return values}
    }
    private func concurrentClose(fails:Bool)throws {
        let(registry,module,scope)=try fixture();try draw(registry,scope)
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),secondStarted=DispatchSemaphore(value:0),firstFinished=DispatchSemaphore(value:0),secondFinished=DispatchSemaphore(value:0),results=CloseResults()
        module.failClose=fails
        module.closeAction={entered.signal();guard release.wait(timeout:.now()+2) == .success else{throw VideoError.unavailable("fixture release deadline")}}
        let close:@Sendable(Int)->Void={index in
            do{try registry.close(invocationID:scope.id);results.set(index,"success")}
            catch{results.set(index,error as? VideoError == .unavailable("fixture close failure") ? "fixture close failure":"unexpected error")}
        }
        DispatchQueue.global().async{close(0);firstFinished.signal()}
        guard entered.wait(timeout:.now()+1) == .success else{release.signal();XCTFail("first physical cleanup did not enter");return}
        DispatchQueue.global().async{secondStarted.signal();close(1);secondFinished.signal()}
        guard secondStarted.wait(timeout:.now()+1) == .success else{release.signal();XCTFail("second close did not start");return}
        XCTAssertEqual(secondFinished.wait(timeout:.now()+0.05),.timedOut,"a concurrent close must wait for the physical cleanup receipt")
        release.signal()
        XCTAssertEqual(firstFinished.wait(timeout:.now()+2),.success);XCTAssertEqual(secondFinished.wait(timeout:.now()+2),.success)
        let expected=fails ? "fixture close failure":"success"
        XCTAssertEqual(results.snapshot(),[expected,expected]);XCTAssertEqual(module.closes,1)
        if fails{XCTAssertThrowsError(try registry.close(invocationID:scope.id))}else{try registry.close(invocationID:scope.id)}
        XCTAssertEqual(module.closes,1,"same invocation must never trigger a second physical termination")
    }
    func test_concurrent_close_waits_for_shared_success_and_only_terminates_once()throws{try concurrentClose(fails:false)}
    func test_concurrent_close_preserves_first_failure_and_only_terminates_once()throws{try concurrentClose(fails:true)}
    func test_bridge_metadata_rejects_missing_wrong_and_nonphysical_exit()throws{
        let response=try Codec.data(PluginRPCResponse(requestID:"r",ok:true,state:"ready"))
        XCTAssertThrowsError(try PluginBridgeWire.parse(response))
        let framed=try PluginBridgeWire.response(response,pid:123);let(event,pid)=try PluginBridgeWire.parse(framed);XCTAssertEqual(event,"response");XCTAssertEqual(pid,123)
        for raw in ["{\"__video_transport\":{\"event\":\"interrupted\",\"peer_pid\":123}}","{\"__video_transport\":{\"event\":\"peer_exited\",\"peer_pid\":0}}","{\"__video_transport\":{\"event\":\"peer_exited\",\"peer_pid\":123},\"ok\":true}"]{XCTAssertThrowsError(try PluginBridgeWire.parse(Data(raw.utf8)))}
    }
    private func probeDirectory()throws->URL {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-readonly-rule-"+Codec.id())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)}
        return root
    }
    func test_native_probe_delivers_finite_stdin_eof_and_removes_capture()throws {
        let root=try probeDirectory(),requests=try PluginPackageProbeRules.requests(),input=try PluginPackageProbeRules.input(requests)
        XCTAssertLessThanOrEqual(input.count,4096)
        let result=try NativeProcessProbe.run(URL(fileURLWithPath:"/bin/cat"),[],root:root,inputData:input)
        XCTAssertEqual(result,input)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),[])
    }
    func test_native_probe_does_not_inherit_the_parent_environment()throws {
        let root=try probeDirectory(),result=try NativeProcessProbe.run(URL(fileURLWithPath:"/usr/bin/env"),[],root:root)
        let lines=String(decoding:result,as:UTF8.self).split(separator:"\n")
        XCTAssertEqual(Set(lines.compactMap{$0.split(separator:"=",maxSplits:1).first.map(String.init)}),["PATH","LANG","LC_ALL","TMPDIR"])
        XCTAssertTrue(lines.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"));XCTAssertTrue(lines.contains("LANG=en_US.UTF-8"));XCTAssertTrue(lines.contains("LC_ALL=en_US.UTF-8"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),[])
    }
    func test_native_probe_rejects_unsuccessful_exit_and_bounded_timeout()throws {
        let root=try probeDirectory()
        XCTAssertThrowsError(try NativeProcessProbe.run(URL(fileURLWithPath:"/usr/bin/false"),[],root:root))
        let started=Date()
        XCTAssertThrowsError(try NativeProcessProbe.run(URL(fileURLWithPath:"/bin/sleep"),["2"],root:root,timeout:0.05))
        XCTAssertLessThan(Date().timeIntervalSince(started),3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),[])
    }
    func test_native_probe_rejects_nonfinite_limits_and_oversize_input_before_start()throws {
        let root=try probeDirectory(),program=URL(fileURLWithPath:"/usr/bin/true")
        for timeout in [TimeInterval.nan,.infinity,0,-1,31] {
            XCTAssertThrowsError(try NativeProcessProbe.run(program,[],root:root,timeout:timeout))
        }
        XCTAssertThrowsError(try NativeProcessProbe.run(program,[],root:root,inputData:Data(repeating:0,count:4097)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),[])
    }
    final class ChunkResult:@unchecked Sendable {
        private let lock=NSLock();private var stored:Data?
        func set(_ data:Data?){lock.lock();stored=data;lock.unlock()}
        func get()->Data?{lock.lock();defer{lock.unlock()};return stored}
    }
    func test_live_bridge_input_returns_a_short_request_before_stdin_eof()throws {
        let pipe=Pipe(),done=DispatchSemaphore(value:0),result=ChunkResult()
        defer{try? pipe.fileHandleForWriting.close();try? pipe.fileHandleForReading.close()}
        DispatchQueue.global().async {
            result.set(try? PluginStdioInput.readChunk(pipe.fileHandleForReading.fileDescriptor))
            done.signal()
        }
        try pipe.fileHandleForWriting.write(contentsOf:Data("one\n".utf8))
        guard done.wait(timeout:.now()+2) == .success else {
            // Release a broken fill-until-EOF reader before failing the assertion.
            try? pipe.fileHandleForWriting.close()
            XCTAssertEqual(done.wait(timeout:.now()+2),.success)
            XCTFail("the live bridge must read a complete short request while stdin stays open")
            return
        }
        XCTAssertEqual(result.get(),Data("one\n".utf8))
        try pipe.fileHandleForWriting.write(contentsOf:Data("two\nthree\n".utf8))
        XCTAssertEqual(try PluginStdioInput.readChunk(pipe.fileHandleForReading.fileDescriptor),Data("two\nthree\n".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertNil(try PluginStdioInput.readChunk(pipe.fileHandleForReading.fileDescriptor))
    }
    func test_jsonl_buffer_preserves_fragmented_multiline_and_nonzero_indices()throws {
        let lines=[Data("one".utf8),Data(),Data("{\"value\":\"雪\\n\"}".utf8)]
        let tail=Data("unfinished".utf8)
        var wire=Data();for line in lines{wire.append(line);wire.append(10)};wire.append(tail)
        for width in 1...wire.count {
            var buffer=PluginJSONLBuffer(),actual=[Data](),offset=0
            while offset<wire.count {
                let end=min(wire.count,offset+width)
                buffer.append(Data(wire[offset..<end]));offset=end
                while let line=buffer.popLine(){actual.append(line)}
            }
            XCTAssertEqual(actual,lines,"chunk width \(width)")
            XCTAssertEqual(buffer.searchedBytes,wire.count)
            XCTAssertEqual(buffer.takeRemainder(),tail);XCTAssertTrue(buffer.isEmpty)
            XCTAssertNil(buffer.takeRemainder())
        }
        let original=Data("prefix:first\npar".utf8),slice=original.dropFirst(7)
        XCTAssertNotEqual(slice.startIndex,0,"fixture must retain nonzero Data indices")
        var buffer=PluginJSONLBuffer(slice)
        XCTAssertEqual(buffer.popLine(),Data("first".utf8));XCTAssertNil(buffer.popLine())
        buffer.append(Data("tial\nlast\n".utf8))
        XCTAssertEqual(buffer.popLine(),Data("partial".utf8));XCTAssertEqual(buffer.popLine(),Data("last".utf8))
        XCTAssertNil(buffer.popLine());XCTAssertTrue(buffer.isEmpty);XCTAssertNil(buffer.takeRemainder())
        XCTAssertEqual(buffer.searchedBytes,slice.count+Data("tial\nlast\n".utf8).count)
    }
    func test_jsonl_buffer_preserves_eof_tails_and_existing_transport_limits()throws {
        var buffer=PluginJSONLBuffer();buffer.append(Data("complete\ntrailing".utf8))
        XCTAssertEqual(buffer.popLine(),Data("complete".utf8));XCTAssertNil(buffer.popLine())
        // A response reader cannot take a partial line; only bridge-input EOF takes this tail.
        XCTAssertEqual(buffer.takeRemainder(),Data("trailing".utf8));XCTAssertNil(buffer.takeRemainder())
        XCTAssertNil(buffer.popLine());XCTAssertEqual(buffer.count,0)
        func json(_ count:Int,transport:Bool)->Data {
            let prefix=Data((transport ? "{\"__video_transport\":{\"event\":\"response\",\"peer_pid\":123},\"padding\":\"":"{\"padding\":\"").utf8),suffix=Data("\"}".utf8)
            return prefix+Data(repeating:120,count:count-prefix.count-suffix.count)+suffix
        }
        let limit=PluginProtocolRules.maximumResponseBytes,exact=json(limit,transport:false)
        buffer.append(exact);XCTAssertNil(buffer.popLine());XCTAssertEqual(buffer.count,limit)
        let atEOF=try XCTUnwrap(buffer.takeRemainder())
        XCTAssertEqual(atEOF,exact);XCTAssertNoThrow(try PluginBridgeWire.response(atEOF,pid:123))
        buffer.append(json(limit+1,transport:false));buffer.append(Data([10]))
        let oversized=try XCTUnwrap(buffer.popLine())
        XCTAssertEqual(oversized.count,limit+1)
        XCTAssertThrowsError(try PluginBridgeWire.response(oversized,pid:123))
        XCTAssertNoThrow(try PluginBridgeWire.parse(json(limit+1024,transport:true)))
        XCTAssertThrowsError(try PluginBridgeWire.parse(json(limit+1025,transport:true)))
        // Framing must not truncate a pending oversize tail and hide it from the caller's buffer guard.
        buffer.append(Data(repeating:120,count:limit+2049));XCTAssertNil(buffer.popLine())
        XCTAssertEqual(buffer.count,limit+2049)
    }
    func test_jsonl_buffer_searches_a_large_fragmented_line_only_once()throws {
        let prefix=Data("{\"padding\":\"".utf8),suffix=Data("\"}".utf8),size=12*1024*1024+512*1024
        let line=prefix+Data(repeating:120,count:size-prefix.count-suffix.count)+suffix
        var buffer=PluginJSONLBuffer(),offset=0
        while offset<line.count {
            let end=min(line.count,offset+65536)
            buffer.append(Data(line[offset..<end]));offset=end
            XCTAssertNil(buffer.popLine());XCTAssertEqual(buffer.searchedBytes,offset)
            XCTAssertNil(buffer.popLine());XCTAssertEqual(buffer.searchedBytes,offset,"no new bytes must mean no repeated search")
        }
        buffer.append(Data([10]));XCTAssertEqual(buffer.popLine(),line)
        XCTAssertEqual(buffer.searchedBytes,line.count+1);XCTAssertTrue(buffer.isEmpty)
        buffer.append(Data("next\n".utf8));XCTAssertEqual(buffer.popLine(),Data("next".utf8))
        XCTAssertEqual(buffer.searchedBytes,line.count+1+5);XCTAssertNil(buffer.popLine())
    }
    func test_plugin_atlas_keeps_the_hash_validated_original_png_bytes()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("original-png-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root),workspace=Workspace(name:"source PNG fixture",owner:"tester")
        let context=try XCTUnwrap(CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.2,green:0.5,blue:0.8,alpha:1));context.fill(CGRect(x:0,y:0,width:4,height:4))
        let image=try XCTUnwrap(context.makeImage()),bytes=NSMutableData()
        let target=try XCTUnwrap(CGImageDestinationCreateWithData(bytes,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(target,image,[kCGImagePropertyPNGDictionary:[kCGImagePropertyPNGDescription:"retained original source description"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(target));let original=bytes as Data
        var asset=try repository.ingest(original,name:"source.png",workspaceID:workspace.id,mediaType:"image")
        let proof=Evidence(workspaceID:workspace.id,title:"isolated source fixture",source:"local-test",claim:"test fixture",owner:"test",commercialAllowed:true,verified:true)
        asset.evidenceID=proof.id
        try repository.transaction{$0.workspaces.append(workspace);$0.assets.append(asset);$0.evidence.append(proof)}
        let source=ClassicSource(assetID:asset.id,hash:asset.hash,source:proof.source,owner:proof.owner,license:"test-only",evidenceID:proof.id)
        var scene=VideoCore.Scene(kind:.simulation,title:"",body:"")
        scene.classicArtwork=ClassicArtwork.quadrants(assetID:asset.id,gameplay:.sokoban,sources:[source])
        let resources=try ClassicArtworkMedia.load(scene:scene,workspaceID:workspace.id,repository:repository,database:repository.read(),commercial:true)
        let sent=try resources.pluginRasterAssets(props:PluginVisualProps(scene:scene))
        XCTAssertEqual(sent.count,1);XCTAssertEqual(sent[0].data,original);XCTAssertEqual(sent[0].sha256,asset.hash)
        XCTAssertEqual(sent[0].width,4);XCTAssertEqual(sent[0].height,4)
        let decoded=try XCTUnwrap(CGImageSourceCreateWithData(original as CFData,nil))
        XCTAssertNotEqual(try ScenePainter.png(XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded,0,nil))),original,"fixture must distinguish original metadata from re-encoded pixels")
        XCTAssertEqual(try resources.pluginRasterAssets(props:PluginVisualProps(scene:scene)),sent)
    }
}
