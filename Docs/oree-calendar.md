# Ajouter au Calendrier

Bouton « calendrier + » dans la barre d'outils quand la page annonce un événement, ou ⌘K › « Ajouter au Calendrier » sur n'importe quelle
page. Orée affiche ce qui sera ajouté (titre, date et heure, lieu), puis ouvre **Calendrier** avec l'événement prérempli : vous choisissez
le calendrier et confirmez.

## Deux étages

1. **Données de la page (instantané, exact).** JSON-LD schema.org : `Event` (concert, festival, webinaire…), réservations de restaurant,
   d'événement ou de train. Une pastille « Événement détecté » apparaît.
2. **Modèle local.** Sinon le modèle d'Apple Intelligence lit le texte de la page (« rendez-vous confirmé le mardi 14 octobre à 9h15 ») et
   répond en JSON. La date n'est gardée que si elle est plausible (de hier à 3 ans) **et que la page cite bien ce jour et ce mois**
   (« 14 octobre » ou « 14/10 ») : un jour seul, ou une date inventée, est refusé.

## Pourquoi un fichier .ics et pas EventKit

Le fichier d'événement ouvert avec Calendrier ne demande **aucune autorisation** et l'app n'accède jamais aux calendriers (ni lecture, ni
écriture) : Calendrier montre sa propre fenêtre d'ajout. Contrepartie : un clic de confirmation dans Calendrier (arguably une protection),
et **pas d'ajout silencieux**. Les **Rappels** (tâches « à rendre avant vendredi ») ne sont pas faits : Rappels n'importe pas les tâches
d'un fichier de la même façon.

Détails : heures sans fuseau lues en heure locale, converties en UTC ; jour seul = événement sur la journée ; sans heure de fin, une
heure ; texte échappé et lignes pliées à 75 octets (RFC 5545), testés.

## Limites

- Un seul événement par page (le principal) ; pas de choix parmi plusieurs dates.
- Le modèle peut se tromper d'heure ou de lieu : d'où l'écran de confirmation avant tout.
- Dates relatives (« demain », « vendredi ») : le modèle reçoit la date du jour, non vérifié sur beaucoup de cas.
- Calendrier doit être l'application Calendrier d'Apple (`/System/Applications/Calendar.app`).

## Tester

```
./build_app.sh --debug
python3 scripts/bench/calendar_check.py   # 8 vérifications ; n'ouvre jamais Calendrier ; la 2e partie utilise le modèle
scripts/test.sh --fast                    # CalendarEventTests
```
