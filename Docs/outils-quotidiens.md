# Outils du quotidien (16 octobre 2026)

Ce qui a été ajouté pour la parité avec les autres navigateurs. Chaque point a des tests dans `Tests/` et, pour l'interface, un banc dans `scripts/bench/`.

| Fonction | Où | Test |
|---|---|---|
| Codes 2FA (TOTP), remplissage auto | `BrowserCore/TOTP.swift`, `CredentialScript.swift` | `PasswordToolsTests`, `security_check.py` |
| Export CSV et audit des mots de passe | `BrowserCore/PasswordAudit.swift` | `PasswordToolsTests`, `PasswordExportRoundTripTests` |
| Adresses et cartes (jamais le CVC) | `AutofillData/Script/Store` | `AutofillStoreTests`, `security_check.py` |
| Menu du Dock, Services, Spotlight | `BrowserUI/+System.swift`, `SpotlightIndexer.swift` | `system_check.py` |
| Mode responsive | `ResponsiveDevice.swift`, `+Responsive.swift` | `system_check.py` |
| Refus des bannières de cookies | `CookieBannerScript.swift` | `CookieBannerScriptTests` |
| Gestes de souris (clic droit + glisser) | `MouseGesture.swift`, `OreeWebView.swift` | `system_check.py` |
| Profils (un processus par profil) | `ProfileContext.swift`, `+Profiles.swift` | `ProfileTests`, `profile_check.py` |
| AirPlay | `+Tabs.swift` (`allowsAirPlayForMediaPlayback`) | non testé (pas d'appareil) |

Les essais de développement utilisent `HB_TEST_KEYS_DIR` (build debug seulement) pour ne jamais toucher au Trousseau.

## Hors de portée sans compte Apple ou serveur
DNS sécurisé (entitlement NetworkExtension), notarisation, passkeys, notifications push, Apple Pay, Handoff, synchronisation iCloud, VPN, Tor, compte et synchronisation, apps iPhone/Windows, « Ajouter au Dock » (signature), navigation au curseur (API privée), ouverture automatique des fichiers sûrs (choix de sécurité).
