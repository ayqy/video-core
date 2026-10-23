# 免费源码分包清单

VideoFree source export · package_free.py · version 1

生成时间：2026-10-23 08:35:41 北京时间

- 源码与必要元数据：122个文件；1256045字节（不含本清单）。
- 整体内容指纹：`59ebd52f8da00b4893d83c97320bccc6c4b87403f546f2143dc2288ad7669643`。
- 来源：受控原始工程中的逐文件白名单；Package.swift来自Distribution/Free/Package.swift模板，README由发行脚本生成。
- 本包不含.git，不可作为新业务checkout；本清单生成过程不执行构建、设备验收、签名安装或公共上传，各阶段以独立证据为准。
- 排除：App、VideoGame、VideoCartoon、Premium、高级实现运行时测试、私有仓库地址、凭据、客户数据、缓存、日志及媒体过程产物。
- 已检查：路径与普通文本文件类型、符号/硬链接拒绝、免费源码闭源import、已知凭据形态和仓库URL。模式检查不能证明任意自由文本绝无敏感信息，仍需发行审查。
- 固定测试例外：PublicationTests的凭据拒绝测试包含一条已按SHA-256精确审核的合成字符串；仅该匹配允许，其余测试与生产源码适用同一检查。

| SHA-256 | 字节数 | 包内路径 / 原工程来源 |
|---|---:|---|
| c006e5a588982cee0be30f46a5e6497b7e9b1840a18a1083c69525be50d70c5c | 8790 | Integrations/README.md |
| 4f646b85881f0ae26539807f0e26d5daad68c91e590989c4b251d9d0b10254f6 | 1859 | Integrations/check_install.py |
| abafee4069a7a58ae79d7e180340fce80d9d51bfcfe50a49847c25da16a266d2 | 2149 | Integrations/discover.py |
| f4ffa8e5e02d6afb0e8609383b04f8651a01e8c2b93f14b46bb4930f302bf614 | 3129 | Integrations/install.py |
| 9f5fd384c9e1f1045d7e64869e9d1acd41184d90939add4b5fa90f0420bdf41a | 10472 | Integrations/qwen_stream.py |
| cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 | 11358 | Integrations/skills/video/LICENSE |
| 1dbab07b005a071618dc75a2e3cd3b68fccfba4c235d4818238a18cdbfcdb052 | 358 | Integrations/skills/video/NOTICE |
| b4f2fbb6d085f9c48b9421a174a5ec3468753ebdad9e9e4aedb797ef3d9ff0f2 | 3404 | Integrations/skills/video/SKILL.md |
| 80f697b67421db6f559e8ba99e92a01734018dca974979cee5f169e0f6f871e4 | 308 | Integrations/skills/video/agents/openai.yaml |
| af117d681ee814036da2a294494d020b16173b46ff38c884a68c5ce89da9775e | 3274 | Integrations/skills/video/references/protocol.md |
| bf5529e22ddf0a9c4742b3a274d5398ac31114d587b0abe8a76850d5d45743b0 | 5236 | Integrations/test_qwen_stream.py |
| cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 | 11358 | LICENSE |
| c369f09e50d62d1a1c8eff1500888667ff7a192d0fdc7b32d39c800dfa1e9721 | 1597 | NOTICE |
| 6a9dec4441a53577b8eb06a1031205221050239fd1b4419ec8eec6132280fe46 | 1034 | Package.swift |
| e1a4b72f972f0afb7cdc025ad9dbb908d92a5cea22434199ea6d968b4e110a56 | 2073 | README.md |
| bbfe59a972a3e8e09e347c04bc22c0eacd2544881af8a4b6068bfc30b38466e8 | 80 | Sources/CSQLite/module.modulemap |
| b052d8e561e942f97b503033ecd2eaa2b35213bdbf374983efe9e68eabdfc024 | 21 | Sources/CSQLite/shim.h |
| 347257a3cd5bcb0e501506a29ab4dc2892a46d2560a111a8d779b124e594ebb9 | 60 | Sources/CZlib/module.modulemap |
| 80324eed37fb3c06611102a5ed598bb3d60aa818eeb6f848068e359677a07ea7 | 18 | Sources/CZlib/shim.h |
| f91009e63ad2cd947bb9a9e20acc909478e7ef5374aadc08c23654f5d8894029 | 15306 | Sources/VideoCLI/FiniteWorker.swift |
| 22a648799001a9805ed1b07e204a59bae5ed64648cd77ba970f92b77389f80f3 | 26375 | Sources/VideoCLI/VideoCLI.swift |
| 5b689ccc73ed07010bc1427c2a6cd97fc456621222d4d1167004ed5cd9011a8f | 19933 | Sources/VideoCore/AgentContract.swift |
| bf2f7ad7ef600774a301f579dd95b966a0702127595ca53e0ae7f55b91a2ded3 | 2784 | Sources/VideoCore/AgentJobAccess.swift |
| 7402a670da1e7fa6a547f0aef9a7bea98f7c6a1c1d8ddc6be134a32ca6965091 | 19110 | Sources/VideoCore/AgentMutation.swift |
| 0d3a975599e87b03984afc2b7489a027bf1d0ba1cffd4fb52c6b58e0a4473cd8 | 9547 | Sources/VideoCore/AgentPreview.swift |
| f2900528cc1b9d8381329336d9a8ad099ef77b9bc091e1c8435b933b03be805f | 11371 | Sources/VideoCore/AgentSchemas.swift |
| 9abfcc0fb2fe524d09107761d1471684807e723a87184e2ad3cd1793b940c55f | 3611 | Sources/VideoCore/AgentWorker.swift |
| a4a917beec4d38f3d9c9aa6f13c83f269987305ab84a195e953a86907fadc3ac | 4979 | Sources/VideoCore/AttributionEditing.swift |
| f614a16bf6fa4c26a81de5a874d826a80e1467466ff766c51f2513a56eca4b28 | 17950 | Sources/VideoCore/BaiduVideoRules.swift |
| f9daf43e9299138b5cabede70d516729482e08b756c1a4b1f12ace9403d9a3ce | 12324 | Sources/VideoCore/BatchRules.swift |
| 686cbcb8b166973abac6f9bdfe7aa2395104b863b0745fe6b2499ef1ebf14995 | 10233 | Sources/VideoCore/ClassicArtwork.swift |
| 8cd136d82731c62a68e0f1ed783aa8346982d17b5a40c99b792eefad061d2132 | 12220 | Sources/VideoCore/CloudProposalRules.swift |
| 7bc7cb33b5ac9d8ca2f18a867d266b2703b9f94b5736cc38a1f3e539839314cf | 7281 | Sources/VideoCore/CloudReviewRules.swift |
| b2cdd155b2ff7507f9ea0ca1b1c85ae41059c903c829d1aecb14f704a34badf0 | 17671 | Sources/VideoCore/CohortFinance.swift |
| aa70a32a41cea941b465ef0b004342f83ed2c362f5085d9c6c4ad55d087fcc4e | 12385 | Sources/VideoCore/Commercial.swift |
| 37223e3cd8ad6f4f74a0207f6cc0ab7f2a24534b6cb8a9eaf0679fafcf66507f | 32992 | Sources/VideoCore/CommercialReports.swift |
| 2fc93abd3cec06c3937d1fbcf76f3a3570e485c63312f8b23a27246cbf85c52c | 18716 | Sources/VideoCore/Dependencies.swift |
| b9c3658050d3c7b0920948f82863b29ccf1ff1b183ee363e721ca4893408389f | 24633 | Sources/VideoCore/Editing.swift |
| 8919c27e75a711c81ee719d739fb99f85c3b35286bbda913977e63fdd1a41d2e | 2095 | Sources/VideoCore/EditorPracticeRules.swift |
| ff72243377a23f6732d56c34e50d291d82e60d1a71ada1878d9ee2e7c5f641b6 | 12517 | Sources/VideoCore/Finance.swift |
| 9e5b2b47e55fdcf7b1495a61e0df94e9b9bb2e915bbb147ebb829585e84d148b | 6424 | Sources/VideoCore/H264Rules.swift |
| 2bfaeccf8e337bf51c8c5e053272308a17f7973c4225570324038aa724308010 | 4242 | Sources/VideoCore/ImportRules.swift |
| 9517233c62f47f04bbf3ff2420de159278d23f09c7733033a9f32ddcfefbe799 | 9431 | Sources/VideoCore/JobOperations.swift |
| 28e2ca8827ae740a162e178cbd522e71f37b89e47683974844eeca854294c617 | 8368 | Sources/VideoCore/Jobs.swift |
| c0cb25559cb31723ce791dd8bc15520a01a75c744dc9882288467729fa644f40 | 5823 | Sources/VideoCore/Layers.swift |
| 52a5b0418fef01b5dfd816a9a66793ae9c4fb2b22d585f300dc3007568c41184 | 1890 | Sources/VideoCore/LearningExample.swift |
| d6c06ae9b610d6b7f636e9ddc301e53445b8ac14e1ec76ff5d435d94a4aefdbe | 8706 | Sources/VideoCore/Loudness.swift |
| 184aa174d927e574b1b049b1f296dab6b97f7c013a86335168324e8b64252f45 | 24411 | Sources/VideoCore/ManagedInstaller.swift |
| c5f7880b28d3447646ea9e8b51e540d171d17455ccf182941e0646fd206c0d98 | 7620 | Sources/VideoCore/ManagedPayload.swift |
| c7c418a77444319e56b71a73ca27a9a9c26fc306ae1e4897ae57705d738fd5f9 | 11686 | Sources/VideoCore/ManagedRelease.swift |
| 04a88217dd3365de9e85e46331ad354828eb7114fbb91653d60a0445f96f69e8 | 16013 | Sources/VideoCore/Models.swift |
| 7d8d9af9996744ea6ae4b13cf284f56c9f2f1bf217e51469466c949a570eb0af | 21343 | Sources/VideoCore/ModuleCatalogPublication.swift |
| c2ca6283284c8a0728c2eec287a00d087e3a473d4d24bfa802c64d4ad8c55336 | 31782 | Sources/VideoCore/Narratives.swift |
| dcbb916e15aa23f978884fb17c6a9696973b7021adbe5a2e1ace68653634fadb | 6458 | Sources/VideoCore/NativeAgent.swift |
| b0888e7851c11f828fc45640bc325815b3aa30526df1eaede5d84992fedb68a8 | 5324 | Sources/VideoCore/Primitives.swift |
| 6440b894201e6e3188bc62c1a2ec1ed1dc50e6f4b17db287fac7fa9f85f1ae01 | 7546 | Sources/VideoCore/ProviderRules.swift |
| e62621f018997d0e706facbd0a59224f61d70e4d8b56c84feb512c59695c09eb | 5921 | Sources/VideoCore/PublicationRules.swift |
| 458006105dd003a1a5920cd3abede5b5770307979325df6fafbf28f1bd40791a | 13402 | Sources/VideoCore/ScenarioPlanning.swift |
| a81ccc15614d9f5d6f2445cfbf2365a738a7a527e01201bad8c3d70372c4ae97 | 18734 | Sources/VideoCore/Speech.swift |
| 92ac3f8a14e69fab1e2e312d1d85ffe4eec6b8a33c40727cee98bd110441e976 | 27626 | Sources/VideoCore/Storage.swift |
| 0cfd24a48f1ac03f1b9a34f4b80cd4cd57fdf3ca10eee07183be496971ed16a1 | 20722 | Sources/VideoCore/WorkspaceAccess.swift |
| e7dd8743febbec2cfdc92e4656c3dcb1fbd54f8eb2a7b71e9863b371b0fcb6a3 | 11050 | Sources/VideoInstall/VideoInstall.swift |
| ea4dc3e512b818726ea6fd7d350e697ef234e337bafff6e34d8af40720d9cc54 | 14314 | Sources/VideoMedia/BaiduVideoProvider.swift |
| ec396089cb7046846c5bf86bd37f830869418de4445dec089466753f3c1e1329 | 4943 | Sources/VideoMedia/ClassicArtworkMedia.swift |
| 6beff353416b9b4329e20ab3cbd84fcb19d34c8687427feb157b97d00ed63b4d | 10707 | Sources/VideoMedia/ClassicBuiltinAssets.swift |
| 07a9e054545e7aa2aefe99c4ba0ff492f806b36d4e709911ee8712556146b3b1 | 50531 | Sources/VideoMedia/CloudReview.swift |
| 451de62ae66ce51bc390deb9d210ca46de5ca66e5bb52b4572a6e5e792e141a2 | 4904 | Sources/VideoMedia/CoursePreview.swift |
| a3c1ff6981dd81b2a97fee7cff2489fc9edb2381904ee46ebad18e9b6562dc91 | 4662 | Sources/VideoMedia/Diagnostics.swift |
| 2eafa759e4f2e1a94a5ecb866f39784b13363f7a5cfcacb60b125cf5e2fa12bd | 13316 | Sources/VideoMedia/FamiliarBuiltinAssets.swift |
| 78eab44c664d354ecf71559b09af166acca4d9ee2c46786e9449fe9d2c8799cf | 9759 | Sources/VideoMedia/Importer.swift |
| 6a44c3423c3414547f8cd78bc171a95e5789a8c8fab8b7ec0a8efe23f6c21fc3 | 2494 | Sources/VideoMedia/LayerPainter.swift |
| ef20e2360f98d7a69fbcfa44641900a3387ff27d6c8537d0a2834d0ab825371f | 3181 | Sources/VideoMedia/LocalJobExecutor.swift |
| 54dd2ed29bf46ef9c88f636768d51ac358b6996c776841b76643b2c0c046141f | 10771 | Sources/VideoMedia/Painter.swift |
| 54f2c2e61cd64c9b3a668a903d13c5dc81287cb6c3221dc6d62396bf9a864141 | 2044 | Sources/VideoMedia/Preview.swift |
| b559534d57549106cce137f015699a82fda438fe7cb686affd8201b65e07caed | 5695 | Sources/VideoMedia/ProviderClient.swift |
| 4f19002514353501551d4b0930172d62e5d65803e953cd9db6005a9d704cc6e0 | 3782 | Sources/VideoMedia/RemoteJobs.swift |
| 5d6e1eed0aaa7ccf3c784077300e1b9a4ae6332e6cb5e5fb926bbd3437dbedf4 | 26808 | Sources/VideoMedia/RenderModules.swift |
| 402b0323be6202700acdd55831a8ee4cb8c76f68ee52cde8f61edb302e64b106 | 26639 | Sources/VideoMedia/Renderer.swift |
| 9ec229f48547a7e2e0218d913dba2dfd38457f08ae55196979968dbbdee2d4e0 | 11971 | Sources/VideoMedia/SpeechService.swift |
| 924b79fb85d46d8f92c02e9347beabbd3c608929b0c5820d6b0ae597938bb941 | 12830 | Sources/VideoMedia/VisualCache.swift |
| 889d232f2f397a808d7d59eff398ccf0d0c8daa0d8e2ae9e9e08d1e16733b6ba | 4502 | Tests/VideoCLITests/baidu_contract_smoke.swift |
| 5ae0c014535f0d2d9217494b30c1e8fe07336f3ee3ee2551abc52b4d21e9aac7 | 7640 | Tests/VideoCLITests/status_scope_smoke.py |
| 09b3610b368060baad6f10bf2636233ff740e5bcffe06a4efb28e61feb743b84 | 7466 | Tests/VideoCLITests/worker_smoke.py |
| 2bfdd4935e5f4e53fb1934516db3c6d3acc1f19f346d021686a24cd9ed1e9895 | 5693 | Tests/VideoCoreTests/AgentContractTests.swift |
| 3f5d9b81a289338a77f797ece9dd2d0fcb77a916ab24a2304ba67263bcd5fab8 | 5797 | Tests/VideoCoreTests/AgentJobAccessTests.swift |
| f95df20581d739ceaa009113fa6342377cd1d9a8a6d6fe218eec78ec78b3d96d | 14882 | Tests/VideoCoreTests/AgentMutationTests.swift |
| ac2f463ab1d63294907721e001aa208851136547d1bff6a28e9d3efde2e6335a | 2864 | Tests/VideoCoreTests/AgentPreviewTests.swift |
| ae65d7672b8c9ff869c7eb006abeb87324392e41d16ce1a8da76d968f96bfabf | 5472 | Tests/VideoCoreTests/AgentSchemasTests.swift |
| fad7f9ba02a4649d468bc0de5e3a5404015f89fcc2eb9c971542b055459f9bea | 3838 | Tests/VideoCoreTests/AgentWorkerTests.swift |
| bca500afc0b8b9eec905be57ff89cc82406a4196a8df7b0d2a2ae63104ffab69 | 4073 | Tests/VideoCoreTests/AttributionEditingTests.swift |
| 1cbb595ea74fc3d72417dd3b1ccfaa5854f6c13feb6562ca37a25272794e7823 | 11809 | Tests/VideoCoreTests/BaiduVideoRulesTests.swift |
| 0cd1f2557db0264ca5eea0934d454d89792cc56e18127658398da9f52e4fa2a6 | 7465 | Tests/VideoCoreTests/BatchTests.swift |
| 84bf0bbbf07c6dfb4a679f9754c238253b53237018d8519be541453f48c70e40 | 11156 | Tests/VideoCoreTests/BrandDeliveryTests.swift |
| c19dd668a235f222bb68d631b9d6dbe34fa53619e9eb4d1003a0709f78347e4f | 7220 | Tests/VideoCoreTests/ClassicArtworkTests.swift |
| 7c742541b3db16c85878d8444639a450f5ed9bcd6c8d9662bb5f2251e2ba4b31 | 14342 | Tests/VideoCoreTests/CloudProposalTests.swift |
| df48a1effa4d0c09db287ca76a6ce735999ae55203b204ac5b58535c8f1c5870 | 8137 | Tests/VideoCoreTests/CloudReviewTests.swift |
| f18fda57b514d19653ff1ac7ce621f4022be6868fb8b385b2cb5884e698c447a | 17786 | Tests/VideoCoreTests/CohortFinanceTests.swift |
| d6f32510e1092e64a73bf2fba1b1c8d1e1c1d6271bfed3dcbf12eb11665bc347 | 10029 | Tests/VideoCoreTests/CommercialTests.swift |
| 99a8daf70a5e5df163941ed33eebd01813b5ba326302f16414ba768d7ab82799 | 11877 | Tests/VideoCoreTests/DependencyTests.swift |
| 87dd1926450623dfa1b1bf1b817530da5e9085ecb1cb6f720dda9f1d58e829b6 | 40448 | Tests/VideoCoreTests/DomainTests.swift |
| 97e9df31b1135207c3f5751836180994700084aa5223ab553acdc4082ed0700f | 4233 | Tests/VideoCoreTests/EditorPracticeTests.swift |
| 2b62fdf4fe6d33e509688253a6e85d6293e58b5188dedfeeeb21f5a1eb335793 | 3900 | Tests/VideoCoreTests/H264RulesTests.swift |
| 34834eefae890a78408967bdb8cab12fe06ba9708ba127f2a1ed61520f9d3aea | 5221 | Tests/VideoCoreTests/JobOperationTests.swift |
| 1c7965c4e437acd65085788b53c88a94ce7aaa8c604e98daa53c1ddae76ff57f | 2546 | Tests/VideoCoreTests/LayerTests.swift |
| 082a8f3a9302736ee62ddc5eab2609dacac100a83145b24b55d5ed6b97ba1737 | 5928 | Tests/VideoCoreTests/LoudnessTests.swift |
| 64e66e90b81fec6ff7c57525ea6160ec9b9429be34424fccb236e9109cc72a43 | 25072 | Tests/VideoCoreTests/ManagedInstallTests.swift |
| 492ed82d5e1d5d7fb2d20071dda1c8dc22a0fcd33b4baf82fed247110d871474 | 7675 | Tests/VideoCoreTests/ManagedPayloadTests.swift |
| a72a2075460f4a291e4de42deea6ec9b6011825999690406affd4920aad8f66c | 18288 | Tests/VideoCoreTests/ModuleCatalogPublicationTests.swift |
| 7ba1587dc551d09402b66e7ef663cc5b7478a55c52c1d6ef93dfe129020d2d7d | 17745 | Tests/VideoCoreTests/NarrativeTests.swift |
| c499c8ae6aca4855864eb5a5e2c5a55305643953a9c47073fc66b45c9bb41767 | 5752 | Tests/VideoCoreTests/NativeAgentTests.swift |
| 9f9e0b1055a1b9ca2dfb2c1a4f03681c0af63641bee85a33384100e0065f9e6c | 4615 | Tests/VideoCoreTests/ProviderRulesTests.swift |
| 2757b45f6d8989066c3a2a4b52177d047b805052386ebf0eb2f5ad81d46ade46 | 10276 | Tests/VideoCoreTests/PublicationTests.swift |
| 55b0219870d78b1fa59579e3c29894c1d5042936eebe189b2b1cc97491701273 | 8541 | Tests/VideoCoreTests/ScenarioPlanningTests.swift |
| 49d626f0c4257ca85042f970b03c87d9fd4f79111b140164a59beb649e62e48a | 11536 | Tests/VideoCoreTests/SimulationRecordingTests.swift |
| c927d9faea68877b494d6fbac3aa5f76001c427ff5de168208d5e049036ec918 | 7072 | Tests/VideoCoreTests/SpeechTests.swift |
| 849d8301671e8780cb4ccd90d761af1e50fbc12938ae1eb458151ec1c91ba4f1 | 17669 | Tests/VideoCoreTests/WorkspaceAccessTests.swift |
| 0207a9002bb7aef610449bd354ee6c50034a84f81d1a261ea8846a9bb864aada | 1906 | Tests/VideoMediaTests/BaiduVideoProviderTests.swift |
| 88150479390d0501342c4c5789864dec9fc2a74522e0806dabeec9d269e143c7 | 3816 | Tests/VideoMediaTests/CloudReviewLocationTests.swift |
| c7b7bf2aa6091f105373becd60c2dc830ed5167fc85db480b9193d60543e1db4 | 3999 | Tests/VideoMediaTests/CoursePreviewTests.swift |
| c7e58b70577f1181d014ba4a7e15bdd276a97129afc9fb2fb7086da9ad1f86b8 | 11493 | Tests/VideoMediaTests/LoudnessMediaTests.swift |
| 9aea48b1ac047193b29e9b16b856fdbce5db432335c4449fa2ffe26c9dad0bae | 16513 | Tests/VideoMediaTests/MediaTests.swift |
| 8700e3940f97c103e7561d937aecd7ec4cdc73a997ca53ba82e380968be1624d | 5269 | Tests/VideoMediaTests/SpeechMediaTests.swift |
