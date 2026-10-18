# La Salle du Temps — Spécification

Addon WoW Forever d'aide à la rotation DPS. Nom en clin d'œil à la salle d'entraînement intensif de Dragon Ball (visuel original à prévoir, par exemple un sablier, sans image ni logo issu de l'œuvre).

Référence étudiée : Hekili (aide à la priorité basée sur des listes de règles et une boucle de simulation).

---

## 1. Principes

- L'addon observe et suggère, il ne lance jamais de sort.
- Il lit les sorts lancés par le joueur (`UNIT_SPELLCAST_*`), ses déplacements et le compteur de dégâts intégré au jeu (`C_DamageMeter`).
- Contraintes du client (bêta 2026-10) : le journal de combat est interdit aux addons ; en combat, la plupart des valeurs sont « secrètes » (ni comparables ni calculables). Les chiffres de dégâts ne sont lisibles qu'**après la sortie de combat**.
- Il détecte automatiquement la classe et le type de ressource du joueur, y compris les changements en combat (formes du druide).

## 2. Phases

1. **Training** : mesurer le DPS sur mannequin et détecter le cycle de rotation.
2. **Formaliser** : transformer le cycle détecté en table de sorts éditable à la main.
3. **Guide** : timeline rythmique en temps réel sous le personnage.
4. **Coach** : comparer ce qui a été joué au cycle de référence, suivre la progression.
5. **Contexte** : adapter la rotation (mono / multi-cibles, durée, niveau, talents, équipement).
6. **Partage** : export et import de cycles entre joueurs (texte à copier-coller).

Enchaînement : Journal → Nouvelle session ou Session d'amélioration → Page Cycle → Vue d'édition → Session d'amélioration…

---

## 3. Mode Training

Sessions de mesure sur mannequin d'entraînement : même cible, même durée, comparaison à armes égales.

