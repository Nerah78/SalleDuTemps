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

-- Core : chargement, base sauvegardée, commande /sdt, icône de minimap.

local NOM_ADDON, ns = ...

ns.VERSION = "0.14.0"

function ns.Print(msg)
    print("|cff66ccffSalle du Temps|r " .. tostring(msg))
end

local Print = ns.Print

-- Le client masque certaines valeurs en combat (« valeurs secrètes ») : un addon ne peut ni les comparer
-- ni calculer avec, sous peine d'erreur. Toute valeur venue du jeu passe par EstSecret avant usage.
function ns.EstSecret(v)
    if not issecretvalue then return false end
    local ok, res = pcall(issecretvalue, v)
    return ok and res and true or false
end

-- Croix de fermeture : celle des modèles du jeu passe par HideUIPanel, qui peut être bloquée en combat
-- (fenêtre impossible à fermer, constaté le 2026-10-17). Nos fenêtres ne sont pas protégées : on les cache
-- directement.
function ns.FermetureDirecte(f)
    local croix = f.CloseButton
    if type(croix) == "table" and croix.SetScript then croix:SetScript("OnClick", function() f:Hide() end) end
end

-- Valeur utilisable telle quelle, ou nil si elle est absente ou secrète.
function ns.Lisible(v)
    if v == nil or ns.EstSecret(v) then return nil end
    return v
end

-- ---------------------------------------------------------------------
-- Base sauvegardée (par compte)
-- ---------------------------------------------------------------------
local DEFAUTS = {
    minimapAngle = 200,
    iconeMasquee = false,
    afficherSorts = true,   -- jalon 1 : affichage brut des sorts lancés dans le chat
}

local function InitialiserBase()
    SalleDuTempsDB = SalleDuTempsDB or {}
    for cle, valeur in pairs(DEFAUTS) do
        if SalleDuTempsDB[cle] == nil then SalleDuTempsDB[cle] = valeur end
    end
    ns.db = SalleDuTempsDB
end

-- ---------------------------------------------------------------------
-- Icône sur le cercle de la minimap (clic : activer / couper l'affichage, glisser : déplacer)
-- ---------------------------------------------------------------------
local icone
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local RAYON_SUPPLEMENT = 10

local function PlacerIcone()
    if not (icone and Minimap) then return end
    local rad = math.rad(ns.db.minimapAngle or DEFAUTS.minimapAngle)
    local rayon = (Minimap:GetWidth() / 2) + RAYON_SUPPLEMENT
    icone:ClearAllPoints()
    icone:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * rayon, math.sin(rad) * rayon)
end

local function MajVisibiliteIcone()
    if not icone then return end
    if ns.db.iconeMasquee then icone:Hide() else icone:Show() end
end

local function SuivreCurseur()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    if not (mx and my and cx and cy) then return end
    local echelle = Minimap:GetEffectiveScale()
    cx, cy = cx / echelle, cy / echelle
    ns.db.minimapAngle = math.deg(atan2(cy - my, cx - mx)) % 360
    PlacerIcone()
end

