import Foundation

/// Independent schema9 transport budget. The published raster/RPC budgets stay unchanged.
public enum PluginModelBankRules {
    public static let maximumChunkBytes = 512 * 1024
    public static let maximumTotalBytes = 64 * 1024 * 1024
    public static let maximumAssets = 512
    public static let maximumBanks = 2
    static func identifier(_ value: String) -> Bool {
        PluginProtocolRules.text(value, maximum:160) && value == value.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func pngPixels(_ data: Data) throws -> Int {
        let b=Array(data.prefix(33))
        guard b.count==33,Array(b[0..<8])==[137,80,78,71,13,10,26,10],Array(b[8..<16])==[0,0,0,13,73,72,68,82] else {throw VideoError.invalid("模型纹理须有实际PNG IHDR头")}
        func integer(_ start:Int)->Int {b[start..<start+4].reduce(0){($0<<8)|Int($1)}}
        let width=integer(16),height=integer(20)
        guard (1...8192).contains(width),(1...8192).contains(height),width*height<=PluginProtocolRules.maximumImagePixels else {throw VideoError.invalid("模型PNG展开尺寸超过既有图片预算")}
        return width*height
    }
}

/// Only immutable byte identities cross. No source paths, permissions, audio or approvals.
public struct PluginModelBankManifest: Codable, Equatable, Sendable {
    public let assets: [ModelAssetReference]
    public init(assets:[ModelAssetReference]) {self.assets=assets.sorted{$0.assetID<$1.assetID}}
    public init(scene:ModelScene3D,durationFrames:Int) throws {
        try scene.validate(durationFrames:durationFrames)
        var references:[String:ModelAssetReference]=[:]
        for instance in scene.instances {
            for item in [instance.resource.model]+Array(instance.resource.textures.values) {references[item.assetID]=item}
        }
        self.init(assets:Array(references.values));try validate()
    }
    public var totalBytes:Int {assets.reduce(0){sum,item in let value=sum.addingReportingOverflow(item.bytes);return value.overflow ? Int.max:value.partialValue}}
    public var dependencyFingerprints:[String:String] {assets.reduce(into:[:]){$0[$1.assetID]=$1.sha256}}
    public func validate() throws {
        guard (1...PluginModelBankRules.maximumAssets).contains(assets.count),assets==assets.sorted(by:{$0.assetID<$1.assetID}),Set(assets.map(\.assetID)).count==assets.count,assets.contains(where:{$0.fileExtension=="dae"}) else {throw VideoError.invalid("模型银行须为排序、唯一且有真实DAE的有限资源清单")}
        var total=0
        for item in assets {
            try item.validate()
            guard PluginModelBankRules.identifier(item.assetID),item.bytes <= (item.fileExtension=="dae" ? DAEInspector.maximumBytes:32*1024*1024),item.bytes<=PluginModelBankRules.maximumTotalBytes-total else {throw VideoError.invalid("模型银行资源或独立64MiB预算无效")}
            total+=item.bytes
        }
    }
    public func contentDigest() throws -> String {try validate();return try Codec.digest(self)}
}
public struct PluginModelBankReference: Codable, Equatable, Sendable {
    public let bankID:String
    public let manifestDigest:String
    public let invocationDigest:String
    public init(bankID:String,manifestDigest:String,invocationDigest:String) {self.bankID=bankID;self.manifestDigest=manifestDigest;self.invocationDigest=invocationDigest}
    public func validate(invocation:PluginInvocation,manifest:PluginModelBankManifest) throws {
        guard PluginModelBankRules.identifier(bankID),manifestDigest == (try manifest.contentDigest()),invocationDigest == (try Codec.digest(invocation)) else {throw VideoError.permission("模型银行引用不属于完整冻结调用或精确资源清单")}
    }
}
public enum PluginModelBankOperationKind:String,Codable,CaseIterable,Sendable {case begin,append,commit,release}
public struct PluginModelBankOperation: Codable, Equatable, Sendable {
    public let kind:PluginModelBankOperationKind
    public let invocation:PluginInvocation
    public let bankID:String
    public let manifest:PluginModelBankManifest?
    public let assetID:String?
    public let offset:Int?
    public let data:Data?
    public let sha256:String?
    public init(kind:PluginModelBankOperationKind,invocation:PluginInvocation,bankID:String,manifest:PluginModelBankManifest?=nil,assetID:String?=nil,offset:Int?=nil,data:Data?=nil,sha256:String?=nil) {
        self.kind=kind;self.invocation=invocation;self.bankID=bankID;self.manifest=manifest;self.assetID=assetID;self.offset=offset;self.data=data;self.sha256=sha256
    }
    public func validate(now:Date=Date()) throws {
        try PluginProtocolRules.validate(invocation,now:now)
        guard PluginModelBankRules.identifier(bankID) else {throw VideoError.invalid("模型银行标识无效")}
        switch kind {
        case .begin:
            guard let manifest,assetID==nil,offset==nil,data==nil,sha256==nil else {throw VideoError.invalid("begin只接受完整资源清单")};try manifest.validate()
        case .append:
            guard manifest==nil,let assetID,PluginModelBankRules.identifier(assetID),let offset,offset>=0,let data,!data.isEmpty,data.count<=PluginModelBankRules.maximumChunkBytes,let sha256,PluginProtocolRules.hash(sha256),sha256==Codec.hash(data) else {throw VideoError.invalid("append须为有序、有界且摘要核同的原始字节块")}
        case .commit,.release:
            guard manifest==nil,assetID==nil,offset==nil,data==nil,sha256==nil else {throw VideoError.invalid("commit/release只接受完整调用和银行标识")}
        }
    }
}
public enum PluginModelBankState:String,Codable,Sendable {case receiving,ready,released}
public struct PluginModelBankReceipt: Codable, Equatable, Sendable {
    public let reference:PluginModelBankReference
    public let state:PluginModelBankState
    public let receivedBytes:Int
    public let totalBytes:Int
    public init(reference:PluginModelBankReference,state:PluginModelBankState,receivedBytes:Int,totalBytes:Int) {self.reference=reference;self.state=state;self.receivedBytes=receivedBytes;self.totalBytes=totalBytes}
}

/// Value-semantic Data snapshots survive bounded store eviction for one active task.
/// PNG checks here are bounded header checks; the renderer must still decode actual PNGs.
public struct PluginModelBankSnapshot: Sendable {
    public let reference:PluginModelBankReference
    public let manifest:PluginModelBankManifest
    public let invocation:PluginInvocation
    public let assets:[String:Data]
    public let inspections:[String:DAEInspection]
    public init(invocation:PluginInvocation,bankID:String,manifest:PluginModelBankManifest,assets:[String:Data],now:Date=Date()) throws {
        try PluginProtocolRules.validate(invocation,now:now);try manifest.validate()
        guard PluginModelBankRules.identifier(bankID),Set(assets.keys)==Set(manifest.assets.map(\.assetID)) else {throw VideoError.invalid("模型银行字节与完整清单不闭合")}
        var parsed:[String:DAEInspection]=[:],pixels=0
        for item in manifest.assets {
            guard let data=assets[item.assetID],data.count==item.bytes,Codec.hash(data)==item.sha256 else {throw VideoError.permission("模型银行实际字节长度或SHA256不同")}
            if item.fileExtension=="dae" {parsed[item.assetID]=try DAEInspector.inspect(data)}
            else {pixels+=try PluginModelBankRules.pngPixels(data);guard pixels<=PluginProtocolRules.maximumTotalImagePixels else {throw VideoError.invalid("模型PNG总展开像素超过既有48M预算")}}
        }
        self.invocation=invocation;self.manifest=manifest;self.assets=assets;self.inspections=parsed
        reference=PluginModelBankReference(bankID:bankID,manifestDigest:try manifest.contentDigest(),invocationDigest:try Codec.digest(invocation))
    }
    public func validate(reference:PluginModelBankReference,invocation:PluginInvocation,scene:ModelScene3D,durationFrames:Int,now:Date=Date()) throws {
        try PluginProtocolRules.validate(invocation,now:now)
        let expected=try PluginModelBankManifest(scene:scene,durationFrames:durationFrames)
        guard self.invocation==invocation,self.reference==reference,manifest==expected else {throw VideoError.permission("模型银行快照与完整调用或当前场景闭包不相同")}
        try reference.validate(invocation:invocation,manifest:manifest)
        for instance in scene.instances {
            guard inspections[instance.resource.model.assetID]==instance.resource.inspection else {throw VideoError.permission("模型场景解析元数据与银行中真实DAE不同")}
        }
    }
}

/// Pure in-memory bounded transport. Synchronization covers every mutable entry.
/// close is terminal; the Host also owns invocation cancellation and active-task snapshots.
public final class PluginModelBankStore: @unchecked Sendable {
    private struct Entry {
        let token=UUID()
        let invocation:PluginInvocation;let manifest:PluginModelBankManifest;let reference:PluginModelBankReference
        var assets:[String:Data]=[:];var snapshot:PluginModelBankSnapshot?;var generation=0
        var received:Int {assets.values.reduce(0){$0+$1.count}}
        var receipt:PluginModelBankReceipt {.init(reference:reference,state:snapshot==nil ? .receiving:.ready,receivedBytes:received,totalBytes:manifest.totalBytes)}
    }
    private let lock=NSLock()
    private var entries:[String:Entry]=[:]
    private var released:[(PluginInvocation,PluginModelBankReceipt)]=[]
    private var inFlight:[UUID:Int]=[:]
    private var closed=false
    public init() {}
    private var ownership:(count:Int,bytes:Int) {
        let live=Set(entries.values.map(\.token)),detached=inFlight.filter{!live.contains($0.key)}
        return (entries.count+detached.count,entries.values.reduce(0){$0+$1.manifest.totalBytes}+detached.values.reduce(0,+))
    }
    public var bankCount:Int {lock.lock();defer{lock.unlock()};return ownership.count}
    public var reservedBytes:Int {lock.lock();defer{lock.unlock()};return ownership.bytes}
    private func purge(_ now:Date) {
        entries=entries.filter{$0.value.invocation.deadlineUnixTime>now.timeIntervalSince1970}
        released.removeAll{$0.0.deadlineUnixTime<=now.timeIntervalSince1970}
    }
    public func purgeExpired(now:Date=Date()) {lock.lock();defer{lock.unlock()};purge(now)}
    public func close() {lock.lock();defer{lock.unlock()};entries.removeAll();released.removeAll();inFlight.removeAll();closed=true}
    public func apply(_ operation:PluginModelBankOperation,now:Date=Date()) throws -> PluginModelBankReceipt {
        lock.lock();defer{lock.unlock()};purge(now)
        guard !closed else {throw VideoError.permission("模型银行调用已关闭，不能重新注册")}
        try operation.validate(now:now)
        let id=operation.bankID
        if operation.kind == .begin {
            let manifest=operation.manifest!
            if let entry=entries[id] {
                guard entry.invocation==operation.invocation,entry.manifest==manifest else {throw VideoError.permission("银行标识已绑定另一完整调用或清单")};return entry.receipt
            }
            guard !released.contains(where:{$0.1.reference.bankID==id}),ownership.count<PluginModelBankRules.maximumBanks,manifest.totalBytes<=PluginModelBankRules.maximumTotalBytes-ownership.bytes else {throw VideoError.invalid("模型银行已释放或超过两银行合计64MiB预算")}
            let reference=PluginModelBankReference(bankID:id,manifestDigest:try manifest.contentDigest(),invocationDigest:try Codec.digest(operation.invocation))
            let entry=Entry(invocation:operation.invocation,manifest:manifest,reference:reference);entries[id]=entry;return entry.receipt
        }
        guard var entry=entries[id] else {
            if operation.kind == .release,let old=released.first(where:{$0.1.reference.bankID==id}) {
                guard old.0==operation.invocation else {throw VideoError.permission("已释放银行属于另一完整调用")};return old.1
            }
            throw VideoError.invalid("模型银行不存在或已经过期")
        }
        guard entry.invocation==operation.invocation else {throw VideoError.permission("模型银行操作与原完整调用不相同")}
        switch operation.kind {
        case .begin:throw VideoError.invalid("begin须先建立独立资源清单")
        case .append:
            guard let item=entry.manifest.assets.first(where:{$0.assetID==operation.assetID}),let data=operation.data,let offset=operation.offset,offset<=item.bytes,data.count<=item.bytes-offset else {throw VideoError.invalid("字节块不属于清单资源或超过声明长度")}
            var current=entry.assets[item.assetID] ?? Data()
            if offset<current.count {
                guard data.count<=current.count-offset,current.subdata(in:offset..<offset+data.count)==data else {throw VideoError.permission("重试字节块与已接受原块不同")};return entry.receipt
            }
            guard entry.snapshot==nil,offset==current.count else {throw VideoError.invalid("字节块必须连续追加，不能有空洞或修改已提交快照")}
            current.append(data);entry.assets[item.assetID]=current;entry.generation+=1;entries[id]=entry;return entry.receipt
        case .commit:
            if entry.snapshot != nil {return entry.receipt}
            guard inFlight[entry.token]==nil else {throw VideoError.unavailable("此银行正在提交核验，请沿同请求重试")}
            let started=Date();inFlight[entry.token]=entry.manifest.totalBytes
            // A bounded parse/hash may be slow. Never hold the state lock across it:
            // release/close stay responsive, and detached work retains its reservation.
            lock.unlock()
            let snapshot:PluginModelBankSnapshot
            do {snapshot=try PluginModelBankSnapshot(invocation:entry.invocation,bankID:id,manifest:entry.manifest,assets:entry.assets,now:now)}
            catch {lock.lock();inFlight.removeValue(forKey:entry.token);throw error}
            lock.lock();inFlight.removeValue(forKey:entry.token)
            let completed=now.addingTimeInterval(max(0,Date().timeIntervalSince(started)));purge(completed)
            guard !closed,var current=entries[id],current.token==entry.token,current.generation==entry.generation else {throw VideoError.permission("银行在提交期间已改变、释放、过期或关闭")}
            current.snapshot=snapshot;entries[id]=current;return current.receipt
        case .release:
            let receipt=PluginModelBankReceipt(reference:entry.reference,state:.released,receivedBytes:entry.received,totalBytes:entry.manifest.totalBytes)
            entries.removeValue(forKey:id);released.append((entry.invocation,receipt));if released.count>PluginModelBankRules.maximumBanks {released.removeFirst()};return receipt
        }
    }
    public func snapshot(reference:PluginModelBankReference,invocation:PluginInvocation,scene:ModelScene3D,durationFrames:Int,now:Date=Date()) throws -> PluginModelBankSnapshot {
        lock.lock();defer{lock.unlock()};purge(now)
        guard !closed,let entry=entries[reference.bankID],let snapshot=entry.snapshot else {throw VideoError.permission("模型银行尚未提交、已过期或已关闭")}
        try snapshot.validate(reference:reference,invocation:invocation,scene:scene,durationFrames:durationFrames,now:now);return snapshot
    }
}
