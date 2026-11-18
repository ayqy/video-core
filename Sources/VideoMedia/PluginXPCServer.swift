import Foundation
import Darwin
import VideoCore

@objc(VideoPluginXPCWire) public protocol PluginXPCWire {
    func exchange(_ data:Data,withReply reply:@escaping(Data)->Void)
}

private final class PluginXPCObject:NSObject,PluginXPCWire {
    let handler:@Sendable(Data,@escaping @Sendable(Data)->Void)->Void
    init(_ handler:@escaping @Sendable(Data,@escaping @Sendable(Data)->Void)->Void){self.handler=handler}
    func exchange(_ data:Data,withReply reply:@escaping(Data)->Void){
        guard !data.isEmpty,data.count<=PluginProtocolRules.maximumRequestBytes else{reply(Data());return}
        handler(data){answer in reply(answer.count<=PluginProtocolRules.maximumResponseBytes ? answer:Data())}
    }
}
private final class PluginXPCDelegate:NSObject,NSXPCListenerDelegate {
    let object:PluginXPCObject;let service:String
    private let lock=NSLock();private var accepted=false
    init(service:String,handler:@escaping @Sendable(Data,@escaping @Sendable(Data)->Void)->Void){self.service=service;object=PluginXPCObject(handler)}
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
        lock.lock();guard !accepted else{lock.unlock();return false};accepted=true;lock.unlock()
        connection.setCodeSigningRequirement(PluginNativeCode.requirement(identifier:service+".host"))
        connection.exportedInterface=NSXPCInterface(with:PluginXPCWire.self)
        connection.exportedObject=object
        // This service is invocation-private. Loss of its one authenticated bridge
        // must stop actual code, including a renderer blocked on another queue.
        connection.invalidationHandler={_exit(125)};connection.interruptionHandler={_exit(125)}
        connection.resume();return true
    }
}

enum PluginXPCResourceLimits {
    static let maximumFileBytes = rlim_t(32 * 1024 * 1024)

    // Optional framework caches must receive EFBIG at the unchanged file limit,
    // rather than terminating the invocation-private rendering process.
    static func install() -> Bool {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        guard sigemptyset(&action.sa_mask) == 0,
              sigaction(SIGXFSZ, &action, nil) == 0 else { return false }
        func ceiling(_ resource: Int32, _ value: rlim_t) -> Bool {
            var limit = rlimit(rlim_cur: value, rlim_max: value)
            return setrlimit(resource, &limit) == 0
        }
        return ceiling(RLIMIT_CPU, rlim_t(4 * 60 * 60))
            && ceiling(RLIMIT_FSIZE, maximumFileBytes)
            && ceiling(RLIMIT_NOFILE, rlim_t(128))
            && ceiling(RLIMIT_CORE, rlim_t(0))
    }
}

/// launchd creates the separate entitlement domain. No inherited sandbox, paths or keys.
public enum PluginXPCServer {
    public static func run(exchange:@escaping @Sendable(Data,@escaping @Sendable(Data)->Void)->Void)->Never {
        guard let name=Bundle.main.bundleIdentifier,PluginNativeCode.validService(name) else{_exit(78)}
        // Hard resource ceilings are per process. They do not claim a RAM or user-wide process quota.
        guard PluginXPCResourceLimits.install() else { _exit(78) }
        let delegate=PluginXPCDelegate(service:name,handler:exchange),listener=NSXPCListener.service()
        listener.delegate=delegate
        withExtendedLifetime(delegate){listener.resume();RunLoop.current.run()}
        _exit(78)
    }
}
