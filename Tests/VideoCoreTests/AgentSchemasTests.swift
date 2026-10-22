import XCTest
@testable import VideoCore

final class AgentSchemasTests:XCTestCase {
    func testDiscoveryShowsActualNestedRequiredFieldsAndEnumPayloads()throws {
        let schema=try XCTUnwrap(AgentContract.inputSchema("products import").object),defs=try XCTUnwrap(schema["$defs"]?.object)
        XCTAssertEqual(schema["properties"]?.object?["product"]?.object?["$ref"],.string("#/$defs/Product"))
        guard case .array(let fields)=defs["Product"]?.object?["required"] else{return XCTFail("required missing")}
        for key in ["id","workspaceID","sku","audience","task","outcome","prerequisite","scope","prices","assetIDs","tags","archived"] {XCTAssertTrue(fields.contains(.string(key)),key)}
        XCTAssertEqual(defs["Price"]?.object?["properties"]?.object?["money"]?.object?["$ref"],.string("#/$defs/Money"))
        guard case .array(let alternatives)=defs["Edit"]?.object?["oneOf"] else{return XCTFail("edit variants missing")}
        XCTAssertEqual(alternatives.count,12);XCTAssertTrue(alternatives.contains{$0.object?["properties"]?.object?["lockLayer"] != nil})
    }
    func testEncodedRepresentativeEntitiesHaveEveryRequiredNestedFieldAndResolvableRefs()throws {
        let defs=AgentSchemas.definitions(),p=Product(workspaceID:"w",sku:"one",name:"课程",checkout:"https://example.com",audience:"新人",task:"复现",outcome:"理解",prerequisite:"",scope:"知识",prices:[Price(money:Money(1),source:"产品页")])
        try verify(try value(p),schema:AgentSchemas.shape("Product"),defs:defs)
        var scene=Scene(title:"知识",body:"解释");scene.layers=[SceneLayer(kind:.text,text:"标签",endFrame:120)];scene.characterProfile=CharacterProfile(name:"圆仔");scene.speechPlan=SpeechPlan(source:"你好",normalized:"你好");scene.captions=[Caption(text:"你好",startFrame:0,endFrame:100)]
        try verify(try value(scene),schema:AgentSchemas.shape("Scene"),defs:defs)
        try verify(try value([Edit.replaceScene("scene",scene),Edit.music(nil),Edit.audioQuality(AudioQualityPolicy.example),Edit.lockLayer("scene","layer",true)]),schema:AgentSchemas.shape("[Edit]"),defs:defs)
        // No generated dangling reference can hide an undiscoverable mandatory DTO.
        func refs(_ node:AgentValue)throws {switch node{case .object(let o):if let ref=o["$ref"]?.string{XCTAssertNotNil(defs[String(ref.dropFirst("#/$defs/".count))],ref)};for v in o.values{try refs(v)};case .array(let a):for v in a{try refs(v)};default:break}}
        for definition in defs.values{try refs(definition)}
    }
    func testWorkerBoundsAndTypesAreCheckedBeforeRepositoryOrDryRun()throws {
        XCTAssertNoThrow(try AgentContract.validate(command:"worker launch",data:Data("{\"workspace_id\":\"w\",\"request_id\":\"r\",\"max_jobs\":2,\"timeout_seconds\":5,\"query_remote\":false}".utf8)))
        for fragment in ["\"max_jobs\":26","\"max_jobs\":1.5","\"timeout_seconds\":4","\"query_remote\":\"true\"","\"job_ids\":[{}]"] {XCTAssertThrowsError(try AgentContract.validate(command:"worker run",data:Data(("{\"workspace_id\":\"w\","+fragment+"}").utf8)))}
        XCTAssertThrowsError(try AgentContract.validate(command:"worker launch",data:Data("{\"workspace_id\":\"w\"}".utf8)))
        XCTAssertEqual(try AgentContract.describe("backup create").idempotency,"filesystem_export_non_atomic_no_request_replay")
        XCTAssertEqual(try AgentContract.describe("script create").idempotency,"atomic_database_request_receipt")
    }
    private func value<T:Encodable>(_ value:T)throws->AgentValue {try Codec.decoder().decode(AgentValue.self,from:Codec.data(value))}
    private func verify(_ value:AgentValue,schema:AgentValue,defs:[String:AgentValue])throws {
        guard let shape=schema.object else{return XCTFail("schema not object")}
        if let ref=shape["$ref"]?.string {try verify(value,schema:XCTUnwrap(defs[String(ref.dropFirst("#/$defs/".count))]),defs:defs);return}
        if case .array(let variants)=shape["oneOf"] {guard let object=value.object,let matched=variants.first(where:{$0.object?["properties"]?.object?.keys.first.map{object[$0] != nil} ?? false}) else{return XCTFail("enum case missing")};try verify(value,schema:matched,defs:defs);return}
        if case .array(let variants)=shape["anyOf"] {if value == .null{return};if let nonnull=variants.first(where:{$0.object?["type"] != .string("null")}){try verify(value,schema:nonnull,defs:defs)};return}
        if let properties=shape["properties"]?.object,let object=value.object {if case .array(let required)=shape["required"]{for field in required.compactMap(\.string){XCTAssertNotNil(object[field],field)}};for (name,child) in object{if let nested=properties[name]{try verify(child,schema:nested,defs:defs)}}}
        if case .array(let values)=value,let items=shape["items"]{for child in values{try verify(child,schema:items,defs:defs)}}
    }
}
