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
        print("\nAdresses et cartes")
        print("  ", ui("tab", "afseed", "0"), ui("tab", "afcount", "0"))
        def val(expr): return ui("eval", expr)
        def fill(kind):
            open("/tmp/oree-af-kind.txt", "w").write(kind); ui("tab", "affill", "0"); time.sleep(1.5)
        ui("load", f"http://127.0.0.1:{PORT}/address.html"); time.sleep(3); fill("address")
        got = [val(f"document.getElementById('{i}').value") for i in ("fn", "ln", "em", "tel", "org", "a1", "a2", "zip", "city", "country")]
        check("champs marqués par autocomplete : tout est rempli " + str(got), got == ["Ana", "Dupont", "ana@exemple.fr", "0612345678", "Exemple SA", "12 rue des Lilas", "Bât. B", "75011", "Paris", "FR"])
        ui("load", f"http://127.0.0.1:{PORT}/french.html"); time.sleep(3); fill("address")
        got = [val(f"document.getElementById('{i}').value") for i in ("p", "n", "mail", "mob", "adr", "cplt", "cp", "vil", "pays", "soc")]
        check("formulaire en français sans autocomplete : champs reconnus par leur nom, leur forme et leur étiquette " + str(got), got == ["Ana", "Dupont", "ana@exemple.fr", "0612345678", "12 rue des Lilas", "Bât. B", "75011", "Paris", "France", "Exemple SA"])
        ui("load", f"http://127.0.0.1:{PORT}/card.html"); time.sleep(3); fill("card")
        got = [val(f"document.getElementById('{i}').value") for i in ("holder", "num", "mm", "yy", "cvc")]
        check("carte : titulaire, numéro, mois et année (listes) remplis, code de sécurité JAMAIS " + str(got), got == ["ANA DUPONT", "4242424242424242", "08", "2031", ""])
        ui("load", f"http://127.0.0.1:{PORT}/card2.html"); time.sleep(3); fill("card")
        got = [val(f"document.getElementById('{i}').value") for i in ("num", "exp", "cvc")]
        check("carte : date en un seul champ « MM/AA » de 5 caractères " + str(got), got == ["4242424242424242", "08/31", ""])
        ui("load", f"http://127.0.0.1:{PORT}/otp.html"); time.sleep(3); fill("address")
        check("un formulaire sans champ d'adresse n'est pas touché", val("document.getElementById('otp').value") in ("", "null"))
        open("/tmp/oree-af-values.json", "w").write('{"name": "Bob Martin", "address-line1": "3 avenue Foch", "postal-code": "69006", "address-level2": "Lyon"}')
        check("l'adresse d'un formulaire envoyé est reconnue comme nouvelle (nom coupé en prénom et nom)", "street=3 avenue Foch city=Lyon first=Bob last=Martin known=false" in ui("tab", "afsubmit", "0"))
        open("/tmp/oree-af-values.json", "w").write('{"given-name": "Ana", "address-line1": "12 RUE des lilas", "postal-code": "75011", "address-level2": "Paris"}')
        check("une adresse déjà enregistrée (écrite autrement) n'est pas reproposée", "known=true" in ui("tab", "afsubmit", "0"))
        print("\nBannières de cookies")
        def page(name, wait=4):
            ui("load", f"http://127.0.0.1:{PORT}/{name}"); time.sleep(wait)
        page("cookies_known.html", 5)
        check("un gestionnaire connu qui arrive après le chargement : « Tout refuser » est cliqué, jamais « Tout accepter »", val("window.__rejected") == "1" and val("window.__accepted") == "0")
        page("cookies_text.html")
        check("une bannière maison : « Continuer sans accepter » est cliqué, « J'accepte » jamais", val("window.__rejected") == "1" and val("window.__accepted") == "0")
        page("cookies_none.html", 6)
        check("une bannière sans bouton de refus clair reste telle quelle (rien n'est accepté à la place de la personne)", val("window.__accepted") == "0")
        page("refuse_invite.html")
        check("un bouton « Refuser » hors d'une bannière de consentement n'est pas touché", val("window.__clicks") == "0")
    finally:
        proc.terminate(); proc.wait(timeout=10); server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
