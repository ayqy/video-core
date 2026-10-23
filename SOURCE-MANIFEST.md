# 免费源码分包清单

VideoFree source export · package_free.py · version 1

生成时间：2026-10-23 16:22:03 北京时间

- 源码与必要元数据：147个文件；1520672字节（不含本清单）。
- 整体内容指纹：`f3002539ad135cfdc3a28e337b0d5beb52d05072c57911acd33d12a4779957ce`。
- 来源：受控原始工程中的逐文件白名单；Package.swift来自Distribution/Free/Package.swift模板，README由发行脚本生成。
- 本包不含.git，不可作为新业务checkout；本清单生成过程不执行构建、设备验收、签名安装或公共上传，各阶段以独立证据为准。
- 来源交付提交（源版本标识）：`2810a0804d4cae37cfe6e1e0d468ed82fa93a6cb`。
- 排除：App、VideoGame、VideoCartoon、Premium、高级实现运行时测试、私有仓库地址、凭据、客户数据、缓存、日志及媒体过程产物。
- 已检查：路径与普通文本文件类型、符号/硬链接拒绝、免费源码闭源import、已知凭据形态和仓库URL。模式检查不能证明任意自由文本绝无敏感信息，仍需发行审查。
- 固定测试例外：PublicationTests的凭据拒绝测试包含一条已按SHA-256精确审核的合成字符串；仅该匹配允许，其余测试与生产源码适用同一检查。

