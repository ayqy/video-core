import Foundation

/// One explicit static change shared by named scenes. Empty instance arrays
/// mean no requested additions/replacements; omission of camera preserves it.
/// Nothing removes an instance or writes tracks, actions, audio or scene timing.
public struct ModelScene3DStaticPatch: Codable, Equatable, Sendable {
    public var sceneIDs: [String]
    public var appendInstances: [ModelInstance3D]
    public var replaceInstances: [ModelInstance3D]
    public var camera: ModelCamera3D?

    public init(sceneIDs: [String], appendInstances: [ModelInstance3D] = [], replaceInstances: [ModelInstance3D] = [], camera: ModelCamera3D? = nil) {
        self.sceneIDs=sceneIDs;self.appendInstances=appendInstances;self.replaceInstances=replaceInstances;self.camera=camera
    }
    private enum CodingKeys: String, CodingKey { case sceneIDs,appendInstances,replaceInstances,camera }
    public init(from decoder: Decoder) throws {
        try ModelSceneEditPatchWire.validate(try AgentValue(from:decoder),schema:AgentSchemas.shape("ModelScene3DStaticPatch"),definitions:AgentSchemas.definitions())
        try ModelStoryDecoding3D.keys(decoder,required:["sceneIDs","appendInstances","replaceInstances"],optional:["camera"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        sceneIDs=try c.decode([String].self,forKey:.sceneIDs)
        appendInstances=try c.decode([ModelInstance3D].self,forKey:.appendInstances)
        replaceInstances=try c.decode([ModelInstance3D].self,forKey:.replaceInstances)
        if c.contains(.camera) { camera=try c.decode(ModelCamera3D.self,forKey:.camera) }
        try validate()
    }
    public func validate() throws {
        let ids=appendInstances.map(\.id)+replaceInstances.map(\.id)
        guard (1...256).contains(sceneIDs.count),Set(sceneIDs).count==sceneIDs.count,
              sceneIDs.allSatisfy({PluginProtocolRules.text($0,maximum:160) && $0==$0.trimmingCharacters(in:.whitespacesAndNewlines)}),
              appendInstances.count<=128,replaceInstances.count<=128,Set(ids).count==ids.count,
              !ids.isEmpty || camera != nil else {
            throw VideoError.invalid("三维静态补丁须明确指定不重复场景及非空变更；实例标识不能重复或同时追加和替换")
        }
        for instance in appendInstances+replaceInstances {
            guard !(instance.nodeVariants ?? []).contains(where:{ $0.keyframes != nil }) else {
                throw VideoError.invalid("三维静态补丁不能编排动态节点切换，请使用完整场景编辑")
            }
            try instance.resource.validate();try instance.transform.validate()
        }
    }
    /// Resolve against the revision at this exact operation, then reuse the
    /// original replaceScene path for all locks, validation and invalidations.
    func replacements(in revision: Revision) throws -> [Edit] {
        try validate()
        return try sceneIDs.map { id in
            guard revision.scenes.filter({$0.id==id}).count==1,let original=revision.scenes.first(where:{$0.id==id}) else {throw VideoError.notFound("三维静态补丁的场景不存在或标识不唯一")}
            guard var model=original.modelScene3D else {throw VideoError.invalid("三维静态补丁只接受已有三维模型场景")}
            let originalIDs=Set(model.instances.map(\.id))
            guard appendInstances.allSatisfy({!originalIDs.contains($0.id)}),replaceInstances.allSatisfy({originalIDs.contains($0.id)}) else {
                throw VideoError.invalid("追加的三维实例必须尚不存在，替换的实例必须已存在于每个指定场景")
            }
            let animatedIDs=Set(model.transformTracks.map(\.instanceID)+model.jointTracks.map(\.instanceID)+(model.actions ?? []).map(\.instanceID))
            for replacement in replaceInstances {
                let old=model.instances.first(where:{$0.id==replacement.id})!
                guard !animatedIDs.contains(replacement.id),!(old.nodeVariants ?? []).contains(where:{$0.keyframes != nil}) else {
                    throw VideoError.permission("三维静态补丁不能替换参与运动、骨骼、原生动作或动态节点切换的实例")
                }
                guard old.locked==replacement.locked else {throw VideoError.permission("三维静态补丁不能隐式改变实例锁；请使用明确锁定操作")}
            }
            let replacements=Dictionary(uniqueKeysWithValues:replaceInstances.map{($0.id,$0)})
            model.instances=model.instances.map{replacements[$0.id] ?? $0}+appendInstances
            if let camera {model.camera=camera}
            var scene=original;scene.modelScene3D=model
            return .replaceScene(id,scene)
        }
    }
}

/// This patch is deliberately stricter than some legacy synthesized DTOs.
/// Walk the published field shapes only to reject unknown nested keys; normal
/// Codable/domain validation remains authoritative for values and source bytes.
enum ModelSceneEditPatchWire {
    static func validate(_ value: AgentValue, schema: AgentValue, definitions: [String:AgentValue]) throws {
        guard let shape=schema.object else {return}
        if let reference=shape["$ref"]?.string,let definition=definitions[String(reference.split(separator:"/").last ?? "")] {
            try validate(value,schema:definition,definitions:definitions);return
        }
        if case .array(let alternatives)=shape["anyOf"],alternatives.contains(where:{$0.object?["type"]?.string=="null"}),value != .null,let concrete=alternatives.first(where:{$0.object?["type"]?.string != "null"}) {
            try validate(value,schema:concrete,definitions:definitions);return
        }
        if let fields=value.object {
            if let properties=shape["properties"]?.object {
                guard Set(fields.keys).isSubset(of:Set(properties.keys)) else {throw VideoError.invalid("三维静态补丁包含未知字段，不能静默忽略")}
                for (key,child) in fields {try validate(child,schema:properties[key]!,definitions:definitions)}
            } else if let items=shape["additionalProperties"],items.object != nil {
                for child in fields.values {try validate(child,schema:items,definitions:definitions)}
            }
        } else if case .array(let values)=value,let items=shape["items"] {
            for child in values {try validate(child,schema:items,definitions:definitions)}
        }
    }
}

public enum ModelSceneEditPatchSchema {
    public static let records: [String:String] = [
        "ModelScene3DStaticPatch":"sceneIDs:[s] appendInstances:[ModelInstance3D] replaceInstances:[ModelInstance3D] camera?:ModelCamera3D"
    ]
}
