# Rend les prompts de l'essai d'appel d'outils avec le modèle de conversation OFFICIEL de Qwen3.5 (Jinja), pour ne pas écrire le format à la main.
#   python3 -m venv venv && venv/bin/pip install jinja2
#   curl -L https://huggingface.co/Qwen/Qwen3.5-2B/raw/main/chat_template.jinja -o qwen35.jinja
#   venv/bin/python render.py            (PROMPT=v2 pour la consigne améliorée)
#   OreeAI --probe cases.jsonl --grammar grammar.gbnf > sortie.jsonl ; venv/bin/python score.py sortie.jsonl
import json, sys
from jinja2 import Environment
from jinja2.sandbox import SandboxedEnvironment
import os
from tools import TOOLS, SYSTEM, SYSTEM_V2
from cases import CASES
def raise_exception(m): raise Exception(m)
env = SandboxedEnvironment(trim_blocks=False, lstrip_blocks=False)
env.policies["json.dumps_kwargs"] = {"ensure_ascii": False}
env.filters["tojson"] = lambda v, **k: json.dumps(v, ensure_ascii=False)
env.globals["raise_exception"] = raise_exception
if os.environ.get("PROMPT") == "v2": SYSTEM = SYSTEM_V2
OUT = "cases_v2.jsonl" if SYSTEM is SYSTEM_V2 else "cases.jsonl"
tpl = env.from_string(open("qwen35.jinja").read())
with open(OUT, "w") as out:
    for c in CASES:
        user = f"Tâche : {c['task']}\n\n<page>\n{c['page']}\n</page>"
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]
        text = tpl.render(messages=msgs, tools=TOOLS, add_generation_prompt=True, enable_thinking=False)
        out.write(json.dumps({"id": c["id"], "prompt": text}, ensure_ascii=False) + "\n")
print(len(CASES), "cas")
