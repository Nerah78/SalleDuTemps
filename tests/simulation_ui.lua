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

-- Simulation de l'interface hors du jeu : imite le minimum de l'API WoW (cadres « factices » qui
-- acceptent toutes les méthodes), charge l'addon dans l'ordre du .toc, puis ouvre chaque fenêtre.
-- Ne vérifie pas l'apparence : attrape les erreurs d'exécution (variable mal nommée, nil indexé...).
-- Usage : lua tests/simulation_ui.lua [chemin de SalleDuTemps.lua (sauvegarde réelle)]

local dossier = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local racine = dossier .. "/.."

-- ---------------------------------------------------------------------
-- Cadres factices
-- ---------------------------------------------------------------------
local cadres = {}
local Objet

local RETOURS = {
    GetText = function() return "" end,
    GetChecked = function() return false end,
    IsShown = function(self) return self._visible end,
    IsVisible = function(self) return self._visible end,
    Show = function(self) self._visible = true if self._scripts.OnShow then self._scripts.OnShow(self) end end,
    Hide = function(self)
        local etait = self._visible
        self._visible = false
        if etait and self._scripts.OnHide then self._scripts.OnHide(self) end
    end,
    SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
    GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
    GetFontString = function() return Objet() end,
    CreateTexture = function() return Objet() end,
    CreateFontString = function() return Objet() end,
    GetVerticalScrollRange = function() return 0 end,
    GetVerticalScroll = function() return 0 end,
    IsMouseOver = function() return false end,
    GetWidth = function() return 100 end,
    GetHeight = function() return 100 end,
    GetCenter = function() return 0, 0 end,
    GetEffectiveScale = function() return 1 end,
    GetStringWidth = function() return 50 end,
    GetFrameLevel = function() return 1 end,
    CreateLine = function() return Objet() end,
    SetScript = function(self, nom, f) self._scripts[nom] = f end,
    GetScript = function(self, nom) return self._scripts[nom] end,
    RegisterEvent = function(self, e) self._evenements[e] = true end,
    RegisterUnitEvent = function(self, e) self._evenements[e] = true end,
    GetParent = function(self) return self._parent end,
}

-- Champs (et non méthodes) que l'addon teste et qui sont absents ici : nil, comme dans le jeu sans modèle.
local CHAMPS = { TitleText = true, TitleContainer = true, editBox = true, EditBox = true, ScrollBar = true,
                 CloseButton = true }

Objet = function(parent)
    local o = { _scripts = {}, _evenements = {}, _visible = true, _parent = parent }
    return setmetatable(o, {
        __index = function(_, cle)
            if RETOURS[cle] then return RETOURS[cle] end
            if CHAMPS[cle] then return nil end
            -- Méthodes de l'API : majuscule initiale. Champs de l'addon (titre, contenu...) : minuscule, nil.
            if type(cle) ~= "string" or not cle:match("^%u") then return nil end
            return function() return nil end   -- toute autre méthode : sans effet
        end,
    })
end

