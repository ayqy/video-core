import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// An immutable reference to bytes held by the normal project asset store.
public struct ModelAssetReference: Codable, Hashable, Sendable {
    public var assetID: String
    public var sha256: String
    public var bytes: Int
    public var fileExtension: String
    public init(assetID: String, sha256: String, bytes: Int, fileExtension: String) {
        self.assetID = assetID; self.sha256 = sha256; self.bytes = bytes; self.fileExtension = fileExtension
    }
    public init(asset: Asset) { self.init(assetID: asset.id, sha256: asset.hash, bytes: asset.bytes, fileExtension: asset.ext) }
    public func validate(assets: [Asset]? = nil) throws {
        guard !assetID.isEmpty, assetID.utf8.count <= 160, PluginProtocolRules.hash(sha256), (1...134_217_728).contains(bytes), ["dae", "png"].contains(fileExtension) else {
            throw VideoError.invalid("三维资源必须引用有界的实际 DAE/PNG 文件、标识和 SHA256")
        }
        if let assets {
            guard assets.filter({ $0.id == assetID }).count == 1, let asset = assets.first(where: { $0.id == assetID }), asset.hash == sha256, asset.bytes == bytes, asset.ext == fileExtension else {
                throw VideoError.invalid("三维资源引用与实际入库文件不一致")
            }
        }
    }
}

public struct DAEImageReference: Codable, Hashable, Sendable {
    public var id: String
    public var relativePath: String
    public init(id: String, relativePath: String) { self.id = id; self.relativePath = relativePath }
}
public struct DAEMaterialReference: Codable, Hashable, Sendable {
    public var id: String
    public var effectID: String
    public init(id: String, effectID: String) { self.id = id; self.effectID = effectID }
}
/// Parsed facts, never an assertion that an unrendered model looks correct.
public struct DAEInspection: Codable, Hashable, Sendable {
    public var sha256: String
    public var bytes: Int
    public var images: [DAEImageReference]
    public var geometryIDs: [String]
    public var materials: [DAEMaterialReference]
    public var jointNames: [String]
    public var nodeIDs: [String]
    public var textureCoordinateSets: [Int]
    public var unitMeters: Double
    public var upAxis: String
    public var animationCount: Int
    public init(sha256: String, bytes: Int, images: [DAEImageReference], geometryIDs: [String], materials: [DAEMaterialReference], jointNames: [String], nodeIDs: [String], textureCoordinateSets: [Int], unitMeters: Double, upAxis: String, animationCount: Int) {
        self.sha256 = sha256; self.bytes = bytes; self.images = images; self.geometryIDs = geometryIDs; self.materials = materials; self.jointNames = jointNames; self.nodeIDs = nodeIDs; self.textureCoordinateSets = textureCoordinateSets; self.unitMeters = unitMeters; self.upAxis = upAxis; self.animationCount = animationCount
    }
    public func validate() throws {
        guard PluginProtocolRules.hash(sha256), (1...DAEInspector.maximumBytes).contains(bytes), !geometryIDs.isEmpty,
              geometryIDs.count <= 4096, images.count <= 2048, materials.count <= 4096, jointNames.count <= 4096, nodeIDs.count <= 32768,
              unitMeters.isFinite, unitMeters > 0, unitMeters <= 1000, ["X_UP", "Y_UP", "Z_UP"].contains(upAxis), (0...4096).contains(animationCount),
              Set(geometryIDs).count == geometryIDs.count, Set(images.map(\.id)).count == images.count,
              Set(materials.map(\.id)).count == materials.count, Set(jointNames).count == jointNames.count, Set(nodeIDs).count == nodeIDs.count,
              textureCoordinateSets.count <= 16, Set(textureCoordinateSets).count == textureCoordinateSets.count, textureCoordinateSets.allSatisfy({ (0...15).contains($0) }) else {
            throw VideoError.invalid("DAE 几何、骨骼、材质或坐标元数据无效")
        }
        for image in images { _ = try DAEInspector.relativeTexturePath(image.relativePath) }
    }
}

