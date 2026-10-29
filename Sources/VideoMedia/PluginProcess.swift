import Foundation
import Darwin
import Security
import VideoCore

public enum PluginNativeCode {
    public static let teamID="VTU3X26EU8"
    public static func validService(_ value:String)->Bool {value.range(of:"^[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)+$",options:.regularExpression) != nil && value.utf8.count<=200}
    public static func requirement(identifier:String)->String {"anchor apple generic and certificate leaf[subject.OU] = \""+teamID+"\" and identifier \""+identifier+"\""}
    public static func verify(root:URL,execution:PluginExecutionDescriptor)throws {
        guard validService(execution.serviceName) else{throw VideoError.permission("独立插件服务标识不合法")}
        let host=root.appendingPathComponent("PluginHost.app"),service=host.appendingPathComponent("Contents/XPCServices/"+execution.serviceName+".xpc")
        for (url,identifier,isService) in [(host,execution.serviceName+".host",false),(service,execution.serviceName,true)] {
            var code:SecStaticCode?,requirement:SecRequirement?
            guard SecStaticCodeCreateWithPath(url as CFURL,[],&code)==errSecSuccess,let code,
                  SecRequirementCreateWithString(self.requirement(identifier:identifier) as CFString,[],&requirement)==errSecSuccess,
                  SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate|kSecCSCheckNestedCode|kSecCSCheckAllArchitectures),requirement)==errSecSuccess else{throw VideoError.permission("独立插件实际Apple代码、资源或固定签名身份未通过")}
            var raw:CFDictionary?
            guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&raw)==errSecSuccess,let info=raw as? [String:Any],
                  let flags=info[kSecCodeInfoFlags as String] as? NSNumber,flags.uint32Value & 0x10000 != 0 else{throw VideoError.permission("独立插件缺少有效Hardened Runtime签名")}
            let entitlements=info[kSecCodeInfoEntitlementsDict as String] as? [String:Any] ?? [:]
            let identityKeys:Set<String>=["com.apple.application-identifier","com.apple.developer.team-identifier"]
            if isService {
                guard let sandbox=entitlements["com.apple.security.app-sandbox"],CFGetTypeID(sandbox as CFTypeRef)==CFBooleanGetTypeID(),sandbox as? Bool==true,
                      Set(entitlements.keys).subtracting(identityKeys)==["com.apple.security.app-sandbox"] else{throw VideoError.permission("高级代码必须处于独立非inherit、无网络和客户目录授权的沙盒服务")}
            }else{
                // A trusted byte-only bridge can inherit the editor's existing domain;
                // it never links or loads premium code. The XPC service must not inherit it.
                guard Set(entitlements.keys).subtracting(identityKeys).isSubset(of:["com.apple.security.app-sandbox","com.apple.security.inherit"]),
                      entitlements["com.apple.security.get-task-allow"] == nil else{throw VideoError.permission("公开桥包含未允许的权限")}
            }
        }
    }
}

