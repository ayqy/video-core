# 共用Agent接入

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

需要固定有限链时使用`PinnedPolicy(directory, commands=(...), pins=(FilePin(绝对路径, SHA256), ...))`，每个命令仅执行一次且须按顺序完成。调用者先固定审查过的解释器、二进制、脚本、Skill及输入原件，再将同一`strict_policy`传给`create_isolated_settings`；`run_qwen`核对实际工具和许可配置后才启动。严格模式不暴露文件写工具，只有显式`allow_skill=True`才允许video Skill，并逐次询问。原生工具开始、许可和完成事件由消费器本身核对，不能仅靠调用方额外callback补审；拒绝、未完成、文件变化或顺序不符不标许可链完成。

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

### Codex受控动态工具

`codex_events.py`只核验有界事件流、完整命令生命周期和失败状态。`exec --json`的`command_execution`开始事件发生于进程启动之后，因此事件比对白名单只能用于事后审计，不能当作执行前许可。旧控制器未保留错误正文，原失败不能补写为认证失败；新摘要仅保留错误消息哈希、有限协议码及明确标注的模式推断，不输出原始错误或会话文本。

`codex_broker.py`针对已核本机协议的Codex 0.159.2，在精确业务cwd内用官方`mcp list`只在内存提取实际名称与enabled状态，再为每个安全名称加本次调用专用的`enabled=false`覆盖，并二次读回名称集一致、全部禁用。空的`mcp_servers={}`会递归合并已有配置，不能清空MCP，因此不作为隔离依据。初始化后还须通过官方`mcpServerStatus/list`：名称集须与已禁用配置完全一致，工具、资源、资源模板为空，没有握手信息、工具错误、活动状态或分页。MCP启动/执行通知继续拒绝；未知安全字段、复杂名称和任何不一致都在`thread/start`之前停止，不改全局配置或认证。

库存门通过后，`thread/start`和`turn/start`明确关闭宿主环境及工作区根，禁用原生命令、补丁和网络搜索；只注册客户端动态工具。所有原生执行/文件权限请求均拒绝。原有`Policy`只接受事先审定的`Command`完整argv、规范绝对cwd和文件SHA-256，每次执行前重新核对，不能由模型增加参数或改变目录。此旧契约仍仅支持实际schema发现和明确的CLI `--dry-run`，不会因新增本地制作契约而取得写权限。

普通本地制作可显式选用`codex_production.py`的`LocalProductionPolicy`，再交给同一`run_codex`消费。调用者先审定最多32个有序`LocalStep`、输入模板、源文件和实际CLI的`FilePin`，指定新的本地工作区及恢复目录；模型只能提交下一步名称、固定cwd和完整计划摘要，不能提交命令行、JSON内容、ID或路径。`ResultBinding`仅将先前经过严格校验的原生回执字段绑定到审定模板；每个写步骤先预检再实际执行，逐次核对退出状态及业务封套。

Codex 0.159.2 的模型目录 `tool_mode` 优先于功能开关。若所选模型声明 `code_mode_only`，仅关闭主机功能仍会拒绝调用。需要 Direct 消费时，调用者可显式传 `run_codex(..., model_catalog=FilePin(目录绝对路径, SHA256))`；只注入官方启动级 `model_catalog_json` 参数，没有任意额外 argv。调用者须先审定同一模型的完整元数据，只改变 `tool_mode` 为 `direct` 并记录原/新摘要；目录放临时工作区，不修改全局配置或认证、不启用 Code Mode 主机。入口核规范普通文件、单模型/Direct 结构和512 KiB上限，启动与调用期反复核pin；线程必须回读同一模型，文件变更即停止。未传该参数时行为保持不变。[官方模式优先顺序](https://github.com/openai/codex/blob/rust-v0.159.2/codex-rs/core/src/tools/mod.rs#L68)、[启动目录配置](https://github.com/openai/codex/blob/rust-v0.159.2/codex-rs/core/config.schema.json#L7411)。

`account/updated` 仅按该版本两个 nullable 枚举字段验证，不保留账户值或授予认证/执行许可。`turn/moderationMetadata` 只接受当前 thread/turn 的完整三字段结构，内部 metadata 仅核有界合法JSON且不保留、不解释；其他未知通知仍拒绝。进程清理保留每次 TERM/KILL 的实际结果；仅当本次已请求 TERM、KILL 被拒且 leader 已实际reap，才对该owned进程组查询一次 signal 0。只有独立 ESRCH 证明组已不存在才能通过，EPERM、存在或未知仍失败，不能凭leader退出猜后代已结束。

本地契约支持普通工程、源文件导入、编辑、原生零元报价与制作、原任务取消/查询，以及本计划生成并核过哈希的含源备份恢复。同步worker仅处理原生任务ID且`query_remote=false`，不启动后台worker；恢复只写新目录。旧工作区、付费报价、供应商或账户操作、删除、人审授权、任意Shell及外部恢复路径均不开放。该接口没有授予高级模块权益，也不会将needs_review改为人工已审核。

构造发现命令时，`FilePin`必须同时绑定实际Python解释器、`discover.py`及实际CLI二进制；预检另绑定输入原件。调用者显式执行`run_codex(prompt, policy, seconds=90)`才会在MCP前置门通过后启动一个有限模型回合；导入和离线规则不启动宿主。`probe_mcp_isolation(policy)`只进行本地配置、初始化和库存检查，永不发送`thread/start`或`turn/start`，即使库存门通过也不将业务`passed`标为真。配置探针和工具子进程使用最小环境，不继承供应商凭据。每个预期动态调用都必须真实完成且CLI回执通过；零工具、未完成、拒绝、超时和清理失败均不能标成功。模型成功也不替代版本、产物及权限的独立用户链回读。

Qwen终态由共用有界JSONL解析器核对完整EOF、重复键、非有限常量和唯一result；首个result之后只兼容合法的惰性usage或system摘要，不能覆盖终态或取得新工具许可。协议拒绝仍执行原owned进程组清理；完整业务回执与实际清理均通过后才报告成功。

许可及超时规则可运行`python3 -m unittest discover -s Integrations -p test_qwen_stream.py`；这些本地协议规则不冒充真实模型、账户或用户链证据。

### Claude原生SDK许可交接

`claude_stream.py`通过本机官方Claude CLI的stdio SDK初始化和`can_use_tool`消费相同的`PinnedPolicy`。仅接受审定的原生`Bash`输入，或显式本地插件的`Skill(video:video)`；允许回执返回原始`updatedInput`，不应用宿主建议的权限变更。工具ID、请求顺序、原生结果与同一session逐项绑定；未知事件、额外字段、后台执行、文件变更及清理无法证明均拒绝。初始化账户元数据与`apiKeySource`不输出，也不作为认证成功。

正常入口`run_claude`不改变HOME或全局配置。解释器、官方CLI和本次配置须有文件pin，关闭用户/项目设置、MCP、Hook和会话持久化，只以`--plugin-dir`加载审定目录。带Skill时，目录只接受固定manifest与同源Skill文件，调用期持续检查完整布局及文件pin；不接受其他插件、Hook或MCP文件。初始化成功和本地规则通过不表示后端认证或模型业务已通过，真实调用必须另记证据。[官方stdio许可语义](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py)、[显式本地插件](https://code.claude.com/docs/en/agent-sdk/plugins)。

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
