// UI locale never changes a card's synthesis language or the SDK's routing.
let saved;
try { saved = localStorage.getItem('voice-studio-ui-language'); } catch { /* Storage can be disabled. */ }
let language = ['en', 'zh-CN'].includes(saved) ? saved : navigator.language.startsWith('zh') ? 'zh-CN' : 'en';
export const tr = (english, chinese) => language === 'zh-CN' ? chinese : english;
const translations = {
  'Get API access': '开通 API',
  '· API usage is separate from CastReader Pro.': '· API 用量与 CastReader Pro 分开计费。',
  '/ Voice Studio': '/ 语音工作室',
  'Interface language': '界面语言',
  'LOCAL APP · 127.0.0.1': '本地应用 · 127.0.0.1',
  'YOUR WORDS, OUT LOUD': '多语言音频工作台',
  'Write it. Hear it. Keep it.': '写下短句，听见声音，保存音频。',
  'Give your words a voice. Write a short script, choose how it sounds, and save an MP3 you can use anywhere.': '让文字拥有声音。写下文本，选择音色，将 MP3 保存到你的设备。',
  'Opening your local workspace…': '正在打开本地工作区…',
  '1. Connect your voice': '1. 连接授权音色',
  'The API key stays in the Node.js server environment.': 'API Key 只保存在 Node.js 服务端环境中。',
  'Load ready voices': '加载可用音色',
  'Authorized voice': '授权音色',
  'Load voices to choose': '请先加载音色',
  'Voice discovery and planning do not generate audio.': '查询音色和制定计划不会生成音频。',
  '2. Write your script': '2. 写下朗读文本',
  '500 characters per clip · Add more clips when you need them': '最多 200 张音频 · 每张最多 500 个规范化字符',
  '+ Add clip': '+ 添加音频',
  'Project title': '项目名称',
  'Choose the language your text is written in. Each clip becomes its own MP3.': '请选择文本本身使用的语言。每段文本将生成独立的 MP3。',
  'Preview cost': '预估费用',
  '3. Review & generate': '3. 确认费用并生成',
  'Preview the cost of your script, then generate when you are ready.': '先保存计划以查看费用，生成时使用已保存的文本与音色。',
  'I approve the displayed maximum cost. Resuming can generate any clips that have not started.': '我同意所示最高费用。恢复时可能生成项目中尚未开始的音频。',
  'Generate audio': '生成音频',
  'Clips generate one at a time. Your progress is saved so you can return later.': '音频逐段生成，进度自动保存，可稍后返回继续。',
  'Saved projects': '已保存项目',
  'Refresh': '刷新',
  'Open a project': '打开原项目',
  'Choose a project': '选择已保存项目',
  'Return to a saved project to play, download, or continue your audio.': '重启后打开同一项目以恢复原任务。失败或过期任务不会自动创建替代任务。',
  'Your audio': '已生成音频',
  'Your studio is ready for its first clip.': '尚未选择项目。',
  'Manifest': '结果清单',
  'Download all · ZIP': '下载全部 · ZIP',
  'Saved clips': '已保存音频',
  'Saved clips will appear here. Replay and download use your local files without generating again.': '已保存音频将显示在这里。播放和下载使用本地文件，不会再次生成。',
  'Powered by CastReader Voice API · Made to be heard.': '由 CastReader Voice API 驱动 · 让文字被听见。',
};
// Capture only the initial static DOM. Dynamic content is rendered with tr().
const staticText = [];
const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
while (walker.nextNode()) {
  const text = walker.currentNode, key = text.textContent.trim();
  if (Object.hasOwn(translations, key)) staticText.push({ text, key });
}
const attributes = [...document.querySelectorAll('[aria-label]')].map(element => ({ element, key: element.getAttribute('aria-label') }));
export function setLanguage(value = language) {
  language = value === 'zh-CN' ? 'zh-CN' : 'en';
  try { localStorage.setItem('voice-studio-ui-language', language); } catch { /* Optional preference only. */ }
  document.documentElement.lang = language;
  document.title = tr('Voice Studio · CastReader', '语音工作室 · CastReader Voice API');
  document.getElementById('ui-language').value = language;
  for (const { text, key } of staticText) if (text.isConnected) text.textContent = tr(key, translations[key]);
  for (const { element, key } of attributes) if (translations[key]) element.setAttribute('aria-label', tr(key, translations[key]));
}
export function errorMessage(code, fallback) {
  const errors = {
    estimate_changed: '提交前价格或余额已变化。请重新预估新项目并确认费用，原任务会保留。',
    job_failed: '音频生成失败。恢复只查询原任务，不会创建替代任务。请查看下方已产生的费用。',
    job_expired: '原任务已过期。本地已保存音频仍可播放。重新生成需要新建项目并查看费用。',
    job_cancelled: '原任务已取消，已完成部分可能仍有费用。恢复不会创建替代任务。',
    missing_key: '请在终端设置 CASTREADER_API_KEY 后重启应用。',
    sdk_unavailable: '请在解压后的示例目录运行 npm install 后重启应用。',
    invalid_api_key: '请检查服务端环境变量 CASTREADER_API_KEY。',
    expired_api_key: '请在服务端环境中更新已过期的密钥。',
    insufficient_scope: '密钥需要 speech:generate、voices:read 和 usage:read 权限。',
    insufficient_balance: '当前余额不足以处理此输入。应用没有发起充值。',
    invalid_voice: '请选择服务端返回的已准备好且获授权的音色。',
    voice_not_found: '此密钥无法使用所选音色。',
    voice_language_unverified: '所选音色尚未启用某个输入语言。',
    text_language_mismatch: '请检查每张音频的语言是否与文本一致。',
    unsupported_language: '当前处理区域不支持某个输入语言。',
    model_limit: '当前处理区域不支持某个输入语言或文本长度。',
    invalid_input: '请使用 1–200 张音频，ID 需唯一且为小写，每张文本为 1–500 个规范化字符。',
    invalid_title: '项目名称应为 1–80 个字符。',
    estimate_unavailable: '某个输入未通过余额估算检查。没有提交生成请求。',
    invalid_estimate: '后端估算结果无效或字符数不匹配，计划已停止。',
    rate_limit_exceeded: 'API 请求频率受限，请稍候再恢复同一项目。',
    admission_paused: '服务暂停接受新任务，请保留项目稍后恢复。',
    batch_running: '已有项目正在处理，请等待后再开始其他项目。',
    batch_locked: '此项目存在 .running 锁。确认旧进程结束后才可手动删除对应锁文件。',
    checkpoint_missing: '已开始的项目丢失了检查点，请恢复原文件后再继续。',
    csrf_denied: '请刷新本地页面以建立新会话。',
    audio_missing: '音频尚未保存或本地文件丢失，请恢复原项目以下载原结果。',
    checksum_mismatch: '本地文件校验失败，请恢复原项目以下载原结果。',
    unsafe_directory: '项目包含符号链接或目录不安全，请恢复原始普通文件后继续。',
    archive_limit: '项目超过 128 MiB ZIP 上限，请分别下载音频和结果清单。',
    operation_stopped: '操作已停止。请保留项目并恢复原任务；若仍无法完成，请检查 API 控制台。',
  };
  return tr(fallback, errors[code] || fallback);
}
setLanguage();
