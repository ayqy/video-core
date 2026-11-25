import Foundation
import CryptoKit
import CoreFoundation
import Darwin

public struct BackupFileReceipt: Sendable {
    public let bytes: Int
    public let sha256: String
}

/// v4 is a bounded file container, not a larger legacy in-memory plist.
/// The header and index are followed by one snapshot and each indexed file in
/// order. No caller-controlled offsets, archive tools or external paths exist.
enum StreamingBackupRules {
    static let magic = Data("VIDBAK04".utf8)
    static let maximumFileBytes = 64 * 1024 * 1024 * 1024
    static let maximumManifestBytes = 64 * 1024 * 1024
    static let maximumEntries = 200_000
    static let maximumContainerBytes = 16 + maximumManifestBytes + BackupSnapshotCodec.maximumStreamingSnapshotBytes + maximumFileBytes
    static let blockBytes = 1024 * 1024

    struct Entry: Codable, Equatable {
        var kind: String
        var path: String
        var bytes: Int
        var sha256: String
    }
    struct Manifest: Codable {
        var version: Int
        var snapshotEncoding: String
        var snapshotBytes: Int
        var snapshotStoredBytes: Int
        var snapshotDigest: String
        var entries: [Entry]
        var totalFileBytes: Int
    }

    static func hash(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.kind == rhs.kind ? lhs.path < rhs.path : lhs.kind < rhs.kind
    }
    static func validPath(_ entry: Entry) -> Bool {
        guard entry.path.utf8.count <= 4096, !entry.path.contains(".."),
              !entry.path.contains("\\"), !entry.path.contains("\0") else { return false }
        switch entry.kind {
        case "assets":
            return entry.path.range(of: "^assets/[a-f0-9]{64}\\.[a-z0-9]{1,12}$", options: .regularExpression) != nil
                && entry.path.split(separator: "/").last!.split(separator: ".").first! == Substring(entry.sha256)
        case "exports": return Repository.validExportPath(entry.path)
        case "visualCache":
            return entry.path.range(of: "^cache/visuals/[a-f0-9]{64}\\.(plist|mp4)$", options: .regularExpression) != nil
        default: return false
        }
    }
    static func validate(_ manifest: Manifest) throws {
        guard manifest.version == 4, manifest.entries.count <= maximumEntries,
              manifest.snapshotBytes > 0, manifest.snapshotBytes <= BackupSnapshotCodec.maximumStreamingSnapshotBytes,
              manifest.snapshotStoredBytes > 0, manifest.snapshotStoredBytes <= BackupSnapshotCodec.maximumStreamingSnapshotBytes,
              hash(manifest.snapshotDigest), manifest.totalFileBytes >= 0, manifest.totalFileBytes <= maximumFileBytes else {
            throw VideoError.invalid("v4备份清单版本、长度或数量超过安全边界")
        }
        if manifest.snapshotEncoding == BackupSnapshotCodec.rawEncoding {
            guard manifest.snapshotStoredBytes == manifest.snapshotBytes else { throw VideoError.invalid("v4原始快照长度不符") }
        } else if manifest.snapshotEncoding == BackupSnapshotCodec.encoding {
            guard manifest.snapshotStoredBytes < manifest.snapshotBytes else { throw VideoError.invalid("v4压缩快照没有压缩收益") }
        } else { throw VideoError.invalid("v4备份快照编码不支持") }
        var total = 0, previous: Entry?, paths = Set<String>()
        for entry in manifest.entries {
            guard entry.bytes >= 0, entry.bytes <= maximumFileBytes - total, hash(entry.sha256), validPath(entry),
                  paths.insert(entry.path).inserted, previous.map({ precedes($0, entry) }) ?? true else {
                throw VideoError.invalid("v4备份文件索引不规范、重复、无序或超过安全边界")
            }
            total += entry.bytes; previous = entry
        }
        guard total == manifest.totalFileBytes else { throw VideoError.invalid("v4备份文件总长度不符") }
    }
    static func decodeManifest(_ data: Data) throws -> Manifest {
        guard !data.isEmpty, data.count <= maximumManifestBytes, data.starts(with: Data("bplist00".utf8)),
              let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              Set(object.keys) == ["version", "snapshotEncoding", "snapshotBytes", "snapshotStoredBytes", "snapshotDigest", "entries", "totalFileBytes"],
              let entries = object["entries"] as? [[String: Any]], entries.count <= maximumEntries else {
            throw VideoError.invalid("v4备份清单字段或格式无效")
        }
        func integer(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType))
        }
        guard ["version", "snapshotBytes", "snapshotStoredBytes", "totalFileBytes"].allSatisfy({ integer(object[$0]) }),
              entries.allSatisfy({ Set($0.keys) == ["kind", "path", "bytes", "sha256"] && integer($0["bytes"]) }) else {
            throw VideoError.invalid("v4备份清单整数或文件字段无效")
        }
        let manifest = try PropertyListDecoder().decode(Manifest.self, from: data)
        try validate(manifest)
        return manifest
    }
    static func validateBackupDestination(_ destination: URL, repositoryRoot: URL) throws {
        guard destination.isFileURL else { throw VideoError.invalid("备份目标必须是本机文件") }
        let parent=try physicalParent(of: destination)
        let target=parent.appendingPathComponent(destination.lastPathComponent)
        var rootInfo=stat()
        guard fstatat(AT_FDCWD, repositoryRoot.path, &rootInfo, 0) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw VideoError.permission("在线工程目录已变化，未开始备份")
        }
        var ancestorPath=parent.path, isDirectParent=true, insideWorkspace=false, directWorkspace=false
        while ancestorPath.count > 1 && ancestorPath.hasSuffix("/") { ancestorPath.removeLast() }
        while true {
            var info=stat()
            guard fstatat(AT_FDCWD, ancestorPath, &info, 0) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw VideoError.permission("备份目标父目录不可用或不是目录")
            }
            if info.st_dev == rootInfo.st_dev && info.st_ino == rootInfo.st_ino {
                insideWorkspace=true; directWorkspace=isDirectParent; break
            }
            // URL.deletingLastPathComponent() is not a POSIX dirname fixed
            // point at '/'. Stop explicitly and never probe an empty/relative
            // URL after reaching the physical filesystem root.
            if ancestorPath == "/" { break }
            guard let separator=ancestorPath.lastIndex(of: "/") else { throw VideoError.invalid("备份目标父目录必须是绝对路径") }
            ancestorPath=separator == ancestorPath.startIndex ? "/" : String(ancestorPath[..<separator])
            isDirectParent=false
        }
        // The existing CLI places archives directly in the workspace. Every
        // other workspace namespace belongs to live data, including unknown
        // future state files. Physical identities cover case aliases/firmlinks
        // as well as ordinary symlink aliases without a path-prefix assumption.
        if insideWorkspace {
            guard directWorkspace, target.pathExtension.lowercased() == "videobackup" else {
                throw VideoError.permission("备份目标不得覆盖在线工程的源文件、历史导出、数据库或内部状态；请另选备份文件位置")
            }
        }
    }
    static func physicalParent(of file: URL) throws -> URL {
        guard file.isFileURL, file.path.hasPrefix("/"), !file.path.contains("\0") else { throw VideoError.invalid("备份文件必须使用本机绝对路径") }
        // Foundation may standardize /private/tmp and /private/var back to
        // their system aliases. POSIX realpath keeps the actual existing
        // directory, so the subsequent O_NOFOLLOW descriptor open is valid.
        let pointer=file.deletingLastPathComponent().path.withCString { Darwin.realpath($0, nil) }
        guard let pointer else { throw VideoError.permission("备份文件父目录不存在或无法解析") }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }
}

