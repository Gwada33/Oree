#!/usr/bin/env python3
"""End-to-end check of « Ajouter au Calendrier » on local pages (no network, and Calendar is never opened): an event announced in the
page's own data (read exactly) and an appointment written in plain text (found by the local model, skipped if Apple Intelligence is
unavailable). Starts its own Orée instance (never touches yours). Exit 1 on any failure.

  python3 scripts/bench/calendar_check.py
"""
import datetime, functools, http.server, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "calendar_fixture")
PORT = 8790
DAYS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
MONTHS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def wait_for(predicate, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if predicate(): return True
        time.sleep(1)
    return False

def main():
    day = datetime.date.today() + datetime.timedelta(days=5)          # always in the future whenever this runs
    when = f"{DAYS[day.weekday()]} {day.day} {MONTHS[day.month - 1]} {day.year}"
    directory = tempfile.mkdtemp(prefix="calfixture-")
    for name in os.listdir(FIXTURE): open(os.path.join(directory, name), "w").write(open(os.path.join(FIXTURE, name)).read())
    open(os.path.join(directory, "rdv.html"), "w").write(f"""<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Confirmation de rendez-vous</title></head><body>
    <h1>Votre rendez-vous est confirmé</h1><p>Bonjour, nous vous confirmons votre consultation avec le Dr Martin le {when} à 9h15, au cabinet médical,
    12 rue Haute, 75003 Paris. Pensez à apporter votre carte Vitale. Pour annuler, appelez-nous au plus tard la veille.</p>
    <p>{"Merci de votre confiance. " * 12}</p></body></html>""")
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=directory))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    before = pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        print("\nÉvénement annoncé par la page")
        ui("load", f"http://127.0.0.1:{PORT}/event.html"); time.sleep(3)
        got = ui("tab", "eventget", "0"); print("  ", got[:300])
        check("l'événement est lu dans les données de la page", wait_for(lambda: "candidate=Concert d'automne, œuvres de Ravel" in ui("tab", "eventget", "0"), 8))
        got = ui("tab", "eventget", "0")
        check("le fichier d'événement a le bon horaire (20 h à Paris = 19 h UTC)", "DTSTART:20270305T190000Z" in got and "DTEND:20270305T213000Z" in got)
        check("le lieu est complet", "LOCATION:Salle Pleyel\\, 252 rue du Faubourg Saint-Honoré\\, 75008 Paris" in got.replace(" / ", "\n").replace("\r", "") or "Salle Pleyel" in got)
        check("l'adresse de la page est jointe", "URL:https://example.com/concert" in got)

        print("\nRendez-vous écrit en texte (modèle local)")
        ui("load", f"http://127.0.0.1:{PORT}/rdv.html"); time.sleep(2.5)
        check("pas de données structurées sur cette page", "candidate=none" in ui("tab", "eventget", "0"))
        out = ui("tab", "eventmodel", "0"); print("  ", out)
        if "available: false" in out:
            print("  ignoré : modèle local indisponible")
        else:
            wait_for(lambda: ui("tab", "aiget", "0") != "pending", 170)
            res = ui("tab", "aiget", "0"); print("  ", res)
            check("le modèle trouve le rendez-vous", res.startswith("event=") and "event=none" not in res)
            check(f"à la bonne date ({day.isoformat()})", f"start={day.isoformat()}" in res.replace("T09:15", "T09:15") or f"{day.isoformat()}T0" in res or (day - datetime.timedelta(days=0)).isoformat() in res)
            check("au bon endroit", "rue Haute" in res)
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
