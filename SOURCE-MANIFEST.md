# video-core 源码清单

VideoCore reviewed source product · manifest version 2

- 当前审定时间：2026-10-23 05:23:52 北京时间；免费上游冻结正式提交`109e4a2dc42433165ad9821ed495cec730376915`。
- 正式文本为122项源码及必要元数据，另有本清单，共123项文件；不含本清单共1191070字节。
- 整体内容指纹：`6d1c093a9e0e29e9b4a8e3bd0e7d9cbf68affec7ac0239cd57f8e2bc6060f7d2`。算法：相对路径按Unicode码点排序，各项为UTF-8“路径 + NUL + SHA-256十六进制 + NUL + 十进制字节数 + 换行”，拼接后计算SHA-256；本清单与Git元数据不参与摘要。
- 审定同源文件114项、1153182字节，逐文件与免费白名单导出及冻结正式源码完全相同，同源集指纹`046a6c078b2ff10103b7a441ba7b7803527dac3f3f4651c18ea1363cb99390c7`。Package.swift来自免费模板；独立README与7项站点附加文件保留原字节。
- 上游受控导出116项文件、1169929字节，其非清单内容指纹`964a23689a8bd76e31702ba84e733f8f5c1fba8331a447e43c8b2d309d9df286`；上游生成README不覆盖本仓库独立README。
- 生产构建输入63项，指纹`baf57de52b5c527eb9424661026a6feabad2ee77cebc07ad066e5ad2844c9c06`。相对公开`04e429bac4264b7d88d9cf001f6d815ea250ef84`仅同步安装器、其18项规则、CloudReview的iOS连接生命周期和Qwen包装及文档，共6份文件差异。
- 安装器在安装、更新、迁移和候选只读探测中保留所有BYOK配置；候选删除、改写或新增配置均拒绝。Qwen包装补齐握手、能力和命令权限、截止时间、工作区路径及显式写入许可约束。
- 当前免费包独立host SwiftPM编译通过，77.74秒；同一公共源码实际host XCTest仅运行ManagedInstallTests，18/18通过、0失败、0跳过，24.443秒。Qwen包装只调用原生env/qwen，不将本机RTK规范引入产品依赖。最新同源包装本地协议7/7通过、0失败、0跳过，0.455秒；实际模型许可往返8.698秒通过，只获准调用该新CLI的capabilities，得到唯一许可和唯一工具结果，CLI ok=true、stderr为空；不新增业务写入或媒体。
- 最新macOS x86_64 CLI为12001696字节，SHA-256`df981eca1fffff3d02e186427839e30c1a461a083338cb28e82ac92eaedc9469`；schema与capabilities两条只读调用成功并解析为对象。安装器规则使用隔离合成数据及临时签名材料，不证明生产签名安装或Gatekeeper验收。
- CloudReview连接方法防止账号失效前挂起的旧成功或旧错误覆盖新会话；该路径仅在iOS条件编译。这里的host编译及规则不证明真实CloudKit SDK、账号、共享或双身份链。
- 业务、媒体、备份和既有生态入口的未变源码证据保持原产物及调用条件边界，未重跑模型、媒体或完整规则。此前真实Qwen工程创建、编辑、备份、恢复和另一只读会话重开使用旧同源业务CLI，不将其称为新安装器的实机验收。
- 独立README SHA-256`2d70cb97074384a7dee7ec07275f5c74c6cd89033ff7d801b24b11afa27ded82`；7项站点附加文件32329字节，指纹`5b04d27050981614b158e5e5391d5e56a5b50c53419bd74986700d6490c704a2`。页面字节及依赖未改，复用北京时间2026-10-23 00:17:11原Chrome桌面与移动视口证据；不称新浏览器验收。
- 排除人工App、游戏/卡通高级实现、发布器、私钥、凭据、客户数据、模型权重、媒体、缓存、日志、任务文档及上游Git元数据。各文本仍按精确白名单、普通文件、UTF-8和敏感形态检查；模式检查不能证明任意自由文本绝无敏感信息。
- 这是独立源码发行与有限开发验证，不是App商店发行、物理安装、真实购买、CloudKit双身份或人工看听验收。源码公开不代替59FR/76TC正式验收。