local function InfoBulleIcone(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("La Salle du Temps")
    GameTooltip:AddLine("v" .. ns.VERSION .. " - jalon 8 (Guide et Coach)", 0.7, 0.7, 0.7)
    local nb = ns.db.sessions and #ns.db.sessions or 0
    GameTooltip:AddLine(string.format("Sessions enregistrées : %d", nb), 1, 0.82, 0)
    if ns.db.afficherSorts then
        GameTooltip:AddLine("Affichage des sorts dans le chat : activé", 0.4, 1, 0.4)
    else
        GameTooltip:AddLine("Affichage des sorts dans le chat : coupé", 1, 0.4, 0.4)
    end
    GameTooltip:AddLine("Clic : journal des cycles", 1, 1, 1)
    GameTooltip:AddLine("Clic droit : activer / couper l'affichage des sorts", 1, 1, 1)
    GameTooltip:AddLine("Glisser : déplacer l'icône", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local glisse = false
local finGlisse = nil

local function BasculerAffichage()
    ns.db.afficherSorts = not ns.db.afficherSorts
    Print("Affichage des sorts lancés : " .. (ns.db.afficherSorts and "activé" or "coupé") .. ".")
end

local function CreerIcone()
    if icone or not Minimap then return end
    local b = CreateFrame("Button", "SalleDuTempsIcone", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    local fond = b:CreateTexture(nil, "BACKGROUND")
    fond:SetSize(20, 20)
    fond:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -5)
    fond:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    local image = b:CreateTexture(nil, "ARTWORK")
    image:SetSize(17, 17)
    image:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -6)
    image:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")   -- provisoire, en attendant un sablier original
    image:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    local bord = b:CreateTexture(nil, "OVERLAY")
    bord:SetSize(53, 53)
    bord:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    bord:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self)
        glisse = true
        GameTooltip:Hide()
        self:SetScript("OnUpdate", SuivreCurseur)
    end)
    b:SetScript("OnDragStop", function(self)
        glisse = false
        finGlisse = GetTime()
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnClick", function(_, bouton)
        if glisse then return end
        if finGlisse and (GetTime() - finGlisse) < 0.25 then return end
        if bouton == "RightButton" then
            BasculerAffichage()
        else
            local ok, err = pcall(ns.UI.BasculerJournal)
            if not ok then Print("Journal : erreur (" .. tostring(err) .. ")") end
        end
    end)
    b:SetScript("OnEnter", function(self)
        local ok, err = pcall(InfoBulleIcone, self)
        if not ok then GameTooltip:SetText("Erreur : " .. tostring(err)) GameTooltip:Show() end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    icone = b
    PlacerIcone()
    MajVisibiliteIcone()
end

-- ---------------------------------------------------------------------
-- Commande /sdt
-- ---------------------------------------------------------------------
-- Les dernières sessions du personnage connecté, en une ligne chacune.
local function ListerSessions()
    local miennes = {}
    for i, s in ipairs(ns.Data.Sessions()) do
        if ns.Data.EstAMoi(s) then miennes[#miennes + 1] = i end
    end
    if #miennes == 0 then
        Print("Aucune session enregistrée pour ce personnage.")
        return
    end
    Print("Dernières sessions de ce personnage :")
    for k = math.max(1, #miennes - 9), #miennes do
        local i = miennes[k]
        local s = ns.Data.Sessions()[i]
        print(string.format("  n° %d · %s · %d s · %s%s · %s · %d sorts",
            i, s.date or "?", s.duree or 0, s.cible or "?", s.mannequin and "" or " (pas un mannequin)",
            s.dps and string.format("%.1f DPS", s.dps) or "DPS ?", s.sorts and #s.sorts or 0)
            .. ((s.etiquette or "") ~= "" and (" · « " .. s.etiquette .. " »") or ""))
    end
end

local function Aide()
    Print("Commandes :")
    print("  /sdt - journal des cycles")
    print("  /sdt session - nouvelle session (panneau des réglages)")
    print("  /sdt test [N] - session de test de N secondes (15 par défaut)")
    print("  /sdt ameliorer [n] [secondes] - session d'amélioration de la session n (timeline rythmique)")
    print("  /sdt progression [n] - progression du cycle de la session n (Coach)")
    print("  /sdt guide - activer / couper le Guide en combat normal (suit le cycle « Actif »)")
    print("  /sdt annuler - annuler la session en cours")
    print("  /sdt sessions - dernières sessions enregistrées")
    print("  /sdt cycle [n] - page Cycle de la session n (la dernière par défaut)")
    print("  /sdt sorts - activer / couper l'affichage des sorts lancés")
    print("  /sdt zero - remettre le chrono d'affichage à zéro")
    print("  /sdt icone - masquer / afficher l'icône de minimap")
    print("  /sdt icone reset - replacer l'icône à sa position par défaut")
    print("  /sdt diag - diagnostic de l'API (journal de combat, valeurs secrètes)")
    print("  /sdt compteur - sonde du compteur de dégâts intégré (résultat dans la sauvegarde)")
    print("  /sdt sonde - sonde du jalon 6b : déplacements et jauge de mana (lancer, bouger, relancer)")
    print("  /sdt sonde energie - sonde du jalon 7, sur un voleur : énergie, combo, coûts, gains d'énergie")
    print("  /sdt sonde controle - ce que le jeu laisse voir d'un étourdissement (lancer, se faire étourdir, relancer)")
    print("  /sdt version - numéro de version et d'interface")
end

local function Commande(texte)
    local arg = strtrim(string.lower(texte or ""))
    if arg == "" or arg == "journal" then
        ns.UI.BasculerJournal()
    elseif arg == "session" then
        ns.UI.BasculerPanneau()
    elseif arg:match("^test") then
        -- Session courte pour tester le déroulé sur un monstre ordinaire (hors spec : 1, 2 ou 3 min).
        local duree = tonumber(arg:match("^test%s+(%d+)")) or 15
        duree = math.max(5, math.min(180, duree))
        ns.Session.Preparer({ duree = duree, type = "mono", etiquette = "test " .. duree .. " s" }, true)
    elseif arg:match("^ameliorer") then
        -- /sdt ameliorer [n] [secondes] : session d'amélioration de la session n (la dernière par défaut).
        local n, secondes = arg:match("^ameliorer%s*(%d*)%s*(%d*)")
        local numero = tonumber(n) or #ns.Data.Sessions()
        local duree = tonumber(secondes)
        if duree then duree = math.max(5, math.min(180, duree)) end
        ns.Session.PreparerAmelioration(numero, duree)
    elseif arg:match("^progression") then
        ns.UI.OuvrirProgression(tonumber(arg:match("^progression%s+(%d+)")) or #ns.Data.Sessions())
    elseif arg == "guide" then
        ns.Guide.Basculer()
    elseif arg == "annuler" then
        ns.Session.Annuler("par le joueur")
    elseif arg == "sessions" then
        ListerSessions()
    elseif arg:match("^cycle") then
        ns.UI.OuvrirCycle(tonumber(arg:match("^cycle%s+(%d+)")))
    elseif arg == "sorts" then
        BasculerAffichage()
    elseif arg == "zero" then
        if ns.Capture then ns.Capture.RemettreAZero() end
        Print("Chrono remis à zéro.")
    elseif arg == "icone" then
        ns.db.iconeMasquee = not ns.db.iconeMasquee
        MajVisibiliteIcone()
        Print("Icône de minimap " .. (ns.db.iconeMasquee and "masquée." or "affichée."))
    elseif arg == "icone reset" then
        ns.db.minimapAngle = DEFAUTS.minimapAngle
        ns.db.iconeMasquee = false
        PlacerIcone()
        MajVisibiliteIcone()
        Print("Icône replacée.")
    elseif arg == "diag" then
        if ns.Capture then ns.Capture.Diagnostic() end
    elseif arg == "sonde energie" then
        ns.Capture.SondeEnergie()
    elseif arg == "sonde controle" or arg == "sonde contrôle" then
        ns.Capture.SondeControle()
    elseif arg == "sonde" then
        ns.Capture.Sonde()
    elseif arg == "compteur" then
        if ns.Capture then ns.Capture.SondeCompteur() end
    elseif arg == "version" then
        local _, build, _, interface = GetBuildInfo()
        Print(string.format("v%s - jeu %s, interface %s", ns.VERSION, tostring(build), tostring(interface)))
    else
        Aide()
    end
end

SLASH_SALLEDUTEMPS1 = "/sdt"
SlashCmdList["SALLEDUTEMPS"] = Commande

-- ---------------------------------------------------------------------
-- Chargement
-- ---------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == NOM_ADDON then
        InitialiserBase()
        ns.Data.Migrer()
        ns.db.regenEnergie = nil   -- ancienne mesure (moyenne sur plusieurs sorts, faussée par les ratés)
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        local ok, err = pcall(CreerIcone)
        if not ok then Print("Icône de minimap : erreur (" .. tostring(err) .. ")") end
        if ns.Capture then ns.Capture.Demarrer() end
        pcall(ns.Data.AttribuerSessions)
        local okR, errR = pcall(ns.Session.Reprendre)
        if not okR then Print("Reprise de session : erreur (" .. tostring(errR) .. ")") end
        Print("v" .. ns.VERSION .. " chargée. /sdt pour l'aide.")
    end
end)
