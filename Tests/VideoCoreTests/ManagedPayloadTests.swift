import XCTest
import VideoCore
import Darwin

final class ManagedPayloadTests:XCTestCase {
    private let fm=FileManager.default
    private var temporary:[URL]=[]
    override func tearDown(){for url in temporary{try? fm.removeItem(at:url)};temporary=[];super.tearDown()}
    private func directory()->URL {
        let url=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("video-payload-test-"+Codec.id());temporary.append(url);return url
    }
    private func sources(product:ManagedReleaseProduct)throws->[String:URL] {
        let root=directory();try fm.createDirectory(at:root,withIntermediateDirectories:false)
        var result:[String:URL]=[:]
        for (index,name) in ManagedPayloadRules.requiredPaths(for:product).sorted().enumerated() {
            let file=root.appendingPathComponent("source-\(index)")
            let bytes=name=="publisher.pub" ? Data(repeating:9,count:32):Data(("isolated "+name).utf8)
            try bytes.write(to:file);try fm.setAttributes([.posixPermissions:name==product.entrypoint ? 0o700:0o600],ofItemAtPath:file.path)
            result[name]=file
        }
        return result
    }
    func testAdvancedPreparationIncludesSeparateLicensesAndRechecksBeforePublication()throws {
        let sources=try sources(product:.advancedCLI),output=directory();var checks=0
        let expected=try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:sources,output:output) {root,files in
            checks+=1;XCTAssertFalse(self.fm.fileExists(atPath:output.path));XCTAssertEqual(try ManagedReleaseRules.inventory(root),files)
        }
        XCTAssertEqual(checks,1);XCTAssertEqual(expected.count,8)
        XCTAssertEqual(try ManagedReleaseRules.inventory(output),expected)
        for name in ["LICENSE","NOTICE","licenses/VideoAdvanced.txt","licenses/VideoGame.txt","licenses/VideoCartoon.txt"] {
            XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent(name)),try Data(contentsOf:sources[name]!))
        }
    }
    func testFailureAfterCopyPreservesExistingOutputAndRemovesStaging()throws {
        let sources=try sources(product:.advancedCLI),parent=directory();try fm.createDirectory(at:parent,withIntermediateDirectories:false)
        let output=parent.appendingPathComponent("prepared")
        XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:sources,output:output) {_,_ in
            throw VideoError.permission("isolated catalog mismatch")
        })
        XCTAssertFalse(fm.fileExists(atPath:output.path));XCTAssertEqual(try fm.contentsOfDirectory(atPath:parent.path),[])
        try fm.createDirectory(at:output,withIntermediateDirectories:false)
        let sentinel=Data("already prepared; preserve".utf8);try sentinel.write(to:output.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:sources,output:output){_,_ in XCTFail("existing output must not be validated or touched")})
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("sentinel")),sentinel)
    }
    func testTargetCreatedDuringValidationCannotBeOverwritten()throws {
        let sources=try sources(product:.advancedCLI),output=directory(),sentinel=Data("concurrent creator".utf8)
        XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:sources,output:output){_,_ in
            try self.fm.createDirectory(at:output,withIntermediateDirectories:false)
            try sentinel.write(to:output.appendingPathComponent("sentinel"))
        })
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("sentinel")),sentinel)
    }
    func testValidationCannotMutateOrAddFilesBeforeAtomicPublication()throws {
        for extra in [false,true] {
            let sources=try sources(product:.advancedCLI),output=directory()
            XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:sources,output:output){root,_ in
                try Data("changed".utf8).write(to:root.appendingPathComponent(extra ? "private.swift":"LICENSE"))
            })
            XCTAssertFalse(fm.fileExists(atPath:output.path))
        }
    }
    func testMissingDisclosureOrExtraSourceMapCredentialAndUserLicenseAreRejected()throws {
        let sources=try sources(product:.advancedCLI),legal=try XCTUnwrap(sources["LICENSE"])
        for name in ["Sources/Game.swift","bin/video-advanced.dSYM","video.js.map","private.pem","credentials.txt","independent.videolicense"] {
            var changed=sources;changed[name]=legal
            XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:changed,output:directory()){_,_ in XCTFail("layout must be checked before validation")})
        }
        for name in ["LICENSE","NOTICE","licenses/VideoGame.txt"] {
            var changed=sources;changed.removeValue(forKey:name)
            XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:changed,output:directory()){_,_ in XCTFail("missing disclosure must be checked before validation")})
        }
    }
    func testSourceLinksAndNonExecutableEntrypointAreRejected()throws {
        let original=try sources(product:.advancedCLI),license=original["LICENSE"]!,link=directory()
        try fm.createSymbolicLink(at:link,withDestinationURL:license)
        var sources=original;sources["LICENSE"]=link
        XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:sources,output:directory()){_,_ in})
        try fm.removeItem(at:link);try fm.linkItem(at:license,to:link)
        XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:sources,output:directory()){_,_ in})
        try fm.removeItem(at:link)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:original[ManagedReleaseProduct.advancedCLI.entrypoint]!.path)
        XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:original,output:directory()){_,_ in})
    }
    func testPipeSourceIsRejectedWithoutWaitingForAWriter()throws {
        var sources=try sources(product:.advancedCLI);let pipe=directory()
        XCTAssertEqual(mkfifo(pipe.path,0o600),0);sources["LICENSE"]=pipe
        let started=Date()
        XCTAssertThrowsError(try ManagedPayloadPreparation.prepare(product:.advancedCLI,sources:sources,output:directory()){_,_ in})
        XCTAssertLessThan(Date().timeIntervalSince(started),2)
    }
    func testSignedManifestValidationCannotBypassBinaryLayoutRules()throws {
        let sources=try sources(product:.coreCLI),output=directory(),key=Data(repeating:7,count:32)
        var files=try ManagedPayloadPreparation.prepare(product:.coreCLI,sources:sources,output:output){_,_ in}
        let valid=ManagedReleaseManifest(product:.coreCLI,version:"1.0.0",build:1,architecture:"x86_64",minimumRollbackBuild:1,publisherKeySHA256:Codec.hash(key),appleTeamID:"TEST",files:files)
        XCTAssertNoThrow(try ManagedReleaseRules.validate(valid,publicKey:key,architecture:"x86_64",osMajor:14,teamID:"TEST"))
        files.append(ManagedReleaseFile(path:"hidden.swift",sha256:String(repeating:"0",count:64),bytes:1,executable:false))
        var invalid=valid;invalid.files=files
        XCTAssertThrowsError(try ManagedReleaseRules.validate(invalid,publicKey:key,architecture:"x86_64",osMajor:14,teamID:"TEST"))
        invalid.files=valid.files.filter{$0.path != "LICENSE"}
        XCTAssertThrowsError(try ManagedReleaseRules.validate(invalid,publicKey:key,architecture:"x86_64",osMajor:14,teamID:"TEST"))
    }
}
