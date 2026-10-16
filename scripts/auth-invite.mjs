// Offline provisioning only: outputs private files, never tokens/passwords to stdout.
import { mkdirSync, writeFileSync, chmodSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomToken, digest } from '../subscription-auth/auth.mjs';

const [username, scopesCsv, origin, directory = '.auth-private'] = process.argv.slice(2);
const valid = value => /^[a-z0-9][a-z0-9_-]{0,31}$/.test(value || '');
const scopes = [...new Set((scopesCsv || '').split(','))];
if (!valid(username) || !scopes.length || !scopes.every(valid) || !/^https:\/\/[a-z0-9.-]+$/.test(origin || '')) {
  throw new Error('Usage: node scripts/auth-invite.mjs <username> <isp,tx> <https://domain> [private-directory]');
}
const target = resolve(directory); mkdirSync(target, { recursive: true, mode: 0o700 }); chmodSync(target, 0o700);
const invite = randomToken(), expires = Math.floor(Date.now() / 1000) + 86400;
const sql = `INSERT INTO users(username, scopes, invite_hash, invite_expires, token_version, created_at) VALUES ('${username}', '${JSON.stringify(scopes)}', '${await digest(invite)}', ${expires}, '${randomToken()}', ${Math.floor(Date.now() / 1000)});\n`;
writeFileSync(resolve(target, username + '.sql'), sql, { flag: 'wx', mode: 0o600 });
writeFileSync(resolve(target, username + '-invite.txt'), `${origin}/#invite=${invite}\nExpires: ${new Date(expires * 1000).toISOString()}\n`, { flag: 'wx', mode: 0o600 });
console.log(`Created private provisioning files for ${username}. Import its SQL, then deliver its one-time invitation privately. Existing users are never overwritten.`);
