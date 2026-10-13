from pathlib import Path
import json, html
from datetime import datetime, timezone
P=Path(__file__).resolve().parent
source=Path('/Users/xuxuheng/Documents/CastReader/reports/custom-product-pages-20261011/live-localizations.json')
locales=[x['attributes']['locale'].upper() for x in json.loads(source.read_text())['data']]
nomination={
 'status':'LOCAL_DRAFT_NOT_APPLIED',
 'existing_nomination_id':'e12dea24-c8b4-45b6-828b-061d97d5d459',
 'purpose':'Refresh the already-submitted October nomination; preserve its existing dates and type.',
 'suggested_attributes':{
  'name':'CastReader — Follow the Words, Hear the Meaning',
  'description':"CastReader helps people follow their own reading material with sound and visible guidance on the same page. Read Aloud pairs speech with synchronized word highlighting and automatic scrolling. AI Explain speaks an explanation while handwritten-style highlights, circles and numbered steps appear on the original text.\n\nVersion 1.2.48 expands the interface and reading experience from nine to 28 languages on iPhone and iPad. Readers can bring PDFs, EPUBs, documents, photos or pasted text, and the Safari extension provides read-aloud with highlighting on web pages. Photo text recognition runs on-device. Available voices and features vary by language and region.\n\nFor October's accessible-reading focus, we would welcome consideration for reading, learning and productivity collections. The editorial story is how listening, following the words and seeing an explanation can work together for people who prefer visual and audio guidance. CastReader is a reading tool; we make no clinical outcome claims.",
  'deviceFamilies':['IPHONE','IPAD'],
  'locales':locales,
  'notes':"The current approved iOS listing is 1.2.48. Please consider the updated language coverage and iPad experience. The earlier back-to-school event has ended; no new event is attached. A short demonstration should show Read Aloud with word highlighting, followed by AI Explain drawing notes on the original. Supplemental footage and screenshots should use the current app and content we own or may display.",
 },
 'materials_to_prepare':['Publicly accessible editorial media page or folder with a current 30–45 second demo, iPhone and iPad screenshots, and a short factual team/product story.','Reuse current approved screenshots and preview; verify the public links work without sign-in.','Provide two or three localized examples to demonstrate actual language support; do not imply all voice-cloning languages are supported.'],
 'preserved_fields':['type','publishStartDate','publishEndDate','relatedApps','existing supplementalMaterialsUris until replacement links are verified'],
 'not_claimed':['VoiceOver compliance','medical efficacy','all processing offline','a new event already exists','guaranteed editorial placement']
}
event={
 'status':'CONCEPT_ONLY_REQUIRES_APP_IMPLEMENTATION_AND_DEVICE_VALIDATION',
 'referenceName':'READ_AND_FOLLOW_NOVEMBER_2026',
 'badge':'CHALLENGE',
 'proposed_schedule':{'timezone':'Asia/Shanghai','publishStart':'2026-11-01T00:00:00+08:00','eventStart':'2026-11-09T00:00:00+08:00','eventEnd':'2026-11-22T23:59:00+08:00','note':'Planning proposal only, not a committed release date. Shift all dates if the in-app experience and review are not ready.'},
 'localizations':{
  'en-US':{'name':'Read and Follow: Seven Days','shortDescription':'Read with audio on seven different days','longDescription':'Bring your own text. Listen with synced highlights and complete seven reading days before the event ends.'},
  'zh-Hans':{'name':'听读同行：七日挑战','shortDescription':'在活动期间，完成七个不同的听读日','longDescription':'导入自己的文章或文档，边听边看同步高亮。在活动结束前完成七个听读日，查看自己的阅读进度。'}
 },
 'proposed_completion_rule':'On seven distinct local dates during the event, complete at least five minutes of actual Read Aloud playback; show progress and completion clearly. This is a proposed new rule, not the legacy import-based behavior.',
 'implementation_requirements':['Confirm the verified current release source; the main checkout is not established as the release baseline.','Create a new campaign ID and independent progress storage; do not count old campaign progress.','Implement the planned schedule, visible event destination, valid event-specific deep link, playback-based completion and ended state.','Validate first install/onboarding, logged-out access, existing user, date boundaries, replay idempotency, iPhone/iPad, and participating languages.','Check whether the planned goal can be completed within the actual free entitlement; represent any additional event purchase accurately.','Re-record demonstration of the real event, then submit a new binary if the event experience requires code changes.'],
 'asset_plan':{'card':'16:9, 1920×1080 or larger within Apple limits','detail':'9:16, 1080×1920 or larger within Apple limits','creative':'Show a real reading scene and genuine progress UI. Keep essential content clear of automatic overlays. Reuse licensed/current app footage, not obsolete event dates.'},
 'nomination_plan':'Submit an editorial nomination at least three weeks before the chosen start window; attach the event after approval. Both editorial selection and App Review are separate outcomes.'
}
for loc,values in event['localizations'].items():
 for field,limit in [('name',30),('shortDescription',50),('longDescription',120)]:
  assert len(values[field])<=limit,(loc,field,len(values[field]))
