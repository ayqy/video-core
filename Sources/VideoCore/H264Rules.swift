import Foundation

public struct H264SPSLayout: Codable, Equatable, Sendable {
    public var profileIDC: Int
    public var levelIDC: Int
    public var chromaFormatIDC: Int
    public var bitDepthLuma: Int
    public var bitDepthChroma: Int
    public var separateColourPlane: Bool
    public var codedWidth: Int
    public var codedHeight: Int
    public var frameMbsOnly: Bool
    public var is4208Bit: Bool { chromaFormatIDC == 1 && bitDepthLuma == 8 && bitDepthChroma == 8 && !separateColourPlane }
}

/// Reads SPS syntax from an AVC configuration NAL, not from encoder-requested settings.
/// H.264 (08/2024), 7.3.2.1.1/7.4.2.1.1: baseline/main/extended infer 4:2:0/8;
/// high profiles carry chroma_format_idc and bit_depth_*_minus8 explicitly.
/// This validates the bounded structural prefix through frame cropping; VUI fields are not
/// substituted for the actual CoreMedia format-description color metadata at the media boundary.
public enum H264Rules {
    public static func parseSPS(_ nal: Data) throws -> H264SPSLayout {
        guard (5...65536).contains(nal.count), let header = nal.first, header & 0x80 == 0, header & 0x1f == 7 else {
            throw VideoError.invalid("H.264 SPS NAL类型、长度或保留位不合法")
        }
        var rbsp: [UInt8] = [], zeros = 0
        let encoded = [UInt8](nal.dropFirst())
        var index = 0
        while index < encoded.count {
            let byte = encoded[index]
            if zeros >= 2 && byte == 3 {
                guard index + 1 < encoded.count, encoded[index + 1] <= 3 else { throw VideoError.invalid("H.264 SPS转义字节损坏") }
                zeros = 0; index += 1; continue
            }
            if zeros >= 2 && byte <= 2 { throw VideoError.invalid("H.264 SPS缺少必需的防竞争转义") }
            rbsp.append(byte); zeros = byte == 0 ? zeros + 1 : 0; index += 1
        }
        var bits = SPSBits(bytes: rbsp)
        let profile = try bits.read(8), constraints = try bits.read(8), level = try bits.read(8)
        guard constraints & 3 == 0 else { throw VideoError.unavailable("H.264 SPS使用未知约束保留位，不能声明已验证输出规格") }
        _ = try bits.ue(max: 31)
        var chroma = 1, luma = 8, chromaDepth = 8, separate = false
        let highProfiles: Set<Int> = [44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 244]
        if highProfiles.contains(profile) {
            chroma = try bits.ue(max: 3)
            if chroma == 3 { separate = try bits.flag() }
            luma = 8 + (try bits.ue(max: 6)); chromaDepth = 8 + (try bits.ue(max: 6))
            _ = try bits.flag() // qpprime_y_zero_transform_bypass_flag
            if try bits.flag() {
                for scaling in 0..<(chroma == 3 ? 12 : 8) {
                    if try bits.flag() {
                        var last = 8, next = 8
                        for _ in 0..<(scaling < 6 ? 16 : 64) {
                            if next != 0 { next = (last + (try bits.se(maxMagnitude: 128)) + 256) % 256 }
                            if next != 0 { last = next }
                        }
                    }
                }
            }
        } else {
            guard [66, 77, 88].contains(profile) else { throw VideoError.unavailable("H.264 SPS profile尚未支持，未推断默认色度/位深") }
        }
        _ = try bits.ue(max: 12) // log2_max_frame_num_minus4
        let orderType = try bits.ue(max: 2)
        if orderType == 0 { _ = try bits.ue(max: 12) }
        else if orderType == 1 {
            _ = try bits.flag(); _ = try bits.se(); _ = try bits.se()
            let cycle = try bits.ue(max: 255)
            for _ in 0..<cycle { _ = try bits.se() }
        }
        _ = try bits.ue(max: 1024); _ = try bits.flag() // reference frames and gaps
        let mbsWide = try bits.ue(max: 65535) + 1, mapUnitsHigh = try bits.ue(max: 65535) + 1
        let frameOnly = try bits.flag()
        if !frameOnly { _ = try bits.flag() }
        _ = try bits.flag() // direct_8x8_inference_flag
        var crop = [Int](repeating: 0, count: 4)
        if try bits.flag() { for i in crop.indices { crop[i] = try bits.ue(max: 65535) } }
        let vuiPresent = try bits.flag()
        guard !vuiPresent || bits.remaining > 0 else { throw VideoError.invalid("H.264 SPS的VUI声明被截断") }
        let arrayType = separate ? 0 : chroma
        let subWidth = arrayType == 1 || arrayType == 2 ? 2 : 1
        let subHeight = arrayType == 1 ? 2 : 1
        let cropX = arrayType == 0 ? 1 : subWidth
        let cropY = (arrayType == 0 ? 1 : subHeight) * (frameOnly ? 1 : 2)
        let width = mbsWide * 16 - (crop[0] + crop[1]) * cropX
        let height = (frameOnly ? 1 : 2) * mapUnitsHigh * 16 - (crop[2] + crop[3]) * cropY
        guard width > 0, height > 0 else { throw VideoError.invalid("H.264 SPS裁切后尺寸非正数") }
        return H264SPSLayout(profileIDC: profile, levelIDC: level, chromaFormatIDC: chroma, bitDepthLuma: luma, bitDepthChroma: chromaDepth, separateColourPlane: separate, codedWidth: width, codedHeight: height, frameMbsOnly: frameOnly)
    }
}

private struct SPSBits {
    let bytes: [UInt8]
    private var offset = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    var remaining: Int { bytes.count * 8 - offset }
    mutating func read(_ count: Int) throws -> Int {
        guard (0...31).contains(count), remaining >= count else { throw VideoError.invalid("H.264 SPS位流被截断") }
        var value = 0
        for _ in 0..<count { value = value << 1 | Int((bytes[offset / 8] >> UInt8(7 - offset % 8)) & 1); offset += 1 }
        return value
    }
    mutating func flag() throws -> Bool { try read(1) == 1 }
    mutating func ue(max maximum: Int = Int(Int32.max)) throws -> Int {
        var leading = 0
        while try read(1) == 0 { leading += 1; guard leading <= 30 else { throw VideoError.invalid("H.264 SPS Exp-Golomb过长") } }
        let value = (1 << leading) - 1 + (try read(leading))
        guard value <= maximum else { throw VideoError.invalid("H.264 SPS字段超出允许范围") }; return value
    }
    mutating func se(maxMagnitude: Int = Int(Int32.max) / 2) throws -> Int {
        let value = try ue(), magnitude = (value + 1) / 2
        guard magnitude <= maxMagnitude else { throw VideoError.invalid("H.264 SPS有符号字段超出允许范围") }
        return value % 2 == 0 ? -magnitude : magnitude
    }
}
