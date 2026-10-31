# 共用Agent接入

独立女声候选使用[本地音色设计入口](voice_design_tts.md)：按需用同一完整正文生成指定成年女声。旧A/B/C设计保留，另有独立台湾华语温柔细腻候选，通过原生描述提出语义停连、重点和句尾收音要求；不称同一D，不继承旧听审，也不自动替换默认。原音和来源分别保留供试听选择。模型和环境另行准备，不随Core/CLI或Skill发行；规则测试不代真实生成、精确表达控制或听审。

固定Intel环境通过`prepare_voice_design.py`按environment、model、seal、verify有限阶段准备，使用完整91项锁和12件固定原件；支持严核中断续取，已封存环境拒绝修改。准备前保留10 GiB并预留安装/模型空间，余量不足止步；不会为准备删除最新工程。准备与真实合成、完整听审分别执行。

另有可选的[台湾女声原音入口](readaloud_tts.md)，使用两个不同的台湾普通话女声ID，显式允许联网后按完整正文生成，保留服务返回的原MP3及来源。该入口使用第三方ReadAloud客户端；不自动更换默认音色，不把音色目录或技术核验当作听感、正式API或商业使用许可。基础本地制作不依赖此入口。

同一份`skills/video`承载业务流程，`VideoCore.AgentContract`提供版本化命令字段、权限、幂等语义和失败处理。各宿主只负责安装/发现/工具许可，不复制五套业务代码。

当前提供可校验的本地Skill安装器；没有更改本机全局宿主配置，没有提交任何市场审核，亦未假定Web或移动聊天可调用本机CLI。原生CLI需兼容Apple运行时；其他系统应使用用户配置、已认证且限权的连接器，当前没有把未实现的MCP服务宣布上线。

| 生态 | 本地宿主路由 | 安装目标（用户选定项目内） | 实测边界 |
|---|---|---|---|
| ChatGPT/Codex | Codex原生工具宿主；聊天界面另需认证连接器 | `.agents/skills/video`或宿主已配置技能目录 | 历史制作/恢复成功只绑定原CLI；较新CLI的两次会话均未实际调用工具。当前提供版本绑定的客户端动态工具桥，离线协议与前置许可规则已核；真实模型调用和完整用户链分别记录，不由历史结果推定 |
| Claude | Claude Code shell；其他界面按实际运行面 | `.claude/skills/video` | 同源Skill安装通过；有界真实会话仅返回init后超时，没有模型响应或video工具调用证据；插件/市场审核未执行 |
| Gemini | Gemini CLI shell | `.gemini/skills/video` | Gemini CLI 0.50.0离线发现video [Enabled]；0.50.0及隔离安装的官方0.65.0真实会话均被现有认证的IneligibleTierError拒绝，未执行video工具 |
| Grok | Grok Build shell | `.grok/skills/video` | Grok Build 1.0.67离线发现video；真实有限会话返回Not signed in，未执行video工具 |
| DeepSeek | 已配置DeepSeek provider的Qwen Code或Codex工具宿主 | Qwen使用`.qwen/skills/video`；Codex使用其实际技能目录 | Qwen Code 0.17.0→官方DeepSeek API的最新有限普通链已实际通过：video Skill与两条有序固定Shell完整许可，普通剪辑、真实音轨、渲染及含源恢复均有独立产物回读。不是高级样片、五生态全验或独立Skill市场上架 |

安装示例：`python3 Integrations/install.py --host codex --destination <项目>/.agents/skills/video`。目标不覆盖已有修改；重复安装同一内容会验证通过，内容不同则保留原文件并报错。`--dry-run`只校验，`--verify`核对现有安装。`--host deepseek-codex`与`--host deepseek-qwen`只标识实际工具宿主，不改provider或读取API Key。Qwen项目安装示例：`python3 Integrations/install.py --host deepseek-qwen --destination <项目>/.qwen/skills/video`。

当前正式Skill为六件：`SKILL.md`、`LICENSE`、`NOTICE`、`agents/openai.yaml`、`references/protocol.md`及`references/narration-writing.md`。新装、更新和六条宿主路由的打包共用同一完整目录校验，缺件、未知文件/目录、链接或超界文件均拒绝。旧五件安装仍可只读回读原指纹、按该指纹升级，并通过显式上一版指纹恢复其原始内容；历史回滚不表示旧包满足当前六件运行契约。

### 有版本绑定的更新与回滚

先用同一安装命令的 `--fingerprint` 回读当前完整技能目录的 SHA-256 指纹，审查新旧 Skill 差异。使用 `--update-from <原指纹>` 才会更新不同内容；可以先同时加 `--dry-run`。原安装若在审查后变化，更新明确拒绝。成功更新保留与原指纹绑定的上一版目录，不覆盖用户修改，也不更改宿主模型、认证或全局设置。技能内容、安装路径、宿主发现与运行权限是独立状态，文件更新不声称当前模型会话已重新加载。

需要回滚时，以 `--rollback-from <上一版指纹> --update-from <当前指纹>` 指明目标及当前状态。工具校验已保留上一版的逐文件摘要，再执行同样的暂存、替换与回读；失败恢复原安装。回滚后的当前版本仍被保留，可再次更新。不存在、篡改、符号链接或来源不符的上一版不会使用。这里只保存已安装的公开 Skill 文件，不保存认证或会话。完整工程的安装迁移与回滚由工具运行时负责，不由 Skill 文件替换承担。

Claude/Grok插件和Gemini扩展须更新完整包，单独替换`skills/video`不会更新原生manifest。用`package.py`生成并审查候选后，显式使用`install.py --host <宿主> --host-package --package-source <候选包根目录> --destination <选定包根目录>`。此模式将原生manifest、同源Skill与根LICENSE/NOTICE作为一个安装单元；`--host-package --fingerprint`回读整包摘要，更新时用`--update-from`绑定该摘要，回滚仍用`--rollback-from`和当前摘要。Codex及两个DeepSeek宿主路由同样支持整包模式。旧的单Skill安装命令保持原用途；两种指纹不可混用。

整包校验拒绝未知文件/目录、链接、附加hooks/MCP和不符的manifest身份或许可。安装后回读失败会恢复原目录；若恢复现场已有其他文件，保留原版并报告实际恢复位置，不覆盖用户文件或删除唯一原版。安装与升级不更改模型、认证或全局宿主设置，不声称已重载当前会话、完整模型调用或市场审核通过。

