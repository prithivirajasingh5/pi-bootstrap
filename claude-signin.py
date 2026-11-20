#!/usr/bin/env python3
"""claude-signin: keep this Pi's Claude Code sign-in alive through Telegram.

Remote Control needs a claude.ai sign-in, which expires after about four weeks (using it doesn't
extend it), and signing in needs a person to approve it in a browser. This helper makes that a
two-tap job from the phone:

  * Every 30 min it reads `claude auth status --json`. When the sign-in ends within WARN_DAYS days
    (or is gone), it starts `claude auth login` and sends the sign-in link via `messenger` (Telegram).
    At most once every REMIND_HOURS hours.
  * You open the link, approve, and send the code it shows to the Telegram bot as:  claude <code>
  * The bot (telegram_bot_server.py, host networking) posts it here; this finishes the sign-in and
    restarts claude-remote.service so Remote Control uses the new sign-in.

HTTP API, on 127.0.0.1 only (the bot is the client):
  GET  /status   sign-in state as text
  POST /login    send a fresh sign-in link now
  POST /code     body = the code from the browser; finishes a waiting sign-in

Runs as the user who owns the sign-in (pi), as claude-signin.service, installed by claude-remote.sh.
Standard library only.
"""
import fcntl
import json
import os
import pty
import re
import signal
import struct
import subprocess
import termios
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CLAUDE = os.path.expanduser("~/.local/bin/claude")
MESSENGER = os.path.expanduser(os.environ.get("CLAUDE_SIGNIN_MESSENGER", "~/docker/python-jobs/jobs/messenger"))
PORT = int(os.environ.get("CLAUDE_SIGNIN_PORT", "8765"))
SERVICE = "claude-remote.service"
WARN_DAYS = 5              # start asking when the sign-in ends within this many days
REMIND_HOURS = 20          # automatic links at most this often (a manual "claude login" always works)
CHECK_SECONDS = 30 * 60    # how often to read the sign-in state
LINK_MINUTES = 30          # a waiting sign-in is dropped after this; ask for a new link then
HOST = os.uname().nodename

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
URL = re.compile(r"https://\S+/oauth/authorize\?\S+")


def log(msg):
    print(msg, flush=True)   # journald adds the time


def notify(text):
    """Send a Telegram message with messenger. True if delivered."""
    try:
        r = subprocess.run([MESSENGER, "--", text], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"messenger could not run ({MESSENGER}): {e}")
        return False
    if r.returncode != 0:
        log(f"messenger failed: {r.stderr.strip()}")
    return r.returncode == 0