/// Bounded native capture shared by installation self-tests and publisher probes.
/// The caller verifies executable identity; this adapter grants no execution rights.
public enum NativeProcessProbe {
    private enum FailureCause:String {case exitNonzero="exit_nonzero",signal,timeout,stdoutLimit="stdout_limit",stderrLimit="stderr_limit"}
    public static func run(_ executable:URL,_ arguments:[String],root:URL,timeout:TimeInterval=20,includeStderr:Bool=false,inputData:Data?=nil)throws->Data {
        guard timeout.isFinite,timeout>0,timeout<=30,(inputData?.count ?? 0)<=4096 else {
            throw VideoError.invalid("原生只读探针的时限或输入超过有限边界")
        }
        let fm=FileManager.default,cache=root.appendingPathComponent(".native-probe-"+Codec.id())
        try fm.createDirectory(at:cache,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:cache)}
        let out=cache.appendingPathComponent("stdout"),err=cache.appendingPathComponent("stderr")
        guard fm.createFile(atPath:out.path,contents:nil,attributes:[.posixPermissions:0o600]),fm.createFile(atPath:err.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw VideoError.unavailable("无法建立受保护的原生探针输出")}
        let stdout=try FileHandle(forWritingTo:out),stderr=try FileHandle(forWritingTo:err)
        defer{try? stdout.close();try? stderr.close()}
        let task=Process();task.executableURL=executable;task.arguments=arguments;task.currentDirectoryURL=root
        task.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8","LC_ALL":"en_US.UTF-8","TMPDIR":cache.path]
        let stdin=inputData==nil ? nil:Pipe()
        if let stdin{task.standardInput=stdin}else{task.standardInput=FileHandle.nullDevice};task.standardOutput=stdout;task.standardError=stderr
        func stop() {
            if task.isRunning{task.terminate();let limit=Date().addingTimeInterval(1);while task.isRunning && Date()<limit{Thread.sleep(forTimeInterval:0.025)};if task.isRunning{kill(task.processIdentifier,SIGKILL)}}
            task.waitUntilExit()
        }
        let started=ProcessInfo.processInfo.systemUptime
        try task.run()
        // A failed pipe write must also reap the launched bridge, never orphan it.
        defer{stop()}
        if let inputData,let stdin{try stdin.fileHandleForWriting.write(contentsOf:inputData);try stdin.fileHandleForWriting.close()}
        let deadline=Date().addingTimeInterval(timeout)
        var stopCause:FailureCause?
        while task.isRunning && Date()<deadline {
            let a=(try? out.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0,b=(try? err.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            if a>4*1024*1024{stopCause = .stdoutLimit;break}
            if b>1024*1024{stopCause = .stderrLimit;break}
            Thread.sleep(forTimeInterval:0.025)
        }
        if task.isRunning,stopCause==nil{stopCause = .timeout}
        if task.isRunning{stop()}else{task.waitUntilExit()}
        try stdout.synchronize();try stderr.synchronize()
        let outBytes=(try out.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0),errBytes=(try err.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
        let cause:FailureCause?
        if let stopCause{cause=stopCause}
        else if outBytes>4*1024*1024{cause = .stdoutLimit}
        else if errBytes>1024*1024{cause = .stderrLimit}
        else if Date()>=deadline{cause = .timeout}
        else if task.terminationReason != .exit{cause = .signal}
        else if task.terminationStatus != 0{cause = .exitNonzero}
        else{cause=nil}
        if let cause {
            let reason=task.terminationReason == .exit ? "exit":"signal"
            let elapsed=Int(max(0,ProcessInfo.processInfo.systemUptime-started)*1000)
            // Numeric facts only: never include captured bytes, request input, arguments or environment.
            throw VideoError.unavailable("原生只读探针未通过：cause=\(cause.rawValue); exitreason=\(reason); status=\(task.terminationStatus); elapsed_ms=\(elapsed); out_bytes=\(outBytes); err_bytes=\(errBytes)")
        }
        return try Data(contentsOf:out)+(includeStderr ? Data(contentsOf:err):Data())
    }
}

/// Observe the real signed service before issuing or installing declarations.
/// Only three no-input RPCs are sent, never a customer frame or an entitlement.
public enum PluginPackageReadOnlyProbe {
    public static func verify(root:URL,manifest:PluginPackageManifest,scratchRoot:URL)throws {
        let expected=try PluginExecutionDescriptor(pluginID:manifest.module.id,architecture:manifest.execution.architecture)
        guard manifest.execution==expected else{throw VideoError.permission("插件只读探针拒绝非固定入口或服务描述")}
        try PluginPackageRules.verifyFiles(manifest,root:root)
        try PluginNativeCode.verify(root:root,execution:expected)
        let requests=try PluginPackageProbeRules.requests(),wire=try PluginPackageProbeRules.input(requests)
        let result=try NativeProcessProbe.run(root.appendingPathComponent(expected.entrypoint),[],root:scratchRoot,timeout:25,inputData:wire)
        try PluginPackageProbeRules.validate(result,requests:requests,manifest:manifest)
        // Code/resources cannot silently change during the real handshake.
        try PluginPackageRules.verifyFiles(manifest,root:root)
        try PluginNativeCode.verify(root:root,execution:expected)
    }
}

public enum PluginBridgeWire {
    public static let metadata="__video_transport"
    public static func response(_ data:Data,pid:pid_t)throws->Data {
        guard data.count<=PluginProtocolRules.maximumResponseBytes,var value=try JSONSerialization.jsonObject(with:data) as? [String:Any],pid>1 else{throw VideoError.invalid("插件桥响应不合法")}
        value[metadata]=["event":"response","peer_pid":Int(pid)]
        return try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    }
    public static func event(_ name:String,pid:pid_t)->Data { (try? JSONSerialization.data(withJSONObject:[metadata:["event":name,"peer_pid":Int(pid)]],options:[.sortedKeys])) ?? Data() }
    public static func parse(_ data:Data)throws->(String,pid_t) {
        guard data.count<=PluginProtocolRules.maximumResponseBytes+1024,let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],let transport=value[metadata] as? [String:Any],Set(transport.keys)==["event","peer_pid"],let event=transport["event"] as? String,["response","peer_exited","transport_failed"].contains(event),let pid=transport["peer_pid"] as? Int,pid>1,pid<=Int(Int32.max) else{throw VideoError.permission("插件桥缺少真实peer身份或有限事件")}
        if event != "response",Set(value.keys) != [metadata]{throw VideoError.permission("插件退出事件夹带额外数据")}
        return(event,pid_t(pid))
    }
}

private struct PluginPIDIdentity:Equatable {
    let pid:pid_t;let seconds:Int;let microseconds:Int
    static func read(_ pid:pid_t)->PluginPIDIdentity? {
        guard pid>1 else{return nil};var mib:[Int32]=[CTL_KERN,KERN_PROC,KERN_PROC_PID,pid],info=kinfo_proc(),size=MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib,UInt32(mib.count),&info,&size,nil,0)==0,size==MemoryLayout<kinfo_proc>.size,info.kp_proc.p_pid==pid else{return nil}
        return PluginPIDIdentity(pid:pid,seconds:info.kp_proc.p_un.__p_starttime.tv_sec,microseconds:Int(info.kp_proc.p_un.__p_starttime.tv_usec))
    }
}
/// Exact dynamic parent provenance, captured before establishing any service connection.
private struct PluginBridgeParent {
    let identity:PluginPIDIdentity;let codeHash:Data;let probeOnly:Bool
    static func inspect()throws->PluginBridgeParent {
        let pid=getppid();guard let identity=PluginPIDIdentity.read(pid) else{throw VideoError.permission("桥不能核验真实父进程启动身份")}
        var code:SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code)==errSecSuccess,let code else{throw VideoError.permission("桥父进程缺少有效动态代码身份")}
        var role:Bool?
        for (identifier,probe) in [("com.ayqy.video.mac",false),("com.ayqy.video.advanced",false),("com.ayqy.video.install",true),("com.ayqy.video.publisher",true),("com.ayqy.video.publisher.vendor-free",true)] {
            var requirement:SecRequirement?
            if SecRequirementCreateWithString(PluginNativeCode.requirement(identifier:identifier) as CFString,[],&requirement)==errSecSuccess,
               SecCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),requirement)==errSecSuccess{role=probe;break}
        }
        var raw:CFDictionary?,staticCode:SecStaticCode?
        guard let probe=role,SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,
              SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&raw)==errSecSuccess,
              let info=raw as? [String:Any],let hash=info[kSecCodeInfoUnique as String] as? Data,
              let flags=info[kSecCodeInfoFlags as String] as? NSNumber,flags.uint32Value & 0x10000 != 0,
              (info[kSecCodeInfoEntitlementsDict as String] as? [String:Any])?["com.apple.security.get-task-allow"] == nil else{throw VideoError.permission("桥父进程不是固定发行Host或只读安装探针")}
        return PluginBridgeParent(identity:identity,codeHash:hash,probeOnly:probe)
    }
    func verify(method:PluginMethod)throws {
        let current=try Self.inspect()
        guard current.identity==identity,current.codeHash==codeHash,current.probeOnly==probeOnly,
              !probeOnly || [PluginMethod.handshake,.describe,.health].contains(method) else{throw VideoError.permission("桥父进程身份变化或只读探针请求越权")}
    }
}
final class PluginCloseReceipt:@unchecked Sendable {
    private let condition=NSCondition();private var result:Result<Void,VideoError>?
    func finish(_ value:Result<Void,VideoError>){condition.lock();if result==nil{result=value};condition.broadcast();condition.unlock()}
    func wait()throws {condition.lock();defer{condition.unlock()};let until=Date().addingTimeInterval(7)
        while result==nil {guard condition.wait(until:until) else{throw VideoError.unavailable("原插件清理仍未形成终止回执，不重试终止")}}
        return try result!.get()
    }
}
final class PluginWeakCancellation {
    weak var value:RenderCancellation?
    init(_ value:RenderCancellation){self.value=value}
}
private final class PluginBridgePeer:@unchecked Sendable {
    let connection:NSXPCConnection;let lock=NSLock();let exited=DispatchSemaphore(value:0)
    var pid:pid_t=0;var identity:PluginPIDIdentity?;var watcher:DispatchSourceProcess?;var didExit=false
    init(service:String){connection=NSXPCConnection(serviceName:service);connection.remoteObjectInterface=NSXPCInterface(with:PluginXPCWire.self);connection.setCodeSigningRequirement(PluginNativeCode.requirement(identifier:service));connection.resume()}
    func observe()throws->pid_t {
        lock.lock();defer{lock.unlock()};let actual=connection.processIdentifier
        guard actual>1,pid==0 || pid==actual else{throw VideoError.permission("XPC实际peer身份变化")}
        if pid==0 {
            pid=actual;identity=PluginPIDIdentity.read(actual)
            let source=DispatchSource.makeProcessSource(identifier:actual,eventMask:.exit,queue:.global(qos:.utility))
            source.setEventHandler{[weak self] in guard let self else{return};self.lock.lock();self.didExit=true;self.lock.unlock();self.exited.signal()}
            watcher=source;source.resume()
        }
        return pid
    }
    func exchange(_ data:Data,until:Date)throws->Data {
        let done=DispatchSemaphore(value:0),answer=PluginReplyBox()
        guard let proxy=connection.remoteObjectProxyWithErrorHandler({_ in answer.fail();done.signal()}) as? PluginXPCWire else{throw VideoError.unavailable("XPC服务未提供标准接口")}
        proxy.exchange(data){data in answer.set(data);done.signal()}
        guard done.wait(timeout:.now()+max(0,until.timeIntervalSinceNow)) == .success,let value=answer.value else{throw VideoError.unavailable("XPC调用未在明确截止内完成")}
        _=try observe();return value
    }
    func close(invocation:PluginInvocation?)throws {
        // Closing a connection is not evidence of process exit. Only this kernel
        // watcher for the authenticated peer can authorize peer_exited.
        lock.lock();let target=pid,alreadyExited=didExit;lock.unlock()
        guard target>1 else{throw VideoError.unavailable("未取得XPC实际peer身份，不能声称已终止")}
        if !alreadyExited,let invocation {
            let request=PluginRPCRequest(requestID:Codec.id(),method:.cancel,invocation:invocation)
            _=try? exchange(Codec.data(request),until:Date().addingTimeInterval(1))
        }
        lock.lock();var ended=didExit;lock.unlock()
        if !ended {_ = exited.wait(timeout:.now()+1);lock.lock();ended=didExit;lock.unlock()}
        if !ended {
            // No PID guessing or global kill. Refuse if start identity is unavailable
            // or reused; a previous failed cleanup never grants a second attempt.
            guard let original=identity,PluginPIDIdentity.read(target)==original,connection.processIdentifier==target else{throw VideoError.unavailable("实际XPC进程身份无法复核；终止未确认")}
            guard Darwin.kill(target,SIGKILL)==0 else{throw VideoError.unavailable("实际XPC进程强终止被拒，保留失败")}
            _=exited.wait(timeout:.now()+1);lock.lock();ended=didExit;lock.unlock()
        }
        guard ended else{throw VideoError.unavailable("未获得XPC实际进程退出事件")}
        connection.invalidate();watcher?.cancel()
    }
}
private final class PluginReplyBox:@unchecked Sendable {
    let lock=NSLock();private var data:Data?;private var failed=false
    var value:Data?{lock.lock();defer{lock.unlock()};return failed ? nil:data}
    func set(_ value:Data){lock.lock();data=value;lock.unlock()}
    func fail(){lock.lock();failed=true;lock.unlock()}
}

