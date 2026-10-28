#!/usr/bin/env python3
"""
KILLER PROXY Telegram bot - offset-aware, inline keyboard, single clean version.
Commands: /start (menu) /list /stats /rotate /status /traffic
"""
import os, json, time, subprocess, logging, requests
from datetime import datetime, timezone

CONF = "/etc/3proxy/telegram_bot.conf"
API = "https://api.telegram.org/bot{token}/{method}"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

def load_conf():
    token, admin = "", ""
    if os.path.exists(CONF):
        for line in open(CONF):
            line = line.strip()
            if line.startswith("BOT_TOKEN="): token = line.split("=", 1)[1].strip().strip('"').strip("'")
            elif line.startswith("ADMIN_ID="): admin = line.split("=", 1)[1].strip().strip('"').strip("'")
    return token, admin

def call(method, token, **kw):
    try:
        return requests.post(API.format(token=token, method=method), json=kw, timeout=20).json()
    except Exception:
        return {}

def send(token, chat_id, text, kb=None):
    kw = {"chat_id": chat_id, "text": text}
    if kb: kw["reply_markup"] = kb
    call("sendMessage", token, **kw)

def main_kb():
    return {"inline_keyboard": [
        [{"text": "📋 List Proxy", "callback_data": "list"},
         {"text": "📊 Stats", "callback_data": "stats"}],
        [{"text": "🔄 Rotate WARP", "callback_data": "rotate"},
         {"text": "📡 Status", "callback_data": "status"},
         {"text": "📈 Traffic", "callback_data": "traffic"}]]}

def load_users():
    try:
        with open("/etc/3proxy/users.json") as f: return json.load(f).get("users", {})
    except Exception: return {}

def get_ip():
    try:
        return requests.get("https://icanhazip.com", timeout=4).text.strip()
    except Exception:
        return "?"

def hb(b):
    for u in ["B","KB","MB","GB","TB"]:
        if b < 1024: return f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} PB"

def traffic_text():
    try:
        out = subprocess.run(["/usr/local/bin/xray", "api", "statsquery", "--server=127.0.0.1:10085"],
                             capture_output=True, text=True, timeout=6).stdout
        if not out: return "Xray API tidak merespon"
        from collections import defaultdict
        d = json.loads(out)
        up = defaultdict(int); down = defaultdict(int); tu = td = 0
        for s in d.get("stat", []):
            n, v = s.get("name",""), s.get("value",0) or 0
            if ">>>traffic>>>" not in n: continue
            seg = n.split(">>>"); direction = seg[-1]
            email = seg[-2] if len(seg) >= 5 else "total"
            if direction == "uplink": up[email] += v; tu += v
            elif direction == "downlink": down[email] += v; td += v
        lines = [f"Total: up {hb(tu)} | down {hb(td)}"]
        for e in sorted(set(up) | set(down)):
            lines.append(f"{e}: up {hb(up[e])} | down {hb(down[e])}")
        return "\n".join(lines)
    except Exception as e:
        return f"traffic err: {e}"

def status_text():
    def act(s): return "✅" if s == "active" else "❌"
    warp = 0
    try:
        warp = len([d for d in os.listdir("/etc/wireproxy") if d.startswith("warp")])
    except Exception: pass
    return (f"🖥 IP: {get_ip()}\n"
            f"Xray: {act(subprocess.run(['systemctl','is-active','xray'],capture_output=True,text=True).stdout.strip())}\n"
            f"3proxy: {act(subprocess.run(['systemctl','is-active','3proxy'],capture_output=True,text=True).stdout.strip())}\n"
            f"WARP: {warp} instance")

def list_text():
    users = load_users(); now = datetime.now(timezone.utc)
    if not users: return "Belum ada user. Ketik: proxy-user add <user> <pass> <days>"
    lines = ["📋 DAFTAR PROXY"]
    for u, info in sorted(users.items(), key=lambda x: x[1].get("socks_port", 9999)):
        try:
            d = (datetime.fromisoformat(info["expires_at"].replace("Z","+00:00")) - now).days
        except Exception: d = 0
        st = "⛔" if (d < 0 or info.get("status") == "expired") else ("⚠️" if d <= 3 else "✅")
        lines.append(f"{st} {u} | {info.get('socks_port')} | {d}d | WARP#{info.get('warp_instance')}")
    return "\n".join(lines)

def main():
    token, admin = load_conf()
    if not token:
        logging.error("No BOT_TOKEN in %s", CONF); return
    logging.info("Bot starting")
    offset = 0
    while True:
        try:
            r = call("getUpdates", token, offset=offset, timeout=20)
            if not r.get("ok"): time.sleep(3); continue
            for item in r["result"]:
                offset = item["update_id"] + 1
                msg = item.get("message", {})
                chat = msg.get("chat", {}).get("id")
                text = msg.get("text", "")
                if text == "/start" or text == "/menu":
                    send(token, chat, "KILLER PROXY PANEL 🚀", main_kb())
                elif text == "/list": send(token, chat, list_text())
                elif text == "/stats": send(token, chat, f"User: {len(load_users())}")
                elif text == "/status": send(token, chat, status_text())
                elif text == "/traffic": send(token, chat, traffic_text())
                cb = item.get("callback_query")
                if cb:
                    cid = cb["message"]["chat"]["id"]
                    data = cb.get("data")
                    call("answerCallbackQuery", token, callback_query_id=cb["id"])
                    if data == "list": send(token, cid, list_text(), main_kb())
                    elif data == "stats": send(token, cid, f"User: {len(load_users())}", main_kb())
                    elif data == "status": send(token, cid, status_text(), main_kb())
                    elif data == "traffic": send(token, cid, traffic_text(), main_kb())
                    elif data == "rotate":
                        send(token, cid, "⏳ Rotating WARP...")
                        subprocess.run(["/usr/local/bin/rotate-warp.sh", "all"], capture_output=True, timeout=90)
                        send(token, cid, "✅ WARP rotated", main_kb())
        except Exception as e:
            logging.warning("loop: %s", e)
            time.sleep(3)
        time.sleep(1)

if __name__ == "__main__":
    main()
