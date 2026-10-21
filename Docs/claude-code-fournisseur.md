# Luciole répond par Claude Code

Réglages › Assistant › Fournisseur › **Claude Code (votre abonnement Claude)**. Orée lance le programme `claude` de ce Mac (`claude -p`), déjà installé et connecté : pas de clé à donner à Orée.
À usage personnel : ce n'est pas un moyen de distribuer l'app avec l'abonnement de quelqu'un d'autre (chaque client aurait besoin de sa propre connexion ou clé).

## Comment ça marche

- `ClaudeCodePrompt` (BrowserCore, pur, testé) transforme la requête de Luciole en texte : la consigne, la liste des outils permis (nom, arguments typés, exemple d'appel exact), puis la conversation.
  Claude répond par des lignes JSON `{"tool":"click","ref":"@e3"}` ou par du texte ; `AgentParser` les lit comme pour tout autre fournisseur, donc **tous les garde-fous restent actifs** (adresses inconnues, valeurs personnelles inventées, confirmations, voile de validation).
- `ClaudeCodeClient` (BrowserUI) lance un processus par tour : `claude -p --model haiku --tools "" --no-session-persistence --output-format json --setting-sources project --disable-slash-commands --strict-mcp-config --system-prompt …`, la conversation par l'entrée standard, dans un dossier vide.
  `--setting-sources project` retire les réglages, mémoires et hooks de l'utilisateur : ~500 jetons d'entrée au lieu de ~1 400.
- `ClaudeCodeLocator` cherche `claude` (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.claude/local`, `~/.local/bin`, le PATH) ; `HB_CLAUDE_PATH` pour les essais.
- Modèles : `haiku` (défaut, le moins coûteux pour la limite), `sonnet`, `opus`.

## Mesures (22 octobre 2026, Haiku)

- Question simple : ~5 s de bout en bout (2 s pour le modèle, le reste est le démarrage du programme et la consigne d'Orée). Calcul avec l'outil : ~8 s (deux appels). Défilement : ~14 s (deux ou trois appels).
- ~100 appels par jour pour ton usage (d'après le journal) ≈ 215 000 jetons ; chaque appel compte dans la limite de l'abonnement (`/usage` dans Claude Code).

## Limites

- Plus lent qu'un service rapide (Groq : 1 à 2 s) : un processus par tour, sans session gardée (la conversation est renvoyée en entier, comme avec une API). Un processus persistant (`--input-format stream-json`) supprimerait le démarrage mais garderait la conversation côté Claude : à étudier.
- Pas de réponse en flux : le texte arrive d'un bloc.
- Les pages lues partent chez Anthropic.
- Si Claude Code n'est pas connecté ou si la limite est atteinte, Luciole le dit et propose de changer de fournisseur.

## Tester

```
./scripts/test.sh --fast                                                  # ClaudeCodePromptTests
OREE_TEST_APP=… python3 scripts/bench/claude_code_check.py                # utilise vraiment `claude` : quelques appels Haiku sur votre limite
```
