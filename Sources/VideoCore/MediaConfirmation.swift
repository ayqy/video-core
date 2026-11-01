import Foundation
import CryptoKit
import Darwin

/// Explicit caller declarations, separate from render content and whole-film
/// review. Reusing approval of a source never approves its captions or the mix.
public enum MediaConfirmationMethod: String, Codable, Sendable {
    case manual
    case approvedOriginal = "approved_original"
    case reliableTimestamps = "reliable_timestamps"
}

public struct MediaVoiceBinding: Codable, Equatable, Sendable {
    public var assetID: String
    public var sha256: String
    public var textDigest: String
    public var durationFrames: Int
    public var method: String
    public init(assetID:String,sha256:String,textDigest:String,durationFrames:Int,method:String) {
        self.assetID=assetID;self.sha256=sha256;self.textDigest=textDigest
        self.durationFrames=durationFrames;self.method=method
    }
}

public struct MediaConfirmationBinding: Codable, Equatable, Sendable {
    public var contentDigest: String
    public var voice: MediaVoiceBinding?
    public var captionsDigest: String
    public init(contentDigest:String,voice:MediaVoiceBinding?,captionsDigest:String) {
        self.contentDigest=contentDigest;self.voice=voice;self.captionsDigest=captionsDigest
    }
}

public struct MediaConfirmationRequest: Codable, Equatable, Sendable {
    public var voice: Bool
    public var captions: Bool
    public var method: MediaConfirmationMethod
    public var statement: String
    public var expected: MediaConfirmationBinding
    public init(voice:Bool,captions:Bool,method:MediaConfirmationMethod,statement:String,expected:MediaConfirmationBinding) {
        self.voice=voice;self.captions=captions;self.method=method;self.statement=statement;self.expected=expected
    }
    public func validate() throws {
        guard voice || captions,!statement.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              statement.utf16.count<=4000,
              [expected.contentDigest,expected.captionsDigest].allSatisfy({$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}) else {throw VideoError.invalid("请明确选择实际确认的声音或字幕，并填写确认依据和精确输入摘要")}
        if let take=expected.voice {
            guard !take.assetID.isEmpty,take.assetID.utf8.count<=200,!take.method.isEmpty,take.method.utf8.count<=400,
                  take.durationFrames>0,[take.sha256,take.textDigest].allSatisfy({$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}) else {
                throw VideoError.invalid("原音冻结事实缺少完整标识、时长、来源方法或摘要")
            }
        }
        guard !voice || expected.voice != nil else {throw VideoError.invalid("声音确认必须冻结其完整原音事实")}
        if method == .approvedOriginal {
            guard voice && !captions else {throw VideoError.review("原音批准只确认绑定的完整原录音，不确认字幕或整片看听")}
        }
        if method == .reliableTimestamps {
            guard captions && !voice else {throw VideoError.review("可靠时间戳声明只能确认字幕时轴，不能代替声音试听")}
        }
    }
}

public struct MediaConfirmation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var workspaceID: String
    public var projectID: String
    public var revisionID: String
    public var sceneID: String
    public var binding: MediaConfirmationBinding
    public var voice: Bool
    public var captions: Bool
    public var method: MediaConfirmationMethod
    public var statement: String
    public var reviewer: String
    public var at: Date
}

public struct MediaConfirmationStatus: Codable, Equatable, Sendable {
    public var voice: Bool
    public var captions: Bool
}

public enum MediaConfirmationRules {
    public static let command = "media confirm"

    /// Do not silently accept a nested review, identity, time or replacement
    /// source field. Codable values alone do not reject unknown JSON members.
    static func validateInput(_ value:AgentValue) throws {
        guard let request=value.object,Set(request.keys)==Set(["voice","captions","method","statement","expected"]),
              let expected=request["expected"]?.object,
              Set(expected.keys).isSubset(of:Set(["contentDigest","voice","captionsDigest"])),
              expected["contentDigest"] != nil,expected["captionsDigest"] != nil else {
            throw VideoError.invalid("确认输入只接受明确选择、确认方法、依据和冻结绑定")
        }
        if let voice=expected["voice"],voice != .null {
            guard let fields=voice.object,Set(fields.keys)==Set(["assetID","sha256","textDigest","durationFrames","method"]) else {
                throw VideoError.invalid("原音绑定字段必须完整且不得附加批准或替换数据")
            }
        }
        let decoded=try Codec.decoder().decode(MediaConfirmationRequest.self,from:Codec.data(value))
        try decoded.validate()
    }

