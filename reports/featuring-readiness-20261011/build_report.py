from pathlib import Path
import json,html,csv
P=Path(__file__).resolve().parent
b=json.loads((P/'analytics-baseline.json').read_text())
a=json.loads((P/'nomination-revision.json').read_text())
esc=html.escape
source_names={'App Store search':'App Store 搜索','App Store browse':'App Store 浏览','Web referrer':'网页引荐','App referrer':'App 引荐','Unavailable':'来源不可用'}
rows=''.join('<tr><td>'+source_names.get(k,k)+'</td>'+''.join('<td>'+format(v.get(c,0),',')+'</td>' for c in ['impressions','productPageViews','firstDownloads','redownloads'])+'</tr>' for k,v in b['sources'].items())
regions=''.join(f'<tr><td>{k}</td><td>{v}</td></tr>' for k,v in list(b['firstDownloadsByTerritory'].items())[:10])
def link(url,label):return f'<a href="{url}">{label}</a>'
source={
'featuring':('https://developer.apple.com/app-store/getting-featured/','Apple：Getting featured'),
'nomination':('https://developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring/','Apple：提名操作与排期'),
'art':('https://help.apple.com/asc/appspromoart/#/itc9783ca70f','Apple：宣传素材请求流程'),
'cpp':('https://developer.apple.com/app-store/custom-product-pages/','Apple：自定产品页面'),
'ppo':('https://developer.apple.com/app-store/product-page-optimization/','Apple：产品页优化'),
'event':('https://developer.apple.com/app-store/in-app-events/','Apple：App 内活动'),
'access':('https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/','Apple：辅助功能标签'),
'data':('https://developer.apple.com/documentation/analytics-reports/data-completeness-corrections','Apple：报表补录与修正'),
'discovery':('https://developer.apple.com/documentation/analytics-reports/app-store-discovery-and-engagement','Apple：曝光与来源定义'),
'campaign':('https://developer.apple.com/help/app-store-connect-analytics/acquisition/campaign-links','Apple：营销活动链接')}
def cite(k):return link(*source[k])
body=f'''<header><p class="label">CASTREADER · 2026-10-11 · 内部执行记录</p><h1>争取编辑推荐，<br>也让现有流量更有效。</h1><p class="lead">主叙事：同一份原文，先听读跟随，再听讲解看标注。优先准备英文阅读、学习和效率合集材料；中文提供真实源文试用。推荐结果由 Apple 编辑决定。</p><div class="links"><a href="https://press.castreader.com/">公开媒体资料页 ↗</a><a href="https://press.castreader.com/review-guide.html">新增编辑试用指南 ↗</a><a href="analytics-baseline.json">原始汇总 JSON</a><a href="traffic-baseline.csv">渠道基线 CSV</a></div></header>
<section><h2>这次具体补了什么</h2><ul><li>新增一份英文编辑试用指南：准备条件 → 导入 → Read Aloud → AI Explain → 可选 iPad／Safari／拍照路径。</li><li>写了中英文原创虚构短文，各生成 TXT 与 EPUB，组成六文件下载包；没有混入账号或私有资料。</li><li>首页接入试用入口；保留正确官方 Logo、透明录屏外围与黑色手机边框，八张当前截图及原始预览继续可下载。</li><li>精简十月提名为一条可亲自验证的产品故事，以新指南替换重复官网链接。10 月 11 日 13:11（上海）已回读为 <strong>SUBMITTED</strong>，见 <a href="nomination-receipt.json">提交回执</a>；提名 ID 与原窗口保持不变。</li><li>从已有 Analytics 请求下载 60 个日报实例的全部分片，验证大小与 MD5，按日期使用最新修订，建立 28 天 iPhone／iPad 基线。</li></ul><p class="note">网页与文件验收不等于本轮完成了 App 真机回归；本轮未新发二进制。公开演示视频仍明确标注为早期录制、当前商店保留的已批准预览。</p></section>
<section><h2>调研后的策略判断</h2><div class="cards"><article><h3>1. 让编辑快速看懂独特体验</h3><p>用一篇短文把听读、词级跟随、原文上的解读标注连起来，比堆格式和音色列表更容易理解。合集、列表和专题故事都值得争取。</p></article><article><h3>2. 优先已有用户的市场</h3><p>美国 294、英国 87 次首次下载，合计占本窗口 55.6%；中国 113 次。英文优先、中文配套有数据基础。德国与日本素材作为本地化补充，当前数据不足以称为主增长市场。</p></article><article><h3>3. 推荐与搜索分别衡量</h3><p>搜索贡献 62.2% 的首次下载；浏览仅 2.9%。推荐值得争取，同时继续改善搜索承接。浏览来源也包含其他商店浏览场景，不能据此宣称已获编辑推荐。</p></article></div><p>Apple 列举体验、设计、创新、独特性、本地化、辅助功能和产品页质量等考虑因素，没有公开的保证入选公式。以上优先级是结合产品与流量作出的判断。{cite('featuring')}</p></section>
<section><h2>真实流量基线</h2><p>2026-09-10 至 2026-10-07，共 28 天；iPhone + iPad。采用事件次数 Counts；不把分组后的 Unique Counts 相加当成独立人数。</p><div class="table"><table><thead><tr><th>来源</th><th>曝光次数</th><th>产品页浏览次数</th><th>首次下载</th><th>重新下载</th></tr></thead><tbody>{rows}<tr class="total"><td>总计</td><td>43,161</td><td>1,507</td><td>685</td><td>72</td></tr></tbody></table></div><p class="note">搜索来源包括 Search Ads，不能直接称为自然搜索；未在本轮开启广告。曝光不包含独立产品页浏览。下载也可能直接发生在搜索结果，因此没有用“下载 ÷ 产品页浏览”伪造官方转化率。未出现的渠道事件计为本报表窗口未报告；数据可能含隐私噪声。{cite('discovery')}</p><details><summary>主要市场与数据处理方法</summary><table><thead><tr><th>地区代码</th><th>首次下载</th></tr></thead><tbody>{regions}</tbody></table><p>最新 processingDate 为 10 月 10 日；选取截至 10 月 7 日的共同窗口，留出三天完整性延迟。对于同一 Date，后一个 processingDate 的整组记录覆盖前一个，不跨修订累加。两个报表均覆盖 28 个日期。Mac 与其他设备已排除。{cite('data')}</p></details></section>
<section><h2>提名：一次有实质内容的补充</h2><p>已有十月提名最初于 8 月 2 日提交，原窗口为 9 月 29 日 00:00 UTC 至 10 月 31 日 23:59:59 UTC。保持这一记录，补充可公开访问的试用材料。Apple 概览建议至少两周，操作帮助建议至少三周；后续按较保守的三周安排，并尽可能提前更多时间。10 月 11 日补充不保证仍进入本月编辑排期。{cite('nomination')}</p><p>本轮提交的重点如下，完整 payload 与回读记录保存在同目录：</p><details><summary>英文提名描述（{len(a['description'])}/1000 字符）</summary><pre>{esc(a['description'])}</pre></details><details><summary>补充备注（{len(a['notes'])}/500 字符）</summary><pre>{esc(a['notes'])}</pre></details><p>不重复创建相同故事的提名；只有实质新功能、新内容或新的编辑故事时，再准备下一窗口。</p></section>
<section><h2>三个自定产品页：审核后怎样接流量</h2><p>Books／Documents／Study 当前均为 WAITING_FOR_REVIEW。以下是激活准备，尚未把待审核页面接入正式推广。每次上线前需再次读取状态，并在目标商店与设备打开验证。</p><div class="table"><table><thead><tr><th>页面</th><th>适合的入口与内容</th><th>审核后动作</th></tr></thead><tbody><tr><td>Books</td><td>自己的 EPUB、长篇阅读、听读跟随</td><td>相应内容页的下载按钮改用 Books 的 ppid 链接，保留默认页回退。</td></tr><tr><td>Documents</td><td>PDF、文档、照片文字转朗读</td><td>文件／OCR 场景入口使用 Documents，首屏截图对应输入方式。</td></tr><tr><td>Study</td><td>难段落解读、原文标注、学习</td><td>解读相关入口使用 Study，明确播放讲解而非原文。</td></tr></tbody></table></div><p>页面还可以关联匹配搜索意图的关键词；先核对当前本地化关键词与唯一组合约束，再分配，不把三个页面全部绑定同一组宽泛词。当前支持最多 70 个页面，但本轮先做好三种真实意图。{cite('cpp')}</p><p>推广链接使用 ASC 生成的真实 provider token，再加稳定的 ct 渠道标记；不能编造 pt。已准备 <a href="cpp-activation.csv">入口映射和待启用链接</a>。Campaign 数据有报告门槛和归因窗口，未显示不等于零。{cite('campaign')}</p></section>
<section><h2>怎样用更少流量做有效测试</h2><p>先看 ASC 的预计样本需求，再只测试一个假设：默认页保持“听读跟随优先”，处理组将“AI Explain 原文标注”放到更早截图。标题、价格与入口同期保持稳定。当前每日约 54 次产品页浏览（所有地区合计），不适合立即切成多个国家 × 多个版本的小组。</p><p>PPO 支持最多三个处理组，单次最长 90 天；结果达到 Apple 提示的可信度后再采用。视频并不必然提升转化，需实测；本轮没有开启缺乏样本估算的实验。{cite('ppo')}</p><p>后续看同地区、同来源、同设备的官方下载转化率，以及 7 日留存。推荐出现时记录实际版位、商店和日期，再比较前后 7／28 天；不能把单日 Browse 波动当成已入选或因果证明。</p></section>
<section><h2>活动与辅助功能：真正补强产品后再申报</h2><div class="table"><table><thead><tr><th>机会</th><th>可执行准备</th><th>上线／申报条件</th></tr></thead><tbody><tr><td>7 天听读挑战</td><td>已有后续活动构想；活动名与短文案可复用阅读主线。目标应是活动期间真实完成的挑战，而非泛泛推广 App。</td><td>应用内有活动入口、实际播放计时、按不同日期计数、完成反馈及有效深链；真机验证新装与已装路径。功能完成并过审后，才创建／提交对应活动与提名关联。</td></tr><tr><td>辅助功能标签</td><td>已建 <a href="readiness-checklist.csv">验收矩阵</a>，覆盖首次启动、导入、朗读、解读、付费／恢复、设置。</td><td>逐平台验证 VoiceOver、放大文字、对比度等真实支持；TTS 或阅读器字号设置本身不足以勾选整个 App 的支持标签。</td></tr><tr><td>当前版本演示视频</td><td>采用本次原创样例拍摄“导入 → 跟随 → 解读”更容易说明故事，也避免借用第三方书籍。</td><td>从已核对的发布基线与当前版本真机录制，检查加载、错误提示及隐私信息；不能把旧录屏改日期当新素材。</td></tr></tbody></table></div><p>常规重复任务、仅打折和泛泛 App 宣传并不适合包装成 App 内活动；活动应对应真实的限时体验。{cite('event')} 辅助功能标签应基于常见任务的实际可完成性。{cite('access')}</p></section>
<section><h2>收到 Apple 素材请求时的响应包</h2><p>官方流程是：Apple 邮件／Promotional Artwork 请求给出主题、模板和截止时间；按请求制作并上传。当前没有“收到邀请”的证据，不需要预造所有尺寸。{cite('art')}</p><ol><li>从请求中确认平台、主题、截止日期和模板；链接已整理到 <a href="artwork-response.txt">响应清单</a>。</li><li>从本媒体包取正确 1024px 图标、当前截图和原始预览；按具体请求补充当前真机无包装录屏／源图。</li><li>在 Apple 指定 PSD 模板中保留原尺寸，素材逐个嵌入为可缩放 Smart Object，不引用本地外链文件。</li><li>检查品牌、可用功能、素材权利、模板裁切和命名；在 ASC 指定入口交付。收到素材请求仍不等于最终入选。</li></ol></section>
<section><h2>下一步的顺序与验收点</h2><ol><li><strong>本轮完成：</strong>公开指南与样例上线、下载和布局验收、现有十月提名实质补充、流量基线与资料归档。</li><li><strong>等待外部状态：</strong>CPP 审核结果、Apple 是否发出推荐／素材请求。仍是 pending 的项目没有标成完成。</li><li><strong>下一次产品迭代：</strong>真机三分钟路径与辅助功能矩阵先验收，再录当前演示。真实的新体验若计划 11 月上旬曝光，需尽早满足至少三周的提名准备期；当前没有承诺未实现功能的发布日期。</li><li><strong>获得明确请求：</strong>按 Apple 的具体截止日交付宣传美术；获推荐后使用 ASC 提供的分享物料并记录实际入口流量。</li></ol><p>创始人经历与团队故事没有可信的现成资料，本轮采用可核验的产品故事，没有虚构个人背景或用户疗效。</p></section><footer>内部报告，不公开业务数据。研究来源为 Apple 官方页面；状态与数据为 2026-10-11 当次读取。代码、来源说明、验证记录与提交回执保存在同一目录。</footer>'''
css='''*{box-sizing:border-box}body{margin:0;background:#f8f6ef;color:#22332e;font:16px/1.8 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",sans-serif}main{max-width:1100px;margin:auto;padding:48px 28px}h1{font-size:48px;line-height:1.22;letter-spacing:-2px}h2{font-size:28px;line-height:1.4;margin-top:0}h3{font-size:19px}.label{font-size:12px;letter-spacing:2px;color:#87502c}.lead{font-size:20px;max-width:870px}.links{display:flex;gap:18px;flex-wrap:wrap}a{color:#8c3d16;text-underline-offset:3px}section{padding:36px 0;border-bottom:1px solid #d8ded6}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}.cards article{padding:22px;background:white;border-radius:16px}.table{overflow:auto}table{width:100%;border-collapse:collapse;font-size:14px}th,td{padding:12px 14px;border-bottom:1px solid #d8ded6;text-align:left;vertical-align:top}th,.total{background:#e6ece1;font-weight:600}.note,footer{font-size:13px;color:#5c675f}details{padding:16px;margin:18px 0;border:1px solid #d8ded6;border-radius:10px}summary{cursor:pointer;font-weight:600}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:14px/1.7 -apple-system,sans-serif}li{margin:10px 0}footer{padding:32px 0}@media(max-width:700px){main{padding:24px 20px}h1{font-size:35px}.cards{grid-template-columns:1fr}h2{font-size:24px}}'''
(P/'research-and-action.html').write_text(f'<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CastReader 编辑推荐与 App Store 流量准备</title><style>{css}</style></head><body><main>{body}</main></body></html>')
with (P/'cpp-activation.csv').open('w',newline='') as f:
 w=csv.writer(f);w.writerow(['page','state_at_read','activation_gate','entry_intent','url','suggested_ct_after_real_pt_generated'])
 for name,id,intent in [('Books','152bd084-4c07-4c00-8b12-3df660f46f92','EPUB/long-form own-content listening'),('Documents','b8450bbc-355d-46af-925a-bac8d55389a3','PDF/document/photo reading'),('Study','d01cfc28-eae9-4d62-be8e-38b471634096','AI Explain/source annotations')]:
  w.writerow([name,'WAITING_FOR_REVIEW','ASC approved + target-store device open verified',intent,'https://apps.apple.com/app/id6757636395?ppid='+id,'web_'+name.lower()+'_202610'])
