import Darwin
import Foundation
import VideoCore
import VideoMedia

/// Generic local SDK bridge for an explicitly selected existing workspace.
/// Uses the Mac editor's authorized Repository/importPack path. JS stays passive;
/// no CLI extension bypass, copied importer, evaluator or new workspace is used.
@main
private enum ImportMotaMaterials {
    private struct Receipt: Encodable {
        let workspaceID: String
        let projectID: String
        let baseRevision: String
        let artwork: ClassicArtwork
        // Exactly the six source-binding fields consumed by world.build_artwork;
        // no Asset.pages, workspace salt, provider, grant or credential dump.
        let assetsByPath: [String: ClassicSource]
    }

    private struct Context {
        let database: Database
        let projectID: String
        let baseRevision: String
        let principal: String
    }

    private static func authorize(_ database: Database, workspaceID: String, projectID: String) throws -> Context {
        guard database.generation > 0,
              database.workspaces.filter({ $0.id == workspaceID }).count == 1 else {
            throw VideoError.invalid("须使用已正常恢复的已有工作区")
        }
        let principal = LocalWorkspaceIdentity.principal(workspaceID: workspaceID, in: database.workspaces)
        let access = WorkspaceAccessContext(workspaceID: workspaceID, principal: principal)
        let workspace = try WorkspaceAccessRules.validate(access, in: database)
        // A foreign imported owner is never promoted to a local principal.
        guard workspace.owner == principal else { throw VideoError.permission("须为当前本地所有者") }
        let projects = database.projects.filter { $0.workspaceID == workspaceID && !$0.archived && $0.id == projectID }
        guard projects.count == 1, let project = projects.first, !project.revisions.isEmpty else {
            throw VideoError.invalid("须绑定唯一已有作者工程")
        }
        _ = try WorkspaceAccessRules.revision(projectID: project.id, revisionID: project.current.id,
                                              access: access, in: database, write: true)
        try AgentContract.authorize(command: "assets import", workspace: workspace, principal: principal,
                                    projectID: project.id, revisionID: project.current.id)
        return Context(database: database, projectID: project.id, baseRevision: project.current.id, principal: principal)
    }

