# Tibo 额度重置提醒

个人 Codex 插件，免费使用 Codex Resets 社区接口，每 15 分钟检查 @thsottiaux 的额度重置消息，并发送 Windows 桌面通知。无须 X 登录、OpenAI 密钥或逐次调用模型。

项目仓库：[RGFishLit/tibo-reset-watch](https://github.com/RGFishLit/tibo-reset-watch)。仓库的 `dist/` 目录提供 ZIP 安装包和 SHA-256 校验值。

## 安装

解压后，在 Windows PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-TiboResetWatch.ps1
```

安装脚本将插件加入独立的本地市场，保留现有 Codex 配置，并创建当前用户的 `Codex-TiboResetWatch` 计划任务。程序和状态位于当前用户的本地应用数据目录 `TiboResetWatch`；MSIX 环境会解析为实际物理路径并固定传给任务，不依赖解压目录继续存在。插件市场源在用户的 `Documents\Codex\plugin-marketplaces\tibo-reset-local`。重新安装保留去重历史。

安装后打开 Codex 新聊天，输入“查看 Tibo 额度重置监测状态”或“测试 Tibo 桌面通知”。如果插件列表未刷新，重启 Codex。

## 常用操作

直接在 Codex 中说：启用 Tibo 提醒、暂停 Tibo 提醒、查看监测状态、立即检查、测试桌面通知、卸载 Tibo 提醒。

也可以手动运行，将末尾 `Status` 换成对应动作：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Documents\Codex\plugin-marketplaces\tibo-reset-local\plugins\tibo-reset-watch\scripts\Invoke-TiboWatch.ps1" -Action Status
```

| 动作 | 参数 |
| --- | --- |
| 启用或恢复 | `Enable` |
| 暂停 | `Pause` |
| 查看状态 | `Status` |
| 立即检查 | `Check` |
| 测试通知 | `TestNotification` |
| 移除后台任务 | `Uninstall` |

卸载时先运行 `Uninstall`，再执行 `codex plugin remove tibo-reset-watch@tibo-reset-local`。历史状态保留，避免误删与重装后重复提醒；不再运行后台任务。

## 提醒规则

- 首次成功检查只建立完整基线，不推送历史消息。
- 仅提醒上游收录、作者为 `thsottiaux` 且有合法 X 原帖链接的消息。社区自行观察、其他作者和无效链接会忽略。
- 预告、待确认信号、常规重置及备用重置分别显示；预测到期不会自动变成执行确认。短回复如 “Done” 采用上游分类，不要求包含 reset 关键词。
- 通知包含中文类别、原文摘要、北京时间和原帖链接。摘要保留原文，避免未经验证的自动翻译；适用会员范围以原帖为准。接收消息不等于个人额度到账。
- 按原帖、类型和阶段去重。未能提交给 Windows 的通知保存在待发送队列中，下次重试；固定通知标识避免崩溃重试产生多条通知中心记录。
- 每轮扫描完整分页历史，以发现断线期间或延迟收录的新记录。分页失败不提交部分结果。接口限流时按 `Retry-After` 等待。
- 连续检查失败 30 分钟提醒一次，恢复后提醒一次；无新消息时保持安静。

## 运行条件与排查

电脑必须开机并登录 Windows；关闭 Codex 不影响计划任务。休眠、关机或退出登录时无法监测，恢复后补查上游仍保留的历史。每 15 分钟是本机检查间隔，另有上游收录延迟，不保证覆盖每条 X 帖子。

Windows 通知使用独立的“Tibo 额度重置提醒 / Tibo Reset Watch”身份，并注册一个开始菜单快捷方式。检查 Windows 设置中的系统通知、Tibo 通知和免打扰；本工具不自动修改这些设置。锁屏、免打扰及企业策略可能让消息仅进入通知中心。

`Status` 输出最近成功检查、数据生成时间、错误、待发送数量及下次执行时间，时间字段为 UTC。运行记录在 `runs.jsonl`，保留一个轮转备份。状态在 `state.json`；损坏时会明确报错并保留文件，不会静默重建基线。`.bak` 是上一次保存的状态，可在暂停任务并备份现有文件后用于人工恢复。

数据来源：[Codex Resets](https://codex-resets.com/)，[免费接口文档](https://codex-resets.com/api/docs)。这是独立社区数据服务，不隶属于 OpenAI。接口原文、预告和概率仅作为数据处理，不能向程序下达命令。接口变化或不可用时不会切换到付费服务、登录浏览器或读取个人额度。