with (P/'readiness-checklist.csv').open('w',newline='') as f:
 w=csv.writer(f);w.writerow(['area','task','pass_evidence','current_status'])
 for area,task,evidence,status in [
 ('Brand','Official app icon matches source','PNG SHA matches app asset; no faux logo','VERIFIED'),
 ('Public web','Guide + samples + media reachable','HTTP checks; desktop/mobile; ZIP CRC; EPUB XML','VERIFICATION_RECORDS_IN_FOLDER'),
 ('App core','Current public build paste/import and Read Aloud','Real-device screen recording; spoken-word alignment; pause/resume; errors recover','NOT_RETESTED_THIS_TURN'),
 ('App core','AI Explain on same original sample','Generated speech and marks, mode switch cancellation, no stale audio','NOT_RETESTED_THIS_TURN'),
 ('Accessibility','VoiceOver across onboarding/import/playback/paywall/settings','Labels, focus order, actions, all common tasks complete on iPhone and iPad','UNVERIFIED_DO_NOT_DECLARE'),
 ('Accessibility','Large text across common tasks','Large-text settings, unclipped controls and checkout, not just reader font','UNVERIFIED_DO_NOT_DECLARE'),
 ('Accessibility','Contrast / reduced motion','Device settings and all primary controls tested, record actual supported features','UNVERIFIED_DO_NOT_DECLARE'),
 ('Event','Real time-limited seven-day challenge','Campaign-specific state, unique-day completion from actual playback, deep link new/existing install','PRODUCT_IMPLEMENTATION_REQUIRED'),
 ('Artwork','Apple-requested final PSD/video','Request ID/theme/template/deadline; exact template and embedded Smart Objects','AWAIT_SPECIFIC_REQUEST'),
 ('Editorial story','Founder background','User-supplied accurate personal story and authorized photos','NOT_PROVIDED_NOT_INVENTED')]:w.writerow([area,task,evidence,status])