private struct StreamingBackupIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let links: nlink_t
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        device=value.st_dev; inode=value.st_ino; size=value.st_size; links=value.st_nlink; mode=value.st_mode
        modifiedSeconds=value.st_mtimespec.tv_sec; modifiedNanos=value.st_mtimespec.tv_nsec
        changedSeconds=value.st_ctimespec.tv_sec; changedNanos=value.st_ctimespec.tv_nsec
    }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode && mode & S_IFMT == other.mode & S_IFMT }
}

/// Pins each directory and the final independent regular file. Hashing and
/// copying share this descriptor; reopening a pathname cannot replace its data.
final class StreamingBackupInput {
    let descriptor: Int32
    let count: Int
    private let parents: [Int32]
    private let directory: Int32
    private let name: String
    private let before: StreamingBackupIdentity
    private(set) var position = 0

    convenience init(url: URL, maximumBytes: Int) throws {
        guard url.isFileURL else { throw VideoError.invalid("备份必须是本机文件") }
        let parent = try StreamingBackupRules.physicalParent(of: url)
        try self.init(root: parent, relative: url.lastPathComponent, bytes: nil, maximumBytes: maximumBytes)
    }
    init(root: URL, relative: String, bytes: Int?, maximumBytes: Int) throws {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard maximumBytes >= 0, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw VideoError.invalid("备份读取路径或上限无效")
        }
        var opened: [Int32] = []
        let base = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard base >= 0 else { throw VideoError.permission("备份读取根目录不可用或为链接") }
        opened.append(base)
        do {
            var parent = base
            for component in parts.dropLast() {
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw VideoError.permission("备份读取目录缺失或包含链接") }
                opened.append(next); parent=next
            }
            let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw VideoError.permission("备份源文件缺失或为链接") }
            var info=stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_size >= 0, info.st_size <= Int64(maximumBytes), bytes.map({ info.st_size == Int64($0) }) ?? true else {
                close(fd); throw VideoError.invalid("备份源文件类型、链接数或长度不符")
            }
            descriptor=fd; count=Int(info.st_size); parents=opened; directory=parent; name=parts.last!; before=StreamingBackupIdentity(info)
        } catch { for fd in opened.reversed() { close(fd) }; throw error }
    }
    deinit { close(descriptor); for fd in parents.reversed() { close(fd) } }
    func rewind(to offset: Int = 0) throws {
        guard offset >= 0, offset <= count, lseek(descriptor, off_t(offset), SEEK_SET) == off_t(offset) else { throw VideoError.invalid("备份流位置无效") }
        position=offset
    }
    func readExactly(_ bytes: Int) throws -> Data {
        guard bytes >= 0, bytes <= count - position else { throw VideoError.invalid("备份流被截断") }
        var data=Data(); data.reserveCapacity(bytes)
        try blocks(bytes: bytes) { data.append($0) }
        return data
    }
    func blocks(bytes: Int, _ consume: (Data) throws -> Void) throws {
        guard bytes >= 0, bytes <= count - position else { throw VideoError.invalid("备份流被截断") }
        var remaining=bytes, buffer=[UInt8](repeating: 0, count: StreamingBackupRules.blockBytes)
        while remaining > 0 {
            try Task.checkCancellation()
            let wanted=min(remaining, buffer.count)
            let amount=buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0, amount <= wanted else { throw VideoError.invalid("备份流读取失败或被截断") }
            let block=Data(buffer[0..<amount]); try consume(block)
            remaining-=amount; position+=amount
        }
    }
    func finish() throws {
        var info=stat(), located=stat()
        guard fstat(descriptor, &info) == 0,
              fstatat(directory, name, &located, AT_SYMLINK_NOFOLLOW) == 0,
              StreamingBackupIdentity(info) == before, StreamingBackupIdentity(located) == before else {
            throw VideoError.conflict("备份源文件在读取期间变化，未发布结果")
        }
    }
    func digest(copyTo target: Int32? = nil) throws -> String {
        var hash=SHA256()
        try blocks(bytes: count - position) { block in
            hash.update(data: block)
            if let target { try StreamingBackupOutput.write(block, to: target) }
        }
        try finish()
        return hash.finalize().map({ String(format: "%02x", $0) }).joined()
    }
}

