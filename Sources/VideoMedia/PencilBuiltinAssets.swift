import Foundation
import Darwin
import ImageIO
import VideoCore

public enum PencilAssetKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case person, coin, road, flower, grass, tree, bird, bug, fish
    public var id: String { rawValue }
    public var fileName: String { "pencil-" + rawValue + "-v1.png" }
    public var title: String {
        switch self {
        case .person: return "人物"
        case .coin: return "代币"
        case .road: return "道路"
        case .flower: return "花"
        case .grass: return "草"
        case .tree: return "树"
        case .bird: return "鸟"
        case .bug: return "虫"
        case .fish: return "鱼"
        }
    }
}

public struct PencilImportedAsset: Identifiable, Sendable {
    public let kind: PencilAssetKind
    public let asset: Asset
    public var id: String { asset.id }
}
public struct PencilImportedPack: Sendable {
    public let sourceRecord: Asset
    public let items: [PencilImportedAsset]
}

/// Passive, exact-version AI illustration originals. No code, model, game IP or premium license is installed.
public enum PencilBuiltinAssets {
    private struct File {
        let kind: PencilAssetKind
        let bytes: Int
        let hash: String
        let width: Int
        let height: Int
    }
    private static let maximumFileBytes = 4 * 1024 * 1024
    private static let maximumPackBytes = 20 * 1024 * 1024
    private static let maximumSourceBytes = 128 * 1024
    private static let sourceBytes = 11706
    private static let sourceHash = "d7020699fbd3105531cd00607cfbb782b80ad5c085f5f97bcb87d877f29c3710"
    private static let owner = "本任务 AI 通用彩铅生成记录（方方）"
    private static let recordSource = "内置 Pencil/SOURCES.md；9件独立原图的完整提示词、生成来源与固定版本记录"
    private static let files: [File] = [
        .init(kind:.person,bytes:1981077,hash:"c7eb57cc424679af52de043a8e3d75cfdb5ec2cf0c2dbaf6686226eff219ff31",width:1024,height:1536),
        .init(kind:.coin,bytes:2305710,hash:"1e27dc458f406f5c679478568ff885e60d744892e6a4c3fd39eadc381203ed97",width:1310,height:1201),
        .init(kind:.road,bytes:972937,hash:"01679327d9ba9358e96329b982192fb745609bd4709b388c48aa98e8dee8a438",width:2172,height:724),
        .init(kind:.flower,bytes:1338747,hash:"c8d1479069a60ab656f0f68e9dc5c5360d01d90a89f3bc93abc610e3cb667c56",width:1145,height:1374),
        .init(kind:.grass,bytes:1088407,hash:"9414cce8fac7df0eb1076fb81ea7c613028dd6338ecd6d119b9fe92dc012cc62",width:1345,height:1169),
        .init(kind:.tree,bytes:2179523,hash:"c36e67705d0d452033327e4b8b121fb383efcccde3200573bb88f1286541af63",width:1334,height:1179),
        .init(kind:.bird,bytes:2138206,hash:"f5e024ba83c3c7d5fc514ec87103d560642594f2fc0ebe29be76f8b64ee1fe0b",width:1536,height:1024),
        .init(kind:.bug,bytes:1251672,hash:"78b61736d1ab772cf5a40d10ae5d25c3a659288ebd847db6e4b030301e0e0472",width:1331,height:1182),
        .init(kind:.fish,bytes:2422235,hash:"1cd2f1fabe7c312fa353530f70c91d7c58327f978e7d3882b5f49f751ededac5",width:1536,height:1024)
    ]