/// DAE dependencies are closed over stored PNG assets; paths are aliases within this bundle only.
public struct ModelDAEResource: Codable, Hashable, Sendable {
    public var model: ModelAssetReference
    public var inspection: DAEInspection
    public var textures: [String: ModelAssetReference]
    public init(model: ModelAssetReference, inspection: DAEInspection, textures: [String: ModelAssetReference]) {
        self.model = model; self.inspection = inspection; self.textures = textures
    }
    public var assetIDs: Set<String> { Set([model.assetID] + textures.values.map(\.assetID)) }
    public func validate(assets: [Asset]? = nil) throws {
        try model.validate(assets: assets); try inspection.validate()
        guard model.fileExtension == "dae", model.sha256 == inspection.sha256, model.bytes == inspection.bytes,
              Set(textures.keys) == Set(inspection.images.map(\.relativePath)), textures.count <= 2048 else {
            throw VideoError.invalid("DAE 与纹理依赖必须完整闭合，不能添加隐藏外部资源")
        }
        for (path, reference) in textures {
            guard try DAEInspector.relativeTexturePath(path) == path, reference.fileExtension == "png" else { throw VideoError.invalid("纹理只接受包内规范 PNG 路径") }
            try reference.validate(assets: assets)
        }
        let references = [model] + textures.values
        for id in assetIDs {
            guard Set(references.filter({ $0.assetID == id })).count == 1 else { throw VideoError.invalid("同一三维资源标识不能声明不同字节") }
        }
    }
    /// Reinspect actual stored model bytes before handing the bundle to a native loader.
    public func verify(modelData: Data, textureDataByAssetID: [String: Data]) throws {
        try validate()
        guard try DAEInspector.inspect(modelData) == inspection else { throw VideoError.invalid("DAE 实际解析结果与冻结资源不一致") }
        guard Set(textureDataByAssetID.keys) == Set(textures.values.map(\.assetID)) else { throw VideoError.invalid("实际纹理文件不完整或含额外文件") }
        for reference in textures.values {
            guard let data = textureDataByAssetID[reference.assetID], data.count == reference.bytes, Codec.hash(data) == reference.sha256,
                  data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw VideoError.invalid("纹理实际字节、PNG 标记或摘要不符") }
        }
    }
}

public enum DAEInspector {
    public static let maximumBytes = 64 * 1024 * 1024
    /// URI decoding happens before traversal checking; the returned path is the canonical alias.
    public static func relativeTexturePath(_ input: String) throws -> String {
        guard !input.isEmpty, input.utf8.count <= 1024, let path = input.removingPercentEncoding,
              !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.contains("\\"), !path.contains("?"), !path.contains("#"), !path.contains("%"),
              path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && (!$0.properties.isWhitespace || $0 == " ") }),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
            throw VideoError.invalid("DAE 纹理必须是无外部 URI、无目录穿越的相对 PNG 路径")
        }
        return path
    }
    public static func inspect(_ data: Data) throws -> DAEInspection {
        guard !data.isEmpty, data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw VideoError.invalid("DAE 只接受有界 UTF-8 XML，禁止 DTD 和实体声明")
        }
        let delegate = DAEParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil, let root = delegate.root else { throw VideoError.invalid(delegate.failure ?? "DAE XML 损坏") }
        return try delegate.inspection(root: root, data: data)
    }
}