/// A pipe request is complete at its newline, not when the writer closes stdin.
/// Foundation read(upToCount:) can wait for the requested count or EOF on Darwin.
enum PluginStdioInput {
    static func readChunk(_ descriptor:Int32)throws->Data? {
        var bytes=[UInt8](repeating:0,count:65536)
        while true {
            let count=Darwin.read(descriptor,&bytes,bytes.count)
            if count>0{return Data(bytes.prefix(count))}
            if count==0{return nil}
            if errno==EINTR{continue}
            throw VideoError.unavailable("插件桥输入无法继续读取")
        }
    }
}

/// Byte framing only. Callers retain their own size, EOF and authorization rules.
struct PluginJSONLBuffer {
    private var storage:Data
    private var searched=0
    // Logical bytes covered by searches, not CPU comparisons or copying work.
    private(set) var searchedBytes=0
    init(_ initial:Data=Data()){storage=initial}
    var count:Int{storage.count}
    var isEmpty:Bool{storage.isEmpty}
    mutating func append(_ data:Data){storage.append(data)}
    mutating func append<S:Sequence>(contentsOf bytes:S) where S.Element==UInt8{storage.append(contentsOf:bytes)}
    mutating func popLine()->Data? {
        guard searched<storage.count else{return nil}
        let lower=storage.index(storage.startIndex,offsetBy:searched)
        guard let newline=storage[lower..<storage.endIndex].firstIndex(of:10) else {
            searchedBytes+=storage.count-searched;searched=storage.count;return nil
        }
        searchedBytes+=storage.distance(from:lower,to:newline)+1
        let line=Data(storage[..<newline])
        storage.removeSubrange(storage.startIndex...newline);searched=0
        return line
    }
    mutating func takeRemainder()->Data? {
        guard !storage.isEmpty else{return nil}
        let remainder=storage;storage=Data();searched=0;return remainder
    }
}

