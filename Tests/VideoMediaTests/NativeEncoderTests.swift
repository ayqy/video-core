import XCTest
import Foundation
import AVFoundation
import VideoToolbox
import VideoCore
@testable import VideoMedia

final class NativeEncoderTests: XCTestCase {
    func testPreparedRealIdentityConstrainsWriterAndCacheKey() throws {
        #if os(macOS)
        let identifiers=try NativeEncoder.availableIdentifiers()
        XCTAssertEqual(identifiers,Array(Set(identifiers)).sorted())
        let scene=Scene(title:"真实编码实现",body:"同一画面，切换本机编码器。",durationFrames:15)
        let revision=try Planner.create(workspaceID:"w",name:"实现身份",aspect:.landscape,scenes:[scene])
        var keys=Set<String>()
        for identifier in identifiers {
            // A listed implementation can lack support for this output size/profile.
            // Only prepared, read-back-verified sessions count as supported here.
            guard let configuration=try? VisualClipCache.EncodingConfiguration.capture(aspect:revision.aspect,fps:revision.fps,selection:.identifier(identifier)) else{continue}
            let actual=try XCTUnwrap(configuration.encoderIdentity)
            XCTAssertEqual(actual.identifier,identifier)
            let settings=try XCTUnwrap(configuration.writerSettings[AVVideoEncoderSpecificationKey] as? [String:Any])
            XCTAssertEqual(settings[kVTVideoEncoderSpecification_EncoderID as String] as? String,actual.identifier)
            if let gpu=actual.gpuRegistryID {
                XCTAssertEqual((settings[kVTVideoEncoderSpecification_RequiredEncoderGPURegistryID as String] as? NSNumber)?.uint64Value,gpu)
            }
            let key=try VisualClipCache.fingerprint(revision:revision,index:0,database:Database(),modules:nil,encoding:configuration)
            XCTAssertTrue(keys.insert(key).inserted,"不同实际实现不得共用同一镜头缓存身份")
            XCTAssertEqual(key,try VisualClipCache.fingerprint(revision:revision,index:0,database:Database(),modules:nil,encoding:configuration))
        }
        guard !keys.isEmpty else{throw XCTSkip("本机没有可准备当前生产配置的H.264实现")}
        #endif
    }

    func testAutomaticIdentityIsPinnedOrPersistentReuseIsDisabled() throws {
        let configuration=try VisualClipCache.EncodingConfiguration.capture(aspect:.landscape,fps:30)
        #if os(macOS)
        if let identity=configuration.encoderIdentity {
            let settings=try XCTUnwrap(configuration.writerSettings[AVVideoEncoderSpecificationKey] as? [String:Any])
            XCTAssertEqual(settings[kVTVideoEncoderSpecification_EncoderID as String] as? String,identity.identifier)
        } else {XCTAssertFalse(configuration.canReusePersistentCache)}
        #else
        XCTAssertFalse(configuration.canReusePersistentCache)
        #endif
        let unidentified=VisualClipCache.EncodingConfiguration(aspect:.landscape,fps:30)
        XCTAssertNil(unidentified.encoderIdentity)
        XCTAssertFalse(unidentified.canReusePersistentCache,"无实际实现身份不能形成共享unknown缓存")
        // Isolated identity fixtures: absence must not be treated as known software.
        XCTAssertFalse(NativeEncoderIdentity(identifier:"fixture.encoder",hardwareAccelerated:nil,gpuRegistryID:nil,gpuIdentityResolved:false).canReusePersistentCache)
        XCTAssertFalse(NativeEncoderIdentity(identifier:"fixture.encoder",hardwareAccelerated:true,gpuRegistryID:nil,gpuIdentityResolved:false).canReusePersistentCache)
    }

