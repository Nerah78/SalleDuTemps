# La Salle du Temps

Addon d'aide à la rotation DPS pour **WoW Forever** (base de type WoW Classic), façon *Guitar Hero* :
trouve la meilleure suite de sorts de ta classe, puis apprends à la jouer en rythme.

> L'addon **ne lance jamais de sort à ta place** : il observe ce que tu joues et te suggère la suite,
> dans le respect des règles de Blizzard.

## Ce que fait l'addon

- **Sessions d'entraînement** chronométrées : la session démarre à ton premier sort sur la cible, et le DPS
  est lu dans le compteur de dégâts du jeu à la sortie de combat.
- **Détection du cycle** : à partir de la suite de sorts joués, l'addon repère ton cycle de rotation
  (ouverture, puis sorts répétés) et l'affiche sur la **page Cycle**.
- **Journal des cycles** : toutes tes sessions par personnage, triées par DPS, fiabilité ou date, avec
  comparaison de deux cycles.
- **Éditeur** : corrige ou complète le cycle détecté (ordre, types de sorts, durée des DoT).
- **Timeline rythmique** (HUD) : les prochains sorts défilent sous ton personnage ; chaque lancer est jugé
  *Parfait*, *Bien*, *Juste* ou *Raté*. Zones d'immobilité pour les incantations, verdict *Interrompu*
  si tu bouges.
- **Sessions d'amélioration** : rejoue un cycle sur une partition fixe et compare-toi à la référence.
- **Guide en combat normal** : hors session, le HUD suit ton cycle « Actif » et se recale sur ce que tu joues.
- **Coach** : courbe de progression (DPS et précision), tendance récente et erreurs les plus fréquentes,
  avec un conseil pour chacune.
- **DoT** : les sorts de dégâts sur la durée reviennent à leur expiration ; une relance trop tôt est
  signalée (« DoT écrasé »).
- **Voleur** : énergie calculée (la note attend que l'énergie suffise), points de combo sous la barre
  d'énergie, coup de grâce jugé sur ses points, coup esquivé ou paré à rejouer sans pénalité, temps passé
  à énergie pleine, pause pendant un étourdissement.

## Installation

1. Télécharge le dépôt (bouton **Code → Download ZIP**) ou clone-le.
2. Place le dossier dans `World of Warcraft/_classic_beta_/Interface/AddOns/`. Il doit s'appeler
   **`SalleDuTemps`** (comme le fichier `SalleDuTemps.toc`).
3. Lance le jeu et active l'addon dans la liste des addons.

Une icône apparaît près de la minimap : clic gauche pour le journal, clic droit pour afficher les sorts
lancés dans le chat.

## Premiers pas

1. `/sdt session` : choisis la durée et le type de combat, puis attaque un monstre.
2. À la fin, la page Cycle s'ouvre avec ton DPS et le cycle détecté.
3. **Améliorer** : rejoue ce cycle en rythme sur la timeline.
4. Dans le journal (menu « … »), **Définir comme actif** : le Guide te suivra ensuite dans tous tes combats.

## Commandes

| Commande | Effet |
|---|---|
| `/sdt` | journal des cycles |
| `/sdt session` | nouvelle session (panneau des réglages) |
| `/sdt test [N]` | session de test de N secondes (15 par défaut) |
| `/sdt ameliorer [n] [secondes]` | session d'amélioration de la session n |
| `/sdt progression [n]` | progression du cycle de la session n (Coach) |
| `/sdt guide` | activer ou couper le Guide en combat normal |
| `/sdt annuler` | annuler la session en cours |
| `/sdt sessions` | dernières sessions enregistrées |
| `/sdt cycle [n]` | page Cycle de la session n (la dernière par défaut) |
| `/sdt sorts` | afficher ou non les sorts lancés dans le chat |
| `/sdt icone` | masquer ou afficher l'icône de minimap (`/sdt icone reset` pour la replacer) |
| `/sdt aide` | liste complète, dont les commandes de diagnostic |
| `/sdt version` | numéro de version |

## État du projet

Développement sur la bêta de WoW Forever (interface 16001). Version actuelle : voir [CHANGELOG.md](CHANGELOG.md).

| Jalon | Contenu | État |
|---|---|---|
| 1 | Squelette, icône, `/sdt`, sorts dans le chat | terminé |
| 2 | Sessions d'entraînement complètes | terminé |
| 3 | Détection du cycle, page Cycle | terminé |
| 4 | Journal des cycles | terminé |
| 5 | Éditeur du cycle | terminé |
| 6 | Timeline rythmique, sessions d'amélioration (classes à mana) | terminé |
| 7 | Énergie (voleur) et rage (guerrier) | énergie faite, rage à venir |
| 8 | Coach, progression, Guide en combat normal | terminé |

La conception détaillée est décrite dans [docs/specification.md](docs/specification.md).

### Limites connues

Le client de WoW Forever protège beaucoup d'informations (« valeurs secrètes ») et interdit le journal de
combat aux addons. L'addon contourne ces limites : DPS lu après le combat, énergie du voleur calculée plutôt
que lue, esquives repérées par les points de combo. Les mannequins d'entraînement ne sont pas accessibles
sur la bêta : les sessions se font sur des monstres.

## Tests hors du jeu

Les modules de calcul (`Cycle.lua`, `Partition.lua`, `Coach.lua`) sont en Lua pur et testés avec Lua 5.4,
depuis le dossier `AddOns` :

```
lua SalleDuTemps/tests/test_cycle.lua
lua SalleDuTemps/tests/test_partition.lua
lua SalleDuTemps/tests/test_coach.lua
lua SalleDuTemps/tests/simulation_ui.lua
```

`simulation_ui.lua` imite l'API du jeu pour ouvrir toutes les fenêtres de l'addon et rejouer des scénarios ;
on peut lui passer une copie d'une sauvegarde `SalleDuTemps.lua` en argument.

## Licence

[GPL v3](LICENSE). Auteur : Nerah78.
