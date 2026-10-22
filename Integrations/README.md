# 共用Agent接入

同一份`skills/video`承载业务流程，`VideoCore.AgentContract`提供版本化命令字段、权限、幂等语义和失败处理。各宿主只负责安装/发现/工具许可，不复制五套业务代码。

当前提供可校验的本地Skill安装器；没有更改本机全局宿主配置，没有提交任何市场审核，亦未假定Web或移动聊天可调用本机CLI。原生CLI需兼容Apple运行时；其他系统应使用用户配置、已认证且限权的连接器，当前没有把未实现的MCP服务宣布上线。

| 生态 | 本地宿主路由 | 安装目标（用户选定项目内） | 实测边界 |
|---|---|---|---|
| ChatGPT/Codex | Codex shell；聊天界面另需认证连接器 | `.agents/skills/video`或宿主已配置技能目录 | Codex 0.159.2已在临时项目离线发现同源video Skill；模型选择与真实工具调用仍待验收 |
| Claude | Claude Code shell；其他界面按实际运行面 | `.claude/skills/video` | 独立Skill可安装；插件/市场审核未执行 |
| Gemini | Gemini CLI shell | `.gemini/skills/video` | Gemini CLI 0.50.0在仅本进程明确工作区信任时，离线skills list返回video [Enabled]；未开始模型会话或工具调用 |
| Grok | Grok Build shell | `.grok/skills/video` | Grok Build 1.0.67在仅本进程明确工作区信任时，离线inspect返回project来源的video；未开始模型会话或工具调用 |
| DeepSeek | 用户已配置DeepSeek provider的Codex等工具宿主 | 使用该宿主技能目录 | 模型API不是执行环境；不虚构独立DeepSeek Skill市场 |

安装示例：`python3 Integrations/install.py --host codex --destination <项目>/.agents/skills/video`。目标不覆盖已有修改；重复安装同一内容会验证通过，内容不同则保留原文件并报错。`--dry-run`只校验，`--verify`核对现有安装。`--host deepseek-codex`不改provider或读取API Key。

2026-10-22（北京时间）的本地离线发现范围：Codex 0.159.2的app-server `skills/list`返回`video`、启用状态与准确安装路径；Gemini CLI 0.50.0通过本进程`GEMINI_CLI_TRUST_WORKSPACE=true`的`skills list`返回`video [Enabled]`；Grok Build 1.0.67通过本进程`GROK_FOLDER_TRUST=0`的`inspect --json`返回`video`、`userInvocable=true`与项目内准确Skill路径。信任条件只用于各自包含审定Skill的隔离临时项目，不写全局可信目录或模型配置。三个宿主的安装文件均与同一份源Skill逐字节一致；Claude Code 2.1.3只核对帮助与版本，DeepSeek未核验实际provider。没有发起模型请求或执行video工具，不据此声明真实业务调用、市场发布或五生态验收通过。

实际贡献时从经开闭源边界审查的免费公开发行源提交相同Skill及宿主必要元数据；不要把当前私有仓库地址当公开安装链接。Claude/Grok插件manifest与Gemini扩展manifest仅在正式打包阶段按当期规范生成，不能用一个未经验证的空manifest假装已支持市场。

规则与格式核对来源（2026-10-22，北京时间）：

- Claude独立技能/插件结构：[官方插件文档](https://code.claude.com/docs/en/plugins/create)、[manifest规范](https://code.claude.com/docs/en/plugins-reference)。
- Gemini技能目录与会话发现：[官方Agent Skills入门](https://geminicli.com/docs/cli/tutorials/skills-getting-started/)；扩展发布另循[官方扩展规范](https://geminicli.com/docs/extensions/reference/)。
- Grok Build技能/插件目录：[官方Skills、Plugins、Marketplaces说明](https://docs.x.ai/build/features/skills-plugins-marketplaces)。
- DeepSeek配置到既有宿主：[官方Codex集成说明](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)。安装器不执行该文档中的远端配置脚本，不接触凭据。
- Codex当前本机`codex --help`确有`exec/mcp/plugin`入口；[官方定制说明](https://learn.chatgpt.com/docs/customization/overview)确认项目`.agents/skills`路径。本地Skill还复用已安装skill-creator的metadata规范，未把插件入口等同市场审核完成。
