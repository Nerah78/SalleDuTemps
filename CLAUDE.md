# La Salle du Temps — Addon de rotation DPS pour WoW Forever

## Contexte
- Jeu : **WoW Forever** (Blizzard, base de type WoW Classic). Développement sur la bêta, version 1.60.1.70009.
- Auteur : Sébastien (compte GitHub Nerah78), UX/UI et Product Designer.
- Objectif : aider le joueur à trouver la meilleure rotation de sorts sur mannequin, puis à la jouer en rythme grâce à une timeline façon Guitar Hero.
- Spécification complète : `docs/specification.md`. La lire avant toute nouvelle fonctionnalité.

## Règles impératives
- Un addon **ne lance jamais de sort** à la place du joueur (fonctions protégées par Blizzard). Il observe et suggère uniquement.
- Ne pas supposer que l'API est identique à WoW Classic ou au WoW moderne : en cas de doute, prévoir une vérification en jeu et le signaler.
- Le dossier de l'addon et le fichier `.toc` s'appellent tous deux `SalleDuTemps`.
- Licence GPL v3. En-tête de licence dans chaque fichier Lua.

## Informations techniques
- Numéro d'interface pour le `.toc` : **16001** (confirmé en jeu).
- Commande en jeu : `/sdt` (alias `/salle` envisagé). `/sdt` seul ouvre le journal des cycles, `/sdt session` le panneau de nouvelle session, `/sdt aide` liste les commandes. Icône de minimap : clic = journal, clic droit = affichage des sorts dans le chat.
- Sauvegarde lisible hors jeu : `WTF/Account/<compte>/SavedVariables/SalleDuTemps.lua` (numéro de compte gardé hors du dépôt, dans la mémoire locale de Claude) (écrite au `/reload` ou à la déconnexion). Utile pour les traces de sessions et les diagnostics.
- Données sauvegardées : `SavedVariables` par compte (`SalleDuTempsDB`) pour les cycles et sessions. Chaque session retient son personnage (`s.personnage`, « Nom-Royaume ») ; afficher par défaut les données du personnage connecté (`Data.EstAMoi`). Sébastien joue au moins un prêtre et un voleur (créé le 2026-10-17).
- Mannequins d'entraînement : existent dans la bêta mais **ne sont pas accessibles** (l'accès au niveau 25 était faux, 2026-10-17) : les sessions se font sur des monstres. Nom : « Mannequin d'entraînement », **PNJ n° 5652** (champ 6 du GUID), niveau 25. Reconnaître par l'identifiant d'abord.
- Le client renvoie des **valeurs secrètes** (`<secret>`, ex. `UnitHealthMax` de la cible) comme le WoW moderne : un addon ne peut ni les comparer ni calculer avec (erreur « attempt to compare … secret »). Constaté secret : nom de la cible de `UNIT_SPELLCAST_SENT` (en combat), `UnitPower("player")` (mana du joueur), `UnitHealthMax("target")`. `CombatLogGetCurrentEventInfo` **n'existe pas**. **Nom et GUID des monstres ciblés sont secrets même hors combat** (constaté 2026-10-14) : la cible d'une session est identifiée après coup par le nom d'ennemi que donne `GetAvailableCombatSessions()`. La mana du joueur reste secrète hors combat.
- **Afficher une valeur secrète marche** : `FontString:SetFormattedText("%d", valeurSecrete)` est accepté (dégâts en direct dans la barre de session), ainsi que `StatusBar:SetMinMaxValues` / `SetValue` (jauge de mana, sonde du 2026-10-17).
- **Déplacements** (sonde `/sdt sonde`, 2026-10-17) : `GetUnitSpeed` lisible hors combat mais **secret en combat** ; `PLAYER_STARTED_MOVING` / `PLAYER_STOPPED_MOVING` reçus. Le verdict « Interrompu » s'appuie sur `UNIT_SPELLCAST_INTERRUPTED` (bouger annule l'incantation) et sur `PLAYER_STARTED_MOVING` pendant une incantation ou canalisation. Toujours tester avec `issecretvalue` (helpers `EstSecret` / `Lisible` dans `Capture.lua`). 
- **Journal de combat interdit** : s'inscrire à `COMBAT_LOG_EVENT_UNFILTERED` déclenche « addon bloqué » (action réservée à l'interface Blizzard, non interceptable par `pcall`). Ne jamais s'y inscrire. Mesure des dégâts : `C_DamageMeter` **existe** (types `DamageDone`, `Dps`…, fonctions : `GetAvailableCombatSessions`, `GetCombatSessionFromID`, `GetCombatSessionFromType`, `GetCombatSessionSourceFromID`, `GetCombatSessionSourceFromType`, `GetSessionDurationSeconds`, `IsDamageMeterAvailable`, `ResetAllCombatSessions`). Relevé hors combat (2026-10-14), **tout est lisible** :
  - `GetAvailableCombatSessions()` → liste `{ sessionID, name (ennemi), durationSeconds (entier) }`, une session par combat.
  - `GetCombatSessionFromType(Enum.DamageMeterSessionType.Current|Overall|Expired, Enum.DamageMeterType.DamageDone)` → `{ durationSeconds, totalAmount, maxAmount, combatSources = { { name, sourceGUID, isLocalPlayer, classFilename, totalAmount, amountPerSecond, … } } }`.
  - `GetCombatSessionSourceFromType(typeSession, DamageDone, UnitGUID("player"))` → `{ totalAmount, maxAmount, combatSpells = { { spellID, totalAmount, amountPerSecond, overkillAmount, … } } }`. **Pas de critiques ni de nombre de coups.**
  - Préférer les `sessionID` à `ResetAllCombatSessions` (qui viderait aussi le compteur Blizzard du joueur).
  - Relevé **en combat** (2026-10-14) : **tous les montants, DPS, durées, noms, GUID et spellID sont secrets**. Restent lisibles : `GetAvailableCombatSessions()` (sessions passées) et `GetSessionDurationSeconds(Current)`. → Lire les résultats **après la sortie de combat** (`PLAYER_REGEN_ENABLED`).
  Sonde : `/sdt compteur`, résultat lisible dans `WTF/Account/<compte>/SavedVariables/SalleDuTemps.lua` (`SalleDuTempsDB.sonde`). `C_AssistedCombat` (assistant de rotation Blizzard) existe aussi. Les événements `UNIT_SPELLCAST_*` du joueur restent utilisables.

