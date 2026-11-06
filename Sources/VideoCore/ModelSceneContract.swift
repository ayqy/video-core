import Foundation

/// Scene coordinates are right-handed, Y-up metres. No filesystem paths or
/// implicit animation clips enter the editable project contract.
public struct ModelVector3: Codable, Hashable, Sendable {
    public var x: Double; public var y: Double; public var z: Double
    public init(x: Double = 0, y: Double = 0, z: Double = 0) { self.x=x; self.y=y; self.z=z }
    private enum CodingKeys: String, CodingKey { case x,y,z }
    public init(from decoder: Decoder) throws {
        try ModelStoryDecoding3D.keys(decoder,required:["x","y","z"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        x=try c.decode(Double.self,forKey:.x);y=try c.decode(Double.self,forKey:.y);z=try c.decode(Double.self,forKey:.z)
    }
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
    /// Explicit source material IDs whose original alphaOne transparent alpha is
    /// cut out below 0.5. May overlap opaque diffuse IDs; nil retains source behavior.
    /// This visual interpretation requires game12 and never rewrites source bytes.
    public var alphaCutoutMaterialIDs: [String]?
    public init(vertexColors: ModelVertexColorUsage = .source, normalEncoding: ModelNormalTextureEncoding = .rgb, opaqueDiffuseMaterialIDs: [String]? = nil, alphaCutoutMaterialIDs: [String]? = nil) {
        self.vertexColors=vertexColors;self.normalEncoding=normalEncoding;self.opaqueDiffuseMaterialIDs=opaqueDiffuseMaterialIDs;self.alphaCutoutMaterialIDs=alphaCutoutMaterialIDs
    }
    private enum CodingKeys:String,CodingKey {case vertexColors,normalEncoding,opaqueDiffuseMaterialIDs,alphaCutoutMaterialIDs}
    public init(from decoder:Decoder)throws {
        try ModelStoryDecoding3D.keys(decoder,required:["vertexColors","normalEncoding"],optional:["opaqueDiffuseMaterialIDs","alphaCutoutMaterialIDs"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        vertexColors=try c.decode(ModelVertexColorUsage.self,forKey:.vertexColors);normalEncoding=try c.decode(ModelNormalTextureEncoding.self,forKey:.normalEncoding)
        opaqueDiffuseMaterialIDs=try c.decodeIfPresent([String].self,forKey:.opaqueDiffuseMaterialIDs)
        alphaCutoutMaterialIDs=try c.decodeIfPresent([String].self,forKey:.alphaCutoutMaterialIDs)
    }
}
/// An explicit step change between mutually exclusive original DAE nodes.
/// Frame zero uses the group's default; no expression or filename is inferred.
public struct ModelNodeVariantKeyframe: Codable, Equatable, Sendable {
    public var frame: Int
    public var nodeID: String
    public init(frame: Int, nodeID: String) { self.frame=frame;self.nodeID=nodeID }
    private enum CodingKeys:String,CodingKey {case frame,nodeID}
    public init(from decoder:Decoder)throws {
        try ModelStoryDecoding3D.keys(decoder,required:["frame","nodeID"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        frame=try c.decode(Int.self,forKey:.frame);nodeID=try c.decode(String.self,forKey:.nodeID)
    }
}
/// Visibility only: all original meshes, textures and joints remain intact.
/// Native loaders must reject ambiguous node identities or overlapping branches.
public struct ModelNodeVariantGroup: Codable, Equatable, Sendable {
    public var id: String
    public var nodeIDs: [String]
    public var defaultNodeID: String
    public var keyframes: [ModelNodeVariantKeyframe]?
    public init(id:String,nodeIDs:[String],defaultNodeID:String,keyframes:[ModelNodeVariantKeyframe]?=nil) {
        self.id=id;self.nodeIDs=nodeIDs;self.defaultNodeID=defaultNodeID;self.keyframes=keyframes
    }
    private enum CodingKeys:String,CodingKey {case id,nodeIDs,defaultNodeID,keyframes}
    public init(from decoder:Decoder)throws {
        try ModelStoryDecoding3D.keys(decoder,required:["id","nodeIDs","defaultNodeID"],optional:["keyframes"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);nodeIDs=try c.decode([String].self,forKey:.nodeIDs)
        defaultNodeID=try c.decode(String.self,forKey:.defaultNodeID)
        if c.contains(.keyframes) {keyframes=try c.decode([ModelNodeVariantKeyframe].self,forKey:.keyframes)}
    }
    /// Already-validated immutable input; arbitrary source-frame order is safe.
    public func selectedNodeID(at sourceFrame:Int)->String {
        guard let keys=keyframes,!keys.isEmpty,sourceFrame>=keys[0].frame else {return defaultNodeID}
        var low=0,high=keys.count
        while low<high {let middle=low+(high-low)/2;if keys[middle].frame<=sourceFrame {low=middle+1}else{high=middle}}
        return keys[low-1].nodeID
    }
}
public struct ModelInstance3D: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var name: String; public var resource: ModelDAEResource; public var transform: ModelTransform3D; public var locked: Bool
    /// Nil preserves the legacy wire representation and source/rgb behavior.
    public var materialInterpretation: ModelMaterialInterpretation?
    /// Nil preserves legacy bytes. Explicit selections require game schema 11.
    public var nodeVariants: [ModelNodeVariantGroup]?
    public init(id: String, name: String, resource: ModelDAEResource, transform: ModelTransform3D = .init(), locked: Bool = false, materialInterpretation: ModelMaterialInterpretation? = nil, nodeVariants:[ModelNodeVariantGroup]?=nil) { self.id=id; self.name=name; self.resource=resource; self.transform=transform; self.locked=locked;self.materialInterpretation=materialInterpretation;self.nodeVariants=nodeVariants }
    private enum CodingKeys:String,CodingKey {case id,name,resource,transform,locked,materialInterpretation,nodeVariants}
    public init(from decoder:Decoder)throws {
        try ModelStoryDecoding3D.keys(decoder,required:["id","name","resource","transform","locked"],optional:["materialInterpretation","nodeVariants"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
        resource=try c.decode(ModelDAEResource.self,forKey:.resource);transform=try c.decode(ModelTransform3D.self,forKey:.transform)
        locked=try c.decode(Bool.self,forKey:.locked);materialInterpretation=try c.decodeIfPresent(ModelMaterialInterpretation.self,forKey:.materialInterpretation)
        if c.contains(.nodeVariants) {nodeVariants=try c.decode([ModelNodeVariantGroup].self,forKey:.nodeVariants)}
    }
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
/// A complete authored camera pose at an integer source frame. The parent
/// camera supplies the fixed up vector and clipping planes for the whole take.
public struct ModelCameraKeyframe3D: Codable, Equatable, Sendable {
    public var frame: Int
    public var position: ModelVector3; public var target: ModelVector3
    public var verticalFieldOfViewDegrees: Double
    public init(frame: Int, position: ModelVector3, target: ModelVector3, verticalFieldOfViewDegrees: Double) {
        self.frame=frame;self.position=position;self.target=target;self.verticalFieldOfViewDegrees=verticalFieldOfViewDegrees
    }
    private enum CodingKeys: String, CodingKey { case frame,position,target,verticalFieldOfViewDegrees }
    public init(from decoder: Decoder) throws {
        try ModelStoryDecoding3D.keys(decoder,required:["frame","position","target","verticalFieldOfViewDegrees"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        frame=try c.decode(Int.self,forKey:.frame);position=try c.decode(ModelVector3.self,forKey:.position)
        target=try c.decode(ModelVector3.self,forKey:.target);verticalFieldOfViewDegrees=try c.decode(Double.self,forKey:.verticalFieldOfViewDegrees)
    }
}
public struct ModelCamera3D: Codable, Equatable, Sendable {
    public var position: ModelVector3; public var target: ModelVector3; public var up: ModelVector3
    public var verticalFieldOfViewDegrees: Double; public var near: Double; public var far: Double
    /// Nil keeps legacy bytes and a stationary camera. Explicit keys require
    /// game13; keys outside the first/last authored pose hold that endpoint.
    public var keyframes: [ModelCameraKeyframe3D]?
    public init(position: ModelVector3, target: ModelVector3, up: ModelVector3 = .init(x:0,y:1,z:0), verticalFieldOfViewDegrees: Double = 45, near: Double = 0.01, far: Double = 1000, keyframes: [ModelCameraKeyframe3D]? = nil) { self.position=position; self.target=target; self.up=up; self.verticalFieldOfViewDegrees=verticalFieldOfViewDegrees; self.near=near; self.far=far;self.keyframes=keyframes }
    private enum CodingKeys: String, CodingKey { case position,target,up,verticalFieldOfViewDegrees,near,far,keyframes }
    public init(from decoder: Decoder) throws {
        try ModelStoryDecoding3D.keys(decoder,required:["position","target","up","verticalFieldOfViewDegrees","near","far"],optional:["keyframes"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        position=try c.decode(ModelVector3.self,forKey:.position);target=try c.decode(ModelVector3.self,forKey:.target);up=try c.decode(ModelVector3.self,forKey:.up)
        verticalFieldOfViewDegrees=try c.decode(Double.self,forKey:.verticalFieldOfViewDegrees);near=try c.decode(Double.self,forKey:.near);far=try c.decode(Double.self,forKey:.far)
        if c.contains(.keyframes) { keyframes=try c.decode([ModelCameraKeyframe3D].self,forKey:.keyframes) }
    }
    fileprivate func pose(_ key: ModelCameraKeyframe3D) -> Self {
        .init(position:key.position,target:key.target,up:up,verticalFieldOfViewDegrees:key.verticalFieldOfViewDegrees,near:near,far:far)
    }
    fileprivate func validatePose() throws {
        let dx=target.x-position.x,dy=target.y-position.y,dz=target.z-position.z
        let length=dx*dx+dy*dy+dz*dz,upLength=up.x*up.x+up.y*up.y+up.z*up.z
        let cross=(dy*up.z-dz*up.y)*(dy*up.z-dz*up.y)+(dz*up.x-dx*up.z)*(dz*up.x-dx*up.z)+(dx*up.y-dy*up.x)*(dx*up.y-dy*up.x)
        guard position.bounded,target.bounded,up.bounded,length>0.00000001,abs(upLength-1)<=0.000001,cross/length>0.00000001,
              verticalFieldOfViewDegrees.isFinite,(1...175).contains(verticalFieldOfViewDegrees),near.isFinite,far.isFinite,near>=0.0001,far>near,far<=1_000_000 else { throw VideoError.invalid("三维相机视向、上方向、透视或裁切范围无效") }
    }
    fileprivate func validate(durationFrames: Int) throws {
        try validatePose()
        guard let keys=keyframes else { return }
        guard !keys.isEmpty else { throw VideoError.invalid("镜头关键帧须非空；静态镜头请省略keyframes") }
        var previous = -1
        for key in keys {
            guard key.frame>previous,key.frame<durationFrames else { throw VideoError.invalid("镜头关键帧须按有效源帧严格递增") }
            try pose(key).validatePose();previous=key.frame
        }
        // Valid endpoints alone do not rule out crossing through the target or
        // a view parallel to up. Both squared tests are quadratics; check their
        // exact minima over each continuous segment, without sampling a few
        // convenient frames or requiring a particular camera direction.
        func delta(_ a:ModelVector3,_ b:ModelVector3)->ModelVector3 { .init(x:b.x-a.x,y:b.y-a.y,z:b.z-a.z) }
        func dot(_ a:ModelVector3,_ b:ModelVector3)->Double { a.x*b.x+a.y*b.y+a.z*b.z }
        func cross(_ a:ModelVector3,_ b:ModelVector3)->ModelVector3 { .init(x:a.y*b.z-a.z*b.y,y:a.z*b.x-a.x*b.z,z:a.x*b.y-a.y*b.x) }
        for (left,right) in zip(keys,keys.dropFirst()) {
            let a=delta(left.position,left.target),b=delta(right.position,right.target),change=delta(a,b)
            let c=cross(a,up),dc=cross(change,up),epsilon=0.00000001
            func positiveMinimum(_ quadratic:Double,_ linear:Double,_ evaluate:(Double)->Double)->Bool {
                var points=[0.0,1.0]
                if quadratic>0 { let point = -linear/(2*quadratic);if point>0 && point<1 { points.append(point) } }
                return points.allSatisfy { let value=evaluate($0);return value.isFinite && value>0 }
            }
            let distanceSafe=positiveMinimum(dot(change,change),2*dot(a,change)) { t in
                let d=ModelVector3.mix(a,b,t);return dot(d,d)-epsilon
            }
            let upSafe=positiveMinimum(dot(dc,dc)-epsilon*dot(change,change),2*(dot(c,dc)-epsilon*dot(a,change))) { t in
                let d=ModelVector3.mix(a,b,t),v=cross(d,up);return dot(v,v)-epsilon*dot(d,d)
            }
            guard distanceSafe,upSafe else { throw VideoError.invalid("镜头插值内段的视向不能消失或与上方向平行") }
        }
    }
}
/// Validated immutable source-frame sampler. It has no wall-clock state and
/// shares the existing vector interpolation with original model transforms.
public struct ModelCameraTimeline3D: Sendable {
    private let camera: ModelCamera3D
    private let durationFrames: Int
    public init(camera: ModelCamera3D, durationFrames: Int) throws {
        guard (1...54000).contains(durationFrames) else { throw VideoError.invalid("镜头采样须使用有效场景源帧区间") }
        try camera.validate(durationFrames:durationFrames);self.camera=camera;self.durationFrames=durationFrames
    }
    public func value(at sourceFrame: Int) throws -> ModelCamera3D {
        guard (0..<durationFrames).contains(sourceFrame) else { throw VideoError.invalid("镜头采样帧不在当前场景源帧区间") }
        guard let keys=camera.keyframes,let first=keys.first else { return camera }
        if sourceFrame<=first.frame { return camera.pose(first) }
        var low=0,high=keys.count
        while low<high { let middle=low+(high-low)/2;if keys[middle].frame<sourceFrame {low=middle+1}else{high=middle} }
        guard low<keys.count else { return camera.pose(keys[keys.count-1]) }
        let a=keys[low-1],b=keys[low],t=Double(sourceFrame-a.frame)/Double(b.frame-a.frame)
        return .init(position:.mix(a.position,b.position,t),target:.mix(a.target,b.target,t),up:camera.up,
                     verticalFieldOfViewDegrees:a.verticalFieldOfViewDegrees+(b.verticalFieldOfViewDegrees-a.verticalFieldOfViewDegrees)*t,
                     near:camera.near,far:camera.far)
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
        try camera.validate(durationFrames:durationFrames)
        var bindings: [String:ModelAssetReference]=[:],variantFrames=0,variantNodes=0
        for instance in instances {
            guard PluginProtocolRules.text(instance.id,maximum:160),PluginProtocolRules.text(instance.name,maximum:160) else { throw VideoError.invalid("三维实例须有明确标识和名称") }
            try instance.transform.validate();try instance.resource.validate(assets:assets)
            if let groups=instance.nodeVariants {
                guard (1...32).contains(groups.count),Set(groups.map(\.id)).count==groups.count else {throw VideoError.invalid("三维节点互斥组须有1至32个不重复的明确组标识")}
                var selectedNodes=Set<String>()
                let sourceNodes=Set(instance.resource.inspection.nodeIDs)
                for group in groups {
                    guard PluginProtocolRules.text(group.id,maximum:160),group.id==group.id.trimmingCharacters(in:.whitespacesAndNewlines),
                          (2...128).contains(group.nodeIDs.count),Set(group.nodeIDs).count==group.nodeIDs.count,
                          group.nodeIDs.contains(group.defaultNodeID),group.nodeIDs.allSatisfy({PluginProtocolRules.text($0,maximum:160) && $0==$0.trimmingCharacters(in:.whitespacesAndNewlines) && sourceNodes.contains($0) && selectedNodes.insert($0).inserted}) else {throw VideoError.invalid("互斥组须明确引用2至128个实际原DAE节点ID，默认项属于本组，且各组不得重复占用节点")}
                    variantNodes+=group.nodeIDs.count
                    if let frames=group.keyframes {
                        guard (1...4096).contains(frames.count) else {throw VideoError.invalid("节点切换关键帧须有界且非空，静态组请省略keyframes")}
                        var previous=0
                        for key in frames {
                            guard key.frame>previous,key.frame<durationFrames,group.nodeIDs.contains(key.nodeID) else {throw VideoError.invalid("节点切换须按有效源帧严格递增并选择本组实际节点；0帧由默认项定义")}
                            previous=key.frame
                        }
                        variantFrames+=frames.count
                        guard variantFrames<=65536 else {throw VideoError.invalid("三维节点切换关键帧超过总上限")}
                    }
                }
            }
            if let ids=instance.materialInterpretation?.opaqueDiffuseMaterialIDs {
                let sourceIDs=Set(instance.resource.inspection.materials.map(\.id))
                guard (1...128).contains(ids.count),Set(ids).count==ids.count,
                      ids.allSatisfy({PluginProtocolRules.text($0,maximum:160) && $0 == $0.trimmingCharacters(in:.whitespacesAndNewlines) && sourceIDs.contains($0)}) else { throw VideoError.invalid("不透明漫反射须明确指定1至128个不重复的原DAE材质标识") }
            }
            if let ids=instance.materialInterpretation?.alphaCutoutMaterialIDs {
                let sourceIDs=Set(instance.resource.inspection.materials.map(\.id))
                guard (1...128).contains(ids.count),Set(ids).count==ids.count,
                      ids.allSatisfy({PluginProtocolRules.text($0,maximum:160) && $0 == $0.trimmingCharacters(in:.whitespacesAndNewlines) && sourceIDs.contains($0)}) else { throw VideoError.invalid("透明裁切须明确指定1至128个不重复的原DAE材质标识") }
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
        guard variantNodes<=8192 else {throw VideoError.invalid("三维互斥节点总数超过8192")}
        var targets=Set<String>(), jointTargets=Set<String>(), totalFrames=variantFrames+(camera.keyframes?.count ?? 0)
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
/// Host and game11 extend the instance record; game9/game10 records stay exact.
public enum ModelNodeVariantSchema {
    public static let records:[String:String] = [
        "ModelNodeVariantKeyframe":"frame:i nodeID:s",
        "ModelNodeVariantGroup":"id:s nodeIDs:[s] defaultNodeID:s keyframes?:[ModelNodeVariantKeyframe]",
        "ModelInstance3D":"id:s name:s resource:ModelDAEResource transform:ModelTransform3D locked:b materialInterpretation?:ModelMaterialInterpretation nodeVariants?:[ModelNodeVariantGroup]"
    ]
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
/// Host/game12 only. Keep game9/10/11 material records byte-for-byte unchanged.
public enum ModelAlphaCutoutSchema {
    public static let records:[String:String] = [
        "ModelMaterialInterpretation":"vertexColors:ModelVertexColorUsage normalEncoding:ModelNormalTextureEncoding opaqueDiffuseMaterialIDs?:[s] alphaCutoutMaterialIDs?:[s]"
    ]
}
/// Additive Host/game13 camera motion. Game9–12 camera records stay exact.
public enum ModelCameraMotionSchema {
    public static let records:[String:String] = [
        "ModelCameraKeyframe3D":"frame:i position:ModelVector3 target:ModelVector3 verticalFieldOfViewDegrees:n",
        "ModelCamera3D":"position:ModelVector3 target:ModelVector3 up:ModelVector3 verticalFieldOfViewDegrees:n near:n far:n keyframes?:[ModelCameraKeyframe3D]"
    ]
}
