import Foundation

/// Storage-only structural sharing. Public IR encoding and revision digests
/// always use the ordinary Codec, without either of these private contexts.
enum RepositorySnapshotCodec {
    static let encoding = "model-array-pool-v1"
    static let writerKey = CodingUserInfoKey(rawValue: "video.repository.model-array-writer")!
    static let readerKey = CodingUserInfoKey(rawValue: "video.repository.model-array-reader")!
    private static let inputBytesKey = CodingUserInfoKey(rawValue: "video.repository.snapshot-input-bytes")!

    static func digest(_ bytes: Data, kind: String) -> String {
        Codec.hash(Data((encoding + "\0" + kind + "\0").utf8) + bytes)
    }
    static func encode(_ state: Database) throws -> Data {
        guard state.schema == 1 else { throw VideoError.unavailable("工程存储版本不支持") }
        let writer = SnapshotModelArrayWriter(), encoder = Codec.encoder()
        encoder.userInfo[writerKey] = writer
        var bytes = try encoder.encode(Envelope(state: state, writer: writer))
        if !writer.isEmpty, !(try writer.hasStorageBenefit()) { bytes = try Codec.data(state) }
        guard !bytes.isEmpty, bytes.count <= BackupSnapshotCodec.maximumStreamingSnapshotBytes else {
            throw VideoError.invalid("工程JSON快照超过1000000000字节安全上限")
        }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Database {
        guard !bytes.isEmpty, bytes.count <= BackupSnapshotCodec.maximumStreamingSnapshotBytes else {
            throw VideoError.invalid("工程JSON快照超过1000000000字节安全上限")
        }
        let decoder = Codec.decoder()
        let header = try decoder.decode(Header.self, from: bytes)
        if header.schema == 1 {
            guard !header.hasEncoding, !header.hasPool else { throw VideoError.invalid("旧存储不能携带共享数组标记") }
            return try decoder.decode(Database.self, from: bytes)
        }
        guard header.schema == 2, header.encoding == encoding, header.hasPool else {
            throw VideoError.unavailable("工程共享存储版本不支持，请保留原文件")
        }
        decoder.userInfo[inputBytesKey] = bytes.count
        let pool = try decoder.decode(PoolEnvelope.self, from: bytes).modelArrayPool
        let reader = try SnapshotModelArrayReader(pool: pool, inputBytes: bytes.count)
        decoder.userInfo[readerKey] = reader
        var state = try decoder.decode(Database.self, from: bytes)
        try reader.finish()
        state.schema = 1
        return state
    }

    private enum Keys: String, CodingKey { case schema, repositoryEncoding, modelArrayPool }
    private struct Header: Decodable {
        let schema: Int; let encoding: String?; let hasEncoding: Bool; let hasPool: Bool
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            schema = try c.decode(Int.self, forKey: .schema)
            hasEncoding = c.contains(.repositoryEncoding); hasPool = c.contains(.modelArrayPool)
            encoding = try c.decodeIfPresent(String.self, forKey: .repositoryEncoding)
        }
    }
    private struct PoolEnvelope: Decodable { let modelArrayPool: SnapshotModelArrayPool }
    private struct Envelope: Encodable {
        let state: Database; let writer: SnapshotModelArrayWriter
        func encode(to encoder: Encoder) throws {
            // Keyed containers on the same encoder share one object. Encode the
            // business fields first so collecting arrays finishes before pool.
            try state.encode(to: encoder)
            guard !writer.isEmpty else { return }
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(2, forKey: .schema)
            try c.encode(RepositorySnapshotCodec.encoding, forKey: .repositoryEncoding)
            try c.encode(writer.pool(), forKey: .modelArrayPool)
        }
    }

    fileprivate static func inputBytes(_ decoder: Decoder) throws -> Int {
        guard let count = decoder.userInfo[inputBytesKey] as? Int, count > 0,
              count <= BackupSnapshotCodec.maximumStreamingSnapshotBytes else {
            throw VideoError.invalid("共享数组只能从有界工程快照读取")
        }
        return count
    }
}

struct SnapshotModelArrayReference: Codable {
    let ref: String
    init(ref: String) { self.ref = ref }
    private enum Keys: String, CodingKey { case ref }
    init(from decoder: Decoder) throws {
        try ModelStoryDecoding3D.keys(decoder, required: ["ref"], optional: [])
        ref = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .ref)
        guard PluginProtocolRules.hash(ref) else { throw VideoError.invalid("共享数组引用摘要无效") }
    }
}

