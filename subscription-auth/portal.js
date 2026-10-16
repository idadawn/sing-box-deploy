const $ = id => document.getElementById(id);
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
function linkRow(label, path) {
  const box = document.createElement('div'), title = document.createElement('h3'), row = document.createElement('div');
  title.textContent = label; row.className = 'link-row';
  const input = document.createElement('input'), button = document.createElement('button');
  input.readOnly = true; input.type = 'password'; input.value = new URL(path, location.origin).href; input.setAttribute('aria-label', label + '专属链接');
  button.type = 'button'; button.textContent = '复制链接';
  button.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(input.value); message('链接已复制，可粘贴到客户端。'); }
    catch { input.type = 'text'; input.select(); message('请复制已选中的链接。'); }
  });
  row.append(input, button); box.append(title, row); return box;
}
function importActions(entry) {
  const actions = document.createElement('div');
  actions.className = 'import-actions';
  const name = entry.kind === 'tx-direct' ? 'LA 直出' : entry.id;
  for (const [client, label, path, scheme] of [
    ['clash', '导入 Clash', entry.clash, 'clash://install-config'],
    ['v2rayng', '导入 v2rayNG', entry.v2, 'v2rayng://install-config/'],
  ]) {
    const link = document.createElement('a');
    const subscription = new URL(path, location.origin).href;
    link.className = 'client-import ' + client;
    // Encode the whole personal URL so isp/token remain inside the URL parameter.
    link.href = scheme + '?url=' + encodeURIComponent(subscription);
    link.rel = 'noopener noreferrer';
    link.referrerPolicy = 'no-referrer';
    link.textContent = label;
    link.setAttribute('aria-label', name + '：' + label);
    actions.append(link);
  }
  return actions;
}
async function load() {
  const data = await api('/api/me');
  $('accountName').textContent = data.username;
  $('entries').replaceChildren(...data.entries.map(entry => {
    const card = document.createElement('article'); card.className = 'panel';
    const head = document.createElement('div'), title = document.createElement('h2'), expiry = document.createElement('span'), address = document.createElement('p');
    head.className = 'entry-header'; title.textContent = entry.kind === 'tx-direct' ? 'LA 直出' : entry.id;
    expiry.textContent = entry.expires && entry.expires !== 'never' ? '到期 ' + entry.expires : '有效期不限';
    address.className = 'address'; address.textContent = entry.host || '';
    head.append(title, expiry); card.append(head, address, importActions(entry), linkRow('Clash Verge / Mihomo', entry.clash), linkRow('v2rayN / v2rayNG / Shadowrocket', entry.v2));
    if (entry.extension) card.append(linkRow('Clash Verge 全局扩展', entry.extension));
    if (entry.shadowrocket_module) card.append(linkRow('Shadowrocket Telegram 模块', entry.shadowrocket_module));
    return card;
  }));
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
