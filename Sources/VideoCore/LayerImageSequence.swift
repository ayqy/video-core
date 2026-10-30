import Foundation

/// A finite atlas animation on the authored scene-source axis. Each interval
/// selects actual pixels from the one image bound by SceneLayer.assetID.
public struct LayerImageSequenceFrame: Codable, Equatable, Sendable {
    public var startFrame: Int
    public var endFrame: Int
    public var sourceRect: MediaFraming

    public init(startFrame: Int, endFrame: Int, sourceRect: MediaFraming) {
        self.startFrame=startFrame; self.endFrame=endFrame; self.sourceRect=sourceRect
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case startFrame, endFrame, sourceRect }
    public init(from decoder: Decoder) throws {
        let raw=try decoder.container(keyedBy:LayerImageSequenceKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of:Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw VideoError.invalid("图片序列帧包含未知字段")
        }
        let c=try decoder.container(keyedBy:CodingKeys.self)
        startFrame=try c.decode(Int.self,forKey:.startFrame)
        endFrame=try c.decode(Int.self,forKey:.endFrame)
        sourceRect=try c.decode(MediaFraming.self,forKey:.sourceRect)
        try validate()
    }
    public func validate() throws {
        guard (0...53999).contains(startFrame),endFrame>startFrame,endFrame<=54000 else {
            throw VideoError.invalid("图片序列帧的源区间无效")
        }
        try sourceRect.validate()
    }
}

public struct LayerImageSequence: Codable, Equatable, Sendable {
    public var version=1
    public var frames: [LayerImageSequenceFrame]
    /// Nil authors an exact layer interval. A split retains the complete source
    /// sequence and explicitly selects a subwindow, even if it shows one pose.
    public var sourceOffsetFrames: Int?

    public init(frames: [LayerImageSequenceFrame], sourceOffsetFrames: Int?=nil) {
        self.frames=frames; self.sourceOffsetFrames=sourceOffsetFrames
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, frames, sourceOffsetFrames }
    public init(from decoder: Decoder) throws {
        let raw=try decoder.container(keyedBy:LayerImageSequenceKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of:Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw VideoError.invalid("图片序列包含当前版本不支持的字段")
        }
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version)
        frames=try c.decode([LayerImageSequenceFrame].self,forKey:.frames)
        sourceOffsetFrames=try c.decodeIfPresent(Int.self,forKey:.sourceOffsetFrames)
        try validateDomain()
    }
    private func validateDomain() throws {
        guard version==1,(2...512).contains(frames.count),(0...54000).contains(sourceOffsetFrames ?? 0) else {
            throw VideoError.invalid("图片序列版本、帧数或源窗口无效")
        }
        for (index,frame) in frames.enumerated() {
            try frame.validate()
            if index>0 {
                let previous=frames[index-1]
                guard frame.startFrame==previous.endFrame,frame.sourceRect != previous.sourceRect else {
                    throw VideoError.invalid("图片序列须连续无重叠，相邻帧必须选择不同源区域；同姿态请延长原区间")
                }
            }
        }
    }
    public func validate(kind: SceneLayer.Kind, startFrame: Int, endFrame: Int) throws {
        try validateDomain()
        let offset=sourceOffsetFrames ?? 0
        guard kind == .image,(0...53999).contains(startFrame),endFrame>startFrame,endFrame<=54000-offset,
              let first=frames.first,let last=frames.last else {
            throw VideoError.invalid("图片序列仅适用于有效图片图层和源窗口")
        }
        let firstVisible=offset+startFrame,lastVisible=offset+endFrame
        if sourceOffsetFrames==nil {
            guard first.startFrame==firstVisible,last.endFrame==lastVisible else {
                throw VideoError.invalid("图片序列须连续覆盖完整图层区间，不能在图层外隐藏帧")
            }
        } else {
            guard first.startFrame<=firstVisible,last.endFrame>=lastVisible else {
                throw VideoError.invalid("图片序列的裁切源窗口越界")
            }
        }
    }
    public func sourceRect(at sceneSourceFrame: Int) throws -> MediaFraming {
        try validateDomain()
        let offset=sourceOffsetFrames ?? 0
        guard (0...54000).contains(sceneSourceFrame),sceneSourceFrame<=54000-offset else {
            throw VideoError.invalid("图片序列采样帧超出源范围")
        }
        let frame=offset+sceneSourceFrame
        guard let pose=frames.first(where:{$0.startFrame<=frame && frame<$0.endFrame}) else {
            throw VideoError.invalid("图片序列采样帧不在已编排区间")
        }
        return pose.sourceRect
    }
    public func advancingSource(by frames: Int) throws -> Self {
        try validateDomain()
        let offset=sourceOffsetFrames ?? 0
        guard (0...54000).contains(frames),frames<=54000-offset else {
            throw VideoError.invalid("图片序列裁切偏移超出源范围")
        }
        var copy=self;copy.sourceOffsetFrames=offset+frames;return copy
    }
}

private struct LayerImageSequenceKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue=stringValue }
    init?(intValue: Int) { return nil }
}