    /// Full content binding includes speed, pitch, gain, source windows, exact
    /// captions and causal timing. Confirmation does not mutate any of them.
    public static func binding(revision:Revision,scene:Scene,database:Database) throws -> MediaConfirmationBinding {
        guard let stored=revision.scenes.first(where:{$0.id==scene.id}),try Codec.digest(stored)==Codec.digest(scene) else {
            throw VideoError.conflict("确认镜头不属于指定版本")
        }
        var voice:MediaVoiceBinding?
        if let take=scene.voice {
            try SpeechProjectRules.validateCompleteTake(take,workspaceID:revision.workspaceID,assets:database.assets)
            guard let asset=database.assets.first(where:{$0.id==take.assetID && $0.workspaceID==revision.workspaceID}),
                  take.textDigest == (try scene.speechDigest()),asset.bytes>0,
                  asset.hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {
                throw VideoError.review("原音资产、完整时长或当前旁白摘要不一致")
            }
            voice=MediaVoiceBinding(assetID:asset.id,sha256:asset.hash,textDigest:take.textDigest,durationFrames:take.durationFrames,method:take.method)
        }
        try SpeechRules.validateCaptions(scene.captions,durationFrames:scene.durationFrames)
        return MediaConfirmationBinding(contentDigest:try revision.contentDigest(),voice:voice,
                                        captionsDigest:try SpeechRules.captionContentDigest(scene.captions))
    }

    static func prepare(workspaceID:String,projectID:String,revisionID:String,sceneID:String,
                        confirmation:MediaConfirmationRequest,database:Database,principal:String,now:Date=Date()) throws -> MediaConfirmation {
        try confirmation.validate()
        let workspace=try database.workspace(workspaceID),project=try database.project(projectID)
        try AgentContract.authorize(command:command,workspace:workspace,principal:principal,projectID:projectID,revisionID:revisionID,now:now)
        guard project.workspaceID==workspaceID,!project.archived,project.current.id==revisionID else {
            throw VideoError.conflict("声音字幕确认须绑定未归档工程的当前版本；原确认不会迁移")
        }
        guard let scene=project.current.scenes.first(where:{$0.id==sceneID}) else {throw VideoError.notFound("当前版本的确认镜头不存在")}
        let exact=try binding(revision:project.current,scene:scene,database:database)
        guard confirmation.expected==exact else {throw VideoError.conflict("版本、原音摘要或字幕原文与时轴已变化，请重新核对实际输入")}
        guard !confirmation.voice || exact.voice != nil else {throw VideoError.review("此镜头没有可确认的完整真实配音")}
        guard !confirmation.captions || !scene.captions.isEmpty else {throw VideoError.review("此镜头没有可确认的字幕")}
        if confirmation.method == .reliableTimestamps,
           scene.captions.contains(where:{$0.alignment.lowercased().contains("estimated")}) {
            throw VideoError.review("估计句段不能声明为可靠时间戳；请实际校正或明确人工核对")
        }
        return MediaConfirmation(id:Codec.id(),workspaceID:workspaceID,projectID:projectID,revisionID:revisionID,
            sceneID:sceneID,binding:exact,voice:confirmation.voice,captions:confirmation.captions,
            method:confirmation.method,statement:confirmation.statement,reviewer:principal,at:now)
    }

    /// Keep historical declarations self-contained. Replacing an asset, removing
    /// an old revision or changing its metadata must only stale the lookup, never
    /// block unrelated future transactions by revalidating today's source state.
    public static func validate(database:Database) throws {
        let records=database.mediaConfirmations ?? []
        guard Set(records.map(\.id)).count==records.count else {throw VideoError.invalid("声音字幕确认记录ID重复")}
        for record in records {
            try MediaConfirmationRequest(voice:record.voice,captions:record.captions,method:record.method,
                statement:record.statement,expected:record.binding).validate()
            guard [record.id,record.workspaceID,record.projectID,record.revisionID,record.sceneID,record.reviewer].allSatisfy({
                !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.utf8.count<=200
            }) else {
                throw VideoError.invalid("声音字幕确认记录的原始范围或确认人不完整")
            }
        }
    }