def auth_status():
    """(logged_in, expires_at) from `claude auth status --json`; (None, None) if it can't be read."""
    try:
        r = subprocess.run([CLAUDE, "auth", "status", "--json"], capture_output=True, text=True, timeout=60)
        d = json.loads(r.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        log(f"could not read the sign-in state: {e}")
        return None, None
    exp = d.get("loginExpiresAt")
    exp = datetime.fromisoformat(exp.replace("Z", "+00:00")) if exp else None
    return bool(d.get("loggedIn")), exp


def describe(logged_in, exp):
    if logged_in is None:
        return "sign-in state unknown (claude auth status failed)"
    if not logged_in:
        return "signed out: Remote Control is down"
    if not exp:
        return "signed in (no end date reported)"
    days = (exp - datetime.now(timezone.utc)).total_seconds() / 86400
    return f"signed in until {exp.astimezone():%a %d %b %H:%M} ({days:.1f} days left)"


class Login:
    """One `claude auth login` waiting in a pseudo-terminal for the code."""

    def __init__(self):
        self.old_exp = auth_status()[1]
        self.pid, self.fd = pty.fork()
        if self.pid == 0:   # child
            try:
                os.execv(CLAUDE, [CLAUDE, "auth", "login", "--claudeai"])
            finally:
                os._exit(127)
        # Wide terminal, so the long URL is never wrapped onto several lines.
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 2000, 0, 0))
        self.started = time.time()
        self.out = ""
        self.url = None
        self.lock = threading.Lock()
        self.ended = threading.Event()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                break
            if not data:
                break
            with self.lock:
                self.out += ANSI.sub("", data.decode(errors="replace"))
        self.ended.set()

    def tail(self, n=400):
        with self.lock:
            return self.out.strip()[-n:]

    def wait_url(self, timeout=45):
        end = time.time() + timeout
        while time.time() < end and not self.ended.is_set():
            with self.lock:
                m = URL.search(self.out)
                if m and "Paste code" in self.out:
                    self.url = m.group(0)
                    return self.url
            time.sleep(0.2)
        return None

    def expired(self):
        return time.time() - self.started > LINK_MINUTES * 60 or self.ended.is_set()

    def submit(self, code, timeout=120):
        """Type the code; True if claude exited 0."""
        with self.lock:
            self.out = ""
        os.write(self.fd, code.encode() + b"\r")
        self.ended.wait(timeout)
        if not self.ended.is_set():
            self.kill()
            return False
        try:
            _, status = os.waitpid(self.pid, 0)
        except ChildProcessError:
            return False
        finally:
            self._close()
        return os.waitstatus_to_exitcode(status) == 0

    def kill(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
            os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        self._close()

    def _close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass


state = threading.Lock()   # guards pending / last_link
pending = None
last_link = 0.0


def send_link(reason):
    """Start a sign-in (or reuse the waiting one) and send its link. Returns a reply for the bot."""
    global pending, last_link
    with state:
        if pending and pending.expired():
            pending.kill()
            pending = None
        if pending is None:
            login = Login()
            if not login.wait_url():
                why = login.tail()
                login.kill()
                log(f"sign-in did not start: {why}")
                return f"❌ Could not start the sign-in on {HOST}:\n{why}"
            pending = login
        url, left = pending.url, LINK_MINUTES - int((time.time() - pending.started) / 60)
        last_link = time.time()
    text = (f"🔑 Claude on {HOST}: {reason}\n\n"
            f"1. Open this link and approve:\n{url}\n\n"
            f"2. Send me the code it shows, like this:\nclaude <code>\n\n"
            f"(valid for {left} min; send \"claude login\" for a new link)")
    log(f"sign-in link sent ({reason})")
    return "📨 Sign-in link sent." if notify(text) else "❌ The link could not be sent (messenger failed; see journalctl -u claude-signin)."


def submit_code(code):
    """Finish the waiting sign-in with the code from the browser. Returns a reply for the bot."""
    global pending
    with state:
        login, pending = pending, None
    if login is None or login.expired():
        if login:
            login.kill()
        return "No sign-in is waiting (links last 30 min). Send: claude login"
    exited_ok = login.submit(code)
    logged_in, exp = auth_status()
    renewed = logged_in and exp and (login.old_exp is None or exp > login.old_exp)
    if not (exited_ok and renewed):
        log(f"sign-in failed: {login.tail()}")
        return f"❌ Sign-in failed:\n{login.tail() or '(no output)'}\n\nSend \"claude login\" for a new link."
    r = subprocess.run(["sudo", "-n", "systemctl", "restart", SERVICE], capture_output=True, text=True)
    restarted = "Remote Control restarted." if r.returncode == 0 else f"⚠️ restarting {SERVICE} failed: {r.stderr.strip()}"
    log(f"signed in again; {restarted}")
    return f"✅ Claude on {HOST}: {describe(logged_in, exp)}. {restarted}"


def watch():
    """Background loop: send a link when the sign-in is about to end or is gone."""
    global pending
    time.sleep(60)
    while True:
        logged_in, exp = auth_status()
        with state:
            if pending and pending.expired():
                pending.kill()
                pending = None
            waiting = pending is not None
            recently = time.time() - last_link < REMIND_HOURS * 3600
        if logged_in is not None and not waiting and not recently:
            if not logged_in:
                send_link("signed out, so Remote Control is down.")
            elif exp and (exp - datetime.now(timezone.utc)).total_seconds() < WARN_DAYS * 86400:
                send_link(f"the sign-in ends {exp.astimezone():%a %d %b %H:%M}. Renew it now:")
        time.sleep(CHECK_SECONDS)


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status, text):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/status":
            with state:
                waiting = pending is not None and not pending.expired()
            extra = "\nA sign-in link is waiting for its code." if waiting else ""
            self._reply(200, f"Claude on {HOST}: {describe(*auth_status())}{extra}")
        else:
            self._reply(404, "not found")

    def do_POST(self):
        if self.path == "/login":
            self._reply(200, send_link("sign-in requested."))
        elif self.path == "/code":
            size = int(self.headers.get("Content-Length") or 0)
            code = self.rfile.read(min(size, 2048)).decode(errors="replace").strip()
            if not code or len(code) > 1000 or any(c.isspace() or ord(c) < 32 for c in code):
                self._reply(400, "That doesn't look like a sign-in code (one word, no spaces).")
            else:
                self._reply(200, submit_code(code))
        else:
            self._reply(404, "not found")

    def log_message(self, fmt, *args):   # no per-request access log (the code is in the body, not the URL)
        pass


if __name__ == "__main__":
    threading.Thread(target=watch, daemon=True).start()
    log(f"claude-signin listening on 127.0.0.1:{PORT}; {describe(*auth_status())}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
