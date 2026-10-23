import Foundation
import CoreGraphics
import ImageIO
import Darwin
import VideoCore

/// Transport-independent, byte-only capability service. The runner owns XPC peer authentication.
/// Drawing is serialized separately from RPC, so cancel/progress/health remain responsive.
public final class PluginRPCServer:@unchecked Sendable {
    private let descriptor:PluginDescription
    private let module:any SceneRenderModule
    private let lock=NSLock()
    private let drawing=DispatchQueue(label:"video.plugin.actual-drawing",qos:.userInitiated)
    private let terminate:@Sendable ()->Void
    private let taskTimeout:Double
    private var invocation:PluginInvocation?
    private var watchdog:DispatchSourceTimer?
    private var taskWatchdog:DispatchSourceTimer?
    private var terminationRequested=false
    private var closing=false
    private var activeTask:String?
    private var tasks:[String:PluginTaskSnapshot]=[:]
    private var order:[String]=[]
    private var executeReceipts:[String:(digest:String,taskID:String)]=[:]
    public init(pluginID:String,capabilityID:String,version:String,inputSchemaVersion:Int=1,moduleFactory:(PluginManifest)throws->any SceneRenderModule,terminate:@escaping @Sendable ()->Void={_exit(124)},taskTimeout:Double=PluginProtocolRules.maximumTaskSeconds)throws {
        guard PluginProtocolRules.text(pluginID),PluginProtocolRules.text(version),["game.simulate","cartoon.animate"].contains(capabilityID),taskTimeout.isFinite,taskTimeout>0,taskTimeout<=PluginProtocolRules.maximumTaskSeconds,PluginInputCompatibility.supports(pluginID:pluginID,version:inputSchemaVersion) else{throw VideoError.invalid("能力服务标识或单帧截止不合法")}
        descriptor=PluginDescription(pluginID:pluginID,capabilityID:capabilityID,version:version,inputSchemaVersion:inputSchemaVersion);self.terminate=terminate;self.taskTimeout=taskTimeout
        // This describes the actual linked implementation only, never grants paid access.
        module=try moduleFactory(PluginManifest(id:pluginID,version:version,capabilities:[capabilityID],inputSchema:inputSchemaVersion,implementationDigest:BuiltinExecutableIdentity.current().digest,permissions:[]))
    }
    deinit{watchdog?.cancel();taskWatchdog?.cancel()}
    public func exchange(_ data:Data,reply:@escaping @Sendable (Data)->Void) {
        var requestID="unparsed"
        do {
            guard !data.isEmpty,data.count<=PluginProtocolRules.maximumRequestBytes else{throw VideoError.invalid("插件RPC消息为空或超出有界长度")}
            let request=try Codec.decoder().decode(PluginRPCRequest.self,from:data);requestID=request.requestID
            guard request.protocolMajor==1,PluginProtocolRules.text(requestID) else{throw VideoError.unavailable("插件协议主版本或请求标识不受支持")}
            let response=try handle(request)
            send(response,reply:reply)
            if request.method == .cancel,request.taskID == nil,response.ok {
                // Reply first; actual process exit is separate evidence from XPC invalidation.
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+0.05){[weak self] in self?.requestTermination()}
            }
        }catch{
            let error=error as? VideoError ?? .invalid("插件RPC不能解析或执行；未返回输入或诊断原文")
            send(PluginRPCResponse(requestID:requestID,ok:false,state:"failed",error:PluginRPCError(code:error.code,message:error.localizedDescription,retryable:error.exitCode==8)),reply:reply)
        }
    }
    private func send(_ response:PluginRPCResponse,reply:@escaping @Sendable (Data)->Void) {
        do {
            let data=try Codec.data(response)
            guard data.count<=PluginProtocolRules.maximumResponseBytes else{throw VideoError.unavailable("插件响应超过有界长度")}
            reply(data)
        }catch{
            let fallback=PluginRPCResponse(requestID:response.requestID,ok:false,state:"failed",error:PluginRPCError(code:"unavailable",message:"插件响应未通过编码/字节上限，未发表帧"))
            if let data=try? Codec.data(fallback){reply(data)}
        }
    }
    private func bind(_ value:PluginInvocation,allowExpiredCancellation:Bool=false)throws {
        if allowExpiredCancellation {
            lock.lock();let bound=invocation;lock.unlock()
            if let bound {guard bound==value else{throw VideoError.permission("关闭操作不属于原完整调用")};return}
        }
        try PluginProtocolRules.validate(value)
        lock.lock();defer{lock.unlock()}
        if let invocation {guard invocation==value else{throw VideoError.permission("能力进程已绑定其他完整调用，不可复用跨工作区/版本/预算")};return}
        guard !closing else{throw VideoError.unavailable("能力服务正在退出，不接受新调用")}
        invocation=value
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
        timer.schedule(deadline:.now()+max(0,value.deadlineUnixTime-Date().timeIntervalSince1970))
        timer.setEventHandler{[weak self] in self?.expire()};watchdog=timer;timer.resume()
    }
    private func requestTermination(){lock.lock();guard !terminationRequested else{lock.unlock();return};terminationRequested=true;lock.unlock();terminate()}
    private func expire(taskID:String?=nil){
        lock.lock()
        if let taskID,activeTask != taskID{lock.unlock();return}
        closing=true
        if let id=activeTask,var task=tasks[id] {if task.state == .running{task.state = .timedOut};task.frame=nil;task.error=PluginRPCError(code:"unavailable",message:"实际绘制超过调用或单帧截止，服务退出；不发表晚到帧");tasks[id]=task}
        activeTask=nil;lock.unlock()
        requestTermination()
    }
    private func scope(_ request:PluginRPCRequest)throws->PluginInvocation {
        guard let value=request.invocation ?? request.input?.invocation else{throw VideoError.permission("插件操作缺少完整冻结调用")}
        if let input=request.input,let explicit=request.invocation {guard input.invocation==explicit else{throw VideoError.permission("插件输入和操作调用范围不符")}}
        try bind(value,allowExpiredCancellation:request.method == .cancel);return value
    }
    private func input(_ request:PluginRPCRequest)throws->PluginFrameInput {
        guard let value=request.input else{throw VideoError.invalid("插件操作缺少实际帧输入")}
        _=try scope(request);try PluginInputCompatibility.requireKnowledgeSupport(value.props.simulation,pluginID:descriptor.pluginID,inputSchema:descriptor.inputSchemaVersion);try PluginProtocolRules.validate(value,capabilityID:descriptor.capabilityID)
        return value
    }
    private func handle(_ request:PluginRPCRequest)throws->PluginRPCResponse {
        switch request.method {
        case .handshake,.describe:
            if request.input != nil || request.invocation != nil {_=try scope(request)}
            return PluginRPCResponse(requestID:request.requestID,ok:true,state:"ready",descriptor:descriptor)
        case .health:
            if request.input != nil || request.invocation != nil {_=try scope(request)}
            lock.lock();let state=closing ? "closing":(activeTask==nil ? "idle":"running");lock.unlock()
            return PluginRPCResponse(requestID:request.requestID,ok:true,state:state,descriptor:descriptor)
        case .validate,.estimate:
            let value=try input(request)
            _=try RenderResources.pluginResources(assets:value.assets)
            return PluginRPCResponse(requestID:request.requestID,ok:true,state:"validated",inputDigest:try value.contentDigest(),cost:PluginCost(currency:value.invocation.currency,budgetReference:value.invocation.budgetReference))
        case .execute:
            let value=try input(request),digest=try value.contentDigest()
            lock.lock()
            if let previous=executeReceipts[request.requestID] {
                guard previous.digest==digest else{lock.unlock();throw VideoError.conflict("同执行请求标识对应不同冻结输入")}
                guard let existing=tasks[previous.taskID] else{lock.unlock();throw VideoError.conflict("原执行回执已退出有界窗口；不重新执行相同请求")}
                lock.unlock();return PluginRPCResponse(requestID:request.requestID,ok:true,state:existing.state.rawValue,inputDigest:digest,task:existing,cost:PluginCost(currency:value.invocation.currency,budgetReference:value.invocation.budgetReference))
            }
            guard !closing,activeTask==nil,executeReceipts.count<65536 else{lock.unlock();throw VideoError.unavailable("能力进程忙碌、正在退出或幂等记录已达上限")}
            let task=PluginTaskSnapshot(taskID:Codec.id(),inputDigest:digest,invocation:value.invocation,state:.running)
            // Keep one completed raster, at most 32 lightweight snapshots, and bounded receipts.
            for id in order {tasks[id]?.frame=nil}
            while order.count>=32 {let old=order.removeFirst();tasks.removeValue(forKey:old)}
            tasks[task.taskID]=task;order.append(task.taskID);activeTask=task.taskID;executeReceipts[request.requestID]=(digest,task.taskID)
            let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
            timer.schedule(deadline:.now()+min(taskTimeout,value.invocation.deadlineUnixTime-Date().timeIntervalSince1970));timer.setEventHandler{[weak self] in self?.expire(taskID:task.taskID)}
            taskWatchdog=timer;timer.resume()
            lock.unlock()
            drawing.async{[weak self] in self?.draw(value,taskID:task.taskID,digest:digest)}
            return PluginRPCResponse(requestID:request.requestID,ok:true,state:"running",inputDigest:digest,task:task,cost:PluginCost(currency:value.invocation.currency,budgetReference:value.invocation.budgetReference))
        case .progress,.cancel:
            let expected=try scope(request)
            lock.lock();defer{lock.unlock()}
            if request.method == .cancel,request.taskID==nil {
                closing=true
                for id in order {if var task=tasks[id] {task.frame=nil;if task.state == .running{task.state = .cancelled};tasks[id]=task}}
                activeTask=nil
                taskWatchdog?.cancel();taskWatchdog=nil
                return PluginRPCResponse(requestID:request.requestID,ok:true,state:"closing",cost:PluginCost(currency:expected.currency,budgetReference:expected.budgetReference))
            }
            guard let id=request.taskID,var task=tasks[id],task.invocation==expected else{throw VideoError.permission("原任务不存在或不属于完整调用")}
            if request.method == .cancel {
                // A completed frame is withdrawn too; cancel is idempotent and never resurrects it.
                task.state = .cancelled;task.frame=nil;tasks[id]=task
                // An executing CGContext cannot be interrupted safely. Retain the active slot
                // until its draw returns; a subsequent execute may not queue behind a stuck draw.
            }
            return PluginRPCResponse(requestID:request.requestID,ok:true,state:task.state.rawValue,inputDigest:task.inputDigest,task:task,cost:PluginCost(currency:expected.currency,budgetReference:expected.budgetReference))
        }
    }
    private func draw(_ input:PluginFrameInput,taskID:String,digest:String) {
        do {
            lock.lock();let canDraw = !closing && tasks[taskID]?.state == .running;lock.unlock()
            guard canDraw else{return finishCancelled(taskID)}
            try PluginProtocolRules.validate(input,capabilityID:descriptor.capabilityID)
            let resources=try RenderResources.pluginResources(assets:input.assets)
            let w=input.canvasWidth,h=input.canvasHeight,r=input.rect
            guard let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw VideoError.unavailable("插件无法分配有界透明画布")}
            let rect=CGRect(x:r.x,y:r.y,width:r.width,height:r.height);context.clip(to:rect)
            try module.draw(scene:input.props.drawingScene(),localFrame:input.sourceFrame,fps:input.fps,rect:rect,context:context,resources:resources)
            guard let image=context.makeImage() else{throw VideoError.unavailable("实际高级绘制没有图层")}
            let png=try ScenePainter.png(image)
            let frame=PluginPNGFrame(data:png,width:w,height:h,sourceFrame:input.sourceFrame,inputDigest:digest,dependencyFingerprints:Dictionary(uniqueKeysWithValues:input.assets.map{($0.assetID,$0.sha256)}))
            try PluginProtocolRules.validate(frame,input:input)
            lock.lock();defer{lock.unlock()}
            guard !closing,Date().timeIntervalSince1970<input.invocation.deadlineUnixTime,var task=tasks[taskID],task.state == .running else{if activeTask==taskID{activeTask=nil;taskWatchdog?.cancel();taskWatchdog=nil};return}
            task.frame=frame;task.progress=1;task.state = .succeeded;tasks[taskID]=task;if activeTask==taskID{activeTask=nil}
            taskWatchdog?.cancel();taskWatchdog=nil
        }catch{
            let failure=error as? VideoError ?? .unavailable("实际高级绘制失败，未返回诊断原文或部分产物")
            lock.lock();defer{lock.unlock()}
            if var task=tasks[taskID],task.state == .running {task.state = .failed;task.frame=nil;task.error=PluginRPCError(code:failure.code,message:failure.localizedDescription);tasks[taskID]=task}
            if activeTask==taskID{activeTask=nil;taskWatchdog?.cancel();taskWatchdog=nil}
        }
    }
    private func finishCancelled(_ id:String){lock.lock();if activeTask==id{activeTask=nil;taskWatchdog?.cancel();taskWatchdog=nil};lock.unlock()}
}
