"""Window for bank_post.py: pick the game folder, paste the webhook, tick the characters, post.

Same engine and state as the command line, so both can be used on one channel. Settings (game
folder, webhook, characters) are saved in config.json next to state.json:
%APPDATA%\\BankLedger on Windows, ~/.config/bankledger elsewhere.
Posting runs in a worker thread that gets a snapshot of the settings and never touches Tk.
"""
import argparse
import contextlib
import json
import os
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_post as bp  # noqa: E402

CONFIG = os.path.join(bp.CONF, "config.json")
HELP_WEBHOOK = ("Discord: channel settings (gear) > Integrations > Webhooks > New Webhook > "
                "Copy Webhook URL, then paste it here.")
HIDE = "•"


def load_config():
    try:
        return json.load(open(CONFIG))
    except (OSError, ValueError):
        return {}


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        json.dump(cfg, f, indent=1)
    if os.name != "nt":
        os.chmod(CONFIG, 0o600)   # it holds the webhook URL


# ---------- work (worker thread; prints go to the window's log) ----------
def pages_for(snap):
    """-> (character names, [(character id, pages)]) for the ticked characters."""
    if not snap.cids:
        raise SystemExit("Tick at least one character first.")
    bp.WOW = snap.wow
    chars = bp.load_all()
    missing = [c for c in snap.cids if c not in chars]
    if missing:
        raise SystemExit(f"No saved pages for {', '.join(missing)}: open the bank on it, then /reload.")
    label = len(snap.cids) > 1
    return ([chars[c][0] for c in snap.cids],
            [(c, bp.prepare(chars[c][0], chars[c][1], snap, label)) for c in snap.cids])


def preview(snap):
    _, sets = pages_for(snap)
    n = 0
    for _, pages in sets:
        for p in pages:
            n += 1
            print("-" * 50 + f" {len(p)} characters\n{p}\n")
    print(f"Preview only: {n} messages, nothing posted.\n")


def post_once(snap):
    if not snap.url.startswith("https://discord.com/api/webhooks/"):
        raise SystemExit("Paste the Discord webhook URL first. " + HELP_WEBHOOK)
    names, sets = pages_for(snap)
    hook = bp.Hook(snap.url)
    base = bp.digest(hook.url)[:12]   # same slots as the command line, so both can share a channel
    print(time.strftime("%H:%M:%S ") + ", ".join(names) + "\n")
    bp.sync([(f"{base}:{c}", p) for c, p in sets], snap, hook, bp.load_state())
    print("Done.\n")


def watch(snap, running):
    print("Watching: the channel updates after every /reload or logout. Keep this window open.\n")
    bp.WOW = snap.wow
    seen = None
    while running.is_set():
        try:
            cur = {p: os.path.getmtime(p) for p in bp.saved_variables()}
            if cur != seen:
                if seen is not None:
                    time.sleep(2)   # let the game finish writing
                seen = {p: os.path.getmtime(p) for p in bp.saved_variables()}
                post_once(snap)
        except SystemExit as e:
            print(f"{e}\n")
        except Exception as e:
            print(f"Error: {e}\n")
        for _ in range(10):
            if not running.is_set():
                break
            time.sleep(0.5)


class QueueWriter:
    """stdout for the worker thread: text goes to a queue the window drains."""
    def __init__(self, q):
        self.q = q

    def write(self, s):
        if s:
            self.q.put(s)

    def flush(self):
        pass


