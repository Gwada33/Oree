# Sécurité et licences : état au 22 octobre 2026

Relecture du code contre l'audit du 10 octobre, plus les licences de tout ce qui est embarqué ou téléchargé.

## Sécurité

| Point (audit du 10/10) | État |
|---|---|
| Canal `--automation` (exécute du JS, saute Touch ID) compilé dans la version finale | **Corrigé** : `#if DEBUG` dans `main.swift` ; la version distribuée ne le contient pas |
| XPC du téléchargeur accepte tout processus | **Corrigé** : `setConnectionCodeSigningRequirement("identifier \"com.nolhan.hyperbrowser\"")`. Limite : avec une signature ad hoc, seul l'identifiant est vérifié ; une signature Developer ID permettrait d'exiger l'équipe |
| `oree://home/photo` lisible par n'importe quel site | **Corrigé le 22/10** : refusé si le document principal n'est pas `oree://` (banc `scripts/bench/home_security_check.py`, 2/2) |
| Favoris importés en `javascript:` devenant des liens de l'accueil | **Corrigé le 22/10** : seules les adresses http(s) deviennent des liens |
| Mise à jour : somme SHA-256 publiée dans la même release que le zip, pas de signature | **Ouvert** : il faut une clé de signature (Ed25519) dont la partie publique est dans l'app et la privée chez le propriétaire, ou une signature Developer ID |
| Signature ad hoc, pas de runtime durci, pas de notarisation | **Ouvert, demande un compte Apple Developer** ; sans cela macOS affiche l'avertissement de Gatekeeper au premier lancement |
| Le gestionnaire d'identifiants vit dans le monde JavaScript de la page (un site peut lui envoyer des messages `focus` / `submit` sans geste de l'utilisateur) | **Ouvert** : à déplacer dans un monde isolé avec le script d'autofill et celui des bannières de cookies (même gestionnaire), puis re-tester l'autofill |

Solide (vérifié dans le code) : origine des identifiants fournie par WebKit, coffre ChaChaPoly + Trousseau + Touch ID, HTTPS d'abord sans contournement de certificat, téléchargements en quarantaine, onglets privés non persistants, sorties de l'IA validées (CSS en liste blanche, widgets en lecture seule, textes masqués envoyés au modèle local), messages des scripts d'Orée (agrandissement vidéo, widgets, Luciole, mémoire) reçus dans des mondes isolés que la page ne voit pas. Info.plist : descriptions d'usage pour caméra, micro, position, réseau local, Bluetooth ; ATS ouvert seulement pour le contenu web (un navigateur doit pouvoir ouvrir du http, avec l'avertissement d'Orée).

## Licences (`Resources/THIRD_PARTY_NOTICES.md`, copié dans l'app, bouton « Licences et mentions » de À propos)

- **Swift** : GRDB.swift (MIT). **Polices** : Instrument Sans et Serif (SIL OFL 1.1, textes inclus).
- **Rust** : 133 crates, toutes permissives (MIT, Apache-2.0, BSD-3, Unicode-3.0) sauf 9 en **MPL-2.0** (adblock-rust de Brave, uniffi) : utilisées **sans modification**, l'adresse du code source est donnée. `r-efi` est proposée en MIT ou Apache ou LGPL : MIT retenue (non utilisée sur macOS). La bibliothèque C zstd est utilisée sous BSD-3.
- **Données** : règles ClearURLs (LGPL-3.0) embarquées sans modification et remplaçables par une copie téléchargée ; EasyList / EasyPrivacy (GPLv3 / CC BY-SA) seulement téléchargées, jamais redistribuées.
- **Google Safe Browsing** : l'API v4 est réservée à un usage **non commercial** par les conditions de Google. Orée n'embarque aucune clé : l'utilisateur met la sienne, donc c'est lui qui accepte ces conditions. Pour une distribution commerciale avec protection intégrée, il faudrait l'API Web Risk (payante).
- **Fournisseur « Claude Code »** : usage personnel seulement (il lance la commande `claude` de l'utilisateur) ; à ne pas activer dans une version distribuée.
- **Orée lui-même** : aucun fichier LICENSE dans le dépôt. À décider par le propriétaire (propriétaire, ou une licence ouverte).
- **Non vérifié** : la licence de l'icône et du logo d'Orée (créés dans ce projet, `Branding/`), les mentions de marque des sites d'aide, et la licence des symboles SF (permise dans l'interface d'une app macOS, interdite comme logo).
