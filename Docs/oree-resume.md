# Reprendre où tu en étais

Orée retient où vous en étiez dans une page et le propose à votre retour. Réglages › Reprise (activé par défaut).

| Cas | Ce qui est gardé | Ce qui est proposé |
|---|---|---|
| Article (voir ci-dessous), ≥ 3 écrans | fraction lue (5 à 97 %) et le début du paragraphe en haut de l'écran | « Reprendre la lecture (62 %) ? » : retour au paragraphe, sinon à la même fraction |
| Terminé (article lu à plus de 97 %) | position oubliée | rien |

**Seulement sur les articles** (12 oct. 2026, la reprise était intempestive sur les listes, boutiques, forums et vidéos). Une page est un article si
elle se déclare telle (`og:type` = article, JSON-LD `Article`/`NewsArticle`/`BlogPosting`) et que son contenu a ≥ 1 500 caractères de
paragraphes, ou si elle a un `<article>` d'au moins 3 000 caractères de paragraphes. La page d'accueil d'un site n'en est jamais une.
Les **vidéos ne sont plus suivies** : plus d'offre « Reprendre la vidéo ».

- L'offre est une pastille en bas de la page (12 s), jamais un saut automatique. Seulement à une **visite neuve** (lien ou adresse
  saisie), pas au retour arrière, au rechargement ni au réveil d'un onglet : WebKit y restaure déjà la position.
- Une fine ligne d'accent au bas de la page montre l'avancée de la lecture d'un article long.
- Clé de page : adresse sans fragment, sans paramètres de suivi (`utm_*`, `fbclid`, …) ni de temps (`t`, `start`), sans « www. » ;
  l'identifiant d'une vidéo (`?v=…`) est gardé. Les « séries et cours » fonctionnent donc page par page : chaque épisode a sa
  position.
- **Vie privée** : positions stockées sur ce Mac (table `resumePoints`), 90 jours et 500 entrées au plus, **jamais en
  navigation privée**, effacées avec les données de navigation.

## Comment ça marche

Un script de page (monde isolé `oree-resume`, frame principale) mesure et signale ; la décision est dans `ResumePolicy` (testée).
Chaque rapport porte l'adresse de la page qui l'envoie : un rapport tardif (fin de page, minuteries ralenties) ne peut pas être
attribué à la page suivante. La vidéo signale sa position au plus toutes les 5 s, et à la pause, à la fin et au départ de la page.

## Limites

- **Vidéos dans une iframe** (lecteurs intégrés) : non suivies, seule la frame principale l'est.
- **Fermer Orée** sans quitter la page ne déclenche pas le rapport final : la dernière position est celle de ≤ 5 s avant.
- Défilement dans un conteneur interne (certaines applications web) : non suivi.
- Pas encore de liste « à reprendre » sur la page d'accueil (le stockage la permet : `ResumeRepository.recent`).
- Fenêtre masquée : WebKit retient les événements de lecture, la position est alors enregistrée à la pause ou au départ de la page.

## Tester

```
./build_app.sh --debug
python3 scripts/bench/resume_check.py     # 11 vérifications, instance séparée ; oublie ses propres entrées
scripts/test.sh --fast                    # ResumePolicyTests, ResumeRepositoryTests
```
