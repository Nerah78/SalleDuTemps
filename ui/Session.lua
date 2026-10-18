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

-- UI de session : panneau « Nouvelle session » (durée, type, étiquette) et barre compacte
-- (attente du premier sort, temps restant, dégâts en direct, annuler).

local _, ns = ...

local UI = ns.UI or {}
ns.UI = UI

local EstSecret = ns.EstSecret

local DUREES = { { 60, "1 min" }, { 120, "2 min" }, { 180, "3 min" } }
local TYPES = { { "mono", "Mono-cible" }, { "multi", "Multi-cibles" } }

local function Texte(parent, police, point, relatif, pointRelatif, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", police)
    fs:SetPoint(point, relatif, pointRelatif, x, y)
    fs:SetJustifyH("LEFT")
    return fs
end

local function Bouton(parent, texte, largeur, hauteur)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(largeur, hauteur or 22)
    b:SetText(texte)
    return b
end

-- ---------------------------------------------------------------------
-- Panneau « Nouvelle session »
-- ---------------------------------------------------------------------
local panneau
local choix = {}   -- réglages en cours d'édition

-- Bouton choisi : surligné et opaque ; les autres : atténués.
local function MarquerChoix(boutons, valeur)
    for _, b in ipairs(boutons) do
        if b.valeur == valeur then
            b:LockHighlight()
            b:SetAlpha(1)
        else
            b:UnlockHighlight()
            b:SetAlpha(0.45)
        end
    end
end

local function MajChoix()
    MarquerChoix(panneau.boutonsDuree, choix.duree)
    MarquerChoix(panneau.boutonsType, choix.type)
end

local function CreerPanneau()
    local f
    local natif = pcall(function() f = CreateFrame("Frame", "SalleDuTempsPanneau", UIParent, "BasicFrameTemplateWithInset") end)
    if not (natif and f) then
        natif = false
        f = CreateFrame("Frame", "SalleDuTempsPanneau", UIParent)
        local fond = f:CreateTexture(nil, "BACKGROUND")
        fond:SetAllPoints()
        fond:SetColorTexture(0.05, 0.05, 0.08, 0.93)
        pcall(function()
            local fermer = CreateFrame("Button", nil, f, "UIPanelCloseButton")
            f.CloseButton = fermer
            fermer:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        end)
    end
    f:SetSize(320, 200)
    ns.FermetureDirecte(f)   -- la croix doit marcher en combat
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if UISpecialFrames then table.insert(UISpecialFrames, "SalleDuTempsPanneau") end

    local titre = natif and (f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)) or nil
    if not (titre and titre.SetText) then titre = Texte(f, "GameFontNormal", "TOP", f, "TOP", 0, -6) end
    titre:SetText("La Salle du Temps - Nouvelle session")

    -- Durée
    local lDuree = Texte(f, "GameFontNormal", "TOPLEFT", f, "TOPLEFT", 18, -40)
    lDuree:SetText("Durée")
    f.boutonsDuree = {}
    for i, d in ipairs(DUREES) do
        local b = Bouton(f, d[2], 70)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 100 + (i - 1) * 72, -35)
        b.valeur = d[1]
        b:SetScript("OnClick", function() choix.duree = d[1] MajChoix() end)
        f.boutonsDuree[i] = b
    end

    -- Type de combat
    local lType = Texte(f, "GameFontNormal", "TOPLEFT", f, "TOPLEFT", 18, -72)
    lType:SetText("Type")
    f.boutonsType = {}
    for i, t in ipairs(TYPES) do
        local b = Bouton(f, t[2], 106)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 100 + (i - 1) * 108, -67)
        b.valeur = t[1]
        b:SetScript("OnClick", function() choix.type = t[1] MajChoix() end)
        f.boutonsType[i] = b
    end

    -- Étiquette
    local lEtiquette = Texte(f, "GameFontNormal", "TOPLEFT", f, "TOPLEFT", 18, -106)
    lEtiquette:SetText("Étiquette")
    local saisie = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    saisie:SetSize(196, 22)
    saisie:SetPoint("TOPLEFT", f, "TOPLEFT", 106, -100)
    saisie:SetAutoFocus(false)
    saisie:SetMaxLetters(40)
    saisie:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    saisie:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.saisie = saisie

    local note = Texte(f, "GameFontDisableSmall", "TOPLEFT", f, "TOPLEFT", 18, -132)
    note:SetText("Le chrono démarre au premier sort lancé sur la cible.")

    local pret = Bouton(f, "Prêt", 100, 24)
    pret:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    pret:SetScript("OnClick", function()
        choix.etiquette = strtrim(saisie:GetText() or "")
        if ns.Session.Preparer({ duree = choix.duree, type = choix.type, etiquette = choix.etiquette }) then
            f:Hide()
        end
    end)

    f:SetScript("OnShow", function()
        local r = ns.Data.Reglages()
        choix.duree, choix.type, choix.etiquette = r.duree, r.type, r.etiquette
        saisie:SetText(choix.etiquette or "")
        MajChoix()
    end)
    f:Hide()
    panneau = f
end

function UI.BasculerPanneau()
    if not panneau then CreerPanneau() end
    if panneau:IsShown() then
        panneau:Hide()
    elseif ns.Session.Etat() ~= "inactif" then
        ns.Print("Une session est déjà en cours (/sdt annuler pour l'arrêter).")
    else
        panneau:Show()
    end