function CreateFrame(_, nom, parent)
    local o = Objet(parent)
    cadres[#cadres + 1] = o
    if nom then _G[nom] = o end
    return o
end

-- ---------------------------------------------------------------------
-- API WoW imitée (le strict nécessaire)
-- ---------------------------------------------------------------------
UIParent, Minimap, GameTooltip = Objet(), Objet(), Objet()
UISpecialFrames, StaticPopupDialogs, SlashCmdList = {}, {}, {}
local dernierPopup
function StaticPopup_Show(nom) dernierPopup = nom end
C_Timer = { After = function(_, f) f() end }
local horloge = 1000
function GetTime() horloge = horloge + 0.1 return horloge end
function GetCursorPosition() return 0, 0 end
function GetBuildInfo() return "1.60.1", "70009", "", 16001 end
function strtrim(s) return (s or ""):match("^%s*(.-)%s*$") end
function strsplit(sep, s)
    local res = {}
    for morceau in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do res[#res + 1] = morceau end
    return table.unpack(res)
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function GetSpellInfo(id) return "Sort " .. tostring(id), nil, 136243, 1500 end
function GetSpellTexture() return 136243 end
-- Descriptions : Douleur (970) et Peste dévorante (2944) sont des DoT, comme en jeu.
local DESCRIPTIONS = {
    [970] = "Une douleur intense inflige 66 points de dégâts d'Ombre en 18 sec.",
    [2944] = "Afflige la cible d'une maladie qui inflige 152 points de dégâts d'Ombre en 24 sec.",
}
function GetSpellDescription(id) return DESCRIPTIONS[id] or "Inflige 50 points de dégâts." end
function GetCursorInfo() return nil end
function ClearCursor() end
function GetActionInfo() return nil end
function GetBindingKey() return nil end
function PlaySound() end
SOUNDKIT = { READY_CHECK = 8960 }
function UnitGUID(u) return u == "player" and "Player-1-0001" or nil end
function UnitName(u) return u == "player" and "Joueur" or nil end
function UnitClass() return "Prêtre", "PRIEST" end
function GetRealmName() return "Royaume" end
function UnitLevel() return 25 end
function UnitExists() return false end
function UnitCanAttack() return false end
function UnitAffectingCombat() return false end
function UnitPower() return 0 end
function UnitPowerMax() return 0 end
function UnitPowerType() return 0 end
function UnitCastingInfo() return nil end
function UnitChannelInfo() return nil end
Enum = {
    DamageMeterSessionType = { Overall = 0, Current = 1, Expired = 2 },
    DamageMeterType = { DamageDone = 0, Dps = 1 },
}
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
date, time = os.date, os.time   -- globales dans WoW

-- Les erreurs interceptées par l'addon (pcall) sont affichées « … erreur (…) » : on les compte aussi.
local erreursAffichees = 0
local printOriginal = print
function print(...)
    local texte = table.concat({ ... }, " ")
    if texte:find("erreur %(") then
        erreursAffichees = erreursAffichees + 1
        printOriginal("ERREUR AFFICHÉE PAR L'ADDON : " .. texte)
    end
    printOriginal(...)
end

-- ---------------------------------------------------------------------
-- Chargement de l'addon (ordre du .toc) et de la sauvegarde
-- ---------------------------------------------------------------------
local erreurs = 0
local function Essayer(nom, f, ...)
    local ok, err = xpcall(f, debug.traceback, ...)
    if ok then
        print("ok      " .. nom)
    else
        erreurs = erreurs + 1
        print("ERREUR  " .. nom .. "\n" .. tostring(err))
    end
end

if arg[1] then
    dofile(arg[1])   -- définit SalleDuTempsDB
else
    SalleDuTempsDB = { sessions = {} }
end
local nbSessions = #(SalleDuTempsDB.sessions or {})

local ns = {}
for ligne in io.lines(racine .. "/SalleDuTemps.toc") do
    local fichier = ligne:match("^%s*([^#%s].-%.lua)%s*$")
    if fichier then
        fichier = fichier:gsub("\\", "/")
        Essayer("chargement " .. fichier, function()
            local morceau = assert(loadfile(racine .. "/" .. fichier))
            morceau("SalleDuTemps", ns)
        end)
    end
end

local function Evenement(nom, ...)
    for _, c in ipairs(cadres) do
        if c._evenements[nom] and c._scripts.OnEvent then c._scripts.OnEvent(c, nom, ...) end
    end
end
Essayer("ADDON_LOADED", Evenement, "ADDON_LOADED", "SalleDuTemps")
Essayer("PLAYER_LOGIN", Evenement, "PLAYER_LOGIN")

-- ---------------------------------------------------------------------
-- Scénarios
-- ---------------------------------------------------------------------
local UI = ns.UI
Essayer("commande /sdt aide", SlashCmdList.SALLEDUTEMPS, "aide")
Essayer("journal : ouverture", UI.BasculerJournal)
for _, tri in ipairs({ "dps", "fiabilite", "date" }) do
    Essayer("journal : tri " .. tri, function()
        -- Les boutons de tri sont des cadres factices : on rafraîchit directement.
        UI.RafraichirJournal()
    end)
end
for i = 1, nbSessions do
    Essayer("page Cycle n° " .. i, UI.OuvrirCycle, i)
    Essayer("mode Édition n° " .. i, UI.ModeEdition)
    Essayer("retour Consultation n° " .. i, UI.ModeConsultation)
    Essayer("éditeur depuis le journal n° " .. i, UI.OuvrirEditeur, i)
end
if nbSessions == 0 then Essayer("page Cycle sans session", UI.OuvrirCycle) end
Essayer("panneau de session", UI.BasculerPanneau)

-- Session d'amélioration : préparation, sorts lancés sur une cible, défilement du HUD, annulation.
local function TousLesOnUpdate()
    for _, c in ipairs(cadres) do
        if c._scripts.OnUpdate then c._scripts.OnUpdate(c, 0.05) end
    end
end
for i = 1, nbSessions do
    local s = SalleDuTempsDB.sessions[i]
    Essayer("amélioration n° " .. i, function()
        if ns.Session.Etat() ~= "inactif" then ns.Session.Annuler("scénario précédent interrompu") end
        local prete = ns.Session.PreparerAmelioration(i, 20)
        if not prete then return end   -- pas de cycle : refus attendu
        UI.MajHUD()
        UnitExists, UnitCanAttack = function() return true end, function() return true end
        for k, e in ipairs(s.sorts or {}) do
            if k > 12 then break end
            if e.ok and e.id then
                local evenement = (e.d or 0) > 0 and "UNIT_SPELLCAST_START" or "UNIT_SPELLCAST_SUCCEEDED"
                Evenement(evenement, "player", "Cast-" .. k, e.id)
                TousLesOnUpdate()
            end
        end
        UnitExists, UnitCanAttack = function() return false end, function() return false end
        ns.Session.Annuler("fin de la simulation")
    end)
end

-- Session d'amélioration menée jusqu'au bout (fin du chrono, résumé avec le rythme, page Cycle).
if nbSessions > 0 then
    Essayer("amélioration jusqu'à la fin", function()
        if ns.Session.Etat() ~= "inactif" then ns.Session.Annuler("scénario précédent interrompu") end
        if not ns.Session.PreparerAmelioration(nbSessions, 5) then return end
        UnitExists, UnitCanAttack = function() return true end, function() return true end
        local premier = ns.Session.Amelioration().notes[1]
        Evenement("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-fin", premier.id)
        UnitExists, UnitCanAttack = function() return false end, function() return false end
        for _ = 1, 200 do
            TousLesOnUpdate()
            if ns.Session.Etat() == "inactif" then break end
        end
        assert(ns.Session.Etat() == "inactif", "la session n'est pas terminée (état " .. ns.Session.Etat() .. ")")
        local derniere = SalleDuTempsDB.sessions[#SalleDuTempsDB.sessions]
        assert(derniere.jugement and derniere.reference, "jugement ou référence absent de la session enregistrée")
    end)
end
Essayer("commande /sdt sessions", SlashCmdList.SALLEDUTEMPS, "sessions")

erreurs = erreurs + erreursAffichees
-- Combat terminé avant la fin du chrono : fenêtre de choix, puis enregistrement ou abandon.
if nbSessions > 0 then
    for _, choix in ipairs({ "OnAccept", "OnCancel" }) do
        Essayer("session écourtée : " .. choix, function()
            if ns.Session.Etat() ~= "inactif" then ns.Session.Annuler("scénario précédent interrompu") end
            local avant = #SalleDuTempsDB.sessions
            assert(ns.Session.PreparerAmelioration(nbSessions, 30), "préparation refusée")
            UnitExists, UnitCanAttack = function() return true end, function() return true end
            Evenement("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-ec", ns.Session.Amelioration().notes[1].id)
            UnitExists, UnitCanAttack = function() return false end, function() return false end
            Evenement("PLAYER_REGEN_DISABLED")
            TousLesOnUpdate()
            dernierPopup = nil
            Evenement("PLAYER_REGEN_ENABLED")
            assert(ns.Session.Etat() == "decision", "état attendu : decision, obtenu " .. ns.Session.Etat())
            assert(dernierPopup == "SALLEDUTEMPS_ECOURTEE", "fenêtre de choix non affichée")
            UI.MajHUD()
            StaticPopupDialogs.SALLEDUTEMPS_ECOURTEE[choix]()
            for _ = 1, 20 do TousLesOnUpdate() end
            assert(ns.Session.Etat() == "inactif", "session non terminée")
            local apres = #SalleDuTempsDB.sessions
            if choix == "OnAccept" then
                assert(apres == avant + 1 and SalleDuTempsDB.sessions[apres].ecourtee, "session écourtée non enregistrée")
            else
                assert(apres == avant, "session abandonnée enregistrée quand même")
            end
        end)
    end
end

-- Interruption : incantation commencée, déplacement puis interruption → un seul verdict « interrompu ».
if nbSessions > 0 then
    Essayer("interruption pendant une incantation", function()
        if ns.Session.Etat() ~= "inactif" then ns.Session.Annuler("scénario précédent interrompu") end
        assert(ns.Session.PreparerAmelioration(nbSessions, 30), "préparation refusée")
        local notes = ns.Session.Amelioration().notes
        local cible
        for _, n in ipairs(notes) do
            if n.type == "cast" then cible = n break end
        end
        cible = cible or { id = 15262, d = 3.5, duree = 3.5 }   -- Flammes sacrées, si la partition n'a pas d'incantation
        -- Ajoute une note à incantation en tête, le temps du scénario : elle est jouée en premier.
        table.insert(notes, 1, { id = cible.id, type = "cast", d = cible.d, duree = cible.duree, t = 0, rep = 0 })
        UnitExists, UnitCanAttack = function() return true end, function() return true end
        Evenement("UNIT_SPELLCAST_START", "player", "Cast-int", cible.id)
        UI.MajHUD()
        Evenement("PLAYER_STARTED_MOVING")
        Evenement("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-int", cible.id)
        UnitExists, UnitCanAttack = function() return false end, function() return false end
        UI.MajHUD()
        local jeu = ns.Session.Amelioration().jeu
        assert(jeu.compte.interrompu == 1, "interruptions comptées : " .. tostring(jeu.compte.interrompu))
        assert(jeu.notes[jeu.i].id == cible.id, "la note interrompue n'est pas de nouveau attendue")
        ns.Session.Annuler("fin de la simulation")
    end)
end

-- Mode comparaison : les trois choix, sur les sessions d'amélioration présentes (réelles ou créées ci-dessus).
local function Ameliorations()
    local liste = {}
    for i, s in ipairs(SalleDuTempsDB.sessions) do
        if s.reference and not s.decision then liste[#liste + 1] = s.uid end
    end
    return liste
end
for _, choix in ipairs({ "version", "remplacer", "ignorer" }) do
    Essayer("comparaison : " .. choix, function()
        local uid = Ameliorations()[1]
        if not uid then print("  (aucune session d'amélioration disponible)") return end
        local avant = #SalleDuTempsDB.sessions
        UI.OuvrirCycle((ns.Data.NumeroParUid(uid)))
        UI.ChoixComparaison(choix)
        if choix == "remplacer" then StaticPopupDialogs.SALLEDUTEMPS_REMPLACER.OnAccept() end
        if choix == "ignorer" then StaticPopupDialogs.SALLEDUTEMPS_IGNORER.OnAccept() end
        local numero, s = ns.Data.NumeroParUid(uid)
        if choix == "ignorer" then
            assert(numero == nil and #SalleDuTempsDB.sessions == avant - 1, "session ignorée toujours présente")
        else
            assert(s and s.decision, "décision non enregistrée")
            print("  → " .. tostring(s.nom) .. " (" .. #SalleDuTempsDB.sessions .. " sessions)")
        end
    end)
end

-- Guide en combat normal (jalon 8a) : cycle actif, entrée en combat, sorts, sortie de combat → bilan gardé.
Essayer("guide en combat normal", function()
    if ns.Session.Etat() ~= "inactif" then ns.Session.Annuler("scénario précédent interrompu") end
    local numero, s
    for i, x in ipairs(SalleDuTempsDB.sessions) do
        if ns.Session.ConstruirePartition(x, 60) then numero, s = i, x break end
    end
    if not numero then print("  (aucune session avec un cycle)") return end
    if not ns.Data.EstActif(s) then ns.Data.BasculerActif(s) end
    local avant = #(SalleDuTempsDB.combatsGuides or {})
    -- Le premier sort part AVANT l'entrée en combat (comme en jeu) : il doit être rattrapé.
    local partition = ns.Session.ConstruirePartition(s, 60)
    Evenement("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-g1", partition[1].id)
    Evenement("PLAYER_REGEN_DISABLED")
    assert(ns.Guide.Actif(), "le Guide n'a pas démarré")
    assert(ns.Guide.Actif().debut and ns.Guide.Actif().jeu.juges == 1, "le sort qui a lancé le combat n'est pas rattrapé")
    UI.MajHUD()
    local notes = ns.Guide.Actif().notes
    for k = 2, 6 do
        Evenement("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-g" .. k, notes[k].id)
        TousLesOnUpdate()
    end
    Evenement("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-hors", 99999)   -- sort hors partition
    TousLesOnUpdate()
    Evenement("PLAYER_REGEN_ENABLED")
    assert(not ns.Guide.Actif(), "le Guide ne s'est pas arrêté")
    assert(#SalleDuTempsDB.combatsGuides == avant + 1, "bilan du combat non gardé")
    local bilan = SalleDuTempsDB.combatsGuides[#SalleDuTempsDB.combatsGuides]
    print(string.format("  → précision %s, %d jugées, %d hors partition", tostring(bilan.precision),
        bilan.compte.parfait + bilan.compte.bien + bilan.compte.juste + bilan.compte.rate, bilan.compte.hors))
end)

-- Page Progression (Coach) pour chaque session restante, et commande.
for i = 1, #SalleDuTempsDB.sessions do
    Essayer("progression n° " .. i, UI.OuvrirProgression, i)
end
Essayer("commande /sdt progression", SlashCmdList.SALLEDUTEMPS, "progression")

-- Personnages : les sessions du prêtre sont à lui ; un voleur ne les voit pas.
Essayer("sessions par personnage", function()
    -- Sans sauvegarde (copie publique du dépôt) : une session de prêtre fabriquée.
    SalleDuTempsDB.sessions = SalleDuTempsDB.sessions or {}
    if not SalleDuTempsDB.sessions[1] then
        SalleDuTempsDB.sessions[1] = { uid = "pretre-simulation", classe = "PRIEST", duree = 30, type = "mono",
                                       date = "2026-10-18 12:00", sorts = {} }
    end
    local s = SalleDuTempsDB.sessions[1]
    -- La sauvegarde réelle est peut-être déjà attribuée (au vrai prêtre) : attribution refaite sur une session
    -- remise sans personnage, de la classe du personnage connecté.
    s.personnage, s.classe = nil, select(2, UnitClass("player"))
    ns.Data.AttribuerSessions()
    assert(s.personnage == "Joueur-Royaume", "session non attribuée au prêtre connecté : " .. tostring(s.personnage))
    assert(ns.Data.EstAMoi(s), "le prêtre ne voit pas sa session")
    local classeOrigine = UnitClass
    UnitClass = function() return "Voleur", "ROGUE" end
    local nomOrigine = UnitName
    UnitName = function(u) return u == "player" and "Voleuse" or nil end
    assert(not ns.Data.EstAMoi(s), "le voleur voit la session du prêtre")
    UI.RafraichirJournal()
    UnitClass, UnitName = classeOrigine, nomOrigine
end)

-- Session d'amélioration d'un voleur (session fabriquée : Attaque pernicieuse ×2, Éviscération) : énergie
-- calculée, zones « sablier », HUD, points de combo SECRETS donc estimés, coup de grâce jugé, énergie pleine.
Essayer("voleur : partition à énergie, combo et HUD", function()
    if ns.Session.Etat() ~= "inactif" then ns.Session.Annuler("scénario précédent interrompu") end
    local origine = { UnitClass, UnitPowerType, C_Spell, GetTime, UnitPower, UnitExists, UnitCanAttack, issecretvalue }
    local SECRET = {}
    issecretvalue = function(v) return v == SECRET end
    UnitClass = function() return "Voleur", "ROGUE" end
    UnitPowerType = function() return 3 end
    UnitPowerMax = function(_, typeRessource) return typeRessource == 3 and 100 or (typeRessource == 4 and 5 or 0) end
    UnitPower = function() return SECRET end   -- énergie et points de combo secrets, comme en combat
    UnitExists = function() return true end
    UnitCanAttack = function() return true end
    local maintenant = 7000
    GetTime = function() return maintenant end
    local TEXTES = {
        [1752] = "Une attaque instantanée qui inflige les dégâts de l'arme plus 3. Ajoute 1 point de combo.",
        [2098] = "Coup de grâce qui inflige des dégâts, selon les points de combo.",
    }
    C_Spell = {
        GetSpellPowerCost = function(id) return { { type = 3, cost = id == 2098 and 35 or 45 } } end,
        GetSpellDescription = function(id) return TEXTES[id] or "" end,
    }
    local sessions = SalleDuTempsDB.sessions
    sessions[#sessions + 1] = {
        uid = "voleur-simulation", classe = "ROGUE", personnage = "Joueur-Royaume", duree = 30, type = "mono",
        date = "2026-10-17 23:00", sorts = {},
        cycleEdite = { etapes = {
            { id = 1752, type = "instant", d = 0, actif = true },
            { id = 1752, type = "instant", d = 0, actif = true },
            { id = 2098, type = "instant", d = 0, actif = true },
        } },
    }
    assert(ns.Session.PreparerAmelioration(#sessions, 30), "session d'amélioration du voleur non préparée")
    local jeu = ns.Session.Amelioration().jeu
    assert(jeu.en, "partition sans énergie pour un voleur")
    assert(jeu.notes[1].genere == 1 and jeu.notes[3].finisseur, "rôles des sorts (combo) non reconnus")
    local attente = false
    for _, n in ipairs(jeu.notes) do if n.attente then attente = true end end
    assert(attente, "aucune attente d'énergie prévue")

    local k = 0
    local function Sort(id, avecPoint)   -- envoi puis lancer instantané ; avecPoint : le jeu signale un point
        k = k + 1
        Evenement("UNIT_SPELLCAST_SENT", "player", "", "Cast-v-" .. k, id)
        Evenement("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-v-" .. k, id)
        if avecPoint then Evenement("UNIT_POWER_FREQUENT", "player", "COMBO_POINTS") end
    end
    local function Attendre(secondes)  -- régénération : un signal de gain toutes les 0,1 s
        for _ = 1, math.floor(secondes * 10 + 0.5) do
            maintenant = maintenant + 0.1
            Evenement("UNIT_POWER_FREQUENT", "player", "ENERGY")
            TousLesOnUpdate()
        end
    end
    maintenant = maintenant + 5            -- énergie pleine depuis longtemps
    TousLesOnUpdate()
    Sort(1752, true)                       -- la session démarre
    assert(ns.Session.Etat() == "enCours", "session du voleur non démarrée")
    Attendre(1)
    Sort(1752, true)
    assert(ns.Capture.PointsCombo() == 2, "points de combo estimés : " .. tostring(ns.Capture.PointsCombo()))
    Attendre(1.5)
    Sort(2098, true)                       -- coup de grâce : le signal remet à zéro
    assert(ns.Capture.PointsCombo() == 0, "points non remis à zéro après le coup de grâce")
    assert(not (jeu.erreurs[2098] and jeu.erreurs[2098].combo), "coup de grâce à 2 points jugé à tort")
    UI.MajHUD()
    -- Attaque esquivée : pas de point, pas de signal ; le coup de grâce suivant n'a qu'un point sur deux.
    Attendre(4.5)
    Sort(1752, false)
    Attendre(4.5)
    Sort(1752, true)
    Attendre(4.5)
    Sort(2098, true)
    assert(jeu.erreurs[2098] and jeu.erreurs[2098].combo == 1, "coup de grâce à 1 point sur 2 non signalé")
    -- Énergie pleine : 6 s sans dépense (5 s comptées au-delà du délai d'1 s), puis fin du chrono.
    Attendre(4)
    maintenant = maintenant + 6
    TousLesOnUpdate()
    UI.MajHUD()
    maintenant = maintenant + 30
    TousLesOnUpdate()                      -- fin du chrono, lecture du compteur, enregistrement
    local s = sessions[#sessions]
    print(string.format("  → énergie pleine : %s s · erreurs : %s", tostring(s.energiePleine),
        s.jugement and s.jugement.erreurs[2098] and tostring(s.jugement.erreurs[2098].combo) or "?"))
    assert(s.energiePleine and s.energiePleine >= 30, "temps à énergie pleine non relevé : " .. tostring(s.energiePleine))
    UnitClass, UnitPowerType, C_Spell, GetTime, UnitPower, UnitExists, UnitCanAttack, issecretvalue = table.unpack(origine, 1, 8)
    UnitPowerMax = function() return 0 end
end)

-- Esquive et perte de contrôle (points de combo LISIBLES, comme en jeu) : la note esquivée est à rejouer,
-- sans faute ; étourdi, rien n'est déclaré passé.
Essayer("voleur : esquive et étourdissement", function()
    if ns.Session.Etat() ~= "inactif" then ns.Session.Annuler("scénario précédent interrompu") end
    local origine = { UnitClass, UnitPowerType, C_Spell, GetTime, UnitPower, UnitExists, UnitCanAttack, HasFullControl }
    local points, controle = 0, true
    UnitClass = function() return "Voleur", "ROGUE" end
    UnitPowerType = function() return 3 end
    UnitPowerMax = function(_, typeRessource) return typeRessource == 3 and 100 or (typeRessource == 4 and 5 or 0) end
    UnitPower = function(_, typeRessource) return typeRessource == 4 and points or 50 end
    UnitExists = function() return true end
    UnitCanAttack = function() return true end
    HasFullControl = function() return controle end
    local maintenant = 8000
    GetTime = function() return maintenant end
    local TEXTES = {
        [1752] = "Une attaque instantanée qui inflige les dégâts de l'arme plus 3. Ajoute 1 point de combo.",
        [2098] = "Coup de grâce qui inflige des dégâts, selon les points de combo.",
    }
    C_Spell = {
        GetSpellPowerCost = function(id) return { { type = 3, cost = id == 2098 and 35 or 45 } } end,
        GetSpellDescription = function(id) return TEXTES[id] or "" end,
    }
    local sessions = SalleDuTempsDB.sessions
    sessions[#sessions + 1] = {
        uid = "voleur-esquive", classe = "ROGUE", personnage = "Joueur-Royaume", duree = 30, type = "mono",
        date = "2026-10-17 23:10", sorts = {},
        cycleEdite = { etapes = {
            { id = 1752, type = "instant", d = 0, actif = true },
            { id = 1752, type = "instant", d = 0, actif = true },
            { id = 2098, type = "instant", d = 0, actif = true },
        } },
    }
    assert(ns.Session.PreparerAmelioration(#sessions, 30), "session non préparée")
    local jeu = ns.Session.Amelioration().jeu
    local k = 0
    local function Sort(id, porte)
        k = k + 1
        Evenement("UNIT_SPELLCAST_SENT", "player", "", "Cast-e-" .. k, id)
        Evenement("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-e-" .. k, id)
        if porte then
            points = id == 2098 and 0 or math.min(5, points + 1)
            Evenement("UNIT_POWER_FREQUENT", "player", "COMBO_POINTS")
        end
    end
    local function Attendre(secondes)
        for _ = 1, math.floor(secondes * 10 + 0.5) do
            maintenant = maintenant + 0.1
            Evenement("UNIT_POWER_FREQUENT", "player", "ENERGY")
            TousLesOnUpdate()
            UI.MajHUD()
        end
    end
    maintenant = maintenant + 5
    TousLesOnUpdate()
    Sort(1752, false)                      -- esquivée : pas de point
    Attendre(1)
    assert(jeu.compte.esquive == 1, "esquive non repérée")
    assert(jeu.i == 1 and jeu.juges == 0, "la note esquivée n'est pas à rejouer")
    Sort(1752, true)                       -- rejouée, elle porte
    Attendre(0.6)
    assert(jeu.compte.esquive == 1 and jeu.i == 2, "le coup qui a porté a été pris pour une esquive")
    -- Étourdi 6 s : rien n'est déclaré passé, message de pause dans le HUD.
    controle = false
    Attendre(6)
    assert(jeu.compte.rate == 0, "notes déclarées passées pendant l'étourdissement")
    controle = true
    Sort(1752, true)
    Attendre(2)
    Sort(2098, true)
    Attendre(0.6)
    print(string.format("  → %d esquivé, %d raté, précision %s", jeu.compte.esquive, jeu.compte.rate,
        tostring(ns.Partition.Precision(jeu))))
    assert(jeu.compte.esquive == 1 and not (jeu.erreurs[2098] and jeu.erreurs[2098].combo), "coup de grâce mal jugé")
    ns.Session.Annuler("fin de la simulation")
    UnitClass, UnitPowerType, C_Spell, GetTime, UnitPower, UnitExists, UnitCanAttack, HasFullControl = table.unpack(origine, 1, 8)
    UnitPowerMax = function() return 0 end
end)

-- Mesure de la régénération d'énergie : segments « plein → sort(s) à 45 → gains pendant N s → plein ».
-- Trois segments à un sort sur 6 s (7,5/s, différent des 10/s par défaut) et un segment à deux sorts, ignoré.
Essayer("voleur : mesure de la régénération", function()
    local classeOrigine, typeOrigine, sortsOrigine, tempsOrigine = UnitClass, UnitPowerType, C_Spell, GetTime
    UnitClass = function() return "Voleur", "ROGUE" end
    UnitPowerType = function() return 3 end
    C_Spell = { GetSpellPowerCost = function() return { { type = 3, cost = 45 } } end }
    local maintenant = 10000   -- après les horloges des scénarios précédents (le temps ne recule pas)
    GetTime = function() return maintenant end
    -- La surveillance ne regarde que toutes les 0,1 s et chaque passage simulé vaut 0,05 s : chaque étape
    -- clé fait donc deux passages, pour que le résultat ne dépende pas de son rythme.
    local function Passage() TousLesOnUpdate() TousLesOnUpdate() end
    local function Segment(sorts, secondes)
        maintenant = maintenant + 5        -- longtemps sans signal : énergie pleine
        Passage()
        for k = 1, sorts do
            Evenement("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-regen-" .. k, 1752)
            -- Comme en jeu : un passage de la surveillance avant le premier signal de gain.
            maintenant = maintenant + 0.05
            Passage()
        end
        for _ = 1, secondes * 10 do        -- un signal de gain toutes les 0,1 s
            maintenant = maintenant + 0.1
            Evenement("UNIT_POWER_FREQUENT", "player", "ENERGY")
            Passage()
        end
        maintenant = maintenant + 2        -- plus de signal (plus que Capture.DELAI_PLEINE) : énergie pleine
        Passage()
    end
    Segment(1, 6)
    Segment(2, 6)                          -- deux sorts : ignoré (un raté fausserait la mesure)
    Segment(1, 6)
    local avant = ns.Capture.RegenEnergie()
    Segment(1, 6)
    local regen = ns.Capture.RegenEnergie()
    UnitClass, UnitPowerType, C_Spell, GetTime = classeOrigine, typeOrigine, sortsOrigine, tempsOrigine
    local liste = SalleDuTempsDB.mesuresRegen and SalleDuTempsDB.mesuresRegen["Joueur-Royaume"]
    print(string.format("  → %d mesures retenues, régénération : %.2f par seconde (avant la 3e : %.2f)",
        liste and #liste or 0, regen, avant))
    assert(liste and #liste == 3, "le segment à deux sorts n'a pas été ignoré, ou des mesures manquent")
    assert(avant == 10, "valeur par défaut attendue avant 3 mesures")
    assert(math.abs(regen - 7.5) < 0.3, "mesure inattendue : " .. regen)
end)

-- Sonde du jalon 7 (énergie) : démarrage, gains d'énergie, arrêt.
Essayer("sonde énergie", function()
    ns.Capture.SondeEnergie()
    Evenement("UNIT_POWER_FREQUENT", "player", "ENERGY")
    Evenement("UNIT_POWER_FREQUENT", "player", "ENERGY")
    ns.Capture.SondeEnergie()
    assert(SalleDuTempsDB.sondeEnergie and #SalleDuTempsDB.sondeEnergie.gains.horsCombat == 2, "gains non relevés")
end)

-- Sonde de perte de contrôle : démarrage, échantillons, événement, arrêt.
Essayer("sonde contrôle", function()
    HasFullControl = function() return false end
    SlashCmdList.SALLEDUTEMPS("sonde controle")
    TousLesOnUpdate() TousLesOnUpdate() TousLesOnUpdate() TousLesOnUpdate()
    Evenement("LOSS_OF_CONTROL_ADDED")
    Evenement("UI_ERROR_MESSAGE", 50, "Vous êtes étourdi")
    SlashCmdList.SALLEDUTEMPS("sonde controle")
    HasFullControl = nil
    local r = SalleDuTempsDB.sondeControle
    assert(r and #r.etats >= 1, "états non relevés")
    print("  → " .. tostring(r.etats[1]))
end)

-- Sonde du jalon 6b : démarrage, échantillons, arrêt.
Essayer("sonde 6b", function()
    ns.Capture.Sonde()
    TousLesOnUpdate()
    ns.Capture.Sonde()
    assert(SalleDuTempsDB.sonde6b, "résultat de la sonde non enregistré")
end)

print(string.format("\n%d erreur(s)", erreurs))
if erreurs > 0 then os.exit(1) end
