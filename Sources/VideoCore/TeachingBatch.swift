import Foundation

public struct TeachingVariant:Codable,Sendable,Identifiable {
    public var id=Codec.id()
    public var name:String
    public var hook:String
    public var aspect:Aspect
    public var budget:Money
    public init(name:String,hook:String,aspect:Aspect,budget:Money){self.name=name;self.hook=hook;self.aspect=aspect;self.budget=budget}
}
public struct TeachingBatchItem:Codable,Sendable,Identifiable {
    public var id:String {variant.id}
    public var variant:TeachingVariant
    public var projectID:String?
    public var frozen:Revision?
    public var state:TopicBatchState
    public var error:String?
    public var history:[Revision]
}
public struct TeachingBatch:Codable,Sendable,Identifiable {
    public var tags:[String]?
    public var id=Codec.id()
    public var workspaceID:String
    public var title:String
    public var sourceProjectID:String
    public var sourceRevision:Revision
    public var items:[TeachingBatchItem]
    public var createdAt:Date
    public var maximumByCurrency:[String:Decimal]{items.filter{!$0.variant.budget.amount.isNaN && $0.variant.budget.amount>=0}.reduce(into:[:]){$0[$1.variant.budget.currency,default:0]+=$1.variant.budget.amount}}
}
public enum TeachingBatchRules {
    /// All variants retain exact source/rights references; only the explicit hook
    /// and format change. A malformed sibling becomes a failed item by itself.
    public static func create(database:inout Database,workspaceID:String,title:String,sourceProjectID:String,variants:[TeachingVariant],now:Date=Date())throws->TeachingBatch {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,(1...25).contains(variants.count),Set(variants.map(\.id)).count==variants.count else{throw VideoError.invalid("对照批次须有标题及1至25个不同条目")}
        let source=try database.project(sourceProjectID)
        guard source.workspaceID==workspaceID,!source.current.scenes.isEmpty else{throw VideoError.permission("请选择当前工作区已有真实镜头的工程")}
        try source.current.validateContext()
        var batch=TeachingBatch(workspaceID:workspaceID,title:title,sourceProjectID:source.id,sourceRevision:source.current,items:[],createdAt:now)
        for variant in variants {
            var item=TeachingBatchItem(variant:variant,state:.planned,history:[])
            do{let project=try makeProject(variant:variant,source:source.current,database:database,now:now);database.projects.append(project);item.projectID=project.id;item.frozen=project.current;item.state = .ready}
            catch{item.state = .failed;item.error=(error as? VideoError)?.localizedDescription ?? "此条目未准备成功；其他条目保留"}
            batch.items.append(item)
        }
        database.teachingBatches=(database.teachingBatches ?? [])+[batch]
        return batch
    }
    private static func makeProject(variant:TeachingVariant,source:Revision,database:Database,now:Date)throws->Project {
        guard !variant.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!variant.hook.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,variant.name.count<=120,variant.hook.count<=2000,!variant.budget.amount.isNaN,variant.budget.amount>=0,variant.budget.currency.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil else{throw VideoError.invalid("条目须有名称、实际开场文字及有效原币预算")}
        let changes=DependencyRules.diff(revision:source,assets:database.assets,evidence:database.evidence,currentProduct:source.product.flatMap{p in database.products.first{$0.id==p.id && $0.workspaceID==source.workspaceID}},now:now)
        guard changes.isEmpty else{throw VideoError.review(changes.map(\.summary).joined(separator:"；"))}
        var revision=source
        revision.id=Codec.id();revision.parentID=nil;revision.number=1;revision.createdAt=now;revision.aspect=variant.aspect
        revision.review=Review();revision.change="从冻结材料建立独立对照："+variant.name
        revision.invalidated=["新开场和画幅需重新制作、校对与完整看听"]
        revision.scenes.insert(Scene(title:"开场 · "+variant.name,body:variant.hook),at:0)
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:database.assets,evidence:database.evidence)
        return Project(workspaceID:source.workspaceID,name:variant.name,revision:revision)
    }
    public static func refreshed(_ batch:TeachingBatch,database:Database,now:Date=Date())->TeachingBatch {
        var result=batch
        for i in result.items.indices {
            guard let projectID=result.items[i].projectID,let frozen=result.items[i].frozen else{continue}
            guard let project=database.projects.first(where:{$0.id==projectID && $0.workspaceID==batch.workspaceID}),project.current.id==frozen.id,(try? project.current.contentDigest())==(try? frozen.contentDigest()) else{result.items[i].state = .invalidated;result.items[i].error="本项版本已变化，请明确接收新版本；其他条目不变";continue}
            let changes=DependencyRules.diff(revision:frozen,assets:database.assets,evidence:database.evidence,currentProduct:frozen.product.flatMap{p in database.products.first{$0.id==p.id && $0.workspaceID==batch.workspaceID}},now:now)
            if !changes.isEmpty{result.items[i].state = .invalidated;result.items[i].error=changes.map(\.summary).joined(separator:"；");continue}
            guard let job=database.jobs.last(where:{$0.workspaceID==batch.workspaceID && $0.projectID==projectID && $0.revisionID==frozen.id}) else{result.items[i].state = .ready;result.items[i].error=nil;continue}
            switch job.state {
            case .queued,.running:result.items[i].state = .running
            case .failed,.interrupted:result.items[i].state = .failed
            case .cancelled:result.items[i].state = .cancelled
            case .unknownRemote,.cancelRequested,.billingPending:result.items[i].state = .waiting
            case .needsReview:result.items[i].state = .needsReview
            case .succeeded:result.items[i].state = project.current.review.complete && project.current.review.digest==(try? project.current.contentDigest()) ? .approved:.needsReview
            }
            result.items[i].error=job.message.isEmpty ? nil:job.message
        }
        return result
    }
    public static func acceptRevision(database:inout Database,batchID:String,itemID:String,now:Date=Date())throws {
        guard var batches=database.teachingBatches,let b=batches.firstIndex(where:{$0.id==batchID}),let i=batches[b].items.firstIndex(where:{$0.id==itemID}),let projectID=batches[b].items[i].projectID else{throw VideoError.notFound("原批次或条目不存在")}
        let project=try database.project(projectID)
        guard project.workspaceID==batches[b].workspaceID else{throw VideoError.permission("条目不属于此工作区")}
        let changes=DependencyRules.diff(revision:project.current,assets:database.assets,evidence:database.evidence,currentProduct:project.current.product.flatMap{p in database.products.first{$0.id==p.id && $0.workspaceID==project.workspaceID}},now:now)
        guard changes.isEmpty else{throw VideoError.review(changes.map(\.summary).joined(separator:"；"))}
        if let old=batches[b].items[i].frozen{batches[b].items[i].history.append(old)}
        batches[b].items[i].frozen=project.current;batches[b].items[i].state = .ready
        batches[b].items[i].error="已接收新版本；原预算保持，须重新报价和看听"
        database.teachingBatches=batches
    }
    public static func retryPreparation(database:inout Database,batchID:String,itemID:String,variant:TeachingVariant,now:Date=Date())throws {
        guard var batches=database.teachingBatches,let b=batches.firstIndex(where:{$0.id==batchID}),let i=batches[b].items.firstIndex(where:{$0.id==itemID}),batches[b].items[i].projectID==nil else{throw VideoError.conflict("仅未创建工程的失败条目可修正重试；已有工程沿原任务恢复")}
        guard variant.id==itemID else{throw VideoError.conflict("重试须保留原条目ID")}
        let project=try makeProject(variant:variant,source:batches[b].sourceRevision,database:database,now:now)
        database.projects.append(project);batches[b].items[i].variant=variant;batches[b].items[i].projectID=project.id;batches[b].items[i].frozen=project.current;batches[b].items[i].state = .ready;batches[b].items[i].error=nil
        database.teachingBatches=batches
    }
    public static func validateSubmission(project:Project,quote:Quote,batches:[TeachingBatch],existingJobs:[Job]=[],requestKey:String?=nil)throws {
        let matches=batches.filter{$0.workspaceID==project.workspaceID}.flatMap(\.items).filter{$0.projectID==project.id}
        guard let item=matches.first else{return}
        guard matches.count==1,let frozen=item.frozen,frozen.id==project.current.id,try frozen.contentDigest()==project.current.contentDigest(),quote.projectID==project.id,quote.revisionID==frozen.id,quote.digest == (try frozen.contentDigest()) else{throw VideoError.review("本项冻结版本或币种已变化，请接收新版本并重新核对费用")}
        if quote.provider=="native" && quote.upper.amount==0{return}
        guard quote.upper.currency==item.variant.budget.currency else{throw VideoError.review("付费报价与本项冻结预算币种不一致；不自动换汇")}
        if let key=requestKey,existingJobs.contains(where:{$0.projectID==project.id && $0.requestKey==key && $0.quote.id==quote.id && $0.digest==quote.digest}){return}
        let prior=existingJobs.filter{$0.projectID==project.id && $0.quote.upper.currency==item.variant.budget.currency}.reduce(Decimal(0)){$0+$1.exposure.amount}
        guard !quote.upper.amount.isNaN,quote.upper.amount>=0,prior+quote.upper.amount<=item.variant.budget.amount else{throw VideoError.budget("本项历史消耗/未知占用加本次上界超出冻结预算；失败或取消不抹账")}
    }
    public static func validateDatabase(_ db:Database)throws {
        let batches=db.teachingBatches ?? []
        guard Set(batches.map(\.id)).count==batches.count else{throw VideoError.invalid("对照批次ID重复")}
        for batch in batches {
            _=try db.workspace(batch.workspaceID)
            guard batch.sourceRevision.workspaceID==batch.workspaceID,(1...25).contains(batch.items.count),Set(batch.items.map(\.id)).count==batch.items.count else{throw VideoError.permission("对照批次来源或条目归属无效")}
            for item in batch.items {
                if let id=item.projectID {guard let frozen=item.frozen,frozen.workspaceID==batch.workspaceID,let project=db.projects.first(where:{$0.id==id && $0.workspaceID==batch.workspaceID}),project.revisions.contains(where:{$0.id==frozen.id && (try? $0.contentDigest())==(try? frozen.contentDigest())}) else{throw VideoError.permission("对照条目的工程、冻结版本或摘要缺失")}}
                else{guard item.frozen==nil,item.state == .failed else{throw VideoError.invalid("未准备成功的条目不能标为可制作")}}
            }
        }
    }
}