## Architecture (un module = un fichier, dans `modules/`)
- `Core.lua` : chargement, commande `/sdt`, icône minimap.
- `Capture.lua` : écoute des sorts lancés (`UNIT_SPELLCAST_*`, le journal de combat étant interdit), des dégâts (source à définir) et des déplacements du joueur.
- `Session.lua` : chrono, départ au premier sort lancé sur la cible, fin, garde-fous.
- `Cycle.lua` : détection du cycle de rotation à partir de la séquence de sorts. Logique en **Lua pur, sans API WoW**, pour être testable hors du jeu.
- `Partition.lua` : partition de la session d'amélioration et jugement du rythme. **Lua pur**, testé par `tests/test_partition.lua`.
- `Guide.lua` : Guide en combat normal (cycle « Actif », partition vivante, bilan des combats pour le Coach).
- `Coach.lua` : progression d'un cycle et erreurs fréquentes. **Lua pur**, testé par `tests/test_coach.lua`.
- `Data.lua` : lecture et écriture de `SalleDuTempsDB`.
- `Classes.lua` : détection de la classe et profils de ressource (mana, énergie, rage).
- `ui/` : HUD et timeline, page Cycle, éditeur, journal des cycles. `ui/Session.lua` : panneau « Nouvelle session » et barre compacte. `ui/Cycle.lua` : page Cycle. `ui/Journal.lua` : journal des cycles et comparaison. `ui/Editeur.lua` : éditeur du cycle (version éditée à côté du cycle détecté). `ui/HUD.lua` : HUD et timeline (amélioration et Guide). `ui/Progression.lua` : page Progression (Coach).

## Pièges de l'API rencontrés
- La croix des modèles de fenêtre du jeu (`BasicFrameTemplateWithInset`, `UIPanelCloseButton`) passe par `HideUIPanel`, bloquée en combat : appeler `ns.FermetureDirecte(f)` après la création de chaque fenêtre.
- Le combat peut commencer avant le premier sort (attaque automatique) : la session de compteur de dégâts du combat existe déjà au départ.

