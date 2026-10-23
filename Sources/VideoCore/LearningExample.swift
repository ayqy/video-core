import Foundation

public enum LearningExample {
    public static let contentProjectName = "时间轴剪辑练习（自带说明）"
    public static let contentSourceName = "时间轴剪辑练习-自带说明.txt"
    public static let contentSourceText = "从时间轴开始\n镜头按顺序组成作品。选中一个镜头，可以修改文字、位置与时长。\n\n让改动有据可查\n应用修改后会保存新版本。观看倍率仅影响预览；修改镜头速度才会改变成片时轴。"

    /// A normal schema-2 walkthrough bound to the actual, fixed built-in source.
    /// The caller ingests these UTF-8 bytes into CAS and saves this project atomically.
    public static func contentProject(workspaceID:String,asset:Asset)throws->Project {
        guard matchesContentSource(asset,workspaceID:workspaceID) else {
            throw VideoError.permission("普通剪辑练习须绑定本工作区的固定自带说明原件、文本和摘要")
        }
        var context=ContentContext(workspaceID:workspaceID,name:contentProjectName)
        context.assetIDs=[asset.id]
        let first=Scene(title:"从时间轴开始",body:"镜头按顺序组成作品。选中一个镜头，可以修改文字、位置与时长。",durationFrames:120)
        let second=Scene(title:"让改动有据可查",body:"应用修改后会保存新版本。观看倍率仅影响预览；修改镜头速度才会改变成片时轴。",durationFrames:150)
        var revision=Revision(contentContext:context,purpose:.education,aspect:.landscape,scenes:[first,second],change:"用户主动创建自带说明剪辑练习")
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[])
        return Project(workspaceID:workspaceID,name:contentProjectName,revision:revision)
    }
    static func matchesContentSource(_ asset:Asset,workspaceID:String)->Bool {
        let bytes=Data(contentSourceText.utf8)
        guard !workspaceID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !asset.id.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              asset.workspaceID==workspaceID,asset.hash==Codec.hash(bytes),asset.bytes==bytes.count,
              asset.mediaType=="text",asset.ext=="txt",asset.durationFrames==nil,
              asset.generatedSource==nil,asset.evidenceID==nil,asset.pages.count==1,
              let page=asset.pages.first,page.number==1,page.text==contentSourceText,
              page.notes.isEmpty,!page.requiresOCR else{return false}
        return true
    }

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