(P/'artwork-response.txt').write_text('''CastReader — Apple promotional artwork response checklist
Prepared 2026-10-11. No claim of an invitation or guaranteed featuring.

Read the actual Apple request first: platform, theme, template, deadline and contact.
Workflow: https://help.apple.com/asc/appspromoart/#/itc9783ca70f
Templates: https://help.apple.com/asc/appspromoart/#/itc8ff78da56
Universal template: https://developer.apple.com/app-store-connect/appspromoart/AppAppleID_AppName_YYYYMMDD_AppStore_Universal.psd.zip
Supporting imagery: https://developer.apple.com/app-store-connect/appspromoart/AppAppleID_AppName_YYYYMMDD_AppStore_SupportingImagery.psd.zip
Apps/Games/Watch: https://developer.apple.com/app-store-connect/appspromoart/AppAppleID_AppName_YYYYMMDD_AppStore_AppsGamesWatch.psd.zip
Product/developer page: https://developer.apple.com/app-store-connect/appspromoart/AppAppleID_AppName_YYYYMMDD_AppStore_ProductPage_DeveloperPage.psd.zip

Current reusable inputs: https://press.castreader.com/castreader-screenshots.zip
Official icon: https://press.castreader.com/assets/castreader-app-icon.png
Preview (earlier recording retained in current listing): https://press.castreader.com/assets/castreader-approved-preview.mp4
New original samples for a future fresh recording: https://press.castreader.com/castreader-editor-trial.zip

Prepare only the requested templates. Preserve dimensions. Embed each component as its own scalable Smart Object, not a linked local file. Use the requested latest/largest device and inspect crops. Check exact filing/naming/rights guidance in the current request before submission. The website phone frame is a web presentation, not a substitute for Apple artwork templates.

Do not treat approved store screenshots as universal rights clearance for every future marketing reuse. Retain sources and rights evidence for whatever is actually submitted. No new legal acceptance or Promotional Artwork upload has been performed in this work.
''')
print('Built research report, CPP activation map, readiness matrix and artwork response checklist.')
