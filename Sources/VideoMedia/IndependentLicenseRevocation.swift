import Foundation
import CoreFoundation
import Darwin
import VideoCore

/// Same-ID, publisher-signed revocations. This is a denial history, never an entitlement
/// issuer or a StoreKit converter. It is outside workspaces and portable business backups.
public struct IndependentLicenseRevocationStore: Sendable {
    public static let abi = 1
    static let stateName = "revocations.plist"
    static let lockName = "revocations.lock"
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumRecords = 1024
    private let root: URL
    private let publicKey: Data
    private struct State: Codable {
        var format = 1
        var publisherKeySHA256: String
        var records: [String: SignedDocument]
    }
    /// Internal for isolated rules only. Runtime exposes no state-root flag or environment override.
    init(root: URL, publicKey: Data) throws {
        guard root.isFileURL, publicKey.count == 32 else { throw VideoError.invalid("撤销历史位置或公钥无效") }
        self.root = root.standardizedFileURL; self.publicKey = publicKey
    }
    public static func production(publicKey: Data) throws -> Self {
        // getpwuid selects the actual OS user, not a caller-controlled HOME environment.
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            throw VideoError.unavailable("无法确定当前系统用户的独立权益历史；未授权")
        }
        let home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        guard home.path.hasPrefix("/"), home.path != "/" else { throw VideoError.permission("系统用户目录不合法") }
        return try Self(root: home.appendingPathComponent("Library/Application Support/com.ayqy.video.advanced/independent-license-revocations", isDirectory: true), publicKey: publicKey)
    }
    public static func revoking(_ original: SignedDocument, publicKey: Data, now: Date = Date()) throws -> ModuleLicense {
        var value = try original.verified(as: ModuleLicense.self, publicKey: publicKey)
        try value.validateStructure(now: now)
        guard !value.revoked else { throw VideoError.conflict("此签名许可证已经是撤销记录；未换发新身份") }
        value.revoked = true
        return value
    }
    private func verifiedRevocation(_ signed: SignedDocument, now: Date) throws -> ModuleLicense {
        let value = try signed.verified(as: ModuleLicense.self, publicKey: publicKey)
        try value.validateStructure(now: now)
        guard value.revoked else { throw VideoError.permission("只接受原发行者签名的撤销记录；普通许可不能写入撤销历史") }
        return value
    }
    /// Read-only. A missing, never-created directory means no observed revocation. Once
    /// initialized, a missing/corrupt state or lock is an error and is never reset to empty.
    public func hasRevocations() throws -> Bool { try withLock(create: false) { !($0?.records.isEmpty ?? true) } }
    public func check(_ license: ModuleLicense, now: Date = Date()) throws {
        try license.validate(now: now)
        try withLock(create: false) { state in
            guard state?.records[Codec.hash(Data(license.id.utf8))] == nil else {
                throw VideoError.permission("此独立许可证ID已观察到受信撤销；旧封套、旧工程或新进程不能恢复该ID")
            }
        }
    }
    public func validateImport(_ signed: SignedDocument, now: Date = Date()) throws {
        _ = try verifiedRevocation(signed, now: now)
        _ = try hasRevocations()
    }
    /// Exclusive union, not replacement. Re-import is idempotent; issuing another ID never
    /// removes a tombstone. At the bound, fail closed instead of evicting prior revocations.
    public func remember(_ signed: SignedDocument, now: Date = Date()) throws {
        let value = try verifiedRevocation(signed, now: now)
        try withLock(create: true) { previous in
            var state = previous ?? State(publisherKeySHA256: Codec.hash(publicKey), records: [:])
            let id = Codec.hash(Data(value.id.utf8))
            if state.records[id] != nil { return }
            guard state.records.count < Self.maximumRecords else { throw VideoError.unavailable("撤销历史已达到安全上限；未移除旧撤销或授予权益") }
            state.records[id] = signed
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let bytes = try encoder.encode(state)
            guard bytes.count <= Self.maximumBytes else { throw VideoError.unavailable("撤销历史超出大小限制；原历史保留") }
            try atomicWrite(bytes)
        }
    }
    private func directoryExists() throws -> Bool {
        try ManagedReleaseRules.safeDirectory(root)
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT else { throw VideoError.permission("无法检查独立撤销历史目录；未授权") }
            return false
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw VideoError.permission("独立撤销历史目录须由当前用户独占且不能是链接")
        }
        return true
    }
    private func withLock<T>(create: Bool, _ action: (State?) throws -> T) throws -> T {
        var created = false
        if try !directoryExists() {
            guard create else { return try action(nil) }
            let parent = root.deletingLastPathComponent()
            try ManagedReleaseRules.safeDirectory(parent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if mkdir(root.path, 0o700) == 0 { created = true }
            else if errno != EEXIST { throw VideoError.unavailable("无法建立独立撤销历史目录；未授权") }
            guard try directoryExists() else { throw VideoError.permission("撤销历史目录建立后丢失") }
        }
        let lock = root.appendingPathComponent(Self.lockName)
        let descriptor = open(lock.path, (create ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | (created ? O_CREAT | O_EXCL : 0), S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VideoError.permission("独立撤销历史锁缺失或不可读取；未重置历史") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw VideoError.permission("撤销历史锁不是受保护的普通文件") }
        guard flock(descriptor, (create ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            throw VideoError.unavailable("独立撤销历史正由另一进程使用；未绕过撤销检查")
        }
        defer { flock(descriptor, LOCK_UN) }
        let state = created ? nil : try readState()
        return try action(state)
    }
    private func readState() throws -> State {
        let file = root.appendingPathComponent(Self.stateName)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw VideoError.permission("已初始化撤销历史缺失；未重建空历史") }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_uid == getuid(), before.st_mode & 0o777 == 0o600, before.st_size > 0,
              before.st_size <= Self.maximumBytes else { throw VideoError.permission("撤销历史不是受保护的有限普通文件") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, bytes.count == before.st_size, before.st_size == after.st_size,
              before.st_ino == after.st_ino, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw VideoError.permission("撤销历史读取期间改变；未授权") }
        guard bytes.starts(with: Data("bplist00".utf8)),
              let object = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              Set(object.keys) == ["format", "publisherKeySHA256", "records"],
              let records = object["records"] as? [String: Any], !records.isEmpty, records.count <= Self.maximumRecords,
              records.values.allSatisfy({ ($0 as? [String: Any]).map { Set($0.keys) == ["payload", "signature"] } ?? false }) else {
            throw VideoError.permission("撤销历史封套结构不合法；未重置历史")
        }
        let state = try PropertyListDecoder().decode(State.self, from: bytes)
        guard state.format == 1, state.publisherKeySHA256 == Codec.hash(publicKey) else { throw VideoError.permission("撤销历史版本或固定发行者不符") }
        for (id, signed) in state.records {
            let value = try verifiedRevocation(signed, now: Date())
            guard id == Codec.hash(Data(value.id.utf8)) else { throw VideoError.permission("撤销历史索引与已签许可证ID不一致") }
        }
        return state
    }
    private func atomicWrite(_ data: Data) throws {
        let temporary = root.appendingPathComponent(".revocation-stage-" + Codec.id())
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VideoError.unavailable("无法建立撤销历史候选文件；原历史保留") }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data); try handle.synchronize()
        try ManagedReleaseRules.safeDirectory(root)
        guard rename(temporary.path, root.appendingPathComponent(Self.stateName).path) == 0 else { throw VideoError.unavailable("撤销历史原子替换失败；原历史保留") }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw VideoError.unavailable("撤销历史目录无法同步；不能报告导入成功") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw VideoError.unavailable("撤销历史目录同步失败；请核对原导入状态") }
    }
}

/// Candidate ABI is a compatibility requirement only, never proof of purchase. A new
/// managed installer refuses an old Host that would ignore already observed revocations.
public enum IndependentLicenseRevocationABI {
    public static let field = "independent_license_revocation_abi"
    public static func validate(_ value: Any?, required: Bool) throws {
        guard required else { return }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)),
              number.intValue == IndependentLicenseRevocationStore.abi else {
            throw VideoError.permission("候选高级Host不支持当前独立许可撤销ABI；保留当前安装和撤销历史")
        }
    }
}
