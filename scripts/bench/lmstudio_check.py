#!/usr/bin/env python3
"""Vérification de bout en bout de la connexion à LM Studio, sans LM Studio : un faux serveur local imite `/v1/models` et `/v1/chat/completions`
(avec un appel d'outil), dans une instance d'Orée séparée. Contrôle : les modèles sont lus depuis l'API (le modèle d'« embedding » est écarté), la question
part au premier modèle de conversation avec les outils du contrat et sans clé, la réponse arrive, et un serveur absent donne un écran clair.

  python3 scripts/bench/lmstudio_check.py
"""
import http.server, json, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
PORT = 8795
requests = []

class Fake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        data = json.dumps(obj).encode(); self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path == "/page": 
            data = "<html><body><h1>Page de test</h1><p>Du texte.</p></body></html>".encode(); self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        elif self.path == "/v1/models": self._send({"object": "list", "data": [{"id": "text-embedding-nomic-embed-text-v1.5"}, {"id": "fake-model"}, {"id": "autre-modele"}]})
        else: self.send_response(404); self.end_headers()
    def _sse(self, chunks, pause=0.0):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.end_headers()
        for chunk in chunks:
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode()); self.wfile.flush(); time.sleep(pause)
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        prompt = body["messages"][-1]["content"]
        requests.append({"path": self.path, "auth": self.headers.get("Authorization"), "model": body.get("model"), "stream": body.get("stream"), "task": prompt.split("TÂCHE :")[-1].split("\n")[0].strip(),
                         "tools": [t["function"]["name"] for t in body.get("tools", [])]})
        task = requests[-1]["task"]
        def call(index, name, args, first=True): return {"choices": [{"delta": {"tool_calls": [{"index": index, "function": ({"name": name, "arguments": ""} if first else {"arguments": args})}]}}]}
        if "Défile" in task:       # deux appels dans une seule réponse (défiler, puis répondre), arguments fragmentés
            self._sse([call(0, "scroll", ""), call(0, "", '{"direction":', False), call(0, "", '"down"}', False), call(1, "done", ""), call(1, "", '{"answer":"Deux appels, un seul tour."}', False)])
        elif "Pense" in task:     # un modèle qui réfléchit : d'abord des « pensées », puis la réponse
            self._sse([{"choices": [{"delta": {"reasoning_content": piece}}]} for piece in ["Je regarde ", "la question, ", "puis je réponds. "]] + [{"choices": [{"delta": {"content": "Réponse après réflexion."}}]}], pause=0.7)
        elif "Outil" in task:     # la réponse donnée par l'outil `done`, dont les arguments arrivent en morceaux
            self._sse([call(0, "done", "")] + [call(0, "", frag, False) for frag in ['{"answer":"Ceci ', 'est écrit ', 'par morceaux ', 'dans l\'outil."}']], pause=0.7)
        elif "bonjour" in task.lower():      # du texte qui s'écrit lentement
            self._sse([{"choices": [{"delta": {"content": piece}}]} for piece in ["Bonjour ", "le ", "monde ", "en flux."]], pause=0.7)
        else:
            self._sse([call(0, "done", ""), call(0, "", '{"answer": "Réponse du faux LM Studio.', False), call(0, "", '"}', False)])

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()
def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())
def state(): return ui("tab", "aistate", "0")
def wait_for(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred(): return True
        time.sleep(0.4)
    return False

def launch(url):
    before = pids(); tmp = tempfile.mkdtemp(prefix="lmcheck-"); ext = os.path.join(tmp, "ext"); os.makedirs(ext)
    env = ["HB_FRESH_SESSION=1", f"HB_DB_PATH={tmp}/db.sqlite", f"HB_EXT_DIR={ext}", "HB_AI_NO_AGENT=1", "HB_AI_PROVIDER=lmstudio", f"HB_LMSTUDIO_URL={url}"]
    subprocess.run(["open", "-g", "-n", *[x for e in env for x in ("--env", e)], APP, "--args", "--automation"]); time.sleep(5)
    return pids() - before

def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Fake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    mine = launch(f"http://127.0.0.1:{PORT}/v1")
    try:
        ui("tab", "aibar", "0")
        check("le panneau est prêt avec LM Studio (modèles lus depuis l'API)", wait_for(lambda: "state=ready" in state(), 15))
        open("/tmp/oree-ai-query.txt", "w").write("Réponds"); ui("tab", "aiquery", "0")
        check("la réponse du serveur arrive dans le panneau", wait_for(lambda: "Réponse du faux LM Studio." in state(), 30))
        r = requests[-1] if requests else {}
        check("la question part au premier modèle de conversation (pas l'embedding)", r.get("model") == "fake-model")
        check("avec les outils du contrat", r.get("tools") == ["search_web", "open_url", "read_page", "click", "type", "select", "scroll", "fill_form", "ask_user", "done"])
        check("en demandant le flux", r.get("stream") is True)
        check("sans aucune clé", r.get("auth") is None)
        check("à l'adresse locale de conversation", r.get("path") == "/v1/chat/completions")

        print("\nFlux de texte")
        seen = []
        open("/tmp/oree-ai-query.txt", "w").write("Dis bonjour"); ui("tab", "aiquery", "0")
        end = time.time() + 20
        while time.time() < end:
            answer = state().split("answer=", 1)[-1]
            if answer and (not seen or seen[-1] != answer): seen.append(answer)
            if "running=false" in state() and "en flux." in answer: break
            time.sleep(0.2)
        print("   morceaux vus :", seen)
        check("le texte apparaît par morceaux avant la fin", len(seen) >= 3 and seen[0] != seen[-1] and "en flux." not in seen[0])
        check("le texte final est complet", bool(seen) and "Bonjour le monde en flux." in seen[-1])

        print("\nRéponse donnée par l'outil done, en morceaux")
        seen2 = []
        open("/tmp/oree-ai-query.txt", "w").write("Réponds avec l'Outil"); ui("tab", "aiquery", "0")
        end = time.time() + 20
        while time.time() < end:
            answer = state().split("answer=", 1)[-1]
            if answer and (not seen2 or seen2[-1] != answer): seen2.append(answer)
            if "running=false" in state() and "dans l'outil." in answer: break
            time.sleep(0.2)
        print("   morceaux vus :", seen2)
        check("la réponse de l'outil s'écrit au fur et à mesure", len(seen2) >= 3 and "dans l'outil." not in seen2[0])
        check("et finit complète", bool(seen2) and seen2[-1].strip() == "Ceci est écrit par morceaux dans l'outil.")

        print("\nModèle qui réfléchit")
        thought = 0
        open("/tmp/oree-ai-query.txt", "w").write("Pense un peu"); ui("tab", "aiquery", "0")
        end = time.time() + 20
        while time.time() < end:
            st = state()
            if "think=" in st:
                try: thought = max(thought, int(st.split("think=")[1].split()[0]))
                except ValueError: pass
            if "running=false" in st and "Réponse après réflexion." in st: break
            time.sleep(0.2)
        check("les pensées s'affichent pendant l'attente", thought > 10)
        check("puis la réponse remplace les pensées", "Réponse après réflexion." in state() and "think=0" in state())

        print("\nPlusieurs appels d'un coup")
        ui("load", f"http://127.0.0.1:{PORT}/page"); time.sleep(2.5)
        before = len(requests)
        open("/tmp/oree-ai-query.txt", "w").write("Défile puis réponds"); ui("tab", "aiquery", "0")
        check("la réponse arrive", wait_for(lambda: "Deux appels, un seul tour." in state(), 30))
        check("un seul appel au serveur pour les deux outils", len(requests) - before == 1)
        check("l'action a bien été faite (trace)", "done:Défilement de la page" in state())
    finally:
        for p in mine: subprocess.run(["kill", p])
    time.sleep(1)
    mine = launch("http://127.0.0.1:9/v1")      # personne n'écoute
    try:
        ui("tab", "aibar", "0")
        check("un serveur absent : le panneau le dit, sans planter", wait_for(lambda: "state=unreachable" in state(), 15))
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