fileprivate protocol SnapshotArrayMember: Codable {
    static var snapshotKind: String { get }
    static var snapshotMinimumCount: Int { get }
    static var snapshotMaximumCount: Int { get }
}
extension SnapshotArrayMember { fileprivate static var snapshotMinimumCount: Int { 0 } }
extension ModelInstance3D: SnapshotArrayMember {
    fileprivate static var snapshotKind: String { "instances" }
    fileprivate static var snapshotMinimumCount: Int { 1 }
    fileprivate static var snapshotMaximumCount: Int { 128 }
}
extension ModelTransformTrack: SnapshotArrayMember {
    fileprivate static var snapshotKind: String { "transformTracks" }
    fileprivate static var snapshotMaximumCount: Int { 128 }
}
extension ModelJointTrack: SnapshotArrayMember {
    fileprivate static var snapshotKind: String { "jointTracks" }
    fileprivate static var snapshotMaximumCount: Int { 4096 }
}

fileprivate struct SnapshotArrayEntry<Element: SnapshotArrayMember>: Codable {
    let digest: String; let json: Data; let value: [Element]
    init(_ value: [Element]) throws {
        guard (Element.snapshotMinimumCount...Element.snapshotMaximumCount).contains(value.count) else { throw VideoError.invalid("共享数组超过原三维数量范围") }
        self.value = value; json = try Codec.data(value)
        digest = RepositorySnapshotCodec.digest(json, kind: Element.snapshotKind)
    }
    private enum Keys: String, CodingKey { case digest, json }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(digest, forKey: .digest); try c.encode(json, forKey: .json)
    }
    init(from decoder: Decoder) throws {
        try ModelStoryDecoding3D.keys(decoder, required: ["digest", "json"], optional: [])
        let c = try decoder.container(keyedBy: Keys.self), inputBytes = try RepositorySnapshotCodec.inputBytes(decoder)
        digest = try c.decode(String.self, forKey: .digest); json = try c.decode(Data.self, forKey: .json)
        guard !json.isEmpty, json.count <= inputBytes, PluginProtocolRules.hash(digest),
              RepositorySnapshotCodec.digest(json, kind: Element.snapshotKind) == digest else {
            throw VideoError.invalid("共享数组原字节或分域摘要不符")
        }
        // An entry is an ordinary strong-typed array, never another reference.
        // Check its original element budget before constructing its elements.
        let arrayDecoder = Codec.decoder()
        arrayDecoder.userInfo[RepositorySnapshotCodec.readerKey] = SnapshotArrayCountLimit(minimum: Element.snapshotMinimumCount, maximum: Element.snapshotMaximumCount)
        value = try arrayDecoder.decode(BoundedSnapshotArray<Element>.self, from: json).value
        guard try Codec.data(value) == json else { throw VideoError.invalid("共享数组不是原规范强类型JSON字节") }
    }
}
private struct SnapshotArrayCountLimit { let minimum: Int; let maximum: Int }
private struct BoundedSnapshotArray<Element: Decodable>: Decodable {
    let value: [Element]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        guard let limit = decoder.userInfo[RepositorySnapshotCodec.readerKey] as? SnapshotArrayCountLimit,
              let count = c.count, (limit.minimum...limit.maximum).contains(count) else { throw VideoError.invalid("共享数组超过原三维数量范围") }
        var result: [Element] = []; result.reserveCapacity(count)
        while !c.isAtEnd { result.append(try c.decode(Element.self)) }
        value = result
    }
}

fileprivate struct SnapshotModelArrayPool: Codable {
    let instances: [SnapshotArrayEntry<ModelInstance3D>]
    let transformTracks: [SnapshotArrayEntry<ModelTransformTrack>]
    let jointTracks: [SnapshotArrayEntry<ModelJointTrack>]
    private enum Keys: String, CodingKey { case instances, transformTracks, jointTracks }
    init(instances: [SnapshotArrayEntry<ModelInstance3D>], transformTracks: [SnapshotArrayEntry<ModelTransformTrack>], jointTracks: [SnapshotArrayEntry<ModelJointTrack>]) {
        self.instances = instances; self.transformTracks = transformTracks; self.jointTracks = jointTracks
    }
    init(from decoder: Decoder) throws {
        try ModelStoryDecoding3D.keys(decoder, required: ["instances", "transformTracks", "jointTracks"], optional: [])
        let c = try decoder.container(keyedBy: Keys.self)
        instances = try c.decode([SnapshotArrayEntry<ModelInstance3D>].self, forKey: .instances)
        transformTracks = try c.decode([SnapshotArrayEntry<ModelTransformTrack>].self, forKey: .transformTracks)
        jointTracks = try c.decode([SnapshotArrayEntry<ModelJointTrack>].self, forKey: .jointTracks)
    }
}