2026-10-22（北京时间）的离线发现结果保留在`artifacts/checks/host-discovery.md`。本次在受管临时工作树内，分别对Codex、Claude、Gemini和Grok安装同一份5文件Skill并逐字节复核；未改全局可信目录、模型或provider。真实执行结果保留在`artifacts/checks/host-live.md`：Codex复用已有ChatGPT登录，产生真实`command_execution`成功事件，`discover.py`调用原生`video schema`所得40命令摘要与直接调用一致。该验证只证明能力发现，不替代首次成片、安装更新、权限拒绝和完整五生态验收。

Claude的3-turn/0.10美元上限会话与缩减后的1-turn/0.01美元上限探针均未收到模型响应；超时后只结束本任务子进程。Gemini现有认证被官方个人层兼容条件拒绝；在受管cache树禁用npm生命周期脚本安装官方0.65.0后仅复验一次，仍为同一认证错误，未修改全局CLI，当前没有已配置的API凭据替代；Grok当前未登录。此前DeepSeek尚未核验实际provider或模型调用；2026-10-23的实际增量见下文。先尝试的Login受管认证工具未支持这些CLI渠道，本次没有新建登录、索要人工操作或读取凭据；保留实际失败而不把安装成功写成可调用。

公开基础源码与共用Skill位于[video-core](https://github.com/ayqy/video-core)，可从该公开仓库的`Integrations/skills/video`安装；修改通过其[公开Pull Request入口](https://github.com/ayqy/video-core/pulls)贡献。生态官方目录/市场仍各自要求其实际包装和审核，不把本仓库公开等同五家市场上架。

实际贡献时从经开闭源边界审查的免费公开发行源提交相同Skill及宿主必要元数据；不要把当前私有仓库地址当公开安装链接。Claude/Grok插件manifest与Gemini扩展manifest仅在正式打包阶段按当期规范生成，不能用一个未经验证的空manifest假装已支持市场。

`package.py --host <宿主> --version <语义版本> --destination <新目录>` 生成可直接检查的宿主源包，也支持无写入的 `--dry-run`。Codex与DeepSeek宿主保留各自的原生项目技能布局；Claude和Grok包装使用 `.claude-plugin/plugin.json` 与同源 `skills/video`，Gemini使用 `gemini-extension.json` 与同源 `skills/video`。Grok的Claude兼容布局依据[官方兼容说明](https://docs.x.ai/build/features/skills-plugins-marketplaces)，Gemini的技能目录依据[官方扩展格式](https://geminicli.com/docs/extensions/reference/)，Claude依据[官方插件格式](https://code.claude.com/docs/en/plugins-reference)。包内逐文件保留同一Skill，不含模型配置、密钥、自动运行钩子或冒充已部署服务的MCP配置；这不是市场提交，也不自动安装或变更全局宿主。运行前仍需实际本机video、相应宿主认证与工具许可。

规则与格式核对来源（2026-10-22，北京时间）：

- Claude独立技能/插件结构：[官方插件文档](https://code.claude.com/docs/en/plugins/create)、[manifest规范](https://code.claude.com/docs/en/plugins-reference)。
- Gemini技能目录与会话发现：[官方Agent Skills入门](https://geminicli.com/docs/cli/tutorials/skills-getting-started/)；扩展发布另循[官方扩展规范](https://geminicli.com/docs/extensions/reference/)。
- Grok Build技能/插件目录：[官方Skills、Plugins、Marketplaces说明](https://docs.x.ai/build/features/skills-plugins-marketplaces)。
- DeepSeek配置到既有宿主：[官方Codex集成说明](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)。安装器不执行该文档中的远端配置脚本，不接触凭据。
- Codex当前本机`codex --help`确有`exec/mcp/plugin`入口；[官方定制说明](https://learn.chatgpt.com/docs/customization/overview)确认项目`.agents/skills`路径。本地Skill还复用已安装skill-creator的metadata规范，未把插件入口等同市场审核完成。

2026-10-23（北京时间）DeepSeek执行面增量：Qwen Code官方支持用`modelProviders`声明`envKey`名称，由原生宿主读取现有环境变量；无需把凭据写入项目、参数或提示。任务验证仅使用隔离的`QWEN_HOME`与`QWEN_RUNTIME_DIR`及项目Skill，不迁移或覆盖全局设置。源码/工具权限和真实调用事件分别核对，模型返回成功本身不等于命令已运行。官方依据：[模型Provider与环境变量](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/model-providers/)、[项目Agent Skills](https://qwenlm.github.io/qwen-code-docs/en/users/features/skills/)、[DeepSeek官方当前模型与工具调用](https://api-docs.deepseek.com/quick_start/pricing/)。

该有限DeepSeek链使用官方stream-json输入、保持任务stdin至原生result，且仅为两条明确命令设置权限；未采用YOLO或全Shell通配放行。实际执行事件与产物身份已记录，未将工具外层`is_error=false`误当CLI命令成功：schema发现成功，空目录doctor真实返回数据库未初始化，后者不计通过。

### Qwen原生许可交接

`qwen_stream.py`提供有限的原生stream-json消费包装。运行依赖Python 3与PATH中的原生Qwen CLI，消费端直接启动Qwen。Qwen Code 0.17.0按第一条消息选择模式：直接发送用户消息会关闭SDK控制服务；工具需要询问时，消费端便收不到`can_use_tool`。包装先发送`control_request/initialize`，确认回执声明`can_handle_can_use_tool=true`后才发用户任务，并保持stdin至原生result。未确认许可能力时不执行任务。

宿主完成还须核`execution_complete`和`cleanup.passed`；严格固定链另须`policy_complete`。清理复用本项目相同的owned进程组证明，保留TERM/KILL实际结果；leader退出不足以证明后代已结束。拒绝、超时、仍存活或无法证明消失的进程组均不能计成功。模型工具调用数、客户端原生CLI步骤数和写前预检次数分别报告，不能将一条固定生产脚本内的多步CLI说成多次模型工具调用。

调用方使用`create_isolated_settings`在当前工作区内创建新的独立`QWEN_HOME`和运行目录；只传已有环境变量的名称，由原生Qwen消费凭据，不迁移全局设置。兼容的`ExactPolicy`仅核精确Shell成员、工作目录及显式允许的JSON文件，不提供命令顺序或文件身份保证。原生`Bash(pattern)`包含前缀匹配，不能当成完整命令相等；PreToolUse异常时可能放行，也不作为独立强制门禁。

需要固定有限链时使用`PinnedPolicy(directory, commands=(...), pins=(FilePin(绝对路径, SHA256), ...))`，每个命令仅执行一次且须按顺序完成。调用者先固定审查过的解释器、二进制、脚本、Skill及输入原件，再将同一`strict_policy`传给`create_isolated_settings`；`run_qwen`核对实际工具和许可配置后才启动。严格模式不暴露文件写工具，只有显式`allow_skill=True`且六件实际Skill均有pin才允许video Skill，并逐次询问；默认绑定本次工作目录的`.qwen/skills/video`，原生Qwen入口拒绝其它技能路径。完整目录在构造、许可和生命周期复核中持续校验。兼容的`ExactPolicy`保留原精确Shell和显式JSON写能力，不自动许可或暴露Skill；需要Skill时改用完整的严格入口。原生工具开始、许可和完成事件由消费器本身核对，不能仅靠调用方额外callback补审；拒绝、未完成、文件变化或顺序不符不标许可链完成。

原生Shell可选的`timeout`只接受严格整数1—120000毫秒，不接受布尔、浮点、字符串或未知字段，也不延长消费端父进程的硬期限；其余精确命令、目录、顺序和许可生命周期检查保持。

文件pin在许可前和完成时核对，不能消除原生宿主从检查到启动之间的全部文件竞争。`policy_complete`只表示许可与工具生命周期一致，仍须独立核CLI退出码、结构化业务回执、实际版本和产物；模型返回success不等于制作成功。

消费方通过`run_qwen(..., seconds=45)`给出父进程硬预算，最多300秒。到期只终止本次创建的进程组，不依赖原生`max-wall-time`及时结束；Exact默认最多30工具调用，Pinned进一步按明确命令数加可选Skill收紧，两种模式均保留36轮上限。函数只返回内存事件、许可决定和安全状态，不保存原始流。`result/success`不是业务验收：还需逐项核验CLI结构化`ok/error`、实际工程版本、备份恢复和独立回读；超过轮数的会话保持其原退出状态，后续只读重开单独记账。

调用CLI前使用现有`discover.py --binary <video>`取得当前命令目录的实际摘要，避免将重复嵌套的完整schema塞进模型上下文。需要枚举值时以真实schema为准：例如非商业草稿的`purpose="非商业教学"`、`aspect="9:16"`、`kind="图文讲解"`，Swift case名称和近义词不是机器协议值。

### 内容设计后的跨项目素材复用

生产脚本使用 `asset_reuse.py` 解析已经完成的内容设计。构思提示只接收知识、叙事和画面目标，先产出所需素材的名称、外观描述、风格及透明要求；不得把已有素材列表、缓存状态或“优先使用这些图”的指令传给构思模型。解析器是后续阶段，不以九种内置示例限制选题或画面。

`AssetRequest(name, description, style, transparent=True)` 接收任意名称。名称按 Unicode NFKC、空白及大小写规范化，外观/风格/透明要求与PNG协议版本共同组成精确键；姿态、内容或风格改变即为不同需求，不用文本相似分数冒充画面适配或权利判定。`generation_prompt` 只由该需求组成，不受缓存内容或命中状态影响。

调用方选定一个持久本地目录创建 `AssetCache(directory)`，不同工程共享它。`codex_production.resolve_sources(cache, requirements)` 会优先核对旧生成原件；完整命中时 `ready` 为真，`file_pins()` 返回实际原件的 `FilePin`，供原 `LocalProductionPolicy` 的普通 `assets import` 使用。源目录仍须由调用方明确允许，计划模板和CLI仍须固定摘要，不增加模型工具权限。缓存不直接写任何工程数据库或审核状态。

没有生成适配器时，缺项保持 `needs_generation`，不得声称已经生成。外部Agent只为缺项调用真实图像工具，逐件取得原始PNG后，用 `cache.register(request, GeneratedAsset(path, sha256, prompt, provenance, rights))` 登记真实原件。`prompt` 保留实际完整生成提示，`provenance` 保留实际工具/来源记录；导入旧图时保留旧图原提示，不把本次需求伪装成其历史生成提示。登记后再次解析，后续工程会命中同一原件。需要自动生成的消费端可显式传 `generator` 给 `resolve_sources` 或 `cache.ensure`：回调只收到单个缺项的内容提示，须返回绑定同一提示的真实 `GeneratedAsset`；没有默认供应商、自动联网或隐含付费。

`AssetRights(owner, source, claim)` 默认未核实、无商用许可、无上传同意，仅供本地草稿审稿。每次复用检查来源、期限、撤销和指定用途；商用或上传选择必须分别有有效显式依据。缓存来源记录不代替工程中素材的正式授权、付费模块权益或视觉/声音/字幕人审，正常导入也不会自动设置这些批准。

缓存使用本地SQLite内部索引和按SHA-256寻址的原始PNG；不输出库存清单给内容提示，也不产生需向用户交付的JSON材料。每次命中重核完整字节摘要和有界PNG数据，支持独立、非交错8-bit RGBA/LA图像及真实透明像素；未知格式明确拒绝、不偷偷转换。损坏、过期、撤销或用途不符的来源不会命中，原记录与失败保留。登记采用事务与原件原子落盘，冲突不覆盖现有有效原件；`ensure` 对同键持锁覆盖生成回调，保证并发调用只生成一次。外部两段式交接不宣称生成器并发去重，其登记仍校验竞争与冲突。原图已导入工程CAS后，删除派生缓存不影响工程含源恢复；共享复用原件应按用户选定的持久目录管理，不当作临时渲染缓存自动删除。

规则验证：`python3 -m unittest discover -s Integrations -p test_asset_reuse.py`。合成微小PNG仅用于存储和拒绝边界测试，不代表真实素材生成、完整成片或人工审稿通过。

### 游戏场景的缺项素材

`game_asset_production.py`把已构思的游戏元素接入同一素材复用和正常CLI编辑路径。
`GameContentDesign`只接收标题、知识内容及元素名称、外观和透明要求，不接收库存；
随后单独提供`GameStyle`及真实参考PNG的固定摘要，用于匹配所选游戏的风格。
解析结果为`needs_generation`时只返回缺项及该件生成提示，不导入素材或修改工程。
外部图像工具取得真实原始PNG后，按实际完整提示、来源、用途权利及SHA256登记缓存，
再解析即可复用；`AssetCache.provenance(request, sha256=..., use=...)`仅返回仍有效的
当前指定原件来源，重新核对字节、撤销、期限及用途，不返回库存或授予权利。

正常入口为`python3 -B Integrations/game_asset_production.py --help`。
调用方显式提供固定CLI、工作区/工程、缓存、内容设计、风格参考、角色绑定、
现有图片字节pin和具体来源凭据；未加`--apply`只预检，`--apply`才正常导入PNG、
登记来源并基于当前版本执行一次CAS绑定。角色绑定使用实际场景ID和role；地图实体与
知识动作仍由作者明确设计，此阶段不凭素材名称编造实体、规则、动作或知识结论。
同一绑定重跑会检查真实工作区原件并保持版本不变；新来源不能覆盖既有冲突来源。
生成补件和上游下载原件逐源区分，不把混用原件的世界改标签宣称整套Q版。

高级绘制仍须安装相容受信的game7模块，受原图数量、字节、像素、来源及用途校验约束；
源码包不附游戏素材或高级实现。正常绑定撤销对应声音和字幕确认，整片仍待独立审核。
运行规则：`python3 -B -m unittest discover -s Integrations -p test_game_asset_production.py`。

### 共用因果模型与故事动作

`causal_story.py`保留已认可的道路示例配方：通过Core运行因果模型并保留真实轨迹，再把轨迹中的原因和结果绑定到已经存在的`story_action.py`动作。它通过正常CLI版本编辑写入可选的Host字段`storyCausality`，不修改游戏或卡通插件ABI。

旧工程没有该字段仍可读取。原始模型、完整轨迹及讲稿仅属于Host工程，不进入`PluginVisualProps`视觉白名单；正常编辑仍会使受影响确认失效。此阶段不生成角色图片、补写未运行的反事实结果、授予素材用途或自动确认声音、字幕和整片审核。

运行规则：`python3 -B -m unittest discover -s Integrations -p test_causal_story.py`。共享因果作者依赖故事动作模块；按实际修改范围运行相交的完整规则。

共享动作作者支持显式的`CartoonRig.version=2`，最多八个独立角色；旧`version=1`保持四人上限。rig2即使只有一名角色也需要受信cartoon schema6，不能回退给旧schema5服务。本次同时修正因果作者的条件数量预算，因此公共CI完整验证`test_causal_story.py`、`test_story_action.py`和相交Core三类。高级绘制和真实模块发行仍由各自受管阶段验证，不改变free/closed或素材用途。

`knowledge_story.py`提供不绑定道路主题、角色ID、种子或镜头总长的作者入口。输入为完整的四层`StoryPlan`、明确的v3规则表、原生来源场景、人物/物件归属、镜头事件选择器和路径锚点；不接受预制动作IR、伪造轨迹或任意Scene补丁。当前支持既有游戏World或普通插画图层，不替换素材、人物适配器或声音。

先用`record_sources(source_project, plan, invoke)`正常录制明确的完整来源；已有录制只通过dry-run核验，不写人审确认。来源工程须与表现工程分开。每个反事实使用相同种子。显式计划v1只改变一个角色计划；计划v2可另用独立的`action_cost: {actionID, newCost}`声明改变一项现有行动成本（0至100000的整数），同一来源不可混用两种干预。v2必须至少有一项成本反事实，父模型的其余字段须逐一保持；正常`knowledge compare`必须返回真实的已录来源对及实际行为差异。只有请求、标签或未生效规则变化不能充当行为差异。

显式计划v3增加`rule_change: {ruleID, rule}`，其中`rule`必须包含原生规则的完整
`id/label/conditions/effects`。`ruleID`指向父模型中唯一已有规则，替换规则的`id`须相同，
整行须实际改变；规则之外的完整模型、其他规则、顺序、种子和原生来源时间轴均保持。
根来源不含任何干预；每个子来源在`intervention`、`action_cost`和`rule_change`中恰好
声明一种。v3至少包含一项规则替换，也可有后续单角色计划或单成本子来源。
v1/v2原字段和编码保持；它们不能夹带`rule_change`。

例如，在已经设计好父子来源、独立来源场景和展示窗口之后，可明确替换一条付款规则
中的金额。`rule_index`及`effect_index`由作者选定，不能由素材名称或画面推断：

```python
from copy import deepcopy

plan['version'] = 3
replacement = deepcopy(parent['model']['ruleTable']['rules'][rule_index])
assert replacement['effects'][effect_index]['kind'] == 'transfer'
replacement['effects'][effect_index]['amount'] = 4
child['rule_change'] = {'ruleID': replacement['id'], 'rule': replacement}
child['model'] = deepcopy(parent['model'])
child['model']['ruleTable']['rules'][rule_index] = deepcopy(replacement)
```

该例以不含其他干预的子来源为前提；子来源仍须指向同种子的较早父来源。替换
`conditions`也使用同一完整规则合同，不提供脚本或任意模型补丁。作者声明不表示
规则一定会生效：正常Core重新验证完整模型并计算所有来源，资源不足、条件不满足
和规则未应用分别保留其实际结果。v3每个子来源都须与父来源存在实际语义行为差异；
仅改标签、摘要、请求、诊断或未应用匹配会拒绝。Python不解释条件或计算资金流。
正常记录和表现来源使用精确的`ruleChange: {ruleID, rule}`原生字段，完整源模型、
轨迹及此声明一同保留；`ProductionWorkflow`恢复读回也核对该声明，不接受同轨迹下
丢失或替换的来源见证。该扩展仅属于Host的`storyCausality.version=3`，不改变插件ABI。

`compile_presentation(target_project, plan, recorded)`把事件选择器编译为既有动作合同；实际执行、扣费、资金流、状态变化和结果均从唯一实际事件取值，金额不由作者填入。所有细节及其镜头均须有表现，前置细节先完成，事件和余额按源时间推进。动作的出方、收方和主体归属分别校验；同一真实资金流不能重复认领。路径使用显式锚点及中间点，同一主体连续移动端点须连贯；跨来源重复移动不做隐式复位。

已有因果来源的场景在完整动作编译及`ProductionWorkflow.animate_scene`后继续核对
同一约束：原业务动作的ID、类型、对象、时窗、接收人及数量保持，只允许显式修改
几何路径或增加普通视觉动作。`transfer`或含`quantity`的动作须有原因果绑定；取出、
跟手、携带和放下使用普通`move`，不能另造一笔付款或交货。后加普通动作也须从前一
`move/transfer`的实际终点继续，不能绕过端点检查；同一主体的移动绑定不能跨来源，
分支需要独立主体。该检查不识别图片、推断持有人或授予动作效果审核。

`apply_presentation(target_project, plan, recorded, invoke)`读回真实来源工程及冻结版本，再通过正常Core dry-run独立重算所有轨迹，最后执行一次CAS编辑。`invoke(command, body, dry_run)`是调用方已有的正常CLI路由。重复应用须重新查询目标并更新`plan.target.base_revision`；内容无变化时不产生新版本。正常编辑撤销受影响确认，既有历史与原音保留。目标旁白必须逐字等于镜头旁白拼接，不能给新知识套旧配音。

示例[双方同意的资金互换](examples/knowledge_exchange.py)把同一个适配器接到两个参与人、seed19、两轮规则和五镜头；它只是有限资金协议，未模拟商品价值或交货付款。另见[单一成本反事实](examples/knowledge_action_cost.py)：两条来源只把确认成本由一枚改为两枚，由Core正常重算扣费、实际互换和最终余额；仅改变输入摘要或未生效动作成本不足以授权不同结果。录制与编译均复查实际差异，旧v1来源不增加新字段。当前入口明确拒绝旧知识模型v1/v2转换、一次混改多条规则或其他模型字段及解说员重编排；这些不能从通用作者入口推定已实现。普通`KnowledgeStoryboardPlan`原有入口继续保留。规则测试使用有界夹具，不能代替真实Core录制、完整有声成片或人工审片。

[先交货后付款](examples/knowledge_delivery.py)复用上述入口和Core既有的`delivery/payment`绑定。`delivery`选择器声明`actor_id/rule_id/from_state_id/to_state_id/to_actor_id`，只认实际已应用的状态转换；表现为一件自有货物移交给另一真实角色。`payment`选择器声明`rule_id/from_actor_id/to_actor_id`，金额只读真实结算，且须在`requires`中引用同分支、同一对买卖双方的完整交货动作。交货真实事件须严格早于付款事件，动作也须完成；同tick内先画货再画钱不能冒充先交后付。剧情细节明确接收人，货物与钱使用独立主体；重复交货及同笔钱按transfer/payment两种名称重复认领均拒绝。示例只改变卖家的交货计划，对照不交货也不收钱；不计算商品价值，不默认提供图片、声音或媒体审核。

### Codex受控动态工具

`codex_events.py`只核验有界事件流、完整命令生命周期和失败状态。`exec --json`的`command_execution`开始事件发生于进程启动之后，因此事件比对白名单只能用于事后审计，不能当作执行前许可。旧控制器未保留错误正文，原失败不能补写为认证失败；新摘要仅保留错误消息哈希、有限协议码及明确标注的模式推断，不输出原始错误或会话文本。

`codex_broker.py`针对已核本机协议的Codex 0.159.2，在精确业务cwd内用官方`mcp list`只在内存提取实际名称与enabled状态，再为每个安全名称加本次调用专用的`enabled=false`覆盖，并二次读回名称集一致、全部禁用。空的`mcp_servers={}`会递归合并已有配置，不能清空MCP，因此不作为隔离依据。初始化后还须通过官方`mcpServerStatus/list`：名称集须与已禁用配置完全一致，工具、资源、资源模板为空，没有握手信息、工具错误、活动状态或分页。MCP启动/执行通知继续拒绝；未知安全字段、复杂名称和任何不一致都在`thread/start`之前停止，不改全局配置或认证。

库存门通过后，`thread/start`和`turn/start`明确关闭宿主环境及工作区根，禁用原生命令、补丁和网络搜索；只注册客户端动态工具。所有原生执行/文件权限请求均拒绝。原有`Policy`只接受事先审定的`Command`完整argv、规范绝对cwd和文件SHA-256，每次执行前重新核对，不能由模型增加参数或改变目录。此旧契约仍仅支持实际schema发现和明确的CLI `--dry-run`，不会因新增本地制作契约而取得写权限。

普通本地制作可显式选用`codex_production.py`的`LocalProductionPolicy`，再交给同一`run_codex`消费。调用者先审定最多32个有序`LocalStep`、输入模板、源文件和实际CLI的`FilePin`，指定新的本地工作区及恢复目录；模型只能提交下一步名称、固定cwd和完整计划摘要，不能提交命令行、JSON内容、ID或路径。`ResultBinding`仅将先前经过严格校验的原生回执字段绑定到审定模板；每个写步骤先预检再实际执行，逐次核对退出状态及业务封套。

需要显式调用共用Skill时，先在业务项目的原生技能目录安装同源6件包，再以`PinnedSkill(directory, pins)`固定全部六件（包括完整解说写作参考），传给`run_codex(..., skill=...)`。入口拒绝未知文件/目录、链接、缺件和改名；逐事件、发起请求前与调用完成后复核全部文件。MCP隔离门后，独立`skills/list(forceReload=true)`必须回读精确路径、`name=video`、启用及无目录错误，才发送固定原生`skill`输入。目录识别、输入提交、模型工具调用和实际业务结果分别记录，不把发送请求本身叫作已加载或制作成功。Agent文字只留长度与摘要，不保存私密会话正文；该接口没有开放模型读文件、Shell或额外执行权限。

回合完成后，消费端关闭stdin，在原父期限内最多再读取2秒完整尾流并等待退出；合法被动尾通知可保留，畸形尾流或终态后工具请求仍拒绝。原生退出码、双流EOF及是否自然退出单列于`native_exit`，不与`cleanup.passed`混同。服务器继续运行、超时或异常时仍按原owned进程组清理，业务是否完成继续由原完整工具生命周期与回执合同判断，不要求持久服务器必须自然退出。

Codex 0.159.2 的模型目录 `tool_mode` 优先于功能开关。若所选模型声明 `code_mode_only`，仅关闭主机功能仍会拒绝调用。需要 Direct 消费时，调用者可显式传 `run_codex(..., model_catalog=FilePin(目录绝对路径, SHA256))`；只注入官方启动级 `model_catalog_json` 参数，没有任意额外 argv。调用者须先审定同一模型的完整元数据，只改变 `tool_mode` 为 `direct` 并记录原/新摘要；目录放临时工作区，不修改全局配置或认证、不启用 Code Mode 主机。入口核规范普通文件、单模型/Direct 结构和512 KiB上限，启动与调用期反复核pin；`thread/start`显式选择目录中已核的唯一slug，加载目录本身不会选择模型。线程必须回读同一模型，文件变更即停止；不接受调用者或模型另传任意模型字符串。未传该参数时不覆盖原线程模型选择。[官方模式优先顺序](https://github.com/openai/codex/blob/rust-v0.159.2/codex-rs/core/src/tools/mod.rs#L68)、[启动目录配置](https://github.com/openai/codex/blob/rust-v0.159.2/codex-rs/core/config.schema.json#L7411)。

`account/updated` 仅按该版本两个 nullable 枚举字段验证，不保留账户值或授予认证/执行许可。`turn/moderationMetadata` 只接受当前 thread/turn 的完整三字段结构，内部 metadata 仅核有界合法JSON且不保留、不解释；其他未知通知仍拒绝。进程清理保留每次 TERM/KILL 的实际结果；仅当本次已请求 TERM、KILL 被拒且 leader 已实际reap，才对该owned进程组查询一次 signal 0。只有独立 ESRCH 证明组已不存在才能通过，EPERM、存在或未知仍失败，不能凭leader退出猜后代已结束。

本地契约支持普通工程、源文件导入、编辑、原生零元报价与制作、原任务取消/查询，以及本计划生成并核过哈希的含源备份恢复。同步worker仅处理原生任务ID且`query_remote=false`，不启动后台worker；恢复只写新目录。旧工作区、付费报价、供应商或账户操作、删除、人审授权、任意Shell及外部恢复路径均不开放。该接口没有授予高级模块权益，也不会将needs_review改为人工已审核。

普通Scene可携带固定模板中的原始`speechPlan`，与其真实VoiceTake一起保留规范稿和音频摘要。契约仅接受当前DTO的原文/规范稿、词典、UTF-16映射、可选voiceIdentifier、语速、notes及`confirmed=false`；原文须等于narration，词典唯一有界、映射严格整数且有序不重叠、范围按UTF-16核对，未知字段、供应商/凭据或审核true仍拒绝。输入继续完整pin，客户端不重新规范化、不改原音摘要或冒试听；真正的SpeechRules摘要一致性与声音长度仍由正常CLI质量门核验。省去SpeechPlan会改变原音绑定语义，不能靠改写VoiceTake摘要绕过质量门。

构造发现命令时，`FilePin`必须同时绑定实际Python解释器、`discover.py`及实际CLI二进制；预检另绑定输入原件。调用者显式执行`run_codex(prompt, policy, seconds=90)`才会在MCP前置门通过后启动一个有限模型回合；导入和离线规则不启动宿主。`probe_mcp_isolation(policy)`只进行本地配置、初始化和库存检查，永不发送`thread/start`或`turn/start`，即使库存门通过也不将业务`passed`标为真。配置探针和工具子进程使用最小环境，不继承供应商凭据。每个预期动态调用都必须真实完成且CLI回执通过；零工具、未完成、拒绝、超时和清理失败均不能标成功。模型成功也不替代版本、产物及权限的独立用户链回读。

Qwen终态由共用有界JSONL解析器核对完整EOF、重复键、非有限常量和唯一result；首个result之后只兼容合法的惰性usage或system摘要，不能覆盖终态或取得新工具许可。协议拒绝仍执行原owned进程组清理；完整业务回执与实际清理均通过后才报告成功。

许可及超时规则可运行`python3 -m unittest discover -s Integrations -p test_qwen_stream.py`；这些本地协议规则不冒充真实模型、账户或用户链证据。

### Claude原生SDK许可交接

`claude_stream.py`通过本机官方Claude CLI的stdio SDK初始化和`can_use_tool`消费相同的`PinnedPolicy`。仅接受审定的原生`Bash`输入，或显式本地插件的`Skill(video:video)`；允许回执返回原始`updatedInput`，不应用宿主建议的权限变更。工具ID、请求顺序、原生结果与同一session逐项绑定；未知事件、额外字段、后台执行、文件变更及清理无法证明均拒绝。初始化账户元数据与`apiKeySource`不输出，也不作为认证成功。

正常入口`run_claude`不改变HOME或全局配置。启用Skill时，`PinnedPolicy(..., allow_skill=True, skill_directory=plugin/"skills/video")`显式绑定实际插件内完整六件的目录及其全部pin；原生入口核对所载插件与该目录相同，并保留完整manifest和外层许可核验。解释器、官方CLI和本次配置须有文件pin，关闭用户/项目设置、MCP、Hook和会话持久化，只以`--plugin-dir`加载审定目录。带Skill时，目录只接受固定manifest与同源Skill文件，调用期持续检查完整布局及文件pin；不接受其他插件、Hook或MCP文件。初始化成功和本地规则通过不表示后端认证或模型业务已通过，真实调用必须另记证据。[官方stdio许可语义](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py)、[显式本地插件](https://code.claude.com/docs/en/agent-sdk/plugins)。

`test_claude_stream.py`使用本地协议peer核许可拒绝、输入/身份绑定、生命周期及配置变更；不联系模型或账户。

### Mac普通内容原生链的实际边界

2026-10-23（北京时间）Codex 0.159.2消费同源Skill，使用普通ContentContext而无Product创建工程并保存两版90/240帧，真实H.264/AAC成片与四件产物保持needs_review。第一次有限制作会话在控制器硬截止前完成备份，但没有原生退出/turn完成回执，因此不算一次完整成功。第二次针对原备份的有限恢复会话65.994秒正常exit0、turn.completed，五个命令全部exit0；独立读回源/恢复均一工作区、零Product、一项目、两版本、同一job，330帧/11秒1280×720 H.264 30fps/AAC 48kHz，四件字节与哈希相同。工程语义仅恢复事务代数与绝对目录变化，人工审核未代勾。该证据绑定当次服务构建CLI，后续源变更与新版发行仍需验证受影响链。

宿主目录的安装/更新/回滚已核逐文件同源与篡改拒绝；Claude原生plugin validate和Gemini原生技能发现是格式/发现证据，不能替代模型业务执行。Grok仍为Not signed in；DeepSeek的最新有限普通业务在隔离Qwen宿主、原生envKey与固定许可下已复现，边界见下文，不推定其他生态认证可用。

### 最新免费CLI的DeepSeek有限业务

2026-10-24（北京时间），最新公开免费CLI经正常`run_qwen`完成一次Qwen→DeepSeek链，Skill一次和固定Shell两次均有相同工具ID的许可/结果，26项文件pin未变。业务包含20次非dry调用、另列11次预检，以及单独一次schema发现；原/恢复同一工程、版本、job和源WAV，四产物逐项一致，实际H.264/AAC文件可解码。人工审核和字幕确认保持false，任务为needs_review。

此结果只证明该固定宿主和普通两秒回归链，不代表完整知识旁白、高级受信模块、人工看听、五生态全验、商店安装或市场贡献。模型返回success本身不能替代业务回执与独立产物回读；配置迁移及timeout未知字段的旧失败仍保留，不改写为历史成功。
# 彩铅生产：先内容，再素材，再动作

`pencil_production.py` 把已经构思完的内容方案接入正常生产入口。内容方案只含
`version: 1`、`title`、`concept`、`drawings`；每项drawing含`name`、`description`、
`style`、`transparent`。名称没有固定类别表。内容设计的SHA256与缓存无关；不要把
缓存库存、文件列表或命中率加入构思prompt。调用方另外提供`name/scene_id/layer_id`
绑定，指向自己已编排好的、未锁定的图片层。

脚本先解析全部依赖；没有配置生成adapter的缺项返回`needs_generation`及该件独立
提示词，不导入素材或修改工程。调用方用真实生成器补齐原件、完整实际prompt和来源，
通过`AssetCache.register`登记，再以同一内容方案继续。Python调用方也可显式给
`produce_drawings`传入generator；adapter只收到缺项内容prompt，成功原件入库后可供
后续工程复用。缓存索引和CAS原图属于本地素材库，应使用持久、由用户选择的目录。

`--apply`经正常CLI逐件导入/核验源字节，再用正常dry-run与CAS编辑绑定；已有工作区
素材仍走导入器检查真实文件，匹配元数据不能替代完整性证明。重复运行保持相同素材及
版本。缓存不复制工作区授权，不授予商用、上传或人审许可。缺失、撤销、过期或损坏的
原件不能沿用陈旧选择。独立的生成现场采用两阶段交接；只有`ensure`持有同key锁的
adapter调用承诺并发只生成一次，不把外部现场宣称为同一原子事务。

`production_motion.py`随后把作者指定的跃入、弧线投入、弹跳、强调、摇动和揭示编译为
现有可编辑图层关键帧。所有时间使用原场景源帧；逐帧检查安全区，不改旁白、字幕cue、
速度或时长，不自动提前因果落点。受影响声音、字幕和整片确认失效，保留正常人工审核。
默认只规划；`--apply`才经正常编辑器提交。重复相同动作不制造新版本；已有动作替换
须作者显式指定，锁定层保持拒绝。该生产阶段不启动渲染或执行购买。

两个入口均使用调用方提供且SHA256固定的正常`video`二进制、明确工作区/工程和有界
本地输入。它们没有扩大Codex宿主工具的既有命令、路径、权益或信任范围。完整影片仍
通过正常`render estimate/submit`、有限`worker run`、产物检查和含源备份恢复交付。

### 普通制作的持久四件

`production_workflow.preserve_artifacts(artifacts, output, *, revision_id, source_root)`
把正常原生作业的成片、字幕、封面和文字四件复制到调用方指定的持久目录。源路径须在
显式`source_root`内；函数先核全部四件的唯一ID、MIME、同一revision、字节数、SHA256
及目标冲突，再写文件。路径须为无符号链接的规范绝对路径，四件不能同名；已有目标
只有字节完全一致才复用，不覆盖不同内容。返回回执的副本仅更新`path`，原回执、
作业、报价、版本和审核状态保持。`ProductionWorkflow.verify`使用这些持久副本继续
验证；复制成功不等于媒体解码、完整工程恢复或人工审核通过。

普通配方把`--output`作为持久四件、报告与含源备份目录，工作区、渲染中间件及独立恢复
目录放在登记树的`--cache`内。新增的共享保全实现也进入配方输入冻结；执行中原件或
实现改变时保留现场，不续接旧输入。picturebook56、data58与mixed61当前入口均为
六个有声场景、617帧：只移除旧版48帧无声封面，将标题合入首个原有旁白镜头，六完整
原句、原WAV及每镜局部动作时钟不变。字幕仍严格标为
`estimated_sentence_no_word_timestamps`，`voice.listened=false`、`captions.confirmed=false`
及整片未审状态保持；没有可靠词级时戳，不声称词级对齐或新片已听审。

## 分层剧情与固定图片解说员

`story_planning.py`在素材解析之前执行四个有限阶段：人物与动机、剧情框架、动作细节、
镜头与素材需求。`generate_story(brief, generate)`由调用方提供真实作者或模型；每层
带前层摘要并校验引用、因果顺序和动作过程。`StoryPlan.rewrite`修改前层后使后层失效，
完整计划的`drawing_design()`才可交给现有`ContentDesign`和素材生产入口。构思输入不
读取缓存库存；资金、状态与售卖结果继续由正常Host核验真实Core记录。

`story_evaluation.py`保存目的、修改前后的同一问题、实际原件摘要及观察范围。它区分
素材、单帧、片段和整片，拒绝以单帧替代片段比较；问题回到剧情、细节、镜头、素材、
表演或时序层修复。它没有自动批准、自动评分达标或伪造声音试听的出口。

`Scene.cartoonPresenter`显式使用卡通schema7，绑定固定人物的实际图片区域、表情序列
和完整原音能量轨。静音选择闭口图，发声在真实的不同开度图片间切换；这是音量驱动的
嘴形近似，不称音素对齐。旧rig和旧nil工程保持原分支；新图片解说员不能混入旧几何rig。
此公开包仅含Host合同与规则，不含高级绘制模块、生成图片或网络参考原图。

### 显式配置的解说员与 SDK 素材

`presenter_composition.compose(scene, timed, profile, materials, energy, *, viewport=(1280, 720))` 将已经完成的
独立业务舞台与一个调用方指定的图片解说员组合。`profile` 须完整声明 `version: 1`、
`id`、`material_key`、`master_role`、`frames: [{role, sourceRect}]`、原生 `clips/cues`、
`x/y/width/height`、`anchor: bottom` 和 `layout: presenter`。实际人物、透明边缘、
源图裁切及贴底位置均来自调用方的真实素材与显式元数据；没有默认人物或内置帧时钟。
`viewport` 按像素宽、高传入实际渲染画布；制作 `9:16` 时应传 `(720, 1280)`。
可选的 `profile.story_bounds` 是规范坐标 `[left, top, right, bottom]`，原点在左上，
四边须在 `0..1` 内且形成非空区域，并与显式解说员框分离。省略它时，竖版将业务区
安排在解说员框上方并保留间隔；框上方没有可用区域时明确拒绝，调用方须调整框或
显式业务区。省略 `viewport` 和 `story_bounds` 的旧横版调用保持原布局。
`materials[material_key]` 绑定正式导入的 `asset_id/evidence_id/path/sha256` 与完整
`ClassicSource`；若另附冻结的 `frames` 表，必须与配置完全一致。同一原件可在不同
原音与镜头中复用相同区域表，不生成替代图片或增加业务动作。

调用方先以真实完整原音执行 `speech_energy.analyze_take(..., actor_id=profile['id'])`，
再传入其结果。组合时核对当前人物、VoiceTake、原件 SHA256、文本摘要、完整时长和
连续 RMS，解说员 cue 与 RMS 都须覆盖 `0..durationFrames`。RMS 只表示声音响度，
仅用于选择调用方实际提供的闭口/开口图；它不提供音素、词级或语音识别时序。
当前真实 RMS 生产链只接受不超过 **60 秒** 的完整原音；profile 纯几何与元数据合同
所允许的更大源帧上限，不代表分析器或本入口已经支持更长原音。
组合复用 `scene_layout.present(scene, 'presenter', viewport=viewport, target_bounds=...)`，
道路边界按实际画布宽高换算，业务图层、关键帧与动作路径一起投影；这不承诺不同画幅
之间的像素等比重投影。原业务动作的数量、因果、来源、
原音与字幕保持原事实，源对象不被修改；标题保留为元数据，屏幕正文清空。

普通铅笔业务舞台可在 `ProductionDocument` 声明中单独设置
`story_layout: {mode: 'plain', bounds: [left, top, right, bottom]}`；`bounds` 可省略，
使用共享 plain 区域。此配置只适用于 pencil 表现，不能与图片解说员或 game 表现混用。
入口使用声明中与 `aspect` 一致的实际 `viewport`：`16:9` 为 `[1280, 720]`，
`9:16` 为 `[720, 1280]`。声明先验证区域，随后对完整动作几何进行布局；选择此路径时
`scene_layout.py` 也进入 `implementation_inputs` 冻结清单。未声明 `story_layout`
的普通制作入口沿用既有行为。布局只处理几何，不改业务模型、资源、原音或字幕时序，
也不替代字幕净空检查及最终真实画面确认。

`sdk_material_import.py` 与 `native/ImportMotaMaterials.swift` 提供显式 `mota-world`
SDK 原件导入桥接。调用方声明规范的 `ThirdParty/GameAssets` 目录、全部 **15 件**
文件的别名/相对路径，以及每件原件的摘要、来源、所有者、权利声明和许可；桥接沿用
已有工作区与工程的正常授权及 `Repository/importPack`，不新建替代工作区。
Python 侧把桥接回执与正常素材清单、含源备份中的证据逐项交叉核对，保留每件真实
`assetID/evidenceID`。JS 和说明文件只作为完整 UTF-8 被动来源文本导入，不执行
上游 JS，不把源码文本当作图片或音频，也不从回执猜测缺失授权。

普通 CLI 使用 SDK 配置时，须同时显式提供 `--world-importer`、
`--world-importer-sha256`、`--world-importer-receipt` 和 `--runtime`。
`production_runtime.checked_importer` 核对当前 Swift 桥接源码、原正常链接回执中的
实际 product 及 `native_input_sha256`，将桥接可执行文件、链接回执和 Swift 源码
三件输入一起冻结；只给一个可执行文件或匹配的文件摘要不足以进入此路径。

`production_document.py` 的表现选择通过显式 `projection`、`presenter`、`story_layout`、`sdk_import`
及原始材料配置进入统一生产流程；图片解说员与游戏表现分别声明。高级表现须提供
真实已安装 runtime，`production_runtime.checked_runtime` 核对正常发布的 package、
冷启动回执、可执行文件、完整插件目录及来源摘要。Host 仍执行原有签名、信任、
模块权益、素材授权和质量门；这些配置或导入桥接不授予许可，也不替代正常购买或
人工声音、字幕及整片确认。公开包保留 Host/编排源码与规则，不包含闭源绘制模块。
恢复同一来源工程时，允许正常录制产生的后继 revision；原设计、模型、种子、
时间轴和已录 trace 仍须保持原身份，不能把任意新版本当作原来源继续。

相关规则使用明确标注的合成素材字节、时间轴、RMS、回执和发布元数据，不计作真实
Core 导入、真实声音分析、Native 构建、正常安装、视觉效果或人工审片证据。

公开`Free production` CI保留原106条Python规则，并按精确方法清单执行八模块174条
纯规则：知识适配器46、故事动作16、生产流程31、声明入口16、解说员27、SDK导入13、
表现风格13、布局12。CLI回执和轨迹夹具仍属于合成观察。该CI另执行当前48个Core
方法（完整40个`StoryCausalSourcesTests`及8个相关方法），逐项核对实际开始、通过及
总数，拒绝缺项、重复、失败、跳过和零测试；随后在同一SwiftPM缓存构建一个普通
Release `video` CLI。这两类计数分别证明适配合同、原生规则与编译，不代替真实CLI
业务CAS、媒体制作、声画效果、完整工程恢复或人审。公开载荷仍为309件；相对基准
`8cc76071b3de425d6e1670c7c787d4eded235550`，仅12件既有输入在审定修改范围内，
其余297件逐字节保持，无新增公开材料或闭源绘制实现。

## 本地H.264编码实现与缓存

`video doctor`列出本机VideoToolbox实际发现的H.264实现。正常`jobs run`可选
`--video-encoder automatic`或doctor返回的实现ID；省略时为自动模式。这只选择本地
编码后端，最终交付仍为H.264，不修改工程内容、镜头速度或声音。

执行器从真实压缩会话读取编码器身份，并将同一身份用于写入器及镜头缓存键。
切换实现会重新编码对应镜头；相同实现和输入才可复用。可识别的硬件还绑定实际GPU，
身份不完整时仍可普通编码，但不持久复用缓存。显式指定的实现若不支持当前画幅或
配置，会明确拒绝，不静默回退。

`jobs run`的`--dry-run`会验证真实会话并报告请求与解析结果，但不制作文件或修改工程。
实现列表仅代表发现；当前画幅、profile和输出参数是否适用，以真实会话验证为准。
