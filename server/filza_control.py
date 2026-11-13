import traceback
#!/usr/bin/env python3
import os, json, sqlite3, secrets, hashlib, hmac, time, mimetypes, urllib.parse, urllib.request, urllib.error, http.client, fcntl
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DB_PATH = Path(os.getenv('FILZA_DB', '/var/lib/filza-control/filza.db'))
LEGACY_LICENSE_DB = Path('/opt/m3sb/m3sb.db')
FILES_DIR = Path(os.getenv('FILZA_FILES', '/var/lib/filza-control/files'))
PUBLIC_BASE = os.getenv('PUBLIC_BASE_URL', 'https://martins-license.duckdns.org/external').rstrip('/')
BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN', '')
ADMIN_IDS = {int(x) for x in os.getenv('TELEGRAM_ADMIN_IDS', '').split(',') if x.strip().isdigit()}
APP_ID = os.getenv('FILZA_APP_ID', 'FILZA_EXTERNAL_0B55')
CATEGORIES = {'TEXTURAS', 'HOLOGRAMAS', 'OUTROS', 'FF NORMAL', 'FF MAX', 'AP'}
OFFSET_FILE = Path(os.getenv('FILZA_BOT_OFFSET', '/var/lib/filza-control/telegram.offset'))
BOT_LOCK_FILE = Path(os.getenv('FILZA_BOT_LOCK', '/var/lib/filza-control/telegram.bot.lock'))


def now(): return datetime.now(timezone.utc)
def iso(dt): return dt.astimezone(timezone.utc).isoformat()
def db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True); FILES_DIR.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DB_PATH); c.row_factory = sqlite3.Row; return c

def init_db():
    with db() as c:
        c.executescript('''
        CREATE TABLE IF NOT EXISTS keys(id INTEGER PRIMARY KEY, key_hash TEXT UNIQUE NOT NULL, key_hint TEXT NOT NULL, created_at TEXT NOT NULL, expires_at TEXT, active INTEGER NOT NULL DEFAULT 1, hwid TEXT, telegram_user INTEGER, note TEXT);
        CREATE TABLE IF NOT EXISTS items(id INTEGER PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL, rank INTEGER NOT NULL DEFAULT 0, filename TEXT NOT NULL, path TEXT NOT NULL, image_path TEXT, created_at TEXT NOT NULL, downloads INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS download_tokens(token_hash TEXT PRIMARY KEY, item_id INTEGER NOT NULL, expires_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS online_sessions(device_hash TEXT PRIMARY KEY, key_hash TEXT NOT NULL, last_seen REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS online_sessions_last_seen_idx ON online_sessions(last_seen);
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, event TEXT NOT NULL, subject TEXT, actor TEXT, created_at TEXT NOT NULL, meta TEXT);
        CREATE TABLE IF NOT EXISTS operators(user_id INTEGER PRIMARY KEY, display_name TEXT, created_at TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS user_profiles(user_id INTEGER PRIMARY KEY, display_name TEXT NOT NULL, key_prefix TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS control_state(name TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '');
        ''')
        c.execute("INSERT OR IGNORE INTO control_state(name,value) VALUES('ipa_locked','0')")
        c.execute("INSERT OR IGNORE INTO control_state(name,value) VALUES('lock_message','')")
        c.execute("INSERT OR IGNORE INTO control_state(name,value) VALUES('global_message','')")
        try: c.execute('ALTER TABLE items ADD COLUMN image_path TEXT')
        except sqlite3.OperationalError: pass
        for statement in (
            'ALTER TABLE operators ADD COLUMN key_days INTEGER NOT NULL DEFAULT 30',
            'ALTER TABLE operators ADD COLUMN key_prefix TEXT NOT NULL DEFAULT "KEY"',
            'ALTER TABLE operators ADD COLUMN manage_files INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE operators ADD COLUMN manage_people INTEGER NOT NULL DEFAULT 0',
        ):
            try: c.execute(statement)
            except sqlite3.OperationalError: pass

def hashv(v): return hashlib.sha256(v.encode()).hexdigest()
def log_event(event, subject='', actor='', meta=None):
    with db() as c: c.execute('INSERT INTO events(event,subject,actor,created_at,meta) VALUES(?,?,?,?,?)', (event, subject, actor, iso(now()), json.dumps(meta or {})))

def transport_key(license_key, item_id):
    return hashlib.sha256(f"filza-transport-v1:{license_key}:{item_id}".encode()).digest()
def encrypt_download(data, license_key, item_id, filename):
    nonce = secrets.token_bytes(12)
    aad = f"{item_id}:{filename}".encode()
    ciphertext = AESGCM(transport_key(license_key, item_id)).encrypt(nonce, data, aad)
    return b"FPT1" + nonce + ciphertext

def json_response(h, status, obj):
    b = json.dumps(obj, ensure_ascii=False).encode(); h.send_response(status); h.send_header('Content-Type','application/json'); h.send_header('Content-Length', str(len(b))); h.end_headers(); h.wfile.write(b)
def body(h):
    n = int(h.headers.get('Content-Length', '0')); return json.loads(h.rfile.read(n) or b'{}')

def active_key(row):
    if not row or not row['active']: return False
    return not row['expires_at'] or datetime.fromisoformat(row['expires_at']) > now()

def active_keys_count():
    # This endpoint belongs exclusively to this backend/database.
    # Do not include keys from legacy or another bot.
    with db() as c:
        return sum(active_key(r) for r in c.execute('SELECT * FROM keys').fetchall())

ONLINE_SESSION_TTL_SECONDS = 90

def online_keys_count():
    """Same metric as the bot: active, non-expired keys bound to a device."""
    with db() as c:
        rows = c.execute("SELECT * FROM keys").fetchall()
    return sum(1 for row in rows if row["hwid"] and active_key(row))

def online_devices_count():
    cutoff = time.time() - ONLINE_SESSION_TTL_SECONDS
    with db() as c:
        rows = c.execute(
            'SELECT s.device_hash,k.active,k.expires_at FROM online_sessions s '
            'JOIN keys k ON k.key_hash=s.key_hash WHERE s.last_seen>=?',
            (cutoff,),
        ).fetchall()
    return len({row['device_hash'] for row in rows if active_key(row)})

