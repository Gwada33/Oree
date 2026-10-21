# Journal d'événements d'Orée

Un journal, **désactivé par défaut**, qui note la façon dont on se sert d'Orée pour pouvoir **mesurer et régler sa vitesse avec des chiffres réels** (préchargements, veille des onglets, temps de
chargement). Tout reste sur ce Mac. Rien n'est envoyé nulle part. Aucun modèle n'est embarqué : le journal prépare le terrain (jeu de données, banc de rejeu) sans rien décider tout seul.

Réglages › Confidentialité › « Journal d'événements » : activer, durée de garde (7, 30 ou 90 jours), exporter, effacer.

## Ce qui n'est JAMAIS écrit
Adresses complètes, titres, textes de pages, ce que vous tapez, les touches, le contenu des champs, les noms de fichiers téléchargés, ce que vous dites à Luciole ou ses réponses, quoi que ce
soit venant d'un onglet privé ou d'une page contenant un champ de mot de passe. Les sites ne sont que des **empreintes** (HMAC-SHA-256 du domaine avec une clé propre à ce Mac, 8 octets) : on peut
compter « le même site » sans pouvoir retrouver lequel.

Ce n'est pas une promesse de la page ou du code qui écrit : c'est le **schéma** (`BrowserCore/JournalSchema.swift`) qui l'impose. Chaque événement a une liste fermée de champs (nombres bornés,
mots d'une liste, empreintes) ; ce qui n'y est pas est jeté avant l'écriture. Même une page web qui enverrait de faux événements ne peut y faire entrer ni adresse ni texte
(`JournalIngest` reconstruit tout : l'onglet est celui que l'app connaît, le site est celui de la page, un nom d'hôte devient une empreinte et disparaît).

## Où et comment c'est gardé
- `~/Library/Application Support/HyperBrowser/Journal/journal-AAAA-MM-JJ.ojl` (un fichier par jour, droits 0600). Blocs `[longueur sur 4 octets][boîte chiffrée ChaCha20-Poly1305]`, chaque bloc des lignes JSON.
- Clé dans le Trousseau (`com.nolhan.hyperbrowser.journal`). Effacer le journal et sa clé rend les empreintes inversibles à personne.
- Écriture sur une file à part, par paquets (toutes les 3 s, à 200 événements, ou à la fermeture) : aucune écriture sur le fil principal.
- Garde : 30 jours par défaut, 100 Mo au plus ; le plus ancien part d'abord.
- Export (JSON Lines, **déchiffré**, avec une ligne d'en-tête) : `scripts/journal/analyze.py fichier.jsonl` en tire les chiffres (précision des règles de préchargement, temps de réveil, durées…).

## Les événements (schéma v1)
| Famille | Événements | Ce qu'on y mesure |
|---|---|---|
| Session | `session.start` (version, système, écran, cœurs, mémoire, énergie, temps de démarrage, onglets restaurés), `session.end`, `app.active`, `sys.state` (thermique, économie d'énergie, charge, pression mémoire), `window.layout`, `perf.mem` (toutes les minutes) | contexte matériel, cadence d'usage |
| Onglets | `tab.open` (comment : nouveau, lien, palette, restauration, externe, archive…), `tab.select` (comment : clic, clavier, récent, palette ; temps passé sur le précédent ; temps depuis la dernière fois ; en veille ou non), `tab.close` (durée de vie, temps au premier plan, pourquoi), `tab.sleep`, `tab.wake` (durée, déclencheur survol ou clic, fantôme), `tab.move`, `tab.hover` (durée, aperçu montré, clic), `space.switch` | quels onglets resservent, quand réveiller |
| Navigation | `nav.start` (comment : saisie, lien, formulaire, retour, rechargement ; site ; site précédent), `nav.commit`, `nav.done` (durée, réussite, code) | temps jusqu'à la première réponse et jusqu'à la fin |
| Page | `page.shape` (nombre de liens, boutons, champs, images ; vidéo ; classe de longueur du texte ; article ; mot de passe ; genre), `page.perf` (ttfb, dcl, load, lcp), `page.leave` (temps visible, profondeur de défilement, clics, touches) | ce qu'est la page, comment elle charge |
| Pointeur et clavier | `link.hover` (durée, cliqué ou non, case 10 × 10, rang vertical, genre de lien, même site ou externe), `link.click`, `ptr.window` (fenêtres de 2 s : distance, vitesse moyenne et maximale, pauses, changements de direction, déplacement net), `ptr.click`, `scroll.window`, `key.window` (un compte), `field.focus` (genre de champ), `text.select` (classe de longueur) | quels liens seront cliqués, comment on bouge |
| Barre d'adresse | `addr.focus`, `addr.input` (nombre de touches, durée, longueur en classe, effacements), `addr.suggest` (nombre proposé par genre, rang choisi), `addr.commit` | aider à choisir quoi préconnecter |
| Interface | `ui.panel` (quel panneau s'ouvre ou se ferme), `palette.use` (genre d'action, longueur de la recherche en classe, durée), `dl.start`, `dl.done` (taille en classe, durée), `media` (lecture, pause, PiP) | usages des fonctions |
| Luciole | `ai.task` (route, requêtes, jetons, durée, réussite, relances, recherches) | coût réel des tâches |

Le pointeur n'est jamais enregistré point par point : le script de la page résume des fenêtres de 2 s (un mouvement par fenêtre, pas de trajectoire). Les touches ne sont comptées que par fenêtres de 3 s.

## Ce que cela permet (sans rien embarquer)
1. **Régler les préchargements avec des chiffres** : `analyze.py` rejoue les survols de liens et dit, pour chaque seuil (« le pointeur reste ≥ 250 ms »), la part de préchargements utiles et la part des clics couverts.
2. **Régler la veille** : combien d'onglets en veille sont rouverts, après combien de temps, quelle latence de réveil.
3. **Plus tard**, si l'on veut tenter un modèle (Create ML / Core ML), le journal est déjà le jeu de données : même format, mêmes variables, rejouable. La règle simple reste la référence à battre.

## Limites
- Les navigations internes d'une application web (changement d'adresse sans rechargement) ne sont pas vues comme des navigations.
- Les pages (re)chargées avant l'activation n'ont pas le script : elles commencent à être observées au prochain chargement. Les événements d'onglets et de navigation n'ont pas besoin du script.
- Le journal ne dit rien de la qualité d'un résultat (une page lente peut être la bonne) : il mesure des durées et des gestes, pas des intentions.
- Un journal d'une seule journée donne un premier signal sur vos habitudes, pas assez pour les cas rares ; ce qu'il apprend ne vaut que pour vous.

## Banc de rejeu du préchargement

`python3 scripts/journal/prefetch_replay.py journal-oree-AAAA-MM-JJ.jsonl` compare la règle « précharger après T ms de survol » à un petit modèle (régression logistique, numpy seulement) appris sur les 70 % premiers du journal et testé sur les 30 % derniers.
Le modèle n'utilise que ce qui est connu au moment du survol (genre et place du lien, site, forme de la page, vitesse du pointeur), jamais la durée finale ni le clic.
Premier essai (21 octobre 2026, 5 705 survols, ~1 000 cliqués, un seul utilisateur) : classement AUC 0,69 ; à couverture égale la règle ne perd rien (précharger tout ce qui dure ≥ 150 ms couvre 97 % des clics) ; à budget serré le modèle couvre bien plus (≈ 507 préchargements : 60 % des clics contre 30 %).
À relancer à chaque nouvel export : le modèle ne vaut la peine que si l'écart se confirme avec 5 000 à 10 000 survols cliqués.