final class SnapshotModelArrayWriter {
    private var instances: [String: SnapshotArrayEntry<ModelInstance3D>] = [:]
    private var transformTracks: [String: SnapshotArrayEntry<ModelTransformTrack>] = [:]
    private var jointTracks: [String: SnapshotArrayEntry<ModelJointTrack>] = [:]
    private var replacementSavings = 0; private var hasDuplicate = false
    var isEmpty: Bool { instances.isEmpty && transformTracks.isEmpty && jointTracks.isEmpty }
    func reference(_ value: [ModelInstance3D]) throws -> SnapshotModelArrayReference {
        let entry = try SnapshotArrayEntry(value)
        if let prior = instances[entry.digest] {
            guard prior.json == entry.json else { throw VideoError.invalid("实例共享摘要对应不同原字节") }; hasDuplicate = true
        } else { instances[entry.digest] = entry }
        try account(entry.json, digest: entry.digest)
        return SnapshotModelArrayReference(ref: entry.digest)
    }
    func reference(_ value: [ModelTransformTrack]) throws -> SnapshotModelArrayReference {
        let entry = try SnapshotArrayEntry(value)
        if let prior = transformTracks[entry.digest] {
            guard prior.json == entry.json else { throw VideoError.invalid("位移轨道共享摘要对应不同原字节") }; hasDuplicate = true
        } else { transformTracks[entry.digest] = entry }
        try account(entry.json, digest: entry.digest)
        return SnapshotModelArrayReference(ref: entry.digest)
    }
    func reference(_ value: [ModelJointTrack]) throws -> SnapshotModelArrayReference {
        let entry = try SnapshotArrayEntry(value)
        if let prior = jointTracks[entry.digest] {
            guard prior.json == entry.json else { throw VideoError.invalid("骨骼轨道共享摘要对应不同原字节") }; hasDuplicate = true
        } else { jointTracks[entry.digest] = entry }
        try account(entry.json, digest: entry.digest)
        return SnapshotModelArrayReference(ref: entry.digest)
    }
    private func account(_ original: Data, digest: String) throws {
        let referenceBytes = try Codec.data(SnapshotModelArrayReference(ref: digest)).count
        let (sum, overflow) = replacementSavings.addingReportingOverflow(original.count - referenceBytes)
        guard !overflow else { throw VideoError.invalid("共享数组表示长度溢出") }
        replacementSavings = sum
    }
    fileprivate func hasStorageBenefit() throws -> Bool {
        // The schema digit has the same byte width. These are precisely the
        // two additional sorted JSON fields, including their leading commas.
        let metadataBytes = Data(",\"repositoryEncoding\":\"model-array-pool-v1\",\"modelArrayPool\":".utf8).count + (try Codec.data(pool()).count)
        return hasDuplicate && replacementSavings > metadataBytes
    }
    fileprivate func pool() -> SnapshotModelArrayPool {
        SnapshotModelArrayPool(instances: instances.values.sorted { $0.digest < $1.digest },
            transformTracks: transformTracks.values.sorted { $0.digest < $1.digest },
            jointTracks: jointTracks.values.sorted { $0.digest < $1.digest })
    }
}

final class SnapshotModelArrayReader {
    private let instances: [String: [ModelInstance3D]]
    private let transformTracks: [String: [ModelTransformTrack]]
    private let jointTracks: [String: [ModelJointTrack]]
    private var usedInstances = Set<String>(), usedTransformTracks = Set<String>(), usedJointTracks = Set<String>()
    private let maximumReferences: Int; private var references = 0
    fileprivate init(pool: SnapshotModelArrayPool, inputBytes: Int) throws {
        func table<T: SnapshotArrayMember>(_ entries: [SnapshotArrayEntry<T>]) throws -> [String: [T]] {
            guard Set(entries.map(\.digest)).count == entries.count else { throw VideoError.invalid("共享数组池存在重复条目") }
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.digest, $0.value) })
        }
        instances = try table(pool.instances); transformTracks = try table(pool.transformTracks); jointTracks = try table(pool.jointTracks)
        // Every on-disk reference contains at least one 64-byte digest. This
        // bound comes from the already bounded input, not a larger scene budget.
        maximumReferences = inputBytes / 64
    }
    private func countReference() throws {
        guard references < maximumReferences else { throw VideoError.invalid("共享数组引用数超过有界原输入") }
        references += 1
    }
    func resolveInstances(_ ref: SnapshotModelArrayReference) throws -> [ModelInstance3D] {
        try countReference(); guard let value = instances[ref.ref] else { throw VideoError.invalid("实例数组引用缺失或类型不符") }
        usedInstances.insert(ref.ref); return value
    }
    func resolveTransformTracks(_ ref: SnapshotModelArrayReference) throws -> [ModelTransformTrack] {
        try countReference(); guard let value = transformTracks[ref.ref] else { throw VideoError.invalid("位移轨道数组引用缺失或类型不符") }
        usedTransformTracks.insert(ref.ref); return value
    }
    func resolveJointTracks(_ ref: SnapshotModelArrayReference) throws -> [ModelJointTrack] {
        try countReference(); guard let value = jointTracks[ref.ref] else { throw VideoError.invalid("骨骼轨道数组引用缺失或类型不符") }
        usedJointTracks.insert(ref.ref); return value
    }
    func finish() throws {
        guard usedInstances == Set(instances.keys), usedTransformTracks == Set(transformTracks.keys),
              usedJointTracks == Set(jointTracks.keys), references > 0 else { throw VideoError.invalid("共享数组池含孤立条目或没有真实引用") }
    }
}