    func testKnownBuiltinGPUResultIsDistinctFromAnUnavailableQuery() throws {
        // Isolated SDK-response fixtures; production values come from a prepared session.
        let builtIn=NativeEncoder.capturedIdentity(identifier:"fixture.encoder",hardwareStatus:noErr,hardware:kCFBooleanTrue,gpuStatus:noErr,gpu:nil)
        XCTAssertEqual(builtIn.hardwareAccelerated,true)
        XCTAssertNil(builtIn.gpuRegistryID)
        XCTAssertTrue(builtIn.gpuIdentityResolved)
        XCTAssertTrue(builtIn.canReusePersistentCache,"Successful NULL identifies a built-in/software binding; it does not mean unknown")
        XCTAssertNil(builtIn.specification[kVTVideoEncoderSpecification_RequiredEncoderGPURegistryID as String])
        let software=NativeEncoder.capturedIdentity(identifier:"fixture.software",hardwareStatus:kVTPropertyNotSupportedErr,hardware:nil,gpuStatus:noErr,gpu:nil)
        XCTAssertNil(software.hardwareAccelerated,"An unsupported query must not manufacture false")
        XCTAssertTrue(software.canReusePersistentCache)
        let unavailable=NativeEncoder.capturedIdentity(identifier:"fixture.encoder",hardwareStatus:noErr,hardware:kCFBooleanTrue,gpuStatus:kVTPropertyNotSupportedErr,gpu:nil)
        XCTAssertFalse(unavailable.gpuIdentityResolved)
        XCTAssertFalse(unavailable.canReusePersistentCache)
        XCTAssertNotEqual(try Codec.digest(builtIn),try Codec.digest(unavailable),"Known NULL and unknown cannot share a dependency identity")
        let invalidValues:[CFTypeRef]=[kCFBooleanTrue,NSNumber(value:0),NSNumber(value:-1),NSNumber(value:1.5),"bad" as CFString]
        for invalid in invalidValues {
            let malformed=NativeEncoder.capturedIdentity(identifier:"fixture.encoder",hardwareStatus:noErr,hardware:nil,gpuStatus:noErr,gpu:invalid)
            XCTAssertFalse(malformed.gpuIdentityResolved)
            XCTAssertFalse(malformed.canReusePersistentCache)
        }
        let external=NativeEncoder.capturedIdentity(identifier:"fixture.encoder",hardwareStatus:noErr,hardware:kCFBooleanTrue,gpuStatus:noErr,gpu:NSNumber(value:1234))
        XCTAssertTrue(external.canReusePersistentCache)
        XCTAssertEqual(external.gpuRegistryID,1234)
        XCTAssertEqual((external.specification[kVTVideoEncoderSpecification_RequiredEncoderGPURegistryID as String] as? NSNumber)?.uint64Value,1234)
        XCTAssertNotEqual(try Codec.digest(builtIn),try Codec.digest(external))
    }

    func testUnavailableExplicitImplementationDoesNotFallBack() throws {
        let absent="com.example.unavailable."+UUID().uuidString
        XCTAssertThrowsError(try NativeEncoder.resolve(.identifier(absent),width:1280,height:720,fps:30))
        XCTAssertThrowsError(try NativeEncoder.resolve(.identifier(""),width:1280,height:720,fps:30))
    }

    func testUnavailableSelectionDoesNotRemovePreviousOutput() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("video-encoder-selection-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root)
        let revision=try Planner.create(workspaceID:"w",name:"输出保护",aspect:.landscape,scenes:[Scene(title:"保留原结果",body:"显式编码器不可用时先拒绝。",durationFrames:15)])
        let output=root.appendingPathComponent("previous-output")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let video=output.appendingPathComponent("video.mp4"),original=Data("previous-output-sentinel".utf8)
        try original.write(to:video)
        do {
            _=try await MediaRenderer(videoEncoder:.identifier("com.example.unavailable."+UUID().uuidString)).render(revision:revision,repository:repository,output:output)
            XCTFail("显式不存在的实现不应回退后生成媒体")
        } catch {
            #if os(macOS)
            guard let failure=error as? VideoError,case .invalid(let message)=failure else{XCTFail("应在实际编码器选择校验处拒绝：\(error)");return}
            XCTAssertTrue(message.contains("H.264编码器"))
            #endif
            XCTAssertEqual(try Data(contentsOf:video),original)
        }
    }
}
