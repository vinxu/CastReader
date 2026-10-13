import { tr, setLanguage, errorMessage } from './i18n.js';
const $ = id => document.getElementById(id);
let csrfToken, languageNames = {}, cards = [], selected = null, dirty = true, busy = false, poll, catalogData = null, keyConfigured = false, skippedBatchCount = 0;
const players = new Map();
const blobURLs = new Set();
function statusLabel(status) {
  const labels = { planned: '已计划', queued: '排队中', running: '处理中', saved: '已保存', complete: '已完成', paused: '已暂停', succeeded: '已成功', failed: '失败', expired: '已过期', cancelled: '已取消', pending: '待查询', download_pending: '待下载', submission_unknown: '提交结果待确认', not_started: '尚未开始' };
  return tr(status.replaceAll('_', ' '), labels[status] || status);
}
function node(tag, text, className) {
  const value = document.createElement(tag);
  if (text !== undefined) value.textContent = text;
  if (className) value.className = className;
  return value;
}
function notice(message, error = false) { $('notice').textContent = message; $('notice').classList.toggle('error', error); }
async function api(path, { body, binary = false } = {}) {
  const response = await fetch(path, { method: body ? 'POST' : 'GET', cache: 'no-store', headers: { 'X-CSRF-Token': csrfToken, ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
  if (!response.ok) {
    const value = await response.json().catch(() => ({}));
    throw new Error(errorMessage(value.error?.code, value.error?.message || tr(`Local request failed (${response.status}).`, `本地请求失败（${response.status}）。`)));
  }
  return binary ? response.blob() : response.json();
}
function controls() {
  $('plan').disabled = busy || !$('voice').value || cards.length === 0 || !cards.every(card => {
    const text = card.text.replace(/\r\n/g, '\n').normalize('NFC').trim();
    return text.isWellFormed() && Array.from(text).length > 0 && Array.from(text).length <= (catalogData?.maxCharacters || 500) && (!catalogData || catalogData.languages.includes(card.language));
  });
  $('start').disabled = busy || dirty || !selected || selected.status === 'running' || !$('confirm').checked;
  $('confirm').disabled = busy || dirty || !selected || selected.status === 'running';
  $('add').disabled = busy || cards.length >= 200;
  $('connect').disabled = busy;
  $('history').disabled = busy;
  $('start').textContent = !selected || selected.status === 'planned' ? tr('Generate audio', '生成已保存项目') : tr('Resume project', '恢复原项目');
}
async function task(work) {
  if (busy) return;
  busy = true; controls();
  try { await work(); }
  catch (error) { notice(error.message, true); }
  finally { busy = false; controls(); }
}
function edited() { dirty = true; $('confirm').checked = false; controls(); count(); }
function count() {
  const total = cards.reduce((n, card) => n + Array.from(card.text.replace(/\r\n/g, '\n').normalize('NFC').trim()).length, 0);
  $('count').textContent = tr(`${cards.length} ${cards.length === 1 ? 'clip' : 'clips'} · ${total.toLocaleString()} normalized characters`, `${cards.length} 张音频 · ${total.toLocaleString()} 个规范化字符`);
}
function renderCards() {
  $('cards').replaceChildren();
  cards.forEach((card, index) => {
    const item = node('div', undefined, 'card');
    const heading = node('div', undefined, 'card-heading');
    const label = node('label', tr(`Clip ${index + 1} · `, `音频 ${index + 1} · `));
    const select = node('select'); select.setAttribute('aria-label', tr(`Clip ${index + 1} language`, `音频 ${index + 1} 的语言`));
    for (const [language, name] of Object.entries(languageNames)) { const option = node('option', name); option.value = language; select.append(option); }
    select.value = card.language;
    select.addEventListener('change', () => { card.language = select.value; edited(); });
    label.append(select);
    const remove = node('button', tr('Remove', '删除'), 'secondary small'); remove.type = 'button'; remove.setAttribute('aria-label', tr(`Remove clip ${index + 1}`, `删除音频 ${index + 1}`));
    remove.addEventListener('click', () => { cards.splice(index, 1); renderCards(); edited(); });
    heading.append(label, remove);
    const text = node('textarea'); text.value = card.text; text.setAttribute('aria-label', tr(`Clip ${index + 1} text`, `音频 ${index + 1} 的文本`)); text.rows = 5;
    // Server validates Unicode code points; maxlength counts UTF-16 units incorrectly.
    const length = node('span', undefined, 'hint');
    const updateLength = () => {
      const normalized = text.value.replace(/\r\n/g, '\n').normalize('NFC').trim();
      const n = Array.from(normalized).length;
      const limit = catalogData?.maxCharacters || 500;
      length.textContent = tr(`${n} / ${limit} characters`, `${n} / ${limit} 字符`);
      text.setCustomValidity(n < 1 || n > limit || !normalized.isWellFormed() ? tr(`Use 1–${limit} normalized characters.`, `请输入 1–${limit} 个规范化字符。`) : '');
      text.setAttribute('aria-invalid', String(!text.validity.valid));
    };
    text.addEventListener('input', () => { card.text = text.value; updateLength(); edited(); }); updateLength();
    item.append(heading, text, length); $('cards').append(item);
  });
  count(); controls();
}
async function catalog() {
  notice(tr("Loading ready voices from the API through your local server…", "正在通过本地服务从 API 加载可用音色…"));
  const result = await api('/api/catalog');
  catalogData = result;
  const previous = $('voice').value;
  $('voice').replaceChildren(node('option', tr('Choose an authorized voice', '选择授权音色')));
  $('voice').firstChild.value = '';
  result.voices.forEach(voice => { const option = node('option', voice.name); option.value = voice.id; $('voice').append(option); });
  $('voice').value = result.voices.some(voice => voice.id === previous) ? previous : result.voices.find(voice => voice.default)?.id || result.voices[0]?.id || '';
  $('voice').disabled = false;
  if ($('voice').value !== previous) edited();
  renderConnection();
  renderCards();
  notice(result.voices.length ? tr("Choose a voice, write your script, then preview the cost.", "请选择音色、编辑音频，然后保存计划。") : tr("No ready voices returned. Check voice readiness and key permissions in the API console.", "没有返回可用音色，请在 API 控制台检查音色状态和密钥权限。"), !result.voices.length);
}
function renderConnection() {
  if (!catalogData) {
    $('connection-status').textContent = keyConfigured ? tr('A server key is configured. Load the voices available to it.', '服务端密钥已配置，请加载此密钥可用的音色。') : tr('Set CASTREADER_API_KEY in your terminal, then restart npm start. Keep the key out of this page.', '请在终端设置 CASTREADER_API_KEY，然后重启 npm start。请勿把密钥填入网页。');
    return;
  }
  const result = catalogData;
  $('connection-status').textContent = tr(`${result.voices.length} ready ${result.voices.length === 1 ? 'voice' : 'voices'} available. The key stays on the server.`, `已加载 ${result.voices.length} 个可用音色。密钥只保存在服务端。`);
  $('voice-note').textContent = tr(`Region languages: ${result.languages.join(', ')}. Plan limit: ${result.maxCharacters} characters per clip.${result.hasMoreVoices ? ' The SDK shows the first page; additional voices are available in the API console.' : ''}`, `区域支持语言：${result.languages.join('、')}。每张最多 ${result.maxCharacters} 个字符。${result.hasMoreVoices ? 'SDK 仅显示第一页，更多音色可在 API 控制台查看。' : ''}`);
}
async function history() {
  const result = await api('/api/batches');
  const { batches } = result;
  skippedBatchCount = result.skippedBatchCount || 0;
  renderHistoryWarning();
  $('history').replaceChildren(node('option', tr('Choose a project', '选择已保存项目')));
  $('history').firstChild.value = '';
  batches.forEach(batch => { const option = node('option', `${batch.title} · ${new Date(batch.createdAt).toLocaleString()} · ${batch.id.slice(0, 8)}`); option.value = batch.id; $('history').append(option); });
  $('history').value = selected?.id || '';
}
function renderHistoryWarning() {
  $('history-warning').hidden = skippedBatchCount === 0;
  $('history-warning').textContent = skippedBatchCount ? tr(
    `${skippedBatchCount} unreadable or incomplete batch(es) skipped. Their local files are preserved; other batches remain available.`,
    `已跳过 ${skippedBatchCount} 个无法读取或不完整的项目。其本地文件均已保留，其他项目仍可正常打开。`
  ) : '';
}
function revokePlayers() {
  for (const url of blobURLs) URL.revokeObjectURL(url);
  blobURLs.clear(); players.clear(); $('results').replaceChildren();
}
async function download(path, name) {
  const blob = await api(path, { binary: true });
  const url = URL.createObjectURL(blob), link = node('a');
  link.href = url; link.download = name; document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
function renderBatch(value) {
  if (selected?.id !== value.id) revokePlayers();
  selected = value;
  $('plan-summary').replaceChildren(node('p', value.title), node('p', `$${value.estimate.maximumChargeUSD}`, 'cost'), node('p', tr('Estimated maximum · USD before trial credit', '最高估算费用 · 美元，未扣除免费额度'), 'hint cost-label'), node('p', tr(`${value.cards.length} ${value.cards.length === 1 ? 'MP3' : 'MP3s'} · ${value.estimate.characters} characters · ${value.voiceName}`, `${value.cards.length} 个 MP3 · ${value.estimate.characters} 个字符 · ${value.voiceName}`), 'hint'), node('p', tr(value.estimate.note, '费用未扣免费额度。逐张余额检查仅为快照，不预留额度，也不保证整批余额充足；不会重复计算免费额度。'), 'hint'));
  if (value.estimate.rows?.length === 1) {
    const estimate = value.estimate.rows[0];
    $('plan-summary').append(node('p', tr(`Current trial estimate: ${estimate.trialCharacters} characters · $${estimate.estimatedChargeUSD} after trial credit.`, `当前免费额度估算：${estimate.trialCharacters} 字符 · 扣除后 $${estimate.estimatedChargeUSD}。`), 'hint'));
  } else if (value.estimate.rows?.length) {
    const details = node('details'), summary = node('summary', tr('Per-clip trial estimates', '各音频免费额度估算'));
    details.append(summary);
    value.estimate.rows.forEach((row, index) => details.append(node('p', tr(`Clip ${index + 1}: ${row.trialCharacters} trial characters · $${row.estimatedChargeUSD} after trial. Allowances may overlap.`, `音频 ${index + 1}：${row.trialCharacters} 免费字符 · 扣除后 $${row.estimatedChargeUSD}。各项额度可能重叠。`), 'hint')));
    $('plan-summary').append(details);
  }
  $('progress').max = value.rows.length; $('progress').value = value.completed;
  $('progress-label').textContent = tr(`${value.completed} / ${value.rows.length} saved · ${statusLabel(value.status)} · ${value.title}`, `已保存 ${value.completed} / ${value.rows.length} · ${statusLabel(value.status)} · ${value.title}`);
  $('run-error').textContent = (value.error ? errorMessage(value.error.code, value.error.message) : '') || (value.status === 'paused' ? tr("Open the same batch and resume to follow its original jobs. Preserve any locks until the earlier process is confirmed stopped.", "请打开同一项目并恢复原任务。确认旧进程结束之前，请保留所有锁文件。") : tr("Playback and downloads use checksum-verified local files.", "播放和下载均使用经过哈希校验的本地文件。"));
  $('manifest').disabled = $('archive').disabled = value.completed !== value.rows.length;
  value.rows.forEach(row => {
    let view = players.get(row.id);
    if (!view) {
      const item = node('div', undefined, 'result'), info = node('div');
      info.append(node('p', row.text), node('small', `${row.language.toUpperCase()} · ${row.id}`));
      const status = node('span', undefined, 'status'), player = node('div'), receipt = node('small', undefined, 'receipt');
      info.append(receipt);
      const load = node('button', tr('Load player', '加载播放器'), 'secondary small'), save = node('button', tr('Download', '下载'), 'secondary small');
      const batchId = value.id;
      load.addEventListener('click', () => task(async () => {
        const blob = await api(`/api/batches/${batchId}/audio/${row.id}`, { binary: true });
        if (selected?.id !== batchId) return;
        const url = URL.createObjectURL(blob); blobURLs.add(url);
        const audio = node('audio'); audio.controls = true; audio.src = url; audio.setAttribute('aria-label', tr(`Play ${row.id}`, `播放 ${row.id}`));
        audio.addEventListener('error', () => notice(tr('This saved file could not be played. Download it to inspect the audio; playback did not generate again.', '此文件无法播放。可下载检查音频；播放不会再次生成。'), true));
        player.replaceChildren(audio);
        notice(tr("Loaded the saved clip. Playback makes no generation requests.", "已加载保存的音频。播放不会发起生成请求。"));
      }));
      save.addEventListener('click', () => task(() => download(`/api/batches/${batchId}/audio/${row.id}`, `${row.id}.mp3`)));
      player.append(load); item.append(info, status, player, save); $('results').append(item);
      view = { status, load, save, receipt }; players.set(row.id, view);
    }
    view.status.textContent = statusLabel(row.status);
    view.receipt.textContent = row.chargedUSD == null ? '' : tr(`Actual charge: $${row.chargedUSD} · Trial used: ${row.trialCharacters ?? '—'} characters`, `实际费用：$${row.chargedUSD} · 已用免费额度：${row.trialCharacters ?? '—'} 字符`);
    view.load.textContent = tr('Load player', '加载播放器');
    view.save.textContent = tr('Download', '下载');
    view.load.disabled = view.save.disabled = !row.saved;
  });
  controls();
}
function schedulePoll() {
  clearTimeout(poll);
  if (!selected) return;
  const id = selected.id;
  poll = setTimeout(async () => {
    try { const value = await api(`/api/batches/${id}`); if (selected?.id === id) renderBatch(value); }
    catch (error) { notice(tr(`${error.message} Reopen this saved batch when the server is available.`, `${error.message} 服务恢复后，请重新打开此已保存项目。`), true); }
    if (selected?.id === id && selected.status === 'running') schedulePoll();
  }, 1800);
}
async function openBatch(id) {
  if (!id) return;
  const value = await api(`/api/batches/${id}`);
  renderBatch(value);
  cards = value.cards.map(card => ({ ...card })); $('title').value = value.title;
  if (![...$('voice').options].some(option => option.value === value.voiceId)) { const option = node('option', tr(`${value.voiceName} (saved batch)`, `${value.voiceName}（已保存项目）`)); option.value = value.voiceId; $('voice').append(option); }
  $('voice').value = value.voiceId;
  renderCards(); dirty = false; $('confirm').checked = false; controls(); schedulePoll();
  notice(tr("Opened the original batch. Resuming keeps its inputs, voice and saved job checkpoints.", "已打开原项目。恢复时保留其文本、音色和原任务检查点。"));
}
$('ui-language').addEventListener('change', () => {
  setLanguage($('ui-language').value);
  renderConnection();
  renderHistoryWarning();
  renderCards();
  if (selected) renderBatch(selected);
  notice(tr('Interface language changed. Card languages and saved batches are unchanged.', '已切换界面语言。音频语言和已保存项目保持原样。'));
});
$('connect').addEventListener('click', () => task(catalog));
$('refresh').addEventListener('click', () => task(history));
$('history').addEventListener('change', () => task(() => openBatch($('history').value)));
$('voice').addEventListener('change', edited); $('title').addEventListener('input', edited);
$('confirm').addEventListener('change', controls);
$('add').addEventListener('click', () => { cards.push({ id: `card-${crypto.randomUUID()}`, language: 'en', text: '' }); renderCards(); edited(); $('cards').lastChild.querySelector('textarea').focus(); });
$('plan').addEventListener('click', () => task(async () => {
  for (const field of $('cards').querySelectorAll('textarea')) if (!field.reportValidity()) return;
  notice(tr("Checking the voice and estimating every card. No audio is being generated…", "正在检查音色并估算每张卡的费用，没有生成音频…"));
  // Freeze the request now; edits made while estimating must still require a new plan.
  const input = { cards: cards.map(card => ({ ...card })), title: $('title').value, voiceId: $('voice').value };
  const result = await api('/api/batches', { body: input });
  dirty = JSON.stringify(input) !== JSON.stringify({ cards, title: $('title').value, voiceId: $('voice').value });
  $('confirm').checked = false; renderBatch(result); await history();
  notice(dirty ? tr("Plan saved, but the editor changed during estimation. Save another plan for those edits.", "计划已保存，但估算期间编辑内容已改变。请为这些修改保存新计划。") : tr("Plan saved. Review its cost and explicitly approve generation when ready.", "计划已保存。请查看费用，准备好后明确确认生成。"));
}));
$('start').addEventListener('click', () => task(async () => {
  if (dirty || !$('confirm').checked || !selected) return;
  const id = selected.id;
  await api(`/api/batches/${id}/start`, { body: { confirm: true } });
  $('confirm').checked = false; renderBatch(await api(`/api/batches/${id}`)); schedulePoll();
  notice(tr("Following this saved batch. You can close this tab while the local server keeps working.", "正在处理已保存项目。可以关闭此页面，本地服务会继续运行。"));
}));
$('manifest').addEventListener('click', () => task(() => download(`/api/batches/${selected.id}/manifest`, 'manifest.json')));
$('archive').addEventListener('click', () => task(() => download(`/api/batches/${selected.id}/archive`, 'voice-studio-results.zip')));
window.addEventListener('pagehide', () => { clearTimeout(poll); revokePlayers(); });
try {
  const response = await fetch('/api/session', { cache: 'no-store' });
  if (!response.ok) throw new Error(tr("Open the exact http://127.0.0.1 address printed by npm start.", "请打开 npm start 打印的完整 http://127.0.0.1 地址。"));
  const session = await response.json(); csrfToken = session.csrfToken; languageNames = session.languages; cards = session.cards; keyConfigured = session.configured;
  renderCards(); await history();
  renderConnection();
  notice(tr("Ready to edit. Load a voice to preview your cost, or open a saved project to listen.", "可以开始编辑。加载可用音色以制定新计划，或打开已保存项目进行恢复和播放。"));
} catch (error) { notice(error.message, true); }