## 审定同源源码与元数据

| SHA-256 | 字节数 | 包内路径 | 核对结果 |
|---|---:|---|---|
| c07cc6d537cb0e119e22a6184cb1423b3dee983074bcc4b81c17072ad9e616c5 | 93 | .gitignore | 独立原文保留 |
| c006e5a588982cee0be30f46a5e6497b7e9b1840a18a1083c69525be50d70c5c | 8790 | Integrations/README.md | 逐字节一致 |
| 4f646b85881f0ae26539807f0e26d5daad68c91e590989c4b251d9d0b10254f6 | 1859 | Integrations/check_install.py | 逐字节一致 |
| abafee4069a7a58ae79d7e180340fce80d9d51bfcfe50a49847c25da16a266d2 | 2149 | Integrations/discover.py | 逐字节一致 |
| f4ffa8e5e02d6afb0e8609383b04f8651a01e8c2b93f14b46bb4930f302bf614 | 3129 | Integrations/install.py | 逐字节一致 |
| 9f5fd384c9e1f1045d7e64869e9d1acd41184d90939add4b5fa90f0420bdf41a | 10472 | Integrations/qwen_stream.py | 逐字节一致 |
| cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 | 11358 | Integrations/skills/video/LICENSE | 逐字节一致 |
| 1dbab07b005a071618dc75a2e3cd3b68fccfba4c235d4818238a18cdbfcdb052 | 358 | Integrations/skills/video/NOTICE | 逐字节一致 |
| b4f2fbb6d085f9c48b9421a174a5ec3468753ebdad9e9e4aedb797ef3d9ff0f2 | 3404 | Integrations/skills/video/SKILL.md | 逐字节一致 |
| 80f697b67421db6f559e8ba99e92a01734018dca974979cee5f169e0f6f871e4 | 308 | Integrations/skills/video/agents/openai.yaml | 逐字节一致 |
| af117d681ee814036da2a294494d020b16173b46ff38c884a68c5ce89da9775e | 3274 | Integrations/skills/video/references/protocol.md | 逐字节一致 |
| bf5529e22ddf0a9c4742b3a274d5398ac31114d587b0abe8a76850d5d45743b0 | 5236 | Integrations/test_qwen_stream.py | 逐字节一致 |
| cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 | 11358 | LICENSE | 逐字节一致 |
| c369f09e50d62d1a1c8eff1500888667ff7a192d0fdc7b32d39c800dfa1e9721 | 1597 | NOTICE | 逐字节一致 |
| 6a9dec4441a53577b8eb06a1031205221050239fd1b4419ec8eec6132280fe46 | 1034 | Package.swift | 逐字节一致 |
| 2d70cb97074384a7dee7ec07275f5c74c6cd89033ff7d801b24b11afa27ded82 | 5559 | README.md | 独立原文保留 |
| bbfe59a972a3e8e09e347c04bc22c0eacd2544881af8a4b6068bfc30b38466e8 | 80 | Sources/CSQLite/module.modulemap | 逐字节一致 |
| b052d8e561e942f97b503033ecd2eaa2b35213bdbf374983efe9e68eabdfc024 | 21 | Sources/CSQLite/shim.h | 逐字节一致 |
| 347257a3cd5bcb0e501506a29ab4dc2892a46d2560a111a8d779b124e594ebb9 | 60 | Sources/CZlib/module.modulemap | 逐字节一致 |
| 80324eed37fb3c06611102a5ed598bb3d60aa818eeb6f848068e359677a07ea7 | 18 | Sources/CZlib/shim.h | 逐字节一致 |
| f91009e63ad2cd947bb9a9e20acc909478e7ef5374aadc08c23654f5d8894029 | 15306 | Sources/VideoCLI/FiniteWorker.swift | 逐字节一致 |
| 22a648799001a9805ed1b07e204a59bae5ed64648cd77ba970f92b77389f80f3 | 26375 | Sources/VideoCLI/VideoCLI.swift | 逐字节一致 |
| 5b689ccc73ed07010bc1427c2a6cd97fc456621222d4d1167004ed5cd9011a8f | 19933 | Sources/VideoCore/AgentContract.swift | 逐字节一致 |
| bf2f7ad7ef600774a301f579dd95b966a0702127595ca53e0ae7f55b91a2ded3 | 2784 | Sources/VideoCore/AgentJobAccess.swift | 逐字节一致 |
| 2f81c81ca458c004242b0ae2a31324cb875200b354366f287d2f75f5d85e443f | 19029 | Sources/VideoCore/AgentMutation.swift | 逐字节一致 |
| 0d3a975599e87b03984afc2b7489a027bf1d0ba1cffd4fb52c6b58e0a4473cd8 | 9547 | Sources/VideoCore/AgentPreview.swift | 逐字节一致 |
| 01f3f2d57aeccb27ae3f27ed32a3c9e6426aac00372c94c69dd18a3bf56c8667 | 10859 | Sources/VideoCore/AgentSchemas.swift | 逐字节一致 |
| 9abfcc0fb2fe524d09107761d1471684807e723a87184e2ad3cd1793b940c55f | 3611 | Sources/VideoCore/AgentWorker.swift | 逐字节一致 |
| f614a16bf6fa4c26a81de5a874d826a80e1467466ff766c51f2513a56eca4b28 | 17950 | Sources/VideoCore/BaiduVideoRules.swift | 逐字节一致 |
| f9daf43e9299138b5cabede70d516729482e08b756c1a4b1f12ace9403d9a3ce | 12324 | Sources/VideoCore/BatchRules.swift | 逐字节一致 |
| 686cbcb8b166973abac6f9bdfe7aa2395104b863b0745fe6b2499ef1ebf14995 | 10233 | Sources/VideoCore/ClassicArtwork.swift | 逐字节一致 |
| 8cd136d82731c62a68e0f1ed783aa8346982d17b5a40c99b792eefad061d2132 | 12220 | Sources/VideoCore/CloudProposalRules.swift | 逐字节一致 |
| 7bc7cb33b5ac9d8ca2f18a867d266b2703b9f94b5736cc38a1f3e539839314cf | 7281 | Sources/VideoCore/CloudReviewRules.swift | 逐字节一致 |
| aa70a32a41cea941b465ef0b004342f83ed2c362f5085d9c6c4ad55d087fcc4e | 12385 | Sources/VideoCore/Commercial.swift | 逐字节一致 |
| 37223e3cd8ad6f4f74a0207f6cc0ab7f2a24534b6cb8a9eaf0679fafcf66507f | 32992 | Sources/VideoCore/CommercialReports.swift | 逐字节一致 |
| 2fc93abd3cec06c3937d1fbcf76f3a3570e485c63312f8b23a27246cbf85c52c | 18716 | Sources/VideoCore/Dependencies.swift | 逐字节一致 |
| a6a28450f1d11a40b7df4874a0d534326a7ae5f299e8169e8fc130ed678945ac | 22556 | Sources/VideoCore/Editing.swift | 逐字节一致 |
| 8919c27e75a711c81ee719d739fb99f85c3b35286bbda913977e63fdd1a41d2e | 2095 | Sources/VideoCore/EditorPracticeRules.swift | 逐字节一致 |
| ff72243377a23f6732d56c34e50d291d82e60d1a71ada1878d9ee2e7c5f641b6 | 12517 | Sources/VideoCore/Finance.swift | 逐字节一致 |
| 9e5b2b47e55fdcf7b1495a61e0df94e9b9bb2e915bbb147ebb829585e84d148b | 6424 | Sources/VideoCore/H264Rules.swift | 逐字节一致 |
| 2bfaeccf8e337bf51c8c5e053272308a17f7973c4225570324038aa724308010 | 4242 | Sources/VideoCore/ImportRules.swift | 逐字节一致 |
| 9517233c62f47f04bbf3ff2420de159278d23f09c7733033a9f32ddcfefbe799 | 9431 | Sources/VideoCore/JobOperations.swift | 逐字节一致 |
| 28e2ca8827ae740a162e178cbd522e71f37b89e47683974844eeca854294c617 | 8368 | Sources/VideoCore/Jobs.swift | 逐字节一致 |
| c0cb25559cb31723ce791dd8bc15520a01a75c744dc9882288467729fa644f40 | 5823 | Sources/VideoCore/Layers.swift | 逐字节一致 |
| 52a5b0418fef01b5dfd816a9a66793ae9c4fb2b22d585f300dc3007568c41184 | 1890 | Sources/VideoCore/LearningExample.swift | 逐字节一致 |
| d6c06ae9b610d6b7f636e9ddc301e53445b8ac14e1ec76ff5d435d94a4aefdbe | 8706 | Sources/VideoCore/Loudness.swift | 逐字节一致 |
| 184aa174d927e574b1b049b1f296dab6b97f7c013a86335168324e8b64252f45 | 24411 | Sources/VideoCore/ManagedInstaller.swift | 逐字节一致 |
| c5f7880b28d3447646ea9e8b51e540d171d17455ccf182941e0646fd206c0d98 | 7620 | Sources/VideoCore/ManagedPayload.swift | 逐字节一致 |
| c7c418a77444319e56b71a73ca27a9a9c26fc306ae1e4897ae57705d738fd5f9 | 11686 | Sources/VideoCore/ManagedRelease.swift | 逐字节一致 |
| c6950f5da04d4531602d738f2552d3a56aff377375d5c96990a27cd23a050a73 | 15431 | Sources/VideoCore/Models.swift | 逐字节一致 |
| f4d5ffef84c3177d22f93b5f0b12400e9121fc6eb34703de1d735fa599cea8fe | 15222 | Sources/VideoCore/ModuleCatalogPublication.swift | 逐字节一致 |
| 4a02f41deb1d630359922eebe8ffe3a436ceedf95ad9ca823a2eb532f74de145 | 28979 | Sources/VideoCore/Narratives.swift | 逐字节一致 |
| dcbb916e15aa23f978884fb17c6a9696973b7021adbe5a2e1ace68653634fadb | 6458 | Sources/VideoCore/NativeAgent.swift | 逐字节一致 |
| b0888e7851c11f828fc45640bc325815b3aa30526df1eaede5d84992fedb68a8 | 5324 | Sources/VideoCore/Primitives.swift | 逐字节一致 |
| 6440b894201e6e3188bc62c1a2ec1ed1dc50e6f4b17db287fac7fa9f85f1ae01 | 7546 | Sources/VideoCore/ProviderRules.swift | 逐字节一致 |
| e62621f018997d0e706facbd0a59224f61d70e4d8b56c84feb512c59695c09eb | 5921 | Sources/VideoCore/PublicationRules.swift | 逐字节一致 |
| a81ccc15614d9f5d6f2445cfbf2365a738a7a527e01201bad8c3d70372c4ae97 | 18734 | Sources/VideoCore/Speech.swift | 逐字节一致 |
| ae4d4e3f7b3b58a1aca1691127a4fecc9d594695df85b0d048902f995c272b9f | 26989 | Sources/VideoCore/Storage.swift | 逐字节一致 |
| 0cfd24a48f1ac03f1b9a34f4b80cd4cd57fdf3ca10eee07183be496971ed16a1 | 20722 | Sources/VideoCore/WorkspaceAccess.swift | 逐字节一致 |
| e7dd8743febbec2cfdc92e4656c3dcb1fbd54f8eb2a7b71e9863b371b0fcb6a3 | 11050 | Sources/VideoInstall/VideoInstall.swift | 逐字节一致 |
| ea4dc3e512b818726ea6fd7d350e697ef234e337bafff6e34d8af40720d9cc54 | 14314 | Sources/VideoMedia/BaiduVideoProvider.swift | 逐字节一致 |
| ec396089cb7046846c5bf86bd37f830869418de4445dec089466753f3c1e1329 | 4943 | Sources/VideoMedia/ClassicArtworkMedia.swift | 逐字节一致 |
| 6beff353416b9b4329e20ab3cbd84fcb19d34c8687427feb157b97d00ed63b4d | 10707 | Sources/VideoMedia/ClassicBuiltinAssets.swift | 逐字节一致 |
| d389ae3a6697c18d8f63e8a58e1334664b4b984db1dd7ca8de44c7025f8b61fd | 49409 | Sources/VideoMedia/CloudReview.swift | 逐字节一致 |
| 451de62ae66ce51bc390deb9d210ca46de5ca66e5bb52b4572a6e5e792e141a2 | 4904 | Sources/VideoMedia/CoursePreview.swift | 逐字节一致 |
| a3c1ff6981dd81b2a97fee7cff2489fc9edb2381904ee46ebad18e9b6562dc91 | 4662 | Sources/VideoMedia/Diagnostics.swift | 逐字节一致 |
| 2eafa759e4f2e1a94a5ecb866f39784b13363f7a5cfcacb60b125cf5e2fa12bd | 13316 | Sources/VideoMedia/FamiliarBuiltinAssets.swift | 逐字节一致 |
| 78eab44c664d354ecf71559b09af166acca4d9ee2c46786e9449fe9d2c8799cf | 9759 | Sources/VideoMedia/Importer.swift | 逐字节一致 |
| 6a44c3423c3414547f8cd78bc171a95e5789a8c8fab8b7ec0a8efe23f6c21fc3 | 2494 | Sources/VideoMedia/LayerPainter.swift | 逐字节一致 |
| ef20e2360f98d7a69fbcfa44641900a3387ff27d6c8537d0a2834d0ab825371f | 3181 | Sources/VideoMedia/LocalJobExecutor.swift | 逐字节一致 |
| dc8002d0598d1a8397f6462fb6df9f8eb182183ffdd328a3d3faf7b40b904aa8 | 10816 | Sources/VideoMedia/Painter.swift | 逐字节一致 |
| 54f2c2e61cd64c9b3a668a903d13c5dc81287cb6c3221dc6d62396bf9a864141 | 2044 | Sources/VideoMedia/Preview.swift | 逐字节一致 |
| b559534d57549106cce137f015699a82fda438fe7cb686affd8201b65e07caed | 5695 | Sources/VideoMedia/ProviderClient.swift | 逐字节一致 |
| 4f19002514353501551d4b0930172d62e5d65803e953cd9db6005a9d704cc6e0 | 3782 | Sources/VideoMedia/RemoteJobs.swift | 逐字节一致 |
| 5d6e1eed0aaa7ccf3c784077300e1b9a4ae6332e6cb5e5fb926bbd3437dbedf4 | 26808 | Sources/VideoMedia/RenderModules.swift | 逐字节一致 |
| 402b0323be6202700acdd55831a8ee4cb8c76f68ee52cde8f61edb302e64b106 | 26639 | Sources/VideoMedia/Renderer.swift | 逐字节一致 |
| 9ec229f48547a7e2e0218d913dba2dfd38457f08ae55196979968dbbdee2d4e0 | 11971 | Sources/VideoMedia/SpeechService.swift | 逐字节一致 |
| 924b79fb85d46d8f92c02e9347beabbd3c608929b0c5820d6b0ae597938bb941 | 12830 | Sources/VideoMedia/VisualCache.swift | 逐字节一致 |
| 889d232f2f397a808d7d59eff398ccf0d0c8daa0d8e2ae9e9e08d1e16733b6ba | 4502 | Tests/VideoCLITests/baidu_contract_smoke.swift | 逐字节一致 |
| 5ae0c014535f0d2d9217494b30c1e8fe07336f3ee3ee2551abc52b4d21e9aac7 | 7640 | Tests/VideoCLITests/status_scope_smoke.py | 逐字节一致 |
| 09b3610b368060baad6f10bf2636233ff740e5bcffe06a4efb28e61feb743b84 | 7466 | Tests/VideoCLITests/worker_smoke.py | 逐字节一致 |
| 2bfdd4935e5f4e53fb1934516db3c6d3acc1f19f346d021686a24cd9ed1e9895 | 5693 | Tests/VideoCoreTests/AgentContractTests.swift | 逐字节一致 |
| 3f5d9b81a289338a77f797ece9dd2d0fcb77a916ab24a2304ba67263bcd5fab8 | 5797 | Tests/VideoCoreTests/AgentJobAccessTests.swift | 逐字节一致 |
| 07b0ec765ee07e2ad3462964180a017b3d7c03d1037590c875e1082b13de8b27 | 12395 | Tests/VideoCoreTests/AgentMutationTests.swift | 逐字节一致 |
| ac2f463ab1d63294907721e001aa208851136547d1bff6a28e9d3efde2e6335a | 2864 | Tests/VideoCoreTests/AgentPreviewTests.swift | 逐字节一致 |
| 8e49c786e7e74699b2a928dc5044d12abbd9b99365ccbedd680aa88267099c7e | 4852 | Tests/VideoCoreTests/AgentSchemasTests.swift | 逐字节一致 |
| fad7f9ba02a4649d468bc0de5e3a5404015f89fcc2eb9c971542b055459f9bea | 3838 | Tests/VideoCoreTests/AgentWorkerTests.swift | 逐字节一致 |
| 1cbb595ea74fc3d72417dd3b1ccfaa5854f6c13feb6562ca37a25272794e7823 | 11809 | Tests/VideoCoreTests/BaiduVideoRulesTests.swift | 逐字节一致 |
| 0cd1f2557db0264ca5eea0934d454d89792cc56e18127658398da9f52e4fa2a6 | 7465 | Tests/VideoCoreTests/BatchTests.swift | 逐字节一致 |
| 84bf0bbbf07c6dfb4a679f9754c238253b53237018d8519be541453f48c70e40 | 11156 | Tests/VideoCoreTests/BrandDeliveryTests.swift | 逐字节一致 |
| c19dd668a235f222bb68d631b9d6dbe34fa53619e9eb4d1003a0709f78347e4f | 7220 | Tests/VideoCoreTests/ClassicArtworkTests.swift | 逐字节一致 |
| 7c742541b3db16c85878d8444639a450f5ed9bcd6c8d9662bb5f2251e2ba4b31 | 14342 | Tests/VideoCoreTests/CloudProposalTests.swift | 逐字节一致 |
| df48a1effa4d0c09db287ca76a6ce735999ae55203b204ac5b58535c8f1c5870 | 8137 | Tests/VideoCoreTests/CloudReviewTests.swift | 逐字节一致 |
| d6f32510e1092e64a73bf2fba1b1c8d1e1c1d6271bfed3dcbf12eb11665bc347 | 10029 | Tests/VideoCoreTests/CommercialTests.swift | 逐字节一致 |
| 99a8daf70a5e5df163941ed33eebd01813b5ba326302f16414ba768d7ab82799 | 11877 | Tests/VideoCoreTests/DependencyTests.swift | 逐字节一致 |
| 87dd1926450623dfa1b1bf1b817530da5e9085ecb1cb6f720dda9f1d58e829b6 | 40448 | Tests/VideoCoreTests/DomainTests.swift | 逐字节一致 |
| 97e9df31b1135207c3f5751836180994700084aa5223ab553acdc4082ed0700f | 4233 | Tests/VideoCoreTests/EditorPracticeTests.swift | 逐字节一致 |
| 2b62fdf4fe6d33e509688253a6e85d6293e58b5188dedfeeeb21f5a1eb335793 | 3900 | Tests/VideoCoreTests/H264RulesTests.swift | 逐字节一致 |
| 34834eefae890a78408967bdb8cab12fe06ba9708ba127f2a1ed61520f9d3aea | 5221 | Tests/VideoCoreTests/JobOperationTests.swift | 逐字节一致 |
| 1c7965c4e437acd65085788b53c88a94ce7aaa8c604e98daa53c1ddae76ff57f | 2546 | Tests/VideoCoreTests/LayerTests.swift | 逐字节一致 |
| 082a8f3a9302736ee62ddc5eab2609dacac100a83145b24b55d5ed6b97ba1737 | 5928 | Tests/VideoCoreTests/LoudnessTests.swift | 逐字节一致 |
| 64e66e90b81fec6ff7c57525ea6160ec9b9429be34424fccb236e9109cc72a43 | 25072 | Tests/VideoCoreTests/ManagedInstallTests.swift | 逐字节一致 |
| 492ed82d5e1d5d7fb2d20071dda1c8dc22a0fcd33b4baf82fed247110d871474 | 7675 | Tests/VideoCoreTests/ManagedPayloadTests.swift | 逐字节一致 |
| 15accf442db3ce30dc6b0ce7c6e8f50d946594eaf1afd592b4af9ba5f0ff8cbf | 12483 | Tests/VideoCoreTests/ModuleCatalogPublicationTests.swift | 逐字节一致 |
| 7ba1587dc551d09402b66e7ef663cc5b7478a55c52c1d6ef93dfe129020d2d7d | 17745 | Tests/VideoCoreTests/NarrativeTests.swift | 逐字节一致 |
| c499c8ae6aca4855864eb5a5e2c5a55305643953a9c47073fc66b45c9bb41767 | 5752 | Tests/VideoCoreTests/NativeAgentTests.swift | 逐字节一致 |
| 9f9e0b1055a1b9ca2dfb2c1a4f03681c0af63641bee85a33384100e0065f9e6c | 4615 | Tests/VideoCoreTests/ProviderRulesTests.swift | 逐字节一致 |
| 2757b45f6d8989066c3a2a4b52177d047b805052386ebf0eb2f5ad81d46ade46 | 10276 | Tests/VideoCoreTests/PublicationTests.swift | 逐字节一致 |
| c927d9faea68877b494d6fbac3aa5f76001c427ff5de168208d5e049036ec918 | 7072 | Tests/VideoCoreTests/SpeechTests.swift | 逐字节一致 |
| 849d8301671e8780cb4ccd90d761af1e50fbc12938ae1eb458151ec1c91ba4f1 | 17669 | Tests/VideoCoreTests/WorkspaceAccessTests.swift | 逐字节一致 |
| 0207a9002bb7aef610449bd354ee6c50034a84f81d1a261ea8846a9bb864aada | 1906 | Tests/VideoMediaTests/BaiduVideoProviderTests.swift | 逐字节一致 |
| 88150479390d0501342c4c5789864dec9fc2a74522e0806dabeec9d269e143c7 | 3816 | Tests/VideoMediaTests/CloudReviewLocationTests.swift | 逐字节一致 |
| c7b7bf2aa6091f105373becd60c2dc830ed5167fc85db480b9193d60543e1db4 | 3999 | Tests/VideoMediaTests/CoursePreviewTests.swift | 逐字节一致 |
| c7e58b70577f1181d014ba4a7e15bdd276a97129afc9fb2fb7086da9ad1f86b8 | 11493 | Tests/VideoMediaTests/LoudnessMediaTests.swift | 逐字节一致 |
| 9aea48b1ac047193b29e9b16b856fdbce5db432335c4449fa2ffe26c9dad0bae | 16513 | Tests/VideoMediaTests/MediaTests.swift | 逐字节一致 |
| 8700e3940f97c103e7561d937aecd7ec4cdc73a997ca53ba82e380968be1624d | 5269 | Tests/VideoMediaTests/SpeechMediaTests.swift | 逐字节一致 |
| e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 | 0 | docs/.nojekyll | 独立原文保留 |
| 88c943e9363dfde53eec899b086d9a3f5c589837d37e081b14539d1dea25a2a8 | 4342 | docs/index.html | 独立原文保留 |
| 461d5bf52e253071a3ea53eb0033f82f270381559f9182f6717c185dc4d63a43 | 8241 | docs/privacy.html | 独立原文保留 |
| 5f1f0911ebcd0163bc0daa42147f4924cc1713a12b34e2ad8eb9e4b84d60a530 | 4718 | docs/site.css | 独立原文保留 |
| 37ed49710d24edd4fd6cd46bc36744e2edc46dd12d205d2a4af2fdad6845f95b | 9481 | docs/support.html | 独立原文保留 |
| a57baa454e02631f7a3c88b1e51dd3bc60d3e173084d391061eefc8b6d20a74f | 5454 | docs/terms.html | 独立原文保留 |
