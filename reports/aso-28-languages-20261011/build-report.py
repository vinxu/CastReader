from pathlib import Path
import json,html
p=Path('reports/aso-28-languages-20261011')
c=json.loads(Path('docs/aso/search-localizations.json').read_text())
s=json.loads((p/'online-before.json').read_text())
old_info={i['attributes']['locale']:i['attributes'] for i in s['appInfos'][0]['localizations']}
old_ver={i['attributes']['locale']:i['attributes'] for i in next(v for v in s['versions'] if v['version']['attributes']['platform']=='IOS')['localizations']}
notes='''# CastReader：28 种应用语言的 App Store 搜索本地化审视

核对日期：2026-10-11。范围：iOS / Mac 的默认产品页搜索字段；不调整 App Store 类别、价格、订阅、地区、隐私或法律声明。

## 发现与原因

线上两个平台各有 29 个商店条目。其中新增的 **18 个条目**，关键词全部为 `Kindle,PDF,EPUB,TTS,OCR`，名称、副标题全部复制英语。18 个条目是 ar-SA、cs、da、el、fi、he、hu、id、ko、ms、nl-NL、no、pl、ro、ru、sv、tr、vi。原有印地语关键词也以英文为主。

描述已经有本地语言内容，缺失集中在直接参与搜索匹配的名称、副标题、关键词。原来的 `approved-keywords.json` 只记录 11 个 locale；校验脚本只取前 20 个条目，未收录的语言仅警告，并且选择版本时没有区分 iOS / Mac。这些检查无法保证新语言完成搜索本地化。发布结果明确存在英文占位回填；本轮没有找到当时临时生成文案的脚本，不将推测写成具体代码根因。

## 文案怎么分配

- 名称：CastReader 品牌 + 本地常用的朗读或文字转语音表达。修复 18 个新增语言的英文名称、副标题，并改善印地语的核心搜索表达；保留其余已有本地化名称、副标题。
- 副标题：具体说明 PDF、书籍、网页等可朗读的内容。关键词栏补充文字转语音、文本阅读器、OCR、扫描、文章、学习等相关意图，避免把副标题中的 PDF 再填一遍。
- 关键词：29 组都逐语言重做；保留适当的 TTS / OCR / EPUB 通用缩写。删除统一的 Kindle 品牌占位，不用其他应用名称获取搜索流量。原来大量“字幕／转录”的词让位给主要朗读用途；这是一轮相关性修正，不是搜索量已经证实的排名优化。
- 地区变体：保留简繁中文、西班牙／墨西哥西语。相同语言可使用相同的自然表达，不为了制造差异而换不常见的词。
- 限制：名称和副标题各不超过 30 字符。Apple 的搜索营销页写 100 字符，ASC 字段参考写 100 字节；本轮统一使用不超过 100 UTF-8 字节的较严格限制，所有条目均通过。

Apple 明确把名称、副标题、关键词列为搜索信息；关键词需要具体、相关，避免名称和副标题中的重复词。推广文字不直接影响搜索排名，描述则用于解释价值和网页搜索，不能用“把描述塞满关键词”替代搜索字段本地化。[搜索规则](https://developer.apple.com/app-store/search/) · [字段限制](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) · [应用信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

## 菲律宾语如何处理

28 种应用语言中，27 种有直接对应的 ASC 语言条目；加繁体中文和墨西哥西班牙语，共 29 个现有条目。Apple 没有菲律宾语元数据 locale；菲律宾商店默认语言为英语（英国），最终显示还受设备设置及应用主语言影响。目前应用仅有 en-US 英语条目，两个平台英文描述都明确列出了 Filipino 支持。

当前保留准确的英文承接，记录 `text to speech`、`read aloud`、`Filipino text to speech` 三个市场查询假设。下一轮可评估完整的 en-GB 本地化，但它服务多个国家，并非菲律宾专属栏，不能给整个英语市场填菲律宾语词。菲律宾语广告／外部落地页需另设内容与预算，不能假装在 ASC 已完成 Filipino 本地化。[Apple 支持语言与地区表](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/)

## 证据与验证边界

- 保存了线上改动前的两个平台版本和两份 App Info 全量快照；同一平台的所有 locale 均已分页读取。
- 对 29 个对应的 Apple 本地语言朗读说明页核对术语，来源逐项保存在 `terminology-sources.json`。这些来源证明自然的功能表达，不证明某个词搜索量大。
- 对 29 个商店条目及菲律宾市场共 30 组核心查询做 iTunes Search API 抽样，全部返回成功。只把它当作公开市场用词和后续趋势基线，不当作真实手机端排名、流量或竞价数据。原始查询、日期、市场及结果保存在 `market-search-samples.json`。
- 文案检查覆盖 29 × 6 = 174 个字段，通过。12 个防回归用例通过：缺语言、20 条截断、额外／重复 locale、英文占位、非拉丁文字丢失、100 字节超限、同号 Mac / iOS 混选、名称／副标题漂移等。
- 没有取得 Apple Ads 关键词搜索热度或真实商店词级归因数据。不能承诺每种语言获得某个排名或曝光增长。

## 从曝光到下载的后续评估

1. 保存本次生效日期和三个核心／场景查询，分别查看国家市场，不把 28 种语言混在一个总量里。等待版本审核、上架及搜索索引更新后再开始比较。
2. 用 App Analytics 的 App Store Search 来源，比较生效前后各 14 天的展示、产品页浏览、首次下载及转化；低量市场延长观察期，不凭几次展示下结论。Apple Ads、CPP、推荐和版本发布同时发生时记录这些干扰，不能把所有变化归因到关键词。
3. 各语言页面的前三张截图应依次证明“听与看同步”“PDF／书籍／网页入口”“学习与理解”。本轮没有重新上传截图，也未逐图声称视觉验收；旧截图的数量齐全不能替代语言与画面内容审查。
4. 现有描述的首段多从设备布局／Safari 设置开始。下一轮转化实验可将已本地化的朗读价值和使用场景前置，保留功能限制与订阅说明；一次只改一组变量，才容易判断结果。
5. 已在其他工作中等待审核的三个 CPP 保留原审核状态。默认页关键词与 CPP 关键词分配不是同一字段；本轮没有改写 CPP、推荐申报或订阅推广。

## 本地发布门禁

当前搜索文案源：`docs/aso/search-localizations.json`；关键词兼容镜像：`docs/aso/approved-keywords.json`。校验两者一致，覆盖应用的全部 28 种语言并明确菲律宾语例外。在线检查现在同时比较名称、副标题、关键词，完整读取分页，按平台及精确版本 ID 选择对象，未知 locale 也作为失败。旧的 11 语同步模板不再能静默覆盖新文案。

这些脚本改动保存在当前工作树，后续发布需使用或合入它们；不是已经自动改动所有其他工作树或个人发布技能。没有改动 GlotLID 或应用运行时代码。

## 每个商店条目的文案

完整前后差异见 [localizations.csv](localizations.csv)，含原值、目标值、字节数、市场、查询和术语来源。以下为目标；实际写入状态以本目录的最终回读和完成记录为准。

| 语言 / locale | 名称 | 副标题 | 关键词（UTF-8 字节） |
| --- | --- | --- | --- |
'''
for k,v in c['localizations'].items():
 notes+=f"| {v['label']} / `{k}` | {v['name']} | {v['subtitle']} | {v['keywords']} ({len(v['keywords'].encode())}) |\n"
