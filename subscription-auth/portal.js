const $ = id => document.getElementById(id);
const KIB = 1024, MIB = KIB ** 2, GIB = KIB ** 3;
let invite = new URLSearchParams(location.hash.slice(1)).get('invite');
if (invite) history.replaceState(null, '', location.pathname); // Never send invitation in Referer/query logs.
function message(text = '', failed = false) { $('message').textContent = text; $('message').className = failed ? 'error' : ''; }
function view(name) { for (const id of ['loginView', 'activateView', 'accountView']) $(id).hidden = id !== name; }
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
  label.className = 'hint'; label.textContent = direct ? '公共流量 · 整机共用' : '个人流量';
  value.className = 'usage-value';
  const limit = (usage?.quota_bytes || (direct ? 1000 : 100) * GIB) / GIB;
  const known = usage?.used_bytes !== null && usage?.used_bytes !== undefined;
  const bytes = usage?.used_bytes;
  const [scale, unit] = bytes >= GIB ? [GIB, 'GB'] : bytes >= MIB ? [MIB, 'MB'] : bytes >= KIB ? [KIB, 'KB'] : [1, 'B'];
  const used = known ? (bytes / scale).toLocaleString('zh-CN', { maximumFractionDigits: 2 }) + ' ' + unit : '—';
  value.textContent = used + ' / ' + limit + ' GB';
  const labels = { initialized: '本月已用', not_connected: '待接入', unavailable: '暂不可用', partial: '部分统计', stale: '待同步', current: '本月已用' };
  status.textContent = usage?.over_quota ? '已超额' : labels[usage?.status || 'not_connected'];
  status.className = 'usage-status' + (usage?.over_quota ? ' over' : '');
  box.append(label, value, status);
  return box;
}
async function load() {
  const data = await api('/api/me');
  $('accountName').textContent = data.username.toUpperCase();
  $('linesHeading').textContent = data.is_admin ? '全部线路' : '我的线路';
  $('entries').replaceChildren(...data.entries.map(entry => {
    const card = document.createElement('article'); card.className = 'panel';
    const head = document.createElement('div'), title = document.createElement('h2'), expiry = document.createElement('span'), address = document.createElement('p');
    const direct = entry.kind === 'tx-direct';
    head.className = 'entry-header'; title.textContent = direct ? '公共直出' : entry.id.toUpperCase();
    expiry.textContent = direct ? '视频 · 下载' : '个人 ISP';
    address.className = 'address'; address.textContent = entry.host || '';
    head.append(title, expiry); card.append(head, usageSummary(entry.usage || (direct ? data.usage?.shared : data.usage?.personal), direct), importActions(entry));
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
  const over = [data.usage?.personal?.over_quota ? '个人流量' : null, data.usage?.shared?.over_quota ? '公共流量' : null].filter(Boolean);
  $('quotaAlert').hidden = !over.length;
  $('quotaAlert').textContent = over.length ? over.join('、') + '已超额，当前仅提醒，不停用。' : '';
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
      else { await api('/api/password', data); form.reset(); view('loginView'); message('密码已修改，请重新登录。'); return; }
      form.reset(); await load(); window.scrollTo({ top: 0 });
    });
  });
}
$('logout').addEventListener('click', event => action(event.currentTarget, async () => { await api('/api/logout', {}); $('entries').replaceChildren(); view('loginView'); }));
$('rotate').addEventListener('click', event => action(event.currentTarget, async () => { await api('/api/rotate-token', {}); await load(); message('链接已重置。请在所有客户端中替换订阅链接。'); }));
if (invite) view('activateView');
else load().catch(error => { view('loginView'); if (error.status !== 401) message(error.message, true); });
