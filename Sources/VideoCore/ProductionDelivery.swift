import Foundation

/// Production instructions, rights and intended delivery. No quote, income, sales or settlement fields.
public struct ProductionBrief: Codable, Equatable, Sendable {
    public var objective: String
    public var intendedUse: String
    public var modifications: String
    public var aiDisclosure: String
    public var commercialDisclosure: String
    public var restrictions: String
    public var evidenceIDs: [String]
    public var permittedUntil: Date?
    public var approvalRequired: Bool
    public init(objective: String = "", intendedUse: String = "", modifications: String = "", aiDisclosure: String = "AI辅助制作", commercialDisclosure: String = "非商业用途", restrictions: String = "", evidenceIDs: [String] = [], permittedUntil: Date? = nil, approvalRequired: Bool = false) {
        self.objective=objective; self.intendedUse=intendedUse; self.modifications=modifications; self.aiDisclosure=aiDisclosure
        self.commercialDisclosure=commercialDisclosure; self.restrictions=restrictions; self.evidenceIDs=evidenceIDs
        self.permittedUntil=permittedUntil; self.approvalRequired=approvalRequired
    }
    public func validate() throws {
        let required=[objective,intendedUse,aiDisclosure,commercialDisclosure]
        guard required.allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}),
              (required + [modifications,restrictions]).allSatisfy({$0.utf16.count<=8000}),
              Set(evidenceIDs).count==evidenceIDs.count, evidenceIDs.count<=500,
              evidenceIDs.allSatisfy({!$0.isEmpty}) else {throw VideoError.invalid("制作Brief须有目标、用途、AI及商业标识声明，证据不可重复或过长")}
    }
}
public struct ProductionApproval: Codable, Identifiable, Sendable {
    public var id=Codec.id()
    public var revisionID:String
    public var contentDigest:String
    public var briefDigest:String
    public var reviewer:String
    public var note:String
    public var at:Date
    /// A local statement records who was entered; it does not authenticate a remote reviewer.
    public var method:String = "local_explicit_review"
}
public struct ProductionDeliveryRecord: Codable, Identifiable, Sendable {
    public var id=Codec.id()
    public var revisionID:String
    public var contentDigest:String
    public var briefDigest:String?
    public var jobID:String
    public var artifactHashes:[String:String]
    public var destinationName:String
    public var at:Date
    public var state:String = "files_exported"
}
public enum ProductionDeliveryRules {
    private struct Terms: Encodable {var brief:ProductionBrief;var evidence:[Evidence];var assets:[Asset];var sourceDigests:[String:String]}
    public static func briefDigest(revision:Revision,database:Database)throws->String {
        guard let brief=revision.productionBrief else{throw VideoError.review("当前版本尚无制作Brief")}
        try brief.validate()
        let graph=try DependencyRules.freeze(revision:revision,assets:database.assets,evidence:database.evidence)
        let ids=Set(brief.evidenceIDs + graph.records.compactMap{$0.evidence?.id})
        let evidence=database.evidence.filter{ids.contains($0.id) && $0.workspaceID==revision.workspaceID}.sorted{$0.id<$1.id}.map{e -> Evidence in var x=e;x.tags=nil;return x}
        guard evidence.count==ids.count else{throw VideoError.review("制作Brief关联证据缺失或越出工作区")}
        let assetIDs=Set(evidence.compactMap(\.assetID))
        let assets=database.assets.filter{assetIDs.contains($0.id) && $0.workspaceID==revision.workspaceID}.sorted{$0.id<$1.id}.map{a -> Asset in var x=a;x.tags=[];x.importedAt=nil;return x}
        guard assets.count==assetIDs.count else{throw VideoError.review("制作Brief的授权或事实原件缺失")}
        return try Codec.digest(Terms(brief:brief,evidence:evidence,assets:assets,sourceDigests:Dictionary(uniqueKeysWithValues:graph.records.map{($0.id,$0.digest)})))
    }
    /// Shape validation permits historical/expired records to remain readable; current delivery rechecks dates and rights.
    public static func validate(project:Project,assets:[Asset],evidence:[Evidence])throws {
        for revision in project.revisions {
            if let brief=revision.productionBrief {
                try brief.validate()
                guard brief.evidenceIDs.allSatisfy({id in evidence.contains{$0.id==id && $0.workspaceID==project.workspaceID}}) else{throw VideoError.permission("制作Brief的证据不属于此工作区")}
            }
        }
        let approvals=project.productionApprovals ?? [],deliveries=project.deliveryRecords ?? []
        guard Set(approvals.map(\.id)).count==approvals.count,Set(deliveries.map(\.id)).count==deliveries.count else{throw VideoError.invalid("审稿或交付记录ID重复")}
        for approval in approvals {
            guard let revision=project.revisions.first(where:{$0.id==approval.revisionID}),revision.productionBrief != nil,
                  approval.contentDigest == (try revision.contentDigest()),!approval.briefDigest.isEmpty,
                  !approval.reviewer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,approval.method=="local_explicit_review" else{throw VideoError.invalid("审稿记录未绑定实际版本和明确审稿人")}
        }
        for record in deliveries {
            guard let revision=project.revisions.first(where:{$0.id==record.revisionID}),
                  record.contentDigest == (try revision.contentDigest()),!record.jobID.isEmpty,!record.destinationName.isEmpty,
                  record.state=="files_exported",Set(record.artifactHashes.keys)==Set(["video/mp4","image/png","application/x-subrip","text/plain"]),
                  record.artifactHashes.values.allSatisfy({$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}) else{throw VideoError.invalid("交付记录须绑定实际版本、四项文件与真实摘要")}
        }
    }
    public static func inspect(revision:Revision,database:Database,requireApproval:Bool=true,now:Date=Date())->[QualityIssue] {
        guard revision.contentContext != nil || revision.productionBrief != nil else{return []}
        let commercial=revision.purpose != .education
        guard let brief=revision.productionBrief else{return commercial ? [QualityIssue("production_brief","商业用途交付须明确制作目标、用途与AI/商业标识；不需要营收、平台挂载或经营账号")]:[]}
        do {
            try brief.validate()
            guard brief.permittedUntil == nil || brief.permittedUntil!>now else{throw VideoError.review("制作Brief的允许用途期限已到期，请核权后创建新版本")}
            let graph=try DependencyRules.freeze(revision:revision,assets:database.assets,evidence:database.evidence)
            for id in Set(brief.evidenceIDs + graph.records.compactMap{$0.evidence?.id}) {
                guard let e=database.evidence.first(where:{$0.id==id && $0.workspaceID==revision.workspaceID}),e.usable(commercial:commercial,now:now) else{throw VideoError.review("Brief引用的事实或权利证据未核实、已到期或不允许此用途")}
                if let until=brief.permittedUntil,let expiry=e.expiresAt,expiry<until {throw VideoError.review("Brief约定用途期限超过素材或声音授权期限，请缩短用途期限或补齐授权")}
            }
            let terms=try briefDigest(revision:revision,database:database)
            if requireApproval && (brief.approvalRequired || revision.purpose == .brand) {
                guard let project=database.projects.first(where:{$0.workspaceID==revision.workspaceID && $0.revisions.contains{$0.id==revision.id}}),
                      let approval=(project.productionApprovals ?? []).last(where:{$0.revisionID==revision.id && $0.contentDigest==(try? revision.contentDigest()) && $0.briefDigest==terms && $0.at<=now}),
                      !approval.reviewer.isEmpty else{throw VideoError.review("当前版本、Brief、修改要求或授权已变化，请取得此指定版本的明确审稿记录；历史审批不覆盖新版本")}
            }
            return []
        } catch{return [QualityIssue("production_delivery",(error as? VideoError)?.localizedDescription ?? "制作交付核对未通过")]}
    }
}
extension Database {
    public mutating func approveProduction(projectID:String,revisionID:String,reviewer:String,note:String,now:Date=Date())throws {
        guard let i=projects.firstIndex(where:{$0.id==projectID}),projects[i].current.id==revisionID else{throw VideoError.conflict("审稿目标版本已变化")}
        let revision=projects[i].current
        guard !reviewer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw VideoError.invalid("请填写实际审稿人")}
        let issues=try Quality.inspect(revision,database:self,requireReview:true,now:now,enforceBrandDelivery:false)+ProductionDeliveryRules.inspect(revision:revision,database:self,requireApproval:false,now:now)
        guard issues.isEmpty,revision.productionBrief != nil else{throw VideoError.review(issues.map(\.message).joined(separator:"；"))}
        guard !projects[i].comments.contains(where:{$0.revisionID==revisionID && !$0.resolved}) else{throw VideoError.review("此版本还有未处理批注，请逐项处理后再记录审稿")}
        let digest=try revision.contentDigest(),terms=try ProductionDeliveryRules.briefDigest(revision:revision,database:self)
        let approval=ProductionApproval(revisionID:revisionID,contentDigest:digest,briefDigest:terms,reviewer:reviewer.trimmingCharacters(in:.whitespacesAndNewlines),note:note,at:now)
        projects[i].productionApprovals=(projects[i].productionApprovals ?? [])+[approval]
    }
    /// Call only after the normal export writer has re-read all four destination files.
    public mutating func recordProductionDelivery(projectID:String,jobID:String,destinationName:String,artifactHashes:[String:String],now:Date=Date())throws {
        guard let i=projects.firstIndex(where:{$0.id==projectID}),let job=jobs.first(where:{$0.id==jobID && $0.projectID==projectID && $0.workspaceID==projects[i].workspaceID && $0.state == .succeeded && $0.revisionID==projects[i].current.id}) else{throw VideoError.conflict("交付任务不属于当前已审版本")}
        let revision=projects[i].current
        let issues=try Quality.inspect(revision,database:self,requireReview:true,now:now)
        guard issues.isEmpty else{throw VideoError.review(issues.map(\.message).joined(separator:"；"))}
        let mimes=Set(["video/mp4","image/png","application/x-subrip","text/plain"])
        guard Set(artifactHashes.keys)==mimes,job.artifacts.count==4,Set(job.artifacts.map(\.mime))==mimes,
              job.artifacts.allSatisfy({$0.revision==revision.id && artifactHashes[$0.mime]==$0.sha256}),!destinationName.isEmpty else{throw VideoError.review("实际导出四件文件与已审产物不一致，未记录成功")}
        let digest=try revision.contentDigest()
        guard job.digest==digest else{throw VideoError.conflict("交付任务摘要已失效")}
        let terms=revision.productionBrief == nil ? nil:try ProductionDeliveryRules.briefDigest(revision:revision,database:self)
        projects[i].deliveryRecords=(projects[i].deliveryRecords ?? [])+[ProductionDeliveryRecord(revisionID:revision.id,contentDigest:digest,briefDigest:terms,jobID:jobID,artifactHashes:artifactHashes,destinationName:destinationName,at:now)]
    }
}
