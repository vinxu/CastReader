from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
import json, hashlib, html, shutil

ROOT = Path(__file__).resolve().parent
def read(name):
    return json.loads((ROOT / f'{name}.json').read_text())
def esc(value):
    return html.escape(str(value))

review = read('review-submitted-readback')['data']
assert review['attributes']['state'] == 'WAITING_FOR_REVIEW'
files = [
    ('搜索结果图', 'search-listen-follow-1920x1280.png', [1920, 1280], read('creative-search-readback')['data']),
    ('产品页页首图', 'header-listen-follow-3840x1646.png', [3840, 1646], read('creative-header-readback')['data']),
    ('年度 Pro 订阅宣传图', 'pro-subscription-1024x1024.png', [1024, 1024], read('yearly-version-readback')['data']),
]
submitted = datetime.fromisoformat(review['attributes']['submittedDate'].replace('Z','+00:00')).astimezone(ZoneInfo('Asia/Shanghai'))
review_url = f'https://appstoreconnect.apple.com/apps/6757636395/distribution/reviewsubmissions/details/{review["id"]}'
prompts = read('header-artwork-prompt') if (ROOT/'header-artwork-prompt.json').exists() else {}
prompt_set = {
    'generationMode': 'built-in image_gen',
    'resizeMode': 'Pillow Lanczos, proportional scaling explicitly authorized by user; no image API fallback',
    'search': json.loads((ROOT.parent/'app-store-extra-exposure-20261011/creative-prompts.json').read_text())['generate'],
    'header': (ROOT/'header-artwork-prompt.txt').read_text(),
    'subscription': (ROOT/'pro-artwork-prompt.txt').read_text(),
}
(ROOT/'final-prompts.json').write_text(json.dumps(prompt_set, ensure_ascii=False, indent=2))
receipt = {
    'appId': '6757636395', 'submittedAt': submitted.isoformat(),
    'reviewSubmissionId': review['id'], 'reviewURL': review_url, 'state': review['attributes']['state'],
    'assets': [{'name': name, 'file': str((ROOT/file).resolve()), 'dimensions': dimensions, 'state': resource['attributes']['state'], 'resourceId': resource['id'], 'sha256': hashlib.sha256((ROOT/file).read_bytes()).hexdigest()} for name,file,dimensions,resource in files],
    'scope': 'Two standalone creative assets plus image-only version 2 of existing approved yearly v2 subscription 6802002910.',
    'copyPreservation': 'Existing subscription localization name and description compared equal before review; prices, billing terms and entitlements unchanged.',
    'generation': prompt_set,
    'existingNomination': {'id': 'e12dea24-c8b4-45b6-828b-061d97d5d459', 'state': read('nomination-before')['data']['attributes']['state']},
    'existingCPPReview': {'id': 'c3c2a6cc-598f-4196-9f5d-1188fd743ea2', 'state': 'WAITING_FOR_REVIEW', 'count': 3},
    'pending': [
        {'item': 'Creative placement publication', 'state': 'AWAITING_APPLE_REVIEW', 'next': 'Once images are approved, assign the search and header assets to the live default iOS product page, preview and publish. Approval alone does not publish placements.'},
        {'item': 'Promoted yearly subscription visibility', 'state': 'REQUIRES_APP_IMPLEMENTATION', 'next': 'Implement StoreKit PurchaseIntent.intents handling on the verified release baseline and pass real-device purchase, cancellation, restoration and new-install coverage before enabling promotion.'},
        {'item': 'New seven-day listening challenge', 'state': 'REQUIRES_APP_IMPLEMENTATION', 'next': 'Implement a new dated campaign and dedicated deep link, real playback progress, completion/end states and real-device verification; create and submit only when the released app delivers the promised activity.'},
    ],
    'releaseAudit': {'checkout': '/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader', 'checkedHead': 'd48a9af144bfef1d07af0e81c7a847b283d8bbf0', 'releasedVersion': '1.2.48 (75)', 'sourceCommit': '60b0973c5dd7e3a922349fb157c5ec0af96cc53b', 'findings': ['No StoreKit PurchaseIntent.intents or legacy shouldAddStorePayment handler found in verified release checkout.', 'StudyBoost campaign back-to-school-2026 ends 2026-09-16 exclusive; its progress records imported/opened study material, not listening duration.']},
}
(ROOT/'completion-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
cards = ''.join(f'<article><a href="{file}"><img src="{file}" alt="{name}"/></a><h2>{name}</h2><p>{dimensions[0]} × {dimensions[1]} · 等比导出 · RGB PNG</p><span class="badge">等待审核</span><p class="small">{esc(resource["id"])}</p><a href="{file}" download>下载正式图片</a></article>' for name,file,dimensions,resource in files)
page = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CastReader · 素材送审回执</title>
<style>body{{margin:0;background:#faf8f3;color:#202b28;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}main{{max-width:1100px;margin:48px auto;padding:0 24px}}h1{{font-size:36px;line-height:1.2}}h2{{font-size:20px}}a{{color:#a73e00}}.eyebrow,.badge{{font-size:13px;font-weight:650}}.eyebrow{{letter-spacing:1px;color:#a73e00}}.badge{{display:inline-block;background:#fff1cb;color:#755309;padding:4px 10px;border-radius:30px}}.grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:20px;margin:30px 0}}article,section{{background:white;border:1px solid #e5e0d8;border-radius:18px;padding:20px;margin-bottom:20px}}article img{{width:100%;height:225px;object-fit:contain;background:#faf8f3;border-radius:10px}}.small{{font-size:12px;overflow-wrap:anywhere;color:#6c756e}}table{{border-collapse:collapse;width:100%}}td,th{{padding:12px;text-align:left;border-bottom:1px solid #eee}}.proof{{width:100%;border-radius:10px}}@media(max-width:720px){{.grid{{grid-template-columns:1fr}}h1{{font-size:28px}}}}</style>
<main><div class="eyebrow">CASTREADER · APP STORE CONNECT</div><h1>三项正式素材已送审</h1><p>{submitted.strftime('%Y-%m-%d %H:%M:%S')}（北京时间）提交，API 与 App Store Connect 页面均已回读“等待审核”。</p><p><a href="{review_url}">打开 Apple 审核回执 ↗</a> · <a href="completion-receipt.json">完整机器可读回执</a></p>
<div class="grid">{cards}</div>
<section><h2>图像处理与检查</h2><p>搜索图从 1536×1024 等比放大到 1920×1280；订阅图从 1254×1254 等比缩小到 1024×1024。页首图采用专门的宽幅构图，统一缩放后仅在左右边缘合计裁去约 1.335 像素，输出 3840×1646，主体没有变形或裁掉。</p><p>三张正式图均为不透明 RGB PNG；已目视检查清晰度、主体和边缘，并由 Apple 返回正确尺寸、无上传错误。采用内置生图与本地等比导出，没有切换图片生成 API。</p><p><a href="image-export-audit.json">等比导出记录</a> · <a href="final-prompts.json">最终提示词与工具记录</a></p></section>
<section><h2>曝光渠道当前状态</h2><table><tr><th>项目</th><th>真实状态</th><th>下一步</th></tr><tr><td>十月编辑推荐提名</td><td>已提交</td><td>等待编辑选择；尚无获得推荐的证据。</td></tr><tr><td>Books / Documents / Study 三张自定产品页</td><td>等待审核</td><td>关键词已配置；批准后核对公开链接。</td></tr><tr><td>搜索图、页首图</td><td>本轮已提交，等待审核</td><td>获批后在已上线产品页中选择并发布；新创意展示适用于 iOS / iPadOS 27+。</td></tr><tr><td>年度订阅宣传图</td><td>本轮已提交，等待审核</td><td>仅图片元数据送审；App 补齐 StoreKit 商店购买承接并验证后，才能启用订阅推广。</td></tr><tr><td>新七日听读活动</td><td>尚不能提交</td><td>当前发布包仍为已结束的旧活动；需新活动配置、真实播放进度和验证后再提交。</td></tr><tr><td>App 标签</td><td>尚无 Apple 分配的标签</td><td>等待分配后核对；开发者不能自建任意标签。</td></tr></table><p>本轮未更改订阅价格、权益或交易条款，未新增广告支出。</p></section>
<section><h2>Apple 页面验证</h2><a href="review-confirmation.png"><img class="proof" src="review-confirmation.png" alt="App Store Connect 显示三项素材等待审核"/></a></section>
<section><h2>官方依据</h2><p><a href="https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-assets-from-asset-library">素材独立送审</a> · <a href="https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications">图片规格</a> · <a href="https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets">审核后发布展示</a> · <a href="https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/promote-in-app-purchases">内购推广条件</a></p></section></main></html>'''
(ROOT/'index.html').write_text(page)
old=ROOT.parent/'app-store-extra-exposure-20261011/opportunities.html'
if old.exists():
    text=old.read_text()
    marker='id="updated-submission-receipt"'
    if marker not in text:
        banner='<aside id="updated-submission-receipt" style="padding:18px;background:#eaf5ed;color:#183b22">更新：正式图已等比导出，搜索图、页首图和年度订阅图均已提交审核。<a href="../app-store-exposure-submission-20261011/index.html">查看最新送审回执</a>。以下为此前调研记录。</aside>'
        text=text.replace('<body>', '<body>'+banner, 1)
        old.write_text(text)
print(json.dumps({'report':str(ROOT/'index.html'),'submission':review['id'],'state':review['attributes']['state'],'asset_count':len(files)},ensure_ascii=False))
