"""Real-browser test of streaming on the live web app (headless Brave/Chrome over DevTools Protocol).

    python3 6_deploy/eval/browser_stream_test.py [URL]

Signs in on login.html as a brand-new Cognito customer (created for the run, deleted after), sends chat
messages the way a user does, and samples the last chat bubble every 250 ms, so it shows exactly
what the user sees and when: the status lines, the first streamed words, the final answer.
Fails if the bubble ever shows reasoning tags, if text never streams, or if errors appear.
"""
import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

import boto3
import websockets

REGION = os.environ.get("REGION") or os.environ.get("AWS_REGION") or "eu-central-1"
BROWSERS = ["/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
PORT = 9333
QUESTIONS = ["Which deals are running right now?",
             "Which laptop under €1,000 is best for a student?",
             "Is the Apple iPhone 14 in stock at my store?"]


def amplify_url():
    for app in boto3.client("amplify", region_name=REGION).list_apps()["apps"]:
        if app["name"] == "spbc-tech-assistant":
            return f"https://main.{app['defaultDomain']}"
    sys.exit("Amplify app spbc-tech-assistant not found")


class Page:
    def __init__(self, ws):
        self.ws, self.n, self.logs = ws, 0, []

    async def call(self, method, **params):
        self.n += 1
        my = self.n
        await self.ws.send(json.dumps({"id": my, "method": method, "params": params}))
        while True:
            msg = json.loads(await self.ws.recv())
            if msg.get("id") == my:
                return msg.get("result", {})
            if msg.get("method") == "Runtime.exceptionThrown":
                self.logs.append("EXCEPTION " + json.dumps(msg["params"]["exceptionDetails"])[:300])
            elif msg.get("method") == "Runtime.consoleAPICalled" and msg["params"]["type"] == "error":
                self.logs.append("console.error " + " ".join(str(a.get("value", a.get("description", "")))[:200]
                                                              for a in msg["params"]["args"]))

    async def js(self, expr):
        r = await self.call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
        return r.get("result", {}).get("value")

    async def wait_for(self, expr, timeout=40):
        end = time.time() + timeout
        while time.time() < end:
            if await self.js(expr):
                return True
            await asyncio.sleep(0.25)
        return False


OBSERVER = """(() => { if (window.__ev) return true; window.__ev = [];
  const box = document.getElementById('chatbot-messages');
  const snap = () => { const b = [...box.querySelectorAll('.bot-message')]; const l = b[b.length - 1]; if (!l) return;
    const text = (l.querySelector('.loading-text') || l).textContent; const cls = l.className;
    const prev = window.__ev[window.__ev.length - 1];
    if (!prev || prev.text !== text || prev.cls !== cls) window.__ev.push({ t: performance.now(), n: b.length, cls, text }); };
  new MutationObserver(snap).observe(box, { childList: true, subtree: true, characterData: true, attributes: true });
  return true; })()"""

BUBBLE = """(() => { const b = [...document.querySelectorAll('#chatbot-messages .bot-message')];
  const last = b[b.length - 1]; if (!last) return null;
  return { n: b.length, cls: last.className, text: (last.querySelector('.loading-text') || last).textContent }; })()"""


async def ask(page, question):
    await page.js(OBSERVER)
    before = (await page.js(BUBBLE))["n"]
    start = await page.js("performance.now()")
    await page.js(f"""(() => {{ const i = document.getElementById('chatbot-input'); i.value = {json.dumps(question)};
        document.getElementById('chatbot-form').dispatchEvent(new Event('submit', {{cancelable: true}})); }})()""")
    t0, final = time.time(), None
    while time.time() - t0 < 90:
        b = await page.js(BUBBLE)
        if b and b["n"] > before and "loading-message" not in b["cls"] and "streaming" not in b["cls"]:
            final = b["text"]
            break
        await asyncio.sleep(0.2)
    events = await page.js(f"window.__ev.filter(e => e.t >= {start} && e.n > {before})") or []
    timeline, last, first_words = [], None, None
    for e in events:
        state = "loading" if "loading-message" in e["cls"] else "streaming" if "streaming" in e["cls"] else "final"
        t = (e["t"] - start) / 1000
        if state == "streaming" and first_words is None and e["text"].strip():
            first_words = t
        key = (state, e["text"] if state == "loading" else len(e["text"]) // 60)
        if key != last:
            timeline.append((round(t, 1), state, e["text"][:70].replace("\n", " ")))
            last = key
    total = timeline[-1][0] if final and timeline else None
    return timeline, first_words, total, final


async def main():
    url = sys.argv[1] if len(sys.argv) > 1 else amplify_url()
    # A fresh customer: a clean conversation history, no effect on the demo login
    import pathlib, secrets as _s, string as _st, uuid as _u
    cfg = json.loads((pathlib.Path(__file__).resolve().parents[1] / "web-app" / "cognito-config.json").read_text())
    idp = boto3.client("cognito-idp", region_name=REGION)
    login = {"username": f"browser{_u.uuid4().hex[:8]}",
             "password": "".join(_s.choice(_st.ascii_letters + _st.digits) for _ in range(16)) + "a1!A"}
    idp.admin_create_user(UserPoolId=cfg["UserPoolId"], Username=login["username"], MessageAction="SUPPRESS")
    idp.admin_set_user_password(UserPoolId=cfg["UserPoolId"], Username=login["username"],
                                Password=login["password"], Permanent=True)
    browser = next((b for b in BROWSERS if os.path.exists(b)), None) or sys.exit("No Brave/Chrome found")
    profile = tempfile.mkdtemp(prefix="cdp-")
    proc = subprocess.Popen([browser, "--headless=new", f"--remote-debugging-port={PORT}", f"--user-data-dir={profile}",
                             "--window-size=1280,900", "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    failures = []
    try:
        for _ in range(40):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json"))
                ws_url = next(t["webSocketDebuggerUrl"] for t in tabs if t["type"] == "page")
                break
            except Exception:  # pylint: disable=broad-exception-caught
                time.sleep(0.25)
        async with websockets.connect(ws_url, max_size=2**24) as ws:
            page = Page(ws)
            await page.call("Runtime.enable")
            await page.call("Page.enable")
            await page.call("Page.navigate", url=f"{url}/login.html")
            await page.wait_for("!!document.getElementById('loginForm')")
            await page.js(f"""(() => {{ document.getElementById('username').value = {json.dumps(login['username'])};
                document.getElementById('password').value = {json.dumps(login['password'])};
                document.getElementById('loginForm').dispatchEvent(new Event('submit', {{cancelable: true}})); }})()""")
            ok = await page.wait_for("location.pathname.endsWith('index.html') || location.pathname === '/'", 40)
            ok = ok and await page.wait_for("!!(window.fixedAgentCoreClient && window.fixedAgentCoreClient.isReady())", 40)
            print(f"{'PASS' if ok else 'FAIL'}  signed in through the real login page ({url})")
            if not ok:
                failures.append("login")
            for q in QUESTIONS:
                timeline, first_words, total, final = await ask(page, q)
                print(f"\n## {q}")
                for t, state, text in timeline:
                    print(f"   {t:5.1f}s  {state:9s} {text!r}")
                streamed = any(s == "streaming" for _, s, _ in timeline)
                leak = any(re.search(r"<\s*/?\s*(thinking|answer|reasoning)", txt, re.I) for _, _, txt in timeline) or \
                    bool(final and re.search(r"<\s*/?\s*(thinking|answer|reasoning)", final, re.I))
                good = bool(final) and streamed and not leak and "error" not in (final or "").lower()
                fw = f"{first_words:.1f}s" if first_words else "-"
                tt = f"{total:.1f}s" if total else "timeout"
                print(f"{'PASS' if good else 'FAIL'}  streamed={streamed} leak={leak} first words {fw} final {tt}")
                if not good:
                    failures.append(q)
            if page.logs:
                print("\nbrowser errors:", *page.logs[:6], sep="\n  ")
    finally:
        proc.terminate()
        idp.admin_delete_user(UserPoolId=cfg["UserPoolId"], Username=login["username"])
        shutil.rmtree(profile, ignore_errors=True)
    print(f"\n{'ALL PASSED' if not failures else 'FAILED: ' + ', '.join(failures)}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())
