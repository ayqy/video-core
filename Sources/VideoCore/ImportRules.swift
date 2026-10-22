import Foundation

public enum ImportRules {
    public struct OrderPreview:Sendable { public var batchID:String; public var rows:[Order]; public var duplicateRows:Int; public var updateCount:Int }
    public static func date(_ text:String) throws -> Date {
        let f=ISO8601DateFormatter(); if let d=f.date(from:text){return d}; f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; if let d=f.date(from:text){return d}
        let b=DateFormatter(); b.locale=Locale(identifier:"en_US_POSIX"); b.timeZone=TimeZone(identifier:"Asia/Shanghai"); b.dateFormat="yyyy-MM-dd"; b.isLenient=false; if let d=b.date(from:text),b.string(from:d)==text{return d}; throw VideoError.invalid("日期须为带时区ISO时间或北京时间YYYY-MM-DD")
    }
    public static func orders(_ csv:String,workspace:Workspace,existing:[Order]) throws -> OrderPreview {
        let raw=try CSV.parse(csv); let batchID=Codec.hash(Data((workspace.id+"|orders|"+csv).utf8)); var result:[String:Order]=[:]; var duplicates=0
        for (i,row) in raw.enumerated() {
            func required(_ k:String)throws->String{guard let s=row[k],!s.isEmpty else{throw VideoError.invalid("第\(i+2)行缺少\(k)")};return s}
            let paid=try Money(text:required("amount"),currency:row["currency"] ?? "CNY"); let fee:Decimal?; if let s=row["fee"],!s.isEmpty{fee=try Money(text:s,currency:paid.currency).amount}else{fee=nil}
            let kind=CustomerKind(rawValue:row["customer_kind"] ?? "") ?? .unknown
            var order=try Order(workspaceID:workspace.id,platform:required("platform"),rawOrderID:required("order_id"),rawBuyerID:row["buyer_id"] ?? "",salt:workspace.salt,sku:required("sku"),paidAt:date(required("paid_at")),paid:paid,fee:fee,sourceCode:(row["source_code"]?.isEmpty==false ? row["source_code"]:nil),kind:kind,maturityDays:Int(row["maturity_days"] ?? "7") ?? 7,importID:batchID)
            let prior=result[order.id] ?? existing.first{$0.id==order.id && $0.workspaceID==workspace.id}
            if let prior {
                guard prior.paid==order.paid,prior.sku==order.sku,prior.paidAt==order.paidAt else{throw VideoError.conflict("同订单的SKU、实付或付款时间冲突；请核对原凭证")}; order.refunds=prior.refunds
                if result[order.id] != nil{duplicates += 1}
            }
            if let refund=row["refund_amount"],!refund.isEmpty {
                let amount=try Money(text:refund,currency:paid.currency).amount; let rawID=try required("refund_id"); let id=Codec.hash(Data((workspace.salt+order.id+rawID).utf8)); let event=Refund(id:id,amount:amount,at:try date(required("refund_at")))
                if let old=order.refunds.first(where:{$0.id==id}) {guard old==event else{throw VideoError.conflict("同退款事件内容冲突，请核对后回滚修订")}}else{order.refunds.append(event)}
            }
            try order.validate(); result[order.id]=order
        }
        let rows=result.values.sorted{$0.id<$1.id}; return OrderPreview(batchID:batchID,rows:rows,duplicateRows:duplicates,updateCount:rows.filter{o in existing.contains{$0.id==o.id}}.count)
    }
    public static func metrics(_ csv:String,workspaceID:String) throws -> (String,[Metric]) {
        let batch=Codec.hash(Data((workspaceID+"|metrics|"+csv).utf8)); let raw=try CSV.parse(csv)
        let rows=try raw.enumerated().map { i,row -> Metric in
            guard let platform=row["platform"],let content=row["content_id"],let at=row["as_of"],let v=row["views"],let views=Int64(v),let definition=row["definition"] else{throw VideoError.invalid("第\(i+2)行缺少指标表头或数值无效")}
            let arrivals:Int64?; if let s=row["arrivals"],!s.isEmpty{guard let n=Int64(s)else{throw VideoError.invalid("到达数不是整数")};arrivals=n}else{arrivals=nil}
            if let value=row["cumulative"],!value.isEmpty,!["true","false"].contains(value){throw VideoError.invalid("累计标记仅接受true或false")}
            return try Metric(workspaceID:workspaceID,platform:platform,contentID:content,asOf:date(at),window:row["window"] ?? "lifetime",cumulative:row["cumulative"] != "false",views:views,arrivals:arrivals,definition:definition,importID:batch)
        }; return (batch,rows)
    }
}
