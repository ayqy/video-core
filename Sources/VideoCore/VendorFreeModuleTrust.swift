import Foundation
import CryptoKit

/// A separate, purpose-bound envelope. Its signature is never a SignedDocument
/// signature over payload alone, so it cannot become a licence or release token.
public struct RestrictedFreeModuleDocument: Codable, Sendable {
    public var format = 1
    public var purpose: String
    public var issuerKeySHA256: String
    public var pairSHA256: String
    public var payload: Data
    public var signature: Data
    public init(purpose:String,issuerKeySHA256:String,pairSHA256:String,payload:Data,signature:Data) {
        self.purpose=purpose;self.issuerKeySHA256=issuerKeySHA256;self.pairSHA256=pairSHA256
        self.payload=payload;self.signature=signature
    }
}

/// This trust is only for fixed free/closed knowledge modules. The legacy root,
/// customer licences, revocations, StoreKit and installer signatures stay separate.
public enum VendorFreeModuleTrust {
    public static let resourceName = "vendor-free-modules.pub"
    // Set only from the actual persistent vendor issuer's public-key receipt.
    // No generated fixture, fallback key, environment or caller key may fill it.
    public static let expectedKeySHA256: String? = "3a7c3911dfd8049f4e631e3e03389079e181456a43647ddcbbdcfdffbbd06970"
    private static let compiledPublicKey: Data? = Data([47,236,110,126,179,59,139,0,184,189,20,43,61,167,190,69,71,235,48,228,241,65,64,31,168,82,57,235,23,176,37,255])
    public static let manifestPurpose = "com.ayqy.video.free-module.manifest.v1"
    public static let policyPurpose = "com.ayqy.video.free-module.policy.v1"
    private static let envelopeFields:Set<String> = ["format","purpose","issuerKeySHA256","pairSHA256","payload","signature"]
    private struct Pair:Encodable {var manifest:PluginPackageManifest;var policy:CommercialPolicy}
    private struct SigningBody:Encodable {
        var format=1;var purpose:String;var issuerKeySHA256:String;var pairSHA256:String;var payload:Data
    }

    public static func validateScope(manifest:PluginPackageManifest,policy:CommercialPolicy) throws {
        let module=manifest.module
        let schemas:[String:Set<Int>]=["video.game":[6,7,8],"video.cartoon":[4,5,6,7,8]]
        guard let schemas=schemas[module.id],let capability=PluginPackageRules.capabilities[module.id],
              schemas.contains(module.inputSchema),module.capabilities==[capability],
              module.abi==1,module.minimumCore==1,module.outputSchema==1,module.permissions.isEmpty,
              module.sourceVisibility=="closed",policy.pluginID==module.id,
              policy.access=="free",policy.sourceVisibility=="closed",
              manifest.format==1,manifest.policyRef==PluginPackageRules.policyName,
              manifest.execution == (try PluginExecutionDescriptor(pluginID:module.id,architecture:manifest.execution.architecture)) else {
            throw VideoError.permission("受限发行根仅允许game/schema6/7/8或cartoon/schema4/5/6/7/8的free/closed独立模块，不授付费、源码开放或其它能力")
        }
    }
    public static func pairDigest(manifest:PluginPackageManifest,policy:CommercialPolicy) throws -> String {
        try validateScope(manifest:manifest,policy:policy)
        return try Codec.digest(Pair(manifest:manifest,policy:policy))
    }
    public static func signingPayload(purpose:String,issuerKeySHA256:String,pairSHA256:String,payload:Data) throws -> Data {
        guard [manifestPurpose,policyPurpose].contains(purpose),
              issuerKeySHA256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              pairSHA256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              !payload.isEmpty,payload.count<=2*1024*1024 else {
            throw VideoError.permission("受限模块签名上下文、发行身份或载荷无效")
        }
        return try Codec.data(SigningBody(purpose:purpose,issuerKeySHA256:issuerKeySHA256,pairSHA256:pairSHA256,payload:payload))
    }

    /// Detection never authorizes a document. A partial/mixed restricted envelope
    /// is sent to the strict verifier, never retried as an ordinary signature.
    public static func usesRestrictedEnvelope(_ data:Data) throws -> Bool {
        guard !data.isEmpty,data.count<=2*1024*1024,
              let object=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else {
            throw VideoError.permission("模块签名须为有界PropertyList对象")
        }
        return !Set(object.keys).isDisjoint(with:envelopeFields.subtracting(["payload","signature"]))
    }
    public static func publicKey() throws -> Data {
        // Match the existing delivery trust: both actual public bytes and their
        // identity travel with the compiled verifier, including a clean installer.
        // A separately shipped .pub is a public receipt, never a caller key source.
        guard let expectedKeySHA256,let compiledPublicKey else {
            throw VideoError.unavailable("此构建尚未配置实际受限模块发行根；未接受新签名")
        }
        try validateKey(compiledPublicKey,expectedKeySHA256:expectedKeySHA256)
        return compiledPublicKey
    }
    static func validateKey(_ key:Data,expectedKeySHA256:String) throws {
        guard key.count==32,expectedKeySHA256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              Codec.hash(key)==expectedKeySHA256 else {throw VideoError.permission("受限模块公钥与本构建固定身份不同")}
    }
    public static func verify(manifest:Data,policy:Data) throws -> (PluginPackageManifest,CommercialPolicy) {
        guard let expectedKeySHA256 else {throw VideoError.unavailable("此构建尚未配置实际受限模块发行根；未接受新签名")}
        let key=try publicKey()
        return try verify(manifest:manifest,policy:policy,publicKey:key,expectedKeySHA256:expectedKeySHA256)
    }
    /// Pure crypto/semantic boundary; production always supplies the fixed resource
    /// and compiled identity above. It neither reads credentials nor grants a licence.
    static func verify(manifest:Data,policy:Data,publicKey:Data,expectedKeySHA256:String) throws -> (PluginPackageManifest,CommercialPolicy) {
        try validateKey(publicKey,expectedKeySHA256:expectedKeySHA256)
        func document(_ data:Data,purpose:String)throws->RestrictedFreeModuleDocument {
            guard try usesRestrictedEnvelope(data),
                  let object=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
                  Set(object.keys)==envelopeFields else {throw VideoError.permission("受限模块封套字段缺失、混用旧封套或含未知字段")}
            let value=try PropertyListDecoder().decode(RestrictedFreeModuleDocument.self,from:data)
            guard value.format==1,value.purpose==purpose,value.issuerKeySHA256==expectedKeySHA256,value.signature.count==64 else {
                throw VideoError.permission("受限模块封套用途、版本或发行身份不符")
            }
            let message=try signingPayload(purpose:value.purpose,issuerKeySHA256:value.issuerKeySHA256,pairSHA256:value.pairSHA256,payload:value.payload)
            let verifier=try Curve25519.Signing.PublicKey(rawRepresentation:publicKey)
            guard verifier.isValidSignature(value.signature,for:message) else {throw VideoError.permission("受限模块上下文签名无效")}
            return value
        }
        let manifestDocument=try document(manifest,purpose:manifestPurpose)
        let policyDocument=try document(policy,purpose:policyPurpose)
        let value=try Codec.decoder().decode(PluginPackageManifest.self,from:manifestDocument.payload)
        let policyValue=try Codec.decoder().decode(CommercialPolicy.self,from:policyDocument.payload)
        let digest=try pairDigest(manifest:value,policy:policyValue)
        guard manifestDocument.pairSHA256==digest,policyDocument.pairSHA256==digest else {
            throw VideoError.permission("受限manifest与policy不属于同一完整签发输入")
        }
        return(value,policyValue)
    }
}