(p/'README.md').write_text(notes)
cards=[]
for k,v in c['localizations'].items():
 def e(value):return html.escape(str(value),quote=True)
 terms=' · '.join(v['searchQueries'])
 cards.append(f'''<article data-search="{e(v['label']+' '+k+' '+v['name']+' '+v['keywords'])}"><header><b>{e(v['label'])}</b><span>{e(k)} · {e(v['market'].upper())}</span></header><h2 dir="auto">{e(v['name'])}</h2><p class="sub" dir="auto">{e(v['subtitle'])}</p><small>关键词 · {len(v['keywords'].encode())}/100 UTF-8 字节</small><p class="terms" dir="auto">{e(v['keywords'])}</p><details><summary>查看原值及查询依据</summary><p>原名称：{e(old_info[k]['name'])}<br>原副标题：{e(old_info[k]['subtitle'])}<br>原关键词：{e(old_ver[k]['keywords'])}</p><p>查询假设（未经搜索量验证）：{e(terms)}</p><a href="{e(v['terminologySource'])}">本地语言术语参考</a></details></article>''')
html_doc='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CastReader · 28 语言 ASO 审视</title><style>body{font:16px/1.6 system-ui,sans-serif;background:#f5f7f9;color:#182938;margin:0}main{max-width:1200px;margin:auto;padding:36px 24px}h1{font-size:32px;margin:0}p.intro{max-width:900px;color:#50616e}.note{background:#eaf2ff;border-left:4px solid #487fbe;padding:16px;margin:24px 0}input{box-sizing:border-box;width:100%;font:inherit;padding:14px;border:1px solid #aebdca;border-radius:8px;margin:8px 0 26px}section{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:18px}article{background:white;border:1px solid #dce4ea;border-radius:12px;padding:22px;min-width:0}article[hidden]{display:none}header{display:flex;justify-content:space-between;gap:10px}header span,small{color:#657583}h2{font-size:20px;margin:20px 0 2px}.sub{margin:0 0 18px;color:#475d70}.terms{overflow-wrap:anywhere;line-height:1.8}details{font-size:14px;border-top:1px solid #e9edf1;padding-top:12px}summary{cursor:pointer;color:#265c8e}a{color:#265c8e}footer{color:#576b78;margin-top:30px}</style><main><h1>28 种应用语言，29 个商店条目</h1><p class="intro">本次发现新增 18 个条目的名称、副标题和关键词全是英文占位。以下展示逐语言重做的搜索文案，可筛选语言或关键词并展开对比原值。</p><div class="note">文案是搜索相关性修正，不是曝光增长承诺。Mac 文案处于待审核阶段；iOS 需随新版本发布。菲律宾语没有独立 ASC 栏位，当前由英文承接；英文描述已明确列出 Filipino 支持。以最终回读记录为准。</div><label for="filter">筛选语言、locale 或关键词</label><input id="filter" placeholder="例如：日语、ar-SA、voorlezen"><section>'''+''.join(cards)+'''</section><footer>2026-10-11 · 29 组名称、副标题、关键词 · 原始快照、术语来源、30 组市场查询和验证报告保存在同目录。<br><a href="README.md">详细审视与评估方案</a> · <a href="localizations.csv">下载完整前后差异 CSV</a></footer></main><script>document.getElementById('filter').addEventListener('input',function(){const q=this.value.toLocaleLowerCase();document.querySelectorAll('article').forEach(x=>x.hidden=!x.dataset.search.toLocaleLowerCase().includes(q));});</script></html>'''
(p/'review.html').write_text(html_doc)
print('Wrote README.md and review.html')
