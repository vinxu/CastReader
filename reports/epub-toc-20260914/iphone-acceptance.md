# iPhone EPUB TOC 验收

设备：iPhone 15 Pro Max，CoreDevice `8D96EFB3-DBC1-52E3-B10D-412C1059D28E`。通过 iPhone Mirroring 实际操作；截图在本任务工具记录中。没有卸载应用、清理账号或原有图书。测试包 1.2.39（60），源码指纹见 `device-source-identity.json`，最后安装回执见 `device-install-final.json`。

入口统一为：首页 + → Quick Import → Upload File → 系统 Files → iCloud Drive / CastReader EPUB TOC 20260914 → 选择原始 EPUB。七个输入的字节数和 SHA-256 见 `iphone-input-manifest.json`。未使用调试直开 fixture 绕过导入入口。

| 时间 | 文件 | 实际操作与观测 | 状态 |
|---|---|---|---|
| 16:52–16:55 | 01-nav3-anchor-lab.epub | 导入成功；NAV 非链接分组、三级层级与原始标签保留；点击 Inline destination 后屏幕从 INLINE TARGET 精确开始；点击播放，日志确认从 paragraph 16 生成音频并见词高亮；播放中选末章后暂停，保存 paragraph 29；关闭会话并从历史重开，恢复末章、完整目录和当前章勾选；点击坏链接留在目录，没有误跳 | 通过 |
| 16:56 | 02-ncx2-anchor-lab.epub | 导入成功；NCX 三级目录，目录标题与正文标题不同仍按锚点准确定位；Nested container 跳到 Chapter Two — Container | 通过 |
| 16:57–16:58 | 03-fallback-lab.epub | 没有 NAV/NCX；显示正文结构生成的来源提示，三个正文标题齐全；第二章跳转准确 | 通过 |
| 16:58–17:00 | 05-ulysses.epub | 完整封面与正文导入；保留原书多层目录；搜索 18 命中第18章，跨数千段落到 [18] 与 Yes because…；重开目录定位当前章并勾选；反向跳到 [14] 与 Deshil Holles Eamus… | 通过 |
| 17:01–17:04 | 06-wanli.epub | 中文原始目录和封面正确；第四章跳到“活着的祖宗”及其正文（paragraph 615）；搜索“历史”命中原书缺失 sec001 的附录，显示位置不可用并禁用，未误跳章首 | 通过 |
| 17:05–17:07 | 07-trading.epub | 原 NCX 的 250 个标签与链接系统性错位；使用书内正确 HTML 目录后保留原层级；1.6 准确跳到“交易风格的确认模式”（paragraph 334）；搜索 24.7，跨到“波动率的稳定方式”（paragraph 8678），两处标题与正文一致 | 通过 |
| 17:08–17:17 | 08-russian-span.epub | FB2 转 EPUB，85 个目录项及三级层级；点击“Воображение и реальность”准确落在同名 span 锚点（paragraph 95）；终止并重新启动 App，从历史重开后仍在该标题和正文开头、没有自动播放；目录完整恢复并勾选当前章 | 通过 |

结果：7/7 输入通过真实 Files 导入与屏幕跳转验收；3 个结构实验文件和4本完整原书。多段流式朗读后选目录的停止、无播放保存、关闭会话重开、应用进程重启后恢复均完成检查。共选择10次目录目标，原文边界与屏幕观测一致。

冷启动使用开发设备工具的 `process launch --terminate-existing`，回执为 `device-cold-relaunch.json`，未通过注入状态模拟恢复。恢复日志：17:16:14.892 `LOCAL reopen cache=hit source=epub paragraphs=3581`，17:16:14.905 `READ resume located source=epub para=95`；对应截图显示同名标题在正文顶部，随后目录显示该条勾选。筛选后的本轮事件见 `iphone-epub-events.log`。

附：局域网 HTTP 下载不可达，未作为成功导入记录。改用 iCloud Files 后完成以上实际导入。目录末章接近全文末尾时滚动受内容底部约束，目标标题与正文仍完整可见；不把“无法滚到屏幕顶部”误判成目标错误。
