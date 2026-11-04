import Foundation
import ImageIO
import SceneKit
import Darwin
#if canImport(FoundationXML)
import FoundationXML
#endif
import VideoCore

/// An explicit original PNG selection. Source paths are used only while importing;
/// the stored resource keeps the DAE's alias and the actual content-addressed bytes.
public struct ModelTextureBinding: Sendable {
    public let url: URL
    public let sha256: String
    public init(url: URL, sha256: String) { self.url = url; self.sha256 = sha256 }
}

public struct ImportedModelPackage {
    public let resource: ModelDAEResource
    public let assets: [Asset]
}

/// Imports the original model and its exact texture closure. The caller saves
/// these returned assets in its normal database transaction and records rights.
public enum ModelPackageMedia {
    public static func importPackage(modelURL: URL, sourceRoot: URL, workspaceID: String, repository: Repository,
                                     textureBindings: [String: ModelTextureBinding] = [:]) throws -> ImportedModelPackage {
        let root = sourceRoot.standardizedFileURL
        guard !workspaceID.isEmpty, modelURL.pathExtension.lowercased() == "dae" else { throw VideoError.invalid("模型导入需要实际 DAE 与工作区") }
        let original = try bytes(modelURL, within: root, maximum: DAEInspector.maximumBytes)
        let inspection = try DAEInspector.inspect(original)
        let declared = Set(inspection.images.map(\.relativePath))
        for (alias, binding) in textureBindings {
            guard try DAEInspector.relativeTexturePath(alias) == alias, declared.contains(alias), PluginProtocolRules.hash(binding.sha256) else {
                throw VideoError.invalid("显式纹理绑定须使用实际DAE声明的规范别名及预定SHA256")
            }
        }
        var textures: [String: Data] = [:]
        var total = original.count
        for image in inspection.images {
            let alias = try DAEInspector.relativeTexturePath(image.relativePath)
            if textures[alias] != nil { continue }
            let binding = textureBindings[alias]
            let selected = binding?.url ?? modelURL.deletingLastPathComponent().appendingPathComponent(alias)
            // An explicit selection never falls back to a same-named local or
            // library file when missing or mismatched.
            let data = try bytes(selected, within: root, maximum: 32 * 1024 * 1024, sha256: binding?.sha256)
            try validatePNG(data)
            total += data.count
            guard total <= 128 * 1024 * 1024 else { throw VideoError.invalid("单个模型及其纹理超过128MiB") }
            textures[alias] = data
        }
        // All source validation and known existing CAS conflicts fail before the
        // first ingest. This is not a crash-atomic batch storage transaction.
        var planned: [String: Data] = [Codec.hash(original) + ".dae": original]
        for data in textures.values { planned[Codec.hash(data) + ".png"] = data }
        for filename in planned.keys.sorted() {
            let data = planned[filename]!
            _ = try readBytes(repository.root.appendingPathComponent("assets").appendingPathComponent(filename),
                within: repository.root, maximum: data.count, sha256: Codec.hash(data), expectedBytes: data.count, missingAllowed: true)
        }
        let model = try repository.ingest(original, name: modelURL.lastPathComponent, workspaceID: workspaceID, mediaType: "model3d")
        var assets = [model], references: [String: ModelAssetReference] = [:]
        for alias in textures.keys.sorted() {
            let asset = try repository.ingest(textures[alias]!, name: URL(fileURLWithPath: alias).lastPathComponent, workspaceID: workspaceID, mediaType: "image")
            assets.append(asset); references[alias] = ModelAssetReference(asset: asset)
        }
        let resource = ModelDAEResource(model: ModelAssetReference(asset: model), inspection: inspection, textures: references)
        try resource.validate(assets: assets)
        return ImportedModelPackage(resource: resource, assets: assets)
    }

    public static func load(_ resource: ModelDAEResource, workspaceID: String, repository: Repository, database: Database, commercial: Bool, now: Date = Date()) throws -> LoadedDAEModel {
        let bank = try verifiedByteClosure(resource, workspaceID: workspaceID, repository: repository,
            database: database, commercial: commercial, now: now)
        return try loadByteClosure(resource, assets: bank)
    }