- Durée choisie : 1, 2 ou 3 minutes.
- Départ au premier sort lancé sur la cible (au début de l'incantation, pas au premier dégât). Un sort lancé sur soi (bouclier, buff) avant l'attaque ne déclenche pas le chrono. Nom et GUID de la cible sont relevés à sa sélection (ils peuvent être secrets ensuite).
- Fin du chrono : signal sonore et consigne d'arrêter d'attaquer. À la sortie de combat, lecture du compteur de dégâts, puis ouverture de la page Cycle.
- Étiquette de session facultative.

**Mannequins :** « Mannequin d'entraînement », PNJ n° 5652 (niveau 25), vu en jeu mais **non accessible** pour l'instant (l'accès au niveau 25 était une fausse information, 2026-10-17). Les sessions sur monstre sont donc le cas normal ; sur un monstre qui riposte, le DPS couvre tout le combat. Reconnaissance par l'identifiant de PNJ si le GUID est lisible ; sinon (cas constaté), par le nom de l'ennemi que donne le compteur de dégâts en fin de session. Sinon, repli sur un monstre avec avertissement ; si le combat s'arrête avant la fin du chrono (monstre mort), la session est annulée.

### Mesure des dégâts
- Source : `C_DamageMeter`, une session de compteur par combat. Au départ, l'addon note le dernier identifiant de session existant ; à la fin, il lit les sessions plus récentes.
- Lue après la sortie de combat : dégâts totaux, durée du combat (à la seconde), dégâts et DPS par sort.
- DPS de la session = dégâts totaux / durée du combat selon le compteur. Le combat commence au premier sort et se termine quelques secondes après le signal : écart faible, signalé dans le rapport.
- Non disponible : critiques et nombre de coups. Le nombre de lancers vient des événements de sorts.

### Détection du cycle

Sur 1 minute (environ 35 à 40 sorts), trouver la suite d'un nombre défini de sorts qui se répète.

- Exemple : `DoT · Feu · Feu · Instant · Feu · Feu · DoT · Feu · Feu…` → cycle de 6 sorts, environ 9 s, répété 6 fois.
- Résultat : **ouverture** (premiers sorts différents), **cycle** (suite, nombre de sorts, durée, répétitions), **fiabilité** (part de la session conforme au cycle), **écarts**.
- Algorithme (jalon 3, `modules/Cycle.lua`) : chaque suite de L sorts (L de 1 à 12) prise dans le début de la session est un motif candidat ; la session entière est alignée sur le motif répété. Sorts de tête hors motif = ouverture ; ensuite, sort en trop = écart « inséré », sort attendu sauté = écart « omis ». Fiabilité = sorts conformes / (sorts après l'ouverture + omissions). Choix : meilleur score (fiabilité − 0,015 × L, pour qu'un motif long n'« avale » pas un proc), puis cycle le plus court, puis ouverture la plus courte. Au moins 2 répétitions. Sorts interrompus ignorés.
- **Décisions du 2026-10-17 :**
  - **Baguette et tir automatique comptés dans le cycle** (grosse part des dégâts à bas niveau) ; une série de tirs consécutifs forme une seule étape « Tir » (le nombre de tirs varie d'une répétition à l'autre).
  - **Sorts sans dégâts écartés** (bouclier, soins, contrôle) d'après le compteur de dégâts ; si le compteur est illisible, rien n'est écarté. Limite connue : un sort utile au DPS sans dégâts propres (malédiction, marque) serait écarté aussi.
  - **Confirmé le 2026-10-17** : les sorts de mise en place (« setup ») qui ne font pas de dégâts, comme Étreinte vampirique, ne font pas partie du cycle. Joués pendant une amélioration ou un combat guidé, ils restent « hors partition », sans pénalité.
  - Un sort présent dans une répétition sur deux (proc ou oubli, indiscernables) reste hors du cycle et compte comme écart.
- Cas à gérer :
  - procs insérés au hasard : mis de côté pour ne pas casser la détection ;
  - cycles longs (DoT de 15 s ou plus) : si la fiabilité est faible, proposer une session de 2 min ;
  - baisse de mana : un second cycle peut apparaître en fin de session ;
  - classes à énergie : cycle défini comme « générateurs × N + finisseur » plutôt que par un nombre fixe de sorts.

---

## 4. Déroulé des sessions

### Nouvelle session
1. Clic sur « Nouvelle session » → panneau : durée, type (mono / multi-cibles), étiquette. Préremplis avec la dernière session.
2. « Prêt » → la fenêtre se ferme, barre compacte « En attente du premier sort sur la cible ».
3. Le chrono démarre au premier sort lancé sur la cible.
4. Pendant la session : temps restant, dégâts en direct (valeur secrète affichée telle quelle, si le client le permet), bouton annuler.
5. Fin du chrono : signal sonore, barre « Terminé, arrête d'attaquer ». À la sortie de combat : lecture du compteur, ouverture de la page Cycle (jalon 2 : résumé dans le chat).

Garde-fous : avertissement si la cible n'est pas un mannequin (possibilité de continuer). Si le combat s'arrête avant la fin du chrono (monstre mort), une fenêtre propose d'**enregistrer la session écourtée** ou de l'**abandonner** (décision du 2026-10-17, remplace l'annulation automatique) ; une session écourtée garde sa durée réelle et la mention « écourtée ».

### Session d'amélioration
Même principe, à partir d'un cycle existant, avec la timeline rythmique affichée.

- Points d'entrée : « Améliorer » (journal), « Essayer sur mannequin » (page Cycle ou éditeur).
- Le panneau affiche en plus le cycle de référence (partition miniature, DPS).
- Pendant l'attente, la timeline est affichée avec le premier sort dans le cadre « maintenant » ; elle démarre avec le chrono.
- Fin : page Cycle en mode comparaison (DPS face à la référence, précision, interruptions, sorts ratés), puis : enregistrer comme nouvelle version, remplacer la référence, ou ignorer.

**Décision :** partition **fixe** pendant les sessions d'amélioration ; partition **vivante** (recalculée selon procs et erreurs) en combat normal.

**Décisions du jalon 6a (2026-10-17, `modules/Partition.lua`) :**
- Partition = version éditée du cycle si elle existe, sinon ouverture + cycle détecté, répété jusqu'à couvrir la durée de la session. Durée d'une note = temps d'incantation (au moins un GCD de 1,5 s) ; série de tirs = durée moyenne mesurée dans la session de référence.
- **Contenu fixe, tempo recalé** : l'heure attendue d'une note = moment où la précédente a été jouée + sa durée (sinon un seul retard décalerait toute la suite, impossible à rattraper).
- Note **sautée** (le sort suivant est joué à sa place) : ratée (« oubliée »), le sort joué est jugé à la place de la note sautée. Note **non jouée** quand l'heure de la suivante arrive : ratée (« pas jouée »).
- Sort **hors partition** (proc, bouclier, soin) : signalé, combo conservé, la note attendue est repoussée de sa durée (au moins un GCD).
- **Série de tirs = temps libre** : le joueur décide quand il arrête de tirer ; aucune note n'est ratée pendant la série, le sort suivant est jugé sur l'ordre seulement. Un tir hors de sa place est ignoré. **La série elle-même est jugée sur l'ordre** (2026-10-17, d'après les combats guidés) : le premier tir automatique part au rythme du jeu, 1,6 à 1,8 s après le sort précédent, pas du joueur.
- Même sort de rang différent = même note (comparaison par nom).
- Précision = moyenne des points (Parfait 1, Bien 0,7, Juste 0,4, Raté 0). Combo = notes réussies d'affilée.
- Points d'entrée : « Améliorer » (menu du journal, page Cycle), `/sdt ameliorer [n] [secondes]`. Le HUD remplace la barre compacte. Fin : résumé avec le rythme dans le chat ; la page Cycle en mode comparaison arrive au jalon 6b.
- **Zones d'immobilité et « Interrompu » (jalon 6b)** : sous chaque note à incantation ou canalisation, une traînée de la longueur du temps d'incantation ; celle de l'incantation en cours se réduit jusqu'au cadre « maintenant ». La vitesse étant secrète en combat, « Interrompu » vient de l'interruption du sort (bouger l'annule) ou d'un déplacement signalé pendant une incantation / canalisation. La note interrompue perd son verdict (0 point), le combo repart à zéro et la note doit être rejouée (elle redevient attendue tout de suite). Un seul « Interrompu » par note.
- **Jauge de mana (jalon 6b)** : barre sous le titre du HUD, alimentée avec la mana secrète (acceptée par la barre). Classes à mana seulement ; énergie et rage au jalon 7.
- **Mode comparaison (jalon 6b)** : la page Cycle d'une session d'amélioration affiche en bas « Comparaison avec « référence » » (DPS face à la référence et écart, bilan du rythme) et trois choix : **Nouvelle version** (gardée, nommée « Nom v2 », « v3 »…, la référence reste), **Remplacer la référence** (prend son nom, sa version éditée et son statut actif ; l'ancienne est supprimée, avec confirmation), **Ignorer** (la session d'amélioration est supprimée, avec confirmation). La version éditée de la référence est reprise pour pouvoir réaméliorer. Nom et DPS de la référence sont figés dans la session.
- Rejeu des sessions réelles (non jouées en rythme) : écarts typiques de +0,3 à +0,6 s entre deux sorts. Seuils de la section 6 à confronter au jeu en rythme.

---

## 5. Écrans

### Page Cycle (consultation)
Version simple (jalon 3) : ouverte en fin de session ou par `/sdt cycle [n]` ; chiffres clés, ouverture et cycle en icônes (durée d'incantation sous chaque icône), écarts, détail par sort. La partition, la frise et la progression viendront ensuite.
- Chiffres clés : DPS et écart avec la meilleure session, nombre de sorts du cycle et durée, répétitions et fiabilité, mana en fin de session (si lisible hors combat).
- Ouverture, puis cycle affiché en partition (même style que la timeline, avec zones d'immobilité).
- Frise de la session : répétitions surlignées, écarts marqués.
- Détail par sort : dégâts, part, lancers, DPS par seconde d'incantation (pas de critiques : non fournis par le compteur).
- Progression (Coach) : courbe d'évolution, erreurs les plus fréquentes.
- Bouton « Modifier le cycle » vers la vue d'édition.

### Vue d'édition (Formaliser) — V1
- Aperçu de la partition en haut, mis à jour en direct (sorts actifs, durée estimée).
- Liste verticale : glisser-déposer (et flèches), touche, nom, type (incantation, instantané, canalisation), activer / désactiver, retirer.
- Ajouter un sort depuis le grimoire.
- « Version auto » pour revenir au cycle détecté.
- État « Modifié · non enregistré », Annuler / Enregistrer, rappel de valider par une session.

**Navigation (décision du 2026-10-17) :** la page Cycle et la vue d'édition sont **une seule page à deux modes**, « Consultation » et « Édition » (même taille, même position mémorisée). Pas d'onglets : « Modifier le cycle » passe en Édition, « Annuler » et « Enregistrer » reviennent en Consultation ; la croix ou Échap ferment la page. Ouvrir le grimoire ne ferme ni la page ni le journal.

**Décisions (jalon 5, 2026-10-17) :** l'éditeur crée une **version éditée enregistrée à côté** du cycle détecté, qui n'est jamais modifié ; « Version auto » recharge le cycle détecté dans la liste. La page Cycle bascule entre « Détecté » et « Édité » (version éditée par défaut si elle existe) ; le journal affiche la version éditée en miniature avec un badge « Édité ». Ouverture : bouton « Modifier le cycle » de la page Cycle ou menu « … » du journal. Ajout de sort par glisser-déposer depuis le grimoire. Type « Série » pour les tirs automatiques. Durée estimée = somme des temps d'incantation (au moins un GCD de 1,5 s) des étapes actives, séries de tirs comptées à part. Touche : relevée sur les barres d'action principales (emplacements 1 à 72) par nom de sort. « Annuler » ou la fermeture abandonne les modifications non enregistrées.

Itérations suivantes : conditions par ligne (expiration de debuff, seuil de ressource, proc actif, plusieurs ennemis), profils multiples, aperçu étendu.

### Journal des cycles
- Cartes : nom, date, type de combat, partition miniature, DPS, nombre de sorts, fiabilité.
- Filtres mono / multi-cibles ; tri par date, DPS ou fiabilité.
- Badges : « Actif dans le Guide » (un par type de combat) et « Meilleur DPS » (par type de combat).
- Sélection de 2 cycles pour comparaison.
- Menu « … » : ouvrir, améliorer, définir comme actif, dupliquer, renommer, supprimer. Clic sur une carte : page Cycle.
- Bouton « Nouvelle session » ; plus tard export / import.
- **Par personnage (2026-10-17)** : la sauvegarde est commune au compte ; chaque session retient son personnage (« Nom-Royaume ») et le journal n'affiche que celles du personnage connecté. Case « Tous les personnages » pour tout voir (nom du personnage sur chaque carte). Les anciennes sessions, sans personnage, sont rattachées par leur classe puis attribuées au premier personnage de cette classe qui se connecte.
- **Version jalon 4 :** ouvert par `/sdt` ou un clic sur l'icône de minimap. Une carte par session enregistrée (y compris sans cycle). « Actif » et « Meilleur DPS » se comprennent **par classe et par type de combat** (le compte peut avoir plusieurs classes). Comparaison simple de 2 cycles côte à côte (DPS, étapes, durée, fiabilité, partition, écart de DPS). « Améliorer » est grisé jusqu'au jalon 6. Le cycle détecté est mis en cache dans la session et recalculé si l'algorithme change (`Cycle.VERSION`).

---

## 4 bis. DoT : dégâts sur la durée (décision du 2026-10-17)

- Un DoT n'a pas de place fixe dans le cycle : il est **rejoué à son expiration** et passe alors avant les sorts de remplissage, qui gardent leur ordre. Pour un DoT à incantation, sa note arrive en avance de son temps d'incantation, pour qu'il s'applique pile à l'expiration.
- L'expiration est **calculée** à partir du moment réel où le joueur a lancé le DoT (fin d'incantation + durée), sans lire les effets sur la cible (secrets en combat). La partition est replanifiée après chaque sort.
- **Durée** : lue automatiquement dans la description du sort (« … de dégâts en / pendant / sur N sec » ; la dernière durée si plusieurs) ; modifiable dans l'éditeur (type « DoT », clic droit sur le type). Un type choisi à la main dans l'éditeur n'est plus changé par la reconnaissance automatique. Canalisations et séries de tirs ne sont jamais des DoT. Cas limite : Flammes sacrées (impact direct + DoT de 10 s) est reconnue comme DoT ; la repasser en « Incantation » si on la veut en remplissage.
- **Jugement** : DoT relancé plus d'un GCD (1,5 s) avant son expiration → « trop tôt · DoT écrasé » (raté, erreur « écrasé » pour le Coach), l'expiration est recalée. Relancé un peu avant (moins d'un GCD) : accepté. DoT dû mais non relancé : compté « pas joué » une seule fois, il reste en tête de partition ; les sorts de remplissage joués entre-temps ne sont pas pénalisés. DoT interrompu : pas posé, de nouveau dû tout de suite.
- Série de tirs : s'arrête à l'échéance du prochain DoT. Cycle fait seulement de DoT : attente entre les échéances.
- HUD : mention « DoT » sur les notes concernées. Logique en Lua pur (`Partition.lua`, 78 tests ; `Cycle.DureeDot`).

## 5 bis. Guide en combat normal (jalon 8a, 2026-10-17)

- En combat normal, hors session, le HUD suit le cycle marqué « Actif » pour la classe du joueur (mono-cible en priorité, sinon multi-cibles). Démarrage à l'entrée en combat, arrêt à la sortie. `/sdt guide` l'active ou le coupe (activé par défaut ; rien ne s'affiche tant qu'aucun cycle n'est actif). Bouton « Masquer » : coupe le Guide pour le combat en cours.
- **Partition vivante** : elle se recale sur ce qui est joué. Le premier sort du combat prend la partition là où il tombe dans le cycle, sans pénalité ; un sort qui correspond à une note plus loin (au plus la longueur du cycle moins une note, plafonné à 8, pour ne jamais sauter un cycle entier) y fait sauter la partition, les notes sautées étant comptées comme oubliées ; procs et sorts hors partition repoussent la note attendue. Mêmes verdicts qu'en amélioration (Parfait… Interrompu).
- Pas de chrono ; le titre indique « Guide · nom du cycle » et le numéro du cycle en cours.
- **Sort d'ouverture rattrapé** : on n'entre en combat qu'après le premier sort (fin de l'incantation, ou juste après un instantané). Les sorts des 6 dernières secondes sont gardés hors combat et rejoués au démarrage du Guide : le sort qui lance le combat est la première note jugée et le départ de la timeline.
- À la fin de chaque combat guidé, le bilan (précision, verdicts, combo, erreurs par sort) est gardé pour le Coach (jalon 8b) dans `SalleDuTempsDB.combatsGuides` (500 derniers combats).

## 5 ter. Coach : page Progression (jalon 8b, 2026-10-17)

- Ouverte depuis la page Cycle (bouton « Progression »), le menu « … » du journal ou `/sdt progression [n]`. Porte sur la **lignée** du cycle : la session racine (on remonte les références), ses améliorations et versions, et les combats guidés sur l'une d'elles.
- **Courbe** des 20 dernières mesures : DPS (or, axe de gauche) et précision (vert, axe de droite) ; gros points pour les sessions et améliorations, petits pour les combats guidés. Le DPS d'un combat guidé est lu dans le compteur de dégâts juste après la sortie de combat.
- **Tendance** : moyenne des 5 dernières mesures contre les 5 précédentes, pour le DPS et la précision (écart en points).
- **Erreurs les plus fréquentes** (5) : par sort, le détail (oublié, pas joué, en retard, trop tôt, interrompu), le nombre de sessions ou combats concernés, et un conseil selon l'erreur dominante.
- Logique en Lua pur (`modules/Coach.lua`, testée par `tests/test_coach.lua`).

## 6. HUD et timeline (sous le personnage)

Bloc unique et compact sous le personnage, déplaçable et redimensionnable d'un seul tenant, légèrement transparent, masqué hors combat et hors session. De haut en bas :

1. **Titre et infos de session** : cycle suivi, répétition en cours (« Cycle 2/6 »), dégâts en direct (valeur secrète, si affichable), temps restant, annuler.
2. **Ligne de ressource** propre à la classe (voir section 7).
3. **Jugement** : combo, verdict, précision.
4. **Timeline** : cadre « maintenant » à gauche, sorts à venir arrivant de la droite et défilant vers la gauche.

### Règles de la timeline
- Chaque icône affiche sa touche de barre d'action.
- Un seul appui par sort : c'est le début de la note qui est jugé.
- **Zone d'immobilité** : traînée en pointillés (icône main levée) derrière les incantations et canalisations, de la longueur du temps d'incantation. Se déplacer pendant cette zone → « Interrompu », combo remis à zéro.
- Les trous entre zones d'immobilité indiquent quand on peut se déplacer.
- **Tolérance en avance** : appuyer juste avant la fin de l'incantation précédente compte comme Parfait (fenêtre de file d'attente des sorts).
- **Notes surprises** : un proc ou un sort réactif apparaît en cours de route.
- **Séparateurs de cycle** : trait pointillé vertical au début de chaque répétition.
- **État d'attente** : « En attente du premier sort sur la cible… ».

### Jugement (seuils de départ, à ajuster en jeu)
| Verdict | Condition |
|---|---|
| Parfait | écart < 0,12 s, ou jusqu'à 0,4 s en avance |
| Bien | écart < 0,25 s |
| Juste | écart < 0,35 s |
| (énergie) | une note qui attendait l'énergie a 0,2 s de retard pardonnée (marge de réaction) |
| Raté · trop peu de points | coup de grâce lancé avec moins de points de combo que les générateurs joués |
| Raté | mauvaise touche ou note passée |
| Interrompu | déplacement pendant une zone d'immobilité |

---

## 7. Adaptation par ressource

### Mana (mage, démoniste, prêtre, chaman, paladin, chasseur, druide hors forme)
- Tempo : GCD et temps d'incantation.
- HUD : jauge de mana. Enjeu : tenue sur la durée.

### Énergie (voleur, druide félin)
**Constats et décisions du 2026-10-17 :** l'énergie est secrète (même hors combat) mais s'affiche dans une barre ; la régénération est **continue** sur ce client (événement toutes les 0,1 s, pas de paliers de 2 s) ; les coûts des sorts sont lisibles. HUD : barre d'énergie jaune à la place de la mana, **points de combo en cases juste en dessous** (barre 0 → max découpée en cases, valeur passée telle quelle). **Partition à énergie (version 0.12.0)** : énergie **calculée** (maximum lu dans le jeu, 100 au départ, coût de chaque sort lu dans le jeu, régénération **mesurée** : segments partis de plein avec **un seul sort**, coût ÷ temps jusqu'au retour à plein, **médiane** des 9 dernières mesures par personnage ; 10/s, règle de Classic, tant qu'il y a moins de 3 mesures. Une attaque ratée ou esquivée rend l'essentiel de son coût sans que l'addon le voie : les segments à plusieurs sorts surestimaient la régénération (12,7 mesurés). « Énergie pleine » = aucun signal de gain depuis 1 s (0,4 s déclenchait des recalages à tort en combat)) ; une note n'arrive que quand l'énergie calculée suffit, l'attente est affichée en zone « sablier » jaune devant la note ; attendre l'énergie n'est jamais une faute, le retard se mesure à partir du moment où l'énergie suffisait. Lancer plus tôt que le calcul ne le prévoyait = l'énergie était là : verdict Parfait et calcul recalé. Recalage à 100 quand le jeu cesse de signaler des gains (énergie pleine). Temps de recharge global d'une seconde. Les sorts hors partition dépensent aussi leur énergie.

**Version 0.13.0 (2026-10-17) :**
- **Marge de réaction** : une note qui attend l'énergie ne peut pas être mise en file d'attente, le joueur réagit à la barre ; son retard est jugé avec **0,2 s pardonnée** (`Partition.MARGE_REACTION`). Les autres notes gardent les seuils normaux.
- **Énergie pleine** : chaque seconde passée à 100 est de la régénération perdue. Le temps à énergie pleine est relevé pour chaque session (depuis le premier sort) et chaque combat guidé (depuis l'entrée en combat : une ouverture tardive compte). Il est affiché dans le résumé du chat avec l'énergie perdue estimée, et en tendance sur la page Progression (une baisse est un progrès). Le HUD signale « PLEINE » en direct. Ce n'est pas une erreur par sort : c'est une mesure de la session.
- **Points de combo** : générateurs et coups de grâce reconnus dans la description des sorts (« Ajoute N point(s) de combo » / « Coup de grâce »). Un coup de grâce est **raté (« trop peu de points »)** s'il part avec moins de points que les générateurs **joués** depuis le coup de grâce précédent. Un générateur oublié est déjà compté « oublié » : pas de double peine. Le cas visé est l'attaque esquivée ou parée, qui ne donne pas de point ; le conseil est d'ajouter une attaque avant le coup de grâce. Les points sont lus s'ils sont lisibles, sinon **estimés** : chaque signal de changement ajoute un point, sauf juste après l'envoi d'un coup de grâce, où il les remet à zéro. Une esquive ne donne ni point ni signal. Les points comptés sont relevés à l'**envoi** du coup de grâce (`UNIT_SPELLCAST_SENT`), avant sa dépense. Sans valeur connue, pas de jugement des points. Vérifié en jeu (sonde du 2026-10-17) : points **lisibles en combat**, signal reçu, rôles bien lus.

**Version 0.14.0 (2026-10-17), décision de Sébastien : une note qui n'a pas porté doit être rejouée avant de passer à la suivante.**
- **Coup esquivé, paré ou raté** : repéré par les points de combo, sans journal de combat. Un générateur dont les points n'augmentent pas, ou un coup de grâce dont les points ne retombent pas, dans les 0,5 s qui suivent son lancer, n'a pas porté. Ce n'est pas une faute du joueur : son verdict est retiré sans pénalité (« ESQUIVÉ · à rejouer »). La même note redevient la note attendue, après le temps de recharge global, et la suite du cycle attend qu'elle soit jouée. Le jeu rend l'essentiel du coût (80 % retenus, règle de Classic à vérifier) : le calcul d'énergie le rajoute. Invisible : un générateur lancé à 5 points.
- **Perte de contrôle** (étourdi, apeuré, désarmé…) : la partition se met en pause. La note attendue reste due, rien n'est déclaré passé, et la première note jouée après a la marge de réaction. L'énergie, elle, continue de se régénérer dans le calcul.
- Tempo : paliers d'énergie (environ +20 toutes les 2 s dans Classic), GCD de 1 s.
- HUD : jauge d'énergie et pastilles de points de combo.
- Timeline : traits des paliers sous la timeline, zones « sablier » d'attente d'énergie (pas de touche à jouer), finisseurs mis en évidence.

### Rage (guerrier, druide ours)
- HUD : jauge de rage et barre de vitesse d'arme.
- Timeline : seconde ligne pour les coups blancs. Les sorts « au prochain coup » (Frappe héroïque) s'y placent, hors GCD ; le jugement vérifie qu'ils ont été placés avant le coup.
- Sorts réactifs (Fulgurance après une esquive) en notes surprises.
- Sur mannequin, le joueur ne reçoit pas de coups : rage plus faible qu'en combat réel, à signaler dans le rapport.

---

## 8. Questions ouvertes
- [x] Numéro d'interface de la bêta pour le `.toc` : 16001 (confirmé en jeu)
- [x] Présence des mannequins dans la bêta : existent (PNJ n° 5652, niveau 25) mais **non accessibles** (2026-10-17). Sessions sur monstre avec avertissement.
- [x] Nom exact des mannequins : « Mannequin d'entraînement », PNJ n° 5652, niveau 25 (emplacement à noter)
- [x] Accès au journal de combat : **interdit aux addons** (2026-10-14). La détection du cycle reste possible via les sorts lancés (`UNIT_SPELLCAST_*`).
- [ ] Ressource du joueur secrète (`UnitPower`) : jauge affichable via une barre de progression ? Logique fondée sur la ressource (énergie, rage, mana en fin de session) à repenser.
- [x] Source du DPS et du détail par sort : `C_DamageMeter` (compteur intégré). Lisible **hors combat seulement** ; en combat tout est secret. Pas de critiques ni de nombre de coups (le nombre de lancers vient de `UNIT_SPELLCAST_*`).
- [x] Dégâts en direct dans le HUD : oui, une valeur secrète s'affiche telle quelle (`SetFormattedText`). Pas de DPS en direct (division impossible), seulement le total.
- [x] Reconnaissance du mannequin : nom et GUID de la cible sont secrets même hors combat ; reconnaissance à la fin de la session par le nom d'ennemi du compteur de dégâts.
- [ ] Mana en fin de session : la mana reste secrète hors combat. Probablement impossible ; à retirer de la page Cycle si confirmé.
- [x] Sections 1, 3, 4, 5 et 6 revues en conséquence (2026-10-14).
- [ ] Jauge de ressource (section 7) : la ressource du joueur est secrète ; affichage via barre de progression à tester.
- [ ] Commande définitive (`/sdt` ou `/salle`)
- [ ] Nom du mode Guide (éventuellement dans le thème)
- [ ] Première classe / spé à couvrir
