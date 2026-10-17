# Mémoire ambiante

Orée garde un extrait des pages que vous lisez, pour que Luciole puisse les retrouver (« l'article d'hier sur la mémoire de WebKit »).
Tout reste sur ce Mac, dans la base d'Orée (table `pageMemory` + index plein texte). Réglages › Mémoire d'Orée : activer, durée de garde (7, 30 ou 90 jours), effacer.

## Ce qui est gardé

- Une page restée ouverte **et visible** 12 secondes après son chargement (`scheduleMemoryCapture`).
- Son titre, son site, un extrait de son texte principal (8 000 caractères au plus) et la date. L'adresse est gardée **sans paramètres ni fragment**.

## Ce qui n'est jamais gardé (`PageMemoryPolicy`, testé)

- Un onglet privé ; une page avec un champ de mot de passe ou de carte (lu par un script en lecture seule, monde isolé `oree-memory`) ;
- les pages de connexion, de paiement, de compte (mots dans l'adresse : login, checkout, paiement, compte, oauth, otp…) ;
- les banques, webmails et sites de paiement connus ; les sites exclus de la protection ; les pages de moins de 400 caractères ; tout ce qui n'est pas http(s).

## Comment Luciole s'en sert

- L'outil `recall` (mots-clés du sujet) renvoie au plus quatre pages lues, les plus récentes d'abord, avec un extrait : des **données** entre balises `<memoire>`, jamais des consignes.
- Il n'est proposé au modèle que si la question le suggère (« j'ai lu », « hier », « retrouve », « souviens »…) : chaque outil coûte des jetons à chaque tour.
- Les adresses retrouvées deviennent des sources connues : les rouvrir ne redemande pas d'accord.
- Jamais appelé depuis un onglet privé.

## Le contexte entre les messages

Avant, une question de plus de cinq mots sans « il » ni « celle-ci » perdait tout le fil de la conversation. Désormais, toute question posée dans une conversation en cours reprend les quatre derniers messages.

## Limites

- Recherche par mots (FTS5), pas par sens : « la mémoire de WebKit » retrouve une page qui contient ces mots, pas une page qui en parle autrement. Des embeddings viendraient ensuite, seulement s'ils battent clairement les mots.
- Le texte n'est pas chiffré dans la base (comme l'historique) ; il est protégé par les droits du dossier de l'utilisateur et le chiffrement du disque.
- Le texte principal est lu par `innerText` : les pages rendues après les 12 secondes ou dans des iframes ne sont pas lues entièrement.

## Tester

```
./scripts/test.sh --all                                   # PageMemoryPolicyTests, PageMemoryRepositoryTests, AgentLocalToolsTests
OREE_TEST_APP=… python3 scripts/bench/memory_check.py     # page lue gardée et retrouvée, page courte écartée
```
