import Foundation

public struct AudioQualityPolicy:Codable,Equatable,Sendable {
    public var targetLUFS:Double?;public var toleranceLU:Double
    public var maximumTruePeakDBTP:Double?;public var silenceThresholdDBFS:Double
    public var longSilenceSeconds:Double;public var rejectLongSilence:Bool
    public init(targetLUFS:Double?=nil,toleranceLU:Double=1,maximumTruePeakDBTP:Double?=nil,silenceThresholdDBFS:Double = -55,longSilenceSeconds:Double=2,rejectLongSilence:Bool=false) {
        self.targetLUFS=targetLUFS;self.toleranceLU=toleranceLU;self.maximumTruePeakDBTP=maximumTruePeakDBTP;self.silenceThresholdDBFS=silenceThresholdDBFS;self.longSilenceSeconds=longSilenceSeconds;self.rejectLongSilence=rejectLongSilence
    }
    /// A user-selectable design example, not a platform requirement or EBU broadcast target.
    public static let example=AudioQualityPolicy(targetLUFS:-16,maximumTruePeakDBTP:-1)
    public func validate()throws {
        guard targetLUFS.map({$0.isFinite && (-70 ... -5).contains($0)}) ?? true,
              maximumTruePeakDBTP.map({$0.isFinite && (-12...0).contains($0)}) ?? true,
              toleranceLU.isFinite,(0.1...10).contains(toleranceLU),silenceThresholdDBFS.isFinite,(-100 ... -20).contains(silenceThresholdDBFS),longSilenceSeconds.isFinite,(0.1...60).contains(longSilenceSeconds) else{throw VideoError.invalid("响度、真峰值或静音检查策略超出支持范围")}
    }
}
public struct AudioSilenceRange:Codable,Equatable,Sendable {
    public var startSeconds:Double;public var endSeconds:Double
    public var duration:Double{endSeconds-startSeconds}
}
public struct LoudnessDiagnostics:Codable,Equatable,Sendable {
    public var integratedLUFS:Double?;public var truePeakDBTP:Double?
    public var gatedBlocks:Int;public var totalBlocks:Int;public var unavailableReason:String?
    public var silenceRanges:[AudioSilenceRange];public var analysisPolicy:AudioQualityPolicy
    public var method:String{"ITU-R BS.1770-5 Annex1/2;48kHz;mono/stereo;400ms/100ms;-70LUFS/-10LU;4x48tapFIR"}
    public func violations(policy:AudioQualityPolicy,audible:Bool=true)->[String] {
        var result:[String]=[]
        // Silence and <400ms recordings have no valid integrated result; never invent a failed LUFS value.
        if audible,let target=policy.targetLUFS,let value=integratedLUFS,abs(value-target)>policy.toleranceLU {result.append(String(format:"综合响度 %.2f LUFS 超出自定目标 %.2f±%.2f LU",value,target,policy.toleranceLU))}
        if let ceiling=policy.maximumTruePeakDBTP,let value=truePeakDBTP,value>ceiling {result.append(String(format:"真峰值 %.2f dBTP 高于自定上限 %.2f dBTP",value,ceiling))}
        if audible,policy.rejectLongSilence,!silenceRanges.isEmpty {result.append("检测到超过自定时长的静音区间，请核对是否为有意停顿")}
        return result
    }
}

