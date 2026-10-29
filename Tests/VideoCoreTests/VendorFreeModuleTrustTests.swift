import XCTest
import CryptoKit
@testable import VideoCore

/// Ephemeral identities only exercise the internal pure verifier. They never
/// configure the production resource, compiled pin or native package gate.
final class VendorFreeModuleTrustTests: XCTestCase {
    private let now=Date(timeIntervalSince1970:1_790_000_000)
    private struct Pair:Encodable {let manifest:PluginPackageManifest;let policy:CommercialPolicy}
    private func values(id:String="video.game",architecture:String="x86_64")throws->(PluginPackageManifest,CommercialPolicy) {
        let capabilities=try XCTUnwrap(PluginPackageRules.capabilities[id])
        let schema=id == "video.game" ? 6:4
        let module=PluginManifest(id:id,version:"1.3.0",capabilities:[capabilities],inputSchema:schema,implementationDigest:String(repeating:"a",count:64),permissions:[])
        let executables=try PluginPackageRules.executablePaths(pluginID:id)
        let files=try PluginPackageRules.requiredPaths(pluginID:id).sorted().map {ManagedReleaseFile(path:$0,sha256:String(repeating:"b",count:64),bytes:1,executable:executables.contains($0))}
        return(PluginPackageManifest(module:module,execution:try PluginExecutionDescriptor(pluginID:id,architecture:architecture),files:files),CommercialPolicy(pluginID:id,version:7,access:"free",updatedAt:now))
    }
    private func encode<T:Encodable>(_ value:T,format:PropertyListSerialization.PropertyListFormat = .binary)throws->Data {
        let encoder=PropertyListEncoder();encoder.outputFormat=format;return try encoder.encode(value)
    }
    private func document(payload:Data,purpose:String,key:Curve25519.Signing.PrivateKey,pair:String,issuer:String?=nil)throws->RestrictedFreeModuleDocument {
        let identity=issuer ?? Codec.hash(key.publicKey.rawRepresentation)
        let message=try VendorFreeModuleTrust.signingPayload(purpose:purpose,issuerKeySHA256:identity,pairSHA256:pair,payload:payload)
        return RestrictedFreeModuleDocument(purpose:purpose,issuerKeySHA256:identity,pairSHA256:pair,payload:payload,signature:try key.signature(for:message))
    }
    private func pair(_ manifest:PluginPackageManifest,_ policy:CommercialPolicy,key:Curve25519.Signing.PrivateKey,format:PropertyListSerialization.PropertyListFormat = .binary)throws->(Data,Data) {
        // Deliberately allow adversarial semantics to be signed in tests; the
        // production issuer and verifier both independently enforce their scope.
        let digest=try Codec.digest(Pair(manifest:manifest,policy:policy))
        return(try encode(document(payload:Codec.data(manifest),purpose:VendorFreeModuleTrust.manifestPurpose,key:key,pair:digest),format:format),try encode(document(payload:Codec.data(policy),purpose:VendorFreeModuleTrust.policyPurpose,key:key,pair:digest),format:format))
    }
    private func verify(_ pair:(Data,Data),key:Curve25519.Signing.PrivateKey)throws->(PluginPackageManifest,CommercialPolicy) {
        try VendorFreeModuleTrust.verify(manifest:pair.0,policy:pair.1,publicKey:key.publicKey.rawRepresentation,expectedKeySHA256:Codec.hash(key.publicKey.rawRepresentation))
    }
    private func mutate(_ data:Data,_ change:(inout [String:Any])->Void)throws->Data {
        var object=try XCTUnwrap(PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any]);change(&object)
        return try PropertyListSerialization.data(fromPropertyList:object,format:.binary,options:0)
    }
    func testCompleteFreeClosedPairPassesForOnlyCurrentModuleSchemasAndBothArchitectures()throws {
        let key=Curve25519.Signing.PrivateKey()
        for id in ["video.game","video.cartoon"] {for architecture in ["arm64","x86_64"] {for schema in (id == "video.game" ? [6,7]:[4,5]) {
            var (manifest,policy)=try values(id:id,architecture:architecture);manifest.module.inputSchema=schema
            let documents=try pair(manifest,policy,key:key)
            let verified=try verify(documents,key:key)
            XCTAssertEqual(verified.0.module,manifest.module);XCTAssertEqual(verified.1.access,"free")
            XCTAssertEqual(try VendorFreeModuleTrust.pairDigest(manifest:manifest,policy:policy),try Codec.digest(Pair(manifest:manifest,policy:policy)))
            XCTAssertNoThrow(try PluginPackageRules.validate(verified.0,policy:verified.1,architecture:architecture,osMajor:14,now:now))
        }}}
    }
    func testRestrictedAndOriginalSignedEnvelopesKeepXMLAndBinaryCompatibility()throws {
        let key=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values()
        for format in [PropertyListSerialization.PropertyListFormat.xml,.binary] {
            let documents=try pair(manifest,policy,key:key,format:format)
            XCTAssertTrue(try VendorFreeModuleTrust.usesRestrictedEnvelope(documents.0));XCTAssertNoThrow(try verify(documents,key:key))
            let payload=try Codec.data(policy),legacy=SignedDocument(payload:payload,signature:try key.signature(for:payload))
            let bytes=try encode(legacy,format:format)
            XCTAssertFalse(try VendorFreeModuleTrust.usesRestrictedEnvelope(bytes))
            XCTAssertEqual(try PropertyListDecoder().decode(SignedDocument.self,from:bytes).verified(as:CommercialPolicy.self,publicKey:key.publicKey.rawRepresentation).version,policy.version)
        }
    }
    func testEveryContextFieldAndPayloadAreAuthenticated()throws {
        let key=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values(),documents=try pair(manifest,policy,key:key)
        for field in ["format","purpose","issuerKeySHA256","pairSHA256","payload","signature"] {
            let changed=try mutate(documents.0) {object in
                switch field {
                case "format":object[field]=2
                case "purpose":object[field]=VendorFreeModuleTrust.policyPurpose
                case "issuerKeySHA256","pairSHA256":object[field]=String(repeating:"f",count:64)
                default:object[field]=Data(repeating:0,count:64)
                }
            }
            XCTAssertThrowsError(try verify((changed,documents.1),key:key),field)
        }
    }
    func testUnknownMissingPartialAndMixedEnvelopeFieldsFailClosed()throws {
        let key=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values(),documents=try pair(manifest,policy,key:key)
        for field in ["format","purpose","issuerKeySHA256","pairSHA256","payload","signature"] {
            let bytes=try mutate(documents.0) {$0.removeValue(forKey:field)}
            XCTAssertThrowsError(try verify((bytes,documents.1),key:key),field)
        }
        XCTAssertThrowsError(try verify((mutate(documents.0){$0["unknown"]="extension"},documents.1),key:key))
        let partial=try mutate(documents.0) {$0.removeValue(forKey:"purpose");$0.removeValue(forKey:"pairSHA256")}
        XCTAssertTrue(try VendorFreeModuleTrust.usesRestrictedEnvelope(partial))
        XCTAssertThrowsError(try verify((partial,documents.1),key:key))
    }
    func testPurposeCannotBeExchangedBetweenManifestAndPolicy()throws {
        let key=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values(),documents=try pair(manifest,policy,key:key)
        XCTAssertThrowsError(try verify((documents.1,documents.0),key:key))
        let digest=try VendorFreeModuleTrust.pairDigest(manifest:manifest,policy:policy)
        let swapped=try encode(document(payload:Codec.data(manifest),purpose:VendorFreeModuleTrust.policyPurpose,key:key,pair:digest))
        XCTAssertThrowsError(try verify((swapped,documents.1),key:key))
    }
    func testMixedPairsAndDifferentIssuersCannotBeSpliced()throws {
        let key=Curve25519.Signing.PrivateKey(),other=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values(),documents=try pair(manifest,policy,key:key)
        var newer=policy;newer.version+=1
        let otherPair=try pair(manifest,newer,key:key),otherIssuer=try pair(manifest,policy,key:other)
        XCTAssertThrowsError(try verify((documents.0,otherPair.1),key:key))
        XCTAssertThrowsError(try verify((documents.0,otherIssuer.1),key:key))
        XCTAssertThrowsError(try verify((otherIssuer.0,documents.1),key:key))
    }
    func testCorrectlySignedButFalsePairDigestCannotAuthorizeEitherDocument()throws {
        let key=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values(),digest=String(repeating:"f",count:64)
        let first=try encode(document(payload:Codec.data(manifest),purpose:VendorFreeModuleTrust.manifestPurpose,key:key,pair:digest))
        let second=try encode(document(payload:Codec.data(policy),purpose:VendorFreeModuleTrust.policyPurpose,key:key,pair:digest))
        XCTAssertThrowsError(try verify((first,second),key:key))
    }
    func testArbitrarySelfSignedKeyAndLegacyNewRootMixAreRejected()throws {
        let key=Curve25519.Signing.PrivateKey(),unknown=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values(),documents=try pair(manifest,policy,key:unknown)
        XCTAssertThrowsError(try VendorFreeModuleTrust.verify(manifest:documents.0,policy:documents.1,publicKey:unknown.publicKey.rawRepresentation,expectedKeySHA256:Codec.hash(key.publicKey.rawRepresentation)))
        XCTAssertThrowsError(try verify(documents,key:key))
        let data=try Codec.data(policy),legacy=try encode(SignedDocument(payload:data,signature:try key.signature(for:data)))
        let trustedPair=try pair(manifest,policy,key:key)
        XCTAssertThrowsError(try verify((trustedPair.0,legacy),key:key))
        XCTAssertThrowsError(try verify((legacy,trustedPair.1),key:key))
    }
    func testPaidDisabledOpenAndUnrelatedModulesAreRejectedEvenWithValidContextSignatures()throws {
        let key=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values()
        for access in ["paid","disabled","unknown"] {var changed=policy;changed.access=access;XCTAssertThrowsError(try verify(pair(manifest,changed,key:key),key:key))}
        var open=manifest;open.module.sourceVisibility="open";var openPolicy=policy;openPolicy.sourceVisibility="open"
        XCTAssertThrowsError(try verify(pair(open,openPolicy,key:key),key:key))
        var unknown=manifest;unknown.module.id="video.editor";var unknownPolicy=policy;unknownPolicy.pluginID=unknown.module.id
        XCTAssertThrowsError(try verify(pair(unknown,unknownPolicy,key:key),key:key))
        var mismatched=policy;mismatched.pluginID="video.cartoon"
        XCTAssertThrowsError(try verify(pair(manifest,mismatched,key:key),key:key))
    }
    func testWrongSchemaABIPermissionsOutputAndExecutionCannotExtendAuthority()throws {
        let key=Curve25519.Signing.PrivateKey()
        for id in ["video.game","video.cartoon"] {
            let (manifest,policy)=try values(id:id)
            for index in 0..<11 {
                var changed=manifest
                switch index {
                case 0:changed.module.inputSchema=1
                case 1:changed.module.abi=2
                case 2:changed.module.minimumCore=0
                case 3:changed.module.outputSchema=2
                case 4:changed.module.permissions=["network"]
                case 5:changed.module.capabilities.append("editor.export")
                case 6:changed.execution.entrypoint="/bin/sh"
                case 7:changed.execution.serviceName="unapproved"
                case 8:changed.execution.minimumOSMajor=13
                case 9:changed.format=2
                default:changed.policyRef="../policy"
                }
                XCTAssertThrowsError(try verify(pair(changed,policy,key:key),key:key),"\(id) mutation \(index)")
            }
        }
    }
    func testSignaturesCannotBecomeLegacyPoliciesOrInstallationDocuments()throws {
        let key=Curve25519.Signing.PrivateKey(),(manifest,policy)=try values(),documents=try pair(manifest,policy,key:key)
        let restricted=try PropertyListDecoder().decode(RestrictedFreeModuleDocument.self,from:documents.0)
        let downgraded=SignedDocument(payload:restricted.payload,signature:restricted.signature)
        XCTAssertThrowsError(try downgraded.verified(as:PluginPackageManifest.self,publicKey:key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try downgraded.verified(as:CommercialPolicy.self,publicKey:key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try downgraded.verified(as:ManagedReleaseManifest.self,publicKey:key.publicKey.rawRepresentation))
        for purpose in ["license","revocation","install",""] {
            XCTAssertThrowsError(try VendorFreeModuleTrust.signingPayload(purpose:purpose,issuerKeySHA256:Codec.hash(key.publicKey.rawRepresentation),pairSHA256:String(repeating:"a",count:64),payload:Data("not-authorized".utf8)))
        }
        let payload=try Codec.data(policy),context=try encode(document(payload:payload,purpose:VendorFreeModuleTrust.manifestPurpose,key:key,pair:String(repeating:"a",count:64)))
        XCTAssertThrowsError(try verify((context,documents.1),key:key))
    }
    func testNewFreePairPreservesPolicyHighWaterAndSameVersionPaidSemantics()throws {
        let key=Curve25519.Signing.PrivateKey(),(manifest,free)=try values()
        var paid=free;paid.access="paid"
        let paidHistory=try ModulePolicyHistory().observing([paid],now:now)
        let verified=try verify(pair(manifest,free,key:key),key:key)
        XCTAssertThrowsError(try paidHistory.observing([verified.1],now:now))
        XCTAssertThrowsError(try PluginPackageRules.validate(verified.0,policy:verified.1,architecture:"x86_64",osMajor:14,minimumPolicyVersion:free.version+1,now:now))
        var newer=free;newer.version+=1
        let next=try verify(pair(manifest,newer,key:key),key:key)
        let history=try paidHistory.observing([next.1],now:now)
        XCTAssertEqual(history.versions[manifest.module.id],newer.version)
        XCTAssertThrowsError(try history.observing([paid],now:now))
        let restored=try ModulePolicyHistory.decode(history.encoded())
        XCTAssertEqual(restored,history);XCTAssertThrowsError(try restored.observing([verified.1],now:now))
    }
    func testMalformedOversizeAndNonDictionaryInputsNeverFallBack()throws {
        for data in [Data(),Data("corrupt".utf8),Data(repeating:0,count:2*1024*1024+1),try encode(["array"])] {
            XCTAssertThrowsError(try VendorFreeModuleTrust.usesRestrictedEnvelope(data))
        }
        let key=Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try VendorFreeModuleTrust.validateKey(key.publicKey.rawRepresentation,expectedKeySHA256:"invalid"))
        XCTAssertThrowsError(try VendorFreeModuleTrust.validateKey(Data(repeating:1,count:31),expectedKeySHA256:Codec.hash(key.publicKey.rawRepresentation)))
        XCTAssertThrowsError(try VendorFreeModuleTrust.signingPayload(purpose:VendorFreeModuleTrust.manifestPurpose,issuerKeySHA256:Codec.hash(key.publicKey.rawRepresentation),pairSHA256:String(repeating:"A",count:64),payload:Data([1])))
    }
    func testOptionalNewPublicResourceDoesNotAlterOriginalManagedLayouts()throws {
        let required=ManagedPayloadRules.requiredPaths(for:.advancedCLI,format:2),executables=ManagedPayloadRules.executablePaths(for:.advancedCLI,format:2)
        let original=required.sorted().map {ManagedReleaseFile(path:$0,sha256:String(repeating:"a",count:64),bytes:$0 == "publisher.pub" ? 32:1,executable:executables.contains($0))}
        let resource=ManagedReleaseFile(path:VendorFreeModuleTrust.resourceName,sha256:String(repeating:"b",count:64),bytes:32,executable:false)
        XCTAssertNoThrow(try ManagedPayloadRules.validate(original,product:.advancedCLI,format:2))
        XCTAssertNoThrow(try ManagedPayloadRules.validate(original+[resource],product:.advancedCLI,format:2))
        XCTAssertThrowsError(try ManagedPayloadRules.validate(original+[resource],product:.advancedCLI,format:1))
        XCTAssertThrowsError(try ManagedPayloadRules.validate(original+[resource],product:.coreCLI))
        var malformed=resource;malformed.bytes=31
        XCTAssertThrowsError(try ManagedPayloadRules.validate(original+[malformed],product:.advancedCLI,format:2))
    }
}