    /// Lookup never claims someone played the film. Only the explicitly selected
    /// dimension can satisfy that dimension's existing quality gate.
    public static func status(revision:Revision,scene:Scene,database:Database,now:Date=Date()) throws -> MediaConfirmationStatus {
        guard let exact=try? binding(revision:revision,scene:scene,database:database) else {
            return MediaConfirmationStatus(voice:false,captions:false)
        }
        let owners=database.projects.filter {$0.workspaceID==revision.workspaceID && $0.revisions.contains(where:{$0.id==revision.id})}
        guard owners.count==1 else {return MediaConfirmationStatus(voice:false,captions:false)}
        let matches=(database.mediaConfirmations ?? []).filter { record in
            record.projectID==owners[0].id && record.workspaceID==revision.workspaceID &&
            record.revisionID==revision.id && record.sceneID==scene.id && record.binding==exact && record.at<=now
        }
        return MediaConfirmationStatus(voice:matches.contains(where:{$0.voice}),captions:matches.contains(where:{$0.captions}))
    }
}

extension Repository {
    /// Invoked in the SQLite mutation transaction before saving the declaration.
    /// No source is synthesized, imported, edited or re-associated.
    func verifyMediaConfirmationSource(_ record:MediaConfirmation,database:Database) throws {
        guard let expected=record.binding.voice else {return}
        guard let asset=database.assets.first(where:{$0.id==expected.assetID && $0.workspaceID==record.workspaceID}) else {
            throw VideoError.review("确认所用的完整原音资产缺失")
        }
        guard asset.hash==expected.sha256,asset.bytes>0,asset.bytes<=256*1024*1024,
              asset.ext.range(of:"^[a-z0-9]{1,12}$",options:.regularExpression) != nil,
              asset.relativePath=="assets/"+expected.sha256+"."+asset.ext else {
            throw VideoError.review("原音路径、摘要或大小不属于工作区完整资产")
        }
        let base=open(root.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard base>=0 else {throw VideoError.review("原音工作区目录不可读取")};defer{close(base)}
        let directory=openat(base,"assets",O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard directory>=0 else {throw VideoError.review("原音资产目录缺失或为链接")};defer{close(directory)}
        let name=expected.sha256+"."+asset.ext
        let file=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        guard file>=0 else {throw VideoError.review("原音文件缺失或为符号链接")};defer{close(file)}
        var before=stat()
        guard fstat(file,&before)==0,(before.st_mode & S_IFMT)==S_IFREG,before.st_nlink==1,before.st_size==Int64(asset.bytes) else {
            throw VideoError.review("原音不是独立普通文件，或完整大小已变化")
        }
        var digest=SHA256(),buffer=[UInt8](repeating:0,count:1024*1024),total=0
        while true {
            try Task.checkCancellation()
            let count=buffer.withUnsafeMutableBytes{Darwin.read(file,$0.baseAddress,$0.count)}
            guard count>=0,count<=asset.bytes-total else {throw VideoError.review("原音读取失败或在校验中变化")}
            if count==0 {break}
            total+=count;digest.update(data:Data(buffer[0..<count]))
        }
        var after=stat(),located=stat()
        guard fstat(file,&after)==0,fstatat(directory,name,&located,AT_SYMLINK_NOFOLLOW)==0,
              (located.st_mode & S_IFMT)==S_IFREG,located.st_dev==before.st_dev,located.st_ino==before.st_ino,
              after.st_dev==before.st_dev,after.st_ino==before.st_ino,after.st_nlink==1,total==asset.bytes,
              after.st_size==before.st_size,after.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec==before.st_ctimespec.tv_sec,after.st_ctimespec.tv_nsec==before.st_ctimespec.tv_nsec,
              digest.finalize().map({String(format:"%02x",$0)}).joined()==expected.sha256 else {
            throw VideoError.review("确认时原音实际字节、文件身份或摘要已变化，未保存声明")
        }
    }
}

public extension Repository {
    /// SDK and CLI share authorization, current CAS, physical-source verification
    /// and atomic request receipts. This never writes a revision or a job.
    @discardableResult func recordMediaConfirmation(workspaceID:String,projectID:String,revisionID:String,sceneID:String,
        confirmation:MediaConfirmationRequest,principal:String,requestID:String) throws -> MediaConfirmation {
        let input:AgentValue = .object(["workspace_id":.string(workspaceID),"project_id":.string(projectID),
            "base_revision":.string(revisionID),"scene_id":.string(sceneID),"request_id":.string(requestID),
            "confirmation":try Codec.decoder().decode(AgentValue.self,from:Codec.data(confirmation))])
        let response=try performAgentMutation(command:MediaConfirmationRules.command,data:Codec.data(input),principal:principal,requestID:requestID)
        guard let result=response.object?["result"] else {throw VideoError.unavailable("声音字幕确认回执缺失")}
        return try Codec.decoder().decode(MediaConfirmation.self,from:Codec.data(result))
    }
}
