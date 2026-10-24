"""Posts BankLedger pages to a Discord channel through a webhook and keeps them up to date.

One message per page (category). The first run posts them in order; later runs edit only the
pages whose text changed. When the set of pages changes (a category gained a second page, a new
category appeared), the old messages are deleted and all pages are posted again, so the order
in the channel always matches the addon.

The addon writes its pages to SavedVariables on /reload, logout or exit, so that is when an
update can happen. --watch polls the file and posts on every change.

Nothing is posted unless the characters are named: the addon records every character, and a
guild channel must only show the bank alt. With several characters each page heading gets the
character's name ("**Amberbank · TRADE GOODS**") and the characters follow each other in order.

usage:
  bank_post.py --char Amberbank [--dry-run] [--watch] [--repost]
  bank_post.py --char Halnobrody,Konar --skip "NEW IN"      (several characters, skip a page)
  bank_post.py --all                                         (every character, e.g. a private channel)
  bank_post.py --list                                        (characters with saved pages)
  bank_post.py --pages pages.json --dry-run                  (test input: a JSON list of page texts)

The webhook URL is read from ~/.config/bankledger/webhook (or $BANKLEDGER_WEBHOOK) and is never
printed. State (message ids) lives in ~/.config/bankledger/state.json.
"""
import argparse
import glob
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import luaparse  # noqa: E402

# the game folder (the one with WTF in it); --wow or $BANKLEDGER_WOW override it
WOW = os.environ.get("BANKLEDGER_WOW", "/LINUX_DATA/Games/WoW Vanilla")
CONF = os.path.expanduser("~/.config/bankledger")
UA = "DiscordBot (https://github.com/bankledger, 1.0)"


def webhook_url():
    url = os.environ.get("BANKLEDGER_WEBHOOK")
    if not url:
        path = os.path.join(CONF, "webhook")
        if not os.path.exists(path):
            sys.exit(f"no webhook: put its URL in {path} (chmod 600)")
        url = open(path).read().strip()
    if not url.startswith("https://discord.com/api/webhooks/"):
        sys.exit("the webhook file does not hold a Discord webhook URL")
    return url


def saved_variables():
    return glob.glob(os.path.join(WOW, "WTF/Account/*/SavedVariables/BankLedger.lua"))


def load_all():
    """-> {"Realm:Name": (name, pages, time written)} for every character with saved pages."""
    out = {}
    for path in saved_variables():
        db = luaparse.parse_file(path).get("BankLedgerDB") or {}
        for cid, c in (db.get("chars") or {}).items():
            if c.get("pages"):
                pages = [c["pages"][i] for i in sorted(c["pages"])]
                out[cid] = (c.get("name") or cid.split(":")[-1], pages, c.get("pagesT", 0))
    return out


def select(chars, wanted):
    """Characters in the order asked for; "Name" or "Realm:Name", any case."""
    picked = []
    for w in wanted:
        hits = [cid for cid, c in chars.items() if w.lower() in (cid.lower(), c[0].lower())]
        if not hits:
            sys.exit(f"no saved pages for {w}: open the bank on it, then /reload or log out "
                     f"(known: {', '.join(c[0] for c in chars.values()) or 'none'})")
        picked += [h for h in hits if h not in picked]
    return picked


def page_key(text):
    return text.split("\n", 1)[0]


def digest(text):
    return hashlib.sha1(text.encode()).hexdigest()


class Hook:
    def __init__(self, url):
        self.url = url.split("?")[0].rstrip("/")

    def call(self, method, path="", body=None, query=""):
        data = json.dumps(body).encode() if body is not None else None
        for _ in range(5):
            req = urllib.request.Request(self.url + path + query, data=data, method=method,
                                         headers={"Content-Type": "application/json", "User-Agent": UA})
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    raw = r.read()
                    left = r.headers.get("X-RateLimit-Remaining")
                    if left == "0":
                        time.sleep(float(r.headers.get("X-RateLimit-Reset-After", "1")))
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as e:
                text = e.read().decode(errors="replace")
                if e.code == 429:
                    time.sleep(float(json.loads(text).get("retry_after", 1)) + 0.2)
                    continue
                if method == "DELETE" and e.code == 404:
                    return None
                # never echo the URL: it is the webhook's secret
                raise SystemExit(f"Discord said {e.code} on {method}: {text[:300]}")
        raise SystemExit("Discord kept rate limiting; try again later")

    def post(self, text):
        msg = self.call("POST", body={"content": text, "username": "Guild Bank",
                                      "allowed_mentions": {"parse": []}}, query="?wait=true")
        return msg["id"]

    def edit(self, mid, text):
        self.call("PATCH", f"/messages/{mid}", {"content": text, "allowed_mentions": {"parse": []}})

    def delete(self, mid):
        self.call("DELETE", f"/messages/{mid}")


def load_state():
    try:
        return json.load(open(os.path.join(CONF, "state.json")))
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(CONF, exist_ok=True)
    path = os.path.join(CONF, "state.json")
    json.dump(state, open(path + ".tmp", "w"), indent=1)
    os.replace(path + ".tmp", path)


def labelled(name, text):
    """**TRADE GOODS** (1/2) -> **Amberbank · TRADE GOODS** (1/2)"""
    return "**" + name + " · " + text[2:] if text.startswith("**") else text


