from pathlib import Path
import json, html, shutil, csv, hashlib

ROOT = Path(__file__).resolve().parent
def read(name):
    return json.loads((ROOT / name).read_text())

generated = Path('/Users/xuxuheng/.codex/generated_images/01a126d0-d046-7263-9c9d-855b072643c9')
drafts = ['exec-c3176872-b8c3-4f67-999a-c91098f89554.png', 'exec-148a02fa-f20f-42a9-9bbf-1ba2235c46bf.png']
for i, name in enumerate(drafts, 1):
    shutil.copyfile(generated / name, ROOT / f'creative-concept-{i}-NOT-UPLOAD-READY.png')

sources = {
    'events': ('App 内活动：展示位置与资格', 'https://developer.apple.com/app-store/in-app-events/'),
    'creative': ('创意素材：审核与发布流程', 'https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets'),
    'specs': ('创意素材尺寸', 'https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications'),
    'iap': ('推广 App 内购买', 'https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/promote-in-app-purchases'),
    'intent': ('承接推广购买的 StoreKit 接口', 'https://developer.apple.com/documentation/storekit/supporting-promoted-in-app-purchases-in-your-app'),
    'tags': ('App 标签', 'https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-tags/'),
    'cpp': ('自定产品页与关键词', 'https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions/'),
    'ads': ('Apple Ads 展示位置', 'https://ads.apple.com/app-store/help/ad-placements/0081-ad-placement-options'),
    'nomination': ('推荐提名', 'https://developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring/'),
    'meet': ('10 月 24 日 App Store 增长讲座', 'https://developer.apple.com/events/view/M99MTKF8V3/dashboard'),
    'awards': ('App Store Awards 官方页面', 'https://developer.apple.com/app-store/app-store-awards/'),
    'design': ('Apple Design Awards 官方页面', 'https://developer.apple.com/design/awards/'),
}
def cite(key):
    title,url=sources[key]
    return f'<a href="{html.escape(url)}">{html.escape(title)} ↗</a>'