private enum StreamingBackupOutput {
    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset=0
            while offset < raw.count {
                try Task.checkCancellation()
                let amount=Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count-offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw VideoError.unavailable("备份写入失败；原文件保留") }
                offset+=amount
            }
        }
    }
    static func file(root: URL, relative: String) throws -> Int32 {
        let parts=relative.split(separator: "/").map(String.init)
        var opened: [Int32]=[]
        let base=open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard base >= 0 else { throw VideoError.permission("恢复暂存目录已变化") }
        opened.append(base); defer { for fd in opened.reversed() { close(fd) } }
        var directory=base
        for part in parts.dropLast() {
            if mkdirat(directory, part, 0o700) != 0 && errno != EEXIST { throw VideoError.unavailable("无法建立恢复子目录") }
            let next=openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw VideoError.permission("恢复目录被替换为链接") }
            opened.append(next); directory=next
        }
        let fd=openat(directory, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VideoError.conflict("恢复文件已存在或不可建立，未覆盖") }
        return fd
    }
}

/// Same-parent unpublished staging; the old target survives every validation
/// failure. Only the exact staging object created by this operation is cleaned.
final class StreamingBackupPublication {
    let final: URL
    let staging: URL
    let descriptor: Int32
    private let parent: URL
    private let parentDescriptor: Int32
    private let parentIdentity: StreamingBackupIdentity
    private let stagingIdentity: StreamingBackupIdentity
    private let existing: StreamingBackupIdentity?
    private let isDirectory: Bool
    private var published=false