/// Trusted headless bridge. It contains no premium renderer and emits no diagnostics or input text.
public enum PluginStdioBridge {
    public static func run()->Never {
        guard CommandLine.arguments.count==1,let name=Bundle.main.infoDictionary?["VideoPluginServiceName"] as? String,PluginNativeCode.validService(name),Bundle.main.bundleIdentifier==name+".host" else{_exit(78)}
        guard let parent=try? PluginBridgeParent.inspect() else{_exit(77)}
        _ = fcntl(STDOUT_FILENO,F_SETNOSIGPIPE,1)
        let parentExit=DispatchSource.makeProcessSource(identifier:parent.identity.pid,eventMask:.exit,queue:.global(qos:.utility))
        parentExit.setEventHandler{_exit(125)};parentExit.resume()
        let parentMonitor=DispatchSource.makeTimerSource(queue:.global(qos:.utility))
        parentMonitor.schedule(deadline:.now()+0.5,repeating:0.5)
        parentMonitor.setEventHandler{if (try? parent.verify(method:.handshake)) == nil{_exit(125)}};parentMonitor.resume()
        let peer=PluginBridgePeer(service:name);var scope:PluginInvocation?,buffer=PluginJSONLBuffer();var failed=false
        do {
            func request(_ line:Data)throws {
                guard !line.isEmpty,line.count<=PluginProtocolRules.maximumRequestBytes else{throw VideoError.invalid("桥消息超限")}
                let value=try Codec.decoder().decode(PluginRPCRequest.self,from:line)
                try parent.verify(method:value.method)
                guard let current=value.invocation ?? value.input?.invocation else{throw VideoError.permission("桥请求缺少调用范围")}
                try PluginProtocolRules.validate(current)
                if let scope {guard scope==current else{throw VideoError.permission("桥拒绝切换完整调用")}}else{scope=current}
                let answer=try peer.exchange(line,until:Date(timeIntervalSince1970:current.deadlineUnixTime))
                try parent.verify(method:value.method)
                let output=try PluginBridgeWire.response(answer,pid:peer.pid)
                FileHandle.standardOutput.write(output);FileHandle.standardOutput.write(Data([10]))
            }
            while let data=try PluginStdioInput.readChunk(STDIN_FILENO) {
                buffer.append(data)
                while let line=buffer.popLine(){try request(line)}
                guard buffer.count<=PluginProtocolRules.maximumRequestBytes else{throw VideoError.invalid("桥消息超限")}
            }
            if let remainder=buffer.takeRemainder(){try request(remainder)}
        }catch{failed=true}
        do {try peer.close(invocation:scope);FileHandle.standardOutput.write(PluginBridgeWire.event("peer_exited",pid:peer.pid));FileHandle.standardOutput.write(Data([10]))}
        catch{failed=true;if peer.pid>1{FileHandle.standardOutput.write(PluginBridgeWire.event("transport_failed",pid:peer.pid));FileHandle.standardOutput.write(Data([10]))}}
        _exit(failed ? 8:0)
    }
}