# ---------- window ----------
class App:
    def __init__(self, root):
        self.root = root
        self.cfg = load_config()
        self.log_q = queue.Queue()
        self.busy = False
        self.watching = threading.Event()
        self.char_vars = {}
        root.title("BankLedger poster")
        root.minsize(620, 520)

        pad = {"padx": 8, "pady": 4}
        top = ttk.Frame(root)
        top.pack(fill="x", **pad)
        top.columnconfigure(1, weight=1)

        ttk.Label(top, text="WoW folder").grid(row=0, column=0, sticky="w")
        self.wow = tk.StringVar(value=self.cfg.get("wow") or bp.WOW)
        ttk.Entry(top, textvariable=self.wow).grid(row=0, column=1, sticky="ew", padx=4)
        ttk.Button(top, text="Browse...", command=self.browse).grid(row=0, column=2)

        ttk.Label(top, text="Webhook URL").grid(row=1, column=0, sticky="w")
        self.hook = tk.StringVar(value=self.cfg.get("webhook", ""))
        self.hook_entry = ttk.Entry(top, textvariable=self.hook, show=HIDE)
        self.hook_entry.grid(row=1, column=1, sticky="ew", padx=4)
        self.show_hook = tk.BooleanVar(value=False)
        ttk.Checkbutton(top, text="show", variable=self.show_hook,
                        command=lambda: self.hook_entry.config(show="" if self.show_hook.get() else HIDE)
                        ).grid(row=1, column=2)
        ttk.Label(top, text=HELP_WEBHOOK, foreground="gray", wraplength=560).grid(
            row=2, column=0, columnspan=3, sticky="w")

        box = ttk.LabelFrame(root, text="Characters to publish (only ticked ones are posted)")
        box.pack(fill="x", **pad)
        self.char_frame = ttk.Frame(box)
        self.char_frame.pack(fill="x", padx=6, pady=4)
        ttk.Button(box, text="Refresh list", command=self.refresh).pack(anchor="w", padx=6, pady=(0, 6))

        opts = ttk.Frame(root)
        opts.pack(fill="x", **pad)
        self.skip_new = tk.BooleanVar(value=self.cfg.get("skip_new", False))
        self.ledger = tk.BooleanVar(value=self.cfg.get("ledger", False))
        ttk.Checkbutton(opts, text='Leave out "New in the guild bank"', variable=self.skip_new).pack(side="left")
        ttk.Checkbutton(opts, text="Also post the officer LEDGER page", variable=self.ledger).pack(side="left", padx=12)

        btns = ttk.Frame(root)
        btns.pack(fill="x", **pad)
        ttk.Button(btns, text="Preview", command=lambda: self.start(preview, refresh=True)).pack(side="left")
        ttk.Button(btns, text="Post now", command=lambda: self.start(post_once, refresh=True)).pack(side="left", padx=6)
        self.watch_btn = ttk.Button(btns, text="Start watching", command=self.toggle_watch)
        self.watch_btn.pack(side="left")
        ttk.Label(btns, text="watching = post after every /reload or logout", foreground="gray").pack(side="left", padx=8)

        self.log = tk.Text(root, height=14, wrap="word", state="disabled")
        self.log.pack(fill="both", expand=True, **pad)

        root.protocol("WM_DELETE_WINDOW", self.close)
        self.refresh()
        self.pump()

    def say(self, text):
        self.log.config(state="normal")
        self.log.insert("end", text)
        self.log.see("end")
        self.log.config(state="disabled")

    def pump(self):
        while not self.log_q.empty():
            self.say(self.log_q.get())
        self.root.after(150, self.pump)

    def browse(self):
        d = filedialog.askdirectory(title="Folder that contains WoW.exe and WTF", initialdir=self.wow.get() or None)
        if d:
            self.wow.set(d)
            self.refresh()

    def ticked(self):
        return [cid for cid, v in self.char_vars.items() if v.get()]

    def remember(self):
        self.cfg.update(wow=self.wow.get().strip(), webhook=self.hook.get().strip(), chars=self.ticked(),
                        skip_new=self.skip_new.get(), ledger=self.ledger.get())
        save_config(self.cfg)

    def refresh(self):
        keep = set(self.ticked()) if self.char_vars else set(self.cfg.get("chars", []))
        for w in self.char_frame.winfo_children():
            w.destroy()
        self.char_vars = {}
        wow = self.wow.get().strip()
        if not wow or not os.path.isdir(os.path.join(wow, "WTF")):
            ttk.Label(self.char_frame, text="Pick the WoW folder (the one with a WTF folder in it).").pack(anchor="w")
            return
        bp.WOW = wow
        try:
            chars = bp.load_all()
        except Exception as e:   # a SavedVariables file the game is writing right now
            ttk.Label(self.char_frame, text=f"Could not read the saved data: {e}").pack(anchor="w")
            return
        if not chars:
            ttk.Label(self.char_frame, text="No BankLedger data yet: in game open the bank, then /reload or log out."
                      ).pack(anchor="w")
            return
        for cid in sorted(chars):
            name, pages, t = chars[cid]
            v = tk.BooleanVar(value=cid in keep)
            self.char_vars[cid] = v
            when = time.strftime("%d %b %H:%M", time.localtime(t))
            ttk.Checkbutton(self.char_frame, variable=v,
                            text=f"{name}  ({cid.split(':')[0]}, {len(pages)} pages, saved {when})").pack(anchor="w")

    def snapshot(self):
        """The settings as plain data, read here in the Tk thread."""
        return argparse.Namespace(
            wow=self.wow.get().strip(), url=self.hook.get().strip(), cids=self.ticked(),
            ledger=self.ledger.get(), skip=["NEW IN"] if self.skip_new.get() else [],
            repost=False, dry_run=False)

    def start(self, fn, refresh=False):
        if self.busy:
            return
        if refresh:
            self.refresh()
        self.remember()
        snap = self.snapshot()
        self.busy = True

        def run():
            try:
                with contextlib.redirect_stdout(QueueWriter(self.log_q)):
                    fn(snap)
            except SystemExit as e:
                self.log_q.put(f"{e}\n")
            except Exception as e:   # keep the window alive, show what went wrong
                self.log_q.put(f"Error: {e}\n")
            finally:
                self.busy = False
        threading.Thread(target=run, daemon=True).start()

    def toggle_watch(self):
        if self.watching.is_set():
            self.watching.clear()
            self.watch_btn.config(text="Start watching")
            self.say("Stopped watching.\n")
            return
        if self.busy:
            return
        self.watching.set()
        self.watch_btn.config(text="Stop watching")
        self.say("(Settings are read now; after changing them, stop and start watching again.)\n")
        self.start(lambda snap: watch(snap, self.watching))

    def close(self):
        self.remember()
        if self.watching.is_set() and not messagebox.askokcancel(
                "BankLedger", "Stop watching and close? The channel will not update while this is closed."):
            return
        self.watching.clear()
        self.root.destroy()


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