    /// Host-side byte freezing, before any plugin invocation exists. Uses the
    /// same workspace, current source rights and no-follow CAS checks as load.
    public static func verifiedByteClosure(_ resource: ModelDAEResource, workspaceID: String,
        repository: Repository, database: Database, commercial: Bool, now: Date = Date(),
        cancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [String: Data] {
        try cancellation()
        guard !workspaceID.isEmpty else { throw VideoError.permission("三维原件读取需要明确工作区") }
        let assets = database.assets.filter { $0.workspaceID == workspaceID }
        try resource.validate(assets: assets)
        var bank: [String: Data] = [:]
        var total = 0
        for id in resource.assetIDs.sorted() {
            try cancellation()
            guard let asset = assets.first(where: { $0.id == id }), let proofID = asset.evidenceID,
                  let proof = database.evidence.first(where: { $0.id == proofID && $0.workspaceID == workspaceID }),
                  proof.assetID == id, proof.usable(commercial: commercial, now: now) else {
                throw VideoError.review("模型或纹理缺少本工作区有效来源确认")
            }
            let maximum = asset.ext == "dae" ? DAEInspector.maximumBytes : 32 * 1024 * 1024
            let data = try bytes(repository.assetURL(asset), within: repository.root, maximum: maximum,
                sha256: asset.hash, expectedBytes: asset.bytes)
            total += data.count
            guard total <= 128 * 1024 * 1024 else { throw VideoError.invalid("单个三维原件闭包超过128MiB") }
            bank[id] = data
        }
        try verifyByteClosure(resource, assets: bank, cancellation: cancellation)
        return bank
    }

    /// Technical decoding of a previously frozen byte bank. This verifies the
    /// complete original resource identity but creates no Evidence, database,
    /// filesystem permission, source-right approval or media-review approval.
    public static func loadByteClosure(_ resource: ModelDAEResource, assets: [String: Data],
        cancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> LoadedDAEModel {
        let (model, textures) = try verifyByteClosure(resource, assets: assets, cancellation: cancellation)
        let loaded = try LoadedDAEModel(resource: resource, modelData: model, textureData: textures)
        try cancellation()
        return loaded
    }

    @discardableResult private static func verifyByteClosure(_ resource: ModelDAEResource, assets: [String: Data],
        cancellation: () throws -> Void) throws -> (Data, [String: Data]) {
        try cancellation(); try resource.validate()
        var selected: [String: Data] = [:], total = 0
        for reference in [resource.model] + Array(resource.textures.values) {
            try cancellation()
            if selected[reference.assetID] != nil { continue }
            guard let data = assets[reference.assetID], data.count == reference.bytes,
                  Codec.hash(data) == reference.sha256 else {
                throw VideoError.review("三维冻结字节不符合原件摘要或长度")
            }
            total += data.count
            guard total <= 128 * 1024 * 1024 else { throw VideoError.invalid("单个三维原件闭包超过128MiB") }
            selected[reference.assetID] = data
        }
        guard let model = selected.removeValue(forKey: resource.model.assetID) else { throw VideoError.notFound("冻结字节库缺少原DAE") }
        try resource.verify(modelData: model, textureDataByAssetID: selected)
        for data in selected.values { try cancellation(); try validatePNG(data) }
        try cancellation()
        return (model, selected)
    }

    static func bytes(_ url: URL, within root: URL, maximum: Int, sha256: String? = nil, expectedBytes: Int? = nil) throws -> Data {
        guard let result = try readBytes(url, within: root, maximum: maximum, sha256: sha256,
                                        expectedBytes: expectedBytes, missingAllowed: false) else {
            throw VideoError.notFound("模型或纹理文件缺失")
        }
        return result
    }

    /// Read relative to the caller-selected physical root, not from the system
    /// root. NOFOLLOW applies to every child and NONBLOCK makes FIFO rejection
    /// reach fstat. Only a missing planned CAS path is an allowed absence.
    private static func readBytes(_ url: URL, within requestedRoot: URL, maximum: Int,
                                  sha256: String?, expectedBytes: Int?, missingAllowed: Bool) throws -> Data? {
        let root = requestedRoot.standardizedFileURL, file = url.standardizedFileURL
        guard requestedRoot.isFileURL, url.isFileURL, (requestedRoot.host ?? "").isEmpty, (url.host ?? "").isEmpty,
              requestedRoot.query == nil, requestedRoot.fragment == nil, url.query == nil, url.fragment == nil, maximum > 0,
              root.resolvingSymlinksInPath() == root, root.path != "/",
              !root.path.contains("\0"), !file.path.contains("\0"), file.path.hasPrefix(root.path + "/"),
              sha256.map({ PluginProtocolRules.hash($0) }) ?? true else {
            throw VideoError.permission("三维素材必须是所选物理来源目录内的本地普通文件")
        }
        let parts = String(file.path.dropFirst(root.path.count + 1)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 96, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw VideoError.permission("模型或纹理相对来源路径无效")
        }
        let base = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw VideoError.permission("无法安全打开所选三维来源目录") }
        var directories = [base], links: [(parent: Int32, name: String, child: Int32)] = []
        defer { for descriptor in directories.reversed() { Darwin.close(descriptor) } }
        func verifyDirectories() throws {
            var opened = stat(), located = stat()
            guard fstat(base, &opened) == 0, lstat(root.path, &located) == 0,
                  (located.st_mode & S_IFMT) == S_IFDIR, opened.st_dev == located.st_dev, opened.st_ino == located.st_ino else {
                throw VideoError.conflict("所选三维来源目录在读取期间变化")
            }
            for link in links {
                guard fstat(link.child, &opened) == 0, fstatat(link.parent, link.name, &located, AT_SYMLINK_NOFOLLOW) == 0,
                      (located.st_mode & S_IFMT) == S_IFDIR, opened.st_dev == located.st_dev, opened.st_ino == located.st_ino else {
                    throw VideoError.conflict("模型或纹理来源父目录在读取期间变化")
                }
            }
        }
        var directory = base
        for part in parts.dropLast() {
            try Task.checkCancellation()
            let child = Darwin.openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0 {
                if missingAllowed && errno == ENOENT { try verifyDirectories(); return nil }
                throw VideoError.permission("模型或纹理父目录缺失、为链接或不可访问")
            }
            links.append((directory, part, child)); directories.append(child); directory = child
        }
        try Task.checkCancellation()
        let name = parts[parts.count - 1]
        let descriptor = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if missingAllowed && errno == ENOENT { try verifyDirectories(); return nil }
            throw VideoError.permission("模型或纹理文件缺失、为链接或不可访问")
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1 else {
            throw VideoError.permission("模型或纹理必须是独立普通文件")
        }
        guard before.st_size > 0, before.st_size <= maximum,
              expectedBytes.map({ before.st_size == $0 }) ?? true else { throw VideoError.invalid("模型或纹理文件为空、大小不符或超出上限") }
        let size = Int(before.st_size)
        var data = Data(), block = [UInt8](repeating: 0, count: 65_536)
        data.reserveCapacity(size)
        while true {
            try Task.checkCancellation()
            let count = block.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw VideoError.unavailable("读取三维来源实际字节失败") }
            if count == 0 { break }
            guard count <= size - data.count else { throw VideoError.conflict("模型或纹理读取期间大小变化") }
            data.append(contentsOf: block.prefix(count))
        }
        var after = stat(), located = stat()
        guard fstat(descriptor, &after) == 0, fstatat(directory, name, &located, AT_SYMLINK_NOFOLLOW) == 0,
              (located.st_mode & S_IFMT) == S_IFREG, located.st_nlink == 1,
              located.st_dev == before.st_dev, located.st_ino == before.st_ino, located.st_size == before.st_size,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_nlink == 1, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              located.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, located.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              located.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, located.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == size else { throw VideoError.conflict("模型或纹理实际来源在读取期间变化") }
        try verifyDirectories()
        guard sha256.map({ Codec.hash(data) == $0 }) ?? true else { throw VideoError.review("模型或纹理实际SHA256与预定原件不符") }
        return data
    }