def legacy_license_key(key, hwid, activate=True):
    """Validate a key issued by the older @FilzaBypassKey_bot database.

    The IPA uses this external service, while the bot historically wrote
    license_keys to /opt/m3sb/m3sb.db. Keep the external service database
    independent and bridge only this validation operation.
    """
    if not LEGACY_LICENSE_DB.is_file():
        return None
    con = sqlite3.connect(LEGACY_LICENSE_DB)
    con.row_factory = sqlite3.Row
    try:
        row = con.execute(
            'SELECT key_code,duration_sec,status,expires_at,hwid,created_by '
            'FROM license_keys WHERE key_code=?', (key,)
        ).fetchone()
        if not row or row['status'] not in ('unused', 'used'):
            return None
        # Catalog checks are read-only: an unused legacy key must first be
        # activated through the normal POST validation endpoint.
        if not activate and row['status'] != 'used':
            return None
        stored_hwid = str(row['hwid'] or '').strip()
        incoming_hwid = str(hwid or '').strip()
        if stored_hwid and incoming_hwid and stored_hwid != incoming_hwid:
            return {'valid': False, 'message': 'Key bound to another device'}
        if not activate and stored_hwid and not incoming_hwid:
            return {'valid': False, 'message': 'Device id required for legacy key'}
        expires = row['expires_at']
        duration = int(row['duration_sec'] or 0)
        lifetime = duration == 0
        if row['status'] == 'unused' and not lifetime:
            expires = (now() + timedelta(seconds=duration)).strftime('%Y-%m-%d %H:%M:%S')
        if row['status'] == 'used' and expires and not lifetime:
            try:
                if datetime.strptime(str(expires), '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc) <= now():
                    if activate:
                        con.execute("UPDATE license_keys SET status='expired' WHERE key_code=?", (key,))
                        con.commit()
                    return None
            except (TypeError, ValueError):
                return None
        if row['status'] == 'unused' and activate:
            if incoming_hwid:
                con.execute('UPDATE license_keys SET status=\'used\', used_at=datetime(\'now\'), expires_at=?, hwid=? WHERE key_code=?', (expires, incoming_hwid, key))
            else:
                con.execute("UPDATE license_keys SET status='used', used_at=datetime('now'), expires_at=? WHERE key_code=?", (expires, key))
            con.commit()
        return {
            'valid': True,
            'message': 'Activated successfully',
            'expiresAt': expires,
            'expiration': expires,
            'type': 'lifetime' if lifetime else 'temporary',
            'lifetime': lifetime,
        }
    finally:
        con.close()

def reseller_license_key(key, hwid=''):
    """Read-only compatibility with the reseller-panel key databases."""
    for path in (Path('/opt/martins-proxy/ProjetoMartinsCompleto/m3sb.db'),
                 Path('/opt/martins-proxy/ProjetoMartinsCompleto/scripts/m3sb.db')):
        if not path.is_file():
            continue
        con=sqlite3.connect(path); con.row_factory=sqlite3.Row
        try:
            cols={r[1] for r in con.execute('PRAGMA table_info(license_keys)')}
            if not {'key','is_active','expires_at'}.issubset(cols): continue
            row=con.execute('SELECT key,is_active,expires_at FROM license_keys WHERE key=?',(key,)).fetchone()
            if not row or not bool(row['is_active']): continue
            expires=row['expires_at']
            if expires:
                raw=str(expires).strip().replace('Z','+00:00')
                try: exp=datetime.fromisoformat(raw)
                except ValueError:
                    try: exp=datetime.strptime(str(expires),'%Y-%m-%d %H:%M:%S')
                    except ValueError: return None
                if exp.tzinfo is None: exp=exp.replace(tzinfo=timezone.utc)
                if exp <= now(): return None
                expires=exp.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            return {'valid':True,'message':'Activated successfully','expiresAt':expires,
                    'expiration':expires,'type':'lifetime' if not expires else 'temporary',
                    'lifetime':not bool(expires)}
        finally: con.close()
    return None

def get_control(name, default=''):
    with db() as c:
        row=c.execute('SELECT value FROM control_state WHERE name=?', (name,)).fetchone()
    return row['value'] if row else default

def set_control(name, value, actor=''):
    with db() as c:
        c.execute('INSERT INTO control_state(name,value) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value', (name, value))
    log_event('control_updated', name, str(actor), {'value': value[:160]})

def authorized_request(handler, allow_legacy=False):
    """Authorize API/catalog requests using the current v2 key store first.

    Catalog access must have the same authorization semantics as v2 validation:
    any active key in this namespace is accepted, including a key that was
    issued by the current system and has never existed in the legacy database.
    The legacy lookup remains an explicit compatibility fallback only.
    """
    key = (handler.headers.get('X-Filza-Key') or '').strip()
    if not key:
        return None
    device_id = (handler.headers.get('X-Filza-Device') or '').strip()
    with db() as c:
        row = c.execute('SELECT * FROM keys WHERE key_hash=?', (hashv(key),)).fetchone()
        if row:
            if not active_key(row):
                return None
            stored_hwid = str(row['hwid'] or '').strip()
            if stored_hwid and device_id and stored_hwid != device_id:
                return None
            if stored_hwid and not device_id:
                return None
            return row
    if not allow_legacy:
        return None
    legacy = legacy_license_key(key, device_id, activate=False)
    if legacy and legacy.get('valid'):
        return {'legacy': True, 'key_hash': hashv(key)}
    reseller = reseller_license_key(key, device_id)
    if reseller and reseller.get('valid'):
        return {'reseller': True, 'key_hash': hashv(key)}
    return None

def catalog():
    with db() as c:
        rows = c.execute('SELECT * FROM items WHERE active=1 ORDER BY category, rank, id').fetchall(); out=[]
        for r in rows:
            t = secrets.token_urlsafe(32); exp = now() + timedelta(minutes=10)
            c.execute('INSERT INTO download_tokens(token_hash,item_id,expires_at) VALUES(?,?,?)', (hashv(t), r['id'], iso(exp)))
            image_url = f'{PUBLIC_BASE}/v1/catalog/image/{r["id"]}?t={urllib.parse.quote(t)}' if r['image_path'] else None
            out.append({'id': str(r['id']), 'name': r['name'], 'img': image_url, 'url': f'{PUBLIC_BASE}/v1/catalog/download/{r["id"]}?t={urllib.parse.quote(t)}', 'file': r['filename'], 'cat': r['category'], 'extra': False, 'rank': r['rank']})
        c.execute('DELETE FROM download_tokens WHERE expires_at < ?', (iso(now()),)); return out

def items_page_text(page=0):
    page=max(0, int(page)); limit=8; offset=page*limit
    with db() as c:
        rows=c.execute('SELECT id,name,category,rank,filename,downloads FROM items WHERE active=1 ORDER BY category,rank,id LIMIT ? OFFSET ?', (limit, offset)).fetchall()
        total=c.execute('SELECT COUNT(*) AS n FROM items WHERE active=1').fetchone()['n']
    if not rows: return '📦 Nenhum arquivo .3105 publicado.', back_button()
    lines=[f'📦 Arquivos .3105 publicados — página {page+1}/{max(1,(total+limit-1)//limit)}\n']
    for r in rows:
        lines.append(f'• #{r["id"]} — {r["name"]}\n  Categoria: {r["category"]} | Rank: {r["rank"]} | Downloads: {r["downloads"]}')
    nav=[]
    if page > 0: nav.append({'text':'⬅️ Anterior', 'callback_data':f'items_page:{page-1}'})
    if offset + limit < total: nav.append({'text':'Próxima ➡️', 'callback_data':f'items_page:{page+1}'})
    delete_rows=[[{'text':f'🔎 Ver #{r["id"]}', 'callback_data':f'item_view:{r["id"]}'}, {'text':'✏️ Renomear', 'callback_data':f'item_rename_ask:{r["id"]}'}, {'text':'🗑️ Excluir', 'callback_data':f'item_delete_ask:{r["id"]}'}] for r in rows]
    markup={'inline_keyboard': ([nav] if nav else []) + delete_rows + [[{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]]}
    return '\n'.join(lines), markup

def delete_item_by_id(item_id, actor=''):
    try: item_id=int(item_id)
    except (TypeError, ValueError): return None
    with db() as c:
        row=c.execute('SELECT * FROM items WHERE id=? AND active=1', (item_id,)).fetchone()
        if not row: return None
        c.execute('DELETE FROM download_tokens WHERE item_id=?', (item_id,))
        c.execute('DELETE FROM items WHERE id=?', (item_id,))
    for asset_key in ('path', 'image_path'):
        asset = row[asset_key]
        if not asset: continue
        path=Path(asset)
        try:
            if path.is_file() and path.resolve().parent == FILES_DIR.resolve(): path.unlink()
        except OSError:
            pass
    log_event('item_deleted', str(item_id), str(actor), {'filename': row['filename'], 'name': row['name']})
    return row

class API(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        p = urllib.parse.urlparse(self.path); path = p.path
        if path == '/v1/ipa_lock': return json_response(self, 200, {'active': get_control('ipa_locked') == '1', 'message': get_control('lock_message') or None})
        if path == '/v1/check_msg': return json_response(self, 200, {'msg_id': 1 if get_control('global_message') else 0, 'message': get_control('global_message') or None})
        if path == '/v1/catalog':
            if not authorized_request(self, allow_legacy=True): return json_response(self, 401, {'detail':'active key required'})
            return json_response(self, 200, {'items': catalog()})
        if path == '/v2/filza/keys/online-count':
            online_count = online_keys_count()
            return json_response(self, 200, {'online_count': online_count, 'online_keys': online_count, 'online_devices': online_count})
        if path in ('/v1/active_keys_count', '/v2/filza/keys/active-count'):
            key_count = active_keys_count()
            return json_response(self, 200, {'active_keys': key_count, 'count': key_count})
        if path.startswith('/v1/catalog/image/'):
            try: item_id = int(path.rsplit('/',1)[1]); token = urllib.parse.parse_qs(p.query).get('t',[''])[0]
            except Exception: return json_response(self, 400, {'detail':'invalid image'})
            with db() as c:
                r = c.execute('SELECT i.*, d.expires_at FROM items i JOIN download_tokens d ON d.item_id=i.id WHERE i.id=? AND d.token_hash=? AND i.active=1', (item_id, hashv(token))).fetchone()
                if not r or datetime.fromisoformat(r['expires_at']) <= now(): return json_response(self, 404, {'detail':'expired image'})
                f = Path(r['image_path']) if r['image_path'] else None
                if not f or not f.is_file(): return json_response(self, 404, {'detail':'image unavailable'})
                data=f.read_bytes()
            self.send_response(200); self.send_header('Content-Type', mimetypes.guess_type(f.name)[0] or 'image/jpeg'); self.send_header('Cache-Control', 'private, max-age=300'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if path.startswith('/v1/catalog/download/'):
            if not authorized_request(self, allow_legacy=True): return json_response(self, 401, {'detail':'active key required'})
            try: item_id = int(path.rsplit('/',1)[1]); token = urllib.parse.parse_qs(p.query).get('t',[''])[0]
            except Exception: return json_response(self, 400, {'detail':'invalid download'})
            with db() as c:
                r = c.execute('SELECT i.*, d.expires_at FROM items i JOIN download_tokens d ON d.item_id=i.id WHERE i.id=? AND d.token_hash=? AND i.active=1', (item_id, hashv(token))).fetchone()
                if not r or datetime.fromisoformat(r['expires_at']) <= now(): return json_response(self, 404, {'detail':'expired download'})
                f = Path(r['path']);
                if not f.is_file(): return json_response(self, 404, {'detail':'file unavailable'})
                data=f.read_bytes(); c.execute('UPDATE items SET downloads=downloads+1 WHERE id=?',(item_id,))
                license_key = (self.headers.get('X-Filza-Key') or '').strip()
                if self.headers.get('X-Filza-Transport') == '1':
                    data = encrypt_download(data, license_key, item_id, r['filename'])
            self.send_response(200); self.send_header('Content-Type', mimetypes.guess_type(r['filename'])[0] or 'application/octet-stream'); self.send_header('Content-Disposition', f'attachment; filename="{r["filename"]}"'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        return json_response(self, 404, {'detail':'not found'})
    def do_POST(self):
        p = urllib.parse.urlparse(self.path)
        if p.path == '/v2/filza/keys/heartbeat':
            key_row = authorized_request(self)
            if not key_row:
                return json_response(self, 401, {'ok': False, 'detail': 'active key required'})
            device_id = (self.headers.get('X-Filza-Device') or '').strip()
            if not (16 <= len(device_id) <= 128) or not all(ch.isalnum() or ch in '-_' for ch in device_id):
                return json_response(self, 400, {'ok': False, 'detail': 'valid device id required'})
            with db() as c:
                c.execute(
                    'INSERT INTO online_sessions(device_hash,key_hash,last_seen) VALUES(?,?,?) '
                    'ON CONFLICT(device_hash) DO UPDATE SET key_hash=excluded.key_hash,last_seen=excluded.last_seen',
                    (hashv(device_id), key_row['key_hash'], time.time()),
                )
                c.execute('DELETE FROM online_sessions WHERE last_seen<?', (time.time() - 7 * 24 * 60 * 60,))
            return json_response(self, 200, {'ok': True})
        if p.path != '/v2/filza/keys/validate': return json_response(self, 404, {'valid':False})
        try: x=body(self); key=str(x.get('key','')).strip(); app=str(x.get('app_id','')); hwid=str(x.get('hwid',''))
        except Exception: return json_response(self, 400, {'valid':False,'detail':'invalid json'})
        if app != APP_ID or not key: return json_response(self, 200, {'valid':False,'message':'Invalid access key'})
        with db() as c:
            r=c.execute('SELECT * FROM keys WHERE key_hash=?',(hashv(key),)).fetchone()
            if not active_key(r):
                legacy = legacy_license_key(key, hwid)
                if legacy is not None:
                    return json_response(self, 200, legacy)
                reseller = reseller_license_key(key, hwid)
                if reseller is not None:
                    return json_response(self, 200, reseller)
                return json_response(self, 200, {'valid':False,'message':'Invalid or expired access key'})
            if r['hwid'] and hwid and r['hwid'] != hwid: return json_response(self, 200, {'valid':False,'message':'Key bound to another device'})
            if hwid and not r['hwid']: c.execute('UPDATE keys SET hwid=? WHERE id=?',(hwid,r['id']))
            return json_response(self, 200, {'valid':True,'message':'Activated successfully','expiresAt':r['expires_at'],'expiration':r['expires_at'],'type':'lifetime' if not r['expires_at'] else 'temporary','lifetime':not bool(r['expires_at'])})


TG_CONNECTION=None
def tg(method, payload=None):
    global TG_CONNECTION
    data=urllib.parse.urlencode(payload or {}).encode(); path=f'/bot{BOT_TOKEN}/{method}'
    for attempt in (1,2):
        try:
            if TG_CONNECTION is None: TG_CONNECTION=http.client.HTTPSConnection('api.telegram.org', timeout=35)
            TG_CONNECTION.request('POST', path, body=data, headers={'Content-Type':'application/x-www-form-urlencoded','Connection':'keep-alive'})
            response=TG_CONNECTION.getresponse(); raw=response.read()
            if response.status >= 500: raise RuntimeError(f'Telegram HTTP {response.status}')
            return json.loads(raw)
        except Exception:
            try:
                if TG_CONNECTION: TG_CONNECTION.close()
            except Exception: pass
            TG_CONNECTION=None
            if attempt == 2: raise
def tg_send(chat, text, markup=None, parse_mode=None):
    try:
        p={'chat_id':chat, 'text':text}
        if markup: p['reply_markup']=json.dumps(markup, ensure_ascii=False)
        if parse_mode: p['parse_mode']=parse_mode
        tg('sendMessage', p)
    except Exception: pass

def tg_edit(chat, message_id, text, markup=None, parse_mode=None):
    try:
        p={'chat_id':chat, 'message_id':message_id, 'text':text}
        if markup: p['reply_markup']=json.dumps(markup, ensure_ascii=False)
        if parse_mode: p['parse_mode']=parse_mode
        tg('editMessageText', p)
    except Exception: pass

def tg_answer(callback_id):
    try: tg('answerCallbackQuery', {'callback_query_id': callback_id})
    except Exception: pass

def back_button(): return {'inline_keyboard': [[{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]]}
def key_state(row):
    if not row['active']: return 'REVOGADA'
    if row['expires_at'] and datetime.fromisoformat(row['expires_at']) <= now(): return 'EXPIRADA'
    return 'ATIVA'

def operator_profile(uid):
    with db() as c:
        row=c.execute('SELECT user_id,key_days,key_prefix,display_name,active,manage_files,manage_people FROM operators WHERE user_id=? AND active=1', (uid,)).fetchone()
    return row

def can_manage_files(uid):
    if uid in ADMIN_IDS: return True
    profile=operator_profile(uid)
    return bool(profile and profile['manage_files'])

def can_manage_people(uid):
    if uid in ADMIN_IDS: return True
    profile=operator_profile(uid)
    return bool(profile and profile['manage_people'])

def keys_report_text(uid=None):
    with db() as c:
        if uid in ADMIN_IDS:
            rows=c.execute('SELECT * FROM keys').fetchall()
        else:
            rows=c.execute('SELECT * FROM keys WHERE telegram_user=?', (uid,)).fetchall()
    counts={state: sum(key_state(r) == state for r in rows) for state in ('ATIVA','EXPIRADA','REVOGADA')}
    bound=sum(bool(r['hwid']) for r in rows if key_state(r) == 'ATIVA')
    return (f'📊 Relatório completo de keys\n\n'
            f'🟢 Ativas: {counts["ATIVA"]}\n'
            f'🟡 Expiradas: {counts["EXPIRADA"]}\n'
            f'🔴 Revogadas: {counts["REVOGADA"]}\n'
            f'📦 Total geradas: {len(rows)}\n'
            f'📱 Ativas vinculadas a HWID: {bound}\n'
            f'🔓 Ativas disponíveis: {counts["ATIVA"] - bound}')

def copy_keys_markup(keys):
    """Use Telegram's native copy button so tapping a key copies its full value."""
    return {'inline_keyboard': [[{'text':key, 'copy_text':{'text':key}}] for key in keys]}

def user_profile(uid):
    with db() as c:
        return c.execute('SELECT user_id,display_name,key_prefix FROM user_profiles WHERE user_id=?', (uid,)).fetchone()

def save_user_profile(uid, display_name, key_prefix):
    stamp=iso(now())
    with db() as c:
        c.execute('INSERT INTO user_profiles(user_id,display_name,key_prefix,created_at,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET display_name=excluded.display_name,key_prefix=excluded.key_prefix,updated_at=excluded.updated_at', (uid, display_name, key_prefix, stamp, stamp))

def configured_key_prefix(uid, fallback='KEY'):
    personal=user_profile(uid)
    if personal: return personal['key_prefix']
    profile=operator_profile(uid)
    if profile: return profile['key_prefix']
    return fallback

def _key_duration_label(row):
    if not row['expires_at']:
        return '∞'
    try:
        created=datetime.fromisoformat(row['created_at'])
        expires=datetime.fromisoformat(row['expires_at'])
        seconds=max(0, int((expires-created).total_seconds()))
        if seconds % 86400 == 0: return f'{seconds // 86400}d'
        if seconds % 3600 == 0: return f'{seconds // 3600}h'
        return f'{max(1, seconds // 60)}m'
    except Exception:
        return '?'

def _global_key_status(row):
    if not row['active'] or (row['expires_at'] and datetime.fromisoformat(row['expires_at']) <= now()):
        return '❌', 'EXPIRADA'
    if row['hwid']:
        return '✅', 'ATIVA'
    return '⏳', 'PENDENTE'

def keys_page_text(page=0, uid=None):
    page=max(0, int(page)); limit=18; offset=page*limit
    with db() as c:
        # Only the owner/admin gets the global view. Operators see only their
        # own generated keys, while the owner sees every operator's keys.
        if uid in ADMIN_IDS:
            rows=c.execute('SELECT * FROM keys ORDER BY id DESC LIMIT ? OFFSET ?', (limit, offset)).fetchall()
            total=c.execute('SELECT COUNT(*) AS n FROM keys').fetchone()['n']
        else:
            rows=c.execute('SELECT * FROM keys WHERE telegram_user=? ORDER BY id DESC LIMIT ? OFFSET ?', (uid, limit, offset)).fetchall()
            total=c.execute('SELECT COUNT(*) AS n FROM keys WHERE telegram_user=?', (uid,)).fetchone()['n']
    if not rows: return '📋 Nenhuma key gerada.', back_button()
    pages=max(1,(total+limit-1)//limit)
    lines=[f'📋 TODAS AS KEYS GERADAS' if uid in ADMIN_IDS else '📋 SUAS KEYS GERADAS', f'Página {page+1}/{pages} · Total: {total}\n']
    for r in rows:
        icon, _ = _global_key_status(r)
        duration=_key_duration_label(r)
        # key_hint is intentionally a non-reversible suffix, not a plaintext key.
        lines.append(f'{icon} ...{r["key_hint"]} · {duration}')
    nav=[]
    if page > 0: nav.append({'text':'⬅️ Anterior', 'callback_data':f'keys_page:{page-1}'})
    if offset + limit < total: nav.append({'text':'Próxima ➡️', 'callback_data':f'keys_page:{page+1}'})
    delete_rows=[[{'text':f'🗑️ Excluir ...{r["key_hint"]}', 'callback_data':f'delete_ask:{r["key_hint"]}'}] for r in rows]
    markup={'inline_keyboard': ([nav] if nav else []) + delete_rows + [[{'text':'📊 ESTATÍSTICAS DO SISTEMA', 'callback_data':'keys_report'}], [{'text':'↩️ Voltar', 'callback_data':'keys_menu'}]]}
    return '\n'.join(lines), markup

def global_keys_report_text():
    with db() as c:
        rows=c.execute('SELECT * FROM keys').fetchall()
    total=len(rows)
    expired=sum(1 for r in rows if (not r['active']) or (r['expires_at'] and datetime.fromisoformat(r['expires_at']) <= now()))
    active=sum(1 for r in rows if r['active'] and not (r['expires_at'] and datetime.fromisoformat(r['expires_at']) <= now()) and r['hwid'])
    pending=sum(1 for r in rows if r['active'] and not (r['expires_at'] and datetime.fromisoformat(r['expires_at']) <= now()) and not r['hwid'])
    return (f'📊 ESTATÍSTICAS DO SISTEMA\n\n'
            f'🔑 Total de Keys: {total}\n'
            f'✅ Keys Ativas: {active}\n'
            f'⏳ Keys Pendentes: {pending}\n'
            f'❌ Keys Expiradas: {expired}')

def main_menu(uid=None):
    if uid not in ADMIN_IDS:
        rows=[[{'text':'🔑 Gerar minhas keys', 'callback_data':'keys_menu'}], [{'text':'🪪 Meu ID', 'callback_data':'my_id'}]]
        if can_manage_files(uid):
            rows.append([{'text':'📦 Gerenciar meus .3105', 'callback_data':'items_page:0'}])
        if can_manage_people(uid):
            rows.append([{'text':'👥 Pessoas autorizadas', 'callback_data':'people_menu'}])
        return {'inline_keyboard': rows}
    return {'inline_keyboard': [
        [{'text':'🔒 Controle da IPA', 'callback_data':'ipa_control'}],
        [{'text':'🔑 Gerenciar keys', 'callback_data':'keys_menu'}],
        [{'text':'📊 Estatísticas', 'callback_data':'stats'}, {'text':'🏆 Ranking', 'callback_data':'rank_menu'}],
        [{'text':'📤 Publicar .3105', 'callback_data':'upload_help'}],
        [{'text':'🗑️ Gerenciar .3105', 'callback_data':'items_page:0'}],
        [{'text':'👥 Pessoas autorizadas', 'callback_data':'people_menu'}],
        [{'text':'🪪 Meu ID', 'callback_data':'my_id'}],
    ]}

def send_menu(chat, prefix='', uid=None):
    tg_send(chat, prefix + '🎛️ FILZA EXTERNAL V1000 Control\n\nEscolha uma operação:', main_menu(uid))

def ipa_control_text():
    locked=get_control('ipa_locked') == '1'
    lock_message=get_control('lock_message') or 'Mensagem padrão de bloqueio.'
    global_message=get_control('global_message') or 'Nenhuma mensagem global publicada.'
    return (f'🔒 Controle da IPA\n\nStatus: {"🔴 TRAVADA" if locked else "🟢 LIBERADA"}\n'
            f'Mensagem de bloqueio: {lock_message}\n\n📢 Mensagem global:\n{global_message}')

def handle_callback(q):
    callback_id=q.get('id',''); tg_answer(callback_id)
    msg=q.get('message') or {}; chat=(msg.get('chat') or {}).get('id'); uid=(q.get('from') or {}).get('id')
    if not chat or not uid: return
    if not admin_db(uid): return tg_edit(chat, msg.get('message_id'), '🔒 Acesso restrito ao administrador.', back_button())
    data=q.get('data',''); mid=msg.get('message_id')
    if uid not in ADMIN_IDS:
        allowed = data in {'menu', 'my_id', 'keys_menu', 'keys_generate'} or data.startswith(('gen_unit:', 'gen_duration:', 'gen_quantity:'))
        if can_manage_files(uid):
            allowed = allowed or data == 'items_page:0' or data in {'upload_help', 'skip_image'} or data.startswith(('items_page:', 'item_delete_ask:', 'item_delete_confirm:', 'item_rename_ask:', 'item_view:', 'upload:'))
        if can_manage_people(uid):
            allowed = allowed or data in {'people_menu', 'people_add', 'people_remove_help'} or data.startswith(('operator_permission:', 'operator_people:', 'person_days:'))
        if not allowed:
            return tg_edit(chat, mid, '🔒 Seu perfil não tem permissão para essa área.', {'inline_keyboard': [[{'text':'🔑 Gerar minhas keys', 'callback_data':'keys_menu'}]]})
    if data == 'menu': return tg_edit(chat, mid, '🎛️ FILZA EXTERNAL V1000 Control\n\nEscolha uma operação:', main_menu(uid))
    if data == 'my_id': return tg_edit(chat, mid, f'🪪 Seu ID do Telegram é:\n`{uid}`', {'inline_keyboard': [[{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]]}, parse_mode='Markdown')
    if data == 'ipa_control':
        return tg_edit(chat, mid, ipa_control_text(), {'inline_keyboard': [
            [{'text':'🔒 Travar IPA', 'callback_data':'ipa_lock_on'}, {'text':'🔓 Destravar IPA', 'callback_data':'ipa_lock_off'}],
            [{'text':'✏️ Editar mensagem de bloqueio', 'callback_data':'ipa_lock_message'}],
            [{'text':'📢 Definir mensagem global', 'callback_data':'ipa_global_message'}, {'text':'🧹 Limpar global', 'callback_data':'ipa_global_clear'}],
            [{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]
        ]})
    if data == 'ipa_lock_on':
        set_control('ipa_locked', '1', uid)
        return tg_edit(chat, mid, '🔴 IPA travada. A tela de bloqueio será exibida na próxima consulta do app.', {'inline_keyboard': [[{'text':'🔒 Voltar ao controle', 'callback_data':'ipa_control'}]]})
    if data == 'ipa_lock_off':
        set_control('ipa_locked', '0', uid)
        return tg_edit(chat, mid, '🟢 IPA destravada. O acesso normal foi restaurado.', {'inline_keyboard': [[{'text':'🔒 Voltar ao controle', 'callback_data':'ipa_control'}]]})
    if data == 'ipa_lock_message':
        handle_update.pending[uid]={'stage':'ipa_lock_message'}
        return tg_edit(chat, mid, '✏️ Envie agora a mensagem que aparecerá quando a IPA estiver travada.\n\nEnvie /cancelar para desistir.', back_button())
    if data == 'ipa_global_message':
        handle_update.pending[uid]={'stage':'ipa_global_message'}
        return tg_edit(chat, mid, '📢 Envie agora a mensagem global que aparecerá para usuários ativos.\n\nEnvie /cancelar para desistir.', back_button())
    if data == 'ipa_global_clear':
        set_control('global_message', '', uid)
        return tg_edit(chat, mid, '🧹 Mensagem global removida.', {'inline_keyboard': [[{'text':'🔒 Voltar ao controle', 'callback_data':'ipa_control'}]]})
    if data == 'keys_menu':
        if uid not in ADMIN_IDS:
            return tg_edit(chat, mid, '🔑 Minhas keys\n\nGere keys com o prefixo autorizado e escolha a duração.', {'inline_keyboard': [
                [{'text':'➕ Gerar keys', 'callback_data':'keys_generate'}],
                [{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]
            ]})
        return tg_edit(chat, mid, '🔑 Gerenciamento de keys\n\nEscolha uma operação:', {'inline_keyboard': [
            [{'text':'➕ Gerar keys', 'callback_data':'keys_generate'}, {'text':'📋 Todas as keys', 'callback_data':'keys_page:0'}],
            [{'text':'📊 Relatório de estados', 'callback_data':'keys_report'}],
            [{'text':'🗑️ Excluir key', 'callback_data':'keys_delete_help'}],
            [{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]
        ]})
    if data == 'keys_delete_help':
        handle_update.pending[uid]={'stage':'delete_key'}
        return tg_edit(chat, mid, '🗑️ Excluir key\n\nAgora envie a key completa ou os 6 últimos caracteres nesta conversa.\n\nO bot pedirá confirmação antes de apagar definitivamente.', {'inline_keyboard': [[{'text':'↩️ Voltar', 'callback_data':'keys_menu'}]]})
    if data == 'skip_image':
        pending=handle_update.pending.get(uid) or {}
        if pending.get('stage') != 'image': return tg_edit(chat, mid, '⚠️ Não há imagem pendente.', back_button())
        with db() as c: c.execute('UPDATE items SET active=1 WHERE id=?', (int(pending['item_id']),))
        handle_update.pending.pop(uid, None)
        return tg_edit(chat, mid, '✅ Publicado sem imagem de prévia.', {'inline_keyboard': [[{'text':'📦 Gerenciar publicados', 'callback_data':'items_page:0'}], [{'text':'↩️ Voltar', 'callback_data':'menu'}]]})
    if data.startswith('delete_ask:'):
        hint=data.split(':',1)[1][-6:]
        return tg_edit(chat, mid, f'⚠️ Confirmar exclusão definitiva da key `...{hint}`?', {'inline_keyboard': [[{'text':'✅ Sim, excluir', 'callback_data':f'delete_confirm:{hint}'}, {'text':'❌ Cancelar', 'callback_data':'keys_page:0'}]]})
    if data.startswith('delete_confirm:'):
        hint=data.split(':',1)[1][-6:]
        n=delete_key_by_hint(hint, uid)
        return tg_edit(chat, mid, ('✅ Key excluída definitivamente.' if n else '⚠️ Essa key já não existe.'), {'inline_keyboard': [[{'text':'🔑 Gerenciar keys', 'callback_data':'keys_menu'}]]})
    if data == 'people_menu':
        if not can_manage_people(uid): return tg_edit(chat, mid, '🔒 Seu perfil não pode administrar pessoas.', back_button())
        return tg_edit(chat, mid, people_text() + '\n\nUse os botões abaixo para administrar acessos.', {'inline_keyboard': [
            [{'text':'➕ Adicionar pessoa', 'callback_data':'people_add'}],
            [{'text':'➖ Remover pessoa', 'callback_data':'people_remove_help'}],
            [{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]
        ]})
    if data == 'people_add':
        if not can_manage_people(uid): return tg_edit(chat, mid, '🔒 Seu perfil não pode adicionar pessoas.', back_button())
        handle_update.pending[uid]={'stage':'person_id'}
        return tg_edit(chat, mid, '➕ Adicionar pessoa\n\nPeça para ela tocar em “Meu ID” no menu ou enviar o número do ID do Telegram.\n\nAgora envie somente o ID numérico da pessoa.', back_button())
    if data.startswith('operator_permission:'):
        pending=handle_update.pending.get(uid) or {}
        if pending.get('stage') != 'operator_permission': return tg_edit(chat, mid, '⚠️ Esse cadastro expirou. Envie /addperson novamente.', back_button())
        manage_files=data.split(':',1)[1] == 'yes'
        pending['manage_files']=manage_files
        return tg_edit(chat, mid, '👥 Permissão adicional\n\nEssa pessoa também poderá adicionar, liberar, ver e remover outras pessoas?', {'inline_keyboard': [[{'text':'✅ Sim, permitir pessoas', 'callback_data':'operator_people:yes'}, {'text':'❌ Não', 'callback_data':'operator_people:no'}], [{'text':'Cancelar', 'callback_data':'menu'}]]})
    if data.startswith('person_days:'):
        pending=handle_update.pending.get(uid) or {}
        if pending.get('stage') != 'person_days': return tg_edit(chat, mid, '⚠️ Esse cadastro expirou. Comece novamente.', back_button())
        try: key_days=int(data.split(':',1)[1])
        except ValueError: return tg_edit(chat, mid, '❌ Duração inválida.', back_button())
        pending['key_days']=key_days; pending['stage']='operator_permission'
        return tg_edit(chat, mid, f'👤 Pessoa: {pending["person"]}\nFormato: {pending["key_prefix"]}-xxxxxxx\nDuração: {key_days or "vitalícia"} dias\n\nEssa pessoa poderá gerenciar arquivos?', {'inline_keyboard': [[{'text':'✅ Sim, permitir arquivos', 'callback_data':'operator_permission:yes'}, {'text':'❌ Não, somente keys', 'callback_data':'operator_permission:no'}], [{'text':'Cancelar', 'callback_data':'menu'}]]})
    if data.startswith('operator_people:'):
        pending=handle_update.pending.get(uid) or {}
        if pending.get('stage') != 'operator_permission': return tg_edit(chat, mid, '⚠️ Esse cadastro expirou. Envie /addperson novamente.', back_button())
        manage_people=data.split(':',1)[1] == 'yes'
        add_operator(pending['person'], pending['name'], pending['key_days'], pending['key_prefix'], pending.get('manage_files', False), manage_people)
        handle_update.pending.pop(uid, None)
        access='pode gerenciar arquivos' if pending.get('manage_files') else 'não gerencia arquivos'
        people='e pode autorizar outras pessoas' if manage_people else 'e não pode autorizar outras pessoas'
        return tg_edit(chat, mid, f'✅ Pessoa {pending["person"]} autorizada.\nKeys: {pending["key_days"] or "vitalícias"} dias\nFormato: {pending["key_prefix"]}-xxxxxxx\nPermissão: {access}; {people}.', {'inline_keyboard': [[{'text':'👥 Ver pessoas', 'callback_data':'people_menu'}], [{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]]})
    if data == 'people_remove_help':
        if not can_manage_people(uid): return tg_edit(chat, mid, '🔒 Seu perfil não pode remover pessoas.', back_button())
        handle_update.pending[uid]={'stage':'person_remove'}
        return tg_edit(chat, mid, '➖ Remover pessoa\n\nAgora envie somente o ID numérico da pessoa que deseja remover.', back_button())
    if data == 'keys_generate':
        profile=operator_profile(uid)
        return tg_edit(chat, mid, '🔑 Gerar keys\n\nEscolha a unidade da duração:', {'inline_keyboard': [
            [{'text':'📅 Dias (1–30)', 'callback_data':'gen_unit:days'}, {'text':'⏱️ Horas (1–23)', 'callback_data':'gen_unit:hours'}],
            [{'text':'✏️ Outro número de dias', 'callback_data':'gen_custom_days'}, {'text':'♾️ Vitalícia', 'callback_data':'gen_duration:days:0'}],
            [{'text':'↩️ Voltar', 'callback_data':'keys_menu'}]
        ]})
    if data == 'gen_custom_days':
        handle_update.pending[uid]={'stage':'gen_custom_days'}
        return tg_edit(chat, mid, '✏️ Duração personalizada\n\nEnvie quantos dias deve durar a key.\nUse 0 para criar uma key vitalícia.\nMáximo: 36.500 dias.', {'inline_keyboard': [[{'text':'↩️ Voltar', 'callback_data':'keys_generate'}]]})
    if data.startswith('gen_unit:'):
        unit=data.split(':',1)[1]
        limit=30 if unit == 'days' else 23
        label='dias' if unit == 'days' else 'horas'
        rows=[]
        for first in range(1, limit + 1, 5):
            rows.append([{'text':str(n), 'callback_data':f'gen_duration:{unit}:{n}'} for n in range(first, min(first+5, limit+1))])
        rows.append([{'text':'↩️ Voltar', 'callback_data':'keys_generate'}])
        return tg_edit(chat, mid, f'🔑 Escolha a duração em {label}:', {'inline_keyboard': rows})
    if data.startswith('gen_duration:'):
        parts=data.split(':')
        unit=parts[1] if len(parts) > 2 else 'days'
        duration=int(parts[2] if len(parts) > 2 else parts[1])
        handle_update.pending[uid]={'stage':'gen_quantity','unit':unit,'duration':duration}
        label='dias' if unit == 'days' else 'horas'
        quantities=[1,5,10,25,50,100]
        return tg_edit(chat, mid, f'✅ Duração: {duration} {label}\n\nAgora escolha quantas keys deseja gerar:', {'inline_keyboard': [[{'text':str(n), 'callback_data':f'gen_quantity:{n}'} for n in quantities[:3]], [{'text':str(n), 'callback_data':f'gen_quantity:{n}'} for n in quantities[3:]], [{'text':'↩️ Voltar', 'callback_data':'keys_generate'}]]})
    if data.startswith('gen_quantity:'):
        pending=handle_update.pending.get(uid) or {}
        if pending.get('stage') != 'gen_quantity': return tg_edit(chat, mid, '⚠️ Essa geração expirou. Comece novamente.', back_button())
        try: quantity=max(1, min(100, int(data.split(':',1)[1])))
        except ValueError: return tg_edit(chat, mid, '❌ Quantidade inválida.', back_button())
        unit=pending['unit']; duration=pending['duration']; handle_update.pending.pop(uid,None)
        generated=[issue_key(uid, days=duration if unit == 'days' else 0, hours=duration if unit == 'hours' else 0)[0] for _ in range(quantity)]
        label='dias' if unit == 'days' else 'horas'
        body=f'✅ {len(generated)} key(s) gerada(s)\n\nPrefixo: {configured_key_prefix(uid)}\nDuração: {duration} {label}\n\n' + '\n'.join(f'`{key}`' for key in generated)
        markup=copy_keys_markup(generated)
        markup['inline_keyboard'] += [[{'text':'📋 Ver todas', 'callback_data':'keys_page:0'}], [{'text':'🔑 Voltar ao menu', 'callback_data':'keys_menu'}]]
        return tg_edit(chat, mid, body[:3900], markup, parse_mode='Markdown')
    if data.startswith('gen:'):
        parts=data.split(':'); days=int(parts[1]); quantity=int(parts[2]) if len(parts)>2 else 1
        generated=[issue_key(uid, days=days)[0] for _ in range(min(quantity,100))]
        body=f'✅ {len(generated)} key(s) gerada(s)\n\nDuração: {days or "vitalícia"} dias'
        if len(generated) <= 10: body += '\n\n' + '\n'.join(f'`{key}`' for key in generated)
        else: body += '\n\nUse “Todas as keys” para consultar a lista paginada.'
        markup=copy_keys_markup(generated)
        markup['inline_keyboard'] += [[{'text':'📋 Ver todas', 'callback_data':'keys_page:0'}], [{'text':'🔑 Gerenciar keys', 'callback_data':'keys_menu'}]]
        return tg_edit(chat, mid, body, markup)
    if data.startswith('keys_page:'):
        text,markup=keys_page_text(int(data.split(':',1)[1]), uid); return tg_edit(chat, mid, text[:3900], markup)
    if data == 'keys_report':
        report=global_keys_report_text() if uid in ADMIN_IDS else keys_report_text(uid)
        return tg_edit(chat, mid, report, {'inline_keyboard': [[{'text':'📋 Todas as keys', 'callback_data':'keys_page:0'}], [{'text':'↩️ Gerenciar keys', 'callback_data':'keys_menu'}]]})
    if data == 'stats':
        with db() as c: keys=c.execute('SELECT * FROM keys').fetchall(); items=c.execute('SELECT * FROM items WHERE active=1').fetchall(); downloads=sum(r['downloads'] for r in items)
        text=f'📊 Estatísticas\n\n🔑 Keys ativas: {sum(active_key(r) for r in keys)}\n🗝️ Keys totais: {len(keys)}\n📦 Patches online: {len(items)}\n⬇️ Downloads: {downloads}'
        return tg_edit(chat, mid, text, back_button())
    if data.startswith('items_page:'):
        if not can_manage_files(uid): return tg_edit(chat, mid, '🔒 Seu perfil pode apenas gerar keys.', back_button())
        text,markup=items_page_text(int(data.split(':',1)[1])); return tg_edit(chat, mid, text[:3900], markup)
    if data.startswith('item_delete_ask:'):
        if not can_manage_files(uid): return tg_edit(chat, mid, '🔒 Seu perfil não pode remover arquivos.', back_button())
        try: item_id=int(data.split(':',1)[1])
        except ValueError: return tg_edit(chat, mid, '❌ Arquivo inválido.', back_button())
        with db() as c: row=c.execute('SELECT name,filename,category FROM items WHERE id=? AND active=1', (item_id,)).fetchone()
        if not row: return tg_edit(chat, mid, '⚠️ Esse arquivo já não está publicado.', {'inline_keyboard': [[{'text':'📦 Voltar aos arquivos', 'callback_data':'items_page:0'}]]})
        return tg_edit(chat, mid, f'⚠️ Excluir definitivamente?\n\nNome: {row["name"]}\nArquivo: {row["filename"]}\nCategoria: {row["category"]}\n\nO arquivo será removido do catálogo da IPA e do VPS.', {'inline_keyboard': [[{'text':'✅ Sim, excluir', 'callback_data':f'item_delete_confirm:{item_id}'}, {'text':'❌ Cancelar', 'callback_data':'items_page:0'}]]})
    if data.startswith('item_rename_ask:'):
        if not can_manage_files(uid): return tg_edit(chat, mid, '🔒 Seu perfil não pode editar arquivos.', back_button())
        try: item_id=int(data.split(':',1)[1])
        except ValueError: return tg_edit(chat, mid, '❌ Arquivo inválido.', back_button())
        with db() as c: row=c.execute('SELECT name,filename,category FROM items WHERE id=? AND active=1', (item_id,)).fetchone()
        if not row: return tg_edit(chat, mid, '⚠️ Esse arquivo já não está publicado.', {'inline_keyboard': [[{'text':'📦 Voltar aos arquivos', 'callback_data':'items_page:0'}]]})
        handle_update.pending[uid]={'stage':'rename_item','item_id':item_id}
        return tg_edit(chat, mid, f'✏️ Editar nome do patch\n\nNome atual: {row["name"]}\nArquivo físico: {row["filename"]}\n\nEnvie somente o novo nome. O arquivo .3105 não será apagado nem reenviado.', {'inline_keyboard': [[{'text':'❌ Cancelar', 'callback_data':'items_page:0'}]]})
    if data.startswith('item_view:'):
        if not can_manage_files(uid): return tg_edit(chat, mid, '🔒 Seu perfil não pode ver arquivos.', back_button())
        try: item_id=int(data.split(':',1)[1])
        except ValueError: return tg_edit(chat, mid, '❌ Arquivo inválido.', back_button())
        with db() as c: row=c.execute('SELECT name,filename,category,rank,downloads FROM items WHERE id=? AND active=1', (item_id,)).fetchone()
        if not row: return tg_edit(chat, mid, '⚠️ Esse arquivo já não está publicado.', {'inline_keyboard': [[{'text':'📦 Voltar aos arquivos', 'callback_data':'items_page:0'}]]})
        return tg_edit(chat, mid, f'🔎 Patch #{item_id}\n\nNome completo:\n{row["name"]}\n\nArquivo físico: {row["filename"]}\nCategoria: {row["category"]}\nRank: {row["rank"]}\nDownloads: {row["downloads"]}', {'inline_keyboard': [[{'text':'✏️ Renomear este patch', 'callback_data':f'item_rename_ask:{item_id}'}], [{'text':'📦 Voltar aos arquivos', 'callback_data':'items_page:0'}]]})
    if data.startswith('item_delete_confirm:'):
        if not can_manage_files(uid): return tg_edit(chat, mid, '🔒 Seu perfil não pode remover arquivos.', back_button())
        try: item_id=int(data.split(':',1)[1])
        except ValueError: return tg_edit(chat, mid, '❌ Arquivo inválido.', back_button())
        row=delete_item_by_id(item_id, uid)
        if not row: return tg_edit(chat, mid, '⚠️ Esse arquivo já foi removido ou não existe.', {'inline_keyboard': [[{'text':'📦 Gerenciar .3105', 'callback_data':'items_page:0'}]]})
        return tg_edit(chat, mid, f'✅ Arquivo excluído definitivamente.\n\n{row["filename"]}', {'inline_keyboard': [[{'text':'📦 Gerenciar .3105', 'callback_data':'items_page:0'}], [{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]]})
    if data == 'rank_menu':
        return tg_edit(chat, mid, '🏆 Ranking de patches\n\nEscolha uma categoria:', {'inline_keyboard': [
            [{'text':'🔥 FF NORMAL', 'callback_data':'rank:FF NORMAL'}, {'text':'⚡ FF MAX', 'callback_data':'rank:FF MAX'}],
            [{'text':'🛡️ AP', 'callback_data':'rank:AP'}],
            [{'text':'🟥 TEXTURAS', 'callback_data':'rank:TEXTURAS'}],
            [{'text':'🟪 HOLOGRAMAS', 'callback_data':'rank:HOLOGRAMAS'}],
            [{'text':'⬛ OUTROS', 'callback_data':'rank:OUTROS'}],
            [{'text':'↩️ Voltar', 'callback_data':'menu'}]
        ]})
    if data.startswith('rank:'):
        cat=data.split(':',1)[1]
        with db() as c: rows=c.execute('SELECT name,rank,downloads FROM items WHERE category=? AND active=1 ORDER BY rank,id',(cat,)).fetchall()
        text=f'🏆 Ranking — {cat}\n\n' + ('\n'.join(f'{i+1}. {r["name"]}\n   Rank: {r["rank"]} | Downloads: {r["downloads"]}' for i,r in enumerate(rows)) or 'Nenhum patch publicado.')
        return tg_edit(chat, mid, text, back_button())
    if data == 'upload_help':
        if not can_manage_files(uid): return tg_edit(chat, mid, '🔒 Seu perfil pode apenas gerar keys.', back_button())
        return tg_edit(chat, mid, '📤 Publicar arquivo .3105\n\n1. Escolha uma categoria.\n2. Digite o nome que aparecerá na IPA.\n3. Envie o arquivo .3105 como documento.\n\nO rank será definido automaticamente.', {'inline_keyboard': [
            [{'text':'🔥 FF NORMAL', 'callback_data':'upload:FF NORMAL'}, {'text':'⚡ FF MAX', 'callback_data':'upload:FF MAX'}],
            [{'text':'🛡️ AP', 'callback_data':'upload:AP'}],
            [{'text':'🟥 TEXTURAS', 'callback_data':'upload:TEXTURAS'}],
            [{'text':'🟪 HOLOGRAMAS', 'callback_data':'upload:HOLOGRAMAS'}],
            [{'text':'⬛ OUTROS', 'callback_data':'upload:OUTROS'}],
            [{'text':'🗑️ Gerenciar publicados', 'callback_data':'items_page:0'}],
            [{'text':'↩️ Voltar', 'callback_data':'menu'}]
        ]})
    if data.startswith('upload:'):
        if not can_manage_files(uid): return tg_edit(chat, mid, '🔒 Seu perfil não pode publicar arquivos.', back_button())
        cat=data.split(':',1)[1]
        cat={'TEXTURA':'TEXTURAS', 'HOLOGRAMA':'HOLOGRAMAS'}.get(cat.upper(), cat.upper())
        handle_update.pending[uid]={'category':cat, 'stage':'name'}
        return tg_edit(chat, mid, f'📤 Categoria selecionada: {cat}\n\nAgora escreva o nome que deve aparecer dentro da IPA.\n\nExemplo: HS ALTO PREMIUM', back_button())

def new_key(days, uid, note='', hours=0, prefix=None):
    if prefix:
        prefix=''.join(ch for ch in str(prefix).upper() if ch.isalnum() or ch in '_-')[:16].strip('-_') or 'KEY'
        suffix=''.join(secrets.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') for _ in range(7))
        raw=f'{prefix}-{suffix}'
    else:
        alphabet='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; body=''.join(secrets.choice(alphabet) for _ in range(16)); raw='DGZ-' + '-'.join(body[i:i+4] for i in range(0,16,4))
    exp=None if (days <= 0 and hours <= 0) else iso(now() + (timedelta(hours=hours) if hours > 0 else timedelta(days=days)))
    with db() as c: c.execute('INSERT INTO keys(key_hash,key_hint,created_at,expires_at,telegram_user,note) VALUES(?,?,?,?,?,?)',(hashv(raw),raw[-6:],iso(now()),exp,uid,note))
    log_event('key_created', raw[-6:], str(uid), {'days':days, 'hours':hours, 'prefix':prefix or 'DGZ'}); return raw, exp

def issue_key(uid, days=30, hours=0, prefix=None):
    if prefix is None: prefix='KEY'
    profile=operator_profile(uid)
    if profile and uid not in ADMIN_IDS:
        # Preserve an explicitly selected custom duration. Older code forced
        # the operator profile duration and zeroed hours, turning 1 hour into
        # a lifetime key.
        if days is None and hours <= 0:
            configured_days=int(profile['key_days'])
            days=configured_days if configured_days > 0 else 30
        prefix=profile['key_prefix']
    personal=user_profile(uid)
    if personal: prefix=personal['key_prefix']
    return new_key(days, uid, hours=hours, prefix=prefix)

def admin(uid): return uid in ADMIN_IDS
def admin_db(uid):
    if uid in ADMIN_IDS: return True
    try:
        with db() as c: return bool(c.execute('SELECT 1 FROM operators WHERE user_id=? AND active=1', (uid,)).fetchone())
    except Exception: return False

def add_operator(uid, name='', key_days=30, key_prefix='KEY', manage_files=0, manage_people=0):
    with db() as c: c.execute('INSERT INTO operators(user_id,display_name,created_at,active,key_days,key_prefix,manage_files,manage_people) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET display_name=excluded.display_name,active=1,key_days=excluded.key_days,key_prefix=excluded.key_prefix,manage_files=excluded.manage_files,manage_people=excluded.manage_people', (uid, name, iso(now()), 1, key_days, key_prefix, int(bool(manage_files)), int(bool(manage_people))))
    log_event('operator_added', str(uid), str(uid), {'key_days':key_days, 'key_prefix':key_prefix, 'manage_files':bool(manage_files), 'manage_people':bool(manage_people)})

def remove_operator(uid):
    with db() as c: n=c.execute('UPDATE operators SET active=0 WHERE user_id=?', (uid,)).rowcount
    log_event('operator_removed', str(uid), str(uid)); return n

def key_hint_for(value):
    value=str(value or '').strip()
    with db() as c:
        if len(value) <= 6:
            row=c.execute('SELECT key_hint FROM keys WHERE key_hint=?', (value[-6:],)).fetchone()
        else:
            row=c.execute('SELECT key_hint FROM keys WHERE key_hash=?', (hashv(value),)).fetchone()
    return row['key_hint'] if row else None

def delete_key_by_hint(hint, actor=''):
    with db() as c:
        n=c.execute('DELETE FROM keys WHERE key_hint=?', (hint[-6:],)).rowcount
    if n: log_event('key_deleted', hint[-6:], str(actor))
    return n

def next_rank(category):
    with db() as c:
        row=c.execute('SELECT COALESCE(MAX(rank),0)+1 AS n FROM items WHERE category=?', (category,)).fetchone()
        return int(row['n'])

def people_text():
    with db() as c: rows=c.execute('SELECT user_id,display_name,active,key_days,key_prefix,manage_files,manage_people FROM operators ORDER BY created_at DESC').fetchall()
    lines=['👥 Pessoas autorizadas\n']
    lines += [f'• {r["user_id"]} — {r["display_name"] or "sem nome"} — {"ATIVA" if r["active"] else "REMOVIDA"}\n  Keys: {r["key_days"]} dias | prefixo {r["key_prefix"]} | arquivos: {"sim" if r["manage_files"] else "não"} | pessoas: {"sim" if r["manage_people"] else "não"}' for r in rows]
    lines.append(f'\nProprietários configurados: {len(ADMIN_IDS)}')
    return '\n'.join(lines)

def read_offset():
    try: return int(OFFSET_FILE.read_text().strip())
    except Exception: return None

def write_offset(value):
    try:
        OFFSET_FILE.parent.mkdir(parents=True, exist_ok=True); OFFSET_FILE.write_text(str(value))
    except Exception: pass

def initial_offset():
    saved=read_offset()
    if saved is not None: return saved
    try:
        rows=tg('getUpdates', {'timeout':0, 'offset':-1}).get('result', [])
        return max((u['update_id'] for u in rows), default=-1) + 1
    except Exception: return 0

def handle_update(u):
    msg=u.get('message') or {}; uid=(msg.get('from') or {}).get('id'); chat=msg.get('chat',{}).get('id')
    if not uid or not chat: return
    text=msg.get('text','').strip(); doc=msg.get('document'); photos=msg.get('photo') or []
    if text == '/myid': return tg_send(chat, f'🪪 Seu ID do Telegram é:\n`{uid}`\n\nEnvie esse número ao administrador.')
    if text in ('/start', '/menu'):
        if not admin_db(uid): return tg_send(chat, '🔒 FILZA EXTERNAL V1000 Control\n\nEste painel é exclusivo de pessoas autorizadas.')
        if text == '/start' and not user_profile(uid):
            handle_update.pending[uid]={'stage':'profile_name'}
            return tg_send(chat, '👋 Bem-vindo ao painel FILZA EXTERNAL!\n\nAntes de começar, qual nome você quer usar no painel?')
        return send_menu(chat, uid=uid)
    if not admin_db(uid): return tg_send(chat, 'Acesso restrito. Peça ao administrador para cadastrar seu ID.')
    pending=handle_update.pending.get(uid)
    if pending and isinstance(pending, dict) and pending.get('stage') == 'profile_name' and text and not text.startswith('/') and not doc:
        display_name=' '.join(text.split())[:48]
        if len(display_name) < 2: return tg_send(chat, 'Digite um nome com pelo menos 2 caracteres.')
        pending['display_name']=display_name
        pending['stage']='profile_prefix'
        return tg_send(chat, f'✅ Nome salvo: {display_name}\n\nAgora envie o prefixo que aparecerá no início das keys.\n\nExemplo: FILZA, VIP ou CLIENTE\nUse letras, números, _ ou - (máximo 16 caracteres).')
    if pending and isinstance(pending, dict) and pending.get('stage') == 'profile_prefix' and text and not text.startswith('/') and not doc:
        key_prefix=''.join(ch for ch in text.upper().strip() if ch.isalnum() or ch in '_-')[:16].strip('-_')
        if len(key_prefix) < 2: return tg_send(chat, 'Prefixo inválido. Use pelo menos 2 caracteres.')
        save_user_profile(uid, pending['display_name'], key_prefix)
        handle_update.pending.pop(uid, None)
        return send_menu(chat, f'✅ Configuração concluída!\nNome: {pending["display_name"]}\nPrefixo das keys: {key_prefix}-...\n\n', uid=uid)
    if pending and isinstance(pending, dict) and pending.get('stage') == 'delete_key' and text and not text.startswith('/') and not doc:
        handle_update.pending.pop(uid, None)
        hint=key_hint_for(text)
        if not hint: return tg_send(chat, '⚠️ Key não encontrada. Abra “Excluir key” e envie a key completa ou os 6 últimos caracteres.')
        return tg_send(chat, f'⚠️ Confirmar exclusão definitiva da key `...{hint}`?', {'inline_keyboard': [[{'text':'✅ Sim, excluir', 'callback_data':f'delete_confirm:{hint}'}, {'text':'❌ Cancelar', 'callback_data':'keys_menu'}]]})
    if pending and isinstance(pending, dict) and pending.get('stage') == 'rename_item' and text and not text.startswith('/') and not doc:
        new_name=' '.join(text.split())[:120]
        if not new_name: return tg_send(chat, '❌ O nome não pode ficar vazio.')
        item_id=int(pending['item_id'])
        with db() as c: row=c.execute('UPDATE items SET name=? WHERE id=? AND active=1 RETURNING name,filename', (new_name, item_id)).fetchone()
        handle_update.pending.pop(uid, None)
        if not row: return tg_send(chat, '⚠️ Esse patch não está mais publicado.', {'inline_keyboard': [[{'text':'📦 Gerenciar publicados', 'callback_data':'items_page:0'}]]})
        log_event('item_renamed', str(item_id), str(uid), {'name':new_name, 'filename':row['filename']})
        return tg_send(chat, f'✅ Nome atualizado na IPA:\n{row["name"]}\n\nArquivo mantido: {row["filename"]}', {'inline_keyboard': [[{'text':'📦 Gerenciar publicados', 'callback_data':'items_page:0'}], [{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]]})
    if pending and isinstance(pending, dict) and pending.get('stage') == 'person_id' and text and not text.startswith('/') and not doc:
        try: person=int(text)
        except ValueError: return tg_send(chat, '❌ Envie somente o ID numérico do Telegram.')
        if person <= 0: return tg_send(chat, '❌ ID inválido. Envie um ID numérico positivo.')
        pending['person']=person; pending['stage']='person_prefix'
        return tg_send(chat, '✅ ID recebido.\n\nAgora envie o prefixo das keys dessa pessoa.\nExemplo: CLIENTE, VIP ou TESTE')
    if pending and isinstance(pending, dict) and pending.get('stage') == 'person_prefix' and text and not text.startswith('/') and not doc:
        key_prefix=''.join(ch for ch in text.upper().strip() if ch.isalnum() or ch in '_-')[:16].strip('-_')
        if len(key_prefix) < 2: return tg_send(chat, '❌ Prefixo inválido. Use pelo menos 2 caracteres.')
        pending['name']=key_prefix; pending['key_prefix']=key_prefix; pending['stage']='person_days'
        return tg_send(chat, '✅ Prefixo definido: ' + key_prefix + '-xxxxxxx\n\nEscolha a duração das keys:', {'inline_keyboard': [[{'text':'7 dias', 'callback_data':'person_days:7'}, {'text':'30 dias', 'callback_data':'person_days:30'}], [{'text':'90 dias', 'callback_data':'person_days:90'}, {'text':'♾️ Vitalícia', 'callback_data':'person_days:0'}], [{'text':'Cancelar', 'callback_data':'menu'}]]})
    if pending and isinstance(pending, dict) and pending.get('stage') == 'person_remove' and text and not text.startswith('/') and not doc:
        try: person=int(text)
        except ValueError: return tg_send(chat, '❌ Envie somente o ID numérico do Telegram.')
        handle_update.pending.pop(uid, None)
        return tg_send(chat, f'✅ Pessoa {person} removida.' if remove_operator(person) else '⚠️ Pessoa não encontrada.', {'inline_keyboard': [[{'text':'👥 Ver pessoas', 'callback_data':'people_menu'}], [{'text':'↩️ Voltar ao menu', 'callback_data':'menu'}]]})
    if uid not in ADMIN_IDS:
        manager=can_manage_files(uid)
        generating = isinstance(pending, dict) and pending.get('stage') in {'gen_duration_choice', 'gen_custom_days', 'gen_quantity'}
        file_flow = manager and (isinstance(pending, dict) and pending.get('stage') in {'name', 'file', 'image', 'rename_item'} or isinstance(pending, tuple) or doc or photos)
        allowed = text == '/cancelar' or text.startswith('/genkey') or generating or file_flow
        if not manager:
            allowed = allowed and not doc
        if not allowed:
            return tg_send(chat, '🔒 Seu perfil pode apenas gerar keys.' if not manager else '🔒 Seu perfil só pode gerar keys e gerenciar os arquivos autorizados.')
    if text == '/cancelar' and pending:
        handle_update.pending.pop(uid, None)
        return tg_send(chat, 'Operação cancelada.', {'inline_keyboard': [[{'text':'🔒 Controle da IPA', 'callback_data':'ipa_control'}]]})
    if pending and isinstance(pending, dict) and pending.get('stage') == 'ipa_lock_message' and text and not doc:
        set_control('lock_message', ' '.join(text.split())[:500], uid)
        handle_update.pending.pop(uid, None)
        return tg_send(chat, '✅ Mensagem de bloqueio atualizada.', {'inline_keyboard': [[{'text':'🔒 Voltar ao controle', 'callback_data':'ipa_control'}]]})
    if pending and isinstance(pending, dict) and pending.get('stage') == 'ipa_global_message' and text and not doc:
        set_control('global_message', ' '.join(text.split())[:500], uid)
        handle_update.pending.pop(uid, None)
        return tg_send(chat, '✅ Mensagem global publicada.', {'inline_keyboard': [[{'text':'🔒 Voltar ao controle', 'callback_data':'ipa_control'}]]})
    if pending and isinstance(pending, dict) and pending.get('stage') == 'gen_custom_days' and text and not text.startswith('/') and not doc:
        try: days=int(text.replace(' ', ''))
        except ValueError: return tg_send(chat, '❌ Envie somente um número inteiro de dias.')
        if not 0 <= days <= 36500: return tg_send(chat, '❌ Use um número entre 0 e 36.500 dias.')
        handle_update.pending[uid]={'stage':'gen_quantity','unit':'days','duration':days}
        duration_text='vitalícia' if days == 0 else f'{days} dias'
        return tg_send(chat, f'✅ Duração definida: {duration_text}\n\nAgora escreva quantas keys deseja gerar (1 a 100):', {'inline_keyboard': [[{'text':'↩️ Voltar', 'callback_data':'keys_generate'}]]})
    if pending and isinstance(pending, dict) and pending.get('stage') == 'gen_quantity' and text and not text.startswith('/') and not doc:
        try: quantity=int(text)
        except ValueError: return tg_send(chat, 'Digite somente um número de 1 a 100.')
        if not 1 <= quantity <= 100: return tg_send(chat, 'A quantidade deve ficar entre 1 e 100.')
        unit=pending['unit']; duration=pending['duration']; handle_update.pending.pop(uid,None)
        generated=[issue_key(uid, days=duration if unit == 'days' else 0, hours=duration if unit == 'hours' else 0)[0] for _ in range(quantity)]
        label='dias' if unit == 'days' else 'horas'
        body=f'✅ {len(generated)} key(s) gerada(s)\n\nPrefixo: {configured_key_prefix(uid)}\nDuração: {duration} {label}'
        if len(generated) <= 10: body += '\n\n' + '\n'.join(f'`{key}`' for key in generated)
        else: body += '\n\nUse “Todas as keys” para consultar a lista paginada.'
        markup=copy_keys_markup(generated)
        markup['inline_keyboard'] += [[{'text':'📋 Ver todas', 'callback_data':'keys_page:0'}], [{'text':'🔑 Gerenciar keys', 'callback_data':'keys_menu'}]]
        return tg_send(chat, body, markup, parse_mode='Markdown')
    if pending and isinstance(pending, dict) and pending.get('stage') == 'name' and text and not text.startswith('/') and not doc:
        name=' '.join(text.split())[:120]
        pending.update({'name':name, 'rank':next_rank(pending['category']), 'stage':'file'})
        return tg_send(chat, f'✅ Nome definido: {name}\n📌 Rank automático: {pending["rank"]}\n\nAgora envie o arquivo `.3105` como documento.')
    if text.lower() in ('/semimagem', '/sem-foto', '/skipimage') and isinstance(pending, dict) and pending.get('stage') == 'image':
        with db() as c: c.execute('UPDATE items SET active=1 WHERE id=?', (int(pending['item_id']),))
        handle_update.pending.pop(uid, None)
        return tg_send(chat, '✅ Publicado sem imagem de prévia.')
    if photos:
        if not isinstance(pending, dict) or pending.get('stage') != 'image':
            return tg_send(chat, 'Envie uma imagem somente depois de publicar o arquivo .3105.')
        if not can_manage_files(uid): return tg_send(chat, '🔒 Seu perfil não pode publicar imagens.')
        fid=photos[-1].get('file_id'); info=tg('getFile', {'file_id': fid}).get('result', {}); fp=info.get('file_path')
        if not fp: return tg_send(chat, 'Não foi possível obter a imagem.')
        suffix=Path(fp).suffix.lower() or '.jpg'
        if suffix not in {'.jpg', '.jpeg', '.png', '.webp'}: return tg_send(chat, 'Envie JPG, PNG ou WEBP.')
        image_dest=FILES_DIR/(secrets.token_hex(8)+'_preview'+suffix)
        try:
            with urllib.request.urlopen(f'https://api.telegram.org/file/bot{BOT_TOKEN}/{fp}', timeout=120) as r: image_data=r.read()
            if len(image_data) > 8 * 1024 * 1024: return tg_send(chat, 'A imagem deve ter no máximo 8 MB.')
            image_dest.write_bytes(image_data)
            with db() as c: c.execute('UPDATE items SET image_path=?, active=1 WHERE id=?', (str(image_dest), int(pending['item_id'])))
        except Exception:
            try: image_dest.unlink()
            except OSError: pass
            return tg_send(chat, 'Não foi possível salvar a imagem.')
        item_id=pending['item_id']; handle_update.pending.pop(uid, None); log_event('item_image_updated', str(item_id), str(uid), {'path': str(image_dest)})
        return tg_send(chat, '✅ Imagem de prévia salva. Ela aparecerá na categoria da IPA.')

    if doc:
        if not pending: return tg_send(chat, 'Use /upload CATEGORIA RANK NOME antes de enviar o arquivo.')
        if not can_manage_files(uid): return tg_send(chat, '🔒 Seu perfil não pode publicar arquivos.')
        if isinstance(pending, dict):
            if pending.get('stage') != 'file': return tg_send(chat, 'Antes de enviar o arquivo, informe o nome do patch.')
            cat,rank,name=pending['category'],pending['rank'],pending['name']
        else:
            cat,rank,name=pending
        cat={'TEXTURA':'TEXTURAS', 'HOLOGRAMA':'HOLOGRAMAS'}.get(str(cat).strip().upper(), str(cat).strip().upper())
        if not str(doc.get('file_name', '')).lower().endswith('.3105'):
            return tg_send(chat, 'Envie somente arquivos com extensão .3105.')
        fid=doc.get('file_id'); info=tg('getFile',{'file_id':fid}).get('result',{}); fp=info.get('file_path')
        if not fp: return tg_send(chat,'Não foi possível obter o arquivo.')
        safe=''.join(ch for ch in (name or doc.get('file_name','patch.3105')) if ch.isalnum() or ch in '._-')[:120] or 'patch'; safe=safe if safe.lower().endswith('.3105') else safe+'.3105'; dest=FILES_DIR/(secrets.token_hex(8)+'_'+safe)
        with urllib.request.urlopen(f'https://api.telegram.org/file/bot{BOT_TOKEN}/{fp}', timeout=120) as r: data=r.read()
        if not data.startswith(b'3105PATCH\x00'): return tg_send(chat, '❌ Arquivo rejeitado: pacote .3105 inválido. Envie um pacote exportado pela FILZA EXTERNAL V1000.')
        dest.write_bytes(data)
        with db() as c:
            publish_now = not (str(cat).startswith('TEXTUR') or str(cat).startswith('HOLOGRAM'))
            c.execute('INSERT INTO items(name,category,rank,filename,path,image_path,created_at,active) VALUES(?,?,?,?,?,?,?,?)',(name or safe,cat,rank,safe,str(dest),None,iso(now()),1 if publish_now else 0))
            item_id=c.execute('SELECT last_insert_rowid() AS id').fetchone()['id']
        log_event('upload', safe, str(uid), {'category':cat,'rank':rank,'item_id':item_id})
        if cat.startswith('TEXTUR') or cat.startswith('HOLOGRAM'):
            handle_update.pending[uid]={'stage':'image','item_id':item_id}
            return tg_send(chat, f'✅ Arquivo publicado em {cat}, rank {rank}: {safe}\n\nAgora envie a imagem de prévia (JPG, PNG ou WEBP), ou toque no botão para continuar sem imagem.', {'inline_keyboard': [[{'text':'⏭️ Continuar sem imagem', 'callback_data':'skip_image'}], [{'text':'↩️ Cancelar', 'callback_data':'menu'}]]})
        handle_update.pending.pop(uid,None); return tg_send(chat, f'Arquivo publicado em {cat}, rank {rank}: {safe}')
    if text.startswith('/genkey'):
        try: days=int(text.split()[1]) if len(text.split())>1 else 30
        except: return tg_send(chat,'Uso: /genkey DIAS (0 = vitalícia)')
        prefix=text.split()[2] if len(text.split())>2 else None
        k,e=issue_key(uid, days=days, prefix=prefix); return tg_send(chat, f'KEY GERADA:\n{k}\nExpira: {e or "nunca"}', copy_keys_markup([k]))
    if text == '/keys':
        with db() as c: rows=c.execute('SELECT key_hint,created_at,expires_at,active,hwid FROM keys ORDER BY id DESC LIMIT 100').fetchall()
        return tg_send(chat, '\n'.join(f'{r["key_hint"]} | {"ATIVA" if active_key(r) else "INATIVA"} | {r["expires_at"] or "nunca"} | HWID:{"sim" if r["hwid"] else "não"}' for r in rows) or 'Nenhuma key.')
    if text.startswith('/revoke '):
        hint=text.split(None,1)[1].strip();
        with db() as c: n=c.execute('UPDATE keys SET active=0 WHERE key_hint=?',(hint[-6:],)).rowcount
        log_event('key_revoked',hint,str(uid)); return tg_send(chat, f'{n} key(s) revogada(s).')
    if text.startswith('/deletekey '):
        value=text.split(None,1)[1].strip(); hint=key_hint_for(value)
        if not hint: return tg_send(chat, '⚠️ Key não encontrada. Use a key completa ou os 6 últimos caracteres.')
        return tg_send(chat, f'⚠️ Confirmar exclusão definitiva da key `...{hint}`?', {'inline_keyboard': [[{'text':'✅ Sim, excluir', 'callback_data':f'delete_confirm:{hint}'}, {'text':'❌ Cancelar', 'callback_data':'keys_menu'}]]})
    if text == '/stats':
        with db() as c: keys=c.execute('SELECT * FROM keys').fetchall(); items=c.execute('SELECT * FROM items WHERE active=1').fetchall(); downloads=sum(r['downloads'] for r in items)
        return tg_send(chat, f'Keys ativas: {sum(active_key(r) for r in keys)}\nKeys totais: {len(keys)}\nPatches online: {len(items)}\nDownloads: {downloads}')
    if text.startswith('/rank '):
        cat=text[6:].strip().upper();
        if cat not in CATEGORIES: return tg_send(chat,'Categorias: FF NORMAL, FF MAX, AP, TEXTURAS, HOLOGRAMAS, OUTROS')
        with db() as c: rows=c.execute('SELECT name,rank,downloads FROM items WHERE category=? AND active=1 ORDER BY rank,id',(cat,)).fetchall()
        return tg_send(chat, '\n'.join(f'{i+1}. {r["name"]} | rank {r["rank"]} | {r["downloads"]} downloads' for i,r in enumerate(rows)) or 'Nenhum patch.')
    if text.startswith('/upload '):
        if not can_manage_files(uid): return tg_send(chat, '🔒 Seu perfil não pode publicar arquivos.')
        parts=text.split(None,3); cat=parts[1].upper() if len(parts)>1 else ''; 
        try: rank=int(parts[2]); name=parts[3] if len(parts)>3 else 'patch.3105'
        except: return tg_send(chat,'Uso: /upload CATEGORIA RANK NOME')
        if cat not in CATEGORIES: return tg_send(chat,'Categorias: FF NORMAL, FF MAX, AP, TEXTURAS, HOLOGRAMAS, OUTROS')
        handle_update.pending[uid]=(cat,rank,name); return tg_send(chat,'Agora envie o arquivo .3105 como documento.')
    if text == '/delete3105':
        if not can_manage_files(uid): return tg_send(chat, '🔒 Seu perfil pode apenas gerar keys.')
        text_out,markup=items_page_text(0); return tg_send(chat, text_out, markup)
    if text.startswith('/addperson '):
        if not can_manage_people(uid): return tg_send(chat, '🔒 Seu perfil não pode adicionar pessoas.')
        parts=text.split()
        try: person=int(parts[1]); key_days=int(parts[2]); key_prefix=parts[3]
        except (IndexError, ValueError): return tg_send(chat, 'Uso: /addperson ID DIAS NOME\nExemplo: /addperson 123456789 30 BYPASS')
        if not 0 <= key_days <= 3650: return tg_send(chat, 'Os dias devem ficar entre 0 (vitalícia) e 3650.')
        key_prefix=''.join(ch for ch in key_prefix.upper() if ch.isalnum() or ch in '_-')[:16].strip('-_')
        if not key_prefix: return tg_send(chat, 'O nome da key deve conter letras ou números. Exemplo: BYPASS')
        handle_update.pending[uid]={'stage':'operator_permission','person':person,'name':key_prefix,'key_days':key_days,'key_prefix':key_prefix}
        return tg_send(chat, f'👤 Revendedor: {person}\nKeys: {key_days or "vitalícias"} dias\nFormato: {key_prefix}-xxxxxxx\n\nEle poderá adicionar, ver e remover arquivos .3105?', {'inline_keyboard': [[{'text':'✅ Sim, permitir arquivos', 'callback_data':'operator_permission:yes'}, {'text':'❌ Não, somente keys', 'callback_data':'operator_permission:no'}], [{'text':'Cancelar', 'callback_data':'menu'}]]})
    if text.startswith('/removeperson '):
        if not can_manage_people(uid): return tg_send(chat, '🔒 Seu perfil não pode remover pessoas.')
        try: person=int(text.split()[1])
        except: return tg_send(chat, 'Uso: /removeperson ID')
        return tg_send(chat, f'✅ Pessoa {person} removida.' if remove_operator(person) else 'Pessoa não encontrada.')
    if text == '/people':
        if not can_manage_people(uid): return tg_send(chat, '🔒 Seu perfil não pode ver pessoas autorizadas.')
        return tg_send(chat, people_text())
    tg_send(chat,'Comando não reconhecido.')
handle_update.pending={}

def bot_loop():
    if not BOT_TOKEN: raise SystemExit('TELEGRAM_BOT_TOKEN ausente')
    BOT_LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    lock_handle=BOT_LOCK_FILE.open('a+')
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('Outra instância do FILZA EXTERNAL V1000 Control já está ativa')
    try:
        tg('setMyCommands', {'commands': json.dumps([
            {'command':'start','description':'Abrir painel visual'},
            {'command':'menu','description':'Voltar ao menu'},
        ], ensure_ascii=False)})
    except Exception: pass
    off=initial_offset()
    while True:
        try:
            r=tg('getUpdates', {'timeout':15,'offset':off,'allowed_updates':json.dumps(['message','callback_query'])})
            for u in r.get('result',[]):
                off=max(off,u['update_id']+1)
                write_offset(off)
                if u.get('callback_query'): handle_callback(u['callback_query'])
                else: handle_update(u)
        except Exception as exc:
            print(f'bot loop transient error: {type(exc).__name__}: {exc!r}', flush=True); traceback.print_exc()
            time.sleep(1)

def main():
    init_db(); mode=os.getenv('MODE','api')
    if mode=='bot': return bot_loop()
    ThreadingHTTPServer(('0.0.0.0', int(os.getenv('PORT','8000'))), API).serve_forever()
if __name__=='__main__': main()
