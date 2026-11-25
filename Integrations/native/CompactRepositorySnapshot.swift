import Darwin
import Foundation
import VideoCore

/// Existing-owner maintenance through the ordinary Repository transaction.
/// No revision, source, budget, review or execution fact is changed. The caller
/// freezes fingerprint mode first and must never replay an uncertain compact.
@main
private enum CompactRepositorySnapshot {
    struct RevisionPin: Codable, Equatable {
        let projectID: String
        let revisionID: String
        let sha256: String
        let scenes: Int
    }
    struct Fingerprint: Codable, Equatable {
        let metadataSHA256: String
        let revisions: [RevisionPin]
    }
    struct Receipt: Encodable {
        let mode: String
        let generationBefore: Int
        let generationAfter: Int
        let protectedSHA256: String
        let fingerprint: Fingerprint
        let revisionCount: Int
        let noBusinessChanges: Bool
    }
    private static func fingerprint(_ database: Database) throws -> Fingerprint {
        var metadata = database
        metadata.generation = 0
        var revisions = [RevisionPin]()
        for index in metadata.projects.indices {
            let project = metadata.projects[index]
            for revision in project.revisions {
                revisions.append(RevisionPin(projectID: project.id, revisionID: revision.id,
                    sha256: try Codec.digest(revision), scenes: revision.scenes.count))
            }
            metadata.projects[index].revisions = []
        }
        return Fingerprint(metadataSHA256: try Codec.digest(metadata), revisions: revisions)
    }
    private static func run() throws {
        let raw = Array(CommandLine.arguments.dropFirst())
        let allowed = Set(["--mode", "--workspace", "--workspace-id", "--project-id",
                           "--base-revision", "--expected-generation", "--expected-digest"])
        guard raw.count % 2 == 0 else { throw VideoError.invalid("须明确维护模式与已有工程范围") }
        var options = [String: String]()
        for index in stride(from: 0, to: raw.count, by: 2) {
            guard allowed.contains(raw[index]), options[raw[index]] == nil else {
                throw VideoError.invalid("参数未知或重复")
            }
            options[raw[index]] = raw[index + 1]
        }
        guard let mode = options["--mode"], ["fingerprint", "compact"].contains(mode),
              let path = options["--workspace"], path.hasPrefix("/"), path != "/",
              let workspaceID = options["--workspace-id"], UUID(uuidString: workspaceID) != nil,
              let projectID = options["--project-id"], UUID(uuidString: projectID) != nil,
              let revisionID = options["--base-revision"], UUID(uuidString: revisionID) != nil else {
            throw VideoError.invalid("只接受明确的已有本地所有者工程")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.path == path, root.resolvingSymlinksInPath().path == path else {
            throw VideoError.invalid("须为规范物理目录")
        }
        var info = stat()
        guard lstat(root.appendingPathComponent("workspace.sqlite").path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw VideoError.invalid("须为已有普通工程数据库")
        }
        let repository = try Repository(root: root, readOnly: mode == "fingerprint")
        let before = try repository.read()
        let principal = LocalWorkspaceIdentity.principal(workspaceID: workspaceID, in: before.workspaces)
        let access = WorkspaceAccessContext(workspaceID: workspaceID, principal: principal)
        let workspace = try WorkspaceAccessRules.validate(access, in: before)
        guard workspace.owner == principal else { throw VideoError.permission("仅本地所有者可维护保存表示") }
        let project = try before.project(projectID)
        guard project.workspaceID == workspaceID, project.current.id == revisionID, !project.archived else {
            throw VideoError.conflict("已有工程或当前版本不符")
        }
        _ = try WorkspaceAccessRules.revision(projectID: projectID, revisionID: revisionID,
                                              access: access, in: before, write: mode == "compact")
        let pinned = try fingerprint(before)
        let digest = try Codec.digest(pinned)
        if mode == "compact" {
            guard let text = options["--expected-generation"], let expected = Int(text),
                  expected == before.generation, options["--expected-digest"] == digest else {
                throw VideoError.conflict("须先冻结同世代完整业务指纹；禁止重放未知维护")
            }
            try repository.transaction(expectedGeneration: expected) { state in
                guard state.generation == before.generation else { throw VideoError.conflict("维护世代改变") }
                // The ordinary validator and source verifier still run before
                // the single atomic save. This closure makes no business edit.
            }
        } else {
            guard options["--expected-generation"] == nil, options["--expected-digest"] == nil else {
                throw VideoError.invalid("只读指纹不接受写入前置参数")
            }
        }
        let after = try repository.read()
        guard try fingerprint(after) == pinned,
              after.generation == before.generation + (mode == "compact" ? 1 : 0) else {
            throw VideoError.conflict("保存表示维护后业务字段或历史不一致；保留原现场")
        }
        let receipt = Receipt(mode: mode, generationBefore: before.generation,
            generationAfter: after.generation, protectedSHA256: digest, fingerprint: pinned,
            revisionCount: pinned.revisions.count, noBusinessChanges: true)
        FileHandle.standardOutput.write(try Codec.data(receipt))
        FileHandle.standardOutput.write(Data([10]))
    }
    static func main() {
        do { try run() }
        catch let error as VideoError {
            FileHandle.standardError.write(Data((error.errorDescription ?? "维护失败").utf8))
            Darwin.exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("保存表示维护未完成；保留原现场".utf8))
            Darwin.exit(8)
        }
    }
}
