import XCTest
import CryptoKit
import CoreGraphics
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
}