    init(destination: URL, directory: Bool, replaceExisting: Bool = false) throws {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
              destination.lastPathComponent != ".", destination.lastPathComponent != ".." else { throw VideoError.invalid("备份目标无效") }
        parent=try StreamingBackupRules.physicalParent(of: destination)
        final=parent.appendingPathComponent(destination.lastPathComponent, isDirectory: directory)
        isDirectory=directory
        let parentFD=open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else { throw VideoError.permission("备份目标父目录不可用") }
        var parentInfo=stat()
        guard fstat(parentFD, &parentInfo) == 0 else { close(parentFD); throw VideoError.unavailable("无法核对备份目标父目录") }
        var old=stat()
        if fstatat(parentFD, final.lastPathComponent, &old, AT_SYMLINK_NOFOLLOW) == 0 {
            guard !directory, replaceExisting, old.st_mode & S_IFMT == S_IFREG, old.st_nlink == 1 else {
                close(parentFD); throw VideoError.conflict("备份或恢复目标已存在；原目标保留")
            }
            existing=StreamingBackupIdentity(old)
        } else {
            guard errno == ENOENT else { close(parentFD); throw VideoError.unavailable("无法核对备份目标") }
            existing=nil
        }
        staging=parent.appendingPathComponent(".video-backup-"+Codec.id()+".preparing", isDirectory: directory)
        let fd: Int32
        if directory {
            guard mkdirat(parentFD, staging.lastPathComponent, 0o700) == 0 else { close(parentFD); throw VideoError.unavailable("无法建立恢复暂存目录") }
            fd=openat(parentFD, staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        } else {
            fd=openat(parentFD, staging.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { close(parentFD); throw VideoError.unavailable("无法建立备份暂存文件") }
        var info=stat()
        guard fstat(fd, &info) == 0 else { close(fd); close(parentFD); throw VideoError.unavailable("无法核对备份暂存文件") }
        descriptor=fd; parentDescriptor=parentFD; parentIdentity=StreamingBackupIdentity(parentInfo); stagingIdentity=StreamingBackupIdentity(info)
    }
    deinit {
        close(descriptor)
        if !published, ownedStaging() { try? FileManager.default.removeItem(at: staging) }
        close(parentDescriptor)
    }
    private func ownedStaging() -> Bool {
        var parentInfo=stat(), stageInfo=stat()
        return lstat(parent.path, &parentInfo) == 0 && parentIdentity.sameObject(StreamingBackupIdentity(parentInfo))
            && fstatat(parentDescriptor, staging.lastPathComponent, &stageInfo, AT_SYMLINK_NOFOLLOW) == 0
            && stagingIdentity.sameObject(StreamingBackupIdentity(stageInfo))
    }
    func publish() throws {
        try Task.checkCancellation()
        guard ownedStaging() else { throw VideoError.conflict("备份暂存或目标父目录已变化，未发布") }
        var current=stat()
        if let existing {
            guard fstatat(parentDescriptor, final.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  StreamingBackupIdentity(current) == existing else { throw VideoError.conflict("所选旧备份已变化，未覆盖") }
        } else {
            guard fstatat(parentDescriptor, final.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw VideoError.conflict("备份或恢复目标在执行期间出现，未覆盖")
            }
        }
        guard fsync(descriptor) == 0 else { throw VideoError.unavailable("无法同步完整备份暂存内容，未发布") }
        let flags: UInt32=existing == nil ? UInt32(RENAME_EXCL) : 0
        guard renameatx_np(parentDescriptor, staging.lastPathComponent, parentDescriptor, final.lastPathComponent, flags) == 0 else {
            throw VideoError.conflict("完整备份未能原子发布；已有目标保留")
        }
        published=true
        _=fsync(parentDescriptor)
    }
}

private struct StreamingBackupPlan {
    var state: Database
    var entries: [StreamingBackupRules.Entry]
    var visualCache: [String: Data]
    var totalBytes: Int
}

private final class StreamingBackupArchive {
    let input: StreamingBackupInput
    let manifest: StreamingBackupRules.Manifest
    let state: Database
    private(set) var offsets: [String: Int]=[:]

    init(input: StreamingBackupInput) throws {
        self.input=input
        try input.rewind()
        guard try input.readExactly(8) == StreamingBackupRules.magic else { throw VideoError.invalid("v4备份文件标记无效") }
        let lengthBytes=try input.readExactly(8)
        let length=lengthBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= UInt64(StreamingBackupRules.maximumManifestBytes),
              length <= UInt64(input.count-input.position) else { throw VideoError.invalid("v4备份清单长度无效") }
        manifest=try StreamingBackupRules.decodeManifest(input.readExactly(Int(length)))
        let remaining=manifest.snapshotStoredBytes + manifest.totalFileBytes
        guard remaining == input.count-input.position else { throw VideoError.invalid("v4备份总长度不符、被截断或含尾随字节") }
        let stored=try input.readExactly(manifest.snapshotStoredBytes)
        let raw=try BackupSnapshotCodec.decodeStreamingSnapshot(stored, encoding: manifest.snapshotEncoding,
            snapshotBytes: manifest.snapshotBytes, digest: manifest.snapshotDigest)
        state=try RepositorySnapshotCodec.decode(raw)
        try state.validate()
        guard state.providers.isEmpty else { throw VideoError.invalid("便携备份不得携带供应商配置或凭据引用") }
        try Self.validateReferences(state, entries: manifest.entries)
    }
    static func validateReferences(_ state: Database, entries: [StreamingBackupRules.Entry]) throws {
        let assets=Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == "assets" }.map { ($0.path, $0) })
        let exports=Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == "exports" }.map { ($0.path, $0) })
        guard Set(assets.keys) == Set(state.assets.map(\.relativePath)),
              Set(exports.keys) == Set(state.jobs.flatMap { $0.artifacts.map(\.path) }) else {
            throw VideoError.invalid("v4文件集合与完整工程源文件或历史导出引用不一致")
        }
        for asset in state.assets {
            guard let entry=assets[asset.relativePath], entry.bytes == asset.bytes, entry.sha256 == asset.hash else {
                throw VideoError.invalid("v4源文件长度或摘要与工程引用不一致")
            }
        }
        for job in state.jobs where !job.artifacts.isEmpty {
            guard let project=state.projects.first(where: { $0.id == job.projectID && $0.workspaceID == job.workspaceID }),
                  let revision=project.revisions.first(where: { $0.id == job.revisionID }) else { throw VideoError.review("历史导出的原任务或冻结版本缺失") }
            try Repository.validateArtifactBinding(job, revision: revision)
            guard job.id.range(of: "^[a-z0-9][a-z0-9-]{0,79}$", options: .regularExpression) != nil,
                  Set(job.artifacts.map(\.path)).count == job.artifacts.count else {
                throw VideoError.invalid("v4历史导出任务ID或文件位置重复")
            }
            for artifact in job.artifacts {
                let components=artifact.path.split(separator: "/").map(String.init)
                let scoped=(components.count == 3 && components[0] == "exports" && components[1] == job.id)
                    || (components.count == 2 && components[0] == "drafts" && components[1] == job.id+".txt" && artifact.mime == "text/plain")
                guard scoped, artifact.revision == job.revisionID,
                      components.last?.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
                      let entry=exports[artifact.path], entry.bytes == artifact.bytes, entry.sha256 == artifact.sha256 else {
                    throw VideoError.invalid("v4历史导出长度或摘要与冻结任务不一致")
                }
            }
        }
    }
    func consumeFiles(copyTo root: URL? = nil) throws {
        var cache: [String: Data]=[:], cacheBytes=0
        for entry in manifest.entries {
            try Task.checkCancellation()
            offsets[entry.path]=input.position
            var digest=SHA256(), cached=Data()
            if entry.kind == "visualCache" {
                guard entry.bytes <= VisualCacheBackup.maximumBytes-cacheBytes else { throw VideoError.invalid("v4绘制缓存超过既有32MiB上限") }
                cacheBytes+=entry.bytes
            }
            let output=try root.map { try StreamingBackupOutput.file(root: $0, relative: entry.path) }
            do {
                try input.blocks(bytes: entry.bytes) { block in
                    digest.update(data: block)
                    if let output { try StreamingBackupOutput.write(block, to: output) }
                    if entry.kind == "visualCache" { cached.append(block) }
                }
                if let output, fsync(output) != 0 { throw VideoError.unavailable("恢复源文件同步失败，未发布目录") }
            } catch { if let output { close(output) }; throw error }
            if let output { close(output) }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
                throw VideoError.invalid("v4备份源文件或历史导出摘要不符")
            }
            if entry.kind == "visualCache" { cache[String(entry.path.dropFirst("cache/visuals/".count))]=cached }
        }
        guard input.position == input.count else { throw VideoError.invalid("v4备份含额外或未读取字节") }
        _=try VisualCacheBackup.validate(cache, availableBytes: VisualCacheBackup.maximumBytes)
        try input.finish()
    }
    func verifyModels() throws {
        try Repository.verifyModelSceneSources(in: state) { asset in
            guard asset.bytes <= DAEInspector.maximumBytes, let offset=self.offsets[asset.relativePath] else { throw VideoError.invalid("v4备份缺少实际模型原件") }
            try self.input.rewind(to: offset)
            return try self.input.readExactly(asset.bytes)
        }
        try input.finish()
    }
}

