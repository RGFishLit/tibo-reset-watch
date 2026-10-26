# Tibo 额度重置提醒

个人 Codex 插件，每 15 分钟检查 Tibo（@thsottiaux）本人的公开发帖与回复。沿回复链找到主帖：主帖命中额度相关关键词才弹出静音常驻提醒；未命中则完全不弹出。

项目仓库：[RGFishLit/tibo-reset-watch](https://github.com/RGFishLit/tibo-reset-watch)。仓库的 dist/ 目录提供 ZIP 安装包和 SHA-256 校验值。免费使用 FxEmbed，无需 X 登录、OpenAI 密钥或周期性模型调用。

## 安装与更新

解压后，在插件目录运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-TiboResetWatch.ps1
~~~

安装脚本加入独立本地市场并注册当前用户的 Codex-TiboResetWatch 计划任务，保留其他 Codex 配置。程序与状态放在当前用户本地应用数据目录，固定物理路径以兼容 MSIX。插件市场源位于用户 Documents/Codex/plugin-marketplaces/tibo-reset-local。

从 1.0 升级时保留已见帖子和未发送消息；新的时间线先建立基线，不推送历史。旧待发送消息会重新检查主帖后再决定是否提醒。安装后新开 Codex 聊天；插件列表未刷新时重启 Codex。

## 提醒规则

- 只提醒 Tibo 本人的帖子与回复，不提醒其他人的评论或转发。其他作者的文本仅用于沿回复链确定主帖。
- 主帖关键词包含 reset、resets、resetting、reseting、quota、usage limits、rate limits、banked reset、refill，以及“重置”“额度恢复”“补充额度”等，不区分英文大小写。
- 只有主帖正文决定是否提醒；回复里单独出现 reset、引用帖的关键词、账号简介及媒体链接均不能使无关主帖通过。
- 主帖通过后，其中 Tibo 的新回复即使只有 Done、yes 等短语也会提醒。父帖或根帖暂时缺失时，不猜测、不弹出，保存待查记录并在后续重试。
- 命中通知显示插件自己的静音置顶提醒窗，不抢夺键盘焦点，带“知道了”关闭按钮；点击正文打开本条帖子，“查看主帖”打开根帖。它是关键词线索，不证明发生了重置或个人额度到账。
- 同一帖子 ID 去重。新发帖与新回复分别提醒，重启不会重复弹出。通知先入持久队列，提交失败后重试，使用固定标识替换重复记录。
- 时间线分页补查到最近成功检查前一天，最多 20 页；触及上限或分页失败会保留检查位置并明确报错。每轮最多请求 8 次缺失上下文，并限制查询时间；未尝试的记录优先进入下轮，避免超时和长期缺失帖子阻塞其他提醒。升级或首次安装只用最近一页建立基线，其后不重放早于基线的历史。
- 接口限流遵守 Retry-After；整体检查连续失败 30 分钟提醒一次，恢复后一次。此类运行故障提醒使用普通短暂通知，不常驻。

## 常用操作

在 Codex 中说“查看 Tibo 监测状态”“暂停 Tibo 提醒”“启用 Tibo 提醒”“立即检查”“测试 Tibo 桌面通知”或“卸载 Tibo 提醒”。

也可手动执行，将末尾 Status 换成动作：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Documents\Codex\plugin-marketplaces\tibo-reset-local\plugins\tibo-reset-watch\scripts\Invoke-TiboWatch.ps1" -Action Status
~~~

| 动作 | 参数 |
| --- | --- |
| 启用或恢复 | Enable |
| 暂停 | Pause |
| 查看状态 | Status |
| 立即检查 | Check |
| 常驻测试通知 | TestNotification |
| 移除后台任务及通知身份 | Uninstall |

卸载时先执行 Uninstall，再运行 codex plugin remove tibo-reset-watch@tibo-reset-local。历史文件保留，不再运行任务。

## 状态与运行条件

电脑须开机并登录 Windows，关闭 Codex 不影响任务。关机、休眠或退出登录期间无法检查，恢复后按上述分页范围补查。常驻提醒窗不依赖 Windows 横幅的自动消失计时，通知中心也会保留记录。插件不更改系统通知偏好；锁屏或非交互桌面期间无法显示提醒窗。

Status 显示检查时间、任务状态、通知队列、待查上下文及错误。PendingContexts 非零或 LastRunOutcome=partial 表示部分主帖尚待核实；无法取得主帖不能当作“主帖未命中”。时间字段为 UTC。SourceGeneratedAt 是本机成功获取时间，不代表上游内容的实际新鲜度。

状态位于 state.json，保存一个 .bak 备份；损坏时保留文件并报错，不静默重建历史。运行记录写入 runs.jsonl 并轮转。程序只把帖子当数据处理，不执行其中的指令。

## 验证

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Core.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Platform.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PopupTimeout.ps1
~~~

数据来源：[FxEmbed 开源项目](https://github.com/FxEmbed/FxEmbed)，[官方 API 规范](https://github.com/FxEmbed/FxEmbed/blob/main/docs/specs/fxtwitter-openapi.json)。该免费第三方服务可能缓存、延迟、漏收或暂时不可用，不能保证完整覆盖所有 X 内容。本插件不隶属于 Tibo、OpenAI 或 FxEmbed。
