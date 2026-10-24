# La Rime (oree://rime/)

Un outil de freestyle dans Orée, dans l'esprit de The Rhyme Game : un beat, des mesures de 4 cases, une balle (Luciole) qui saute de case en case ; la rime tombe dans la 4ᵉ. On rappe à voix haute : **Orée n'écoute pas et ne note pas** (comme l'original).

- **Où le trouver** : bouton « ♪ La Rime » en bas à droite de la page d'accueil, et ⌘K › « Jouer à La Rime ». Adresse : `oree://rime/`.
- **Niveaux** : Débutant (débuts de phrase dans les 3 premières cases), Normal (seulement la rime), Avancé (la rime disparaît à la 3ᵉ mesure d'un bloc de 4), Expert (montrée une seule fois par bloc). **Durée** : 8, 16, 32 mesures ou sans fin. **Rimes** : au hasard (une famille par bloc de 4 mesures) ou une famille choisie.
- **Beat** : celui d'Orée (batterie synthétisée, tempo réglable, « Taper le tempo ») ou **ta prod** (mp3, wav, m4a… déposé ou choisi) : le tempo et le premier temps sont détectés (`bpm.js`), à corriger avec −/+ , ÷2 / ×2, « Premier temps » ±10 ms et « Écouter avec le clic ». La prod reste dans la page, rien n'est envoyé.
- **Dictionnaire de rimes** : tape un mot, il liste les mots de la même famille (48 familles, ~1 000 mots).
- **Fichiers** : `Resources/Rime/` (index.html, style.css, game.js, words.js, bpm.js), servis par `OreeSchemeHandler` ; copiés dans l'app par `build_app.sh`.
- **Essais** : `node scripts/bench/rime_words_test.js`, `node scripts/bench/rime_bpm_test.js` (tempo juste sur des beats synthétiques, 90 à 140 BPM ; un tempo en double est ramené à sa moitié, d'où le bouton ×2), `OREE_TEST_APP=… python3 scripts/bench/rime_check.py` (11 vérifications dans l'app).
- **Limites** : détection du tempo vérifiée sur des beats synthétiques seulement, pas sur de vraies prods ; le glisser-déposer d'un fichier n'a pas été essayé dans Orée ; le beat d'Orée accélère pas (le tempo reste celui choisi).

## v3 : histoires, syllabes, structure de la prod
- **Style « Histoire »** (défaut) : 4 histoires de 8 mesures (`STORIES` dans `words.js`), rimes en couplets AABB. Chaque mesure = 3 morceaux + la rime plurisyllabique en 4ᵉ case ; les mesures se suivent comme un récit. Niveaux : Débutant = phrase entière, Normal = début de phrase + rime, Avancé = rime seule, Expert = la rime du 2ᵉ vers du couplet est cachée (…).
- **Style « Mots »** : l'ancien mode (une famille de rimes par bloc de 4 mesures), avec le choix « 2 syllabes et + » / « 3 et + » (`syl()` : approximation par groupes de voyelles).
- **Structure de la prod** (`analyzeSections` dans `bpm.js`) : énergie des graves (< 150 Hz) par mesure, seuil à 30 % du 80ᵉ centile → `beat` ou `calme`. Affichée avant de jouer (une pastille par mesure). Mesure sans beat : la phrase est posée d'un bloc, plus lentement, sur les 3 premiers temps (case étendue), la rime reste sur le 4ᵉ. Avec beat : un morceau par temps.
- Limites : la structure n'est lue que sur les 90 premières secondes (au-delà : « beat ») ; un break avec des basses ne sera pas vu comme calme ; seuil non réglé sur de vraies prods. Tests : `rime_bar_test.js`, `rime_bpm_test.js` (break synthétique), `rime_words_test.js`.
