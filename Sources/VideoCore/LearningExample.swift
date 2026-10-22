import Foundation

public enum LearningExample {
    /// An explicitly requested tutorial, never inserted into a user's real business workspace.
    public static func project(workspaceID:String,asset:Asset)throws->Project {
        guard asset.workspaceID==workspaceID else {throw VideoError.permission("示例来源工作区不符")}
        var product=Product(workspaceID:workspaceID,sku:"practice-local-explanation",name:"离线练习（合成示意，非商品）",checkout:"https://example.com/training",audience:"首次使用者",task:"预览并修改一个片段",outcome:"掌握版本保存与恢复操作",prerequisite:"无需模型账户",scope:"基础编辑与本地输出示意",prices:[Price(money:Money(0),from:Date(timeIntervalSince1970:0),source:"练习示意值，不代表任何真实售价",verified:true)])
        product.isExample=true;product.assetIDs=[asset.id]
        var a=Scene(title:"从一个知识点开始",body:"这是合成练习资料，未代表任何真实商品、销量或经营结果。",durationFrames:120)
        var b=Scene(title:"改一处，留一个版本",body:"编辑这段正文，再保存新版本。旧版内容仍可在版本记录中查看。",durationFrames:150)
        var c=Scene(title:"完整看听后再交付",body:"本例明确没有旁白。实际作品需要核对字幕、声音、来源与权利。",durationFrames:150)
        let source=NarrativeSource(assetID:asset.id,excerpt:"基础编辑与本地输出练习",confirmed:true)
        a.narrativeSources=[source];b.narrativeSources=[source];c.narrativeSources=[source]
        let r=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[a,b,c],cta:"换成真实资料，再创建自己的作品",change:"用户主动创建离线练习示例")
        return Project(workspaceID:workspaceID,name:"第一次离线练习（示意）",revision:r)
    }
}