/// Preserve short writes without adding a fixed sleep to every full pipe.
/// The caller still owns byte limits, peer identity and the response deadline.
enum PluginPipeOutput {
    static func write(_ data:Data,descriptor:Int32,until:Date,check:()throws->Void)throws {
        var offset=0
        while offset<data.count {
            try check()
            guard Date()<until else{throw VideoError.unavailable("插件请求写入超过调用截止")}
            let count=data.withUnsafeBytes{Darwin.write(descriptor,$0.baseAddress!.advanced(by:offset),data.count-offset)}
            if count>0{offset+=count;continue}
            guard count<0 else{throw VideoError.unavailable("插件桥未接收完整请求")}
            let failure=errno
            if failure==EINTR{continue}
            guard failure==EAGAIN || failure==EWOULDBLOCK else{throw VideoError.unavailable("插件桥未接收完整请求")}
            // Readiness may wake immediately. Five milliseconds is only the
            // previous authorization/cancel check interval, never a fixed nap.
            try check()
            let remaining=until.timeIntervalSinceNow
            guard remaining>0 else{throw VideoError.unavailable("插件请求写入超过调用截止")}
            var descriptorState=pollfd(fd:descriptor,events:Int16(POLLOUT),revents:0)
            let result=poll(&descriptorState,1,Int32(max(1,min(5,ceil(remaining*1000)))))
            if result<0{if errno==EINTR{continue};throw VideoError.unavailable("插件请求管道未能继续写入")}
            guard descriptorState.revents & Int16(POLLERR|POLLHUP|POLLNVAL)==0 else{throw VideoError.unavailable("插件桥在完整请求前关闭")}
            // Timeout, interruption and readiness all return through the same
            // live scope check before another byte can be written.
        }
    }
}