    static func validatePNG(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(w), (1...8192).contains(h), w * h <= 24_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw VideoError.invalid("模型纹理不是可解码的有界单帧 PNG")
        }
    }
}

/// Keeps the private material directory alive for SceneKit's deferred textures.
/// It never receives arbitrary original filesystem URLs or a network grant.
public final class LoadedDAEModel {
    public let scene: SCNScene
    public let resource: ModelDAEResource
    /// Exact original material IDs to the actual objects used by scene meshes.
    /// Names remain as authored; unused source declarations have no native entry.
    public let materialsBySourceID: [String: [SCNMaterial]]
    private let directory: URL
    fileprivate init(resource: ModelDAEResource, modelData: Data, textureData: [String: Data]) throws {
        self.resource = resource
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("video-model-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for (alias, reference) in resource.textures {
                let target = directory.appendingPathComponent(alias)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try textureData[reference.assetID]!.write(to: target, options: .atomic)
            }
            let file = directory.appendingPathComponent("model.dae")
            try modelData.write(to: file, options: .atomic)
            // This runtime-only metadata projection gives otherwise unnamed
            // native materials their exact source ID. Stored/source bytes and
            // the authoritative inspection are never changed or written back.
            let runtimeData = try DAEMaterialNameProjection.data(modelData, inspection: resource.inspection)
            guard let source = SCNSceneSource(data: runtimeData, options: nil) else { throw VideoError.invalid("SceneKit无法读取实际DAE") }
            scene = try source.scene(options: [.checkConsistency: true, .assetDirectoryURLs: [directory], .overrideAssetURLs: true,
                .convertToYUp: true, .convertUnitsToMeters: 1.0, .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay])
            materialsBySourceID = try DAETextureAdapter.apply(to: scene, resource: resource, modelData: modelData, textureData: textureData)
            var geometries = 0
            scene.rootNode.enumerateChildNodes { node, _ in if node.geometry != nil { geometries += 1 } }
            guard geometries > 0 else { throw VideoError.invalid("DAE未加载出实际网格，不能用占位模型替代") }
        } catch {
            if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
    deinit { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
}

/// SceneKit does not retain material.id as SCNMaterial.name. Only a missing
/// material name is projected to that same ID for the native importer; this is
/// not an edited source model and never becomes the saved asset/inspection.
private enum DAEMaterialNameProjection {
    private final class Writer: NSObject, XMLParserDelegate {
        var output = Data(), path: [String] = [], expandedPath: [String] = [], namespaces: [[String: String]] = []
        var count = 0, additions = 0
        var failure: String?
        func fail(_ parser: XMLParser, _ message: String) { if failure == nil { failure = message }; parser.abortParsing() }
        func append(_ text: String, parser: XMLParser) {
            guard failure == nil, text.utf8.count <= DAEInspector.maximumBytes - output.count else { fail(parser, "临时材质名称投影超过DAE字节上限"); return }
            output.append(contentsOf: text.utf8)
        }
        func escaped(_ text: String, attribute: Bool = false) -> String {
            var result = text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\r", with: "&#13;")
            if attribute {
                result = result.replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "\t", with: "&#9;").replacingOccurrences(of: "\n", with: "&#10;")
            }
            return result
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard path.count < 96, count <= 200_000, attributes.count <= 32 else { fail(parser, "临时材质名称投影XML超出有界范围"); return }
            if count % 1024 == 0, Task.isCancelled { fail(parser, "临时材质名称投影已取消"); return }
            var environment = namespaces.last ?? [:]
            for (key, value) in attributes {
                if key == "xmlns" { environment[""] = value }
                else if key.hasPrefix("xmlns:") { environment[String(key.dropFirst(6))] = value }
            }
            let parts = name.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let local = parts.last else { fail(parser, "临时材质名称投影不支持无效XML限定名"); return }
            let prefix = parts.count == 2 ? String(parts[0]) : ""
            let qualified = (environment[prefix] ?? "") + "|" + String(local)
            let collada = "http://www.collada.org/2005/11/COLLADASchema|"
            var projected = attributes
            if expandedPath == [collada + "COLLADA", collada + "library_materials"],
               qualified == collada + "material", attributes["name"] == nil {
                guard let id = attributes["id"], !id.isEmpty, attributes.count < 32 else { fail(parser, "临时材质名称只能投影实际原material.id"); return }
                projected["name"] = id; additions += 1
            }
            path.append(name); expandedPath.append(qualified); namespaces.append(environment)
            append("<" + name, parser: parser)
            for key in projected.keys.sorted() { append(" " + key + "=\"" + escaped(projected[key]!, attribute: true) + "\"", parser: parser) }
            append(">", parser: parser)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard path.last == name else { fail(parser, "临时材质名称投影XML元素不平衡"); return }
            append("</" + name + ">", parser: parser); path.removeLast(); expandedPath.removeLast(); namespaces.removeLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { append(escaped(string), parser: parser) }
        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { append(escaped(whitespaceString), parser: parser) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { fail(parser, "临时材质名称投影CDATA不是UTF-8"); return }
            // Escaped character data has the same XML text semantics as CDATA.
            append(escaped(text), parser: parser)
        }
        func parser(_ parser: XMLParser, foundComment comment: String) { append("<!--" + comment + "-->", parser: parser) }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            fail(parser, "临时材质名称投影不支持可能含外部指向的处理指令")
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { fail(parser, "临时材质名称投影禁止外部实体"); return nil }
    }
    static func data(_ original: Data, inspection: DAEInspection) throws -> Data {
        try Task.checkCancellation()
        let writer = Writer(), parser = XMLParser(data: original)
        // Preserve original qualified element/attribute names and xmlns values.
        parser.shouldProcessNamespaces = false; parser.shouldResolveExternalEntities = false; parser.delegate = writer
        guard parser.parse(), writer.failure == nil, writer.path.isEmpty else { throw VideoError.invalid(writer.failure ?? "临时材质名称投影无法解析原XML") }
        try Task.checkCancellation()
        if writer.additions == 0 { return original }
        var projected = try DAEInspector.inspect(writer.output)
        projected.sha256 = inspection.sha256; projected.bytes = inspection.bytes
        guard projected == inspection else { throw VideoError.invalid("临时名称投影改变了原DAE几何、骨骼、材质引用或坐标声明") }
        return writer.output
    }
}

/// Resolve the original document's identities, never a filename search or an
/// independently instantiated SceneSource entry. Only actual scene materials
/// receive the exact verified image; constants and the lighting model survive.
private enum DAETextureAdapter {
    private final class Element {
        let name: String; let attributes: [String: String]
        var children: [Element] = []; var value = ""
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func named(_ name: String) -> [Element] { children.filter { $0.name == name } }
        func descendants(_ name: String) -> [Element] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
    }
    private final class Parser: NSObject, XMLParserDelegate {
        var roots: [Element] = [], primitives: [[Int]] = []
        var path: [String] = [], captured: [Element] = [], primitive: (depth: Int, sets: [Int])?
        var count = 0, textBytes = 0, failure: String?
        func fail(_ parser: XMLParser, _ message: String) { failure = message; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            count += 1
            guard path.count < 96, count <= 200_000, attributes.count <= 32 else { fail(parser, "材质引用XML超出有界解析范围"); return }
            let parent = path.last; path.append(name)
            if ["triangles", "polylist", "polygons", "trifans", "tristrips", "lines", "linestrips"].contains(name), parent == "mesh" {
                primitive = (path.count, [])
            } else if name == "input", attributes["semantic"] == "TEXCOORD", primitive?.depth == path.count - 1 {
                guard let set = Int(attributes["set"] ?? "0"), (0...15).contains(set) else { fail(parser, "原材质UV集合无效"); return }
                primitive?.sets.append(set)
            }
            let isRoot = (name == "effect" && parent == "library_effects") || (name == "material" && parent == "library_materials") || name == "instance_material"
            if !captured.isEmpty || isRoot {
                let element = Element(name, attributes)
                if let last = captured.last { last.children.append(element) } else { roots.append(element) }
                captured.append(element)
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let element = captured.last, ["init_from", "source", "wrap_s", "wrap_t"].contains(element.name) else { return }
            textBytes += string.utf8.count; element.value += string
            if textBytes > 4 * 1024 * 1024 || element.value.utf8.count > 4096 { fail(parser, "材质引用文本超出上限") }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if let current = primitive, current.depth == path.count { primitives.append(current.sets); primitive = nil }
            if let last = captured.last { last.value = last.value.trimmingCharacters(in: .whitespacesAndNewlines); captured.removeLast() }
            if !path.isEmpty { path.removeLast() }
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { fail(parser, "材质引用禁止外部实体"); return nil }
    }
    private struct Texture {
        let slot: String; let alias: String; let semantic: String
        let wrapS: SCNWrapMode?; let wrapT: SCNWrapMode?
    }
    private struct Material {
        let id: String; let aliases: Set<String>; let textures: [Texture]
    }
    private static func one(_ elements: [Element], _ message: String) throws -> Element {
        guard elements.count == 1 else { throw VideoError.invalid(message) }; return elements[0]
    }
    private static func reference(_ value: String?) throws -> String {
        guard let value, value.hasPrefix("#"), value.count > 1 else { throw VideoError.invalid("材质须引用本DAE的实际标识") }
        return String(value.dropFirst())
    }
    private static func wrap(_ elements: [Element]) throws -> SCNWrapMode? {
        guard !elements.isEmpty else { return nil }
        switch try one(elements, "同一采样器包裹方式不能重复").value {
        case "WRAP": return .repeat
        case "MIRROR": return .mirror
        case "CLAMP": return .clamp
        case "BORDER": return .clampToBorder
        default: throw VideoError.invalid("原材质采样器包裹方式未支持，未猜测替换")
        }
    }
    private static func property(_ slot: String, of material: SCNMaterial) -> SCNMaterialProperty {
        switch slot {
        case "emission": return material.emission
        case "ambient": return material.ambient
        case "diffuse": return material.diffuse
        case "specular": return material.specular
        case "reflective": return material.reflective
        case "transparent": return material.transparent
        default: return material.normal // Only a parsed FCOLLADA bump reaches this case.
        }
    }
    static func apply(to scene: SCNScene, resource: ModelDAEResource, modelData: Data, textureData: [String: Data]) throws -> [String: [SCNMaterial]] {
        // The same original bytes were already inspected and hash-verified by load.
        try Task.checkCancellation()
        let parsed = Parser(), parser = XMLParser(data: modelData)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = parsed
        let valid = parser.parse()
        try Task.checkCancellation()
        guard valid, parsed.failure == nil else { throw VideoError.invalid(parsed.failure ?? "材质原文引用无法解析") }
        let effects = parsed.roots.filter { $0.name == "effect" }
        let images = Dictionary(uniqueKeysWithValues: resource.inspection.images.map { ($0.id, $0.relativePath) })
        var materials: [Material] = []
        for material in parsed.roots where material.name == "material" {
            guard let id = material.attributes["id"] else { throw VideoError.invalid("原材质缺少实际标识") }
            let instance = try one(material.named("instance_effect"), "原材质必须唯一引用一个effect")
            guard instance.children.isEmpty else { throw VideoError.invalid("尚不支持instance_effect覆盖，未按base材质猜测") }
            let effectID = try reference(instance.attributes["url"])
            let effect = try one(effects.filter { $0.attributes["id"] == effectID }, "原材质effect引用不唯一")
            let profile = try one(effect.named("profile_COMMON"), "材质适配需要唯一profile_COMMON")
            guard effect.children.filter({ $0.name.hasPrefix("profile_") }).count == 1 else { throw VideoError.invalid("多材质profile选择未明确") }
            let technique = try one(profile.named("technique"), "材质technique引用不唯一")
            let shader = try one(technique.children.filter { ["lambert", "phong", "blinn", "constant"].contains($0.name) }, "材质光照类型未明确或尚不支持")
            var parameters: [String: Element] = [:]
            for parameter in profile.named("newparam") {
                guard let sid = parameter.attributes["sid"], !sid.isEmpty, parameters[sid] == nil else { throw VideoError.invalid("材质采样器SID缺失或重复") }
                parameters[sid] = parameter
            }
            var textures: [Texture] = [], recognized = Set<ObjectIdentifier>()
            func texture(_ field: Element, slot: String) throws {
                guard !field.descendants("texture").isEmpty else { return }
                let item = try one(field.named("texture"), "材质贴图属性必须直接唯一引用texture")
                guard field.descendants("texture").count == 1,
                      let samplerID = item.attributes["texture"], let parameter = parameters[samplerID],
                      let semantic = item.attributes["texcoord"], !semantic.isEmpty else { throw VideoError.invalid("材质贴图采样器或UV语义未明确") }
                let sampler = try one(parameter.named("sampler2D"), "材质仅支持明确二维采样器")
                guard item.children.isEmpty,
                      sampler.children.allSatisfy({ ["source", "wrap_s", "wrap_t"].contains($0.name) }) else { throw VideoError.invalid("原贴图变换或采样过滤尚不支持，未静默丢弃") }
                let surfaceID = try one(sampler.named("source"), "采样器surface引用不唯一").value
                guard let surfaceParameter = parameters[surfaceID] else { throw VideoError.invalid("材质surface SID引用缺失") }
                let surface = try one(surfaceParameter.named("surface"), "材质surface引用不唯一")
                let image = try one(surface.named("init_from"), "材质图片引用不唯一")
                guard surface.attributes["type"] == "2D", image.attributes.isEmpty, image.children.isEmpty,
                      let alias = images[image.value], resource.textures[alias] != nil else { throw VideoError.invalid("材质图片ID不能精确对应已核原件别名") }
                textures.append(Texture(slot: slot, alias: alias, semantic: semantic,
                    wrapS: try wrap(sampler.named("wrap_s")), wrapT: try wrap(sampler.named("wrap_t"))))
                recognized.insert(ObjectIdentifier(item))
            }
            for slot in ["emission", "ambient", "diffuse", "specular", "reflective", "transparent"] {
                let fields = shader.named(slot)
                guard fields.count <= 1 else { throw VideoError.invalid("同一材质属性重复") }
                if let field = fields.first {
                    if slot == "transparent", let opaque = field.attributes["opaque"], !["A_ONE", "RGB_ZERO"].contains(opaque) { throw VideoError.invalid("透明贴图opaque声明尚不支持") }
                    try texture(field, slot: slot)
                }
            }
            for extensionTechnique in profile.descendants("technique") where extensionTechnique.attributes["profile"] == "FCOLLADA" {
                for bump in extensionTechnique.named("bump") {
                    guard bump.attributes["bumptype"] == nil || bump.attributes["bumptype"] == "NORMALMAP", !textures.contains(where: { $0.slot == "normal" }) else { throw VideoError.invalid("原法线贴图声明重复或不是NORMALMAP") }
                    try texture(bump, slot: "normal")
                }
            }
            guard Set(profile.descendants("texture").map(ObjectIdentifier.init)) == recognized else { throw VideoError.invalid("原材质存在未支持或多义的贴图属性") }
            let aliases = Set([id, material.attributes["name"], effectID, effect.attributes["name"]].compactMap { $0 }.filter { !$0.isEmpty })
            materials.append(Material(id: id, aliases: aliases, textures: textures))
        }
        var bindings: [String: [String: Int]] = [:]
        for instance in parsed.roots where instance.name == "instance_material" {
            let id = try reference(instance.attributes["target"])
            guard let original = materials.first(where: { $0.id == id }) else { throw VideoError.invalid("实际材质usage没有源材质归属") }
            if original.textures.isEmpty { continue }
            var current: [String: Int] = [:]
            for bind in instance.named("bind_vertex_input") {
                guard bind.attributes["input_semantic"] == "TEXCOORD", let semantic = bind.attributes["semantic"], !semantic.isEmpty,
                      let set = Int(bind.attributes["input_set"] ?? "0"), (0...15).contains(set), current[semantic] == nil else { throw VideoError.invalid("材质UV绑定缺失、重复或尚不支持") }
                if let previous = bindings[id]?[semantic], previous != set { throw VideoError.invalid("同源材质不同usage的UV集合冲突") }
                current[semantic] = set
            }
            let required = original.textures.map(\.semantic)
            guard required.allSatisfy({ current[$0] != nil }) else { throw VideoError.invalid("每个实际材质usage都必须明确绑定全部贴图UV语义") }
            bindings[id, default: [:]].merge(current) { old, _ in old }
        }
        guard !materials.isEmpty else { return [:] }
        if materials.contains(where: { !$0.textures.isEmpty && bindings[$0.id] != nil }) {
            guard parsed.primitives.allSatisfy({ $0.isEmpty || $0 == Array(0..<$0.count) }) else { throw VideoError.invalid("稀疏或乱序原UV集合不能猜测为原生mappingChannel") }
        }
        var native: [ObjectIdentifier: (material: SCNMaterial, channels: Int)] = [:], usageConflicts = Set<ObjectIdentifier>()
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let count = geometry.sources(for: .texcoord).count
            for material in geometry.materials {
                let id = ObjectIdentifier(material)
                if let previous = native[id], previous.channels != count { usageConflicts.insert(id) }
                native[id] = (material, count)
            }
        }
        var decoded: [String: CGImage] = [:], pixels = 0, sourceChannels: [String: Int] = [:]
        var bySourceID: [String: [SCNMaterial]] = [:]
        var assignments: [(property: SCNMaterialProperty, image: CGImage, channel: Int, s: SCNWrapMode?, t: SCNWrapMode?)] = []
        for value in native.values {
            try Task.checkCancellation()
            guard let name = value.material.name else { throw VideoError.invalid("实际原生材质没有可唯一对应原文档的名称") }
            let candidates = materials.filter { $0.aliases.contains(name) }
            guard candidates.count == 1 else { throw VideoError.invalid("实际原生材质名在原material/effect中缺失或多义") }
            let original = candidates[0]
            bySourceID[original.id, default: []].append(value.material)
            if original.textures.isEmpty { continue }
            guard !usageConflicts.contains(ObjectIdentifier(value.material)) else { throw VideoError.invalid("共享原生贴图材质的实际UV通道数量冲突") }
            guard sourceChannels[original.id] == nil || sourceChannels[original.id] == value.channels else { throw VideoError.invalid("同源材质实际几何UV通道数量不一致") }
            sourceChannels[original.id] = value.channels
            for texture in original.textures {
                guard let channel = bindings[original.id]?[texture.semantic], channel < value.channels,
                      let reference = resource.textures[texture.alias], let data = textureData[reference.assetID] else { throw VideoError.invalid("材质贴图UV语义或实际原件闭包不完整") }
                let image: CGImage
                if let existing = decoded[reference.sha256] { image = existing }
                else {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = metadata[kCGImagePropertyPixelWidth] as? Int, let height = metadata[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 48_000_000 - pixels else { throw VideoError.invalid("材质原件累计解码超过4800万像素") }
                    pixels += width * height
                    guard let loaded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw VideoError.invalid("材质实际PNG无法解码") }
                    image = loaded; decoded[reference.sha256] = image
                }
                assignments.append((property(texture.slot, of: value.material), image, channel, texture.wrapS, texture.wrapT))
            }
        }
        for assignment in assignments {
            assignment.property.contents = assignment.image
            assignment.property.mappingChannel = assignment.channel
            if let s = assignment.s { assignment.property.wrapS = s }
            if let t = assignment.t { assignment.property.wrapT = t }
        }
        return bySourceID
    }
}
