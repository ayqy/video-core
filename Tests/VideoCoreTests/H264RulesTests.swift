import XCTest
@testable import VideoCore

final class H264RulesTests: XCTestCase {
    func testActualCameraSPSReports422InsteadOfAssumingRequested420() throws {
        // Encoded camera parameter data used in the WebRTC project's SPS parser tests:
        // https://webrtc.googlesource.com/src/+/refs/heads/main/common_video/h264/sps_parser_unittest.cc
        // This codec configuration is data, not a port of WebRTC's parser implementation.
        let nal = Data([0x67, 0x7a, 0x00, 0x1f, 0xbc, 0xd9, 0x40, 0x50, 0x05, 0xba, 0x10, 0x00, 0x00, 0x03, 0x00, 0xc0, 0x00, 0x00, 0x2a, 0xe0, 0xf1, 0x83, 0x19, 0x60])
        let actual = try H264Rules.parseSPS(nal)
        XCTAssertEqual(actual.profileIDC, 122)
        XCTAssertEqual(actual.chromaFormatIDC, 2)
        XCTAssertEqual(actual.bitDepthLuma, 8); XCTAssertEqual(actual.bitDepthChroma, 8)
        XCTAssertEqual(actual.codedWidth, 1280); XCTAssertEqual(actual.codedHeight, 720)
        XCTAssertFalse(actual.is4208Bit)
    }
    func testBaselineAndHighProfilesExposeInferredVersusSignalledLayout() throws {
        let baseline = try H264Rules.parseSPS(Self.sps(profile: 66))
        XCTAssertTrue(baseline.is4208Bit)
        XCTAssertEqual(baseline.codedWidth, 720); XCTAssertEqual(baseline.codedHeight, 1280)
        let high = try H264Rules.parseSPS(Self.sps(profile: 100, chroma: 1, depth: 8))
        XCTAssertTrue(high.is4208Bit)
        let tenBit = try H264Rules.parseSPS(Self.sps(profile: 110, chroma: 1, depth: 10))
        XCTAssertFalse(tenBit.is4208Bit); XCTAssertEqual(tenBit.bitDepthLuma, 10)
        let fullChroma = try H264Rules.parseSPS(Self.sps(profile: 244, chroma: 3, depth: 8))
        XCTAssertFalse(fullChroma.is4208Bit); XCTAssertEqual(fullChroma.chromaFormatIDC, 3)
    }
    func testUnknownTruncatedAndUnboundedSPSNeverDefaultsToValidLayout() throws {
        XCTAssertThrowsError(try H264Rules.parseSPS(Self.sps(profile: 17)))
        XCTAssertThrowsError(try H264Rules.parseSPS(Data([0x68, 66, 0, 30, 0xff])))
        XCTAssertThrowsError(try H264Rules.parseSPS(Data([0xe7, 66, 0, 30, 0xff])))
        XCTAssertThrowsError(try H264Rules.parseSPS(Data([0x67, 66, 0, 30, 0, 0, 3])))
        var truncated = Self.sps(profile: 100); truncated.removeLast(2)
        XCTAssertThrowsError(try H264Rules.parseSPS(truncated))
        XCTAssertThrowsError(try H264Rules.parseSPS(Self.sps(profile: 100, chroma: 4)))
        XCTAssertThrowsError(try H264Rules.parseSPS(Self.sps(profile: 100, chroma: 1, depth: 15)))
    }
    private static func sps(profile: Int, chroma: Int = 1, depth: Int = 8) -> Data {
        var values: [Bool] = []
        func bit(_ value: Bool) { values.append(value) }
        func fixed(_ value: Int, _ count: Int) { for index in stride(from: count - 1, through: 0, by: -1) { bit(value & (1 << index) != 0) } }
        func ue(_ value: Int) { let code = value + 1, length = Int.bitWidth - code.leadingZeroBitCount; for _ in 0..<length - 1 { bit(false) }; fixed(code, length) }
        fixed(profile, 8); fixed(0, 8); fixed(31, 8); ue(0)
        if [100, 110, 244].contains(profile) {
            ue(chroma); if chroma == 3 { bit(false) }
            ue(max(0, depth - 8)); ue(max(0, depth - 8)); bit(false); bit(false)
        }
        ue(0); ue(0); ue(0); ue(1); bit(false)
        ue(44); ue(79); bit(true); bit(true); bit(false); bit(false)
        bit(true); while values.count % 8 != 0 { bit(false) }
        var payload: [UInt8] = []
        for offset in stride(from: 0, to: values.count, by: 8) { var byte: UInt8 = 0; for i in 0..<8 { byte = (byte << 1) | (values[offset + i] ? 1 : 0) }; payload.append(byte) }
        var encoded: [UInt8] = [0x67]; var zeros = 0
        for byte in payload {
            if zeros >= 2 && byte <= 3 { encoded.append(3); zeros = 0 }
            encoded.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data(encoded)
    }
}
