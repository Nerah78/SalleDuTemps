# Journal des modifications

## 0.14.0 — Coups esquivés et pertes de contrôle (2026-10-17, validé en jeu)
- Retour en jeu (0.13.0) : points de combo **lisibles en combat**, rôles des sorts bien lus en français, « trop peu de points » signalé deux fois ; Sébastien : les ratés et esquives cassent les cycles, et les étourdissements du monstre font passer des notes.
- Coup esquivé, paré ou raté repéré par les points de combo (générateur sans point gagné, coup de grâce sans points dépensés, 0,5 s après le lancer) : étape « Esquivé ». La note n'est pas une faute (« ESQUIVÉ · à rejouer », série de notes réussies rétablie), elle **doit être rejouée avant de passer à la suivante**, et 80 % de son coût en énergie est rendu au calcul. Le segment de mesure de régénération en cours est abandonné. Résumé : « N esquivés (rejoués) ».
- Perte de contrôle (étourdi, apeuré… : `HasFullControl`, `C_LossOfControl`) : la partition se met en pause, rien n'est déclaré passé, la note attendue reste due et la première note jouée ensuite a la marge de réaction. HUD : « Perte de contrôle : partition en pause ».
- `/sdt sonde controle` : ce que le jeu laisse voir d'une perte de contrôle. Résultat : le nombre de pertes de contrôle actives (`C_LossOfControl`) est lisible en combat, `HasFullControl` ne change pas quand on est étourdi. Pause validée en jeu, esquive repérée et rejouée en jeu.
- `Partition.Esquiver`, `Partition.Pause` ; `Partition.Interrompre` partage désormais l'annulation du verdict. 112 tests (+10) ; simulation : scénario « esquive et étourdissement ».

