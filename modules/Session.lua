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

-- Session : session Training.
-- États : "inactif" → "attente" (premier sort sur la cible) → "enCours" (chrono) → "fin" (chrono écoulé,
-- attente de la sortie de combat pour lire le compteur de dégâts) → "inactif".
-- Garde-fous : avertissement si la cible n'est pas un mannequin ; annulation si le combat s'arrête avant la fin.

local _, ns = ...

local Session = {}
ns.Session = Session

local Print = function(msg) ns.Print(msg) end
local EstSecret, Lisible = ns.EstSecret, ns.Lisible

local NPC_MANNEQUIN = 5652
local NOM_MANNEQUIN = "mannequin d'entraînement"   -- comparé en minuscules, apostrophe droite

local function EstNomMannequin(nom)
    if not nom then return false end
    return string.lower((nom:gsub("’", "'"))) == NOM_MANNEQUIN
end
local DELAI_LECTURE = 1   -- s après la sortie de combat, le temps que le compteur clôture le combat

local etat = "inactif"
local s              -- session en préparation ou en cours (format : voir Data.lua)
local debut          -- GetTime() du premier sort
local idCompteur     -- dernier identifiant de session du compteur avant le départ
local combatVu       -- le joueur est entré en combat pendant la session
local parCast = {}   -- castGUID -> entrée de s.sorts
local cibleRetenue = {}   -- nom et GUID lisibles de la cible, relevés à sa sélection (PLAYER_TARGET_CHANGED)
local pleinDebut     -- Capture.TempsPlein() au départ (classe à énergie), nil sinon
-- Session d'amélioration (jalon 6a) : { uid, nom, notes, jeu (état de Partition), repetitions } ou nil.
local amelioration

function Session.Etat() return etat end

-- Comparaison par nom : un rang supérieur du même sort joue la même note.
function Session.MemeSort(a, b) return a == b or ns.Capture.NomSort(a) == ns.Capture.NomSort(b) end

