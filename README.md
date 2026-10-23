# video-core

免费的视频制作基础源码，包含 Swift SDK、macOS 命令行工具和共用 Agent Skill，采用 Apache-2.0 许可。

普通工程从材料、讲稿或空白时间线开始，不要求商品、SKU、价格或购买页。可编辑真实素材、声音与字幕，并使用原生 H.264/AAC 导出；基础制作独立于高级模块和 Mac App，不要求联网激活。营收管理、销售订单和变现渠道不属于桌面制作工具的功能。旧工程兼容数据结构继续保留，不会因此成为普通制作的前置。

## 运行条件

- CLI 需要 macOS 14 或更新版本、Swift 5.10 或更新的兼容 Apple 工具链，以及宿主明确授予的本机工具执行权限。不是 Windows、Linux 或浏览器端视频运行时。
- VideoCore、VideoMedia 的包声明保留历史 iOS 17 兼容范围；当前人工应用目标为 macOS 桌面，本仓库不包含完整人工 App，也不代表发行手机 App。
- 外部模型和云服务使用用户自己的账户；服务费用、输入数据和素材许可由使用者核对。模型 API 本身不会取得本机执行权限。

## 从源码构建

在仓库根目录构建；示例把派生缓存放到明确的本机缓存目录：

    swift build --scratch-path .cache/build --product video
    .cache/build/debug/video doctor
    .cache/build/debug/video capabilities
    .cache/build/debug/video schema

业务调用使用显式 --workspace 和 --input。projects create 可以建立没有商品的 schema 2 工程；script create 的 product_id 可省略。命令字段、权限、退出码和幂等语义以实际 schema 为准。旧 schema 1 产品工程仍按原证据规则读取，不会伪造零元商品或默认销售 CTA。

queued 只表示排队；needs_review 仍需真实的人完整看听并审核。Agent 不得代填人工声明。修改版本、声音、字幕或素材会使相应审核和导出失效，未审核产物不能冒称可交付。

video-install 提供固定发行者签名目录包的安装、更新和程序/数据成对回滚：

    swift build --scratch-path .cache/build --product video-install
    .cache/build/debug/video-install --help

更新器不提供私钥、许可证或跳过签名检查的开关。当前公开的是源码，尚无已签名、公证的 Mac 二进制或正式购买入口。

## SDK 与 Skill

VideoCore 提供不可变工程 IR、版本、权限和审核规则；VideoMedia 提供 Apple 原生素材、声音和渲染适配。两个产品可通过 Swift Package 集成。

共用 Skill 的逐文件安装、发现辅助和宿主能力边界见 [Integrations](Integrations/README.md)。安装只写用户明确选择的目录，不更改模型账户、供应商配置或执行许可。提供适配材料不等于五种宿主的完整业务链或市场审核已经通过。

## 当前验证边界

2026-10-23（北京时间），本轮独立免费包在 macOS 重新编译通过，并通过真实 CLI 的 18 次普通工程调用：没有商品的空白草稿、真实输入脚本、重复请求与冲突、权限、空草稿制作门禁和数据诊断。该检查不代填人工审核；不沿用旧商品链结果作为普通工程通过证据。发布后的媒体与备份恢复链单独核验，不由这 18 次调用推断通过。

已有工程、素材和历史导出不会因购买或联网激活被扣押。高级游戏/卡通实现、人工 Mac App、发行私钥、模型权重、客户数据和媒体素材不包含在本仓库。公共能力协议和策略接口不会授予闭源实现或相应权益。

## 产品支持文档

[产品介绍](docs/index.html)、[使用支持](docs/support.html)、[隐私说明](docs/privacy.html)和[使用条款](docs/terms.html)说明 macOS 桌面视频剪辑产品的范围。桌面 App 仍在开发，页面不提供正式应用下载或购买，不以网页介绍冒充已发行产物。

## 许可与源码核对

参阅 [LICENSE](LICENSE)、[NOTICE](NOTICE) 和 [SOURCE-MANIFEST.md](SOURCE-MANIFEST.md)。源码许可不替代系统框架、外部服务或用户素材各自的许可与费用。清单证明指定源码字节，不证明 Mac UI、真实购买、跨身份协作、公证发行或完整集中验收通过。