/// One exact render invocation owns one headless bridge and one isolated XPC process.
final class PluginProcessClient {
    let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe();let invocation:PluginInvocation
    private let closeLock=NSLock();private var closeRequested=false
    var buffer=PluginJSONLBuffer();var stderrBytes=0;var stderrOpen=true;var peer:pid_t?;var termination:Result<Void,VideoError>?
    init(package:VerifiedPluginPackage,scope:RenderInvocation)throws {
        try scope.check();try PluginPackageRules.verifyFiles(package.manifest,root:package.rootURL);try PluginNativeCode.verify(root:package.rootURL,execution:package.execution)
        invocation=PluginInvocation(workspaceID:scope.workspaceID,projectID:scope.projectID,revisionID:scope.revisionID,revisionDigest:scope.revisionDigest,jobID:scope.jobID,invocationID:scope.id,budgetReference:scope.budgetReference,currency:scope.currency,budgetLimit:scope.budgetLimit.amount,deadlineUnixTime:scope.deadline.timeIntervalSince1970)
        try PluginProtocolRules.validate(invocation)
        process.executableURL=package.rootURL.appendingPathComponent(package.execution.entrypoint);process.currentDirectoryURL=package.rootURL
        process.arguments=[];process.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8"]
        process.standardInput=input;process.standardOutput=output;process.standardError=errors;try process.run()
        for fd in [input.fileHandleForWriting.fileDescriptor,output.fileHandleForReading.fileDescriptor,errors.fileHandleForReading.fileDescriptor]{_ = fcntl(fd,F_SETFL,O_NONBLOCK)}
        _ = fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
    }
    func requestClose(){closeLock.lock();closeRequested=true;closeLock.unlock()}
    private func check(_ scope:RenderInvocation)throws{try scope.check();closeLock.lock();let closing=closeRequested;closeLock.unlock();if closing{throw CancellationError()}}
    private func next(until:Date,check:()throws->Void={})throws->Data {
        while Date()<until {
            try check()
            if let line=buffer.popLine(){return line}
            var descriptors=[pollfd(fd:output.fileHandleForReading.fileDescriptor,events:Int16(POLLIN|POLLHUP),revents:0),pollfd(fd:stderrOpen ? errors.fileHandleForReading.fileDescriptor:-1,events:Int16(POLLIN|POLLHUP),revents:0)]
            let status=poll(&descriptors,2,25);guard status>=0 || errno==EINTR else{throw VideoError.unavailable("插件管道未能继续读取")}
            for index in 0..<2 where descriptors[index].revents != 0 {
                var bytes=[UInt8](repeating:0,count:65536);let count=read(descriptors[index].fd,&bytes,bytes.count)
                if count>0 {if index==0{buffer.append(contentsOf:bytes.prefix(count))}else{stderrBytes+=count}}
                if count==0,index==1{stderrOpen=false}
                // popLine above found no complete line; an EOF read appended no bytes.
                if count==0,index==0{throw VideoError.unavailable("插件桥提前关闭，缺少完整退出或响应回执")}
            }
            guard buffer.count<=PluginProtocolRules.maximumResponseBytes+2048,stderrBytes<=1024*1024 else{throw VideoError.unavailable("插件管道输出超出有界长度")}
        }
        throw VideoError.unavailable("插件响应或终止超过明确截止")
    }
    func exchange(_ request:PluginRPCRequest,scope:RenderInvocation)throws->PluginRPCResponse {
        try check(scope);guard request.invocation==invocation || request.input?.invocation==invocation else{throw VideoError.permission("插件请求不属于原完整调用")}
        var data=try Codec.data(request);guard data.count<=PluginProtocolRules.maximumRequestBytes else{throw VideoError.invalid("插件请求超过有界长度")};data.append(10)
        try PluginPipeOutput.write(data,descriptor:input.fileHandleForWriting.fileDescriptor,until:scope.deadline){try self.check(scope)}
        let answer=try next(until:min(scope.deadline,Date().addingTimeInterval(10))){try self.check(scope)};try check(scope)
        let(event,pid)=try PluginBridgeWire.parse(answer)
        guard event=="response",peer==nil || peer==pid else{throw VideoError.permission("插件响应来自其他进程或不是方法回执")};peer=pid
        let value=try Codec.decoder().decode(PluginRPCResponse.self,from:answer)
        guard value.protocolMajor==1,value.requestID==request.requestID,value.ok,value.error==nil else{throw VideoError.unavailable("独立插件拒绝请求或协议回执不符；未发表部分帧")}
        return value
    }
    func close()throws {
        if let termination{return try termination.get()}
        // Mark an in-flight failure first. A catch/defer cannot retry termination.
        termination = .failure(.unavailable("插件终止尚未确认"))
        do {
            try input.fileHandleForWriting.close();let deadline=Date().addingTimeInterval(5);var exited=false
            while !exited {
                let line=try next(until:deadline);let(event,pid)=try PluginBridgeWire.parse(line)
                guard peer==nil || peer==pid else{throw VideoError.permission("插件终止peer身份变化")};peer=pid
                if event=="peer_exited"{exited=true}else if event=="transport_failed"{throw VideoError.unavailable("插件实际进程终止未确认")}
            }
            while process.isRunning,Date()<deadline{Thread.sleep(forTimeInterval:0.01)}
            guard !process.isRunning,process.terminationReason == .exit,process.terminationStatus==0,stderrBytes==0 else{throw VideoError.unavailable("插件peer已退出但公开桥清理未通过")}
            termination = .success(())
        }catch{
            let failure=error as? VideoError ?? .unavailable("插件终止或管道回收失败")
            termination = .failure(failure)
            if process.isRunning{process.terminate();let end=Date().addingTimeInterval(0.2);while process.isRunning,Date()<end{Thread.sleep(forTimeInterval:0.01)};if process.isRunning{_ = Darwin.kill(process.processIdentifier,SIGKILL)}}
        }
        try? output.fileHandleForReading.close();try? errors.fileHandleForReading.close()
        return try termination!.get()
    }
}
