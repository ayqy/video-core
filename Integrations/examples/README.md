# 免费基础制作配方

另有[资金互换作者示例](knowledge_exchange.py)，演示完整四层StoryPlan如何声明非道路知识、两份显式v3规则表及既存场景主体。它配合`knowledge_story.record_sources/compile_presentation/apply_presentation`和调用方正常CLI使用，不自带游戏素材、运行时或旁白，不是可单独执行的完整有声样片。协议只在两人同意时交换既有硬币；商品价值、交货和买卖付款未纳入这个示例。

这个入门配方通过普通video CLI制作一段可编辑的“三个位置各放一颗宝石”操作片，再把完整工程和源素材恢复到新目录。内容先定义目标、准备、逐颗放入和完成；之后才解析固定Kenney CC0图像及实际录音。它不需要知幕Mac App、激活、付费模块、模型账户或供应商密钥。

Ready、Go、You win是三条实际英文操作提示音，字幕只显示真实原词；中文说明由画面文字表达。它们不充当中文知识旁白。本例展示普通图文、数据进度、关键帧及声音剪辑，不冒充高级游戏仿真或完整制作形态质量验收。

需要macOS 14或以上、正常构建的免费video CLI、Python 3和实际ffmpeg/ffprobe。先按免费包README构建video，然后记录该二进制真实SHA256。运行时明确指定新的产物目录和与其分开的专属缓存目录：

```sh
python3 Integrations/examples/free_production.py \
  --binary /绝对路径/video --binary-sha256 <实际SHA256> \
  --output /绝对路径/我的入门作品 --cache /绝对路径/专属缓存
```

所有业务改动仅经过正常CLI。配方建立普通工作区、教学脚本和实际素材，按来源证据绑定图音；正常编辑四镜、接入真实完整提示录音，再报价并只提交一个零元本地作业。生成MP4、封面、SRT和文字后，核索引、完整解码双轨、备份并恢复到新的restored-workspace；比较全部业务字段及每个源/产物字节，只有恢复generation和正常绝对路径根映射可以变化。

产物在选定output中，summary.md给出真实作业、版本、媒体参数、原件来源、四件摘要与含源备份。--binary-sha256可省略，此时固定并报告本次实际二进制摘要；--cache可省略，此时在输出同级建立带目标摘要的专属缓存。下载、完整原录音、格式转换及配方自身的recipe-progress.sqlite在专属cache中；它与产品workspace.sqlite完全分开，不直接修改产品快照。原作者声音发布包只在内存校验，保留精确原Ogg及许可，不生成或交付ZIP。

配方附带`ThirdParty/GameAssets/voiceover/`中的三件固定原Ogg及原作者许可，均已与[Kenney原作者包](https://kenney.nl/media/pages/assets/voiceover-pack/3f7f168698-1677589897/kenney_voiceover-pack.zip)逐件核同。三件录音的固定[公开镜像来源](https://github.com/Mcamento8/open-game-sfx-index/tree/34bbe8b525b5ceff3804915ea745532af11f6055/audio/voiceover-pack/Female)只用于说明原件来历；配方不执行镜像代码、不接受用户替换URL，也不更换声音。许可原文以`AUTHOR-LICENSE.txt`保留，四件原件适用CC0。

|原件|字节数|SHA-256|
|---|---:|---|
|ready.ogg|7313|4a49258fab1f84b00d0060e1535218b22a3b4bba61ef4d989b82e4cab15d69b3|
|go.ogg|8283|1ba6aa2cb3710fd7c6e021622b4ef0428a0107c8f2db2e0dda8de8bcbdb56fd3|
|you_win.ogg|10736|18907e24f8cbd0751831eed8d2dd1c2501ed587da6a7451404edf0876aa56150|
|AUTHOR-LICENSE.txt|486|57d021b53ab176ba287ee0e32abe3a31df86a2449715bf437789cf9779cc1d4e|

已有缓存原件先逐件核对，摘要、大小或普通文件边界不符就保留并拒绝覆盖；缓存缺件时从完整本地固定原件组补齐。若本地整组原件均不存在，才使用既有固定原作者包并核其整体及成员摘要。本地组缺件或损坏时明确失败，不用其它声音替代。原Ogg仍按原方式完整解码为PCM，源身份、时长、字幕及待审状态不变。

若依赖缺失、公开原件改变或正常CLI拒绝，配方明确失败并保留现场。安装缺失依赖或排除故障后，用同一二进制及完全相同output/cache参数重跑：已完成步骤读取原回执；先只读核原提交键，有原job就查询真实原ID，不再报价或提交。中断/失败或运行中任务只通过一个最多300秒、仅原ID的正常有限worker续接，租约仍有效时由产品守卫处理；取消和外部状态不自动恢复。不要删缓存或换output重交。若此前报价已过期且原键确未产生作业，只刷新未使用的本地零元报价，仍绑定同一提交键；不对已接单作业重复提交。

本例所有声音试听、字幕和五项Review确认保持false，输出是needs_review待审稿。完整看听、声音和具体用途审核须由实际使用者完成，来源CC0核对不代替这些确认。配方不授商业或上传许可、不调用App或打开窗口，也不凭本机运行推断机器从未安装App；若用于验证干净环境，调用者应另保留真实环境与安装清单。

[单一成本反事实](knowledge_action_cost.py)在同一有限资金协议中仅改变确认成本，保持人物计划、其他规则和种子，由正常Core比较一枚与两枚成本的实际后果。计划v2显式声明该成本，仍不附运行时、图片或旁白；完整有声成片与人工审核不由该作者示例授予。
