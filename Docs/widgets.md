# Widgets de la barre latérale

Une pastille au pied de la barre latérale montre une petite valeur lue sur un onglet ouvert (messages non lus, prochain rendez-vous…).

## Ce que c'est
- `PageWidget` (BrowserCore) : un site, un nom, un symbole SF, une teinte, une **source en lecture seule** : le nombre entre parenthèses du titre de l'onglet, le nombre d'éléments d'un sélecteur CSS, ou le texte d'un élément. Jamais de script.
- `WidgetPolicy.validated` refuse un site sans domaine, un motif qui ne compile pas ou n'a pas exactement un groupe, un sélecteur trop large ou dangereux (mêmes règles que les boosts), et ramène un symbole inconnu au symbole par défaut.
- Gmail est fourni (`WidgetPolicy.gmail`) : Gmail met le nombre de non lus dans le titre de l'onglet.
- Lecture : `refreshWidgets()` toutes les 20 s et à chaque changement de titre ou d'onglet, dans un monde JavaScript isolé. Pas de lecture des onglets privés ni des onglets endormis ; jamais de page chargée en cachette.

## Créer un widget (⌘K › « Créer un widget pour cette page… »)
1. L'utilisateur décrit ce qu'il veut voir.
2. Le **modèle local d'Apple** (sur le Mac, rien ne part) reçoit la liste numérotée des éléments de la page avec leur texte **réduit à sa forme** (a = lettre, 0 = chiffre) : jamais le contenu d'un message ou d'un agenda. Il répond par un numéro de ligne, pas par un sélecteur.
3. Orée lit la valeur pour de vrai ; sans valeur (compteur à 0, texte vide) il n'y a pas de widget.
4. Un aperçu montre la valeur et ce qui est lu ; rien n'est ajouté avant « Ajouter ». Clic droit sur une pastille : « Retirer ce widget ».
Le nom, le symbole et la teinte viennent de la demande et du site (`WidgetPolicy.style`), pas du modèle, qui les choisit mal.

## Mesures et limites (octobre 2026, modèle local de macOS 27 bêta)
- Une demande prend 12 à 25 s au modèle.
- Page de test : « le prochain rendez-vous de l'agenda » → le bon élément ; « le nombre de messages non lus » → le mauvais (il compte toutes les lignes, pas les non lues) : le petit modèle ne sait pas, d'après des classes opaques et des textes masqués, laquelle désigne les non lus. D'où l'aperçu obligatoire : la valeur affichée (5 au lieu de 2) permet de refuser.
- Non testé sur un vrai Gmail ou Google Agenda (pas de compte dans les essais).
- Bancs : `scripts/bench/widget_check.py` (pastilles, 7 vérifications), dev op `tab widgetmodel` (flux complet avec le modèle, demande dans /tmp/oree-widget-request.txt ; il écrit dans les réglages de l'utilisateur : supprimer `settings.pageWidgets` après).
