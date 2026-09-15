# 多语言社区推荐验证 · 2026-09-15

此次通过运营后台更新内容，iOS 产品源码不变，已安装的 `6c7807d` 真机包无需覆盖安装。

新增可见的社区推荐：日语 5、德语 5、法语 6、西语 5、葡语 6；中英文各 6 保留。常规音色仍是发现主体，克隆保留在独立 Curated voices 模块，说明多语言和月度额度。推荐按来源 `referenceLanguage` 过滤，朗读能力继续按 `supportedLanguages` 判断，全部社区声音仍可在完整目录搜索。

运营还配置了韩语 6、俄语 4，但当前 iOS `VoiceCatalogSnapshot.summaries` 只生成 `SupportedTTSLanguage.allCases` 的入口，没有韩语 / 俄语选项。本次不改常规引擎的语言合同。意大利语 / 印地语没有对应社区来源，不填充英文推荐。

17 项 VoiceDiscoveryTests 通过，包括新增 9 来源 × 两区、跨语言输出、缓存淘汰后再次切换、6 项上限前过滤、无来源不展示、常规推荐不被克隆取代。首次新增 fixture 曾把韩语 / 俄语错误建成常规语言，合同验证拒绝；修正为与线上相同的编码（基础 language=en，referenceLanguage=ko/ru）后通过。

线上日语 / 法语 UI 路径均通过：英文界面 → Voice → 对应语言精选 → 播放 / 停止试听，保留头像、名字、分类与额度提示，没有混入英文推荐。测试使用异步 URLSession 获取当前运营成员，避免把每周会变化的 ID 写死在用例中。

证据：`/tmp/castreader-curated-all-languages-20260915/ios-tests-final.xcresult` 与 `live-ui-final.xcresult`。较早一轮截图位于同目录 `attachments/`，已目视确认日语 5 个和法语 6 个成员。

生成前检查排除了 3 个不合格参考音频，最终运营池 49 个声音在国际线路完成参考处理和 prompt 恢复；没有用用户文本合成，也不改变选择 / 朗读 / 解读或额度链路。全部 1,606 个目录 ID 保留。
