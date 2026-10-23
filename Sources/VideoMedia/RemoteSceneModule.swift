import Foundation
import CoreGraphics
import ImageIO
import VideoCore

public protocol ScopedSceneRenderModule:SceneRenderModule {
    func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext,resources:RenderResources,invocation:RenderInvocation)throws
    func close(invocationID:String)throws
}

/// No closed implementation is linked here. Each scope talks to its verified package's service.
public final class RemoteSceneModule:ScopedSceneRenderModule,@unchecked Sendable {
    public let package:VerifiedPluginPackage
    public var manifest:PluginManifest{package.module}
    private final class Session {
        let client:PluginProcessClient;let mutex=NSLock();let cancellation:RenderCancellation
        init(_ client:PluginProcessClient,cancellation:RenderCancellation){self.client=client;self.cancellation=cancellation}
    }
    private let mutex=NSLock()
    private var sessions:[String:Session]=[:]
    private var closed:[String:(token:PluginWeakCancellation,result:Result<Void,VideoError>)]=[:]
    private var closing:[String:PluginCloseReceipt]=[:]
    public init(package:VerifiedPluginPackage)throws {
        try PluginPackageRules.verifyFiles(package.manifest,root:package.rootURL)
        try PluginNativeCode.verify(root:package.rootURL,execution:package.execution)
        self.package=package
    }
    public static func load(root:URL,publicKey:Data,architecture:String,minimumPolicyVersion:Int=1,declarationsRoot:URL?=nil,now:Date=Date())throws->RemoteSceneModule {
        let package=try PluginPackageRules.verify(root:root,declarationsRoot:declarationsRoot,publicKey:publicKey,architecture:architecture,osMajor:ProcessInfo.processInfo.operatingSystemVersion.majorVersion,minimumPolicyVersion:minimumPolicyVersion,now:now,implementationDigest:{try MachOCodeIdentity.digest(PluginPackageRules.read($0,limit:512*1024*1024))},validateCode:PluginNativeCode.verify)
        return try RemoteSceneModule(package:package)
    }
    private func session(_ scope:RenderInvocation)throws->Session {
        mutex.lock();defer{mutex.unlock()}
        closed=closed.filter{$0.value.token.value != nil}
        guard closed[scope.id]==nil,closing[scope.id]==nil else{throw VideoError.conflict("此插件调用已经关闭，禁止重新启动同一调用")}
        if let existing=sessions[scope.id] {
            let value=existing.client.invocation
            guard value.workspaceID==scope.workspaceID,value.projectID==scope.projectID,value.revisionID==scope.revisionID,value.revisionDigest==scope.revisionDigest,value.jobID==scope.jobID,value.budgetReference==scope.budgetReference,value.currency==scope.currency,value.budgetLimit==scope.budgetLimit.amount,value.deadlineUnixTime==scope.deadline.timeIntervalSince1970 else{throw VideoError.permission("同插件调用ID对应不同身份、版本或预算")}
            return existing
        }
        guard sessions.count<8 else{throw VideoError.unavailable("高级插件同时活跃调用超过有限上限")}
        let client=try PluginProcessClient(package:package,scope:scope),result=Session(client,cancellation:scope.cancellation)
        sessions[scope.id]=result
        for method in [PluginMethod.handshake,.describe,.health] {
            let response=try client.exchange(PluginRPCRequest(requestID:Codec.id(),method:method,invocation:client.invocation),scope:scope)
            try validate(response.descriptor)
        }
        return result
    }
    private func validate(_ description:PluginDescription?)throws {
        guard let value=description,value.pluginID==manifest.id,value.version==manifest.version,value.capabilityID==manifest.capabilities.first,Set(value.methods)==Set(PluginMethod.allCases),value.methods.count==8,value.inputSchemaVersion==manifest.inputSchema,value.outputSchemaVersion==manifest.outputSchema,!value.filesystemAccess,!value.networkAccess else{throw VideoError.permission("独立插件实际握手/能力/权限与受信包不符")}
    }
    public func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext)throws {throw VideoError.permission("独立高级绘制必须携带Host实时核验的完整调用范围")}
    public func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext,resources:RenderResources)throws {throw VideoError.permission("独立高级绘制缺少调用范围")}
    public func draw(scene:VideoCore.Scene,localFrame:Int,fps:Int,rect:CGRect,context:CGContext,resources:RenderResources,invocation:RenderInvocation)throws {
        try invocation.check();try PluginInputCompatibility.requireKnowledgeSupport(scene.simulation,pluginID:manifest.id,inputSchema:manifest.inputSchema);try PluginInputCompatibility.requireCartoonSupport(scene.cartoonPerformance,pluginID:manifest.id,inputSchema:manifest.inputSchema);let session=try session(invocation)
        session.mutex.lock();defer{session.mutex.unlock()}
        let props=PluginVisualProps(scene:scene),client=session.client
        let input=PluginFrameInput(invocation:client.invocation,props:props,sourceFrame:localFrame,fps:fps,canvasWidth:context.width,canvasHeight:context.height,rect:PluginRect(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height),assets:try resources.pluginRasterAssets(props:props))
        try PluginProtocolRules.validate(input,capabilityID:manifest.capabilities[0]);let digest=try input.contentDigest()
        for method in [PluginMethod.validate,.estimate] {
            let answer=try client.exchange(PluginRPCRequest(requestID:Codec.id(),method:method,input:input,invocation:client.invocation),scope:invocation)
            guard answer.inputDigest==digest,answer.cost?.budgetReference==client.invocation.budgetReference,answer.cost?.actual==Money(0,client.invocation.currency),answer.task==nil else{throw VideoError.permission("插件预检/费用不属于原冻结输入或预算")}
        }
        var answer=try client.exchange(PluginRPCRequest(requestID:digest+"-execute",method:.execute,input:input,invocation:client.invocation),scope:invocation)
        guard let initial=answer.task else{throw VideoError.unavailable("插件没有返回原帧的异步任务")}
        while true {
            try invocation.check()
            guard let task=answer.task,task.taskID==initial.taskID,task.invocation==client.invocation,task.inputDigest==digest,task.progress.isFinite,(0...1).contains(task.progress),answer.cost?.budgetReference==client.invocation.budgetReference,answer.cost?.actual==Money(0,client.invocation.currency) else{throw VideoError.permission("插件任务身份、版本、进度或费用不符")}
            switch task.state {
            case .running:
                Thread.sleep(forTimeInterval:0.005)
                answer=try client.exchange(PluginRPCRequest(requestID:Codec.id(),method:.progress,invocation:client.invocation,taskID:task.taskID),scope:invocation)
            case .succeeded:
                guard let frame=task.frame else{throw VideoError.unavailable("插件完成任务没有实际图层")}
                try PluginProtocolRules.validate(frame,input:input)
                guard let source=CGImageSourceCreateWithData(frame.data as CFData,nil),CGImageSourceGetCount(source)==1,CGImageSourceGetType(source) as String?=="public.png",let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],properties[kCGImagePropertyPixelWidth] as? Int==frame.width,properties[kCGImagePropertyPixelHeight] as? Int==frame.height,let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width==frame.width,image.height==frame.height else{throw VideoError.permission("插件PNG实际码流尺寸与冻结画布不同")}
                try invocation.check();context.saveGState();defer{context.restoreGState()};context.clip(to:rect)
                context.draw(image,in:CGRect(x:0,y:0,width:frame.width,height:frame.height));return
            case .cancelled:throw CancellationError()
            case .failed,.timedOut:throw VideoError.unavailable("实际高级子进程绘制失败或超时，没有采用部分/晚到图层")
            }
        }
    }
    public func close(invocationID:String)throws {
        mutex.lock()
        closed=closed.filter{$0.value.token.value != nil}
        if let result=closed[invocationID]{mutex.unlock();return try result.result.get()}
        if let receipt=closing[invocationID]{mutex.unlock();return try receipt.wait()}
        guard let session=sessions.removeValue(forKey:invocationID) else{mutex.unlock();return}
        let receipt=PluginCloseReceipt();closing[invocationID]=receipt
        mutex.unlock();session.client.requestClose();session.mutex.lock()
        let result:Result<Void,VideoError>
        do{try session.client.close();result = .success(())}catch{result = .failure(error as? VideoError ?? .unavailable("高级子进程终止未确认"))}
        session.mutex.unlock();mutex.lock();closed[invocationID]=(PluginWeakCancellation(session.cancellation),result)
        receipt.finish(result);closing.removeValue(forKey:invocationID);mutex.unlock()
        return try result.get()
    }
}