public extension Repository {
    private func streamingBackupPlan() throws -> StreamingBackupPlan {
        var state=try read(); try state.validate(); try verifyModelSceneSources(in: state); state.providers=[]
        var files: [String: StreamingBackupRules.Entry]=[:]
        func include(_ entry: StreamingBackupRules.Entry) throws {
            guard StreamingBackupRules.validPath(entry), StreamingBackupRules.hash(entry.sha256), entry.bytes >= 0 else { throw VideoError.invalid("完整备份文件路径、长度或摘要无效") }
            if let old=files[entry.path] { guard old == entry else { throw VideoError.invalid("同一路径的完整备份引用不一致") } }
            else { files[entry.path]=entry }
        }
        for asset in state.assets { try include(.init(kind: "assets", path: asset.relativePath, bytes: asset.bytes, sha256: asset.hash)) }
        for index in state.jobs.indices {
            let job=state.jobs[index]
            if !job.artifacts.isEmpty {
                guard let project=state.projects.first(where: { $0.id == job.projectID && $0.workspaceID == job.workspaceID }),
                      let revision=project.revisions.first(where: { $0.id == job.revisionID }) else { throw VideoError.review("历史导出原任务或版本缺失，完整备份未标成功") }
                try Self.validateArtifactBinding(job, revision: revision)
            }
            let locations=job.artifacts.isEmpty ? [] : try artifactLocations(job)
            for artifactIndex in job.artifacts.indices {
                let artifact=job.artifacts[artifactIndex], path=locations[artifactIndex].components.joined(separator: "/")
                try include(.init(kind: "exports", path: path, bytes: artifact.bytes, sha256: artifact.sha256))
                state.jobs[index].artifacts[artifactIndex].path=path
            }
        }
        var total=0
        for entry in files.values {
            guard entry.bytes <= StreamingBackupRules.maximumFileBytes-total else { throw VideoError.invalid("v4完整备份源文件和历史导出超过64GiB上限") }
            total+=entry.bytes
        }
        let cache=try backupVisualCache(availableBytes: StreamingBackupRules.maximumFileBytes-total) ?? [:]
        for (name, data) in cache {
            try include(.init(kind: "visualCache", path: "cache/visuals/"+name, bytes: data.count, sha256: Codec.hash(data)))
            guard data.count <= StreamingBackupRules.maximumFileBytes-total else { throw VideoError.invalid("v4完整备份文件总量超过64GiB上限") }
            total+=data.count
        }
        guard files.count <= StreamingBackupRules.maximumEntries else { throw VideoError.invalid("v4完整备份文件数超过200000项") }
        let entries=files.values.sorted(by: StreamingBackupRules.precedes)
        try StreamingBackupArchive.validateReferences(state, entries: entries)
        return StreamingBackupPlan(state: state, entries: entries, visualCache: cache, totalBytes: total)
    }