private final class DAEElement {
    let name: String
    let attributes: [String: String]
    var children: [DAEElement] = []
    var text = ""
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func descendants(_ name: String) -> [DAEElement] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
    func child(_ name: String) -> DAEElement? { children.first { $0.name == name } }
    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
private final class DAEParser: NSObject, XMLParserDelegate {
    var root: DAEElement?
    var stack: [DAEElement] = []
    var failure: String?
    var identifiers = Set<String>()
    var elementCount = 0
    var textBytes = 0
    func fail(_ parser: XMLParser, _ reason: String) { if failure == nil { failure = reason }; parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elementCount += 1
        guard stack.count < 96, elementCount <= 200_000, attributes.count <= 32, !["include", "reference", "ref"].contains(name) else { fail(parser, "DAE XML 层级、元素数量或外部资源无效"); return }
        if stack.isEmpty {
            guard root == nil, name == "COLLADA", namespaceURI == nil || ["http://www.collada.org/2005/11/COLLADASchema", "http://www.collada.org/2008/03/COLLADASchema"].contains(namespaceURI!) else { fail(parser, "文件不是受支持的 COLLADA 文档"); return }
        }
        for (key, value) in attributes {
            guard value.utf8.count <= 4096, !key.lowercased().contains("schemalocation"), key != "xml:base", key != "base", name != "include" else { fail(parser, "DAE 不接受外部 XML 资源"); return }
            if key == "id" {
                guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }), identifiers.insert(value).inserted else { fail(parser, "DAE 标识为空或重复"); return }
            }
            if ["url", "source", "target"].contains(key) {
                if name == "channel", key == "target" {
                    guard !value.hasPrefix("#"), value.contains("/"), !value.contains(":"), !value.contains("%"), !value.contains("\\"), !value.contains("..") else { fail(parser, "DAE动画通道必须是文档内节点SID引用"); return }
                } else {
                    guard value.hasPrefix("#"), value.count > 1, !value.dropFirst().contains("#"), !value.contains(":") else { fail(parser, "DAE 只接受文档内引用"); return }
                }
            }
        }
        let element = DAEElement(name: name, attributes: attributes)
        if let parent = stack.last { parent.children.append(element) } else { root = element }
        stack.append(element)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBytes += string.utf8.count
        guard textBytes <= DAEInspector.maximumBytes else { fail(parser, "DAE 文本数量超限"); return }
        stack.last?.text += string
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { fail(parser, "DAE 禁止外部实体"); return nil }
    func inspection(root: DAEElement, data: Data) throws -> DAEInspection {
        let all = [root] + flatten(root)
        for element in all {
            if element.name == "skeleton" {
                guard element.value.hasPrefix("#"), identifiers.contains(String(element.value.dropFirst())) else { throw VideoError.invalid("DAE骨架必须引用本文件实际节点") }
            }
            for key in ["url", "source", "target"] {
                if let reference = element.attributes[key] {
                    // Animation channel targets address a node's SID; URL/source are XML IDs.
                    let target = element.name == "channel" && key == "target" ? reference : String(reference.dropFirst())
                    let id = target.split(separator: "/").first.map(String.init) ?? ""
                    guard identifiers.contains(id) else { throw VideoError.invalid("DAE 存在悬空的文档内引用") }
                }
            }
            if ["float_array", "matrix", "translate", "rotate", "scale", "bind_shape_matrix", "color"].contains(element.name) {
                let tokens = element.value.split(whereSeparator: { $0.isWhitespace })
                guard tokens.count <= 2_000_000, tokens.allSatisfy({ Double($0)?.isFinite == true }) else { throw VideoError.invalid("DAE 含无效或非有限数值") }
                if let declared = element.attributes["count"] { guard Int(declared) == tokens.count else { throw VideoError.invalid("DAE 浮点数组数量不符") } }
                let fixed = ["matrix": 16, "translate": 3, "rotate": 4, "scale": 3, "bind_shape_matrix": 16]
                if let count = fixed[element.name] { guard tokens.count == count else { throw VideoError.invalid("DAE 变换维度无效") } }
            }
        }
        let images = try all.filter { $0.name == "image" }.map { element -> DAEImageReference in
            guard let id = element.attributes["id"], let source = element.child("init_from"), source.children.isEmpty else { throw VideoError.invalid("DAE 图片必须明确引用本包 PNG") }
            return DAEImageReference(id: id, relativePath: try DAEInspector.relativeTexturePath(source.value))
        }
        let imageIDs = Set(images.map(\.id))
        for surface in all.filter({ $0.name == "surface" }) {
            for source in surface.children.filter({ $0.name == "init_from" }) {
                guard imageIDs.contains(source.value) else { throw VideoError.invalid("DAE 材质引用了未声明的图片") }
            }
        }
        let materials = try all.filter { $0.name == "material" }.map { element -> DAEMaterialReference in
            guard let id = element.attributes["id"], let effect = element.child("instance_effect")?.attributes["url"], effect.hasPrefix("#") else { throw VideoError.invalid("DAE 材质缺少实际 effect") }
            return DAEMaterialReference(id: id, effectID: String(effect.dropFirst()))
        }
        let jointNames = try all.filter { $0.name == "node" && $0.attributes["type"] == "JOINT" }.map { element -> String in
            guard let name = element.attributes["sid"] ?? element.attributes["name"] ?? element.attributes["id"], !name.isEmpty else { throw VideoError.invalid("DAE 骨骼缺少实际名称") }
            return name
        }
        let uvSets = try Set(all.filter { $0.name == "input" && $0.attributes["semantic"] == "TEXCOORD" }.map { element -> Int in
            guard let set = Int(element.attributes["set"] ?? "0"), (0...15).contains(set) else { throw VideoError.invalid("DAE UV 坐标集合无效") }
            return set
        }).sorted()
        var unit = 1.0
        if let meter = root.child("asset")?.child("unit")?.attributes["meter"] {
            guard let parsed = Double(meter), parsed.isFinite, parsed > 0, parsed <= 1000 else { throw VideoError.invalid("DAE 单位无效") }; unit = parsed
        }
        let result = DAEInspection(sha256: Codec.hash(data), bytes: data.count, images: images.sorted { $0.id < $1.id },
            geometryIDs: all.filter { $0.name == "geometry" }.compactMap { $0.attributes["id"] }.sorted(), materials: materials.sorted { $0.id < $1.id },
            jointNames: jointNames.sorted(), nodeIDs: all.filter { $0.name == "node" }.compactMap { $0.attributes["id"] }.sorted(), textureCoordinateSets: uvSets,
            unitMeters: unit, upAxis: root.child("asset")?.child("up_axis")?.value ?? "Y_UP", animationCount: all.filter { $0.name == "animation" }.count)
        try result.validate(); return result
    }
    private func flatten(_ element: DAEElement) -> [DAEElement] { element.children.flatMap { [$0] + flatten($0) } }
}
