import json
from pathlib import Path
from html import escape
from datetime import datetime
from zoneinfo import ZoneInfo

root = Path(__file__).resolve().parent
read = lambda name: json.loads((root / (name + '.json')).read_text())
plan = read('plan')
submission = read('submission-final')['data']
states = {x['id']: x['attributes']['state'] for x in read('page-states-final')}
audits = {x['page']: x for x in read('audit')}
submitted = datetime.fromisoformat(submission['attributes']['submittedDate'].replace('Z', '+00:00')).astimezone(ZoneInfo('Asia/Shanghai'))
titles = {'books': '电子书听读', 'documents': 'PDF、网页与拍照朗读', 'study': 'AI 解读与学习'}
explanations = {
 'books': '先展示书籍朗读与同步高亮，再展示书库和续读能力。',
 'documents': '先展示网址、文件、照片与文本导入，再展示朗读和解读效果。',
 'study': '先展示 AI 对原文的标注，再展示同步朗读及资料导入。'
}
cards = []
for page in plan['pages']:
    key = page['key']
    inv = read(key + '-inventory')
    rows = []
    for d in inv['details']:
        locale = d['localization']['attributes']['locale']
        keywords = ', '.join(k['id'] for k in d['keywords']) or '保留默认搜索页；自定页可用于直接链接'
        rows.append(f'<tr><td>{escape(locale)}</td><td>{escape(keywords)}</td><td dir="auto">{escape(page["copy"][locale])}</td></tr>')
    status = states[inv['version']['id']]
    cards.append(f'''<article><div class="copy"><span class="pill">{escape(status)}</span>
      <h2>{titles[key]}</h2><p>{explanations[key]}</p>
      <p class="promo">{escape(page['copy']['zh-Hans'])}</p>
      <p>29 个本地化版本 · iPhone / iPad · {audits[key]['keywordAssignments']} 个关键词分配</p>
      <p><a href="{escape(inv['page']['attributes']['url'])}">App Store 独立链接</a> ·
      <a href="https://appstoreconnect.apple.com/apps/6757636395/distribution/productpages/{inv['version']['id']}">在 App Store Connect 验收</a></p>
      <details><summary>查看 29 个本地化版本的文案和关键词</summary><table><thead><tr><th>地区语言</th><th>已配置关键词</th><th>推广文案</th></tr></thead><tbody>{''.join(rows)}</tbody></table></details></div>
      <img class="creative" src="assets/en-{page['order'][0]}.png" alt="{titles[key]}首张截图"></article>''')
html = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CastReader 自定产品页验收 · 2026-10-11</title>
<style>body{{margin:0;background:#fbf8f3;color:#202622;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}}main{{max-width:1120px;margin:48px auto;padding:0 24px}}h1{{font-size:38px;line-height:1.2;letter-spacing:-1px}}h2{{margin:15px 0 8px;font-size:28px}}a{{color:#c44700}}.muted{{color:#677068}}.stats{{display:flex;gap:18px;flex-wrap:wrap;margin:28px 0}}.stats div{{background:white;border:1px solid #e5ded3;padding:18px 24px;border-radius:14px}}.stats b{{font-size:30px;display:block}}article{{display:flex;align-items:start;gap:36px;padding:32px;margin:22px 0;background:white;border:1px solid #e5ded3;border-radius:20px}}.copy{{flex:1;min-width:0}}.creative{{width:220px;border-radius:12px}}.pill{{display:inline-block;font-size:12px;letter-spacing:.5px;background:#fff0d8;color:#7a4d00;padding:5px 10px;border-radius:6px}}.promo{{border-left:3px solid #ff6600;padding-left:16px}}summary{{cursor:pointer;color:#c44700}}table{{width:100%;border-collapse:collapse;font-size:13px}}td,th{{padding:10px 6px;text-align:left;vertical-align:top;border-bottom:1px solid #eee}}.note{{padding:24px;background:#f1eee6;border-radius:14px}}footer{{font-size:13px;color:#677068;margin:30px 0}}@media(max-width:750px){{article{{flex-direction:column;padding:22px}}.creative{{width:200px}}h1{{font-size:30px}}}}</style>
<main><p class="muted">CastReader · App Store 自定产品页 · 2026-10-11</p><h1>三个使用场景，三组独立产品页</h1>
<p>已于北京时间 {submitted.strftime('%Y-%m-%d %H:%M:%S')} 提交 Apple 审核。当前审核状态：<strong>{escape(submission['attributes']['state'])}</strong>。页面获批后才能公开展示，当前不是已上线状态。</p>
<div class="stats"><div><b>3</b>自定产品页</div><div><b>29</b>每页本地化版本</div><div><b>123</b>互不重叠的关键词分配</div><div><b>2</b>设备尺寸 / 本地化版本</div></div>
{''.join(cards)}
<section class="note"><h2>验收与效果判断</h2><p>三页共 87 份推广文案，全部符合 170 字符限制。每页沿用 1 条已获批的英语 App 预览视频，三个视频引用状态均为 COMPLETE。174 组设备截图共 870 个引用已全部完成处理；逐项核对了来源校验和、截图顺序、页面可见设置和关键词分配。素材复用已获批的 1.2.48 真实截图，并非新增拍摄 870 张图片。</p>
<p>每个页面匹配不同的搜索需求，首图直接呈现该场景。现有版本缺少相关学习关键词的语言保留默认搜索路径，学习页仍有独立推广链接。没有把不相关词强行分配到学习页。</p>
<p>自定页关键词来自当前已获批版本；作用是在相关搜索中显示对应页面，不能保证增加搜索排名或曝光。获批后，站外入口可按意图使用对应独立链接。App Analytics 中分别查看曝光、产品页浏览、首次下载及转化率，分开比较国家、语言和来源；页面至少获得 5 次首次下载后才有自定页指标。明日可验收素材和审核状态，增长效果需要积累样本。</p>
<p>默认 1.2.48 的 29 份本地化字段与截图组标识回读一致。审核为独立 iOS 产品页提交，三个审核项目均对应本次新建页面。</p>
<p><a href="https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions">Apple：自定页与关键词规则</a> · <a href="https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-a-custom-product-page/">Apple：自定页审核流程</a></p></section>
<footer>审核记录：{submission['id']}<br>证据：<a href="audit.json">页面校验</a> · <a href="submission-final.json">审核回执</a> · <a href="page-states-final.json">三页状态</a> · <a href="keyword-overlap-check.json">关键词唯一性</a> · <a href="baseline-preservation.json">原页面保留检查</a></footer></main></html>'''
(root / 'acceptance.html').write_text(html)
print(root / 'acceptance.html')
