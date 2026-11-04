import Darwin
import Foundation
import ImageIO
import VideoCore
import VideoMedia

/// Existing-owner author seam. Source declarations arrive on stdin; the normal
/// SDK parses/imports DAE/PNG and the normal repository transaction saves rights.
/// This does not create a project, authorize commercial use, or record a review.
@main
private enum ImportModelMaterials {
    private struct FileDeclaration: Codable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
        let source: String
        let owner: String
        let claim: String
        let license: String
        var ext: String { URL(fileURLWithPath: path).pathExtension }
        var mediaType: String { ext == "dae" ? "model3d" : "image" }
        var evidenceClaim: String { claim + "\n许可声明：" + license + "\n用途：local-noncommercial" }
    }
    private struct PackageDeclaration: Decodable {
        let model: FileDeclaration
        let textures: [String: FileDeclaration]
    }
    private struct Declaration: Decodable {
        let version: Int
        let kind: String
        let use: String
        let models: [String: PackageDeclaration]
    }
    private struct Receipt: Encodable {
        let workspaceID: String
        let projectID: String
        let baseRevision: String
        let resources: [String: ModelDAEResource]
        let assetsByPath: [String: ModelAssetReference]
        let evidenceIDsByPath: [String: String]
    }
    private struct Input {
        let workspace: URL
        let workspaceID: String
        let projectID: String
        let baseRevision: String
        let sourceRoot: URL
    }
    private struct Context {
        let database: Database
        let principal: String
    }
    private static let maximumTotalBytes = 64 * 1024 * 1024
    private static let evidenceTitle = "本地非商业三维来源"
    private static func provenanceText(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && value.utf8.count <= 4096 &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) })
    }

    private static func directory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"), url.path == path,
              url.resolvingSymlinksInPath().path == path else { throw VideoError.invalid("须为明确规范物理目录") }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw VideoError.invalid("须为已有普通目录") }
        return url
    }
    private static func ordinaryFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              url.resolvingSymlinksInPath().path == url.path else { throw VideoError.invalid("已有文件不能为链接或特殊文件") }
    }
    private static func arguments() throws -> Input {
        let args = Array(CommandLine.arguments.dropFirst())
        let allowed = Set(["--workspace", "--workspace-id", "--project-id", "--base-revision", "--source-root"])
        guard args.count == 10 else { throw VideoError.invalid("须明确五对已有工作区、工程、版本和来源根参数") }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: args.count, by: 2) {
            guard allowed.contains(args[index]), options[args[index]] == nil,
                  !args[index + 1].isEmpty else { throw VideoError.invalid("参数重复或无效") }
            options[args[index]] = args[index + 1]
        }
        guard let workspace = options["--workspace"], let source = options["--source-root"],
              let workspaceID = options["--workspace-id"], UUID(uuidString: workspaceID) != nil,
              let projectID = options["--project-id"], UUID(uuidString: projectID) != nil,
              let revision = options["--base-revision"], UUID(uuidString: revision) != nil else { throw VideoError.invalid("须提供真实工作区、工程和版本ID") }
        let root = try directory(workspace)
        try ordinaryFile(root.appendingPathComponent("workspace.sqlite"))
        for suffix in ["-wal", "-shm"] {
            let file = root.appendingPathComponent("workspace.sqlite" + suffix)
            var info = stat()
            if lstat(file.path, &info) == 0 { try ordinaryFile(file) }
            else if errno != ENOENT { throw VideoError.permission("数据库附属文件不可检查") }
        }
        let assets = root.appendingPathComponent("assets")
        var info = stat()
        if lstat(assets.path, &info) == 0 { _ = try directory(assets.path) }
        else if errno != ENOENT { throw VideoError.permission("素材目录不可检查") }
        return Input(workspace: root, workspaceID: workspaceID, projectID: projectID,
                     baseRevision: revision, sourceRoot: try directory(source))
    }
    private static func authorize(_ db: Database, input: Input) throws -> Context {
        guard db.generation > 0, db.workspaces.filter({ $0.id == input.workspaceID }).count == 1 else { throw VideoError.invalid("只接受已有工作区") }
        let principal = LocalWorkspaceIdentity.principal(workspaceID: input.workspaceID, in: db.workspaces)
        let access = WorkspaceAccessContext(workspaceID: input.workspaceID, principal: principal)
        let workspace = try WorkspaceAccessRules.validate(access, in: db)
        guard workspace.owner == principal else { throw VideoError.permission("只接受当前本地所有者") }
        let projects = db.projects.filter { $0.id == input.projectID && $0.workspaceID == input.workspaceID && !$0.archived }
        guard projects.count == 1, let project = projects.first, !project.revisions.isEmpty,
              project.current.id == input.baseRevision else { throw VideoError.conflict("已有工程或当前版本不符") }
        _ = try WorkspaceAccessRules.revision(projectID: project.id, revisionID: input.baseRevision, access: access, in: db, write: true)
        for command in ["assets import", "evidence add"] {
            try AgentContract.authorize(command: command, workspace: workspace, principal: principal,
                                        projectID: project.id, revisionID: input.baseRevision)
        }
        return Context(database: db, principal: principal)
    }
    private static func relativePath(_ path: String, ext: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains("\0"), parts.count <= 96, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              URL(fileURLWithPath: path).pathExtension == ext else { throw VideoError.invalid("来源须为规范相对DAE或PNG路径") }
    }
    private static func exactKeys(_ value: Any, _ expected: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == expected else { throw VideoError.invalid("声明字段不完整或含未知字段") }
        return object
    }
    private static func declaration() throws -> Declaration {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
            guard data.count <= 8 * 1024 * 1024 - chunk.count else { throw VideoError.invalid("声明超过8MiB") }
            data.append(chunk)
        }
        let object = try exactKeys(JSONSerialization.jsonObject(with: data), ["version", "kind", "use", "models"])
        guard let models = object["models"] as? [String: Any], (1...128).contains(models.count) else { throw VideoError.invalid("须明确1至128个模型") }
        for (alias, raw) in models {
            guard alias.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { throw VideoError.invalid("模型别名无效") }
            let row = try exactKeys(raw, ["model", "textures"])
            _ = try exactKeys(row["model"]!, ["path", "bytes", "sha256", "source", "owner", "claim", "license"])
            guard let textures = row["textures"] as? [String: Any], textures.count <= 512 else { throw VideoError.invalid("纹理声明数量无效") }
            for (path, texture) in textures {
                guard try DAEInspector.relativeTexturePath(path) == path else { throw VideoError.invalid("纹理别名无效") }
                _ = try exactKeys(texture, ["path", "bytes", "sha256", "source", "owner", "claim", "license"])
            }
        }
        let result = try Codec.decoder().decode(Declaration.self, from: data)
        guard result.version == 1, result.kind == "model-packages", result.use == "local-noncommercial" else { throw VideoError.permission("仅接受明确的本地非商业模型声明") }
        return result
    }
    /// Every ancestor is opened without following links. NONBLOCK makes FIFOs
    /// reach fstat instead of hanging. Hash and size are checked on actual bytes.
    private static func sourceBytes(_ file: FileDeclaration, root: URL) throws -> Data {
        let base = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw VideoError.permission("来源根不可安全读取") }
        var descriptors = [base]
        defer { for descriptor in descriptors.reversed() { Darwin.close(descriptor) } }
        var parent = base
        let parts = file.path.split(separator: "/").map(String.init)
        var links: [(Int32, String, Int32)] = []
        for part in parts.dropLast() {
            let next = Darwin.openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw VideoError.permission("来源父目录缺失或为链接") }
            links.append((parent, part, next)); descriptors.append(next); parent = next
        }
        let fd = Darwin.openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw VideoError.permission("来源文件不可安全读取") }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat(), located = stat(), opened = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size == off_t(file.bytes) else { throw VideoError.invalid("来源不是单链接普通文件或长度不符") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw VideoError.unavailable("来源读取失败") }
            if count == 0 { break }
            guard count <= file.bytes - result.count else { throw VideoError.conflict("来源长度在读取时变化") }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec, after.st_nlink == 1,
              fstatat(parent, parts.last!, &located, AT_SYMLINK_NOFOLLOW) == 0,
              located.st_mode & S_IFMT == S_IFREG, located.st_dev == before.st_dev, located.st_ino == before.st_ino,
              fstat(base, &opened) == 0, lstat(root.path, &located) == 0,
              located.st_mode & S_IFMT == S_IFDIR, opened.st_dev == located.st_dev, opened.st_ino == located.st_ino else { throw VideoError.conflict("来源身份在读取期间变化") }
        for (ancestor, name, child) in links {
            guard fstat(child, &opened) == 0, fstatat(ancestor, name, &located, AT_SYMLINK_NOFOLLOW) == 0,
                  located.st_mode & S_IFMT == S_IFDIR, opened.st_dev == located.st_dev, opened.st_ino == located.st_ino else { throw VideoError.conflict("来源父目录身份变化") }
        }
        guard result.count == file.bytes, Codec.hash(result) == file.sha256 else { throw VideoError.review("实际来源SHA256或长度不符") }
        return result
    }
    private static func files(_ declaration: Declaration) throws -> [String: FileDeclaration] {
        var result: [String: FileDeclaration] = [:], identities: [String: FileDeclaration] = [:]
        var total = 0
        for package in declaration.models.values {
            try relativePath(package.model.path, ext: "dae")
            for file in [package.model] + Array(package.textures.values) {
                try relativePath(file.path, ext: file.ext)
                guard ["dae", "png"].contains(file.ext), PluginProtocolRules.hash(file.sha256),
                      (1...(file.ext == "dae" ? DAEInspector.maximumBytes : 32 * 1024 * 1024)).contains(file.bytes),
                      [file.source, file.owner, file.claim, file.license].allSatisfy(provenanceText),
                      result[file.path] == nil || result[file.path] == file else { throw VideoError.invalid("完整来源、用途或同路径声明不符") }
                if let same = identities[file.sha256 + "." + file.ext] {
                    guard same.bytes == file.bytes, same.source == file.source, same.owner == file.owner,
                          same.claim == file.claim, same.license == file.license else { throw VideoError.conflict("同字节声明了不同来源或许可") }
                } else {
                    guard file.bytes <= maximumTotalBytes - total else { throw VideoError.invalid("来源去重总量超过64MiB") }
                    total += file.bytes; identities[file.sha256 + "." + file.ext] = file
                }
                result[file.path] = file
            }
            guard package.textures.values.allSatisfy({ $0.ext == "png" }) else { throw VideoError.invalid("纹理来源仅接受PNG") }
        }
        guard result.count <= 512 else { throw VideoError.invalid("来源超过512个明确文件") }
        return result
    }
    private static func validate(_ asset: Asset, file: FileDeclaration, workspaceID: String, database: Database) throws {
        guard asset.workspaceID == workspaceID, asset.hash == file.sha256, asset.bytes == file.bytes,
              asset.ext == file.ext, asset.mediaType == file.mediaType, asset.durationFrames == nil,
              asset.generatedSource == nil, asset.pages.isEmpty, asset.warnings.isEmpty,
              let id = asset.evidenceID, database.evidence.filter({ $0.id == id }).count == 1,
              let proof = database.evidence.first(where: { $0.id == id }), proof.workspaceID == workspaceID,
              proof.assetID == asset.id, proof.title == evidenceTitle, proof.source == file.source,
              proof.owner == file.owner, proof.claim == file.evidenceClaim, proof.usable(commercial: false),
              !proof.commercialAllowed, !proof.uploadConsent else { throw VideoError.conflict("同源已有记录的类型、来源或本地用途不符；未覆盖旧记录") }
    }
    private static func existing(_ files: [String: FileDeclaration], database: Database, input: Input) throws -> [String: Asset] {
        var result: [String: Asset] = [:]
        for (path, file) in files {
            let matches = database.assets.filter { $0.workspaceID == input.workspaceID && $0.hash == file.sha256 && $0.ext == file.ext }
            guard matches.count <= 1 else { throw VideoError.conflict("同源已有素材重复；未自动挑选") }
            if let asset = matches.first {
                try validate(asset, file: file, workspaceID: input.workspaceID, database: database)
                let cas = FileDeclaration(path: asset.relativePath, bytes: file.bytes, sha256: file.sha256,
                                          source: file.source, owner: file.owner, claim: file.claim, license: file.license)
                _ = try sourceBytes(cas, root: input.workspace)
                result[path] = asset
            }
        }
        return result
    }
    private static func unchanged(_ after: Database, before: Database, allowedAssets: Set<String>, allowedEvidence: Set<String>, changed: Bool) throws {
        guard after.generation == before.generation + (changed ? 1 : 0),
              try Codec.digest(Array(after.assets.prefix(before.assets.count))) == Codec.digest(before.assets),
              try Codec.digest(Array(after.evidence.prefix(before.evidence.count))) == Codec.digest(before.evidence),
              after.assets.dropFirst(before.assets.count).allSatisfy({ allowedAssets.contains($0.id) }),
              after.evidence.dropFirst(before.evidence.count).allSatisfy({ allowedEvidence.contains($0.id) }) else { throw VideoError.conflict("追加范围超过本次实际模型来源") }
        var other = after
        other.generation = before.generation; other.assets = before.assets; other.evidence = before.evidence
        guard try Codec.digest(other) == Codec.digest(before) else { throw VideoError.conflict("导入改动了已有项目、原音或其他记录") }
    }
    static func main() {
        if Array(CommandLine.arguments.dropFirst()) == ["--help"] {
            print("ImportModelMaterials --workspace <existing> --workspace-id <id> --project-id <id> --base-revision <id> --source-root <physical-root>; explicit version 1 model-packages local-noncommercial declaration on stdin")
            return
        }
        var stage = "arguments"
        do {
            let input = try arguments(), declared = try declaration(), declaredFiles = try files(declared)
            stage = "read-only-authorize"
            let context = try authorize(Repository(root: input.workspace, readOnly: true).read(), input: input)
            stage = "preflight-all-sources"
            var inspections: [String: DAEInspection] = [:]
            for file in declaredFiles.values {
                let data = try sourceBytes(file, root: input.sourceRoot)
                if file.ext == "dae" { inspections[file.path] = try DAEInspector.inspect(data) }
                else {
                    guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                          CGImageSourceGetType(image) as String? == "public.png", CGImageSourceGetCount(image) == 1,
                          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 8192, height <= 8192,
                          width <= 24_000_000 / height,
                          CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                        throw VideoError.invalid("实际PNG完整解码、尺寸或有界像素检查失败")
                    }
                }
                var info = stat()
                let cas = input.workspace.appendingPathComponent("assets/" + file.sha256 + "." + file.ext)
                if lstat(cas.path, &info) == 0 {
                    let stored = FileDeclaration(path: "assets/" + file.sha256 + "." + file.ext, bytes: file.bytes,
                                                 sha256: file.sha256, source: file.source, owner: file.owner, claim: file.claim, license: file.license)
                    _ = try sourceBytes(stored, root: input.workspace)
                } else if errno != ENOENT { throw VideoError.permission("CAS目标无法安全检查") }
            }
            for package in declared.models.values {
                guard let inspection = inspections[package.model.path], Set(package.textures.keys) == Set(inspection.images.map(\.relativePath)) else { throw VideoError.invalid("模型纹理映射必须与实际DAE完整闭合") }
            }
            _ = try existing(declaredFiles, database: context.database, input: input)
            stage = "open-existing"
            let repository = try Repository(root: input.workspace)
            guard try Codec.digest(repository.read()) == Codec.digest(context.database) else { throw VideoError.conflict("打开已有仓库期间记录变化") }
            stage = "normal-sdk-import"
            var packages: [String: ImportedModelPackage] = [:], staged: [String: Asset] = [:]
            for alias in declared.models.keys.sorted() {
                try Task.checkCancellation()
                let package = declared.models[alias]!
                let bindings = package.textures.mapValues { ModelTextureBinding(url: input.sourceRoot.appendingPathComponent($0.path), sha256: $0.sha256) }
                let imported = try ModelPackageMedia.importPackage(modelURL: input.sourceRoot.appendingPathComponent(package.model.path),
                                                                   sourceRoot: input.sourceRoot, workspaceID: input.workspaceID,
                                                                   repository: repository, textureBindings: bindings)
                guard imported.resource.inspection == inspections[package.model.path], imported.resource.model.sha256 == package.model.sha256,
                      imported.resource.model.bytes == package.model.bytes else { throw VideoError.conflict("SDK实际模型不符已冻结声明") }
                var byAlias = package.textures.mapValues { $0.path }
                byAlias["\0model"] = package.model.path
                for (imageAlias, path) in byAlias {
                    let reference = imageAlias == "\0model" ? imported.resource.model : imported.resource.textures[imageAlias]!
                    guard let asset = imported.assets.first(where: { $0.id == reference.assetID }),
                          let file = declaredFiles[path], reference.sha256 == file.sha256, reference.bytes == file.bytes,
                          reference.fileExtension == file.ext else { throw VideoError.conflict("SDK实际来源资产与声明不符") }
                    if staged[path] == nil { staged[path] = asset }
                }
                packages[alias] = imported
            }
            stage = "normal-source-registration"
            let current = try authorize(repository.read(), input: input)
            guard current.principal == context.principal, try Codec.digest(current.database) == Codec.digest(context.database) else { throw VideoError.conflict("源导入期间原工程或记录变化") }
            var final = try existing(declaredFiles, database: current.database, input: input)
            let changed = final.count != declaredFiles.count
            if changed {
                final = try repository.transaction(expectedGeneration: context.database.generation) { db in
                    let authorized = try authorize(db, input: input)
                    guard authorized.principal == context.principal, try Codec.digest(db) == Codec.digest(context.database) else { throw VideoError.conflict("提交前原记录或工程版本变化") }
                    var values = try existing(declaredFiles, database: db, input: input)
                    for path in declaredFiles.keys.sorted() where values[path] == nil {
                        let file = declaredFiles[path]!
                        if let same = values.values.first(where: { $0.hash == file.sha256 && $0.ext == file.ext }) { values[path] = same; continue }
                        guard var asset = staged[path] else { throw VideoError.conflict("缺少SDK实际资产") }
                        let proof = Evidence(workspaceID: input.workspaceID, title: evidenceTitle, source: file.source,
                                             claim: file.evidenceClaim, owner: file.owner, commercialAllowed: false,
                                             uploadConsent: false, verified: true, assetID: asset.id)
                        asset.evidenceID = proof.id; db.assets.append(asset); db.evidence.append(proof); values[path] = asset
                        try validate(asset, file: file, workspaceID: input.workspaceID, database: db)
                    }
                    return values
                }
            }
            stage = "verify-and-receipt"
            let after = try repository.read(), authorized = try authorize(after, input: input)
            guard authorized.principal == context.principal, Set(final.keys) == Set(declaredFiles.keys) else { throw VideoError.conflict("提交后来源范围不符") }
            var references: [String: ModelAssetReference] = [:], evidence: [String: String] = [:], resources: [String: ModelDAEResource] = [:]
            for (path, asset) in final {
                try validate(asset, file: declaredFiles[path]!, workspaceID: input.workspaceID, database: after)
                references[path] = ModelAssetReference(asset: asset); evidence[path] = asset.evidenceID!
            }
            for (alias, package) in declared.models {
                guard let original = packages[alias], let model = references[package.model.path] else { throw VideoError.conflict("实际模型包回执缺失") }
                let resource = ModelDAEResource(model: model, inspection: original.resource.inspection,
                                                textures: package.textures.mapValues { references[$0.path]! })
                try resource.validate(assets: after.assets); resources[alias] = resource
                _ = try ModelPackageMedia.verifiedByteClosure(resource, workspaceID: input.workspaceID,
                                                              repository: repository, database: after, commercial: false)
            }
            try unchanged(after, before: context.database, allowedAssets: Set(final.values.map(\.id)),
                          allowedEvidence: Set(evidence.values), changed: changed)
            let receipt = Receipt(workspaceID: input.workspaceID, projectID: input.projectID, baseRevision: input.baseRevision,
                                  resources: resources, assetsByPath: references, evidenceIDsByPath: evidence)
            FileHandle.standardOutput.write(try Codec.data(receipt)); FileHandle.standardOutput.write(Data([10]))
        } catch {
            // CAS staging is deliberately retained on failure. No fake rollback,
            // source input, credential, path dump or evidence is printed.
            let code = (error as? VideoError)?.code ?? "local_model_import_failed"
            FileHandle.standardError.write(Data("ImportModelMaterials stage=\(stage) code=\(code)\n".utf8))
            exit((error as? VideoError)?.exitCode ?? 8)
        }
    }
}
