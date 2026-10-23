# 共用Agent接入

同一份`skills/video`承载业务流程，`VideoCore.AgentContract`提供版本化命令字段、权限、幂等语义和失败处理。各宿主只负责安装/发现/工具许可，不复制五套业务代码。

当前提供可校验的本地Skill安装器；没有更改本机全局宿主配置，没有提交任何市场审核，亦未假定Web或移动聊天可调用本机CLI。原生CLI需兼容Apple运行时；其他系统应使用用户配置、已认证且限权的连接器，当前没有把未实现的MCP服务宣布上线。

| 生态 | 本地宿主路由 | 安装目标（用户选定项目内） | 实测边界 |
|---|---|---|---|
| ChatGPT/Codex | Codex shell；聊天界面另需认证连接器 | `.agents/skills/video`或宿主已配置技能目录 | Codex 0.159.2已发现同源Skill并实际执行普通内容项目链；第一次制作会话到控制器硬截止，第二次独立恢复会话65.994秒正常exit0/turn.completed，五命令成功，备份四产物与版本逐哈希相同；不冒称单次完整成功或五生态通过 |
| Claude | Claude Code shell；其他界面按实际运行面 | `.claude/skills/video` | 同源Skill安装通过；有界真实会话仅返回init后超时，没有模型响应或video工具调用证据；插件/市场审核未执行 |
| Gemini | Gemini CLI shell | `.gemini/skills/video` | Gemini CLI 0.50.0离线发现video [Enabled]；0.50.0及隔离安装的官方0.65.0真实会话均被现有认证的IneligibleTierError拒绝，未执行video工具 |
| Grok | Grok Build shell | `.grok/skills/video` | Grok Build 1.0.67离线发现video；真实有限会话返回Not signed in，未执行video工具 |
| DeepSeek | 已配置DeepSeek provider的Qwen Code或Codex工具宿主 | Qwen使用`.qwen/skills/video`；Codex使用其实际技能目录 | 本轮Qwen Code 0.17.0→官方DeepSeek API已返回`deepseek-flash`真实模型会话、video Skill成功事件和40命令原生schema调用；doctor对尚无数据库的目录返回unavailable，不计工程业务链通过，不虚构DeepSeek网页shell或独立Skill市场 |

安装示例：`python3 Integrations/install.py --host codex --destination <项目>/.agents/skills/video`。目标不覆盖已有修改；重复安装同一内容会验证通过，内容不同则保留原文件并报错。`--dry-run`只校验，`--verify`核对现有安装。`--host deepseek-codex`与`--host deepseek-qwen`只标识实际工具宿主，不改provider或读取API Key。Qwen项目安装示例：`python3 Integrations/install.py --host deepseek-qwen --destination <项目>/.qwen/skills/video`。

### 有版本绑定的更新与回滚

先用同一安装命令的 `--fingerprint` 回读当前完整技能目录的 SHA-256 指纹，审查新旧 Skill 差异。使用 `--update-from <原指纹>` 才会更新不同内容；可以先同时加 `--dry-run`。原安装若在审查后变化，更新明确拒绝。成功更新保留与原指纹绑定的上一版目录，不覆盖用户修改，也不更改宿主模型、认证或全局设置。技能内容、安装路径、宿主发现与运行权限是独立状态，文件更新不声称当前模型会话已重新加载。

需要回滚时，以 `--rollback-from <上一版指纹> --update-from <当前指纹>` 指明目标及当前状态。工具校验已保留上一版的逐文件摘要，再执行同样的暂存、替换与回读；失败恢复原安装。回滚后的当前版本仍被保留，可再次更新。不存在、篡改、符号链接或来源不符的上一版不会使用。这里只保存已安装的公开 Skill 文件，不保存认证或会话。完整工程的安装迁移与回滚由工具运行时负责，不由 Skill 文件替换承担。

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

调用方使用`create_isolated_settings`在当前工作区内创建新的独立`QWEN_HOME`和运行目录；只传已有环境变量的名称，由原生Qwen消费凭据，不迁移全局设置。`ExactPolicy`指定完整Shell命令和可写的JSON输入文件绝对路径；Bash和Edit统一强制询问，匹配后只放行本次调用。追加参数、目录变更、后台运行和其他文件路径均拒绝。原生`Bash(pattern)`包含前缀匹配，不能当成完整命令相等；PreToolUse异常时可能放行，也不作为独立强制门禁。

消费方通过`run_qwen(..., seconds=45)`给出父进程硬预算，最多300秒。到期只终止本次创建的进程组，不依赖原生`max-wall-time`及时结束；同时保留30工具调用、36轮的原生有限上限。函数只返回内存事件、许可决定和安全状态，不保存原始流。`result/success`不是业务验收：还需逐项核验CLI结构化`ok/error`、实际工程版本、备份恢复和独立回读；超过轮数的会话保持其原退出状态，后续只读重开单独记账。

调用CLI前使用现有`discover.py --binary <video>`取得40命令目录的实际摘要，避免将重复嵌套的完整schema塞进模型上下文。需要枚举值时以真实schema为准：例如非商业草稿的`purpose="非商业教学"`、`aspect="9:16"`、`kind="图文讲解"`，Swift case名称和近义词不是机器协议值。

许可及超时规则可运行`python3 -m unittest discover -s Integrations -p test_qwen_stream.py`；这些本地协议规则不冒充真实模型、账户或用户链证据。

### Mac普通内容原生链的实际边界

2026-10-23（北京时间）Codex 0.159.2消费同源Skill，使用普通ContentContext而无Product创建工程并保存两版90/240帧，真实H.264/AAC成片与四件产物保持needs_review。第一次有限制作会话在控制器硬截止前完成备份，但没有原生退出/turn完成回执，因此不算一次完整成功。第二次针对原备份的有限恢复会话65.994秒正常exit0、turn.completed，五个命令全部exit0；独立读回源/恢复均一工作区、零Product、一项目、两版本、同一job，330帧/11秒1280×720 H.264 30fps/AAC 48kHz，四件字节与哈希相同。工程语义仅恢复事务代数与绝对目录变化，人工审核未代勾。该证据绑定当次服务构建CLI，后续源变更与新版发行仍需验证受影响链。

宿主目录的安装/更新/回滚已核逐文件同源与篡改拒绝；Claude原生plugin validate和Gemini原生技能发现是格式/发现证据，不能替代模型业务执行。Grok仍为Not signed in，DeepSeek历史成功依赖其原有安全环境，当前新环境未复现；不提取凭据或虚构账户可用性。