| SHA-256 | 字节数 | 包内路径 / 原工程来源 |
|---|---:|---|
| f5fbcf1aa2be025380eb1016c62b991b5e74007af7c7b6636f32c5ae547d57df | 12159 | Integrations/README.md |
| 2fd53e7e866f87b400ce0fca4d0cc3e23a2996fce3df643c9435547caf1c68e8 | 3266 | Integrations/check_install.py |
| e84bf34e9d75233ae83412a628a278b9bb3df3558522eceb9f32f4f4f59b2387 | 2626 | Integrations/check_package.py |
| abafee4069a7a58ae79d7e180340fce80d9d51bfcfe50a49847c25da16a266d2 | 2149 | Integrations/discover.py |
| 858674ea372ba1e4fabe4918cafa10f165ac1645b1f14707da251bc1902eea96 | 6974 | Integrations/install.py |
| ab412944919610199d5d486789b0b3c4de3b7cb92c4c546fe8aaafe29c435ec1 | 4031 | Integrations/package.py |
| 9f5fd384c9e1f1045d7e64869e9d1acd41184d90939add4b5fa90f0420bdf41a | 10472 | Integrations/qwen_stream.py |
| cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 | 11358 | Integrations/skills/video/LICENSE |
| 1dbab07b005a071618dc75a2e3cd3b68fccfba4c235d4818238a18cdbfcdb052 | 358 | Integrations/skills/video/NOTICE |
| 42b59aa8c603a12a46c3fbda7023eed4f66ffa41116ad0efa68efc740ba1aec0 | 3711 | Integrations/skills/video/SKILL.md |
| 80f697b67421db6f559e8ba99e92a01734018dca974979cee5f169e0f6f871e4 | 308 | Integrations/skills/video/agents/openai.yaml |
| af117d681ee814036da2a294494d020b16173b46ff38c884a68c5ce89da9775e | 3274 | Integrations/skills/video/references/protocol.md |
| bf5529e22ddf0a9c4742b3a274d5398ac31114d587b0abe8a76850d5d45743b0 | 5236 | Integrations/test_qwen_stream.py |
| cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 | 11358 | LICENSE |
| c369f09e50d62d1a1c8eff1500888667ff7a192d0fdc7b32d39c800dfa1e9721 | 1597 | NOTICE |
| 6a9dec4441a53577b8eb06a1031205221050239fd1b4419ec8eec6132280fe46 | 1034 | Package.swift |
| 98f5ccef24767ddaf28b50d5b597f2049b1e179d383903e1fd942893d085a5b9 | 2370 | README.md |
| bbfe59a972a3e8e09e347c04bc22c0eacd2544881af8a4b6068bfc30b38466e8 | 80 | Sources/CSQLite/module.modulemap |
| b052d8e561e942f97b503033ecd2eaa2b35213bdbf374983efe9e68eabdfc024 | 21 | Sources/CSQLite/shim.h |
| 347257a3cd5bcb0e501506a29ab4dc2892a46d2560a111a8d779b124e594ebb9 | 60 | Sources/CZlib/module.modulemap |
| 80324eed37fb3c06611102a5ed598bb3d60aa818eeb6f848068e359677a07ea7 | 18 | Sources/CZlib/shim.h |
| f91009e63ad2cd947bb9a9e20acc909478e7ef5374aadc08c23654f5d8894029 | 15306 | Sources/VideoCLI/FiniteWorker.swift |
| a61228d0198452b50b0421b7f24759da300fbccc3502942f9ae0d30a2cbd23b9 | 27018 | Sources/VideoCLI/VideoCLI.swift |
| 9e32bb073a8fa08b21e6e01dde228bae7fa566d4532c658f1a9c6f13270fc273 | 20398 | Sources/VideoCore/AgentContract.swift |
| bf2f7ad7ef600774a301f579dd95b966a0702127595ca53e0ae7f55b91a2ded3 | 2784 | Sources/VideoCore/AgentJobAccess.swift |
| 8bf2579a1f2466e15406fcad08bcbbc615b82cd2242a0f2db10aef489e805fbc | 20489 | Sources/VideoCore/AgentMutation.swift |
| 0d3a975599e87b03984afc2b7489a027bf1d0ba1cffd4fb52c6b58e0a4473cd8 | 9547 | Sources/VideoCore/AgentPreview.swift |
| 0ce30c2c08562fb4af2f7b203ea97b4f8e89d03581e80dd7ff00761e363146f9 | 11677 | Sources/VideoCore/AgentSchemas.swift |
| 9abfcc0fb2fe524d09107761d1471684807e723a87184e2ad3cd1793b940c55f | 3611 | Sources/VideoCore/AgentWorker.swift |
| a4a917beec4d38f3d9c9aa6f13c83f269987305ab84a195e953a86907fadc3ac | 4979 | Sources/VideoCore/AttributionEditing.swift |
| ed5c2583fc589c335d05adcf137c6c583546c4ceff4996160d080dfc8eb1390e | 2201 | Sources/VideoCore/AudioMixRules.swift |
| e4188a8ecfcc0be2a4be4232e062ca6228523577a0e15a07074710671845bf3a | 18116 | Sources/VideoCore/BaiduVideoRules.swift |
| 189ad6135ff5becbe08363ac71b03ed91e90ca27a03f07d0ec2fe3de97f3470f | 12961 | Sources/VideoCore/BatchRules.swift |
| 686cbcb8b166973abac6f9bdfe7aa2395104b863b0745fe6b2499ef1ebf14995 | 10233 | Sources/VideoCore/ClassicArtwork.swift |
| 0738345f2b0906ba05dfb92159cbbe4eb3c6e3e12ff61bfcabf8b6af2011cbef | 4941 | Sources/VideoCore/ClassicSceneEditing.swift |
| 7d672f82702e70aa5274d644995c9e6617744205f6186bd5bd1853912244af88 | 12294 | Sources/VideoCore/CloudProposalRules.swift |
| 906e95ae96ce972273c71fb4c23860eff12957952772c95d793adaaf83471952 | 7247 | Sources/VideoCore/CloudReviewRules.swift |
| b2cdd155b2ff7507f9ea0ca1b1c85ae41059c903c829d1aecb14f704a34badf0 | 17671 | Sources/VideoCore/CohortFinance.swift |
| aa70a32a41cea941b465ef0b004342f83ed2c362f5085d9c6c4ad55d087fcc4e | 12385 | Sources/VideoCore/Commercial.swift |
| e9b64ac1623ddede8f3e28ec11cf5a7a70ac64358d5592e43fb52a6131fb03ca | 32976 | Sources/VideoCore/CommercialReports.swift |
| 17137a461b816b17ea4da94e59f6ee299b3e7dd53992b985a04e98df0e21e9a5 | 4217 | Sources/VideoCore/ContentAssetMatching.swift |
| 80b4a15fb501e5f2f522ba831d9c0af79ed9b5d7879fc4f62e5258186724a597 | 20194 | Sources/VideoCore/Dependencies.swift |
| c15f7176efc9c4708cd3326908d8171118ec6acf5d44af23c89878cdcf95d6ec | 27085 | Sources/VideoCore/Editing.swift |
| 2812b4b5a76d74c216cdf19af91de902ff2808edc0d2750bbc4a38cf71043c9f | 5735 | Sources/VideoCore/EditorPracticeRules.swift |
| ff72243377a23f6732d56c34e50d291d82e60d1a71ada1878d9ee2e7c5f641b6 | 12517 | Sources/VideoCore/Finance.swift |
| 9e5b2b47e55fdcf7b1495a61e0df94e9b9bb2e915bbb147ebb829585e84d148b | 6424 | Sources/VideoCore/H264Rules.swift |
| 2bfaeccf8e337bf51c8c5e053272308a17f7973c4225570324038aa724308010 | 4242 | Sources/VideoCore/ImportRules.swift |
| aac5404f87e8cf28f21ff655a186b284e651b2612c1cbbfc4a7d35dcb2aed090 | 9523 | Sources/VideoCore/JobOperations.swift |
| b7af7e4c3d6f63da6beb33517189d7c89f920f619ad46037628202087871a8cb | 9966 | Sources/VideoCore/Jobs.swift |
| ab25d8428f1989c0952deb18a33d0ca406f6bb44311dca15bc7dd0cf07d05735 | 6405 | Sources/VideoCore/Layers.swift |
| 6036d8aff46e3704441f07e6a20d01adfa1db9315c3c182f083bd0ccaf47bc41 | 4408 | Sources/VideoCore/LearningExample.swift |
| d6c06ae9b610d6b7f636e9ddc301e53445b8ac14e1ec76ff5d435d94a4aefdbe | 8706 | Sources/VideoCore/Loudness.swift |
| 2cf8f0c5444889865d1b5564fc6fa27fa29f0e3824fad7ffbadad58bcd41588a | 3898 | Sources/VideoCore/MacCommerceLifecycle.swift |
| 6eabe46707e7bb5445aa76111f75c631c7e81d4442a62d70bfd36a9c9753dbb5 | 3402 | Sources/VideoCore/MacCommerceRules.swift |
| 184aa174d927e574b1b049b1f296dab6b97f7c013a86335168324e8b64252f45 | 24411 | Sources/VideoCore/ManagedInstaller.swift |
| c5f7880b28d3447646ea9e8b51e540d171d17455ccf182941e0646fd206c0d98 | 7620 | Sources/VideoCore/ManagedPayload.swift |
| c7c418a77444319e56b71a73ca27a9a9c26fc306ae1e4897ae57705d738fd5f9 | 11686 | Sources/VideoCore/ManagedRelease.swift |
| 45cfdbe345ed26687ef12d0051db89a45b2b729a46dd77a4ecc18816843966cf | 20977 | Sources/VideoCore/Models.swift |
| 7d8d9af9996744ea6ae4b13cf284f56c9f2f1bf217e51469466c949a570eb0af | 21343 | Sources/VideoCore/ModuleCatalogPublication.swift |
| 0b94f0b7ccbe405352bd5e63f76ddc38401c4356b445861cfcad6cffa5242fd3 | 32056 | Sources/VideoCore/Narratives.swift |
| cef4682d7f33ea2603444a91147db6cde10f4a82bc7d18a5d4c6a50e622ae830 | 6511 | Sources/VideoCore/NativeAgent.swift |
| b0888e7851c11f828fc45640bc325815b3aa30526df1eaede5d84992fedb68a8 | 5324 | Sources/VideoCore/Primitives.swift |
| 700d99b9dbcfeff3846bc60ba749298a22cf8ae0df22ba9d906ba6ed809d9e12 | 11500 | Sources/VideoCore/ProductionDelivery.swift |
| d9fe45e9ead4ef96d3b9c156150ae20b66e89ffa72264952cfa1d2d02a398d00 | 8999 | Sources/VideoCore/ProviderRules.swift |
| e62621f018997d0e706facbd0a59224f61d70e4d8b56c84feb512c59695c09eb | 5921 | Sources/VideoCore/PublicationRules.swift |
| 458006105dd003a1a5920cd3abede5b5770307979325df6fafbf28f1bd40791a | 13402 | Sources/VideoCore/ScenarioPlanning.swift |
| 7cb1d10ba903baa1b854bd0b3f67fe97df1736410a0154478c34aad7b4c0605c | 5556 | Sources/VideoCore/ScriptJobRules.swift |
| a81ccc15614d9f5d6f2445cfbf2365a738a7a527e01201bad8c3d70372c4ae97 | 18734 | Sources/VideoCore/Speech.swift |
| 00967cfa2271cce35d16419d6065ef787a2a301ca7b77aa92215b519c86af3b6 | 28268 | Sources/VideoCore/Storage.swift |
| 8e7174e54a4fab84ab55261d3a914fc2775e59adcca7ebb0b64c82d52f58a6f5 | 20135 | Sources/VideoCore/Teaching.swift |
| eedd110e80735e0534e55dfcc0233723ab35e2fd41ce240b77a2b728c08e51c4 | 11179 | Sources/VideoCore/TeachingBatch.swift |
| 7121ad27352879f52316887ec87d9b806024faf64d2352017a459210363375a1 | 26694 | Sources/VideoCore/WorkspaceAccess.swift |
| e7dd8743febbec2cfdc92e4656c3dcb1fbd54f8eb2a7b71e9863b371b0fcb6a3 | 11050 | Sources/VideoInstall/VideoInstall.swift |
| ea4dc3e512b818726ea6fd7d350e697ef234e337bafff6e34d8af40720d9cc54 | 14314 | Sources/VideoMedia/BaiduVideoProvider.swift |
| e38eb6246bcfe8b0d4436c6a88397cf49afcb21928addcf57ce3c71b490f1055 | 20919 | Sources/VideoMedia/BubbleBuiltinAssets.swift |
| ec396089cb7046846c5bf86bd37f830869418de4445dec089466753f3c1e1329 | 4943 | Sources/VideoMedia/ClassicArtworkMedia.swift |
| 6beff353416b9b4329e20ab3cbd84fcb19d34c8687427feb157b97d00ed63b4d | 10707 | Sources/VideoMedia/ClassicBuiltinAssets.swift |
| 1f3e87b9c94b1afa479053fb8526f1a6855ba1fd84bb9f8a828232e6b18d552f | 51217 | Sources/VideoMedia/CloudReview.swift |
| 451de62ae66ce51bc390deb9d210ca46de5ca66e5bb52b4572a6e5e792e141a2 | 4904 | Sources/VideoMedia/CoursePreview.swift |
| a3c1ff6981dd81b2a97fee7cff2489fc9edb2381904ee46ebad18e9b6562dc91 | 4662 | Sources/VideoMedia/Diagnostics.swift |
| 2eafa759e4f2e1a94a5ecb866f39784b13363f7a5cfcacb60b125cf5e2fa12bd | 13316 | Sources/VideoMedia/FamiliarBuiltinAssets.swift |
| 78eab44c664d354ecf71559b09af166acca4d9ee2c46786e9449fe9d2c8799cf | 9759 | Sources/VideoMedia/Importer.swift |
| 6a44c3423c3414547f8cd78bc171a95e5789a8c8fab8b7ec0a8efe23f6c21fc3 | 2494 | Sources/VideoMedia/LayerPainter.swift |
| 6f1fc85edc8eff1ff52c36c729e9fa27be6901777b4b254ef1017416cc370dd6 | 3364 | Sources/VideoMedia/LocalJobExecutor.swift |
| 4b6d8487da56af3c6df2870fee10e5b7dfd993b2056c2e540b1c8c981e3038fb | 10882 | Sources/VideoMedia/Painter.swift |
| 6e107b8c173030a7c7dbdd5f2868792f2ad566f98da0e1b73537b2687c4cd0f0 | 2020 | Sources/VideoMedia/Preview.swift |
| 84caf128a9581acc291f764fd7969a1ed6b29628f35324e32c3e213014a9ce1b | 6704 | Sources/VideoMedia/ProviderClient.swift |
| 9ff1a8e9f3144669944d830a8c63f30b474d1ffcd215e36b6a1956cf2bb9c100 | 4309 | Sources/VideoMedia/RemoteJobs.swift |
| e1cd0087f60707862549b757b664b64f934527b2fe0e160ca4cf50837622de59 | 28681 | Sources/VideoMedia/RenderModules.swift |
| c3adda68d879756384dae3724e1ea2a9438b84823b085ce093c92d596c869b89 | 27836 | Sources/VideoMedia/Renderer.swift |
| 06fdff6e71495ced1c996fc1d589d46010e2f1b798ce03b6e065df78ac8419da | 4392 | Sources/VideoMedia/ScriptJobs.swift |
| 9ec229f48547a7e2e0218d913dba2dfd38457f08ae55196979968dbbdee2d4e0 | 11971 | Sources/VideoMedia/SpeechService.swift |
| 12b4a7a0867959e113e2da2972f23e38b8ba521c20cfea682494e6baeb605734 | 12815 | Sources/VideoMedia/VisualCache.swift |
| 889d232f2f397a808d7d59eff398ccf0d0c8daa0d8e2ae9e9e08d1e16733b6ba | 4502 | Tests/VideoCLITests/baidu_contract_smoke.swift |
| 5d43deeb252e4329088ac744ebb71028287c508b2b8ba89d5e4e83fc476c1ddc | 4040 | Tests/VideoCLITests/content_project_smoke.py |
| 5ae0c014535f0d2d9217494b30c1e8fe07336f3ee3ee2551abc52b4d21e9aac7 | 7640 | Tests/VideoCLITests/status_scope_smoke.py |
| 09b3610b368060baad6f10bf2636233ff740e5bcffe06a4efb28e61feb743b84 | 7466 | Tests/VideoCLITests/worker_smoke.py |
| 2bfdd4935e5f4e53fb1934516db3c6d3acc1f19f346d021686a24cd9ed1e9895 | 5693 | Tests/VideoCoreTests/AgentContractTests.swift |
| 3f5d9b81a289338a77f797ece9dd2d0fcb77a916ab24a2304ba67263bcd5fab8 | 5797 | Tests/VideoCoreTests/AgentJobAccessTests.swift |
| f884bc9e1f7eb717eb0552011aaeda67e056d7fcabf821293efd5855b7568c82 | 14884 | Tests/VideoCoreTests/AgentMutationTests.swift |
| ac2f463ab1d63294907721e001aa208851136547d1bff6a28e9d3efde2e6335a | 2864 | Tests/VideoCoreTests/AgentPreviewTests.swift |
| c2eabc7f064a3f739cd544140ea253e314e2a90d749a1643bf48458ba87a783c | 5604 | Tests/VideoCoreTests/AgentSchemasTests.swift |
| fad7f9ba02a4649d468bc0de5e3a5404015f89fcc2eb9c971542b055459f9bea | 3838 | Tests/VideoCoreTests/AgentWorkerTests.swift |
| bca500afc0b8b9eec905be57ff89cc82406a4196a8df7b0d2a2ae63104ffab69 | 4073 | Tests/VideoCoreTests/AttributionEditingTests.swift |
| 09b5081bc681775fe4709d494b0379f1748f991a4cefe4ec0e446605132dbb05 | 2394 | Tests/VideoCoreTests/AudioMixRulesTests.swift |
| 1cbb595ea74fc3d72417dd3b1ccfaa5854f6c13feb6562ca37a25272794e7823 | 11809 | Tests/VideoCoreTests/BaiduVideoRulesTests.swift |
| 07169ed97856c4c968d69ac395cb8890131fcffb2048c05d9251d290f9083aff | 7467 | Tests/VideoCoreTests/BatchTests.swift |
| 84bf0bbbf07c6dfb4a679f9754c238253b53237018d8519be541453f48c70e40 | 11156 | Tests/VideoCoreTests/BrandDeliveryTests.swift |
| c19dd668a235f222bb68d631b9d6dbe34fa53619e9eb4d1003a0709f78347e4f | 7220 | Tests/VideoCoreTests/ClassicArtworkTests.swift |
| f2740fbb374616f1a6b5e6229b6c6dc32cf874c6556a211184d9bd594adb60e0 | 5654 | Tests/VideoCoreTests/ClassicSceneEditingTests.swift |
| 2e39493e88ecc1c19df5e5e273a6f139be3ff1ffcdf6b19840cbee2248ba6542 | 15901 | Tests/VideoCoreTests/CloudProposalTests.swift |
| d7faff10e36e4c68b85d79a46a4523848071a3be9671c9442331e5c9eb60c6da | 8138 | Tests/VideoCoreTests/CloudReviewTests.swift |
| f18fda57b514d19653ff1ac7ce621f4022be6868fb8b385b2cb5884e698c447a | 17786 | Tests/VideoCoreTests/CohortFinanceTests.swift |
| d6f32510e1092e64a73bf2fba1b1c8d1e1c1d6271bfed3dcbf12eb11665bc347 | 10029 | Tests/VideoCoreTests/CommercialTests.swift |
| 8438c62638b707de943349321ec17617c4299d29a9e4c0d3dfa5981350c413be | 18704 | Tests/VideoCoreTests/ContentProjectTests.swift |
| 08acb39d3dddf1cccba68ee97a005612f46313268da81deef87c5d1b804820b9 | 11123 | Tests/VideoCoreTests/ContentServiceRulesTests.swift |
| 6bb3cfdf279a83e4f972e2bd55c18977d0d63c3f98816505fe65c557ff8b2214 | 9519 | Tests/VideoCoreTests/ContentWorkflowIntegrationTests.swift |
| 89f331f7cc7e16e2bcb1d11a06c4ee9949a4be9a5b930ad5cb231a0eb58231d0 | 11878 | Tests/VideoCoreTests/DependencyTests.swift |
| d951b2d09a8aeafcb974fc15519c5e85a82ebea2269572003b0cf95a9fa92296 | 40455 | Tests/VideoCoreTests/DomainTests.swift |
| 3679c347b506d7431bfd4e0a9f2d08c383e9b87bd613c0d5e959b7635722240e | 13842 | Tests/VideoCoreTests/EditorPracticeTests.swift |
| 2b62fdf4fe6d33e509688253a6e85d6293e58b5188dedfeeeb21f5a1eb335793 | 3900 | Tests/VideoCoreTests/H264RulesTests.swift |
| e18a02e8dba8aef63d20f4a2f43f29aadb9993e3ccf111a62eaf03d7170031c4 | 11873 | Tests/VideoCoreTests/JobOperationTests.swift |
| 1c7965c4e437acd65085788b53c88a94ce7aaa8c604e98daa53c1ddae76ff57f | 2546 | Tests/VideoCoreTests/LayerTests.swift |
| 082a8f3a9302736ee62ddc5eab2609dacac100a83145b24b55d5ed6b97ba1737 | 5928 | Tests/VideoCoreTests/LoudnessTests.swift |
| 8d96dc578eeedbfdf5683f62849a41fc5ba8502ac3d0cd14287c3efcd70a6d3e | 6556 | Tests/VideoCoreTests/MacCommerceRulesTests.swift |
| 64e66e90b81fec6ff7c57525ea6160ec9b9429be34424fccb236e9109cc72a43 | 25072 | Tests/VideoCoreTests/ManagedInstallTests.swift |
| 492ed82d5e1d5d7fb2d20071dda1c8dc22a0fcd33b4baf82fed247110d871474 | 7675 | Tests/VideoCoreTests/ManagedPayloadTests.swift |
| a72a2075460f4a291e4de42deea6ec9b6011825999690406affd4920aad8f66c | 18288 | Tests/VideoCoreTests/ModuleCatalogPublicationTests.swift |
| e3b277d23a6c7a7951f541f010d35b7bce7cd9522eaaa53e726e58edcf8686b5 | 17747 | Tests/VideoCoreTests/NarrativeTests.swift |
| c499c8ae6aca4855864eb5a5e2c5a55305643953a9c47073fc66b45c9bb41767 | 5752 | Tests/VideoCoreTests/NativeAgentTests.swift |
| eb2f556a46d084668b26d9a28077c120906f408733ba9f7ed1c1e84b5e6927bf | 9621 | Tests/VideoCoreTests/ProductionDeliveryTests.swift |
| 9f9e0b1055a1b9ca2dfb2c1a4f03681c0af63641bee85a33384100e0065f9e6c | 4615 | Tests/VideoCoreTests/ProviderRulesTests.swift |
| 2757b45f6d8989066c3a2a4b52177d047b805052386ebf0eb2f5ad81d46ade46 | 10276 | Tests/VideoCoreTests/PublicationTests.swift |
| 55b0219870d78b1fa59579e3c29894c1d5042936eebe189b2b1cc97491701273 | 8541 | Tests/VideoCoreTests/ScenarioPlanningTests.swift |
| 251d6da78644401bb4dafca5bfda69ac65f49abfaf6dd2e93485be29da7e6909 | 11539 | Tests/VideoCoreTests/SimulationRecordingTests.swift |
| c927d9faea68877b494d6fbac3aa5f76001c427ff5de168208d5e049036ec918 | 7072 | Tests/VideoCoreTests/SpeechTests.swift |
| d9c73a0cf74c764280d45920b0e7a4f073143c94c4035b335917aaf2d355d2bf | 15186 | Tests/VideoCoreTests/TeachingTests.swift |
| 7ba0ca151fe677d9a3e081af45a3e9c0cbc725c82549e6b7b8193ef2cfbb8a3e | 24793 | Tests/VideoCoreTests/WorkspaceAccessTests.swift |
| 69a1c1dde465f45b51620943a9dd3c9240537e51fe861897a7528cd6c3c194ed | 5331 | Tests/VideoMediaTests/AudioMixMediaTests.swift |
| 0207a9002bb7aef610449bd354ee6c50034a84f81d1a261ea8846a9bb864aada | 1906 | Tests/VideoMediaTests/BaiduVideoProviderTests.swift |
| 04c765d5be6d04f06db5752c8b0beef1dad8cda87a0be1193be63fa17318f8da | 4089 | Tests/VideoMediaTests/BubbleArtworkMediaTests.swift |
| 88150479390d0501342c4c5789864dec9fc2a74522e0806dabeec9d269e143c7 | 3816 | Tests/VideoMediaTests/CloudReviewLocationTests.swift |
| 117c05fd7ca0c29ea20d0c5f0ea371193f41ec62610bfc8e0e6702f25c9a6088 | 4175 | Tests/VideoMediaTests/ContentProjectMediaTests.swift |
| c7b7bf2aa6091f105373becd60c2dc830ed5167fc85db480b9193d60543e1db4 | 3999 | Tests/VideoMediaTests/CoursePreviewTests.swift |
| c7e58b70577f1181d014ba4a7e15bdd276a97129afc9fb2fb7086da9ad1f86b8 | 11493 | Tests/VideoMediaTests/LoudnessMediaTests.swift |
| a82e3484e58837b5a7e0525619fa438c5aa88be02d3a63cb08de9bce0e05d820 | 16547 | Tests/VideoMediaTests/MediaTests.swift |
| 8700e3940f97c103e7561d937aecd7ec4cdc73a997ca53ba82e380968be1624d | 5269 | Tests/VideoMediaTests/SpeechMediaTests.swift |