-- Notes de partition tirées d'une session : sa version éditée, ou à défaut ouverture + cycle détecté,
-- répétés sur dureeTotale. Retourne notes, ou nil si la session n'a pas de cycle exploitable.
function Session.ConstruirePartition(ref, dureeTotale)
    local detecte = ns.Data.Cycle(ref)
    local ouverture, cycle
    -- Les DoT (reconnus d'après la description du sort) sont rejoués à leur expiration.
    if ref.cycleEdite then
        cycle = ns.Data.CompleterDots(ref.cycleEdite.etapes)
    elseif detecte then
        cycle = ns.Cycle.Etapes(detecte, ref.sorts, ns.Capture.DureeDot)
        ouverture = ns.Cycle.Etapes({ cycle = detecte.ouverture }, ref.sorts, ns.Capture.DureeDot)
    end
    if not cycle or #ns.Cycle.Actives(cycle) == 0 then return nil end
    local options = {
        dureeTotale = dureeTotale,
        dureeSerie = ns.Partition.DureeSerie(ref.sorts),
    }
    -- Classe à énergie (voleur) : coûts des sorts, énergie calculée, temps de recharge global d'une seconde.
    if ns.Capture.UtiliseEnergie() then
        -- Points de combo prévus : générateurs et coups de grâce reconnus d'après la description du sort.
        for _, liste in ipairs({ cycle, ouverture or {} }) do
            for _, e in ipairs(liste) do
                e.cout = ns.Capture.CoutEnergie(e.id)
                local role, n = ns.Capture.TypeCombo(e.id)
                e.finisseur = role == "finisseur" or nil
                e.genere = role == "generateur" and (n or 1) or nil
            end
        end
        local maximum = ns.Capture.EnergieMax()
        options.energie = { max = maximum, regen = ns.Capture.RegenEnergie(), depart = maximum }
        options.gcd = 1
        options.comboMax = ns.Capture.ComboMax()
    end
    return ns.Partition.Construire(ouverture, cycle, options)
end

-- Énergie pleine signalée par le jeu : recale l'énergie calculée d'une partition (une fois par passage à plein).
-- La régénération suit la dernière mesure (Capture.RegenEnergie), qui s'affine en jouant.
local etaitPleine = setmetatable({}, { __mode = "k" })   -- par partition en cours (clés faibles)
function Session.RecalerEnergie(jeu, t)
    if not jeu.en then return end
    jeu.en.regen = ns.Capture.RegenEnergie()
    local pleine = ns.Capture.EnergiePleine()
    if pleine and not etaitPleine[jeu] then ns.Partition.EnergiePleine(jeu, t) end
    etaitPleine[jeu] = pleine
end
function Session.Amelioration() return amelioration end

-- Coût en énergie et points de combo au lancer (coup de grâce) d'un sort joué, pour Partition.Jouer.
function Session.InfosEnergie(spellID)
    if not ns.Capture.UtiliseEnergie() then return nil, nil end
    return ns.Capture.CoutEnergie(spellID), ns.Capture.PointsAuLancer(spellID)
end

-- Énergie rendue par le jeu pour un coup esquivé, paré ou raté.
function Session.Rendu(spellID)
    if not ns.Capture.UtiliseEnergie() then return 0 end
    return ns.Capture.CoutEnergie(spellID) * ns.Capture.REMBOURSEMENT
end

-- Le temps passe pour une partition : en pause si le joueur a perdu le contrôle (étourdi…), puis notes non
-- jouées à temps. Retourne les verdicts.
function Session.FaireAvancer(jeu, t)
    Session.RecalerEnergie(jeu, t)
    if ns.Capture.SousControle() then ns.Partition.Pause(jeu, t) end
    return ns.Partition.Avancer(jeu, t)
end

-- Temps passé à énergie pleine depuis « depuis » (relevé de Capture.TempsPlein), arrondi au dixième ; nil
-- pour une classe sans énergie.
function Session.TempsPleinDepuis(depuis)
    if not depuis then return nil end
    return math.floor((ns.Capture.TempsPlein() - depuis) * 10 + 0.5) / 10
end

-- Temps écoulé depuis le premier sort (0 avant le départ).
function Session.Ecoule()
    if etat == "enCours" or etat == "fin" then return GetTime() - debut end
    return 0
end

local function UI(fonction, ...)
    if ns.UI and ns.UI[fonction] then ns.UI[fonction](...) end
end

local function EnCombat()
    local v = UnitAffectingCombat("player")
    if EstSecret(v) then return true end
    return v and true or false
end

local function Signal()
    local ok = SOUNDKIT and SOUNDKIT.READY_CHECK and pcall(PlaySound, SOUNDKIT.READY_CHECK, "Master")
    if not ok then pcall(PlaySound, 8960, "Master") end
end

-- Identifiant de PNJ tiré d'un GUID « Creature-0-xxxx-0-xxxx-NPCID-xxxx ».
local function NpcID(guid)
    if not guid then return nil end
    local genre, _, _, _, _, id = strsplit("-", guid)
    if genre ~= "Creature" and genre ~= "Vehicle" then return nil end
    return tonumber(id)
end

-- ---------------------------------------------------------------------
-- Préparation, départ, annulation
-- ---------------------------------------------------------------------
-- sansMemoriser : ne pas retenir ces réglages pour préremplir le panneau (sessions de test courtes).
-- reference (facultatif) : session d'amélioration { uid, nom, notes, repetitions }.
function Session.Preparer(reglages, sansMemoriser, reference)
    if etat ~= "inactif" then
        Print("Une session est déjà en cours (/sdt annuler pour l'arrêter).")
        return false
    end
    if not sansMemoriser then ns.Data.EnregistrerReglages(reglages) end
    s = {
        etiquette = reglages.etiquette or "",
        duree = reglages.duree,
        type = reglages.type,
        sorts = {},
        reference = reference and reference.uid,
        -- Copie figée de la référence : la comparaison reste possible si elle est remplacée ou supprimée.
        referenceNom = reference and reference.nom,
        referenceDps = reference and reference.dps,
    }
    amelioration = nil
    if ns.Guide then ns.Guide.Arreter() end   -- une session prend le pas sur le Guide
    if reference then
        amelioration = {
            uid = reference.uid,
            nom = reference.nom,
            notes = reference.notes,
            repetitions = reference.repetitions,
            jeu = ns.Partition.Nouvelle(reference.notes, Session.MemeSort),
        }
    end
    wipe(parCast)
    combatVu = false
    -- La cible a pu être choisie avant un /reload (pas de PLAYER_TARGET_CHANGED) : relevé ici aussi.
    local guid, nom = Lisible(UnitGUID("target")), Lisible(UnitName("target"))
    if guid then cibleRetenue.guid = guid end
    if nom then cibleRetenue.nom = nom end
    etat = "attente"
    UI("AfficherBarre")
    Print(string.format("Session de %d s prête : elle démarre au premier sort lancé sur la cible.", s.duree))
    return true
end

function Session.Annuler(raison)
    if etat == "inactif" then
        Print("Aucune session en cours.")
        return
    end
    ns.db.enAttente = nil
    etat = "inactif"
    s = nil
    amelioration = nil
    UI("MasquerBarre")
    Print("Session annulée" .. (raison and (" : " .. raison) or "") .. ".")
end

-- Prépare une session d'amélioration à partir de la session n° numero : partition fixe tirée de sa version
-- éditée (ou, à défaut, de son cycle détecté, précédé de l'ouverture). dureeForcee : sessions de test.
function Session.PreparerAmelioration(numero, dureeForcee)
    local ref = ns.Data.Sessions()[numero]
    if not ref then
        Print("Pas de session n° " .. tostring(numero) .. ".")
        return false
    end
    local duree = dureeForcee or ref.duree or 60
    local notes = Session.ConstruirePartition(ref, duree)
    if not notes then
        Print("Pas de cycle à améliorer pour cette session : modifie-la d'abord ou fais une session plus longue.")
        return false
    end
    -- Améliorer une amélioration : pas de « Amélioration · Amélioration · … ».
    local nom = ns.Data.Nom(ref, numero):gsub("^Amélioration · ", "")
    UI("ReinitialiserTouches")
    return Session.Preparer({ duree = duree, type = ref.type or "mono", etiquette = "Amélioration · " .. nom }, true,
        { uid = ref.uid, nom = nom, dps = ref.dps, notes = notes, repetitions = ns.Partition.Repetitions(notes, duree) })
end

-- Le temps passe : notes non jouées à temps (appelé par le HUD).
function Session.AvancerPartition()
    if etat ~= "enCours" or not amelioration then return end
    local verdicts = Session.FaireAvancer(amelioration.jeu, GetTime() - debut)
    if #verdicts > 0 then UI("Verdicts", verdicts) end
end

local function CibleValide()
    if not UnitExists("target") then return false end
    local attaquable = UnitCanAttack("player", "target")
    if EstSecret(attaquable) then return true end
    return attaquable and true or false
end

local function Demarrer(t)
    debut = t
    pleinDebut = ns.Capture.UtiliseEnergie() and ns.Capture.TempsPlein() or nil
    idCompteur = ns.Capture.DernierIdCompteur()
    combatVu = EnCombat()
    -- Combat déjà engagé au premier sort (voleur ou guerrier : attaque automatique d'abord) : la session de
    -- compteur de ce combat existe déjà, elle doit être lue aussi.
    if combatVu and idCompteur > 0 then idCompteur = idCompteur - 1 end
    -- En combat (voire dès l'incantation), nom et GUID de la cible peuvent être secrets :
    -- repli sur ceux relevés à la sélection de la cible.
    local guid = Lisible(UnitGUID("target")) or cibleRetenue.guid
    s.npcID = NpcID(guid)
    s.cible = Lisible(UnitName("target")) or cibleRetenue.nom or "?"
    -- Nom et GUID sont souvent secrets : le mannequin est alors reconnu à la fin, par le nom
    -- de l'ennemi que donne le compteur de dégâts (voir Finaliser).
    local cibleConnue = s.npcID ~= nil or s.cible ~= "?"
    s.mannequin = s.npcID == NPC_MANNEQUIN or EstNomMannequin(s.cible)
    s.classe = select(2, UnitClass("player"))
    s.personnage = ns.Data.Personnage()
    s.niveau = UnitLevel("player")
    s.date = date("%Y-%m-%d %H:%M")
    s.horodatage = time()
    etat = "enCours"
    Print(string.format("Chrono lancé : %d s.", s.duree))
    if cibleConnue and not s.mannequin then
        Print(string.format("|cffff9933Attention|r : %s n'est pas un mannequin d'entraînement, le DPS sera peu comparable. "
            .. "La session sera annulée si le combat s'arrête avant la fin. (/sdt annuler pour arrêter)", s.cible))
    end
end

-- ---------------------------------------------------------------------
-- Sorts (appelé par Capture pour chaque étape d'un sort du joueur)
-- ---------------------------------------------------------------------
local function Enregistrer(etape, spellID, castGUID, duree, t)
    local rel = t - debut
    if etape == "Début" or etape == "Canal." then
        local e = { t = rel, id = spellID, d = duree or 0, k = etape == "Début" and "cast" or "canal" }
        s.sorts[#s.sorts + 1] = e
        if castGUID then parCast[castGUID] = e end
        -- Une canalisation est comptée lancée dès son début (SUCCEEDED n'est pas garanti).
        if etape == "Canal." then e.ok = true end
    elseif etape == "Lancé" then
        local e = castGUID and parCast[castGUID]
        if e then e.ok = true parCast[castGUID] = nil end
    elseif etape == "Instant" then
        s.sorts[#s.sorts + 1] = { t = rel, id = spellID, d = 0, k = "instant", ok = true }
    elseif etape == "Interrompu" or etape == "Échec" then
        local e = castGUID and parCast[castGUID]
        if e then e.ok = false e.fin = rel parCast[castGUID] = nil end
    elseif etape == "Déplacement" then
        -- Bougé pendant l'incantation : noté (l'interruption suit en général pour une incantation).
        local e = castGUID and parCast[castGUID]
        if e then e.deplacement = rel end
    elseif etape == "Esquivé" then
        -- Coup qui n'a pas porté : le dernier lancer de ce sort est marqué.
        for k = #s.sorts, 1, -1 do
            if s.sorts[k].id == spellID then s.sorts[k].esquive = true break end
        end
    end
end

-- Le sort vise-t-il la cible ? cibleSort : nom donné par UNIT_SPELLCAST_SENT (peut être vide ou secret,
-- auquel cas on ne peut pas trancher et le sort est accepté).
local function VisePasLaCible(cibleSort)
    if cibleSort == nil or EstSecret(cibleSort) or cibleSort == "" then return false end
    if cibleSort == UnitName("player") then return true end
    return cibleRetenue.nom ~= nil and cibleSort ~= cibleRetenue.nom
end

function Session.SurSort(etape, spellID, castGUID, duree, t, cibleSort)
    if etat == "attente" then
        if etape ~= "Début" and etape ~= "Canal." and etape ~= "Instant" then return end
        if not CibleValide() then
            Print("Sort ignoré pour le départ : pas de cible attaquable.")
            return
        end
        if VisePasLaCible(cibleSort) then
            Print("Sort ignoré pour le départ : lancé sur " .. cibleSort .. ", pas sur la cible.")
            return
        end
        local ok, err = pcall(Demarrer, t)
        if not ok then
            Print("Départ de la session : erreur (" .. tostring(err) .. ")")
            Session.Annuler("erreur au départ")
            return
        end
    end
    if etat == "enCours" then
        Enregistrer(etape, spellID, castGUID, duree, t)
        -- Session d'amélioration : chaque début de sort est jugé contre la partition.
        if amelioration and spellID and (etape == "Début" or etape == "Canal." or etape == "Instant") then
            local cout, combo = Session.InfosEnergie(spellID)
            local verdicts = ns.Partition.Jouer(amelioration.jeu, spellID, t - debut, duree, cout, combo)
            if #verdicts > 0 then UI("Verdicts", verdicts) end
        elseif amelioration and spellID and etape == "Esquivé" then
            -- Coup qui n'a pas porté : pas de faute, la note est à rejouer, l'énergie en partie rendue.
            local verdicts = ns.Partition.Esquiver(amelioration.jeu, spellID, t - debut, Session.Rendu(spellID))
            if #verdicts > 0 then UI("Verdicts", verdicts) end
        elseif amelioration and spellID and (etape == "Déplacement" or etape == "Interrompu" or etape == "Échec") then
            -- Zone d'immobilité non tenue : la note jouée devient « interrompue » et doit être rejouée.
            local verdicts = ns.Partition.Interrompre(amelioration.jeu, spellID, t - debut)
            if #verdicts > 0 then UI("Verdicts", verdicts) end
        end
    end
end

-- ---------------------------------------------------------------------
-- Fin : chrono écoulé, puis lecture du compteur à la sortie de combat
-- ---------------------------------------------------------------------
local function Pourcent(x) return string.format("%d %%", math.floor(x * 100 + 0.5)) end

local function Resume(numero)
    local lances, interrompus = 0, 0
    local noms = {}
    for _, e in ipairs(s.sorts) do
        if e.ok then
            lances = lances + 1
            noms[#noms + 1] = ns.Capture.NomSort(e.id)
        elseif e.ok == false then
            interrompus = interrompus + 1
        end
    end
    Print(string.format("|cff66ff66Session terminée|r%s · %s · %s%s.",
        s.etiquette ~= "" and (" « " .. s.etiquette .. " »") or "", ns.Data.DureeTexte(s),
        s.cible, s.mannequin and "" or " (pas un mannequin)"))
    if s.dps then
        print(string.format("  |cffffd100%.1f DPS|r : %d dégâts en %d s de combat%s.", s.dps, s.degats, s.dureeCombat,
            s.nbCombats > 1 and string.format(" (%d combats)", s.nbCombats) or ""))
    else
        print("  DPS indisponible : " .. tostring(s.erreurCompteur or "compteur illisible"))
    end
    print(string.format("  Sorts lancés : %d%s.", lances, interrompus > 0 and string.format(" (+ %d interrompus)", interrompus) or ""))
    print("  Séquence : " .. table.concat(noms, " · "))
    if s.parSort and s.degats and s.degats > 0 then
        local liste = {}
        for id, montant in pairs(s.parSort) do liste[#liste + 1] = { id = id, montant = montant } end
        table.sort(liste, function(a, b) return a.montant > b.montant end)
        local parties = {}
        for _, x in ipairs(liste) do
            parties[#parties + 1] = string.format("%s %s (%d)", ns.Capture.NomSort(x.id), Pourcent(x.montant / s.degats), x.montant)
        end
        print("  Dégâts par sort : " .. table.concat(parties, ", "))
    end
    if s.manaFin then print("  Mana en fin de session : " .. Pourcent(s.manaFin)) end
    if s.energiePleine then
        print(string.format("  Énergie pleine pendant %.1f s (environ %d d'énergie perdue).", s.energiePleine,
            math.floor(s.energiePleine * ns.Capture.RegenEnergie() + 0.5)))
    end
    local j = s.jugement
    if j then
        print(string.format("  Rythme : précision %s · %d parfait, %d bien, %d juste, %d raté, %d interrompu · combo max %d%s.",
            j.precision and Pourcent(j.precision) or "-", j.compte.parfait, j.compte.bien, j.compte.juste,
            j.compte.rate, j.compte.interrompu or 0, j.comboMax,
            (j.compte.hors > 0 and string.format(" · %d hors partition", j.compte.hors) or "")
            .. ((j.compte.esquive or 0) > 0 and string.format(" · %d esquivé%s (rejoué%s)", j.compte.esquive,
                j.compte.esquive > 1 and "s" or "", j.compte.esquive > 1 and "s" or "") or "")))
    end
    print(string.format("  Session enregistrée (n° %d).", numero))
end

local function Finaliser()
    if etat ~= "fin" then return end
    local r = ns.Capture.LireCompteur(idCompteur)
    if r and r.nbCombats > 0 and r.duree > 0 then
        s.degats, s.dureeCombat, s.nbCombats, s.parSort = r.total, r.duree, r.nbCombats, r.parSort
        s.dps = r.total / r.duree
    end
    if r then s.erreurCompteur = r.erreur else s.erreurCompteur = "C_DamageMeter absent" end
    if r and r.ennemis and #r.ennemis > 0 then
        if s.cible == "?" then s.cible = table.concat(r.ennemis, ", ") end
        for _, nom in ipairs(r.ennemis) do
            if EstNomMannequin(nom) then s.mannequin = true end
        end
    end
    -- Mana (ressource 0) : secrète en combat, peut-être lisible maintenant.
    local mana, manaMax = Lisible(UnitPower("player", 0)), Lisible(UnitPowerMax("player", 0))
    if mana and manaMax and manaMax > 0 then s.manaFin = mana / manaMax end
    local numero = ns.Data.AjouterSession(s)
    ns.db.enAttente = nil
    local ok, err = pcall(Resume, numero)
    if not ok then Print("Résumé : erreur (" .. tostring(err) .. ")") end
    etat = "inactif"
    s = nil
    amelioration = nil
    UI("MasquerBarre")
    local okP, errP = pcall(UI, "OuvrirCycle", numero)
    if not okP then Print("Page Cycle : erreur (" .. tostring(errP) .. ")") end
    pcall(UI, "RafraichirJournal")
end

-- Fige le bilan du rythme (session d'amélioration) dans la session.
local function FigerJugement()
    if not amelioration then return end
    local jeu = amelioration.jeu
    s.jugement = {
        compte = ns.Data.Copie(jeu.compte),
        precision = ns.Partition.Precision(jeu),
        comboMax = jeu.comboMax,
        notesJouees = jeu.i - 1,
        erreurs = ns.Data.Copie(jeu.erreurs),   -- par sort, pour le Coach
    }
end

local function FinChrono()
    etat = "fin"
    s.energiePleine = Session.TempsPleinDepuis(pleinDebut)
    FigerJugement()
    -- Gardée dans la sauvegarde : un /reload avant la sortie de combat ne la perd pas (voir Session.Reprendre).
    ns.db.enAttente = { session = s, idCompteur = idCompteur }
    Signal()
    if EnCombat() then
        Print("Temps écoulé : arrête d'attaquer, le résultat s'affichera à la sortie de combat.")
        UI("BarreFin")
    else
        C_Timer.After(DELAI_LECTURE, Finaliser)
    end
end

-- Combat terminé avant la fin du chrono (monstre mort) : le joueur choisit d'enregistrer la session
-- écourtée ou de l'abandonner (fenêtre de confirmation, ui/Session.lua).
local function CombatEcourte()
    etat = "decision"
    s.ecourtee = true
    s.dureeJouee = math.floor(GetTime() - debut + 0.5)
    s.energiePleine = Session.TempsPleinDepuis(pleinDebut)
    FigerJugement()
    UI("DemanderEcourtee", s.dureeJouee, s.duree)
end

function Session.EnregistrerEcourtee()
    if etat ~= "decision" then return end
    etat = "fin"
    ns.db.enAttente = { session = s, idCompteur = idCompteur }
    Print(string.format("Session écourtée enregistrée (%d s sur %d).", s.dureeJouee or 0, s.duree or 0))
    C_Timer.After(DELAI_LECTURE, Finaliser)
end

-- Au chargement : finalise une session dont le chrono était fini avant un /reload.
function Session.Reprendre()
    local attente = ns.db.enAttente
    if not (attente and attente.session) then return end
    s, idCompteur = attente.session, attente.idCompteur or 0
    etat = "fin"
    Print("Session terminée avant le rechargement : résultat à la sortie de combat.")
    if EnCombat() then
        UI("AfficherBarre")
    else
        C_Timer.After(DELAI_LECTURE, Finaliser)
    end
end

-- Temps restant (s) de la session en cours, ou nil.
function Session.Restant()
    if etat ~= "enCours" then return nil end
    return math.max(0, s.duree - (GetTime() - debut))
end

-- ---------------------------------------------------------------------
-- Événements : chrono et combat
-- ---------------------------------------------------------------------
local cadre = CreateFrame("Frame")
cadre:RegisterEvent("PLAYER_REGEN_DISABLED")
cadre:RegisterEvent("PLAYER_REGEN_ENABLED")
cadre:RegisterEvent("PLAYER_TARGET_CHANGED")
cadre:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_TARGET_CHANGED" then
        cibleRetenue.guid = Lisible(UnitGUID("target"))
        cibleRetenue.nom = Lisible(UnitName("target"))
    elseif event == "PLAYER_REGEN_DISABLED" then
        if etat == "enCours" then combatVu = true end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if etat == "enCours" and combatVu then
            CombatEcourte()
        elseif etat == "fin" then
            C_Timer.After(DELAI_LECTURE, Finaliser)
        end
    end
end)
cadre:SetScript("OnUpdate", function()
    if etat == "enCours" and GetTime() - debut >= s.duree then FinChrono() end
end)
