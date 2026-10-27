import Foundation

/// Rates retain their original billing unit. Quantities are already upper bounds;
/// no conversion between credits, tokens, seconds or currency is implicit.
public struct RateLine: Codable, Sendable, Equatable, Identifiable {
    public var id = Codec.id()
    public var label: String; public var quantity: Decimal; public var quantityUnit: String
    public var price: Money; public var per: Decimal; public var count: Int; public var attempts: Int
    public init(label: String, quantity: Decimal, unit: String, price: Money, per: Decimal = 1, count: Int = 1, attempts: Int = 1) {
        self.label=label; self.quantity=quantity; self.quantityUnit=unit; self.price=price; self.per=per; self.count=count; self.attempts=attempts
    }
    public func total() throws -> Money {
        guard !label.isEmpty, !quantityUnit.isEmpty, !quantity.isNaN, quantity >= 0, !price.amount.isNaN, price.amount >= 0, !per.isNaN, per > 0, (1...10000).contains(count), (1...100).contains(attempts), price.currency.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil else { throw VideoError.invalid("计费数量、原单位、单价或尝试数不合法") }
        let amount = quantity / per * price.amount * Decimal(count) * Decimal(attempts)
        guard !amount.isNaN else { throw VideoError.invalid("费用计算超出十进制范围") }
        return Money(amount,price.currency)
    }
}
public struct EstimateBreakdown: Codable, Sendable {
    public var version: String; public var specification: String; public var source: String
    public var validFrom: Date; public var expiresAt: Date; public var lines: [RateLine]; public var excluded: [String]
    public init(version: String, specification: String, source: String, validFrom: Date, expiresAt: Date, lines: [RateLine], excluded: [String]) { self.version=version; self.specification=specification; self.source=source; self.validFrom=validFrom; self.expiresAt=expiresAt; self.lines=lines; self.excluded=excluded }
    public var maximumAttempts: Int { lines.map(\.attempts).max() ?? 0 }
    public func total() throws -> Money { guard let first=lines.first else { throw VideoError.invalid("报价明细为空") }; return try lines.reduce(Money(0,first.price.currency)) { try $0.adding($1.total()) } }
    public func validate(now: Date = Date()) throws { guard !version.isEmpty, !specification.isEmpty, !source.isEmpty, validFrom <= now, expiresAt > now, !lines.isEmpty, !excluded.contains(where:{$0.isEmpty}) else { throw VideoError.review("报价来源、规格或有效期不完整/已失效") }; _ = try total() }
    public func quote(project: Project, provider: String, confirmed: Bool, now: Date = Date()) throws -> Quote {
        try validate(now:now)
        var q=Quote(projectID:project.id,revisionID:project.current.id,digest:try project.current.contentDigest(),upper:try total(),unit:try total().currency,provider:provider,expiresAt:expiresAt,attempts:maximumAttempts,confirmed:confirmed)
        q.breakdown=self; return q
    }
}
public struct WorkerLease: Codable, Sendable {
    public var owner: String; public var token: String; public var heartbeat: Date; public var expiresAt: Date
}
public struct BillingRecord: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case charge, refundRequested, refundReceived }
    public var id: String; public var kind: Kind; public var money: Money; public var source: String; public var at: Date
    public init(id: String, kind: Kind, money: Money, source: String, at: Date = Date()) { self.id=id; self.kind=kind; self.money=money; self.source=source; self.at=at }
}
public struct RemoteSnapshot: Codable, Sendable {
    public enum State: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled, unknown }
    public var remoteID: String; public var requestKey: String; public var state: State; public var progress: Double
    public var actual: Money?; public var checkedAt: Date
    public init(remoteID: String, requestKey: String, state: State, progress: Double, actual: Money? = nil, checkedAt: Date = Date()) { self.remoteID=remoteID; self.requestKey=requestKey; self.state=state; self.progress=progress; self.actual=actual; self.checkedAt=checkedAt }
}
public enum JobOperations {
    public static func claim(_ job: Job, owner: String, now: Date = Date(), ttl: TimeInterval = 120) throws -> Job {
        guard job.quote.provider == "native", job.state == .queued, !owner.isEmpty, (10...900).contains(ttl) else { throw VideoError.conflict("只能认领本地排队任务") }
        guard job.lease == nil || job.lease!.expiresAt <= now else { throw VideoError.conflict("任务已被其他执行端认领") }
        var j=job; j.lease=WorkerLease(owner:owner,token:Codec.id(),heartbeat:now,expiresAt:now.addingTimeInterval(ttl)); j.state = .running; j.attempt += 1; j.updatedAt=now; return j
    }
    public static func heartbeat(_ job: Job, token: String, progress: Double, now: Date = Date()) throws -> Job {
        guard var lease=job.lease, lease.token==token, lease.expiresAt > now, job.state == .running else { throw VideoError.conflict("执行权过期或任务已取消，旧执行端不得覆盖结果") }
        guard progress.isFinite,(0...1).contains(progress) else { throw VideoError.invalid("任务进度超出范围") }
        var j=job; lease.heartbeat=now; lease.expiresAt=now.addingTimeInterval(120); j.lease=lease; j.progress=max(j.progress,progress); j.updatedAt=now; return j
    }
    public static func finish(_ job: Job, token: String, artifacts: [Artifact], now: Date = Date()) throws -> Job {
        guard job.state == .running, let lease=job.lease, lease.token==token, lease.expiresAt > now, !artifacts.isEmpty, artifacts.allSatisfy({$0.revision==job.revisionID && ($0.bytes>0 || ($0.bytes==0 && $0.mime=="application/x-subrip")) && $0.sha256.count==64}) else { throw VideoError.conflict("任务执行权或产物版本不符，拒绝把取消/旧任务标成功") }
        var j=job; j.artifacts=artifacts; j.state = .needsReview; j.progress=1; j.actual=Money(0,j.quote.upper.currency); j.billingUnknown=false; j.lease=nil; j.updatedAt=now; return j
    }
    public static func recoverExpired(_ job: Job, now: Date = Date()) -> Job {
        guard job.state == .running, job.lease == nil || job.lease!.expiresAt <= now else { return job }
        var j=job; j.lease=nil; j.state = j.quote.provider == "native" ? .interrupted : .unknownRemote; j.updatedAt=now; j.message=j.quote.provider == "native" ? "执行中断，保留原任务及已校验缓存" : "远端可能已接单，先查原ID/幂等键，禁止重复付费"; return j
    }
    public static func reconcile(_ job: Job, record: BillingRecord) throws -> Job {
        guard !record.id.isEmpty, !record.source.isEmpty, !record.money.amount.isNaN, record.money.amount >= 0, record.money.currency==job.quote.upper.currency else { throw VideoError.invalid("对账需原币种、非负金额与账单凭据") }
        var j=job; var entries=j.billing ?? []
        if let old=entries.first(where:{$0.id==record.id}) { guard try Codec.digest(old)==Codec.digest(record) else { throw VideoError.conflict("相同账单事件ID对应不同金额或内容") }; return job }
        entries.append(record)
        func sum(_ k:BillingRecord.Kind)->Decimal { entries.filter{$0.kind==k}.map{$0.money.amount}.reduce(0,+) }
        let charge=sum(.charge), requested=sum(.refundRequested), refunded=sum(.refundReceived)
        guard refunded<=charge, requested<=charge, refunded<=requested else { throw VideoError.invalid("退款不能超过确认消耗；到账退款须有先前申请记录") }
        j.billing=entries; j.actual=Money(charge-refunded,record.money.currency); j.refundPending=requested>refunded ? Money(requested-refunded,record.money.currency):nil
        // A new receipt is authoritative for the net ledger, but an unrelated
        // event cannot silently resolve a different supplier observation. An
        // exact replay above also preserves that unresolved observation.
        if record.kind == .refundRequested {
            // An application is not money received and cannot settle an
            // outstanding discrepancy, even when it has a new event ID.
            j.billingUnknown=job.billingUnknown || (j.remoteReportedActual.map{$0 != j.actual} ?? false)
        }else if let reported=j.remoteReportedActual {
            let changedNet=job.actual != j.actual
            j.billingUnknown=reported != j.actual || (job.billingUnknown && !changedNet)
        }else {j.billingUnknown=false}
        if j.billingUnknown {
            j.message=(j.remoteReportedActual.map{$0 != j.actual} ?? false)
                ? "已核账单与服务报费不一致；实际及待退款按凭据保留，继续占用预算，请核对原任务差额"
                : "实际及待退款按凭据保留；最终费用仍待核对，继续占用预算"
        }
        else if job.remoteReportedActual != nil {j.message="已按凭据核对实际费用；服务报费与净实际额一致，退款申请与到账仍分开记录"}
        j.updatedAt=record.at; return j
    }
    private static func remoteObservationVersion(_ job:Job,observing original:Job)throws->Int {
        let sequence=job.remoteObservationSequence ?? 0,observed=original.remoteObservationSequence ?? 0
        guard sequence>=0,sequence<Int.max,observed>=0,observed<Int.max else {
            throw VideoError.conflict("原远端观察版本无效或已达上限；未接受回包")
        }
        guard job.id==original.id,job.workspaceID==original.workspaceID,job.projectID==original.projectID,
              job.revisionID==original.revisionID,job.digest==original.digest,job.requestKey==original.requestKey,
              job.remoteID==original.remoteID,job.quote.provider==original.quote.provider,job.quote.provider != "native",
              try Codec.digest(job.createdAt)==Codec.digest(original.createdAt),
              try Codec.digest(job.quote)==Codec.digest(original.quote),
              job.videoGeneration==nil,original.videoGeneration==nil else {
            throw VideoError.conflict("通用远端观察不属于原任务、冻结报价或原ID；百度生成回执须使用其专用观察规则")
        }
        guard sequence==observed,job.state==original.state,job.progress==original.progress,
              try Codec.digest(job.remoteCheckedAt)==Codec.digest(original.remoteCheckedAt),
              job.remoteReportedActual==original.remoteReportedActual,
              try Codec.digest(job.lease)==Codec.digest(original.lease),
              try Codec.digest(job.artifacts)==Codec.digest(original.artifacts),
              (job.outputAssetIDs ?? [])==(original.outputAssetIDs ?? []) else {
            throw VideoError.conflict("原任务已有较新观察、取消意图或执行/产物状态；未写入迟到回包，请读取原ID当前结果")
        }
        return sequence
    }
    /// A local cancellation intent is not a supplier observation and does not
    /// consume a version. Its state change still invalidates older observations.
    public static func requestRemoteCancellation(_ job:Job,observing original:Job)throws->Job {
        _ = try remoteObservationVersion(job,observing:original)
        return JobRules.cancel(job)
    }
    /// Async callers must retain the job observed before transport and use this
    /// overload. Receipt-backed reconciliation may change cash independently;
    /// another observation, cancellation intent or execution fact may not.
    public static func applyRemote(_ snapshot:RemoteSnapshot,to job:Job,observing original:Job,now:Date=Date())throws->Job {
        let sequence=try remoteObservationVersion(job,observing:original)
        var result=try applyRemote(snapshot,to:job,now:now)
        let nonterminal=[RemoteSnapshot.State.queued,.running,.unknown].contains(snapshot.state)
        if nonterminal,job.state == .cancelRequested {
            result.state = .cancelRequested
            result.message="取消仍待原服务确认；未知或进行中的查询不撤销取消意图，费用继续待核"
        }
        if nonterminal,job.state == .cancelled {
            result.state = .cancelled;result.progress=job.progress
            result.message="保留原任务已确认取消的事实；后续非终态观察不撤销取消，最终费用仍待核"
        }
        if nonterminal,(job.billing ?? []).isEmpty,let reported=snapshot.actual {
            let known=max(job.actual?.amount ?? 0,job.remoteReportedActual?.amount ?? 0)
            if reported.amount<known {
                result.actual=job.actual
                result.remoteReportedActual=Money(known,job.quote.upper.currency)
                result.billingUnknown=true
                result.message="已见费用继续保留；进行中或未知的较低报费不代表退款，继续核对原任务账单"
            }
        }
        result.remoteObservationSequence=sequence+1
        return result
    }
    /// Serial application of an already selected observation. Without the
    /// pre-transport job this overload cannot detect a delayed async response;
    /// repository query/cancel callers use the observing overload above.
    public static func applyRemote(_ snapshot: RemoteSnapshot, to job: Job, now: Date = Date()) throws -> Job {
        guard job.quote.provider != "native", snapshot.requestKey==job.requestKey, job.remoteID == nil || job.remoteID==snapshot.remoteID, !snapshot.remoteID.isEmpty, snapshot.progress.isFinite,(0...1).contains(snapshot.progress), snapshot.checkedAt <= now.addingTimeInterval(60), snapshot.checkedAt >= job.createdAt.addingTimeInterval(-60) else { throw VideoError.conflict("远端响应不属于原任务或时间/进度无效") }
        if let checked=job.remoteCheckedAt, snapshot.checkedAt<checked { throw VideoError.conflict("远端响应早于已核状态") }
        var j=job; j.remoteID=snapshot.remoteID; j.remoteCheckedAt=snapshot.checkedAt; j.updatedAt=now; j.progress=snapshot.progress
        switch snapshot.state { case .queued:j.state = job.state == .cancelRequested ? .cancelRequested:.queued; case .running:j.state = job.state == .cancelRequested ? .cancelRequested:.running; case .succeeded:j.state = .billingPending; j.message="远端制作完成，需核对产物/实际账单，尚未通过看听审核"; case .failed:j.state = .failed; case .cancelled:j.state = .cancelled; case .unknown:j.state = .unknownRemote }
        if let actual=snapshot.actual {
            guard actual.currency==j.quote.upper.currency,actual.amount>=0,!actual.amount.isNaN else { throw VideoError.invalid("远端账单币种/金额不符") }
            if (j.billing ?? []).isEmpty {
                // Preserve the original status-only service contract when the
                // user has not reconciled any receipt-backed ledger entries.
                j.remoteReportedActual=actual;j.actual=actual;j.billingUnknown=false
            }else {
                // Do not infer whether the supplier's number includes refunds.
                // A lower observation cannot settle an unresolved higher one;
                // the original task's terminal report must match the net ledger.
                let unresolved=job.billingUnknown && job.remoteReportedActual != job.actual
                let terminal=[RemoteSnapshot.State.succeeded,.failed,.cancelled].contains(snapshot.state)
                let confirmsNet=terminal && actual==j.actual
                let retained=unresolved && !confirmsNet ? max(job.remoteReportedActual?.amount ?? actual.amount,actual.amount):actual.amount
                j.remoteReportedActual=Money(retained,actual.currency)
                j.billingUnknown=j.remoteReportedActual != j.actual
            }
        }
        if [.queued, .running, .unknown].contains(snapshot.state) { j.billingUnknown=true }
        if !(j.billing ?? []).isEmpty,j.remoteReportedActual != nil,j.remoteReportedActual != j.actual {
            j.billingUnknown=true
            j.message="已核账单与服务报费不一致；实际及待退款按凭据保留，继续占用预算，请核对原任务差额"
        }else if !(j.billing ?? []).isEmpty,!j.billingUnknown,snapshot.actual != nil {
            j.message="原任务终态报费与已核净实际额一致；实际及待退款按凭据保留，产物仍须审核"
        }
        return j
    }
}
