# Sessions Stats

Application macOS de barre de menus qui surveille en temps réel un calendrier et
inscrit, dans la description de chaque nouvelle session, le nombre d'occurrences
passées du même intitulé et leur durée cumulée.

Pas de scrutation périodique : l'application reste éveillée et s'abonne à la
notification système `EKEventStoreChanged`, émise à chaque modification de la
base Calendrier ou Rappels — y compris quand un événement créé sur iPhone
achève de se synchroniser sur le Mac.

## Installation

```
./build.sh
```

Puis déplacez `SessionsStats.app` dans `/Applications` et **lancez-la depuis le
Finder** (double-clic). Une fois cette première installation faite, `build.sh`
reporte automatiquement les versions suivantes dans `/Applications`. Ce point n'est pas cosmétique : lancée par un autre
programme, l'application hérite des autorisations de celui-ci au lieu de
demander les siennes, et macOS refuse l'accès au Calendrier sans afficher de
dialogue.

Deux demandes d'autorisation apparaissent au premier lancement (Calendrier,
puis Rappels). Acceptez-les.

Aucune icône dans le Dock : l'application vit dans la barre de menus.

## Réglages

Menu de la barre de menus → **Réglages…**

**Général**
- Surveillance active / lancement à l'ouverture de session
- Calendrier surveillé (liste déroulante des calendriers réels)
- Liste de rappels servant de filtre, et possibilité de désactiver ce filtre
- Fenêtre de détection (±N jours) et profondeur d'historique (N années)
- État des autorisations, nombre d'événements suivis, dernière activité
- **Analyser maintenant**, **Oublier l'état**, **Retraiter tout l'historique**

**Format**
- Sections à inclure : informations de la tâche, notes personnelles protégées
- Choix ligne par ligne du contenu des statistiques, avec aperçu en direct
- Lignes de séparation personnalisables
- Conservation ou remplacement des notes existantes

**Journal** — les 200 dernières lignes, et accès au fichier complet.

## Fonctionnement

1. À chaque notification (regroupée sur 2 s pour absorber les rafales iCloud),
   les événements du calendrier sur la fenêtre de détection sont listés.
2. Ils sont comparés à `~/Library/Application Support/SessionsStats/state.json`,
   qui retient les identifiants déjà traités. La détection ne repose donc pas
   sur la date de création : un événement est « nouveau » au moment où il
   apparaît sur le Mac, quel qu'ait été le délai de synchronisation.
3. Pour chaque nouvel événement de titre X, si le filtre Rappels est actif, un
   rappel de titre X doit exister dans la liste choisie (terminé ou non) ; sinon
   l'événement est ignoré.
4. Les événements de même titre qui se terminent avant le début de la session
   courante sont comptés, leurs durées sommées, et le bloc est écrit.

Le rapprochement des titres est insensible à la casse, aux accents et aux
espaces superflus.

## Glisser-déposer depuis Rappels

Déposer un rappel sur le calendrier crée un événement dont le titre reprend
celui de la tâche **suivi du contenu de sa note**. L'application gère ce cas :

- la correspondance se fait par préfixe, donc l'événement est bien rattaché à sa
  tâche malgré le suffixe (« Tolérer un suffixe après le titre de la tâche ») ;
- le regroupement se fait sur le titre de la **tâche**, sans quoi une même
  activité serait comptée séparément selon que le suffixe est présent ou non ;
- le titre de l'événement est ramené à celui de la tâche (« Nettoyer le titre de
  l'événement ») ;
- le contenu de la note n'est pas récupéré depuis le titre : il est reconstitué
  proprement depuis les propriétés du rappel, dans la section « Informations de
  la tâche » décrite ci-dessous.

**Premier lancement** : les événements déjà présents sont enregistrés comme vus
sans être modifiés — l'historique n'est pas réécrit rétroactivement. Le bouton
« Retraiter tout l'historique » permet de forcer l'inverse.

## Description de l'événement

Elle est composée de trois sections balisées :

```
── Informations de la tâche ──
Liste : Doctorat - Tâches
Échéance : 14 septembre 2026
Priorité : haute
Commentaires : voir le compte rendu du 3 juillet

── Notes personnelles ──
Relu les entretiens 4 à 7, plan de la section 2 arrêté.

── Statistiques ──
Session n°8 — « Rédaction chapitre 2 »
Cette session : 2 h 30
Sessions antérieures : 7 — 14 h 15
Dernière séance : 22 juillet 2026
Cumul : 16 h 45
```

**Informations de la tâche** — relevées sur le rappel lui-même : liste,
échéance, date de début, priorité, lieu, lien, récurrence, alertes, date
d'achèvement, commentaires. Seules les propriétés renseignées apparaissent.
Régénérée à chaque passage.

**Notes personnelles** — section protégée. Son contenu est repris mot pour mot,
y compris lors d'un retraitement complet : c'est là qu'écrire ce que vous avez
accompli. Le texte libre trouvé dans une description antérieure à toute section
y est versé au premier passage, plutôt que d'être écrasé.

**Statistiques** — régénérée à chaque passage.

Chaque section est délimitée par sa ligne de séparation, personnalisable dans
l'onglet Format. Les modifier après coup empêche de retrouver les sections déjà
écrites dans les événements existants.

## Signature et autorisations

`build.sh` signe l'application en ad-hoc, ce qui suffit à TCC et à l'ouverture
au démarrage. Chaque recompilation change l'empreinte du binaire : macOS peut
alors redemander les autorisations.

**Point critique** : la signature active le *hardened runtime*, et dans ce mode
macOS exige des droits explicites pour accéder au Calendrier et aux Rappels.
Ils sont déclarés dans `SessionsStats.entitlements` :

- `com.apple.security.personal-information.calendars`
- `com.apple.security.personal-information.reminders`

Sans eux, l'accès est refusé **immédiatement et silencieusement** : aucun
dialogue d'autorisation ne s'affiche, l'application n'apparaît nulle part dans
Réglages Système → Confidentialité, et rien dans son propre journal n'en donne
la raison. Le diagnostic se lit uniquement dans les traces de `tccd` :

```
/usr/bin/log stream --predicate 'process == "tccd"' --info --debug
```

Ne retirez pas l'option `--entitlements` de `build.sh`.

## Licence

MIT — voir [LICENSE](LICENSE).