(P/'nomination-refresh-draft.json').write_text(json.dumps(nomination,ensure_ascii=False,indent=2)+'\n')
(P/'event-concept.json').write_text(json.dumps(event,ensure_ascii=False,indent=2)+'\n')
S={
 'nominate':'https://developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring/',
 'featuring':'https://developer.apple.com/app-store/getting-featured/',
 'event':'https://developer.apple.com/app-store/in-app-events/',
 'create':'https://developer.apple.com/help/app-store-connect/offer-in-app-events/offer-in-app-events/',
 'submit':'https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-event/',
 'queue':'https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/overview-of-submitting-for-review/',
 'accessibility':'https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/',
 'ppo':'https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/overview-of-product-page-optimization',
 'cpp':'https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions/',
 'metrics':'https://developer.apple.com/help/app-store-connect-analytics/acquisition/in-app-events/',
 'voicedream':'https://apps.apple.com/us/app/voice-dream-natural-reader/id496177674',
}
def a(key,label): return f'<a href="{S[key]}">{label}</a>'
def esc(v):return html.escape(str(v))
ns=json.loads((P/'nominations-submitted.json').read_text())['data']
rows=''.join(f'<tr><td>{esc(n["attributes"]["name"])}</td><td>{esc(n["attributes"]["state"])}</td><td>{esc(n["attributes"]["publishStartDate"][:10])}—{esc(n["attributes"]["publishEndDate"][:10])}</td></tr>' for n in ns)
eventrows=''.join(f'<tr><td>{esc(l)}</td><td>{esc(v["name"])}<small>{len(v["name"])} / 30</small></td><td>{esc(v["shortDescription"])}<small>{len(v["shortDescription"])} / 50</small></td><td>{esc(v["longDescription"])}<small>{len(v["longDescription"])} / 120</small></td></tr>' for l,v in event['localizations'].items())
body=f'''<p class="eyebrow">CASTREADER · APP STORE · 2026-10-11</p>
<h1>把编辑推荐、活动与产品页连起来</h1>
<p class="lead">建议优先更新仍在窗口内的十月提名，再筹备一场真实的七日听读挑战。三类自定产品页负责承接相应场景的访问；辅助功能标签与默认页测试补充长期发现和转化。</p>
<p class="notice">本次完成官方资料调研、线上只读核对与本地草稿；没有修改线上提名、创建新活动或提交新二进制。此前三个自定产品页仍在等待审核。以下日期是方案，不是发布承诺。</p>
<h2>线上核对发现</h2>
<table><thead><tr><th>项目</th><th>实际情况</th><th>行动判断</th></tr></thead><tbody>
<tr><td>编辑推荐提名</td><td>4 个 SUBMITTED；其中 3 个窗口已经过去，十月提名窗口至 10 月 31 日</td><td>先补充十月记录，不重复创建相同主题；SUBMITTED 不能证明已经推荐或未被推荐</td></tr>
<tr><td>十月材料</td><td>8 月 2 日后未更新；只选 iPhone，描述为九语，只有官网和商店两个补充链接</td><td>加入 1.2.48 的 28 语、iPad 与当前演示材料；将语言能力表述限定到已验证范围</td></tr>
<tr><td>App 内活动</td><td>仅一个返校活动，ID 6797107767，状态 PAST，8 月 18 日至 9 月 15 日；9 个本地化</td><td>旧活动已结束，下一场应有独立主题、日期和进度</td></tr>
<tr><td>自定产品页</td><td>阅读、文档、学习三页已提交；本次读回 WAITING_FOR_REVIEW</td><td>获批后分别用于相关入口并观察转化</td></tr>
<tr><td>辅助功能标签</td><td>API 返回空列表</td><td>验证常用流程后填写实际支持项目</td></tr>
</tbody></table>
<details><summary>全部提名记录与证据</summary><table><tr><th>名称</th><th>状态</th><th>请求窗口（UTC 日期）</th></tr>{rows}</table><p><a href="nominations-submitted.json">提名快照</a> · <a href="events.json">活动快照</a> · <a href="product_page_review.json">产品页审核状态</a> · <a href="accessibility-declarations.json">辅助功能声明快照</a></p></details>
<h2>每个入口解决什么问题</h2>
<table><thead><tr><th>入口</th><th>可以争取的结果</th><th>CastReader 的用法</th></tr></thead><tbody>
<tr><td>Featuring Nominations</td><td>进入编辑选题考虑，可能获得 Today、主题集合等展示</td><td>围绕“听到文字、跟住原文、看到讲解”的具体体验讲故事</td></tr>
<tr><td>App 内活动</td><td>活动卡片和详情页，并有搜索、推荐展示机会</td><td>真实的限时挑战或重要功能发布；不能用纯广告或日常重复任务充数</td></tr>
<tr><td>自定产品页</td><td>让特定搜索或外部链接进入更相关的页面</td><td>Books / Documents / Study 分别对应已有三页；不把页面数量当作流量保证</td></tr>
<tr><td>产品页优化</td><td>测试默认商店页素材的下载转化</td><td>流量足够后对首屏“听读跟随”与“AI 解读原文”做一次明确比较；不能对 CPP 直接运行 PPO</td></tr>
<tr><td>辅助功能标签</td><td>向用户展示支持能力，并改善含相关功能词的搜索匹配</td><td>逐项验证 VoiceOver、大字体、对比度等常用流程，再据实声明</td></tr>
</tbody></table>
<p>{a('featuring','Apple 编辑推荐')} · {a('event','活动适用范围')} · {a('cpp','自定产品页')} · {a('ppo','PPO 适用范围')} · {a('accessibility','辅助功能标签与搜索')}</p>
<h2>第一优先：更新十月提名</h2>
<p>推荐保留现有提名的时间窗口及 APP_ENHANCEMENTS 类型，补充当前产品事实。最有辨识度的展示是：同一份原文先做同步听读，再展示讲解与原文标注。28 语和 iPad 体验作为已完成的更新依据。不要补写未核实的临床效果、全面离线能力或系统辅助功能认证。</p>
<p>准备一个无需登录的编辑材料入口，包含 30–45 秒演示、iPhone/iPad 实际截图、2–3 个本地化例子以及简短的真实产品背景。先复用已通过审核的素材，仅补齐演示中缺少的片段。不要把本地路径作为编辑团队可访问的链接。</p>
<p>在 App Store Connect 的“精选 → 提名”打开现有记录，更新信息并保存。新建提名时填写主题、类型、日期、平台、地区、本地化和补充材料后正式提交；已获批或已发布的活动可以关联。{a('nominate','官方提交说明')}</p>
<details open><summary>可直接用于补充的英文草稿（尚未提交）</summary><pre>{esc(nomination['suggested_attributes']['description'])}</pre><p><a href="nomination-refresh-draft.json">下载完整字段草稿</a>，包含 29 个商店本地化及 iPhone/iPad；28 是产品语言数量，两者口径不同。</p></details>
<h2>第二优先：下一场真实的听读挑战</h2>
<p>建议主题“听读同行：七日挑战”：活动期间在七个不同日期各完成至少五分钟实际播放，页面显示进度。此规则是产品方案。当前主目录旧代码将成功导入并打开资料计为一个学习日，且日期固定到 9 月 15 日；它不等于已验证的新活动实现，也不能仅改 ASC 活动日期就复用。</p>
<p>须先在当前已验证发布源码上确认并实现新活动 ID、独立进度、结束状态和准确深链。验证首次安装、已有用户、登录前后、日期边界和重复计数；如需代码变更，随新的已验证 App 版本提交。现有 <code>castreader://study</code> 只能作为历史入口线索，不能当作新活动已验收的链接。</p>
<table><tr><th>语言</th><th>名称</th><th>短描述</th><th>长描述</th></tr>{eventrows}</table>
<p>备选方向是围绕真正新增的多语阅读体验申请 Major Update 活动，但必须有明确的新体验与对应入口。1.2.48 已经上线，后续宣传应准确写发布时间；轻微修复和泛化宣传不适合作为重大更新活动。{a('event','Apple 对活动类型的要求')}</p>
<p>素材计划：横卡 1920×1080、竖详情 1080×1920，使用实际阅读与进度画面，避免把普通商店截图上的大段宣传字照搬成活动主视觉。尺寸与叠层以提交时的预览核验。{a('event','官方素材规范')}</p>
<h2>提交顺序与建议日程</h2>
<ol>
<li><b>现在：</b>补充十月提名的事实、设备和公开演示材料。旧提名已经提前提交；补充材料仍由编辑决定是否纳入本轮。</li>
<li><b>筹备下一轮：</b>完成活动体验与素材，并提交下一轮编辑提名。可暂按 11 月 9—22 日活动、11 月 1 日预热规划，未就绪则整体顺延。</li>
<li><b>活动审核：</b>App 内活动 → 创建 → 填写 30/50/120 字符文案、素材、类型、地区时间、深链、目的及费用 → 添加以供审核 → 提交审核。已上线 App 可以单独提交活动；需要新功能时与对应版本一起审。{a('create','创建字段')} · {a('submit','正式提审')}</li>
<li><b>获批后：</b>将获批活动关联至编辑提名；核对实际公开卡片、事件入口和产品页链接。</li>
<li><b>发布后：</b>按地区和来源比较曝光、详情访问、下载、首次成功听读与后续留存，决定下一轮是否继续。</li>
</ol>
<p>Apple 的编辑介绍页写至少提前两周，Connect 提名帮助页建议至少三周。执行按更保守的三周以上、通常 3–6 周准备；大型季节主题可更早。活动本身最长 31 天，可最多提前 14 天预热。这些是不同时间要求。{a('featuring','编辑排期介绍')} · {a('nominate','提名操作建议')} · {a('create','活动日期限制')}</p>
<p>当前 CPP 占着 iOS 的纯素材提交队列。Apple 每个平台允许同时一个含 App 版本的提交和一个不含版本的提交；因此下一场若单独提审，应先读回队列状态。不要为了新活动撤掉已经提交的产品页。{a('queue','审核队列规则')}</p>
<h2>如何提高被选中与被点击的机会</h2>
<p><b>我的判断：</b>CastReader 值得主推的不是功能清单长度，而是同步听读与原文讲解这一组可看见的体验。分别做“看长文容易跟丢”“文档学习”“外语跟读”的场景素材；每份提名聚焦一个当下已交付的变化。地域优先级先参考真实下载与留存，再配置相应母语素材；本次未拉取最新地区增长数据，因此不编造最佳市场排名。</p>
<p>同类案例可参考 Voice Dream：当前美国商店页确有 Editors’ Choice 标识，编辑短评用通勤听故事、检查工作演讲稿等具体场景介绍它。这支持 TTS 工具能够进入编辑选择的判断，但不能据此推算 CastReader 的入选概率或流量。{a('voicedream','Voice Dream 商店页')}</p>
<p>辅助功能标签目前是空白。验证从导入、选择内容、播放、切模式到设置与付费等常用任务，再申报满足条件的支持项。不要因为 App 会 TTS 朗读就直接勾选 VoiceOver；这些是不同能力。标签可以参与相关功能查询的搜索匹配。{a('accessibility','官方评估标准')}</p>
<p>三个 CPP 获批后，让文章/文档入口进入 Documents、电子书入口进入 Books、学习与讲解入口进入 Study。默认页的 A/B 测试应一次只回答一个问题，并结合样本量判断；不同入口用户之间的 CPP 数据不是随机实验。</p>
<h2>验收口径</h2>
<table><tr><th>阶段</th><th>看什么</th><th>不能混淆的结论</th></tr>
<tr><td>提交</td><td>提名 SUBMITTED；活动审核状态；公开链接可用</td><td>提交成功不等于编辑推荐</td></tr>
<tr><td>发现</td><td>活动曝光、来源、地区、首次下载；Browse 与 Search 分开</td><td>Browse 增长本身不能证明获得编辑席位</td></tr>
<tr><td>转化</td><td>详情访问/曝光、下载、首次成功听读、次日与七日留存</td><td>卡片可直接下载，详情访问率不覆盖全部下载路径</td></tr>
<tr><td>后续</td><td>活动进度、实际播放、免费到付费的完整漏斗</td><td>本次没有拉取实际活动成效或新增推荐证据，不能声称效果提升</td></tr></table>
<p>{a('metrics','活动分析指标')}</p>
<p class="footer">调研与读取日期：2026-10-11（Asia/Shanghai）。官方规则以链接的当前内容为准。相关 API JSON 为只读证据；草案文件不触发提交。</p>'''
style='''body{font:16px/1.7 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:#172b38;background:#f5f7f9;margin:0}main{max-width:1100px;margin:40px auto;padding:48px;background:white;border-radius:20px}h1{font-size:38px;line-height:1.25;letter-spacing:-1px}h2{font-size:24px;margin-top:40px;padding-top:14px;border-top:1px solid #dae1e7}.eyebrow{color:#b24b19;font-size:13px;letter-spacing:2px}.lead{font-size:20px;color:#294b5e}.notice{background:#fff4e7;border-left:4px solid #e37b2d;padding:16px}table{border-collapse:collapse;width:100%;font-size:14px;margin:18px 0}td,th{text-align:left;vertical-align:top;padding:12px;border-bottom:1px solid #dce3e9}th{background:#edf3f6}a{color:#11648a}pre{white-space:pre-wrap;font:15px/1.7 -apple-system,sans-serif;background:#eff4f6;padding:20px;border-radius:10px}details{margin:16px 0}summary{cursor:pointer;font-weight:600}small{display:block;color:#697b86}.footer{font-size:13px;color:#697b86;margin-top:40px}li{margin:12px 0}code{overflow-wrap:anywhere}@media(max-width:750px){main{margin:0;padding:22px;border-radius:0}h1{font-size:30px}table{display:block;overflow-x:auto}}'''
(P/'research.html').write_text(f'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>CastReader · App Store 曝光调研与提交方案</title><style>{style}</style><main>{body}</main></html>')
(P/'sources.json').write_text(json.dumps({'checked_at':datetime.now(timezone.utc).isoformat(),'sources':S},ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'report':str(P/'research.html'),'nomination_locale_count':len(locales),'event_text_lengths':{l:{k:len(v) for k,v in d.items()} for l,d in event['localizations'].items()},'status':'local research and drafts only'},ensure_ascii=False,indent=2))
