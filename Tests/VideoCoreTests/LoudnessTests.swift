import XCTest
@testable import VideoCore

final class LoudnessTests:XCTestCase {
    private func tone(seconds:Double=2,channels:Int=1,frequency:Double=997,amplitude:Double=0.1,opposite:Bool=false,fade:Bool=false)throws->LoudnessDiagnostics {
        var meter=try LoudnessMeter(channels:channels)
        let total=Int(seconds*48000)
        for start in stride(from:0,to:total,by:4096) {
            var chunk:[Float]=[]
            for frame in start..<min(total,start+4096) {
                let gain=fade ? min(1,min(Double(frame)/2400,Double(total-frame-1)/2400)):1
                let value=Float(amplitude*sin(2 * .pi * frequency*Double(frame)/48000)*gain)
                for channel in 0..<channels{chunk.append(opposite && channel==1 ? -value:value)}
            }
            try meter.append(chunk)
        }
        return try meter.finish()
    }
    func testNormative997HzCalibrationAndStereoChannelEnergy()throws {
        // BS.1770 Annex1: 0dBFS 997Hz mono is -3.01LKFS. -20dB amplitude => -23.01.
        let mono=try tone(),stereo=try tone(channels:2,opposite:true)
        XCTAssertEqual(try XCTUnwrap(mono.integratedLUFS),-23.01,accuracy:0.02)
        XCTAssertEqual(try XCTUnwrap(stereo.integratedLUFS),-20,accuracy:0.02)
        XCTAssertEqual(mono.totalBlocks,17);XCTAssertEqual(mono.gatedBlocks,17)
        XCTAssertEqual(try XCTUnwrap(mono.truePeakDBTP),-20,accuracy:0.03)
    }
    func testRelativeGateExcludesLowLevelProgrammeAndFindsActualLongSilence()throws {
        var meter=try LoudnessMeter(channels:1,policy:AudioQualityPolicy(silenceThresholdDBFS:-70,longSilenceSeconds:1))
        for second in 0..<8 {
            let amplitude=second<3 ? 0.1:(second<5 ? 0:0.001)
            try meter.append((0..<48000).map{Float(amplitude*sin(2 * .pi * 997*Double($0)/48000))})
        }
        let result=try meter.finish()
        XCTAssertEqual(try XCTUnwrap(result.integratedLUFS),-23.233,accuracy:0.02)
        XCTAssertEqual(result.totalBlocks,77);XCTAssertEqual(result.gatedBlocks,30)
        XCTAssertEqual(result.silenceRanges.count,1)
        XCTAssertEqual(result.silenceRanges[0].startSeconds,3,accuracy:1.0/48000)
        XCTAssertEqual(result.silenceRanges[0].endSeconds,5,accuracy:5.0/48000)
    }
    func testTruePeakDetectsIntersamplePeakAboveSamplePeak()throws {
        let measured=try tone(frequency:12000,amplitude:0.95,fade:true)
        // Quarter-rate sine is sampled 45 degrees out of phase to expose the ~3dB under-read.
        var meter=try LoudnessMeter(channels:1),samplePeak=0.0
        for start in stride(from:0,to:96000,by:4000) {
            var chunk:[Float]=[]
            for frame in start..<min(96000,start+4000) {
                let envelope=min(1,min(Double(frame)/2400,Double(95999-frame)/2400))
                let value=Float(0.95*sin(2 * .pi * 12000*Double(frame)/48000 + .pi/4)*envelope)
                samplePeak=max(samplePeak,abs(Double(value)));chunk.append(value)
            };try meter.append(chunk)
        }
        let result=try meter.finish()
        XCTAssertGreaterThan(try XCTUnwrap(result.truePeakDBTP),20*log10(samplePeak)+2.8)
        XCTAssertEqual(try XCTUnwrap(result.truePeakDBTP),20*log10(0.95),accuracy:0.1)
        XCTAssertNotNil(measured.integratedLUFS)
    }
    func testShortOrSilentTracksDoNotInventLoudnessOrFailOptionalTarget()throws {
        let short=try tone(seconds:0.2);XCTAssertNil(short.integratedLUFS);XCTAssertEqual(short.totalBlocks,0)
        XCTAssertTrue(short.violations(policy:.example).isEmpty)
        var silent=try LoudnessMeter(channels:1,policy:AudioQualityPolicy(longSilenceSeconds:0.2));try silent.append(Array(repeating:0,count:48000))
        let silence=try silent.finish();XCTAssertNil(silence.integratedLUFS);XCTAssertNil(silence.truePeakDBTP)
        XCTAssertEqual(silence.silenceRanges.count,1);XCTAssertTrue(silence.violations(policy:.example,audible:false).isEmpty)
    }
    func testChunkingDoesNotChangeMeasurementAndFinalTransientIsDrained()throws {
        let samples=(0..<48000).map{Float(0.1*sin(2 * .pi * 997*Double($0)/48000))}
        var full=try LoudnessMeter(channels:1),chunks=try LoudnessMeter(channels:1)
        try full.append(samples)
        for start in stride(from:0,to:samples.count,by:137){try chunks.append(Array(samples[start..<min(samples.count,start+137)]))}
        XCTAssertEqual(try full.finish(),try chunks.finish())
        var edge=try LoudnessMeter(channels:1);try edge.append(Array(repeating:0,count:47999)+[0.8])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(edge.finish().truePeakDBTP),20*log10(0.8)-0.0001)
    }
    func testPolicyIsVersionedRestorableAndInvalidatesReview()throws {
        let product=Product(workspaceID:"w",sku:"test",name:"test",checkout:"https://example.com",audience:"a",task:"t",outcome:"o",prerequisite:"p",scope:"s",prices:[Price(money:Money(1),source:"test")])
        let old=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"t",body:"b")],cta:"核对")
        let original=Project(workspaceID:"w",name:"test",revision:old)
        let updated=try Editor.apply([.audioQuality(.example)],to:original,baseRevision:old.id,assets:[],message:"修改目标")
        XCTAssertNotEqual(try old.contentDigest(),try updated.current.contentDigest());XCTAssertEqual(updated.current.audioQuality,.example)
        XCTAssertFalse(updated.current.review.complete)
        let restored=try Editor.apply([.restore(old.id)],to:updated,baseRevision:updated.current.id,assets:[],message:"恢复")
        XCTAssertNil(restored.current.audioQuality)
        var invalid=AudioQualityPolicy();invalid.targetLUFS = .nan
        XCTAssertThrowsError(try Editor.apply([.audioQuality(invalid)],to:original,baseRevision:old.id,assets:[],message:"无效"))
        XCTAssertThrowsError(try LoudnessMeter(sampleRate:44100,channels:1))
        XCTAssertThrowsError(try LoudnessMeter(channels:6))
    }
}
