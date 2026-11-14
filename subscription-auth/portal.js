const $ = id => document.getElementById(id);
const KIB = 1024, MIB = KIB ** 2, GIB = KIB ** 3;
const formatTraffic = bytes => {
  if (bytes == null) return '—';
  const [scale, unit] = bytes >= GIB ? [GIB, 'GB'] : bytes >= MIB ? [MIB, 'MB'] : bytes >= KIB ? [KIB, 'KB'] : [1, 'B'];
  return (bytes / scale).toLocaleString('zh-CN', { maximumFractionDigits: 2 }) + ' ' + unit;
};
const localDate = seconds => seconds ? new Date(seconds * 1000).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false }) : '待同步';
let invite = new URLSearchParams(location.hash.slice(1)).get('invite');
let currentUser = null, sessionRevision = 0;
if (invite) history.replaceState(null, '', location.pathname); // Never send invitation in Referer/query logs.
function message(text = '', failed = false) { $('message').textContent = text; $('message').className = failed ? 'error' : ''; }
function view(name) {
  for (const id of ['loginView', 'activateView', 'accountView', 'adminView']) $(id).hidden = id !== name;
  $('pageBadge').textContent = name === 'adminView' ? '管理后台' : '个人空间';
}
async function api(path, data) {
  const response = await fetch(path, { credentials: 'same-origin', cache: 'no-store', ...(data ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) } : {}) });
  const body = await response.json();
  if (!response.ok) { const error = new Error(body.error || '请求失败'); error.status = response.status; throw error; }
  return body;
}
function linkRow(label, path, { sensitive = true, copyLabel = '复制链接' } = {}) {
  const box = document.createElement('div'), title = document.createElement('h3'), row = document.createElement('div');
  title.textContent = label; row.className = 'link-row';
  const input = document.createElement('input'), button = document.createElement('button');
  input.readOnly = true; input.type = sensitive ? 'password' : 'text'; input.value = new URL(path, location.origin).href; input.setAttribute('aria-label', label + (sensitive ? '专属链接' : '链接'));
  button.type = 'button'; button.textContent = copyLabel;
  button.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(input.value); message('链接已复制，可粘贴到客户端。'); }
    catch { input.type = 'text'; input.select(); message('请复制已选中的链接。'); }
  });
  row.append(input, button); box.append(title, row); return box;
}
function importActions(entry) {
  const actions = document.createElement('div');
  actions.className = 'import-actions';
  const name = entry.kind === 'tx-direct' ? '公共直出' : entry.id.toUpperCase();
  for (const [client, label, path, scheme] of [
    ['clash', '导入 Clash', entry.clash, 'clash://install-config'],
    ['v2rayng', '导入 v2rayNG', entry.v2, 'v2rayng://install-config/'],
    ['shadowrocket', '导入 Shadowrocket', entry.shadowrocket || entry.v2, 'shadowrocket://add/sub://'],
  ]) {
    const link = document.createElement('a');
    const subscription = new URL(path, location.origin).href;
    link.className = 'client-import ' + client;
    // Shadowrocket uses a Base64 remote subscription, not a one-off node import.
    // Other clients need the whole personal URL encoded in a single URL parameter.
    link.href = client === 'shadowrocket'
      ? scheme + btoa(subscription) + '?remark=' + encodeURIComponent(name)
      : scheme + '?url=' + encodeURIComponent(subscription);
    link.rel = 'noopener noreferrer';
    link.referrerPolicy = 'no-referrer';
    link.textContent = label;
    link.setAttribute('aria-label', name + '：' + label);
    actions.append(link);
  }
  return actions;
}
function usageSummary(usage, direct) {
  const box = document.createElement('div'); box.className = 'usage-summary';
  const label = document.createElement('p'), value = document.createElement('p'), status = document.createElement('span');
  const provider = direct && usage?.source === 'kiwivm';
  const account = usage?.source === 'account';
  label.className = 'hint'; label.textContent = account ? '个人总流量 · ISP + 公共直出' : provider ? '公共套餐流量 · KiwiVM' : direct ? '公共流量 · 整机共用' : '个人流量';
  value.className = 'usage-value';
  const limit = usage?.quota_bytes == null ? '—' : (usage.quota_bytes / GIB).toLocaleString('zh-CN', { maximumFractionDigits: 2 });
  const known = usage?.used_bytes !== null && usage?.used_bytes !== undefined;
  const bytes = usage?.used_bytes;
  const [scale, unit] = bytes >= GIB ? [GIB, 'GB'] : bytes >= MIB ? [MIB, 'MB'] : bytes >= KIB ? [KIB, 'KB'] : [1, 'B'];
  const used = known ? (bytes / scale).toLocaleString('zh-CN', { maximumFractionDigits: 2 }) + ' ' + unit : '—';
  value.textContent = used + ' / ' + limit + ' GB';
  const labels = { initialized: '本月已用', not_connected: '待接入', unavailable: '暂不可用', partial: '部分统计', stale: '待同步', current: '本月已用' };
  status.textContent = usage?.over_quota ? '已超额' : labels[usage?.status || 'not_connected'];
  if (provider) status.textContent = usage.status === 'current' ? (usage.over_quota ? '套餐流量已用尽' : '本账期已用') : usage.status === 'stale' ? '上次同步用量 · 待同步' : '等待 KiwiVM 数据';
  if (account) status.textContent = usage.status === 'current' ? (usage.over_quota ? '个人额度已用尽' : '本账期已用') : usage.status === 'partial' ? '接入后已用 · 历史未补齐' : usage.status === 'stale' ? '待同步' : '等待个人流量数据';
  status.className = 'usage-status' + (usage?.over_quota ? ' over' : '');
  box.append(label, value, status);
  if (provider) {
    const remaining = document.createElement('p'), reset = document.createElement('p'), updated = document.createElement('p');
    remaining.className = 'usage-remaining';
    remaining.textContent = usage.remaining_bytes == null ? '剩余额度待同步' : '剩余 ' + (usage.remaining_bytes / GIB).toLocaleString('zh-CN', { maximumFractionDigits: 2 }) + ' GB';
    reset.className = updated.className = 'usage-status';
    const date = seconds => new Date(seconds * 1000).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false });
    reset.textContent = usage.reset_at ? '下次重置：' + date(usage.reset_at) + '（北京时间）' : '重置时间待同步';
    if (usage.reset_at && usage.reset_at <= Date.now() / 1000) reset.textContent = '已到重置时间，等待 KiwiVM 确认新账期';
    updated.textContent = usage.observed_at ? '同步于 ' + date(usage.observed_at) + '（北京时间）' : '用量、额度和账期均以 KiwiVM 为准';
    box.append(remaining, reset, updated);
  }
  if (account) {
    for (const text of [
      '上传 ' + formatTraffic(usage.upload_bytes) + ' · 下载 ' + formatTraffic(usage.download_bytes),
      usage.remaining_bytes == null ? '完整剩余额度暂不可确定' : '个人剩余额度 ' + formatTraffic(usage.remaining_bytes),
      '下次重置：' + localDate(usage.reset_at) + '（北京时间）',
      '统计起点：' + localDate(usage.started_at) + '（北京时间）',
      '同步于 ' + localDate(usage.observed_at) + '（北京时间）',
    ]) { const p = document.createElement('p'); p.className = 'usage-status'; p.textContent = text; box.append(p); }
  }
  return box;
}
function compactUsage(usage, shared) {
  const box = document.createElement('div'), label = document.createElement('p'), value = document.createElement('p'), note = document.createElement('p');
  box.className = 'usage-summary'; label.className = 'hint'; value.className = 'usage-value'; note.className = 'usage-status';
  label.textContent = shared ? '大家合计已用' : '我已用';
  value.textContent = formatTraffic(usage?.used_bytes) + (shared ? ' / ' + formatTraffic(usage?.quota_bytes) : '');
  if (shared) {
    note.textContent = usage?.remaining_bytes == null ? '公共剩余额度待同步' : '公共剩余 ' + formatTraffic(usage.remaining_bytes);
    if (usage?.status === 'stale') note.textContent += ' · 待同步';
  } else {
    note.textContent = usage?.status === 'partial' ? '接入后统计' : usage?.status === 'stale' ? '待同步' : usage?.used_bytes == null ? '等待用量数据' : 'ISP + 公共直出';
    if (usage?.status === 'partial') note.title = '历史未补齐；统计起点：' + localDate(usage.started_at) + '（北京时间）';
  }
  box.append(label, value, note); return box;
}
function clearAdmin() {
  for (const id of ['accountOverview', 'adminAccountDetail', 'adminSharedUsage']) $(id).replaceChildren();
  $('adminAccountDetail').hidden = true;
  const all = document.createElement('option'); all.value = ''; all.textContent = '全部账号'; $('adminAccount').replaceChildren(all);
}
function clearSession() {
  sessionRevision++; currentUser = null; clearAdmin();
  for (const id of ['entries', 'personalUsage', 'sharedUsage']) $(id).replaceChildren();
  $('adminLink').hidden = true;
  history.replaceState(null, '', location.pathname + location.search); view('loginView');
}
function accountOverview(overview) {
  const box = $('accountOverview'); box.replaceChildren(); box.hidden = !overview;
  if (!overview) return;
  const heading = document.createElement('h2'); heading.textContent = '各账号总流量 · ISP + 公共直出'; box.append(heading);
  const table = document.createElement('table'), head = document.createElement('thead'), header = document.createElement('tr'), body = document.createElement('tbody');
  for (const text of ['账号', '上传', '下载', '合计', '统计状态', '最近同步']) { const th = document.createElement('th'); th.textContent = text; header.append(th); }
  head.append(header); table.append(head, body);
  for (const { username, usage } of overview.accounts) {
    const row = document.createElement('tr');
    for (const text of [username.toUpperCase(), formatTraffic(usage.upload_bytes), formatTraffic(usage.download_bytes), formatTraffic(usage.used_bytes),
      usage.status === 'current' ? '本账期' : usage.status === 'partial' ? '历史未补齐' : usage.status === 'stale' ? '待同步' : '待接入', localDate(usage.observed_at)]) {
      const td = document.createElement('td'); td.textContent = text; row.append(td);
    }
    body.append(row);
  }
  const wrapper = document.createElement('div'); wrapper.className = 'usage-table'; wrapper.append(table); box.append(wrapper);
  const legacy = document.createElement('p'); legacy.className = 'hint';
  legacy.textContent = '旧节点未归属流量（接入后）：' + formatTraffic(overview.legacy?.used_bytes) + '。旧共享凭据无法识别使用人，请各客户端更新订阅。';
  const note = document.createElement('p'); note.className = 'hint';
  note.textContent = '个人统计上传＋下载业务流量，每笔只计一次。KiwiVM 整机账单还包含两段转发、协议及系统流量；历史未归属部分不分摊到个人。';
  box.append(legacy, note);
}
async function loadAdmin() {
  if (!currentUser?.is_admin) throw new Error('仅管理员可查询账号流量');
  const selected = $('adminAccount').value, revision = sessionRevision, username = currentUser.username;
  try {
    const data = await api('/api/admin/usage' + (selected ? '?account=' + encodeURIComponent(selected) : ''));
    if (revision !== sessionRevision || currentUser?.username !== username || location.hash !== '#admin') return;
    const options = ['', ...data.account_names].map(name => {
      const option = document.createElement('option'); option.value = name; option.textContent = name ? name.toUpperCase() : '全部账号'; return option;
    });
    $('adminAccount').replaceChildren(...options); $('adminAccount').value = selected;
    accountOverview(data);
    $('adminSharedUsage').replaceChildren(usageSummary(data.shared, true));
    $('adminAccountDetail').hidden = !selected;
    $('adminAccountDetail').replaceChildren(...(selected && data.accounts[0] ? [usageSummary(data.accounts[0].usage, false)] : []));
    view('adminView');
  } catch (error) {
    if (error.status === 401) clearSession();
    else if (error.status === 403) {
      clearAdmin(); if (currentUser) currentUser.is_admin = false; $('adminLink').hidden = true;
      history.replaceState(null, '', location.pathname + location.search); view('accountView');
    }
    throw error;
  }
}
async function load() {
  const revision = sessionRevision;
  const data = await api('/api/me');
  if (revision !== sessionRevision) return;
  if (!data.is_admin || currentUser?.username !== data.username) clearAdmin();
  currentUser = { username: data.username, is_admin: data.is_admin };
  $('accountName').textContent = data.username.toUpperCase();
  $('linesHeading').textContent = data.is_admin ? '全部线路' : '我的线路';
  $('adminLink').hidden = !data.is_admin || !data.usage?.account_mode;
  $('personalUsage').replaceChildren(compactUsage(data.usage?.personal, false));
  $('sharedUsage').replaceChildren(compactUsage(data.usage?.shared, true));
  $('entries').replaceChildren(...data.entries.map(entry => {
    const card = document.createElement('article'); card.className = 'panel';
    const head = document.createElement('div'), title = document.createElement('h2'), expiry = document.createElement('span'), address = document.createElement('p');
    const direct = entry.kind === 'tx-direct';
    head.className = 'entry-header'; title.textContent = direct ? '公共直出' : entry.id.toUpperCase();
    expiry.textContent = direct ? '视频 · 下载' : '个人 ISP';
    address.className = 'address'; address.textContent = entry.host || '';
    head.append(title, expiry); card.append(head);
    if (data.usage?.account_mode) { const hint = document.createElement('p'); hint.className = 'hint'; hint.textContent = '使用此节点的流量统一计入你的个人总量。'; card.append(hint); }
    card.append(importActions(entry));
    const links = document.createElement('details'), summary = document.createElement('summary');
    summary.textContent = '链接与模块'; links.className = 'subscription-details';
    links.append(summary, address, linkRow('Clash', entry.clash), linkRow('v2rayN / v2rayNG / Shadowrocket', entry.v2));
    if (entry.extension) links.append(linkRow('Clash Verge 全局扩展', entry.extension));
    if (entry.shadowrocket_module) {
      const module = linkRow('Telegram 分流模块（可选）', entry.shadowrocket_module, { sensitive: false, copyLabel: '复制模块' });
      const help = document.createElement('p');
      help.className = 'hint';
      help.textContent = 'Shadowrocket“配置 → 模块”中添加。Telegram 已能正常走代理时可不加。';
      module.append(help); links.append(module);
    }
    card.append(links);
    return card;
  }));
  $('quotaAlert').hidden = !data.usage?.shared?.over_quota;
  $('quotaAlert').textContent = data.usage?.shared?.over_quota ? '公共套餐流量已用尽，供应商可能暂停服务。' : '';
  $('billingCycle').textContent = data.usage?.shared?.source === 'kiwivm'
    ? '公共套餐全员共用，用量与账期以 KiwiVM 为准。' : '公共额度全员共用。';
  if (location.hash === '#admin' && data.is_admin && data.usage?.account_mode) { await loadAdmin(); return; }
  if (location.hash === '#admin') { history.replaceState(null, '', location.pathname + location.search); message('没有流量后台访问权限', true); }
  view('accountView');
}
async function action(button, task) {
  button.disabled = true; message();
  try { await task(); } catch (error) { message(error.message, true); } finally { button.disabled = false; }
}
for (const id of ['loginForm', 'activateForm', 'passwordForm']) {
  $(id).addEventListener('submit', event => {
    event.preventDefault(); const form = event.currentTarget, data = Object.fromEntries(new FormData(form));
    action(form.querySelector('button'), async () => {
      if (id === 'activateForm') {
        if (data.password !== data.confirmation) throw new Error('两次输入的密码不一致');
        await api('/api/activate', { password: data.password, invite }); invite = null;
      } else if (id === 'loginForm') await api('/api/login', data);
      else { await api('/api/password', data); form.reset(); clearSession(); message('密码已修改，请重新登录。'); return; }
      form.reset(); await load(); window.scrollTo({ top: 0 });
    });
  });
}
$('logout').addEventListener('click', event => action(event.currentTarget, async () => { await api('/api/logout', {}); clearSession(); }));
$('refreshUsage').addEventListener('click', event => action(event.currentTarget, load));
$('refreshAdmin').addEventListener('click', event => action(event.currentTarget, loadAdmin));
$('adminAccount').addEventListener('change', event => action(event.currentTarget, loadAdmin));
$('backToAccount').addEventListener('click', () => { location.hash = ''; });
window.addEventListener('hashchange', () => { message(); load().catch(error => { if (error.status === 401) clearSession(); else message(error.message, true); }); });
$('rotate').addEventListener('click', event => action(event.currentTarget, async () => { await api('/api/rotate-token', {}); await load(); message('链接已重置。请在所有客户端中替换订阅链接。'); }));
if (invite) view('activateView');
else load().catch(error => { if (error.status === 401) clearSession(); else { view('loginView'); message(error.message, true); } });
