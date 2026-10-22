# 命令发现与交接

命令与字段以安装版本的`video schema`为准。输入根节点严格按命令校验，实体仍由对应VideoCore Codable及领域规则校验；当前不声称每个嵌套实体都有严格未知字段拒绝。

`video <命令> --workspace <数据目录> --input <输入文件或-> [--dry-run]`

机器stdout是一份JSON封套，诊断不混入。读取`ok`和`state`，不是只看进程0：`queued`只表示接受，`needs_review`表示实际成片待人工确认；成本`unknown`不能转0。`project_id/revision/job_id`和`artifacts`保存到调用者的任务上下文。

最小读取输入示例（正文示例，不是生产业务数据）：

```json
{"workspace_id":"已存在工作区ID","project_id":"已存在项目ID","request_id":"本次可追溯操作ID"}
```

以上用于`render estimate`。提交需返回的冻结quote、原项目ID和稳定request_id，且报价确认/有效期/预算均通过；不是复制一个示例quote就可提交。修改原文、读法、声音、画幅或素材后重新估算，不复用旧digest。

`jobs status`按原`job_id`查询；`jobs run`只运行原排队本地作业；`jobs query`查询已存在的供应商远端ID。`jobs remote-cancel`不保证远端退款。`jobs reconcile`只记实际账单凭证，不能用预计价格替代实际消耗。

非所有者查询`jobs status`时，每次重新核对原任务绑定的不可变版本与当前授权，只返回任务ID、工程/版本、状态、进度和不含本机路径的产物摘要；不返回报价、账单、实耗、幂等键、远端ID、服务引用或任务消息。所有者仍可读取完整任务。查询旧版本的权限不能读取同工程新版本，撤销/过期立即生效。本地CLI的`principal`来自受信任宿主的本机执行范围，不是远端身份认证。

`doctor --workspace <已有工程目录>`以只读方式打开真实数据库并执行领域校验，成功后`result.repository_schema`和`result.repository_generation`说明实际兼容版本与代数；缺失或损坏工程会失败，不创建新库。未指定工作区的系统诊断不证明任何现有数据兼容。诊断成功不等于购买、签名发行或用户链验收。

`edit apply`的`audioQuality`为可选响度策略编辑，具体字段见`$defs.AudioQualityPolicy`；`null`清除自定策略，数值须通过领域范围校验。响度目标是用户自定值，不冒充平台强制规范，测量不能代替完整听审。

退出码：0成功/已接受（继续检查state）；2输入/未找到；3权限；4预算；5待审核；6版本/幂等冲突；8外部条件或远端不确定。当前ABI/永久失败的更细分码未宣称实现。

写操作是否以request_id安全回放，按该命令schema里的idempotency字段判断。幂等账本需要与业务修改同一事务保存；单独调用fingerprint/replay工具函数不能自动提供断电原子性。不要因CLI接受了request_id便给全部命令许诺“恰好一次”。

需要人机交接时提供：当前项目/版本/任务、实际产物与哈希、待确认的术语/字幕帧或声音问题、授权缺口、未知费用。人完成看听再记录其真实声明，保留待审核状态直到确认完成。