    /// Writes source and history payloads one block at a time. No complete CAS
    /// dictionary or complete container Data is ever constructed.
    func backup(to destination: URL, replaceExisting: Bool = false) throws -> BackupFileReceipt {
        try Task.checkCancellation()
        try StreamingBackupRules.validateBackupDestination(destination, repositoryRoot: root)
        let plan=try streamingBackupPlan(), raw=try RepositorySnapshotCodec.encode(plan.state)
        guard !raw.isEmpty, raw.count <= BackupSnapshotCodec.maximumStreamingSnapshotBytes else { throw VideoError.invalid("v4备份JSON快照超过1000000000字节安全上限") }
        var stored=raw, encoding=BackupSnapshotCodec.rawEncoding
        if raw.count >= BackupSnapshotCodec.minimumCompressionBytes {
            let compressed=try BackupSnapshotCodec.compressStreamingSnapshot(raw)
            if compressed.count < raw.count { stored=compressed; encoding=BackupSnapshotCodec.encoding }
        }
        let manifest=StreamingBackupRules.Manifest(version: 4, snapshotEncoding: encoding, snapshotBytes: raw.count,
            snapshotStoredBytes: stored.count, snapshotDigest: Codec.hash(raw), entries: plan.entries, totalFileBytes: plan.totalBytes)
        try StreamingBackupRules.validate(manifest)
        let encoder=PropertyListEncoder(); encoder.outputFormat = .binary
        let index=try encoder.encode(manifest)
        guard index.count <= StreamingBackupRules.maximumManifestBytes else { throw VideoError.invalid("v4备份清单超过64MiB安全上限") }
        let publication=try StreamingBackupPublication(destination: destination, directory: false, replaceExisting: replaceExisting)
        var digest=SHA256(), bytes=0
        func write(_ block: Data) throws {
            guard block.count <= StreamingBackupRules.maximumContainerBytes-bytes else { throw VideoError.invalid("v4备份总长度超过安全上限") }
            try StreamingBackupOutput.write(block, to: publication.descriptor); digest.update(data: block); bytes+=block.count
        }
        try write(StreamingBackupRules.magic)
        let indexLength=UInt64(index.count)
        try write(Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: indexLength >> UInt64($0*8)) }))
        try write(index); try write(stored)
        for entry in plan.entries {
            if entry.kind == "visualCache" {
                guard let data=plan.visualCache[String(entry.path.dropFirst("cache/visuals/".count))], data.count == entry.bytes, Codec.hash(data) == entry.sha256 else { throw VideoError.invalid("绘制缓存暂存内容变化") }
                try write(data)
            } else {
                let input=try StreamingBackupInput(root: root, relative: entry.path, bytes: entry.bytes, maximumBytes: StreamingBackupRules.maximumFileBytes)
                var fileDigest=SHA256()
                try input.blocks(bytes: entry.bytes) { block in fileDigest.update(data: block); try write(block) }
                try input.finish()
                guard fileDigest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else { throw VideoError.invalid("备份源素材或历史导出摘要不符；原备份保留") }
            }
        }
        guard bytes == 16 + index.count + stored.count + plan.totalBytes else { throw VideoError.invalid("v4备份写入总长度不符") }
        guard fsync(publication.descriptor) == 0 else { throw VideoError.unavailable("完整备份暂存同步失败") }
        let expectedDigest=digest.finalize().map({ String(format: "%02x", $0) }).joined()
        let staged=try StreamingBackupInput(url: publication.staging, maximumBytes: StreamingBackupRules.maximumContainerBytes)
        guard staged.count == bytes, try staged.digest() == expectedDigest else { throw VideoError.invalid("完整备份暂存长度或摘要变化，未发布") }
        try publication.publish()
        return BackupFileReceipt(bytes: bytes, sha256: expectedDigest)
    }

    /// New file entry point accepts old bounded plist envelopes as well as v4.
    /// A v4 recovery is invisible until all files, models and SQLite validate.
    static func restore(from source: URL, to destination: URL) throws -> Repository {
        try Task.checkCancellation()
        let input=try StreamingBackupInput(url: source, maximumBytes: StreamingBackupRules.maximumContainerBytes)
        let prefix=try input.readExactly(min(8, input.count))
        if prefix != StreamingBackupRules.magic {
            guard input.count <= 350 * 1024 * 1024 else { throw VideoError.invalid("旧版备份超过350MiB封套上限") }
            try input.rewind(); let data=try input.readExactly(input.count); try input.finish()
            // Keep the legacy decoder and its exact limits. The file API also
            // stages old formats so the selected recovery path remains absent.
            let publication=try StreamingBackupPublication(destination: destination, directory: true)
            var restored: Repository?=try Repository.restoreLegacy(data, to: publication.staging,
                artifactRoot: publication.final, allowEmptyDirectory: true)
            _=try restored!.read()
            restored=nil
            try input.finish(); try publication.publish()
            return try Repository(root: publication.final)
        }
        let archive=try StreamingBackupArchive(input: input)
        let publication=try StreamingBackupPublication(destination: destination, directory: true)
        try archive.consumeFiles(copyTo: publication.staging)
        try Self.verifyModelSceneSources(in: archive.state) { asset in
            let file=try StreamingBackupInput(root: publication.staging, relative: asset.relativePath, bytes: asset.bytes, maximumBytes: DAEInspector.maximumBytes)
            let data=try file.readExactly(asset.bytes); try file.finish(); return data
        }
        var state=archive.state
        for j in state.jobs.indices { for a in state.jobs[j].artifacts.indices {
            state.jobs[j].artifacts[a].path=publication.final.appendingPathComponent(state.jobs[j].artifacts[a].path).path
        } }
        var repository: Repository?=try Repository(root: publication.staging)
        try repository!.transaction { $0=state }
        repository=nil // close SQLite/WAL before the directory rename
        try input.finish()
        try publication.publish()
        return try Repository(root: publication.final)
    }

    /// Installer comparison does not create another multi-GiB container. It
    /// still authenticates every source/export and includes the full history.
    func backupSemanticDigest() throws -> String {
        let plan=try streamingBackupPlan()
        for entry in plan.entries where entry.kind != "visualCache" {
            let file=try StreamingBackupInput(root: root, relative: entry.path, bytes: entry.bytes, maximumBytes: StreamingBackupRules.maximumFileBytes)
            guard try file.digest() == entry.sha256 else { throw VideoError.invalid("工程源文件或历史导出摘要不符") }
        }
        return try Self.streamingSemanticDigest(state: plan.state, entries: plan.entries)
    }
    static func backupSemanticDigest(from source: URL) throws -> String {
        let input=try StreamingBackupInput(url: source, maximumBytes: StreamingBackupRules.maximumContainerBytes)
        let prefix=try input.readExactly(min(8, input.count))
        guard prefix == StreamingBackupRules.magic else {
            guard input.count <= 350 * 1024 * 1024 else { throw VideoError.invalid("旧版备份超过350MiB封套上限") }
            try input.rewind(); let data=try input.readExactly(input.count); try input.finish()
            let value=try PropertyListDecoder().decode(Backup.self, from: data)
            guard [2, 3].contains(value.version) else { throw VideoError.invalid("安装备份版本不符") }
            let state=try RepositorySnapshotCodec.decode(value.decodedSnapshot()); try state.validate()
            var entries: [StreamingBackupRules.Entry]=[], total=0
            for (kind, files) in [("assets", value.assets), ("exports", value.exports ?? [:])] {
                for (path, bytes) in files {
                    guard bytes.count <= 300 * 1024 * 1024-total else { throw VideoError.invalid("旧版备份源文件超过300MiB上限") }; total+=bytes.count
                    entries.append(.init(kind: kind, path: path, bytes: bytes.count, sha256: Codec.hash(bytes)))
                }
            }
            guard entries.allSatisfy({ StreamingBackupRules.validPath($0) }) else { throw VideoError.invalid("旧版备份文件路径或扩展名无效") }
            try StreamingBackupArchive.validateReferences(state, entries: entries)
            try Self.verifyModelSceneSources(in: state) { asset in
                guard let bytes=value.assets[asset.relativePath] else { throw VideoError.invalid("旧版备份缺少模型原件") }; return bytes
            }
            _=try VisualCacheBackup.validate(value.visualCache, availableBytes: 300 * 1024 * 1024-total)
            return try streamingSemanticDigest(state: state, entries: entries)
        }
        let archive=try StreamingBackupArchive(input: input)
        try archive.consumeFiles(); try archive.verifyModels()
        return try streamingSemanticDigest(state: archive.state, entries: archive.manifest.entries)
    }
    private static func streamingSemanticDigest(state: Database, entries: [StreamingBackupRules.Entry]) throws -> String {
        var snapshot=state; snapshot.generation=0; snapshot.providers=[]
        struct Fingerprint: Encodable { var snapshot: Database; var assets: [String: String]; var exports: [String: String] }
        let assets=Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == "assets" }.map { ($0.path, $0.sha256) })
        let exports=Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == "exports" }.map { ($0.path, $0.sha256) })
        return try Codec.digest(Fingerprint(snapshot: snapshot, assets: assets, exports: exports))
    }
}
