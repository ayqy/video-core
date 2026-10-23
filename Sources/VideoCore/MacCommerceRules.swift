import Foundation

public enum MacCommerceProduct:String,CaseIterable,Codable,Sendable {
    case editor="com.ayqy.video.mac.editor"
    case game="com.ayqy.video.mac.game"
    case cartoon="com.ayqy.video.mac.cartoon"
    public var moduleID:String?{switch self{case .editor:return nil;case .game:return "video.game";case .cartoon:return "video.cartoon"}}
}

/// Metadata checks are separate from cryptographic verification. Only the StoreKit adapter can grant an entitlement.
public struct MacTransactionMetadata:Sendable {
    public var productID:String
    public var bundleID:String
    public var productType:String
    public var purchaseDate:Date
    public var expiresAt:Date?
    public var revokedAt:Date?
    public var upgraded:Bool
    public init(productID:String,bundleID:String,productType:String,purchaseDate:Date,expiresAt:Date?=nil,revokedAt:Date?=nil,upgraded:Bool=false){
        self.productID=productID;self.bundleID=bundleID;self.productType=productType;self.purchaseDate=purchaseDate;self.expiresAt=expiresAt;self.revokedAt=revokedAt;self.upgraded=upgraded
    }
}
public enum MacCommerceRules {
    public static let bundleID="com.ayqy.video.mac"
    public static let productIDs=Set(MacCommerceProduct.allCases.map(\.rawValue))
    public static func recognizes(_ metadata:MacTransactionMetadata,runningBundleID:String?)->Bool{
        runningBundleID==bundleID && metadata.bundleID==bundleID && productIDs.contains(metadata.productID)
    }
    public static func current(_ metadata:MacTransactionMetadata,runningBundleID:String?,now:Date=Date())->Bool{
        guard recognizes(metadata,runningBundleID:runningBundleID),metadata.purchaseDate<=now.addingTimeInterval(60),
              metadata.revokedAt==nil,!metadata.upgraded,metadata.expiresAt==nil || metadata.expiresAt!>now else{return false}
        if metadata.productID==MacCommerceProduct.editor.rawValue{return metadata.productType=="nonConsumable"}
        return metadata.productType=="nonConsumable" || metadata.productType=="autoRenewable"
    }
    /// Called once at the Mac transaction boundary, covering new projects and
    /// every current-version change from planners, candidates, batches or inspectors.
    public static func authorizeProjectChanges(before:[Project],after:[Project],assets:[Asset],entitledProductIDs:Set<String>,checking:Bool)throws{
        for project in after {
            guard !project.revisions.isEmpty else{throw VideoError.invalid("工程没有可核对版本")}
            if let old=before.first(where:{$0.id==project.id}),!old.revisions.isEmpty,
               old.revisions.count==project.revisions.count,old.current.id==project.current.id,
               try old.current.contentDigest()==project.current.contentDigest(){continue}
            try authorizeEditor(entitledProductIDs:entitledProductIDs,checking:checking,project:project,assets:assets)
        }
    }
    public static func authorizeEditor(entitledProductIDs:Set<String>,checking:Bool,project:Project,assets:[Asset])throws{
        guard (!checking && entitledProductIDs.contains(MacCommerceProduct.editor.rawValue)) || EditorPracticeRules.allows(project:project,assets:assets) else{
            throw VideoError.permission("Mac人工编辑器须有当前已核验的独立商店权益；免费CLI、原素材、历史导出和备份恢复保持可用，内置离线练习可体验")
        }
    }
}
