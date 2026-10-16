#!/usr/bin/env python3
"""Vérification de bout en bout des codes 2FA (remplissage d'un champ de code, d'un code en cases), dans une instance d'essai séparée (debug).

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/security_check.py
"""
import base64, functools, hashlib, hmac, http.server, os, struct, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "security_fixture")
PORT = 8798
SECRET = base64.b32decode("JBSWY3DPEHPK3PXP")

def totp(at=None, digits=6, period=30):
    counter = int((at or time.time()) // period)
    mac = hmac.new(SECRET, struct.pack(">Q", counter), hashlib.sha1).digest()
    o = mac[-1] & 0x0f
    return str((struct.unpack(">I", mac[o:o + 4])[0] & 0x7fffffff) % 10 ** digits).zfill(digits)

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def main():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="seccheck-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.makedirs(os.path.join(tmp, "ext"))
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto, HB_TAB_LAYOUT="vertical")
    os.environ["HB_AUTOMATION_DIR"] = auto
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        time.sleep(9)
        print("Code 2FA")
        ui("load", f"http://127.0.0.1:{PORT}/otp.html"); time.sleep(3)
        check("sans secret enregistré, rien n'est rempli", (ui("tab", "otpfill", "0"), time.sleep(1.5), ui("eval", "document.getElementById('otp').value"))[2] in ("", "null"))
        print("  ", ui("tab", "otpseed", "0"))
        before = totp()
        ui("tab", "otpfill", "0"); time.sleep(2.5)
        value = ui("eval", "document.getElementById('otp').value")
        after = totp()
        check(f"le champ de code reçoit le code du moment ({value})", value in (before, after) and len(value) == 6)
        ui("load", f"http://127.0.0.1:{PORT}/split.html"); time.sleep(3)
        ui("tab", "otpseed", "0"); ui("tab", "otpfill", "0"); time.sleep(2.5)
        boxes = ui("eval", "[...document.querySelectorAll('input.d')].map(i => i.value).join('')")
        check(f"un code en six cases est réparti case par case ({boxes})", boxes in (before, totp()) and len(boxes) == 6)
    finally:
        proc.terminate(); proc.wait(timeout=10); server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