## 0.13.0 — Énergie du voleur : réaction, énergie pleine, points de combo (2026-10-17, à tester en jeu)
- Marge de réaction : une note qui attend l'énergie est jugée avec 0,2 s de retard pardonné (le joueur réagit à la barre, sans file d'attente possible ; `Partition.MARGE_REACTION`).
- Énergie pleine : temps passé à 100 relevé par session et par combat guidé (`energiePleine`), affiché dans le résumé du chat (« Énergie pleine pendant N s, environ X d'énergie perdue ») et en tendance sur la page Progression ; alerte « PLEINE » dans la barre d'énergie du HUD.
- Points de combo dans le jugement : un coup de grâce lancé avec moins de points que les générateurs joués depuis le précédent est « RATÉ · trop peu de points (1 sur 2) », avec conseil du Coach. Rôles lus dans la description des sorts (`Cycle.TypeCombo`) ; points lus, ou **estimés** d'après le signal de changement s'ils sont secrets en combat, relevés à l'envoi du coup de grâce. HUD : « combo estimé N » quand l'estimation est utilisée (diagnostic).
- `/sdt sonde energie` : rôles des sorts et signaux de points de combo (hors combat, en combat, lisibles).
- Tests : 50 (+5), 102 (+10) ; simulation : scénario voleur refait sur une session fabriquée (il ne testait plus rien avec la sauvegarde réelle), scénario « sessions par personnage » rendu indépendant de la sauvegarde.

## 0.12.0 — Partition à énergie (voleur, jalon 7) (2026-10-17, à tester en jeu)
- `Partition.lua` : énergie calculée (maximum, régénération 10/s, coûts des sorts), notes retardées jusqu'à ce que l'énergie suffise (`note.attente`), recalage sur la dépense réelle et quand l'énergie est pleine (`Partition.EnergiePleine`) ; durée de base des notes séparée de l'attente (correctif de l'heure attendue après replanification). 89 tests (+11).
- `Capture.lua` : coûts en énergie (`GetSpellPowerCost`), énergie pleine déduite de l'arrêt des signaux de gain.
- Session d'amélioration et Guide : partition à énergie pour un voleur, GCD d'une seconde.
- HUD : zones « sablier » jaunes devant les notes qui attendent l'énergie.
- Régénération d'énergie mesurée en jouant (au lieu de 10/s supposés, qui faisaient arriver les notes un peu trop tôt) : total dépensé ÷ temps jusqu'au retour à plein, moyenne glissante par personnage (`SalleDuTempsDB.regenEnergie`), message dans le chat à la première mesure.
- Mesure de la régénération rendue robuste aux attaques ratées (qui rendent l'essentiel de leur coût, invisible pour l'addon) : segments à un seul sort, médiane des 9 dernières mesures, 10/s tant qu'il y a moins de 3 mesures (`SalleDuTempsDB.mesuresRegen`) ; l'ancienne mesure (12,7, surestimée) est abandonnée.
- Retour en jeu : notes encore trop tôt (calcul au-dessus de l'énergie réelle). Délai « énergie pleine » porté de 0,4 à 1 s (un ralentissement en combat remontait le calcul à 100 à tort). Essai : énergie réelle déduite de la largeur remplie de la barre du HUD, si le jeu la laisse lire (« lu N ») ; le calcul s'y recale alors (`Partition.RecalerEnergie`, 92 tests).
- Diagnostic : le HUD affiche l'énergie calculée à côté de la vraie (« Énergie 83 · calcul 7 »), pour comprendre un écart vu en jeu (la timeline faisait attendre avec 83 d'énergie). Première mesure réelle : 12,7 d'énergie par seconde (voleur niveau 5).
- Correctif : la mesure se fermait aussitôt ouverte (avant le premier signal de gain, l'énergie semblait encore pleine) ; une dépense compte désormais comme un signal. Scénario de simulation vérifié dans les deux sens (échoue sans le correctif).

## 0.11.0 — Sessions par personnage, sonde d'énergie (2026-10-17 ; séparation par personnage validée en jeu, sonde à passer)
- Chaque session retient son personnage ; le journal et `/sdt sessions` n'affichent que les sessions du personnage connecté ; case « Tous les personnages » dans le journal. Anciennes sessions rattachées par leur classe.
- `/sdt sonde energie` (jalon 7) : énergie, points de combo, coûts des sorts de voleur, temps de recharge global, rythme des gains d'énergie, jauge d'énergie de test.
- HUD : ligne de ressource selon la classe (mana en bleu, énergie en jaune) et points de combo en cases sous l'énergie (voleur, druide félin).
- Correctif : les fenêtres de l'addon ne se fermaient pas en combat (croix du modèle du jeu bloquée) ; la croix les cache désormais directement (`ns.FermetureDirecte`).
- Correctif : pas de DPS quand le combat commençait avant le premier sort (voleur à l'attaque automatique) ; la session de compteur du combat en cours est maintenant lue.

## 0.10.0 — DoT rejoués à leur expiration (2026-10-17, à tester en jeu)
- `Partition.lua` : moteur de priorités. Les DoT sont replanifiés à leur expiration (calculée depuis le lancer réel) et passent avant le remplissage, qui garde son ordre ; DoT à incantation lancé en avance de son incantation ; série de tirs arrêtée à l'échéance du prochain DoT. Jugement : « trop tôt · DoT écrasé » au-delà d'un GCD d'avance, DoT oublié compté une fois et gardé en tête, DoT interrompu de nouveau dû. Cycles sans DoT inchangés. 78 tests (+18).
- `Cycle.DureeDot` : durée lue dans la description du sort ; `Cycle.Etapes` reconnaît les DoT. 45 tests (+12).
- Éditeur : type « DoT » (durée affichée), clic droit pour modifier la durée ; un type choisi à la main n'est plus changé automatiquement.
- HUD : mention « DoT » sur les notes ; Coach : erreur « écrasé » avec son conseil ; page Cycle : légende « DoT 18 s ».
- Correctif : la page Cycle affiche les DoT de la version éditée comme l'éditeur (reconnaissance automatique appliquée aussi à l'affichage).

## 0.9.0 — Jalon 8b : Coach (2026-10-17, validé en jeu ; jalon 8 terminé)
- `modules/Coach.lua` (Lua pur, 19 tests) : lignée d'un cycle, points de progression, tendance, erreurs les plus fréquentes avec conseil.
- `ui/Progression.lua` : page Progression (courbe DPS et précision, tendance, erreurs fréquentes), ouverte depuis la page Cycle, le menu « … » du journal ou `/sdt progression [n]`.
- Les sessions d'amélioration gardent les erreurs par sort ; le DPS des combats guidés est lu dans le compteur de dégâts à la sortie de combat.
- Correctifs d'après le premier essai : légende sous les dates, points de précision visibles au-dessus du DPS, tendance au singulier, sections ancrées les unes sous les autres, conseil affiché une seule fois par type d'erreur ; fenêtre de recalage du Guide limitée à un cycle moins une note (un sort dans le désordre comptait jusqu'à 7 oublis).
- Correctif de la courbe : une série avec des trous (combats sans DPS) n'affichait qu'un point, au milieu ; lignes d'erreur resserrées (place réservée au conseil seulement s'il est affiché).

## 0.8.0 — Jalon 8a : Guide en combat normal (2026-10-17, validé en jeu)
- `modules/Guide.lua` : en combat normal, hors session, le HUD suit le cycle « Actif » de la classe ; démarrage à l'entrée en combat, arrêt à la sortie ; `/sdt guide` pour l'activer ou le couper ; bouton « Masquer » dans le HUD.
- **Partition vivante** (`Partition.Nouvelle(..., { vivante = true })`) : départ en cours de cycle sans pénalité, recalage sur une note jusqu'à 8 notes plus loin (notes sautées = oubliées). 59 tests.
- Erreurs par sort relevées pendant le jeu (oublié, pas joué, en retard, trop tôt, interrompu) ; bilan de chaque combat guidé gardé pour le Coach (`SalleDuTempsDB.combatsGuides`).
- `Session.ConstruirePartition` et `Session.MemeSort` partagés entre amélioration et Guide.
- Correctif : le sort qui lance le combat était ignoré (le jeu n'entre en combat qu'après lui). Les sorts des 6 dernières secondes sont rattrapés au démarrage du Guide.
- Correctif de jugement (d'après 3 combats guidés) : une série de tirs n'est plus jugée « en retard », seul l'ordre compte (le premier tir automatique suit le rythme du jeu). 60 tests.

## 0.7.0 — Jalon 6b : comparaison, immobilité, jauge de mana (2026-10-17, validé en jeu)
- Page Cycle en **mode comparaison** pour une session d'amélioration : DPS face à la référence, bilan du rythme, choix Nouvelle version / Remplacer la référence / Ignorer (`Data.DecisionComparaison`).
- `/sdt sonde` : sonde des déplacements (vitesse, événements de déplacement, hors combat et en combat) et d'une jauge de mana à valeur secrète ; résultat dans `SalleDuTempsDB.sonde6b`.
- Zones d'immobilité sous les notes à incantation (et celle de l'incantation en cours) ; verdict **Interrompu** (interruption du sort ou déplacement pendant l'incantation) : 0 point, combo à zéro, note à rejouer (`Partition.Interrompre`, 51 tests).
- Jauge de mana dans le HUD (valeur secrète passée telle quelle à la barre).
- `Capture.lua` : suivi de l'incantation en cours, `PLAYER_STARTED_MOVING`, `UNIT_SPELLCAST_STOP` / `CHANNEL_STOP` ; étape « Déplacement ».
- Interruptions comptées dans le résumé du chat et le mode comparaison.

## 0.6.0 — Jalon 6a : timeline rythmique et session d'amélioration (2026-10-17, validé en jeu)
- Combat terminé avant la fin du chrono : fenêtre « Enregistrer / Abandonner » au lieu de l'annulation automatique (Training et amélioration) ; mention « écourtée » et durée réelle dans le résumé, le journal et la page Cycle.
- Correctif d'affichage : plus de « Amélioration · Amélioration · … » en améliorant une amélioration.
- `modules/Partition.lua` (Lua pur, 43 tests) : partition fixe tirée de la version éditée (ou ouverture + cycle détecté), tempo recalé sur chaque sort joué, jugement Parfait / Bien / Juste / Raté selon les seuils de la spec, notes sautées ou non jouées, sorts hors partition (repoussent la note attendue), séries de tirs en temps libre, comparaison par nom de sort (rangs), précision et combo.
- `ui/HUD.lua` : HUD déplaçable sous le personnage (titre, cycle n/N, temps restant, dégâts en direct, verdict, combo, précision) et timeline (cadre « maintenant », notes défilant de droite à gauche avec leur touche, trait au début de chaque répétition).
- Session d'amélioration : « Améliorer » dans le menu du journal et sur la page Cycle, `/sdt ameliorer [n] [secondes]`. La session enregistre la référence et le bilan du rythme ; le résumé du chat l'affiche.
- `tests/simulation_ui.lua` : scénarios d'amélioration (dont une session menée jusqu'au bout) ; imitation de l'API complétée (`date`, `time`, `GetFrameLevel`) ; les erreurs interceptées par l'addon sont comptées.

## 0.5.0 — Jalon 5 : éditeur du cycle V1 (2026-10-17, validé en jeu)
- Correctifs : l'éditeur reste ouvert à l'ouverture du grimoire ; « Modifier le cycle » ferme la page Cycle, qui revient à la fermeture de l'éditeur.
- Page Cycle et éditeur réunis en une seule page à deux modes (même taille 540 × 600 et même position mémorisée) : « Modifier le cycle » passe en Édition, « Annuler » / « Enregistrer » reviennent en Consultation, la croix ferme la page ; le journal reste ouvert à l'ouverture du grimoire. Pas d'onglets (redondants avec ces boutons).
- Correctif : la page Cycle ne s'ouvrait plus (variable du cadre intérieur masquée par une variable de boucle).
- `tests/simulation_ui.lua` : simulation de l'interface hors du jeu (API WoW imitée), lancée sur les vraies sessions.
- `ui/Editeur.lua` : éditeur ouvert par « Modifier le cycle » (page Cycle) ou le menu « … » du journal. Aperçu de la partition en direct (étapes actives, durée estimée), liste réordonnable (flèches et glisser-déposer), touche de barre d'action, type (incantation, instantané, canalisation, série), activer / désactiver, retirer, ajout par glisser-déposer depuis le grimoire, « Version auto », état « Modifié · non enregistré », Annuler / Enregistrer, rappel de validation par une session.
- La version éditée est enregistrée **à côté** du cycle détecté (`cycleEdite`), qui reste intact.
- Page Cycle : bascule Détecté / Édité, bouton « Modifier le cycle ». Journal : badge « Édité », miniature de la version éditée.
- `Cycle.lua` : `Etapes`, `TypeSort`, `Estimer`, `Actives` (Lua pur, testés : 33 tests).

## 0.4.0 — Jalon 4 : journal des cycles (2026-10-17, validé en jeu)
- Correctif : la page Cycle et la comparaison s'affichent au-dessus du journal (journal en strate HIGH).
- `ui/Journal.lua` : journal ouvert par `/sdt` ou un clic sur l'icône de minimap. Cartes (nom, date, type, cible, partition miniature, DPS, étapes, fiabilité), badges « Actif » et « Meilleur DPS » (par classe et type de combat), filtres Tous / Mono / Multi, tri par date, DPS ou fiabilité, bouton « Nouvelle session ».
- Menu « … » : ouvrir, améliorer (grisé, jalon 6), définir comme actif / retirer, dupliquer, renommer, supprimer (avec confirmation).
- Sélection de 2 cycles et fenêtre de comparaison (DPS, étapes, durée, fiabilité, partition, écart de DPS).
- `Data.lua` : identifiant stable par session (migration des anciennes), nom, cycles actifs, meilleur DPS, duplication, suppression ; la limite de 200 sessions ne retire jamais un cycle actif. Cycle détecté mis en cache (`Cycle.VERSION`).
- `/sdt session` ouvre désormais le panneau de nouvelle session ; page Cycle titrée avec le nom de la session.

## 0.3.0 — Jalon 3 : détection du cycle et page Cycle simple (2026-10-16, validé en jeu le 2026-10-17)
- `modules/Cycle.lua` (Lua pur, sans API WoW) : détection de l'ouverture, du cycle (suite, nombre de sorts, durée, répétitions), de la fiabilité et des écarts (sorts en trop, sorts oubliés). Attaques automatiques et sorts interrompus ignorés.
- `ui/Cycle.lua` : page Cycle ouverte en fin de session et par `/sdt cycle [n]` : DPS et écart avec la meilleure session (même classe, même type), cycle et fiabilité, ouverture et cycle en icônes avec info-bulles, écarts, détail par sort (dégâts, part, lancers, DPS par seconde d'incantation), conseil si la fiabilité est faible.
- Règles ajustées après le premier cycle réel (2026-10-17) : tirs de baguette comptés, une série de tirs = une étape « Tir » ; sorts sans dégâts (bouclier, soins, contrôle) écartés d'après le compteur ; pénalité de longueur pour qu'un motif long n'avale pas un proc ; lancers de baguette rattachés à leurs dégâts.
- Tests hors jeu : `tests/test_cycle.lua` (9 scénarios + traces réelles dont `pretre_60s_araignee`), `tests/analyser_sauvegarde.lua` (analyse et export des sessions enregistrées en traces), `tests/traces/`. Logique vérifiée par une traduction PowerShell faute d'interpréteur Lua ; à lancer avec `lua` dès qu'il est installé.

## 0.2.0 — Jalon 2 : session Training (2026-10-14, validé en jeu sur monstres ; reste à valider sur mannequin au niveau 25)
- Panneau « Nouvelle session » (`/sdt` ou clic sur l'icône de minimap) : durée 1, 2 ou 3 min, mono / multi-cibles, étiquette ; préremplis avec la dernière session.
- Barre compacte déplaçable : attente du premier sort, temps restant, dégâts en direct (essai d'affichage d'une valeur secrète), annuler.
- Départ au premier sort lancé sur une cible attaquable ; reconnaissance du mannequin (PNJ n° 5652), avertissement sinon.
- Fin du chrono : signal sonore ; à la sortie de combat, lecture du compteur de dégâts intégré (`C_DamageMeter`) et résumé dans le chat (DPS, séquence, dégâts par sort, mana restante si lisible).
- Annulation automatique si le combat s'arrête avant la fin ; `/sdt annuler`.
- Sauvegarde des sessions (séquence horodatée des sorts, dégâts) dans `SalleDuTempsDB.sessions` ; `/sdt sessions`.
- Un sort lancé sur soi ne déclenche pas le chrono ; cible relevée à sa sélection (nom et GUID secrets en combat).
- Session terminée gardée en cas de `/reload` avant la sortie de combat, puis finalisée au chargement.
- `/sdt test [N]` : session courte pour tester sur un monstre ordinaire.
- Diagnostic : `/sdt diag`, `/sdt compteur`. Clic droit sur l'icône : affichage des sorts dans le chat.
- Nouveaux fichiers : `modules/Data.lua`, `modules/Session.lua`, `ui/Session.lua`.

## 0.1.0 — Jalon 1 : squelette (2026-10-14, validé en jeu)
- `SalleDuTemps.toc` (interface 16001, comme l'addon Parcours sur la même bêta), base sauvegardée `SalleDuTempsDB`.
- `modules/Core.lua` : chargement, commande `/sdt` (aide, `sorts`, `zero`, `icone`, `icone reset`, `version`), icône de minimap déplaçable.
- `modules/Capture.lua` : affichage brut dans le chat des sorts lancés par le joueur (début d'incantation, canalisation, lancé, instantané, interrompu), avec temps relatif, identifiant, durée d'incantation et cible.
- Licence GPL v3 (`LICENSE`).
