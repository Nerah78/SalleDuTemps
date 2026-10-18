-- La Salle du Temps - addon d'aide à la rotation DPS pour WoW Forever
-- Copyright (C) 2026 Sébastien
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <https://www.gnu.org/licenses/>.

-- Capture : écoute des sorts lancés par le joueur.
-- Jalon 1 : affichage brut dans le chat (temps relatif, étape, sort, identifiant, durée d'incantation, cible).
-- Le journal de combat et les déplacements viendront au jalon 2.

local _, ns = ...

local Capture = {}
ns.Capture = Capture

local Print = function(msg) ns.Print(msg) end

local origine       -- GetTime() du premier sort affiché (chrono relatif)
local cibles = {}   -- castGUID -> nom de la cible (donné par UNIT_SPELLCAST_SENT)
local enCours = {}  -- castGUID -> true pour les incantations / canalisations commencées

local EstSecret, Lisible = ns.EstSecret, ns.Lisible

local function NomSort(id)
    id = Lisible(id)
    if not id then return "?" end
    if GetSpellInfo then
        local ok, nom = pcall(GetSpellInfo, id)
        if ok and Lisible(nom) then return nom end
    end
    if C_Spell and C_Spell.GetSpellName then
        local ok, nom = pcall(C_Spell.GetSpellName, id)
        if ok and Lisible(nom) then return nom end
    end
    return "?"
end
Capture.NomSort = NomSort

-- ---------------------------------------------------------------------
-- Énergie (voleur, jalon 7) : coûts des sorts (lisibles) et énergie pleine (déduite : le jeu signale un gain
-- d'énergie toutes les 0,1 s tant qu'elle n'est pas pleine ; plus de signal = pleine). L'énergie elle-même
-- est secrète.
-- ---------------------------------------------------------------------
local TYPE_ENERGIE = 3   -- Enum.PowerType.Energy
local coutsEnergie = {}
local dernierGainEnergie   -- GetTime() du dernier signal de gain d'énergie

-- Le personnage utilise-t-il l'énergie ? (type de ressource lisible ; sinon d'après la classe)
function Capture.UtiliseEnergie()
    local ok, typeRessource = pcall(UnitPowerType, "player")
    local lisible = ok and Lisible(typeRessource)
    if lisible ~= nil then return lisible == TYPE_ENERGIE end
    return select(2, UnitClass("player")) == "ROGUE"
end

-- Coût en énergie d'un sort (0 s'il n'en coûte pas), mis en cache.
function Capture.CoutEnergie(id)
    id = Lisible(id)
    if not id then return 0 end
    if coutsEnergie[id] then return coutsEnergie[id] end
    local lire = C_Spell and C_Spell.GetSpellPowerCost or GetSpellPowerCost
    if not lire then return 0 end
    local ok, couts = pcall(lire, id)
    if not (ok and type(couts) == "table" and not EstSecret(couts)) then
        return 0   -- données du sort pas encore chargées : pas mis en cache, on relira plus tard
    end
    local cout = 0
    for _, c in ipairs(couts) do
        if Lisible(c.type) == TYPE_ENERGIE and Lisible(c.cost) then cout = c.cost end
    end
    coutsEnergie[id] = cout
    return cout
end

-- Énergie pleine ? (aucun signal de gain depuis 1 s ; à 0,4 s, un ralentissement du jeu ou du réseau en plein
-- combat faisait croire à une énergie pleine et remontait le calcul à tort, 2026-10-17)
Capture.DELAI_PLEINE = 1
function Capture.EnergiePleine()
    return dernierGainEnergie == nil or GetTime() - dernierGainEnergie > Capture.DELAI_PLEINE
end

-- Temps passé à énergie pleine (cumulé depuis le chargement, en s) : la régénération y est perdue. Une période
-- pleine commence au dernier signal de gain (l'énergie vient d'atteindre le maximum) et finit à la dépense
-- suivante. Une session ou un combat en retient la différence entre son début et sa fin.
local chargement = GetTime()
local cumulPlein = 0

local function FinPeriodePleine(t)
    local depuis = dernierGainEnergie or chargement
    if t - depuis > Capture.DELAI_PLEINE then cumulPlein = cumulPlein + (t - depuis) end
end

function Capture.TempsPlein()
    local t = GetTime()
    local enCours = Capture.EnergiePleine() and (t - (dernierGainEnergie or chargement)) or 0
    return cumulPlein + enCours
end

function Capture.EnergieMax()
    local maximum = Lisible(UnitPowerMax("player", TYPE_ENERGIE))
    return (maximum and maximum > 0) and maximum or 100
end

-- Régénération d'énergie MESURÉE (par s) : partie de plein, un seul sort lancé, l'énergie revient à plein quand
-- la régénération a compensé son coût : regen = coût / temps jusqu'au retour à plein.
-- Seulement les segments à UN sort, et la MÉDIANE des dernières mesures (au moins 3, sinon 10/s, règle de
-- Classic) : une attaque ratée ou esquivée rend l'essentiel de son coût, sans que l'addon le voie (journal de
-- combat interdit) ; compter des coûts pleins sur plusieurs sorts surestimait la régénération (12,7 au lieu de
-- ~10, 2026-10-17).
Capture.REGEN_DEFAUT = 10
Capture.MESURES_MIN = 3
local MESURES_GARDEES = 9
local mesure = { pleine = true, debut = nil, depense = 0, sorts = 0 }

local function Mediane(valeurs)
    local triees = {}
    for i, v in ipairs(valeurs) do triees[i] = v end
    table.sort(triees)
    local n = #triees
    if n % 2 == 1 then return triees[(n + 1) / 2] end
    return (triees[n / 2] + triees[n / 2 + 1]) / 2
end

function Capture.RegenEnergie()
    local liste = ns.db.mesuresRegen and ns.db.mesuresRegen[ns.Data.Personnage()]
    if not liste or #liste < Capture.MESURES_MIN then return Capture.REGEN_DEFAUT end
    return Mediane(liste)
end

-- Sort réussi à l'instant t : sa dépense d'énergie entre dans la mesure en cours.
local function NoterDepense(id, t)
    if not Capture.UtiliseEnergie() then return end
    local cout = Capture.CoutEnergie(id)
    if cout <= 0 then return end
    -- La dépense vaut signal : l'énergie n'est plus pleine, même si le premier signal de gain tarde un peu
    -- (sans ça, la mesure était aussitôt close, le dernier signal datant d'avant la dépense).
    FinPeriodePleine(t)
    dernierGainEnergie = t
    if mesure.debut then
        mesure.depense, mesure.sorts = mesure.depense + cout, mesure.sorts + 1
    elseif mesure.pleine then
        mesure.debut, mesure.depense, mesure.sorts, mesure.pleine = t, cout, 1, false
    end
end

local function FinMesure()
    local fin = dernierGainEnergie
    -- Un seul sort dans le segment : un raté éventuel reste une mesure isolée, écartée par la médiane.
    if fin and mesure.debut and mesure.sorts == 1 and fin - mesure.debut > 1 and mesure.depense >= 20 then
        local regen = mesure.depense / (fin - mesure.debut)
        if regen >= 3 and regen <= 30 then   -- mesure plausible seulement
            ns.db.mesuresRegen = ns.db.mesuresRegen or {}
            local moi = ns.Data.Personnage()
            local liste = ns.db.mesuresRegen[moi] or {}
            liste[#liste + 1] = regen
            while #liste > MESURES_GARDEES do table.remove(liste, 1) end
            ns.db.mesuresRegen[moi] = liste
            if #liste == Capture.MESURES_MIN then
                Print(string.format("Régénération d'énergie mesurée : %.1f par seconde (la partition s'y adapte).",
                    Capture.RegenEnergie()))
            end
        end
    end
    mesure.debut, mesure.depense, mesure.sorts = nil, 0, 0
end

-- ---------------------------------------------------------------------
-- Points de combo (voleur) : LUS quand le jeu le permet (hors combat, au moins), sinon ESTIMÉS d'après le signal
-- de changement (UNIT_POWER_FREQUENT « COMBO_POINTS », lisible même si la valeur ne l'est pas) : un changement
-- juste après l'envoi d'un coup de grâce les remet à zéro, tout autre changement en ajoute un. Une attaque
-- esquivée n'en donne pas, et ne donne pas de signal : l'estimation reste juste.
-- Les points comptés pour juger un coup de grâce sont relevés à son ENVOI (UNIT_SPELLCAST_SENT), avant que sa
-- dépense ne les remette à zéro.
-- ---------------------------------------------------------------------
local TYPE_COMBO = 4   -- Enum.PowerType.ComboPoints
local comboEstime = 0
local finisseurEnvoye        -- GetTime() de l'envoi d'un coup de grâce, en attendant sa remise à zéro
local auFinisseur            -- { id, points, t } : points au dernier envoi d'un coup de grâce
local rolesCombo = {}        -- [id] = "finisseur" | "generateur" | false, et ajoutsCombo[id] = points ajoutés
local ajoutsCombo = {}

local function Description(id)
    for _, lire in ipairs({ C_Spell and C_Spell.GetSpellDescription, GetSpellDescription }) do
        if lire then
            local ok, t = pcall(lire, id)
            if ok and Lisible(t) and t ~= "" then return t end
        end
    end
end

-- Rôle d'un sort pour les points de combo : "finisseur", "generateur" (+ points ajoutés), ou nil.
function Capture.TypeCombo(id)
    id = Lisible(id)
    if not id then return nil end
    if rolesCombo[id] == nil then
        local texte = Description(id)
        if not texte then return nil end   -- pas encore chargée : on réessaiera
        local role, n = ns.Cycle.TypeCombo(texte)
        rolesCombo[id], ajoutsCombo[id] = role or false, n
    end
    return rolesCombo[id] or nil, ajoutsCombo[id]
end

function Capture.ComboMax()
    local ok, maximum = pcall(UnitPowerMax, "player", TYPE_COMBO)
    maximum = ok and Lisible(maximum)
    return (maximum and maximum > 0) and maximum or 5
end

-- Points de combo actuels (lus, ou estimés) ; second résultat : true s'ils ont été lus.
function Capture.PointsCombo()
    local ok, v = pcall(UnitPower, "player", TYPE_COMBO)
    v = ok and Lisible(v)
    if type(v) == "number" then
        comboEstime = v
        return v, true
    end
    return comboEstime, false
end

local function ChangementCombo()
    local _, lu = Capture.PointsCombo()
    if lu then return end
    if finisseurEnvoye and GetTime() - finisseurEnvoye < 1.5 then
        comboEstime, finisseurEnvoye = 0, nil
    else
        comboEstime = math.min(Capture.ComboMax(), comboEstime + 1)
    end
end

-- Coup esquivé, paré ou raté (2026-10-17) : le journal de combat est interdit, mais les points de combo sont
-- lisibles en combat (sonde du 2026-10-17). Un générateur réussi dont les points n'augmentent pas, ou un coup
-- de grâce dont les points ne retombent pas, n'a pas porté : étape « Esquivé ». Le jeu rend alors l'essentiel
-- du coût en énergie (80 % dans Classic, à vérifier). Invisible : un générateur lancé à points déjà pleins.
Capture.DELAI_ESQUIVE = 0.5
Capture.REMBOURSEMENT = 0.8
local envois = {}   -- [id] = points lus à l'envoi d'un sort à points de combo
local enVol         -- { id, guid, role, avant, t } : coup lancé, en attente de confirmation par les points

-- Envoi d'un sort (UNIT_SPELLCAST_SENT) : les points du moment sont retenus (coup de grâce : pour le jugement
-- de ses points ; tout sort à points de combo : pour repérer une esquive).
local function EnvoiSort(id)
    if not id then return end
    local role = Capture.TypeCombo(id)
    if not role then return end
    local points, lus = Capture.PointsCombo()
    envois[id] = lus and points or nil
    if role == "finisseur" then
        auFinisseur = { id = id, points = points, t = GetTime() }
        finisseurEnvoye = GetTime()
    end
end

-- Sort à points de combo réussi : à confirmer par les points (voir Capture.VerifierEsquive).
local function SurveillerCoup(id, guid)
    if not id or envois[id] == nil then return end
    enVol = { id = id, guid = guid, role = Capture.TypeCombo(id), avant = envois[id], t = GetTime() }
    envois[id] = nil
end

-- Points de combo d'un coup de grâce qui vient d'être lancé (relevés à son envoi), ou nil.
function Capture.PointsAuLancer(id)
    if auFinisseur and auFinisseur.id == id and GetTime() - auFinisseur.t < 3 then return auFinisseur.points end
    return nil
end

local surveillance = CreateFrame("Frame")
local ecouleMesure = 0
surveillance:SetScript("OnUpdate", function(_, dt)
    ecouleMesure = ecouleMesure + dt
    if ecouleMesure < 0.1 then return end
    ecouleMesure = 0
    if Capture.UtiliseEnergie() then Capture.PointsCombo() end   -- recalage de l'estimation quand c'est lisible
    Capture.VerifierEsquive()
    local pleine = Capture.EnergiePleine()
    if mesure.debut and pleine then FinMesure() end
    mesure.pleine = pleine
end)

-- Durée d'un DoT, lue dans la description du sort (« … en 18 sec »), ou nil. Gardée en cache une fois lue :
-- la description peut être vide tant que les données du sort ne sont pas chargées par le jeu.
local dureesDot = {}

function Capture.DureeDot(id)
    id = Lisible(id)
    if not id then return nil end
    if dureesDot[id] ~= nil then return dureesDot[id] or nil end
    local texte
    for _, lire in ipairs({ C_Spell and C_Spell.GetSpellDescription, GetSpellDescription }) do
        if lire and not texte then
            local ok, t = pcall(lire, id)
            if ok and Lisible(t) and t ~= "" then texte = t end
        end
    end
    if not texte then return nil end   -- pas encore chargée : on réessaiera
    local duree = ns.Cycle.DureeDot(texte)
    dureesDot[id] = duree or false
    return duree
end

-- Durée prévue (en secondes) de l'incantation ou de la canalisation en cours, d'après l'API.
local function DureeEnCours(fonction)
    if not fonction then return nil end
    local ok, _, _, _, debutMS, finMS = pcall(fonction, "player")
    debutMS, finMS = Lisible(debutMS), Lisible(finMS)
    if ok and debutMS and finMS then return (finMS - debutMS) / 1000 end
    return nil
end

local function Temps()
    local maintenant = GetTime()
    if not origine then origine = maintenant end
    return maintenant - origine
end

local function Cible(castGUID)
    local brut = castGUID and cibles[castGUID]
    if brut ~= nil and EstSecret(brut) then return "(masquée)" end
    if brut and brut ~= "" then return brut end
    local nom = UnitName("target")
    if nom == nil then return "aucune" end
    if EstSecret(nom) then return "(masquée)" end
    return nom
end

local COULEURS = {
    ["Début"]      = "ffffd100",
    ["Canal."]     = "ffcc99ff",
    ["Lancé"]      = "ff66ff66",
    ["Instant"]    = "ff66ccff",
    ["Interrompu"] = "ffff6666",
    ["Échec"]      = "ffff9966",
    ["Déplacement"] = "ffff9933",
    ["Esquivé"]    = "ffaaaaaa",
}

-- Incantation ou canalisation en cours : { guid, id, canal } (zone d'immobilité), nil sinon.
local incantation

local function Afficher(etape, spellID, castGUID, duree)
    if not (ns.db and ns.db.afficherSorts) then return end
    local texteDuree = duree and string.format(" · %.2f s", duree) or ""
    print(string.format("|cff888888[%6.2f]|r |c%s%s|r · %s (%s)%s · cible : %s",
        Temps(), COULEURS[etape] or "ffffffff", etape, NomSort(spellID), tostring(Lisible(spellID) or "secret"), texteDuree, Cible(castGUID)))
end

-- Affiche l'étape dans le chat et la transmet à la session en cours.
-- Étapes : "Début" (incantation), "Canal." (canalisation), "Lancé" (fin d'incantation réussie),
-- "Instant", "Interrompu", "Échec", "Déplacement" (le joueur bouge pendant une incantation ou canalisation).
local function Signaler(etape, spellID, castGUID, duree)
    Afficher(etape, spellID, castGUID, duree)
    if etape == "Instant" or etape == "Lancé" then
        NoterDepense(Lisible(spellID), GetTime())
        SurveillerCoup(Lisible(spellID), castGUID)
    elseif etape == "Esquivé" then
        -- Coût en grande partie rendu, invisible pour la mesure de régénération : segment abandonné.
        mesure.debut, mesure.depense, mesure.sorts = nil, 0, 0
    end
    if ns.Session then
        ns.Session.SurSort(etape, Lisible(spellID), castGUID, duree, GetTime(), castGUID and cibles[castGUID])
    end
    if ns.Guide then ns.Guide.SurSort(etape, Lisible(spellID), castGUID, duree, GetTime()) end
end

-- Coup en vol (appelé par la surveillance, toutes les 0,1 s) : confirmé par les points, ou esquivé au bout de
-- Capture.DELAI_ESQUIVE.
function Capture.VerifierEsquive()
    if not enVol then return end
    local points, lus = Capture.PointsCombo()
    if not lus then enVol = nil return end
    local c = enVol
    local porte = (c.role == "generateur" and points > c.avant) or (c.role == "finisseur" and points < c.avant)
    if porte then
        enVol = nil
    elseif GetTime() - c.t > Capture.DELAI_ESQUIVE then
        enVol = nil
        local visible = (c.role == "generateur" and c.avant < Capture.ComboMax()) or (c.role == "finisseur" and c.avant > 0)
        if visible then Signaler("Esquivé", c.id, c.guid) end
    end
end

-- Le joueur a-t-il perdu le contrôle (étourdi, apeuré, désarmé…) ? Partition en pause pendant ce temps.
function Capture.SousControle()
    if HasFullControl then
        local ok, v = pcall(HasFullControl)
        if ok and not EstSecret(v) and v == false then return true end
    end
    local perte = C_LossOfControl and C_LossOfControl.GetActiveLossOfControlDataCount
    if perte then
        local ok, n = pcall(perte)
        n = ok and Lisible(n)
        if type(n) == "number" and n > 0 then return true end
    end
    return false
end

local function FinIncantation(castGUID)
    if incantation and (castGUID == nil or incantation.guid == castGUID) then incantation = nil end
end

local function OnEvent(_, event, unite, ...)
    -- Gain d'énergie (la valeur est secrète, le signal non).
    if event == "UNIT_POWER_FREQUENT" then
        local typeRessource = select(1, ...)
        if unite == "player" and typeRessource == "ENERGY" then
            FinPeriodePleine(GetTime())
            dernierGainEnergie = GetTime()
        elseif unite == "player" and typeRessource == "COMBO_POINTS" then
            ChangementCombo()
        end
        return
    end
    -- Déplacement (événement sans unité) : lisible même en combat, contrairement à la vitesse (secrète).
    if event == "PLAYER_STARTED_MOVING" then
        if incantation then Signaler("Déplacement", incantation.id, incantation.guid) end
        return
    end
    if unite ~= "player" then return end
    if event == "UNIT_SPELLCAST_SENT" then
        local cible, castGUID, spellID = ...
        if castGUID then cibles[castGUID] = cible end
        if Capture.UtiliseEnergie() then EnvoiSort(Lisible(spellID)) end
    elseif event == "UNIT_SPELLCAST_START" then
        local castGUID, spellID = ...
        if castGUID then enCours[castGUID] = true end
        incantation = { guid = castGUID, id = spellID }
        Signaler("Début", spellID, castGUID, DureeEnCours(UnitCastingInfo))
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        local castGUID, spellID = ...
        if castGUID then enCours[castGUID] = true end
        incantation = { guid = castGUID, id = spellID, canal = true }
        Signaler("Canal.", spellID, castGUID, DureeEnCours(UnitChannelInfo))
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local castGUID, spellID = ...
        if castGUID and enCours[castGUID] then
            Signaler("Lancé", spellID, castGUID)
        else
            Signaler("Instant", spellID, castGUID)
        end
        -- Une canalisation continue après SUCCEEDED : sa zone d'immobilité finit à CHANNEL_STOP.
        if not (incantation and incantation.canal) then FinIncantation(castGUID) end
        if castGUID then enCours[castGUID] = nil cibles[castGUID] = nil end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        local castGUID, spellID = ...
        if castGUID and enCours[castGUID] then
            Signaler("Interrompu", spellID, castGUID)
            enCours[castGUID] = nil
        end
        FinIncantation(castGUID)
        if castGUID then cibles[castGUID] = nil end
    elseif event == "UNIT_SPELLCAST_FAILED" then
        -- Seulement pour une incantation déjà commencée : les échecs de spam (GCD, hors de portée) restent muets.
        local castGUID, spellID = ...
        if castGUID and enCours[castGUID] then
            Signaler("Échec", spellID, castGUID)
            enCours[castGUID] = nil
            FinIncantation(castGUID)
        end
        if castGUID then cibles[castGUID] = nil end
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local castGUID = ...
        FinIncantation(castGUID)
    end
end

local EVENEMENTS = {
    "UNIT_SPELLCAST_SENT",
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_POWER_FREQUENT",
}

local cadre

function Capture.Demarrer()
    if cadre then return end
    guidJoueur = UnitGUID("player")
    cadre = CreateFrame("Frame")
    cadre:SetScript("OnEvent", OnEvent)
    for _, e in ipairs(EVENEMENTS) do
        local ok, err
        if cadre.RegisterUnitEvent then
            ok, err = pcall(cadre.RegisterUnitEvent, cadre, e, "player")
        else
            ok, err = pcall(cadre.RegisterEvent, cadre, e)
        end
        if not ok then Print("Événement " .. e .. " indisponible (" .. tostring(err) .. ")") end
    end
    -- Événement sans unité : inscription classique.
    local ok, err = pcall(cadre.RegisterEvent, cadre, "PLAYER_STARTED_MOVING")
    if not ok then Print("Événement PLAYER_STARTED_MOVING indisponible (" .. tostring(err) .. ")") end
end

-- Incantation ou canalisation en cours (pour le HUD) : { guid, id, canal } ou nil.
function Capture.Incantation() return incantation end

-- ---------------------------------------------------------------------
-- Compteur de dégâts intégré (C_DamageMeter). Une session de compteur par combat.
-- Lisible hors combat seulement ; en combat, montants et identifiants sont secrets.
-- ---------------------------------------------------------------------
local guidJoueur

local function TypeSession(nom)
    return Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType[nom]
end

local function TypeDegats()
    return Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone
end

local function SessionsCompteur()
    if not (C_DamageMeter and C_DamageMeter.GetAvailableCombatSessions) then return {} end
    local ok, liste = pcall(C_DamageMeter.GetAvailableCombatSessions)
    if not ok or type(liste) ~= "table" or EstSecret(liste) then return {} end
    return liste
end

-- Plus grand identifiant de session de compteur existant (0 si aucun).
function Capture.DernierIdCompteur()
    local max = 0
    for _, s in ipairs(SessionsCompteur()) do
        local id = Lisible(s.sessionID)
        if id and id > max then max = id end
    end
    return max
end

-- Additionne les dégâts du joueur dans un résultat de GetCombatSessionSource*.
local function Cumuler(resultat, source)
    if type(source) ~= "table" or EstSecret(source) then return false end
    local total = Lisible(source.totalAmount)
    if not total then return false end
    resultat.total = resultat.total + total
    if type(source.combatSpells) == "table" then
        for _, sort in ipairs(source.combatSpells) do
            local id, montant = Lisible(sort.spellID), Lisible(sort.totalAmount)
            if id and montant then resultat.parSort[id] = (resultat.parSort[id] or 0) + montant end
        end
    end
    return true
end

-- Dégâts du joueur dans les sessions de compteur postérieures à idDepart. À appeler hors combat.
-- Retourne { total, duree (s, somme des combats), nbCombats, parSort = { [spellID] = dégâts }, erreur } ou nil.
function Capture.LireCompteur(idDepart)
    if not C_DamageMeter then return nil end
    local guid = UnitGUID("player")
    local resultat = { total = 0, duree = 0, nbCombats = 0, parSort = {} }
    local recentes = {}
    for _, s in ipairs(SessionsCompteur()) do
        local id = Lisible(s.sessionID)
        if id and id > idDepart then recentes[#recentes + 1] = s end
    end
    if #recentes == 0 then
        resultat.erreur = "aucun combat enregistré par le compteur"
        return resultat
    end
    -- Nom de l'ennemi de chaque combat : lisible hors combat, contrairement à UnitName("target").
    resultat.ennemis = {}
    for _, s in ipairs(recentes) do
        local nom = Lisible(s.name)
        if nom then resultat.ennemis[#resultat.ennemis + 1] = nom end
    end
    for _, s in ipairs(recentes) do
        local ok, source = pcall(C_DamageMeter.GetCombatSessionSourceFromID, s.sessionID, TypeDegats(), guid)
        if ok and Cumuler(resultat, source) then
            resultat.nbCombats = resultat.nbCombats + 1
            resultat.duree = resultat.duree + (Lisible(s.durationSeconds) or 0)
        elseif not ok then
            resultat.erreur = "GetCombatSessionSourceFromID : " .. tostring(source)
        end
    end
    -- Repli : un seul combat, c'est la session « en cours » du compteur.
    if resultat.nbCombats == 0 and #recentes == 1 then
        local ok, source = pcall(C_DamageMeter.GetCombatSessionSourceFromType, TypeSession("Current"), TypeDegats(), guid)
        if ok and Cumuler(resultat, source) then
            resultat.nbCombats = 1
            resultat.duree = Lisible(recentes[1].durationSeconds) or 0
            resultat.methode = "Current"
        end
    end
    return resultat
end

-- Dégâts du joueur dans le combat en cours, bruts : en combat c'est une valeur secrète,
-- utilisable seulement pour un affichage direct (FontString:SetText).
local traceDirect   -- le premier appel en combat est décrit dans SalleDuTempsDB.traceDirect

function Capture.DegatsEnDirect()
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionSourceFromType) then return nil end
    local guid = guidJoueur or UnitGUID("player")
    local ok, source = pcall(C_DamageMeter.GetCombatSessionSourceFromType, TypeSession("Current"), TypeDegats(), guid)
    local valeur
    if ok and type(source) == "table" and not EstSecret(source) then valeur = source.totalAmount end
    local enCombat = UnitAffectingCombat("player")
    if not traceDirect and (EstSecret(enCombat) or enCombat) then
        traceDirect = true
        ns.db.traceDirect = {
            date = date("%Y-%m-%d %H:%M:%S"),
            guidConnu = guid ~= nil,
            appelOk = ok,
            erreur = not ok and tostring(source) or nil,
            typeRetour = type(source),
            retourSecret = EstSecret(source),
            totalNil = valeur == nil,
            totalSecret = EstSecret(valeur),
        }
    end
    return valeur
end

-- ---------------------------------------------------------------------
-- Diagnostic (/sdt diag) : que permet l'API de la bêta pour mesurer les dégâts ?
-- Constaté le 2026-10-14 : s'inscrire à COMBAT_LOG_EVENT_UNFILTERED est une action réservée à l'interface
-- Blizzard (fenêtre « addon bloqué », non interceptable par pcall). Ne JAMAIS s'y inscrire.
-- Le diagnostic cherche donc les solutions de remplacement (compteur de dégâts intégré, etc.).
-- ---------------------------------------------------------------------
local function Oui(v) return v and "|cff66ff66oui|r" or "|cffff6666non|r" end

local function Cles(t)
    local cles = {}
    if type(t) == "table" then
        for k in pairs(t) do cles[#cles + 1] = tostring(k) end
        table.sort(cles)
    end
    return table.concat(cles, ", ")
end

function Capture.Diagnostic()
    Print("Diagnostic :")
    print("  issecretvalue existe : " .. Oui(issecretvalue))
    print("  C_DamageMeter existe : " .. Oui(C_DamageMeter))
    print("  CombatLogGetCurrentEventInfo existe : " .. Oui(CombatLogGetCurrentEventInfo))
    if UnitExists("target") then
        print("  PV / PV max de la cible secrets : " .. Oui(EstSecret(UnitHealth("target"))) .. " / " .. Oui(EstSecret(UnitHealthMax("target"))))
        print("  GUID de la cible secret : " .. Oui(EstSecret(UnitGUID("target"))))
    end
    print("  Mana du joueur secrète : " .. Oui(EstSecret(UnitPower("player"))))
    if C_DamageMeter then
        print("  Fonctions de C_DamageMeter : " .. Cles(C_DamageMeter))
    end
    if Enum and Enum.DamageMeterType then
        print("  Enum.DamageMeterType : " .. Cles(Enum.DamageMeterType))
    end
    -- Autres espaces de l'API qui pourraient servir à mesurer les dégâts.
    local pistes = {}
    for nom, valeur in pairs(_G) do
        if type(nom) == "string" and type(valeur) == "table" and nom:match("^C_")
            and (nom:find("Damage") or nom:find("Combat") or nom:find("Meter")) then
            pistes[#pistes + 1] = nom
        end
    end
    table.sort(pistes)
    print("  Espaces C_ liés au combat : " .. (#pistes > 0 and table.concat(pistes, ", ") or "aucun"))
end

-- ---------------------------------------------------------------------
-- Sonde du compteur de dégâts intégré (/sdt compteur).
-- Explore C_DamageMeter (signatures inconnues : chaque appel est protégé) et enregistre le résultat
-- dans SalleDuTempsDB.sonde, lisible hors du jeu dans WTF/Account/<compte>/SavedVariables/SalleDuTemps.lua.
-- ---------------------------------------------------------------------
local MAX_LIGNES = 400

local function Explorer(v, chemin, profondeur, lignes)
    if #lignes >= MAX_LIGNES then return end
    if EstSecret(v) then
        lignes[#lignes + 1] = chemin .. " = <secret " .. type(v) .. ">"
    elseif type(v) == "table" then
        if profondeur >= 4 then
            lignes[#lignes + 1] = chemin .. " = {...}"
            return
        end
        local vide = true
        for k, x in pairs(v) do
            vide = false
            local cle = EstSecret(k) and "<secret>" or tostring(k)
            Explorer(x, chemin .. "." .. cle, profondeur + 1, lignes)
        end
        if vide then lignes[#lignes + 1] = chemin .. " = {}" end
    else
        lignes[#lignes + 1] = chemin .. " = " .. tostring(v)
    end
end

local function Appeler(lignes, libelle, fonction, ...)
    if not fonction then
        lignes[#lignes + 1] = libelle .. " : fonction absente"
        return
    end
    local resultats = { pcall(fonction, ...) }
    if not resultats[1] then
        lignes[#lignes + 1] = libelle .. " : ERREUR " .. tostring(resultats[2])
        return
    end
    if #resultats == 1 then lignes[#lignes + 1] = libelle .. " : (aucun retour)" end
    for i = 2, #resultats do
        Explorer(resultats[i], libelle .. "[" .. (i - 1) .. "]", 0, lignes)
    end
end

function Capture.SondeCompteur()
    local lignes = {}
    lignes[#lignes + 1] = "En combat : " .. tostring(UnitAffectingCombat("player"))
    if not C_DamageMeter then
        lignes[#lignes + 1] = "C_DamageMeter absent"
    else
        local fonctions = {}
        for k in pairs(C_DamageMeter) do fonctions[#fonctions + 1] = tostring(k) end
        table.sort(fonctions)
        lignes[#lignes + 1] = "Fonctions : " .. table.concat(fonctions, ", ")

        -- Énumérations liées au compteur (types de session, types de mesure...).
        if Enum then
            for nom, valeurs in pairs(Enum) do
                if type(nom) == "string" and nom:find("DamageMeter") then
                    Explorer(valeurs, "Enum." .. nom, 0, lignes)
                end
            end
        end

        local DM = C_DamageMeter
        local typeDegats = Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone
        Appeler(lignes, "IsDamageMeterAvailable()", DM.IsDamageMeterAvailable)
        Appeler(lignes, "GetAvailableCombatSessions()", DM.GetAvailableCombatSessions)
        local typesSession = Enum and Enum.DamageMeterSessionType
        if typesSession then
            for nom, st in pairs(typesSession) do
                Appeler(lignes, "GetSessionDurationSeconds(" .. nom .. ")", DM.GetSessionDurationSeconds, st)
                Appeler(lignes, "GetCombatSessionFromType(" .. nom .. ", DamageDone)", DM.GetCombatSessionFromType, st, typeDegats)
                Appeler(lignes, "GetCombatSessionSourceFromType(" .. nom .. ", DamageDone, joueur)",
                    DM.GetCombatSessionSourceFromType, st, typeDegats, UnitGUID("player"))
            end
        else
            lignes[#lignes + 1] = "Enum.DamageMeterSessionType absent : appels par type ignorés"
        end
    end
    if #lignes >= MAX_LIGNES then lignes[#lignes + 1] = "... (tronqué)" end

    ns.db.sonde = ns.db.sonde or {}
    local cle = UnitAffectingCombat("player") and "enCombat" or "horsCombat"
    ns.db.sonde[cle] = { date = date("%Y-%m-%d %H:%M:%S"), lignes = lignes }
    Print(string.format("Sonde %s enregistrée (%d lignes). Elle sera écrite sur le disque au prochain /reload.",
        cle == "enCombat" and "en combat" or "hors combat", #lignes))
end

-- ---------------------------------------------------------------------
-- Sonde du jalon 6b (/sdt sonde) : déplacements et jauge de mana.
-- 1er appel : démarre (barre de mana de test affichée, échantillonnage de la vitesse, événements de
-- déplacement). 2e appel : arrête et enregistre le résultat dans SalleDuTempsDB.sonde6b.
-- ---------------------------------------------------------------------
local sonde

local function Resultat(ok, valeur)
    if not ok then return "erreur : " .. tostring(valeur) end
    if valeur == nil then return "nil" end
    if EstSecret(valeur) then return "secret" end
    return "lisible (" .. tostring(valeur) .. ")"
end

function Capture.Sonde()
    if not sonde then
        local r = { date = date("%Y-%m-%d %H:%M:%S"), echantillons = { horsCombat = {}, enCombat = {} }, evenements = {} }
        sonde = { r = r }
        -- Fonctions disponibles
        r.GetUnitSpeed = GetUnitSpeed and Resultat(pcall(GetUnitSpeed, "player")) or "absente"
        r.IsPlayerMoving = IsPlayerMoving and Resultat(pcall(IsPlayerMoving)) or "absente"
        r.UnitPowerPercent = UnitPowerPercent and Resultat(pcall(UnitPowerPercent, "player", 0)) or "absente"
        r.manaMax = Resultat(pcall(UnitPowerMax, "player", 0))
        r.mana = Resultat(pcall(UnitPower, "player", 0))
        -- Barre de mana de test : accepte-t-elle des valeurs secrètes ?
        local barre = CreateFrame("StatusBar", nil, UIParent)
        barre:SetSize(220, 16)
        barre:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
        barre:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        barre:SetStatusBarColor(0.2, 0.4, 1)
        local fond = barre:CreateTexture(nil, "BACKGROUND")
        fond:SetAllPoints()
        fond:SetColorTexture(0, 0, 0, 0.6)
        local titre = barre:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        titre:SetPoint("BOTTOM", barre, "TOP", 0, 2)
        titre:SetText("Salle du Temps - jauge de mana de test")
        sonde.barre = barre
        local function MajBarre()
            local okMax, errMax = pcall(barre.SetMinMaxValues, barre, 0, UnitPowerMax("player", 0))
            local okVal, errVal = pcall(barre.SetValue, barre, UnitPower("player", 0))
            r.barreMinMax = okMax and "acceptée" or ("refusée : " .. tostring(errMax))
            r.barreValeur = okVal and "acceptée" or ("refusée : " .. tostring(errVal))
        end
        MajBarre()
        -- Événements de déplacement
        local cadre = CreateFrame("Frame")
        for _, e in ipairs({ "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING" }) do
            local ok, err = pcall(cadre.RegisterEvent, cadre, e)
            r.evenements[e] = ok and 0 or ("inscription refusée : " .. tostring(err))
        end
        cadre:SetScript("OnEvent", function(_, e)
            if type(r.evenements[e]) == "number" then r.evenements[e] = r.evenements[e] + 1 end
        end)
        -- Échantillons de vitesse, hors combat et en combat
        local ecoule = 0
        cadre:SetScript("OnUpdate", function(_, dt)
            ecoule = ecoule + dt
            if ecoule < 0.25 then return end
            ecoule = 0
            MajBarre()
            local combat = UnitAffectingCombat("player")
            local cle = (EstSecret(combat) or combat) and "enCombat" or "horsCombat"
            local e = r.echantillons[cle]
            e.total = (e.total or 0) + 1
            local ok, v = pcall(GetUnitSpeed or function() return nil end, "player")
            if not ok or v == nil then
                e.illisible = (e.illisible or 0) + 1
            elseif EstSecret(v) then
                e.secret = (e.secret or 0) + 1
            elseif v > 0 then
                e.enMouvement = (e.enMouvement or 0) + 1
            else
                e.immobile = (e.immobile or 0) + 1
            end
        end)
        sonde.cadre = cadre
        Print("Sonde lancée. Une jauge de mana de test s'affiche en haut de l'écran : dis-moi si elle suit ta mana.")
        print("  Déplace-toi hors combat, puis en combat (bouge aussi pendant une incantation), puis retape /sdt sonde.")
        return
    end
    sonde.cadre:SetScript("OnUpdate", nil)
    sonde.cadre:UnregisterAllEvents()
    sonde.barre:Hide()
    ns.db.sonde6b = sonde.r
    local r = sonde.r
    sonde = nil
    Print("Sonde arrêtée et enregistrée (écrite sur le disque au prochain /reload).")
    print("  GetUnitSpeed : " .. r.GetUnitSpeed .. " · barre de mana : " .. tostring(r.barreValeur))
    for cle, e in pairs(r.echantillons) do
        print(string.format("  %s : %d échantillons, %d secrets, %d en mouvement, %d immobiles", cle,
            e.total or 0, e.secret or 0, e.enMouvement or 0, e.immobile or 0))
    end
    for e, n in pairs(r.evenements) do print("  " .. e .. " : " .. tostring(n)) end
end

-- ---------------------------------------------------------------------
-- Sonde du jalon 7 (/sdt sonde energie), à passer sur un voleur : énergie, points de combo, coûts des sorts,
-- rythme des gains d'énergie. 1er appel : démarre ; 2e appel : arrête et enregistre dans SalleDuTempsDB.sondeEnergie.
-- ---------------------------------------------------------------------
local sondeEnergie

local ENERGIE, COMBO = 3, 4   -- Enum.PowerType.Energy, Enum.PowerType.ComboPoints
local SORTS_VOLEUR = { 1752, 2098, 53, 1776, 5171 }   -- Attaque pernicieuse, Éviscération, Attaque sournoise, Suriner, Débiter

local function CoutEnergie(id)
    local lire = C_Spell and C_Spell.GetSpellPowerCost or GetSpellPowerCost
    if not lire then return "fonction absente" end
    local ok, couts = pcall(lire, id)
    if not ok then return "erreur : " .. tostring(couts) end
    if couts == nil then return "nil" end
    if EstSecret(couts) then return "secret" end
    if type(couts) ~= "table" then return tostring(couts) end
    local parties = {}
    for _, c in ipairs(couts) do
        parties[#parties + 1] = string.format("type %s : %s", Resultat(true, c.type), Resultat(true, c.cost))
    end
    return #parties > 0 and table.concat(parties, ", ") or "aucun coût"
end

function Capture.SondeEnergie()
    if not sondeEnergie then
        local r = { date = date("%Y-%m-%d %H:%M:%S"), classe = select(2, UnitClass("player")),
                    gains = { horsCombat = {}, enCombat = {} }, couts = {} }
        sondeEnergie = { r = r, dernier = nil }
        r.energie = Resultat(pcall(UnitPower, "player", ENERGIE))
        r.energieMax = Resultat(pcall(UnitPowerMax, "player", ENERGIE))
        r.comboUnitPower = Resultat(pcall(UnitPower, "player", COMBO))
        r.comboGetComboPoints = GetComboPoints and Resultat(pcall(GetComboPoints, "player", "target")) or "absente"
        r.typeRessource = Resultat(pcall(UnitPowerType, "player"))
        for _, id in ipairs(SORTS_VOLEUR) do r.couts[NomSort(id) .. " (" .. id .. ")"] = CoutEnergie(id) end
        -- Rôles pour les points de combo, lus dans les descriptions (2026-10-17).
        r.roles = {}
        local roles = {}
        for _, id in ipairs(SORTS_VOLEUR) do
            local role, n = Capture.TypeCombo(id)
            local texte = role == "finisseur" and "coup de grâce"
                or role == "generateur" and ("générateur +" .. tostring(n or 1)) or "aucun"
            r.roles[NomSort(id) .. " (" .. id .. ")"] = texte
            roles[#roles + 1] = NomSort(id) .. " : " .. texte
        end
        print("  Rôles (points de combo) : " .. table.concat(roles, " · "))
        r.signauxCombo = { horsCombat = 0, enCombat = 0, lusEnCombat = 0 }
        -- Temps de recharge global (sort 61304) : lisible ?
        if C_Spell and C_Spell.GetSpellCooldown then
            r.gcd = Resultat(pcall(C_Spell.GetSpellCooldown, 61304))
        elseif GetSpellCooldown then
            r.gcd = Resultat(pcall(GetSpellCooldown, 61304))
        end
        -- Jauge d'énergie de test (valeur secrète acceptée par une barre, comme la mana ?)
        local barre = CreateFrame("StatusBar", nil, UIParent)
        barre:SetSize(220, 16)
        barre:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
        barre:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        barre:SetStatusBarColor(1, 0.85, 0.1)
        local fond = barre:CreateTexture(nil, "BACKGROUND")
        fond:SetAllPoints()
        fond:SetColorTexture(0, 0, 0, 0.6)
        local titre = barre:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        titre:SetPoint("BOTTOM", barre, "TOP", 0, 2)
        titre:SetText("Salle du Temps - jauge d'énergie de test")
        sondeEnergie.barre = barre
        local function MajBarre()
            local okMax, errMax = pcall(barre.SetMinMaxValues, barre, 0, UnitPowerMax("player", ENERGIE))
            local okVal, errVal = pcall(barre.SetValue, barre, UnitPower("player", ENERGIE))
            r.barreMinMax = okMax and "acceptée" or ("refusée : " .. tostring(errMax))
            r.barreValeur = okVal and "acceptée" or ("refusée : " .. tostring(errVal))
        end
        MajBarre()
        -- Gains d'énergie : instants des événements UNIT_POWER_FREQUENT (énergie), hors combat et en combat.
        local cadre = CreateFrame("Frame")
        local ok, err = pcall(cadre.RegisterUnitEvent or cadre.RegisterEvent, cadre, "UNIT_POWER_FREQUENT", "player")
        r.evenementPuissance = ok and "inscrit" or ("refusé : " .. tostring(err))
        cadre:SetScript("OnEvent", function(_, _, unite, typePuissance)
            local combat = UnitAffectingCombat("player")
            if unite == "player" and typePuissance == "COMBO_POINTS" then
                -- Signal de changement des points de combo : reçu ? valeur lisible en combat ?
                local enCombat = EstSecret(combat) or combat
                local signaux = r.signauxCombo
                if enCombat then
                    signaux.enCombat = signaux.enCombat + 1
                    if Lisible(UnitPower("player", COMBO)) then signaux.lusEnCombat = signaux.lusEnCombat + 1 end
                else
                    signaux.horsCombat = signaux.horsCombat + 1
                end
                return
            end
            if unite ~= "player" or typePuissance ~= "ENERGY" then return end
            local liste = r.gains[(EstSecret(combat) or combat) and "enCombat" or "horsCombat"]
            if #liste < 60 then
                local maintenant = GetTime()
                liste[#liste + 1] = sondeEnergie.dernier and math.floor((maintenant - sondeEnergie.dernier) * 100 + 0.5) / 100 or 0
                sondeEnergie.dernier = maintenant
            end
            MajBarre()
        end)
        sondeEnergie.cadre = cadre
        Print("Sonde d'énergie lancée. Une jauge de test s'affiche en haut de l'écran : dis-moi si elle suit ton énergie.")
        print("  Attends quelques secondes hors combat (énergie pas pleine), puis combats ~30 s avec Attaque pernicieuse")
        print("  et Éviscération, puis retape /sdt sonde energie.")
        return
    end
    sondeEnergie.cadre:UnregisterAllEvents()
    sondeEnergie.barre:Hide()
    local r = sondeEnergie.r
    r.comboFin = Resultat(pcall(UnitPower, "player", COMBO))
    ns.db.sondeEnergie = r
    sondeEnergie = nil
    Print("Sonde d'énergie arrêtée et enregistrée (écrite sur le disque au prochain /reload).")
    print("  Énergie : " .. r.energie .. " · combo : " .. r.comboUnitPower .. " · barre : " .. tostring(r.barreValeur))
    print(string.format("  Gains d'énergie relevés : %d hors combat, %d en combat", #r.gains.horsCombat, #r.gains.enCombat))
    local signaux = r.signauxCombo or {}
    print(string.format("  Signaux de points de combo : %d hors combat, %d en combat (dont %d lisibles)",
        signaux.horsCombat or 0, signaux.enCombat or 0, signaux.lusEnCombat or 0))
end

-- ---------------------------------------------------------------------
-- Sonde de perte de contrôle (/sdt sonde controle, 2026-10-17) : la pause sur étourdissement ne s'est pas
-- déclenchée en jeu (HasFullControl et C_LossOfControl muets ou secrets ?). Relève ce que le jeu laisse voir :
-- fonctions, états échantillonnés (changements seulement), événements de perte de contrôle, auras néfastes du
-- joueur, messages d'erreur (« Vous êtes étourdi »). 1er appel : démarre ; 2e : enregistre dans
-- SalleDuTempsDB.sondeControle.
-- ---------------------------------------------------------------------
local sondeControle

local function Texte(v)
    if v == nil then return "nil" end
    if EstSecret(v) then return "secret" end
    return tostring(v)
end

local function DonneesPerte()
    local L = C_LossOfControl
    if not L then return "C_LossOfControl absente" end
    local lire = L.GetActiveLossOfControlData or (L.GetActiveLossOfControlDataByUnit
        and function(i) return L.GetActiveLossOfControlDataByUnit("player", i) end)
    if not lire then return "pas de fonction de données" end
    local ok, d = pcall(lire, 1)
    if not ok then return "erreur : " .. tostring(d) end
    if type(d) ~= "table" then return "données : " .. Texte(d) end
    local champs = {}
    for _, cle in ipairs({ "locType", "displayText", "timeRemaining", "duration", "startTime", "spellID" }) do
        champs[#champs + 1] = cle .. "=" .. Texte(d[cle])
    end
    return table.concat(champs, " ")
end

local function Debuffs()
    local noms = {}
    for i = 1, 10 do
        local nom
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HARMFUL")
            if not ok or a == nil then break end
            nom = EstSecret(a) and "secret" or Texte(a.name)
        elseif UnitDebuff then
            local ok, n = pcall(UnitDebuff, "player", i)
            if not ok or n == nil then break end
            nom = Texte(n)
        else
            return "pas de fonction d'auras"
        end
        noms[#noms + 1] = nom
    end
    return #noms > 0 and table.concat(noms, ",") or "aucun"
end

function Capture.SondeControle()
    if not sondeControle then
        local debut = GetTime()
        local r = { date = date("%Y-%m-%d %H:%M:%S"), fonctions = {}, inscriptions = {}, etats = {}, evenements = {} }
        r.fonctions.HasFullControl = HasFullControl and "présente" or "absente"
        local cles = {}
        for k in pairs(C_LossOfControl or {}) do cles[#cles + 1] = tostring(k) end
        table.sort(cles)
        r.fonctions.C_LossOfControl = C_LossOfControl and table.concat(cles, ", ") or "absente"
        r.fonctions.auras = (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) and "C_UnitAuras"
            or (UnitDebuff and "UnitDebuff" or "absente")
        local cadre = CreateFrame("Frame")
        for _, e in ipairs({ "LOSS_OF_CONTROL_ADDED", "LOSS_OF_CONTROL_UPDATE", "LOSS_OF_CONTROL_COMMIT",
                             "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED", "UI_ERROR_MESSAGE" }) do
            local ok, err = pcall(cadre.RegisterEvent, cadre, e)
            r.inscriptions[e] = ok and "inscrit" or ("refusé : " .. tostring(err))
        end
        cadre:SetScript("OnEvent", function(_, e, ...)
            if #r.evenements >= 80 then return end
            local args = {}
            for i = 1, select("#", ...) do args[i] = Texte((select(i, ...))) end
            local ligne = string.format("%.1f %s %s", GetTime() - debut, e, table.concat(args, " | "))
            if e:find("LOSS_OF_CONTROL", 1, true) then ligne = ligne .. " · " .. DonneesPerte() end
            r.evenements[#r.evenements + 1] = ligne
        end)
        local ecoule, dernier = 0, nil
        cadre:SetScript("OnUpdate", function(_, dt)
            ecoule = ecoule + dt
            if ecoule < 0.2 then return end
            ecoule = 0
            local combat = UnitAffectingCombat("player")
            local etat = string.format("combat=%s · HasFullControl=%s · pertes=%s · debuffs=%s",
                Texte(combat),
                HasFullControl and Resultat(pcall(HasFullControl)) or "absente",
                (C_LossOfControl and C_LossOfControl.GetActiveLossOfControlDataCount)
                    and Resultat(pcall(C_LossOfControl.GetActiveLossOfControlDataCount)) or "absente",
                Debuffs())
            if etat ~= dernier and #r.etats < 80 then
                r.etats[#r.etats + 1] = string.format("%.1f %s", GetTime() - debut, etat)
                dernier = etat
            end
        end)
        sondeControle = { r = r, cadre = cadre }
        Print("Sonde de perte de contrôle lancée : fais-toi étourdir par un monstre (deux ou trois fois si possible), "
            .. "puis retape /sdt sonde controle.")
        return
    end
    sondeControle.cadre:SetScript("OnUpdate", nil)
    sondeControle.cadre:UnregisterAllEvents()
    local r = sondeControle.r
    ns.db.sondeControle = r
    sondeControle = nil
    Print(string.format("Sonde de perte de contrôle enregistrée : %d états, %d événements (écrite au prochain /reload).",
        #r.etats, #r.evenements))
end

function Capture.RemettreAZero()
    origine = nil
    wipe(cibles)
    wipe(enCours)
end