    private static func ordinaryDirectory(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw VideoError.invalid("须明确绝对目录") }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.path == path, url.resolvingSymlinksInPath().path == path else {
            throw VideoError.permission("目录与父目录不能是链接或非规范路径")
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VideoError.invalid("须为普通已存在目录")
        }
        return url
    }

    private static func ordinaryFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path == url.path else {
            throw VideoError.invalid("须为普通已存在文件，不能使用链接")
        }
    }

    private static func arguments() throws -> (workspace: URL, workspaceID: String, projectID: String, resources: URL) {
        let values = Array(CommandLine.arguments.dropFirst())
        guard values.count == 8 else { throw VideoError.invalid("须明确四对工作区、工程及原件参数") }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: values.count, by: 2) {
            let key = values[index], value = values[index + 1]
            guard ["--workspace", "--workspace-id", "--project-id", "--resources"].contains(key), options[key] == nil,
                  !value.isEmpty, !value.hasPrefix("--") else { throw VideoError.invalid("参数无效") }
            options[key] = value
        }
        guard let path = options["--workspace"], let resourcePath = options["--resources"],
              let workspaceID = options["--workspace-id"], UUID(uuidString: workspaceID) != nil,
              let projectID = options["--project-id"], UUID(uuidString: projectID) != nil else {
            throw VideoError.invalid("须明确目录与真实工作区及工程ID")
        }
        let workspace = try ordinaryDirectory(path)
        let resources = try ordinaryDirectory(resourcePath)
        guard resources.lastPathComponent == "GameAssets",
              resources.deletingLastPathComponent().lastPathComponent == "ThirdParty" else {
            throw VideoError.invalid("须明确普通ThirdParty/GameAssets原件根目录")
        }
        // Check before even opening a writable Repository; never initialize a DB.
        try ordinaryFile(workspace.appendingPathComponent("workspace.sqlite"))
        for suffix in ["-wal", "-shm"] {
            let sidecar = workspace.appendingPathComponent("workspace.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try ordinaryFile(sidecar)
            } else if (try? FileManager.default.attributesOfItem(atPath: sidecar.path)) != nil {
                throw VideoError.invalid("数据库附属文件不能是悬空链接")
            }
        }
        let assets = workspace.appendingPathComponent("assets", isDirectory: true)
        if FileManager.default.fileExists(atPath: assets.path) {
            _ = try ordinaryDirectory(assets.path)
        } else if (try? FileManager.default.attributesOfItem(atPath: assets.path)) != nil {
            throw VideoError.invalid("素材目录不能是悬空链接")
        }
        // A pre-existing CAS object must also stay an ordinary local file.
        for file in MotaWorldAssets.fileDescriptors {
            let ext = URL(fileURLWithPath: file.path).pathExtension
            let url = assets.appendingPathComponent(file.sha256 + "." + ext)
            if FileManager.default.fileExists(atPath: url.path) {
                try ordinaryFile(url)
            } else if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
                throw VideoError.invalid("素材原件不能是悬空链接")
            }
        }
        return (workspace, workspaceID, projectID, resources)
    }

    private static func verify(_ after: Database, context: Context, pack: MotaWorldImportedPack,
                               workspaceID: String) throws -> [String: ClassicSource] {
        let before = context.database
        let current = try authorize(after, workspaceID: workspaceID, projectID: context.projectID)
        guard current.principal == context.principal, current.projectID == context.projectID,
              current.baseRevision == context.baseRevision,
              try Codec.digest(Array(after.assets.prefix(before.assets.count))) == Codec.digest(before.assets),
              try Codec.digest(Array(after.evidence.prefix(before.evidence.count))) == Codec.digest(before.evidence),
              Set(pack.assetsByPath.keys) == Set(MotaWorldAssets.fileDescriptors.map(\.path)) else {
            throw VideoError.conflict("原项目或已有来源在导入期间变化")
        }
        let allowedAssets = Set(pack.assetsByPath.values.map(\.id))
        let allowedProofs = Set(pack.artwork.sources.map(\.evidenceID))
        let skins = pack.artwork.sprites.filter { $0.role == "dialogue_skin" }
        guard allowedAssets.count == 15, allowedProofs.count == 15,
              let skinAsset = pack.assetsByPath["mota/project/images/winskin.png"],
              skins.count == 1, skins[0].assetID == skinAsset.id,
              skins[0].x == 0, skins[0].y == 0, skins[0].width == 1, skins[0].height == 1,
              after.assets.dropFirst(before.assets.count).allSatisfy({ allowedAssets.contains($0.id) }),
              after.evidence.dropFirst(before.evidence.count).allSatisfy({ allowedProofs.contains($0.id) }),
              Set(after.assets.map(\.id)).count == after.assets.count,
              Set(after.evidence.map(\.id)).count == after.evidence.count else {
            throw VideoError.conflict("固定来源之外出现新增或重复记录")
        }
        let newAssets = after.assets.count - before.assets.count
        let newEvidence = after.evidence.count - before.evidence.count
        guard newAssets >= 0, newAssets <= 15, newEvidence == newAssets,
              after.generation == before.generation + (newAssets == 0 ? 0 : 1),
              Set(after.assets.map(\.id)).isSuperset(of: allowedAssets),
              Set(after.evidence.map(\.id)).isSuperset(of: allowedProofs) else {
            throw VideoError.conflict("导入记录或generation变化超出一次正常固定素材事务")
        }
        // A repeat import must preserve the complete Database, including generation.
        if newAssets == 0 {
            guard try Codec.digest(after) == Codec.digest(before) else {
                throw VideoError.conflict("重复导入改变了已有完整数据库")
            }
        }
        // Compare the complete domain snapshot after replacing only the normal
        // import's permitted fields in this in-memory value; never write it.
        var unchanged = after
        unchanged.generation = before.generation
        unchanged.assets = before.assets
        unchanged.evidence = before.evidence
        guard try Codec.digest(unchanged) == Codec.digest(before) else {
            throw VideoError.conflict("素材导入改变了其他业务记录")
        }
        var bindings: [String: ClassicSource] = [:]
        for file in MotaWorldAssets.fileDescriptors {
            guard let asset = pack.assetsByPath[file.path], asset.workspaceID == workspaceID,
                  asset.hash == file.sha256, asset.bytes == file.bytes, asset.mediaType == file.mediaType,
                  file.acceptsAssetName(asset.name), asset.ext == URL(fileURLWithPath: file.path).pathExtension,
                  asset.generatedSource == nil, asset.durationFrames == nil, asset.warnings.isEmpty,
                  let source = pack.artwork.sources.first(where: { $0.assetID == asset.id }),
                  source.hash == asset.hash, source.evidenceID == asset.evidenceID,
                  let proof = after.evidence.first(where: { $0.id == source.evidenceID }),
                  proof.assetID == asset.id, proof.workspaceID == workspaceID,
                  proof.usable(commercial: false), !proof.commercialAllowed, !proof.uploadConsent,
                  proof.title == file.evidenceTitle(assetName: asset.name), proof.claim == file.evidenceClaim,
                  proof.source == file.sourceURL, proof.owner == file.evidenceOwner,
                  source.source == proof.source, source.owner == proof.owner,
                  source.license == MotaWorldAssets.licence else {
                throw VideoError.conflict("固定来源回执与真实导入记录不一致")
            }
            bindings[file.path] = source
        }
        return bindings
    }

    static func main() async {
        if Array(CommandLine.arguments.dropFirst()) == ["--help"] {
            print("ImportMotaMaterials --workspace <absolute-existing-workspace> --workspace-id <real-id> --project-id <existing-project-id> --resources <absolute-ThirdParty/GameAssets>")
            return
        }
        var stage = "arguments"
        do {
            let input = try arguments()
            stage = "read-only-authorize"
            // Reject unknown identity before a writable Repository can initialize
            // or migrate anything. The existing CLI restore owns this database.
            let context = try authorize(Repository(root: input.workspace, readOnly: true).read(), workspaceID: input.workspaceID, projectID: input.projectID)
            stage = "open-existing"
            let repository = try Repository(root: input.workspace)
            guard try Codec.digest(repository.read()) == Codec.digest(context.database) else {
                throw VideoError.conflict("正常打开时工程发生变化，请保留现场")
            }
            stage = "normal-import"
            let pack = try await MotaWorldAssets.importPack(from: input.resources, workspaceID: input.workspaceID,
                                                           repository: repository)
            stage = "verify"
            let bindings = try verify(repository.read(), context: context, pack: pack, workspaceID: input.workspaceID)
            stage = "encode"
            let receipt = Receipt(workspaceID: input.workspaceID, projectID: context.projectID,
                                  baseRevision: context.baseRevision, artwork: pack.artwork, assetsByPath: bindings)
            FileHandle.standardOutput.write(try Codec.data(receipt))
            FileHandle.standardOutput.write(Data([0x0a]))
        } catch {
            // Only fixed stages and the public error category are disclosed.
            // Keep the restored workspace/CAS intact for normal resume.
            let code = (error as? VideoError)?.code ?? "local_import_failed"
            FileHandle.standardError.write(Data("ImportMotaMaterials stage=\(stage) code=\(code)\n".utf8))
            exit((error as? VideoError)?.exitCode ?? 8)
        }
    }
}
