import Foundation
import VideoToolbox
import VideoCore

/// Select a real local H.264 implementation, for example when troubleshooting a
/// hardware encoder. The output delivery format remains H.264 High / 4:2:0.
public enum NativeEncoderSelection: Equatable, Sendable {
    case automatic
    case identifier(String)
}

/// A captured VideoToolbox identity, read from a prepared real compression session.
public struct NativeEncoderIdentity: Encodable, Equatable, Sendable {
    public let identifier: String
    public let hardwareAccelerated: Bool?
    public let gpuRegistryID: UInt64?
    /// A successful NULL GPU property is a documented built-in/software result,
    /// distinct from an unavailable property. Keep unknown hardware as unknown.
    public let gpuIdentityResolved: Bool

    var canReusePersistentCache: Bool {
        !identifier.isEmpty && gpuIdentityResolved && (gpuRegistryID.map { $0>0 } ?? true)
    }
    var specification: [String:Any] {
        var result: [String:Any] = [kVTVideoEncoderSpecification_EncoderID as String:identifier]
        if let gpuRegistryID { result[kVTVideoEncoderSpecification_RequiredEncoderGPURegistryID as String]=NSNumber(value:gpuRegistryID) }
        return result
    }
}

public enum NativeEncoder {
    /// GPU NULL has a specified meaning only when the property query succeeded.
    /// A malformed number or failed query must never create a shared unknown key.
    static func capturedIdentity(identifier:String,hardwareStatus:OSStatus,hardware:CFTypeRef?,gpuStatus:OSStatus,gpu:CFTypeRef?) -> NativeEncoderIdentity {
        let hardwareValue:Bool? = hardwareStatus==noErr && hardware.map { CFGetTypeID($0)==CFBooleanGetTypeID() }==true ? (hardware as? NSNumber)?.boolValue:nil
        var registry:UInt64?
        if gpuStatus==noErr,let gpu,CFGetTypeID(gpu)==CFNumberGetTypeID(),let number=gpu as? NSNumber {
            registry=UInt64(number.stringValue).flatMap { $0>0 ? $0:nil }
        }
        return NativeEncoderIdentity(identifier:identifier,hardwareAccelerated:hardwareValue,gpuRegistryID:registry,
            gpuIdentityResolved:gpuStatus==noErr && (gpu==nil || registry != nil))
    }
    /// Enumeration is discovery, not a claim that a listed encoder can create a
    /// session for every frame size/profile. resolve() performs that validation.
    public static func availableIdentifiers() throws -> [String] {
        var entries: CFArray?
        let status=VTCopyVideoEncoderList(nil,&entries)
        guard status==noErr,let entries=entries as? [[String:Any]] else {
            throw VideoError.unavailable("无法枚举本机H.264编码器（\(status)）")
        }
        return Set(entries.compactMap { entry -> String? in
            guard (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value==kCMVideoCodecType_H264 else{return nil}
            return entry[kVTVideoEncoderList_EncoderID as String] as? String
        }).sorted()
    }

    /// Unknown automatic identity keeps ordinary encoding available, but must not
    /// enter a shared persistent cache. An explicit unavailable identity never falls
    /// back to a different encoder.
    public static func resolve(_ selection:NativeEncoderSelection = .automatic,width:Int,height:Int,fps:Int,
                               averageBitRate:Int=2_500_000,allowsFrameReordering:Bool=false,
                               maximumKeyFrameInterval:Int?=nil,profileLevel:String=kVTProfileLevel_H264_High_AutoLevel as String) throws -> NativeEncoderIdentity? {
        #if os(macOS)
        do {
            guard width>0,height>0,width<=Int(Int32.max),height<=Int(Int32.max),(1...120).contains(fps),averageBitRate>0 else {
                throw VideoError.invalid("编码尺寸、帧率或码率无效")
            }
            var specification:CFDictionary?
            var requested:String?
            if case .identifier(let identifier)=selection {
                guard !identifier.isEmpty,identifier.utf8.count<=256,try availableIdentifiers().contains(identifier) else {
                    throw VideoError.invalid("指定的H.264编码器不在本机可用列表中，请先运行doctor查看真实实现")
                }
                requested=identifier
                specification=[kVTVideoEncoderSpecification_EncoderID as String:identifier] as CFDictionary
            }
            var value:VTCompressionSession?
            let creation=VTCompressionSessionCreate(allocator:nil,width:Int32(width),height:Int32(height),codecType:kCMVideoCodecType_H264,encoderSpecification:specification,imageBufferAttributes:nil,compressedDataAllocator:nil,outputCallback:nil,refcon:nil,compressionSessionOut:&value)
            guard creation==noErr,let session=value else {throw VideoError.unavailable("H.264编码器无法创建当前画幅会话（\(creation)）")}
            defer{VTCompressionSessionInvalidate(session)}
            let properties:[(CFString,CFTypeRef)]=[
                (kVTCompressionPropertyKey_ProfileLevel,profileLevel as CFString),
                (kVTCompressionPropertyKey_ExpectedFrameRate,NSNumber(value:fps)),
                (kVTCompressionPropertyKey_AverageBitRate,NSNumber(value:averageBitRate)),
                (kVTCompressionPropertyKey_AllowFrameReordering,NSNumber(value:allowsFrameReordering)),
                (kVTCompressionPropertyKey_MaxKeyFrameInterval,NSNumber(value:maximumKeyFrameInterval ?? fps*2))
            ]
            for (key,property) in properties {
                let status=VTSessionSetProperty(session,key:key,value:property)
                guard status==noErr else {throw VideoError.unavailable("H.264编码器不支持当前输出配置（\(status)）")}
            }
            let prepare=VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepare==noErr else {throw VideoError.unavailable("H.264编码器无法准备当前输出配置（\(prepare)）")}
            var actual:CFTypeRef?
            let read=VTSessionCopyProperty(session,key:kVTCompressionPropertyKey_EncoderID,allocator:nil,valueOut:&actual)
            guard read==noErr,let identifier=actual as? String,!identifier.isEmpty,
                  requested==nil || requested==identifier else {throw VideoError.unavailable("H.264编码器实际身份无法确认，拒绝替换指定实现")}
            var hardware:CFTypeRef?,gpu:CFTypeRef?
            let hardwareRead=VTSessionCopyProperty(session,key:kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,allocator:nil,valueOut:&hardware)
            let gpuRead=VTSessionCopyProperty(session,key:kVTCompressionPropertyKey_UsingGPURegistryID,allocator:nil,valueOut:&gpu)
            return capturedIdentity(identifier:identifier,hardwareStatus:hardwareRead,hardware:hardware,gpuStatus:gpuRead,gpu:gpu)
        } catch {
            if case .automatic=selection {return nil}
            throw error
        }
        #else
        // AVVideoEncoderSpecificationKey is a macOS writer setting. Keep other
        // platforms' ordinary writer, without pretending its implementation is pinned.
        if case .identifier=selection {throw VideoError.unavailable("当前平台不支持显式选择本地H.264编码器")}
        return nil
        #endif
    }
}