end

-- ---------------------------------------------------------------------
-- Barre compacte
-- ---------------------------------------------------------------------
local barre

-- Affichage des dégâts en direct. En combat, le compteur renvoie une valeur secrète : on tente de la
-- passer telle quelle à la police (permis sur le client moderne ?). Le résultat est noté dans
-- SalleDuTempsDB.testDirect pour lecture hors du jeu.
local modeDirect   -- nil : pas encore essayé ; "format", "texte" ou "aucun"

local function NoterTest(resultat)
    ns.db.testDirect = { date = date("%Y-%m-%d %H:%M:%S"), resultat = resultat }
end

local function AfficherDegats(fs, v)
    if v == nil then
        fs:SetText("Dégâts : -")
        return
    end
    if not EstSecret(v) then
        fs:SetFormattedText("Dégâts : %d", v)
        return
    end
    if modeDirect == nil or modeDirect == "format" then
        local ok, err = pcall(fs.SetFormattedText, fs, "Dégâts : %d", v)
        if ok then
            if modeDirect == nil then NoterTest("SetFormattedText accepte la valeur secrète") end
            modeDirect = "format"
            return
        end
        if modeDirect == nil then NoterTest("SetFormattedText refusé : " .. tostring(err)) end
        modeDirect = "texte"
    end
    if modeDirect == "texte" then
        local ok, err = pcall(fs.SetText, fs, v)
        if ok then return end
        ns.db.testDirect.texte = "SetText refusé : " .. tostring(err)
        modeDirect = "aucun"
    end
    fs:SetText("Dégâts : masqués en combat")
end

local function SauverPosition()
    local point, _, pointRelatif, x, y = barre:GetPoint()
    ns.db.barre = { point = point, pointRelatif = pointRelatif, x = x, y = y }
end

local function CreerBarre()
    local f = CreateFrame("Frame", "SalleDuTempsBarre", UIParent)
    f:SetSize(280, 52)
    local p = ns.db.barre
    if p then
        f:SetPoint(p.point, UIParent, p.pointRelatif, p.x, p.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    end
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SauverPosition() end)

    local fond = f:CreateTexture(nil, "BACKGROUND")
    fond:SetAllPoints()
    fond:SetColorTexture(0, 0, 0, 0.6)

    f.ligne1 = Texte(f, "GameFontNormal", "TOPLEFT", f, "TOPLEFT", 10, -8)
    f.ligne2 = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", 10, -30)

    local annuler = Bouton(f, "Annuler", 70, 20)
    annuler:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    annuler:SetScript("OnClick", function() ns.Session.Annuler("par le joueur") end)

    local ecoule = 0
    f:SetScript("OnUpdate", function(self, dt)
        ecoule = ecoule + dt
        if ecoule < 0.2 then return end
        ecoule = 0
        local etat = ns.Session.Etat()
        if etat == "attente" then
            self.ligne1:SetText("En attente du premier sort sur la cible…")
            self.ligne2:SetText("")
        elseif etat == "enCours" then
            local restant = ns.Session.Restant() or 0
            self.ligne1:SetFormattedText("Session : %d:%02d restantes", math.floor(restant / 60), math.floor(restant % 60))
            AfficherDegats(self.ligne2, ns.Capture.DegatsEnDirect())
        elseif etat == "decision" then
            self.ligne1:SetText("|cffff9933Combat terminé avant la fin|r")
            self.ligne2:SetText("Enregistrer la session écourtée ?")
        elseif etat == "fin" then
            self.ligne1:SetText("|cff66ff66Terminé|r : arrête d'attaquer")
            self.ligne2:SetText("Résultat à la sortie de combat…")
        end
    end)
    f:Hide()
    barre = f
end

UI.AfficherDegats = AfficherDegats   -- partagé avec le HUD

-- ---------------------------------------------------------------------
-- Combat terminé avant la fin du chrono : enregistrer la session écourtée ou l'abandonner
-- ---------------------------------------------------------------------
StaticPopupDialogs["SALLEDUTEMPS_ECOURTEE"] = {
    text = "Le combat s'est terminé après %s s, sur une session de %s s.\nEnregistrer la session écourtée ?",
    button1 = "Enregistrer",
    button2 = "Abandonner",
    OnAccept = function() ns.Session.EnregistrerEcourtee() end,
    OnCancel = function()
        -- Fermeture sans choix (Échap, délai) : la session est abandonnée aussi.
        if ns.Session.Etat() == "decision" then ns.Session.Annuler("session écourtée abandonnée") end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function UI.DemanderEcourtee(secondes, duree)
    StaticPopup_Show("SALLEDUTEMPS_ECOURTEE", tostring(secondes), tostring(duree))
end

-- En session d'amélioration, le HUD (ui/HUD.lua) remplace la barre compacte.
function UI.AfficherBarre()
    if ns.Session.Amelioration() then
        if barre then barre:Hide() end
        UI.AfficherHUD()
        return
    end
    if not barre then CreerBarre() end
    barre:Show()
end

function UI.BarreFin()
    if ns.Session.Amelioration() then return end   -- le HUD affiche lui-même l'état « Terminé »
    if barre then barre:Show() end
end

function UI.MasquerBarre()
    if barre then barre:Hide() end
    if UI.MasquerHUD then UI.MasquerHUD() end
end