def prepare(name, pages, args, label):
    keep = []
    for p in pages:
        if not args.ledger and p.startswith("**LEDGER"):
            continue
        if any(p.startswith("**" + k) for k in args.skip):
            continue
        p = labelled(name, p) if label else p
        if len(p) > 2000:
            sys.exit(f"page over 2000 characters: {page_key(p)}")
        keep.append(p)
    return keep


def sync(sets, args, hook, state):
    """sets: [(slot, pages)] in channel order. Edits changed pages in place; if any character's
    set of pages changed, deletes every selected character's messages and posts all again."""
    whole = args.repost or any(state.get(slot, {}).get("keys") != [page_key(p) for p in pages]
                               for slot, pages in sets)
    if not whole:
        todo = [(slot, i) for slot, pages in sets for i, p in enumerate(pages)
                if state[slot]["hashes"][i] != digest(p)]
        print(f"{len(todo)} pages changed" + (": " + ", ".join(page_key(dict(sets)[s][i]) for s, i in todo) if todo else ""))
        if args.dry_run:
            return
        for slot, i in todo:
            text = dict(sets)[slot][i]
            hook.edit(state[slot]["ids"][i], text)
            state[slot]["hashes"][i] = digest(text)
            save_state(state)
        return
    total = sum(len(p) for _, p in sets)
    old = sum(len(state.get(slot, {}).get("ids", [])) for slot, _ in sets)
    print(f"posting {total} pages" + (f" (replacing {old} old messages)" if old else ""))
    if args.dry_run:
        for _, pages in sets:
            for p in pages:
                print("-" * 60 + f" {len(p)} chars\n{p}")
        return
    for slot, _ in sets:
        for mid in state.get(slot, {}).get("ids", []):
            hook.delete(mid)
        state.pop(slot, None)
        save_state(state)
    for slot, pages in sets:
        new = state[slot] = {"keys": [], "ids": [], "hashes": []}
        for p in pages:
            new["ids"].append(hook.post(p))
            new["keys"].append(page_key(p))
            new["hashes"].append(digest(p))
            save_state(state)   # after every message, so a crash never orphans posted ones


def main():
    global WOW
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--char", action="append", default=[],
                    help="character(s) to publish, comma-separated or repeated, in channel order")
    ap.add_argument("--all", action="store_true", help="publish every character with saved pages")
    ap.add_argument("--list", action="store_true", help="list characters with saved pages and exit")
    ap.add_argument("--skip", action="append", default=[], help='leave out pages whose title starts with this, e.g. "NEW IN"')
    ap.add_argument("--no-label", action="store_true", help="no character name in headings, even with several characters")
    ap.add_argument("--wow", help=f"game folder containing WTF (default {WOW})")
    ap.add_argument("--pages", help="JSON list of page texts instead of SavedVariables (tests)")
    ap.add_argument("--dry-run", action="store_true", help="show what would be posted, touch nothing")
    ap.add_argument("--watch", action="store_true", help="keep running and post whenever the game saves")
    ap.add_argument("--ledger", action="store_true", help="also post the officer-only LEDGER page")
    ap.add_argument("--repost", action="store_true", help="delete and post everything again")
    args = ap.parse_args()
    if args.wow:
        WOW = args.wow
    wanted = [w.strip() for c in args.char for w in c.split(",") if w.strip()]

    if args.list:
        for cid, (name, pages, t) in sorted(load_all().items()):
            print(f"{name:14} {cid:28} {len(pages):3} pages, written {time.strftime('%d %b %H:%M', time.localtime(t))}")
        return
    if not (wanted or args.all or args.pages):
        sys.exit("name the characters to publish: --char Amberbank (or --all; --list shows them)")

    hook = None if args.dry_run else Hook(webhook_url())
    state = load_state()
    # message ids belong to one webhook (= one channel); keep them per webhook and character
    slot_base = "dry" if args.dry_run else digest(hook.url)[:12]

    def once():
        if args.pages:
            chars, cids = {"test": ("test", json.load(open(args.pages)), time.time())}, ["test"]
        else:
            chars = load_all()
            cids = sorted(chars) if args.all else select(chars, wanted)
        label = len(cids) > 1 and not args.no_label
        sets = []
        for cid in cids:
            name, pages, t = chars[cid]
            print(f"{time.strftime('%H:%M:%S')} {cid}: pages written {time.strftime('%d %b %H:%M', time.localtime(t))}")
            sets.append((f"{slot_base}:{cid}", prepare(name, pages, args, label)))
        sync(sets, args, hook, state)

    once()
    if not args.watch:
        return
    seen = {p: os.path.getmtime(p) for p in saved_variables()}
    print("watching SavedVariables (Ctrl+C stops)", flush=True)
    while True:
        time.sleep(5)
        cur = {p: os.path.getmtime(p) for p in saved_variables()}
        if cur != seen:
            time.sleep(2)   # let the game finish writing
            seen = {p: os.path.getmtime(p) for p in saved_variables()}
            args.repost = False
            try:
                once()
            except SystemExit as e:   # a half-written file or a Discord error must not end the watch
                print(e, flush=True)
            sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
