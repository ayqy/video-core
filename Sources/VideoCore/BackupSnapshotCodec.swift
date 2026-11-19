import Foundation
import Compression
import CZlib

/// A portable backup's JSON snapshot may be compressed without changing the
/// online SQLite snapshot, its digest, any revision, or the source-file budget.
/// COMPRESSION_ZLIB uses the RFC 1951 raw DEFLATE format (no zlib/gzip wrapper).
public enum BackupSnapshotCodec {
    public static let encoding = "deflate-raw-v1"
    public static let maximumSnapshotBytes = 350 * 1024 * 1024
    public static let minimumCompressionBytes = 1024 * 1024
    private static let chunkBytes = 64 * 1024

    public static func compress(_ snapshot: Data) throws -> Data {
        try process(snapshot, operation: COMPRESSION_STREAM_ENCODE,
                    maximumOutputBytes: maximumSnapshotBytes, expectedOutputBytes: nil)
    }

    public static func decode(version: Int, snapshot: Data, encoding: String?,
                              snapshotBytes: Int?, digest: String) throws -> Data {
        let decoded: Data
        switch version {
        case 1, 2:
            guard encoding == nil, snapshotBytes == nil, !snapshot.isEmpty,
                  snapshot.count <= maximumSnapshotBytes else {
                throw VideoError.invalid("旧版备份快照格式或大小无效")
            }
            decoded = snapshot
        case 3:
            guard encoding == Self.encoding, let count = snapshotBytes,
                  count > 0, count <= maximumSnapshotBytes else {
                throw VideoError.invalid("压缩备份快照编码或展开长度无效")
            }
            decoded = try inflateExactly(snapshot, expectedBytes: count)
        default:
            throw VideoError.invalid("备份版本不支持")
        }
        guard Codec.hash(decoded) == digest else {
            throw VideoError.invalid("备份快照完整性校验失败")
        }
        return decoded
    }

    /// Apple's Compression decoder can consume bytes after a raw DEFLATE end.
    /// zlib exposes the exact unused byte count, so a second stream or trailing
    /// data cannot be silently accepted as the declared original snapshot.
    private static func inflateExactly(_ input: Data, expectedBytes: Int) throws -> Data {
        guard !input.isEmpty, input.count <= maximumSnapshotBytes else {
            throw VideoError.invalid("备份快照流为空或超过有界读取上限")
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw VideoError.unavailable("无法初始化备份快照解压流")
        }
        defer { inflateEnd(&stream) }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkBytes)
        defer { destination.deallocate() }
        return try input.withUnsafeBytes { source -> Data in
            guard let address = source.bindMemory(to: UInt8.self).baseAddress else {
                throw VideoError.invalid("备份快照流缺少输入")
            }
            stream.next_in = UnsafeMutablePointer(mutating: address)
            stream.avail_in = uInt(source.count)
            var output = Data()
            while true {
                try Task.checkCancellation()
                let remainingBefore = stream.avail_in
                stream.next_out = destination
                stream.avail_out = uInt(chunkBytes)
                let status = inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw VideoError.invalid("备份快照压缩流损坏或被截断")
                }
                let count = chunkBytes - Int(stream.avail_out)
                guard count <= expectedBytes - output.count else {
                    throw VideoError.invalid("备份快照展开超过声明长度或350MiB上限")
                }
                output.append(destination, count: count)
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, output.count == expectedBytes else {
                        throw VideoError.invalid("备份快照流尾部或展开长度不符")
                    }
                    return output
                }
                guard count > 0 || stream.avail_in < remainingBefore else {
                    throw VideoError.invalid("备份快照压缩流未完整结束")
                }
            }
        }
    }

    private static func process(_ input: Data, operation: compression_stream_operation,
                                maximumOutputBytes: Int, expectedOutputBytes: Int?) throws -> Data {
        guard !input.isEmpty, input.count <= maximumSnapshotBytes,
              maximumOutputBytes > 0, maximumOutputBytes <= maximumSnapshotBytes else {
            throw VideoError.invalid("备份快照流为空或超过有界读取上限")
        }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkBytes)
        defer { destination.deallocate() }
        // The SDK imports this C struct without a zero-argument initializer.
        // Non-null placeholders carry zero sizes and are never read or written.
        var stream = compression_stream(dst_ptr: destination, dst_size: 0,
            src_ptr: UnsafePointer(destination), src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw VideoError.unavailable("无法初始化备份快照压缩流")
        }
        defer { compression_stream_destroy(&stream) }
        return try input.withUnsafeBytes { source -> Data in
            guard let address = source.bindMemory(to: UInt8.self).baseAddress else {
                throw VideoError.invalid("备份快照流缺少输入")
            }
            stream.src_ptr = address
            stream.src_size = source.count
            var output = Data()
            while true {
                let remainingBefore = stream.src_size
                stream.dst_ptr = destination
                stream.dst_size = chunkBytes
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw VideoError.invalid("备份快照压缩流损坏或被截断")
                }
                let count = chunkBytes - stream.dst_size
                guard count <= maximumOutputBytes - output.count else {
                    throw VideoError.invalid("备份快照展开超过声明长度或350MiB上限")
                }
                output.append(destination, count: count)
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0,
                          expectedOutputBytes.map({ output.count == $0 }) ?? true else {
                        throw VideoError.invalid("备份快照流尾部或展开长度不符")
                    }
                    return output
                }
                guard count > 0 || stream.src_size < remainingBefore else {
                    throw VideoError.invalid("备份快照压缩流未完整结束")
                }
            }
        }
    }
}
