#!/usr/bin/env python3
"""La Rime (oree://rime/) dans Orée : la page se charge avec ses polices, une prod synthétique est analysée (tempo et premier temps justes), le jeu des 4 cases démarre et avance sur le beat.

  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/rime_check.py
Les essais des mots et de la détection du tempo (sans l'app) : node scripts/bench/rime_words_test.js ; node scripts/bench/rime_bpm_test.js
"""
import json, os, subprocess, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh"); APP = os.environ["OREE_TEST_APP"]
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
SYNTH = """(function(){var sr=44100,bpm=100,off=0.3,secs=24,ctx=new AudioContext(),b=ctx.createBuffer(1,sr*secs,sr),x=b.getChannelData(0),beat=60/bpm,seed=1,r=function(){return (seed=seed*16807%2147483647)/2147483647};
function add(t,f,len,amp,noise){var s0=Math.floor(t*sr);for(var i=0;i<len*sr&&s0+i<x.length;i++){var e=Math.exp(-i/sr*(noise?60:18));x[s0+i]+=amp*e*(noise?r()*2-1:Math.sin(2*Math.PI*f*(1+2*Math.exp(-i/sr*30))*i/sr))}}
for(var k=0;off+k*beat<secs-0.3;k++){var t=off+k*beat;if(k%4===0||k%8===6)add(t,55,0.3,0.9,false);if(k%4===1||k%4===3)add(t,0,0.15,0.4,true);add(t+beat/2,0,0.04,0.12,true)}
var d=__rime.loadBuffer(b);return JSON.stringify({bpm:d.bpm,offset:d.offset,confidence:d.confidence})})()"""

if __name__ == "__main__":
    tmp = tempfile.mkdtemp(prefix="rime-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.makedirs(os.path.join(tmp, "ext")); os.environ["HB_AUTOMATION_DIR"] = auto
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AI_NO_AGENT="1", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"))
    p = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    shots = os.environ.get("RIME_SHOTS")
    try:
        time.sleep(9); ui("load", "oree://rime/"); time.sleep(3)
        check("la page se charge (titre « La Rime »)", ui("eval", "document.title") == "La Rime")
        print("   polices :", ui("eval", "Array.from(document.fonts).map(function(f){return f.family+':'+f.status}).join(' ')"))
        check("les polices d'Orée sont chargées", ui("eval", "Array.from(document.fonts).filter(function(f){return f.status==='loaded'}).length>=2") in ("true", "1"))
        if shots: ui("snapshot", os.path.join(shots, "rime-intro.png"))
        d = json.loads(ui("eval", SYNTH) or "{}")
        check(f"une prod à 100 BPM est analysée juste (trouvé {d.get('bpm')} BPM)", abs(d.get("bpm", 0) - 100) < 0.6)
        check(f"son premier temps est trouvé à ±40 ms (trouvé {d.get('offset', 0):.3f} s, attendu 0,300 s)", min(abs(d.get("offset", 9) - 0.3), abs(d.get("offset", 9) - 0.3 - 2.4)) < 0.04)
        time.sleep(0.4)
        if shots: ui("snapshot", os.path.join(shots, "rime-prod.png"))
        print("   contrôles :", ui("eval", "['half','double','offsetRow','preview'].map(function(i){var e=document.getElementById(i);return i+':'+(e?(e.hidden?'caché':Math.round(e.getBoundingClientRect().width)):'absent')}).join(' ')"))
        check("l'écran propose « ×2 », « ÷2 », le décalage et l'écoute avec le clic", ui("eval", "['half','double','offsetRow','preview'].every(function(i){var e=document.getElementById(i);return e&&!e.hidden&&e.getBoundingClientRect().width>0})") in ("true", "1"))
        check("le niveau « Normal » est choisi par défaut et les 16 mesures aussi", ui("eval", "__rime.state.level + ' ' + __rime.state.length") == "normal 16")
        jouer = json.loads(ui("eval", "(function(){document.getElementById('start').scrollIntoView({block:'center'});var r=document.getElementById('start').getBoundingClientRect();return JSON.stringify({x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2+52)})})()") or "{}")
        print("   bouton Jouer :", jouer); ui("key", "return"); time.sleep(2.5)
        if shots: ui("snapshot", os.path.join(shots, "rime-click.png"))
        print("   son :", ui("eval", "__rime.audio + ' temps=' + __rime.time.toFixed(2)"))
        check("la partie démarre avec la prod (mode jeu)", ui("eval", "__rime.state.mode") == "game")
        check("le décompte et les premières mesures sont dessinés, 4 cases chacune", ui("eval", "document.querySelectorAll('#rows .bar').length >= 5 && Array.from(document.querySelectorAll('#rows .bar')).every(function(b){return b.querySelectorAll('.cell').length===4})") in ("true", "1"))
        check("niveau Normal en histoire : un début de phrase, puis la rime plurisyllabique en 4e case", ui("eval", "(function(){var b=document.querySelector('#rows .bar[data-i=\"1\"]');var c=Array.from(b.querySelectorAll('.cell')).map(function(x){return x.textContent});return c[0].length>3&&c[1]===''&&c[2]===''&&c[3].length>3})()") in ("true", "1"))
        check("la structure de la prod est affichée (pastilles par mesure)", ui("eval", "document.querySelectorAll('#structure i').length") not in ("", "0"))
        if shots: ui("snapshot", os.path.join(shots, "rime-play.png"))
        time.sleep(7)
        check("le temps passe : la mesure 1 est atteinte (le beat de la prod fait avancer le jeu)", "mesure" in ui("eval", "document.getElementById('barNo').textContent"))
        if shots: ui("snapshot", os.path.join(shots, "rime-play2.png"))
        check("la balle (Luciole) bouge d'une case à l'autre", ui("eval", "document.getElementById('luciole').style.transform.length>10") in ("true", "1"))
    finally:
        p.terminate()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