actions = [
    dict(priority='P0',route='现有编辑提名',status='SUBMITTED（此前已提交并更新）',next='保持 10 月现有提名；仅在出现真实新证据时更新，避免提交相同故事的重复提名。',gate='Apple 编辑选择，尚无入选证据'),
    dict(priority='P0',route='三个自定产品页',status='WAITING_FOR_REVIEW',next='获批后验证公开链接和对应国家语言的搜索承接；比较匹配人群的下载结果。',gate='Apple 审核；关键词已经配置，本轮没有重复修改'),
    dict(priority='P1',route='搜索 / 页首创意素材',status='CONCEPT_ONLY_NOT_SUBMITTED',next='完成符合尺寸的正式图，上传素材库并单独送审；批准后在已上线版本的页首与搜索结果中选择并发布。',gate='当前生成图 1536×1024；搜索图最低 1920×1280；仅 iOS/iPadOS 27+ 展示'),
    dict(priority='P1',route='Pro 订阅推广',status='NOT_CONFIGURED',next='核对实际发布源码的 StoreKit PurchaseIntent 承接；完成真机购买 / 取消 / 恢复 / 新安装测试；制作订阅专属图片并配置已批准订阅推广。',gate='现有工作树未发现 PurchaseIntent.intents 或旧版 shouldAddStorePayment；尚未核实发布包'),
    dict(priority='P1',route='限时七日听读挑战',status='CONCEPT_REQUIRES_PRODUCT_WORK',next='实现独立活动入口、真实播放计时、七日进度、完成与结束状态；实测后再创建活动并提交。',gate='11 月 9–22 日是提案日期；如未达成产品和审核条件则顺延'),
    dict(priority='P2',route='美国 App 标签',status='NO_ASSIGNED_TAGS',next='Apple 分配标签后核对准确性；保持美国元数据真实清晰。',gate='开发者不能自建任意标签'),
    dict(priority='OPTIONAL_PAID',route='Apple Ads',status='NO_NEW_CAMPAIGN_STARTED_THIS_TURN',next='优先用搜索结果广告验证 PDF、OCR、EPUB 等意图与 CPP；再依据付费和留存决定扩展版位。',gate='本轮没有新增支出；新增投放须有明确支出范围'),
]
(ROOT/'action-plan.json').write_text(json.dumps({'checkedAt':'2026-10-11 Asia/Shanghai','actions':actions,'sources':sources},ensure_ascii=False,indent=2))
with (ROOT/'action-plan.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=['priority','route','status','next','gate']); w.writeheader(); w.writerows(actions)

keywords=[]
for kind in ['books','documents','study']:
    for entry in read(kind+'_locales.json')['data']:
        terms=[x['id'] for x in entry.get('relationships',{}).get('searchKeywords',{}).get('data',[])]
        keywords.append({'page':kind,'locale':entry['attributes']['locale'],'keywords':', '.join(terms),'status':'already configured; no write this turn'})
with (ROOT/'verified-cpp-keywords.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=['page','locale','keywords','status']); w.writeheader(); w.writerows(keywords)

rows = [
('App 内活动','新发现入口','搜索、产品页、个性化和编辑精选','旧活动已结束；七日挑战仍需产品实现',cite('events')),
('推广 Pro 订阅','新发现入口','独立内购卡片；可能出现在搜索或推荐','后台 0 项；需先验证商店发起购买承接',cite('iap')),
('美国 App 标签','新发现入口','标签聚合页面、搜索和产品页','后台 0 个已分配标签；只能管理 Apple 分配的标签',cite('tags')),
('创意素材','展示 / 点击优化','搜索大图、产品页页首，iOS/iPadOS 27+','入口已开放；本轮两张概念稿像素不足，未送审',cite('creative')),
('自定产品页','搜索意图匹配','同一 App 的对应产品页','3 页待审；Books 和 Documents 各 29 个语言版本已有关键词，Study 有 10 个',cite('cpp')),
('Apple Ads','付费流量','搜索结果、Search、Today、其他产品页','本轮没有新开投放；广告与编辑推荐分开评估',cite('ads')),
]
row_html=''.join('<tr>'+''.join('<td>'+v+'</td>' for v in row)+'</tr>' for row in rows)
todo_html=''.join(f'<li><strong>{a["route"]}</strong> <span class="label">{a["priority"]}</span><p>{a["next"]}</p><small>{a["gate"]}</small></li>' for a in actions)
doc='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>CastReader · App Store 曝光机会核查</title>
<style>:root{color-scheme:light}body{margin:0;background:#f7f6f2;color:#21302e;font:16px/1.8 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}main{max-width:1100px;margin:auto;padding:48px 24px 80px}h1{font-size:38px;line-height:1.25;margin:12px 0 22px}h2{font-size:24px;margin-top:42px}p{max-width:900px}a{color:#ac3c00;text-underline-offset:3px}.eyebrow{font-size:13px;letter-spacing:.1em;color:#765d4c}.lead{font-size:20px}.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin:28px 0}.stat,section{background:#fff;border:1px solid #e2e3dc;border-radius:16px;padding:20px}.stat b{display:block;font-size:36px;line-height:1.3}.stat small{display:block;margin-top:5px;color:#64726b}.scroll{overflow:auto}table{border-collapse:collapse;min-width:840px;width:100%;font-size:14px}th,td{padding:14px 12px;text-align:left;vertical-align:top;border-bottom:1px solid #e2e3dc}th{background:#eeefe9}td:first-child{font-weight:650;min-width:100px}small,.muted{color:#66726c}li{margin:20px 0}li p{margin:4px 0}.label{background:#f1ebe1;border-radius:5px;padding:3px 7px;font-size:12px;margin-left:6px}.notice{border-left:4px solid #ef620c;padding:10px 18px;background:#fff4e7}img{display:block;width:min(100%,720px);border-radius:14px}details{padding:16px 0;border-bottom:1px solid #deded4}summary{font-weight:650;cursor:pointer}code{overflow-wrap:anywhere}footer{margin-top:40px;font-size:13px;color:#66726c}@media(max-width:600px){main{padding:28px 16px}h1{font-size:29px}.stats{grid-template-columns:1fr}.stat b{font-size:28px}section{padding:16px}}</style>
<main><div class="eyebrow">CASTREADER · 核查日期 2026-10-11</div><h1>把 App Store 曝光入口补齐</h1><p class="lead">重点推进真实 App 内活动、推广订阅，并完成搜索创意素材。现有 10 月提名和三个产品页继续保留。</p>
<div class="stats"><div class="stat"><b>426</b>搜索来源首次下载<small>包含搜索广告带来的下载</small></div><div class="stat"><b>20</b>商店浏览来源首次下载<small>新增自然浏览机会值得投入</small></div><div class="stat"><b>55.6%</b>美国与英国占首次下载比例<small>381 / 685；优先验证这两区</small></div></div>
<p class="muted">基线：2026-09-10 至 10-07，iPhone + iPad，28 天，共 685 次首次下载。它是来源统计，不是因果实验；不能据此声称所有搜索下载来自自然流量。来源：<a href="../featuring-readiness-20261011/analytics-baseline.json">本地后台数据回执</a>。</p>
<h2>机会与现在能做的事</h2><div class="scroll"><table><thead><tr><th>入口</th><th>作用</th><th>商店位置</th><th>CastReader 现状</th><th>Apple 依据</th></tr></thead><tbody>'''+row_html+'''</tbody></table></div>
<h2>执行顺序</h2><ol>'''+todo_html+'''</ol>
<h2>三项新准备</h2><section><details open><summary>1. 搜索创意素材：概念已出，尚未提交</summary><p>两次内置 image_gen 生成均返回 1536×1024，无透明通道；搜索专用图最低需 1920×1280，最高 3840×2560，比例 3:2。页首图需 3840×1646；通用图需 5244×2950 PNG。这些概念稿不可作为符合尺寸的交付。</p><img src="creative-concept-1-NOT-UPLOAD-READY.png" alt="听读同步的纸张与音频丝带创意概念稿，未提交审核"><p>正式图需完成尺寸与清晰度检查，预览手机 / 平板裁切，然后素材库单独送审。获批后，已上线版本可通过 Browse Assets → Publish 更新，无须仅为这张图提交新二进制。素材审核通过和实际上架展示是两步。</p><p>'''+cite('specs')+' · '+cite('creative')+'''</p><p><a href="creative-prompts.json">完整提示词</a> · <a href="creative-concept-1-NOT-UPLOAD-READY.png">概念 1 原图</a> · <a href="creative-concept-2-NOT-UPLOAD-READY.png">概念 2 原图</a>。素材库现有 4 张已批准创意图均为旧活动卡片 / 详情规格，不能直接当作搜索或页首图。</p></details>
<details open><summary>2. 推广订阅：先接通购买，再配置展示</summary><p>建议先选一个已经批准的 Pro 订阅，验证展示和购买效果，再决定是否加入其他周期。展示名称和权益必须与现有批准订阅一致；不为推广改价格或新增收费承诺。</p><p>技术准备：在已验证发布源码中接收 StoreKit PurchaseIntent，将入口接到现有账号绑定和购买事务流程；处理冷启动、未登录、已订阅、用户取消、待批准、重复事件与购买恢复。不能绕过当前 ProManager 的身份和交易核验。</p><p>后台准备：专属内购推广图片、准确本地化、审核批准及推广设置。当前主目录搜索未找到系统 PurchaseIntent 承接，不代表已发布二进制一定不支持；必须核对真实发布基线后再实施。'''+cite('intent')+'''</p></details>
<details open><summary>3. App 内活动：七日听读挑战</summary><p>活动提案：11 月 9–22 日期间，用户在七个不同日期，每天实际朗读至少五分钟，看到真实进度与完成结果。11 月 1 日开始商店预告；这是计划窗口，尚未创建或提交。若产品未就绪，整体顺延。</p><p>需要独立活动 ID、入口和深链，播放而非导入计数，跨午夜和重复回调防重，未安装与老用户承接，以及活动结束状态。先验证免费用户能够完成目标，再决定最终活动费用描述。</p><p>现有后台活动 BTS_STUDY_BOOST_2026 已结束。直接修改日期、复用旧进度，或把普通功能宣传当限时活动，都不能证明真实活动已准备好。</p><p><a href="../app-store-discovery-research-20261011/event-concept.json">已有中英文案和具体实现要求</a> · '''+cite('events')+'''</p></details></section>
<h2>还有哪些“活动”值得申请？</h2><p>当前官方活动列表可申请 10 月 24 日 <em>Build a global business on the App Store</em>，地点为阿根廷布宜诺斯艾利斯，西班牙语线下，申请截止当地 10 月 23 日 21:00。它适合学习增长与交流，不直接授予 App Store 展示位；本轮未代报海外线下行程。'''+cite('meet')+'''</p><p>App Review 线上预约解决审核问题，不是编辑推荐申请。App Store Awards 页面当前展示 2025 获奖者，Apple Design Awards 页面已展示 2026 获奖者；在这两页没有找到本轮可直接提交的公开参赛表单，不能将它们计作已经开放的获客申请。'''+cite('awards')+' · '+cite('design')+'''</p>
<h2>验证效果</h2><p>各入口单独记录上线时间和实际展示位置。以相同国家 / 设备 / 来源比较上线前后至少两个完整自然周：商店浏览曝光及首次下载、搜索结果点击与首次下载、活动详情访问与参与、Pro 推广购买完成。区分新增用户和重新下载，广告流量单列；不给低样本或同时多项上线的数据做单一因果结论。</p>
<div class="notice"><strong>本轮交付边界：</strong>完成了官方入口调研、后台现状与关键词审计、两张创意概念稿和实施清单。本轮没有新增活动送审、创意图送审、订阅推广发布或广告支出；这些项目的具体前置条件已列在上面。之前的 10 月推荐提名已提交，三个产品页仍在等待审核，均不代表已经获得曝光。</div>
<footer><a href="action-plan.csv">下载执行清单 CSV</a> · <a href="verified-cpp-keywords.csv">87 条产品页语言配置回执</a> · <a href="action-plan.json">结构化计划与来源</a><p>本报告含后台经营数据，仅保存在本地，不发布到公开媒体页。图片使用内置 image_gen 生成；本轮未通过其他工具改图或放大。</p></footer></main></html>'''
(ROOT/'opportunities.html').write_text(doc)
receipt={'checkedAt':'2026-10-11 Asia/Shanghai','externalMutationsThisTurn':[], 'cppCount':3,'cppState':'WAITING_FOR_REVIEW','cppKeywordLocalizationCounts':{'books':29,'documents':29,'study':10},'promotedPurchases':0,'appTags':0,'activeEvents':0,'creativeDrafts':{'count':2,'dimensions':[1536,1024],'submitted':False,'limitation':'below required search placement 1920x1280'},'artifacts':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in ROOT.glob('*') if p.is_file() and p.name!='completion-receipt.json'}}
(ROOT/'completion-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2))
print(json.dumps({'report':str(ROOT/'opportunities.html'),'cppRows':len(keywords),'actions':len(actions)},ensure_ascii=False))