/// Original Swift implementation of the published ITU-R BS.1770-5 equations and Annex2 coefficients.
/// https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/
/// Only mono/stereo at 48kHz: callers must resample or explicitly reject unsupported layouts.
/// Storage is a 400ms energy ring, 12 samples/channel and <=35997 scalar gating blocks/hour.
public struct LoudnessMeter:Sendable {
    private struct Filter:Sendable {
        var b0:Double;var b1:Double;var b2:Double;var a1:Double;var a2:Double
        var z1=0.0,z2=0.0
        mutating func apply(_ x:Double)->Double {let y=b0*x+z1;z1=b1*x-a1*y+z2;z2=b2*x-a2*y;return y}
    }
    // Normative 48kHz K-weighting filters (Annex1 Tables1,2).
    private var shelf:[Filter];private var highPass:[Filter]
    // Annex2 four polyphase branches, each 12 taps. Float arithmetic needs no 12.04dB headroom shift.
    private static let taps:[[Double]]=[
        [0.001708984375,0.010986328125,-0.0196533203125,0.033203125,-0.0594482421875,0.1373291015625,0.97216796875,-0.102294921875,0.047607421875,-0.026611328125,0.014892578125,-0.00830078125],
        [-0.0291748046875,0.029296875,-0.0517578125,0.089111328125,-0.16650390625,0.465087890625,0.77978515625,-0.2003173828125,0.1015625,-0.0582275390625,0.0330810546875,-0.0189208984375],
        [-0.0189208984375,0.0330810546875,-0.0582275390625,0.1015625,-0.2003173828125,0.77978515625,0.465087890625,-0.16650390625,0.089111328125,-0.0517578125,0.029296875,-0.0291748046875],
        [-0.00830078125,0.014892578125,-0.026611328125,0.047607421875,-0.102294921875,0.97216796875,0.1373291015625,-0.0594482421875,0.033203125,-0.0196533203125,0.010986328125,0.001708984375]
    ]
    private let channels:Int;private let policy:AudioQualityPolicy;private let silenceAmplitude:Double
    private var energy=[Double](repeating:0,count:19200),energyIndex=0,energySum=0.0
    private var blocks:[Double]=[],frames:Int64=0,history:[Double],historyIndex=0,peak=0.0
    private var silenceStart:Int64?;private var ranges:[AudioSilenceRange]=[]
    private var finished=false
    public init(sampleRate:Double=48000,channels:Int,policy:AudioQualityPolicy = .init())throws {
        try policy.validate()
        guard sampleRate==48000,(1...2).contains(channels) else{throw VideoError.unavailable("BS.1770检查须为48kHz单/双声道；不会猜测环绕声/LFE布局")}
        self.channels=channels;self.policy=policy;silenceAmplitude=pow(10,policy.silenceThresholdDBFS/20)
        shelf=Array(repeating:Filter(b0:1.53512485958697,b1:-2.69169618940638,b2:1.19839281085285,a1:-1.69065929318241,a2:0.73248077421585),count:channels)
        highPass=Array(repeating:Filter(b0:1,b1:-2,b2:1,a1:-1.99004745483398,a2:0.99007225036621),count:channels)
        history=Array(repeating:0,count:channels*24)
    }
    private mutating func truePeak(_ value:Double,channel:Int) {
        let base=channel*24;history[base+historyIndex]=value;history[base+historyIndex+12]=value
        peak=max(peak,abs(value))
        for phase in Self.taps {
            var sum=0.0
            for tap in 0..<12 {sum += phase[tap]*history[base+historyIndex+12-tap]}
            peak=max(peak,abs(sum))
        }
    }
    public mutating func append(_ interleaved:[Float])throws {
        guard !finished,interleaved.count%channels==0,frames+Int64(interleaved.count/channels)<=48000*3600 else{throw VideoError.invalid("响度输入不完整、已结束或超过一小时")}
        for offset in stride(from:0,to:interleaved.count,by:channels) {
            var weightedEnergy=0.0,audible=false
            for channel in 0..<channels {
                let value=Double(interleaved[offset+channel]);guard value.isFinite else{throw VideoError.invalid("响度输入包含非有限采样")}
                audible = audible || abs(value)>=silenceAmplitude
                let weighted=highPass[channel].apply(shelf[channel].apply(value));weightedEnergy += weighted*weighted
                truePeak(value,channel:channel)
            }
            historyIndex=(historyIndex+1)%12
            energySum += weightedEnergy-energy[energyIndex];energy[energyIndex]=weightedEnergy;energyIndex=(energyIndex+1)%19200
            if audible {if let start=silenceStart{recordSilence(from:start,to:frames);silenceStart=nil}}
            else if silenceStart==nil{silenceStart=frames}
            frames += 1
            if frames>=19200,(frames-19200)%4800==0 {blocks.append(max(0,energySum)/19200)}
        }
    }
    private mutating func recordSilence(from:Int64,to:Int64) {
        if Double(to-from)/48000>=policy.longSilenceSeconds {ranges.append(AudioSilenceRange(startSeconds:Double(from)/48000,endSeconds:Double(to)/48000))}
    }
    public mutating func finish()throws->LoudnessDiagnostics {
        guard !finished,frames>0 else{throw VideoError.invalid("响度检查没有真实采样或已结束")};finished=true
        if let start=silenceStart{recordSilence(from:start,to:frames)}
        // Drain FIR latency so a final transient is not lost. These zeros never become loudness/silence input.
        for _ in 0..<11 {for channel in 0..<channels{truePeak(0,channel:channel)};historyIndex=(historyIndex+1)%12}
        let absolute=pow(10,(-70+0.691)/10),first=blocks.filter{$0>absolute}
        let mean=first.isEmpty ? 0:first.reduce(0,+)/Double(first.count)
        let gated=first.filter{$0>mean/10}
        let integrated=gated.isEmpty ? nil:Optional(-0.691+10*log10(gated.reduce(0,+)/Double(gated.count)))
        return LoudnessDiagnostics(integratedLUFS:integrated,truePeakDBTP:peak>0 ? 20*log10(peak):nil,gatedBlocks:gated.count,totalBlocks:blocks.count,unavailableReason:blocks.isEmpty ? "不足400毫秒完整测量块":(gated.isEmpty ? "所有完整测量块低于-70 LUFS绝对门限":nil),silenceRanges:ranges,analysisPolicy:policy)
    }
}