## Pièges Lua rencontrés
- Ne jamais utiliser `#` sur une liste qui peut contenir des `nil` (trous) : le résultat n'est pas fiable. Passer le nombre d'éléments explicitement (bug de la courbe de progression, 2026-10-17).
- Ne pas réutiliser comme variable de boucle un nom déjà pris par une variable locale proche (bug de la page Cycle, cadre `c` masqué par `for _, c in ...`).

## Tests hors jeu
- Les séquences réelles enregistrées en session sont exportées dans `tests/traces/`.
- `tests/` contient des tests Lua (exécutables avec `lua` en ligne de commande) qui rejouent ces traces dans `Cycle.lua`.

## Jalons
1. Squelette : `.toc`, icône minimap, `/sdt`, affichage brut des sorts lancés dans le chat.
2. Session Training complète (réglages, départ au premier sort, fin, garde-fous) et sauvegarde des séquences.
3. Détection du cycle et page Cycle simple.
4. Journal des cycles.
5. Éditeur V1 du cycle.
6. Timeline rythmique (classes à mana) et session d'amélioration (partition fixe).
7. Variantes énergie (voleur) et rage (guerrier).
8. Coach, progression, partition vivante en combat normal.

Jalon en cours : **6**, découpé en **6a** (HUD, timeline, jugement du rythme : validé en jeu le 2026-10-17, précision 92,5 % sur un essai de 15 s ; fenêtre « session écourtée » validée) et **6b** (mode comparaison, zones d'immobilité, « Interrompu », jauge de mana : validés en jeu le 2026-10-17). **Jalon 6 terminé.** Jalon 7 (énergie, rage) **reporté** : pas de voleur ni de guerrier pour tester. **Jalon 8 terminé** le 2026-10-17 : **8a** (Guide en combat normal, partition vivante) et **8b** (Coach, page Progression) validés en jeu. **Jalon 7 commencé le 2026-10-17 par l'énergie (voleur)**. Sonde `/sdt sonde energie` passée (voleur niveau 5) : énergie **secrète même hors combat**, énergie max lisible (100), jauge à valeur secrète acceptée ; coûts des sorts **lisibles** via `C_Spell.GetSpellPowerCost` (Attaque pernicieuse 45, Attaque sournoise 60, Suriner 45, Éviscération 35 + combo, Débiter 25 + combo) ; points de combo lisibles hors combat (en combat : à vérifier) ; `UNIT_POWER_FREQUENT` (ENERGY) toutes les **0,1 s** : la régénération est **continue** sur ce client (pas de paliers de 2 s) ; les événements s'arrêtent quand l'énergie est pleine (point d'appui pour recaler une énergie calculée). Partition à énergie écrite (version 0.12.0) : énergie calculée, zones « sablier ». Premier essai : notes un peu trop tôt (35 combats guidés, surtout des « pas jouées ») → régénération désormais **mesurée** en jeu (`Capture.RegenEnergie`). Première mesure 12,7/s, surestimée par les attaques ratées (qui rendent l'essentiel de leur coût, invisible pour l'addon) → mesure limitée aux segments à un seul sort, médiane, 10/s par défaut (règle de Classic). Faux « énergie pleine » corrigé (délai 1 s) : écart calcul / réel tombé à ~4 points (2026-10-17). La largeur remplie d'une barre à valeur secrète est **secrète aussi** (pas de lecture possible de l'énergie réelle). Version 0.13.0 (2026-10-17, à tester en jeu) : marge de réaction de 0,2 s sur les notes qui attendent l'énergie, temps à énergie pleine (résumé, Progression, alerte « PLEINE » du HUD), coup de grâce jugé sur ses points de combo (lus, ou estimés d'après le signal `COMBO_POINTS` s'ils sont secrets en combat ; relevés à `UNIT_SPELLCAST_SENT`). Sonde passée : points de combo **lisibles en combat**, signal reçu, rôles bien lus ; « trop peu de points » vu en jeu. Version 0.14.0 (à tester) : coup esquivé repéré par les points de combo (note à rejouer, sans faute, 80 % de l'énergie rendue), partition en pause pendant une perte de contrôle : **validée en jeu**. Sonde `/sdt sonde controle` (2026-10-17) : `C_LossOfControl.GetActiveLossOfControlDataCount()` **lisible en combat** (1 pendant un étourdissement), données de la perte lisibles aussi (type, durée, sort) ; `HasFullControl()` reste vrai quand on est étourdi (inutile) ; événements `LOSS_OF_CONTROL_ADDED` / `UPDATE` reçus (`COMMIT` n'existe pas) ; `UI_ERROR_MESSAGE` lisible (« Impossible lorsque vous êtes étourdi(e). »). Esquive repérée et rejouée en jeu (1 sur les combats de 0.14.0, plus de « trop peu de points »). Première mesure de régénération : 8,5/s (il en faut 3). La rage (guerrier) viendra ensuite.
- **DoT** (2026-10-17, version 0.10.0) : rejoués à leur expiration par un moteur de priorités dans `Partition.lua` (voir spec, section 4 bis). Lecture des durées validée en jeu (éditeur : Flammes sacrées 10 s, Peste 24 s, Douleur 24 s avec talent) ; HUD du Guide avec mention « DoT » vu en jeu. Reste à vérifier dans les données : relance à l'expiration, « DoT écrasé », DPS des combats guidés.

## À reprendre plus tard (demandé par Sébastien)
- Retouches d'interface, à voir dans un second temps : par exemple remplacer la mention « DoT » des notes du HUD par une bordure violette (la mention et la touche se partagent l'icône) ; rendre plus visibles les séparations entre les cases de points de combo (peu visibles sur fond sombre ; à 0 point, la barre se confond avec le fond) ; retirer à terme le diagnostic « calcul N » de la barre d'énergie, ou le garder en option.
- HUD du voleur validé en jeu le 2026-10-17 (barre d'énergie, cases de combo, Guide sur le cycle « new 02 »). (zones d'immobilité, verdict Interrompu, jauge de mana, page Cycle en mode comparaison). Jalon 5 validé en jeu le 2026-10-17 (une seule page à deux modes, sans onglets). Jalon 4 validé en jeu le 2026-10-17 (navigation, menu, comparaison ; superposition des fenêtres corrigée). Jalon 3 validé en jeu le 2026-10-17 (session n° 6 : cycle de 4 étapes conforme à la prévision). Jalon 2 validé en jeu sur monstres le 2026-10-14 (`/sdt test N`) ; pas de validation sur mannequin possible (inaccessibles). Jalon 1 validé le 2026-10-14.
- **Lua 5.4.6 installé** (winget `DEVCOM.Lua`, 2026-10-17). Dans un terminal ouvert avant l'installation, recharger le PATH : `$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")`.
- Après chaque modification : `lua SalleDuTemps/tests/test_cycle.lua` et `lua SalleDuTemps/tests/test_partition.lua`, `lua SalleDuTemps/tests/test_coach.lua` (tests), `luac -p` sur chaque fichier `.lua` (syntaxe), et `lua SalleDuTemps/tests/analyser_sauvegarde.lua "<chemin de SalleDuTemps.lua>"` pour rejouer les sessions réelles.
- **Toute modification de l'interface** : `lua SalleDuTemps/tests/simulation_ui.lua "<copie de SalleDuTemps.lua>"` (API WoW imitée, ouvre journal, page Cycle, éditeur, panneau avec les vraies sessions ; attrape les erreurs d'exécution que `luac` ne voit pas). Travailler sur une **copie** de la sauvegarde. Ajouter un scénario pour chaque nouvelle fenêtre.

## Façon de travailler
- Un jalon à la fois, chacun testable en jeu avec `/reload`. Commencer simple, puis itérer.
- Sébastien teste en jeu et revient avec ses retours et les erreurs (capturées avec BugSack).
- Mettre à jour `CHANGELOG.md` à chaque jalon. Publication avec GitHub Desktop.
- Toute décision de conception prise en cours de route est reportée dans `docs/specification.md`.
- Répondre en **français**, de façon concise. Signaler franchement un problème technique ou de règles Blizzard.
