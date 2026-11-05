import Foundation

/// Scene coordinates are right-handed, Y-up metres. No filesystem paths or
/// implicit animation clips enter the editable project contract.
public struct ModelVector3: Codable, Hashable, Sendable {
    public var x: Double; public var y: Double; public var z: Double
    public init(x: Double = 0, y: Double = 0, z: Double = 0) { self.x=x; self.y=y; self.z=z }
    fileprivate var bounded: Bool { [x,y,z].allSatisfy { $0.isFinite && abs($0)<=1_000_000 } }
    fileprivate static func mix(_ a: Self, _ b: Self, _ t: Double) -> Self { .init(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t,z:a.z+(b.z-a.z)*t) }
}
public struct ModelQuaternion: Codable, Hashable, Sendable {
    public var x: Double; public var y: Double; public var z: Double; public var w: Double
    public init(x: Double = 0, y: Double = 0, z: Double = 0, w: Double = 1) { self.x=x; self.y=y; self.z=z; self.w=w }
    fileprivate func validate() throws {
        guard [x,y,z,w].allSatisfy({$0.isFinite && abs($0)<=1.000001}), abs(x*x+y*y+z*z+w*w-1)<=0.000001 else { throw VideoError.invalid("三维旋转须为单位四元数") }
    }
    fileprivate static func mix(_ a: Self, _ original: Self, _ t: Double) -> Self {
        var b=original
        var dot=a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w
        if dot<0 { b = .init(x:-b.x,y:-b.y,z:-b.z,w:-b.w); dot = -dot }
        dot=min(1,max(-1,dot))
        let left: Double, right: Double
        if dot>0.9995 { left=1-t; right=t }
        else { let angle=acos(dot), denominator=sin(angle); left=sin((1-t)*angle)/denominator; right=sin(t*angle)/denominator }
        let x=left*a.x+right*b.x, y=left*a.y+right*b.y, z=left*a.z+right*b.z, w=left*a.w+right*b.w
        let norm=sqrt(x*x+y*y+z*z+w*w)
        return .init(x:x/norm,y:y/norm,z:z/norm,w:w/norm)
    }
}
/// Translation, quaternion rotation and positive local scale, applied as T*R*S.
public struct ModelTransform3D: Codable, Hashable, Sendable {
    public var translation: ModelVector3; public var rotation: ModelQuaternion; public var scale: ModelVector3
    public init(translation: ModelVector3 = .init(), rotation: ModelQuaternion = .init(), scale: ModelVector3 = .init(x:1,y:1,z:1)) { self.translation=translation; self.rotation=rotation; self.scale=scale }
    public func validate() throws {
        guard translation.bounded,scale.bounded,[scale.x,scale.y,scale.z].allSatisfy({(0.0001...10000).contains($0)}) else { throw VideoError.invalid("三维平移或正缩放超出范围") }
        try rotation.validate()
    }
    fileprivate static func mix(_ a: Self, _ b: Self, _ t: Double) -> Self { .init(translation:.mix(a.translation,b.translation,t),rotation:.mix(a.rotation,b.rotation,t),scale:.mix(a.scale,b.scale,t)) }
}
/// Explicit interpretation of unchanged source attributes; never inferred from
/// a game name, inventory entry, texture filename or sampled pixel values.
public enum ModelVertexColorUsage: String, Codable, Hashable, CaseIterable, Sendable { case source, ignored }
public enum ModelNormalTextureEncoding: String, Codable, Hashable, CaseIterable, Sendable { case rgb, redGreenPositiveZ }
public struct ModelMaterialInterpretation: Codable, Hashable, Sendable {
    public var vertexColors: ModelVertexColorUsage
    public var normalEncoding: ModelNormalTextureEncoding
    /// Explicit source material IDs whose diffuse alpha is interpreted as opaque.
    /// Nil retains source alpha; this never changes source texture or vertex bytes.
    public var opaqueDiffuseMaterialIDs: [String]?
    public init(vertexColors: ModelVertexColorUsage = .source, normalEncoding: ModelNormalTextureEncoding = .rgb, opaqueDiffuseMaterialIDs: [String]? = nil) {
        self.vertexColors=vertexColors;self.normalEncoding=normalEncoding;self.opaqueDiffuseMaterialIDs=opaqueDiffuseMaterialIDs
    }
}
public struct ModelInstance3D: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var name: String; public var resource: ModelDAEResource; public var transform: ModelTransform3D; public var locked: Bool
    /// Nil preserves the legacy wire representation and source/rgb behavior.
    public var materialInterpretation: ModelMaterialInterpretation?
    public init(id: String, name: String, resource: ModelDAEResource, transform: ModelTransform3D = .init(), locked: Bool = false, materialInterpretation: ModelMaterialInterpretation? = nil) { self.id=id; self.name=name; self.resource=resource; self.transform=transform; self.locked=locked;self.materialInterpretation=materialInterpretation }
}
public struct ModelTransformKeyframe: Codable, Equatable, Sendable {
    public var frame: Int; public var transform: ModelTransform3D
    public init(frame: Int, transform: ModelTransform3D) { self.frame=frame; self.transform=transform }
}
public struct ModelTransformTrack: Codable, Equatable, Sendable {
    public var instanceID: String; public var keyframes: [ModelTransformKeyframe]
    public init(instanceID: String, keyframes: [ModelTransformKeyframe]) { self.instanceID=instanceID; self.keyframes=keyframes }
}
/// Each value is an explicit delta from the original DAE joint's local bind
/// transform: localBind * delta. Joint names must exist in the parsed source.
public struct ModelJointTrack: Codable, Equatable, Sendable {
    public var instanceID: String; public var jointName: String; public var keyframes: [ModelTransformKeyframe]
    public init(instanceID: String, jointName: String, keyframes: [ModelTransformKeyframe]) { self.instanceID=instanceID; self.jointName=jointName; self.keyframes=keyframes }
}
public struct ModelCamera3D: Codable, Equatable, Sendable {
    public var position: ModelVector3; public var target: ModelVector3; public var up: ModelVector3
    public var verticalFieldOfViewDegrees: Double; public var near: Double; public var far: Double
    public init(position: ModelVector3, target: ModelVector3, up: ModelVector3 = .init(x:0,y:1,z:0), verticalFieldOfViewDegrees: Double = 45, near: Double = 0.01, far: Double = 1000) { self.position=position; self.target=target; self.up=up; self.verticalFieldOfViewDegrees=verticalFieldOfViewDegrees; self.near=near; self.far=far }
    fileprivate func validate() throws {
        let dx=target.x-position.x,dy=target.y-position.y,dz=target.z-position.z
        let length=dx*dx+dy*dy+dz*dz,upLength=up.x*up.x+up.y*up.y+up.z*up.z
        let cross=(dy*up.z-dz*up.y)*(dy*up.z-dz*up.y)+(dz*up.x-dx*up.z)*(dz*up.x-dx*up.z)+(dx*up.y-dy*up.x)*(dx*up.y-dy*up.x)
        guard position.bounded,target.bounded,up.bounded,length>0.00000001,abs(upLength-1)<=0.000001,cross/length>0.00000001,
              verticalFieldOfViewDegrees.isFinite,(1...175).contains(verticalFieldOfViewDegrees),near.isFinite,far.isFinite,near>=0.0001,far>near,far<=1_000_000 else { throw VideoError.invalid("三维相机视向、上方向、透视或裁切范围无效") }
    }
}
public enum ModelLightKind: String, Codable, Sendable { case ambient, directional, omni }
public struct ModelLight3D: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var kind: ModelLightKind; public var color: String; public var intensity: Double; public var transform: ModelTransform3D
    public init(id: String, kind: ModelLightKind, color: String = "FFFFFF", intensity: Double = 1000, transform: ModelTransform3D = .init()) { self.id=id; self.kind=kind; self.color=color; self.intensity=intensity; self.transform=transform }
}
/// Editable source-frame contract only. Saving this data does not assert that a
/// compatible signed renderer is installed or that any ACNH effect was reviewed.
public struct ModelScene3D: Codable, Equatable, Sendable {
    public var version: Int; public var instances: [ModelInstance3D]; public var camera: ModelCamera3D; public var lights: [ModelLight3D]
    public var transformTracks: [ModelTransformTrack]; public var jointTracks: [ModelJointTrack]
    /// Explicit v2 only. Nil preserves the exact v1 wire representation.
    /// These are operations on actual native instances and original joints,
    /// never two-dimensional stand-ins for a rule event.
    public var actions: [ModelStoryAction3D]?
    public init(version: Int = 1, instances: [ModelInstance3D], camera: ModelCamera3D, lights: [ModelLight3D], transformTracks: [ModelTransformTrack] = [], jointTracks: [ModelJointTrack] = [], actions: [ModelStoryAction3D]? = nil) { self.version=version; self.instances=instances; self.camera=camera; self.lights=lights; self.transformTracks=transformTracks; self.jointTracks=jointTracks; self.actions=actions }
    private enum CodingKeys: String, CodingKey { case version,instances,camera,lights,transformTracks,jointTracks,actions }
    public init(from decoder: Decoder) throws {
        try ModelStoryDecoding3D.keys(decoder,required:["version","instances","camera","lights","transformTracks","jointTracks"],optional:["actions"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version);instances=try c.decode([ModelInstance3D].self,forKey:.instances)
        camera=try c.decode(ModelCamera3D.self,forKey:.camera);lights=try c.decode([ModelLight3D].self,forKey:.lights)
        transformTracks=try c.decode([ModelTransformTrack].self,forKey:.transformTracks);jointTracks=try c.decode([ModelJointTrack].self,forKey:.jointTracks)
        if c.contains(.actions) {
            guard version==2,!(try c.decodeNil(forKey:.actions)) else {throw VideoError.invalid("三维动作须显式使用v2，旧v1不接受隐藏动作、空值或新字段")}
            actions=try c.decode([ModelStoryAction3D].self,forKey:.actions)
            guard !(actions?.isEmpty ?? true) else {throw VideoError.invalid("三维v2须有实际原生动作")}
        } else {
            guard version==1 else {throw VideoError.invalid("三维v2必须声明实际原生动作；未知版本不会降级")}
            actions=nil
        }
    }
    public var assetIDs: Set<String> { instances.reduce(into:Set<String>()) { $0.formUnion($1.resource.assetIDs) } }
    private struct DigestInput: Encodable { let scene: ModelScene3D; let durationFrames: Int }
    public func contentDigest(durationFrames: Int) throws -> String { try validate(durationFrames:durationFrames);return try Codec.digest(DigestInput(scene:self,durationFrames:durationFrames)) }
    public func validate(durationFrames: Int, assets: [Asset]? = nil) throws {
        guard ((version==1 && actions==nil) || (version==2 && !(actions?.isEmpty ?? true))),(1...54000).contains(durationFrames),(1...128).contains(instances.count),(1...16).contains(lights.count),transformTracks.count<=128,jointTracks.count<=4096,
              Set(instances.map(\.id)).count==instances.count,Set(lights.map(\.id)).count==lights.count,Set(instances.map(\.id)).isDisjoint(with:Set(lights.map(\.id))) else { throw VideoError.invalid("三维场景版本、实例、灯光数量或标识无效") }
        try camera.validate()
        var bindings: [String:ModelAssetReference]=[:]
        for instance in instances {
            guard PluginProtocolRules.text(instance.id,maximum:160),PluginProtocolRules.text(instance.name,maximum:160) else { throw VideoError.invalid("三维实例须有明确标识和名称") }
            try instance.transform.validate();try instance.resource.validate(assets:assets)
            if let ids=instance.materialInterpretation?.opaqueDiffuseMaterialIDs {
                let sourceIDs=Set(instance.resource.inspection.materials.map(\.id))
                guard (1...128).contains(ids.count),Set(ids).count==ids.count,
                      ids.allSatisfy({PluginProtocolRules.text($0,maximum:160) && $0 == $0.trimmingCharacters(in:.whitespacesAndNewlines) && sourceIDs.contains($0)}) else { throw VideoError.invalid("不透明漫反射须明确指定1至128个不重复的原DAE材质标识") }
            }
            if let assets {
                guard assets.first(where:{$0.id==instance.resource.model.assetID})?.mediaType == "model3d" else { throw VideoError.invalid("三维实例须绑定已入库的真实模型类型") }
                for texture in instance.resource.textures.values {
                    guard let asset=assets.first(where:{$0.id==texture.assetID}),asset.mediaType=="image" || asset.mediaType.hasPrefix("image/") else { throw VideoError.invalid("三维纹理须绑定已入库图片") }
                }
            }
            for reference in [instance.resource.model]+Array(instance.resource.textures.values) {
                guard bindings[reference.assetID]==nil || bindings[reference.assetID]==reference else { throw VideoError.invalid("同一模型场景不能为同一素材声明不同字节") }
                bindings[reference.assetID]=reference
            }
        }
        guard bindings.count<=4096,bindings.values.reduce(Int64(0),{$0+Int64($1.bytes)})<=536_870_912 else { throw VideoError.invalid("三维场景去重资源超过512MiB或4096文件") }
        for light in lights {
            guard PluginProtocolRules.text(light.id,maximum:160),light.color.utf8.count==6,light.color.range(of:"^[A-Fa-f0-9]{6}$",options:.regularExpression) != nil,light.intensity.isFinite,(0...100000).contains(light.intensity) else { throw VideoError.invalid("三维灯光标识、颜色或强度无效") }
            try light.transform.validate()
        }
        var targets=Set<String>(), jointTargets=Set<String>(), totalFrames=0
        for track in transformTracks {
            guard instances.contains(where:{$0.id==track.instanceID}),targets.insert(track.instanceID).inserted else { throw VideoError.invalid("三维位置轨道须唯一绑定实际实例") }
            try Self.validate(track.keyframes,durationFrames:durationFrames);totalFrames+=track.keyframes.count
        }
        for track in jointTracks {
            guard let instance=instances.first(where:{$0.id==track.instanceID}),instance.resource.inspection.jointNames.contains(track.jointName),jointTargets.insert(track.instanceID+"\u{0}"+track.jointName).inserted else { throw VideoError.invalid("骨骼轨道须唯一绑定实际DAE关节，不能以自造名字冒原骨架") }
            try Self.validate(track.keyframes,durationFrames:durationFrames);totalFrames+=track.keyframes.count
        }
        guard totalFrames<=65536 else { throw VideoError.invalid("三维动作关键帧超过总上限") }
        if let actions {try ModelStoryActionRules3D.validateVerifiedModel(actions,model:self,durationFrames:durationFrames)}
    }
    private static func validate(_ frames: [ModelTransformKeyframe], durationFrames: Int) throws {
        guard (1...4096).contains(frames.count),frames.first?.frame==0,frames.last?.frame==durationFrames-1 else { throw VideoError.invalid("三维轨道须明确覆盖完整源帧区间") }
        var previous = -1
        for key in frames {
            guard key.frame>previous,key.frame<durationFrames else { throw VideoError.invalid("三维动作关键帧须按源帧严格递增") }
            try key.transform.validate();previous=key.frame
        }
    }
    /// Deterministic source-frame sampling; quaternion rotations use shortest-arc
    /// slerp, translation and positive scale are linear. No inferred walk cycle.
    public func sampledTransform(instanceID: String, jointName: String? = nil, sourceFrame: Int, durationFrames: Int) throws -> ModelTransform3D {
        try validate(durationFrames:durationFrames)
        guard (0..<durationFrames).contains(sourceFrame),let instance=instances.first(where:{$0.id==instanceID}) else { throw VideoError.invalid("三维采样须指定实际实例及有效源帧") }
        let keys: [ModelTransformKeyframe]
        if let jointName {
            guard instance.resource.inspection.jointNames.contains(jointName) else { throw VideoError.invalid("采样关节不在实际DAE骨架") }
            keys=jointTracks.first{$0.instanceID==instanceID && $0.jointName==jointName}?.keyframes ?? []
        } else { keys=transformTracks.first{$0.instanceID==instanceID}?.keyframes ?? [] }
        return Self.sample(keys:keys,fallback:jointName==nil ? instance.transform:.init(),sourceFrame:sourceFrame)
    }
    /// Internal sampling of already validated original tracks. Action validation
    /// uses this primitive instead of recursively validating the whole model.
    static func sample(keys:[ModelTransformKeyframe],fallback:ModelTransform3D,sourceFrame:Int)->ModelTransform3D {
        guard let first=keys.first else {return fallback}
        if sourceFrame<=first.frame {return first.transform}
        guard let index=keys.firstIndex(where:{$0.frame>=sourceFrame}) else {return keys.last!.transform}
        let a=keys[index-1],b=keys[index]
        return .mix(a.transform,b.transform,Double(sourceFrame-a.frame)/Double(b.frame-a.frame))
    }
}
public enum ModelScene3DRules {
    public static func validate(scene: Scene, assets: [Asset]? = nil) throws {
        guard let model=scene.modelScene3D else {return}
        guard scene.kind == .simulation,scene.assetID==nil,scene.gameWorld==nil,scene.classicArtwork==nil,scene.cartoonRig==nil,scene.cartoonPresenter==nil,scene.cartoonPerformance==nil,scene.storyActions==nil,(scene.storyCausality==nil || model.version==2),scene.simulationPresentation==nil else { throw VideoError.invalid("三维模型场景须独立绑定仿真镜头，不能混旧二维地图、图集或二维过程动作；真实因果只支持显式三维v2") }
        if model.version==2 {
            guard scene.sourceStartFrame==0,(scene.sourceEndFrame==nil || scene.sourceEndFrame==scene.durationFrames),scene.speed==1,scene.pauseFrames==0 else {throw VideoError.invalid("三维v2动作使用完整源帧轴，尚不支持裁切、重定时或附加停顿")}
        }
        guard Set((scene.layers ?? []).map(\.id)).isDisjoint(with:Set(model.instances.map(\.id))) else {throw VideoError.invalid("三维实例与叠加图层标识不能冲突")}
        try model.validate(durationFrames:scene.durationFrames,assets:assets)
    }
    public static func protectLocked(old: Scene, new: Scene) throws {
        guard let previous=old.modelScene3D,previous.instances.contains(where:{$0.locked}) else {return}
        guard let next=new.modelScene3D,old.durationFrames==new.durationFrames,old.speed==new.speed,old.pauseFrames==new.pauseFrames else { throw VideoError.permission("请先解锁三维实例，再移除场景或改动作时基") }
        for item in previous.instances where item.locked {
            guard next.instances.first(where:{$0.id==item.id})==item,previous.transformTracks.filter({$0.instanceID==item.id})==next.transformTracks.filter({$0.instanceID==item.id}),previous.jointTracks.filter({$0.instanceID==item.id})==next.jointTracks.filter({$0.instanceID==item.id}),(previous.actions ?? []).filter({$0.instanceID==item.id})==(next.actions ?? []).filter({$0.instanceID==item.id}) else { throw VideoError.permission("已锁定三维实例的资源、变换、骨骼动作或原生表现不能改变") }
        }
    }
}
public enum ModelScene3DSchema {
    public static let records: [String:String] = [
        "ModelAssetReference":"assetID:s sha256:s bytes:i fileExtension:s",
        "DAEImageReference":"id:s relativePath:s", "DAEMaterialReference":"id:s effectID:s",
        "DAEInspection":"sha256:s bytes:i images:[DAEImageReference] geometryIDs:[s] materials:[DAEMaterialReference] jointNames:[s] nodeIDs:[s] textureCoordinateSets:[i] unitMeters:n upAxis:s animationCount:i",
        "ModelDAEResource":"model:ModelAssetReference inspection:DAEInspection textures:{ModelAssetReference}",
        "ModelVector3":"x:n y:n z:n", "ModelQuaternion":"x:n y:n z:n w:n",
        "ModelTransform3D":"translation:ModelVector3 rotation:ModelQuaternion scale:ModelVector3",
        "ModelMaterialInterpretation":"vertexColors:ModelVertexColorUsage normalEncoding:ModelNormalTextureEncoding opaqueDiffuseMaterialIDs?:[s]",
        "ModelInstance3D":"id:s name:s resource:ModelDAEResource transform:ModelTransform3D locked:b materialInterpretation?:ModelMaterialInterpretation",
        "ModelTransformKeyframe":"frame:i transform:ModelTransform3D",
        "ModelTransformTrack":"instanceID:s keyframes:[ModelTransformKeyframe]",
        "ModelJointTrack":"instanceID:s jointName:s keyframes:[ModelTransformKeyframe]",
        "ModelCamera3D":"position:ModelVector3 target:ModelVector3 up:ModelVector3 verticalFieldOfViewDegrees:n near:n far:n",
        "ModelLight3D":"id:s kind:ModelLightKind color:s intensity:n transform:ModelTransform3D",
        "ModelScene3D":"version:i instances:[ModelInstance3D] camera:ModelCamera3D lights:[ModelLight3D] transformTracks:[ModelTransformTrack] jointTracks:[ModelJointTrack]"
    ]
}