    public static func importPack(bundle: Bundle = .main, workspaceID: String, repository: Repository, principal: String) async throws -> PencilImportedPack {
        try await importPack(workspaceID:workspaceID,repository:repository,principal:principal) { name in
            let part=name as NSString
            guard let url=bundle.url(forResource:part.deletingPathExtension,withExtension:part.pathExtension,subdirectory:"Pencil") else { throw VideoError.notFound("彩铅素材原件未安装："+name) }
            return url
        }
    }
    public static func importPack(from directory: URL, workspaceID: String, repository: Repository, principal: String) async throws -> PencilImportedPack {
        try await importPack(workspaceID:workspaceID,repository:repository,principal:principal) { directory.appendingPathComponent($0) }
    }
    private static func authorize(workspaceID: String, principal: String, database: Database) throws {
        let workspace=try WorkspaceAccessRules.validate(.init(workspaceID:workspaceID,principal:principal),in:database)
        guard workspace.owner==principal else { throw VideoError.permission("只有当前工作区所有者可以向当前本地素材库导入彩铅原件") }
    }
    /// One stable descriptor, a strict read budget, and original byte hashes precede all CAS/database writes.
    private static func read(_ url: URL, maximum: Int, hash: String, expectedBytes: Int? = nil) throws -> Data {
        guard url.isFileURL else { throw VideoError.invalid("彩铅原件必须是本机普通文件") }
        let descriptor=open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor>=0 else { throw VideoError.notFound("彩铅原件缺失或不是可直接读取的普通文件："+url.lastPathComponent) }
        defer { close(descriptor) }
        var before=stat()
        guard fstat(descriptor,&before)==0,before.st_mode & S_IFMT == S_IFREG,before.st_nlink==1,before.st_size>0,before.st_size<=maximum else { throw VideoError.invalid("彩铅原件仅接受单链接有界普通文件，图片每件至多4MiB") }
        if let expectedBytes { guard before.st_size==expectedBytes else { throw VideoError.review("彩铅原件长度与固定版本不符："+url.lastPathComponent) } }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
        var data=Data();data.reserveCapacity(Int(before.st_size))
        while data.count<=maximum {
            let part=try handle.read(upToCount:min(256*1024,maximum+1-data.count)) ?? Data()
            if part.isEmpty { break }
            data.append(part)
        }
        var after=stat(),pathAfter=stat()
        guard fstat(descriptor,&after)==0,lstat(url.path,&pathAfter)==0,
              after.st_mode & S_IFMT == S_IFREG,pathAfter.st_mode & S_IFMT == S_IFREG,
              after.st_nlink==1,pathAfter.st_nlink==1,
              before.st_dev==after.st_dev,before.st_ino==after.st_ino,after.st_dev==pathAfter.st_dev,after.st_ino==pathAfter.st_ino,
              before.st_size==after.st_size,after.st_size==pathAfter.st_size,data.count==before.st_size,data.count<=maximum,
              before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec,before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec else { throw VideoError.conflict("彩铅原件读取期间改变，未导入") }
        guard Codec.hash(data)==hash else { throw VideoError.review("彩铅原件或来源记录SHA-256与固定版本不符："+url.lastPathComponent) }
        return data
    }
    static func validateImage(_ data: Data, width: Int, height: Int) throws {
        let allowedAlpha:[CGImageAlphaInfo]=[.first,.last,.premultipliedFirst,.premultipliedLast]
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let type=CGImageSourceGetType(source),type as String=="public.png",
              CGImageSourceGetCount(source)==1,let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width==width,image.height==height,
              allowedAlpha.contains(image.alphaInfo) else { throw VideoError.invalid("彩铅原件须为可解码、尺寸匹配且保留透明通道的单张PNG") }
    }
    private static func imageSource(_ file: File) -> String { recordSource+"；"+file.kind.fileName+"；SHA-256 "+file.hash }
    private static func existing(_ file: File?, rights: Bool = false, database: Database, workspaceID: String, recordID: String?) throws -> Asset? {
        let name=rights ? "pencil-sources-v1.md":file!.kind.fileName
        let hash=rights ? sourceHash:file!.hash
        let matches=database.assets.filter{$0.workspaceID==workspaceID && $0.name==name && $0.hash==hash}
        guard matches.count<=1 else { throw VideoError.conflict("彩铅原件存在重复来源记录，请先核对素材库") }
        guard let asset=matches.first else { return nil }
        guard asset.mediaType==(rights ? "text":"image"),asset.ext==(rights ? "md":"png"),asset.bytes==(rights ? sourceBytes:file!.bytes),let proofID=asset.evidenceID else { throw VideoError.conflict("彩铅素材元数据已改变，请先核对素材库："+name) }
        let proofs=database.evidence.filter{$0.id==proofID && $0.workspaceID==workspaceID}
        guard proofs.count==1,let proof=proofs.first,proof.owner==owner,
              proof.source==(rights ? recordSource:imageSource(file!)),proof.assetID==(rights ? asset.id:recordID) else { throw VideoError.conflict("彩铅来源关联已改变，请先核对素材库："+name) }
        return asset // Preserve expiry, revocation, commercial/upload decisions, tags and review metadata exactly.
    }
    private static func importPack(workspaceID: String, repository: Repository, principal: String, url: (String) throws -> URL) async throws -> PencilImportedPack {
        try authorize(workspaceID:workspaceID,principal:principal,database:repository.read())
        let recordData=try read(url("SOURCES.md"),maximum:maximumSourceBytes,hash:sourceHash,expectedBytes:sourceBytes)
        var budget=recordData.count
        var snapshots:[(File,Data)]=[]
        for file in files {
            let data=try read(url(file.kind.fileName),maximum:maximumFileBytes,hash:file.hash,expectedBytes:file.bytes)
            guard budget<=maximumPackBytes-data.count else { throw VideoError.invalid("彩铅原件整包超过20MiB，未导入") }
            budget+=data.count
            try validateImage(data,width:file.width,height:file.height)
            snapshots.append((file,data))
        }
        return try repository.transaction { database in
            try authorize(workspaceID:workspaceID,principal:principal,database:database)
            let oldRecord=try existing(nil,rights:true,database:database,workspaceID:workspaceID,recordID:nil)
            var reused:[PencilAssetKind:Asset]=[:]
            for (file,_) in snapshots {
                if let old=try existing(file,database:database,workspaceID:workspaceID,recordID:oldRecord?.id) { reused[file.kind]=old }
            }
            var record:Asset
            if let oldRecord { record=oldRecord }
            else {
                record=try repository.ingest(recordData,name:"pencil-sources-v1.md",workspaceID:workspaceID,mediaType:"text")
                let proof=Evidence(workspaceID:workspaceID,title:"AI通用彩铅原件生成与来源记录",source:recordSource,claim:"完整保存9件独立AI生成原图的提示词、生成记录和版本；仅核对固定来源原件，不自动批准视觉审稿、商用传播、第三方IP或高级制作权益。",owner:owner,commercialAllowed:false,uploadConsent:false,verified:true,assetID:record.id)
                record.evidenceID=proof.id;record.tags=["AI生成通用彩铅素材","彩铅备用库v1","来源原件"]
                database.assets.append(record);database.evidence.append(proof)
            }
            var items:[PencilImportedAsset]=[]
            for (file,data) in snapshots {
                let asset:Asset
                if let old=reused[file.kind] { asset=old }
                else {
                    var fresh=try repository.ingest(data,name:file.kind.fileName,workspaceID:workspaceID,mediaType:"image")
                    let proof=Evidence(workspaceID:workspaceID,title:"AI通用彩铅 · "+file.kind.title,source:imageSource(file),claim:"本任务按已保存提示词独立生成的透明彩铅PNG；非GitHub知名游戏素材，不替代游戏素材、高级插件权益或商用许可；原件来源核对不代表完整视觉/声音/字幕人审。",owner:owner,commercialAllowed:false,uploadConsent:false,verified:true,assetID:record.id)
                    fresh.evidenceID=proof.id;fresh.tags=["AI生成通用彩铅素材","彩铅备用库v1",file.kind.title]
                    fresh.warnings=["AI生成的通用彩铅图形；不是GitHub游戏角色或场景，不代表高级制作权益。","来源原件已保存；视觉审稿与具体传播用途仍须核对。"]
                    database.assets.append(fresh);database.evidence.append(proof);asset=fresh
                }
                items.append(.init(kind:file.kind,asset:asset))
            }
            return PencilImportedPack(sourceRecord:record,items:items)
        }
    }
}
