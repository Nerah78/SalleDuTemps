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

-- Éditeur du cycle, V1 (jalon 5). Travaille sur une copie des étapes ; « Enregistrer » crée ou remplace la
-- version éditée de la session, à côté du cycle détecté (qui n'est jamais modifié).
-- Aperçu de la partition en direct, liste réordonnable (flèches et glisser-déposer), touche, type,
-- activer / désactiver, retirer, ajout par glisser-déposer depuis le grimoire, « Version auto ».

local _, ns = ...

local UI = ns.UI or {}
ns.UI = UI

local LARGEUR, HAUTEUR = UI.LARGEUR_CYCLE, UI.HAUTEUR_CYCLE   -- même page que la Consultation (Cycle.lua)
local HAUTEUR_LIGNE = 26
local MAX_APERCU = 16
local ICONE_INCONNUE = "Interface\\Icons\\INV_Misc_QuestionMark"

local TYPES = { "cast", "instant", "canal", "serie", "dot" }
local LIBELLES = { cast = "Incantation", instant = "Instantané", canal = "Canalisation", serie = "Série", dot = "DoT" }
local DUREE_DOT_DEFAUT = 12   -- s, si la description du sort ne donne pas la durée

local editeur
local uid            -- session éditée
local etapes = {}    -- copie de travail
local modifie = false
local glisse         -- index de la ligne en cours de glisser-déposer
local touches        -- cache nom de sort -> touche, refait à chaque ouverture
local versConsultation = false   -- sortie par Annuler / Enregistrer : afficher la Consultation

-- ---------------------------------------------------------------------
-- Utilitaires
-- ---------------------------------------------------------------------
local function Nombre(x, decimales)
    return (string.format("%." .. (decimales or 0) .. "f", x):gsub("%.", ","))
end

local function IconeSort(id)
    if id then
        if C_Spell and C_Spell.GetSpellTexture then
            local ok, tex = pcall(C_Spell.GetSpellTexture, id)
            if ok and tex then return tex end
        end
        if GetSpellTexture then
            local ok, tex = pcall(GetSpellTexture, id)
            if ok and tex then return tex end
        end
    end
    return ICONE_INCONNUE
end

-- Temps d'incantation (s) d'après le jeu, pour un sort ajouté à la main.
local function DureeIncantation(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" and info.castTime then return info.castTime / 1000 end
    end
    if GetSpellInfo then
        local ok, _, _, _, castTime = pcall(GetSpellInfo, id)
        if ok and castTime then return castTime / 1000 end
    end
    return 0
end

local function Texte(parent, police, point, relatif, pointRelatif, x, y, largeur)
    local fs = parent:CreateFontString(nil, "OVERLAY", police)
    fs:SetPoint(point, relatif, pointRelatif, x, y)
    fs:SetJustifyH("LEFT")
    if largeur then fs:SetWidth(largeur) end
    return fs
end

local function Bouton(parent, texte, largeur, hauteur)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(largeur, hauteur or 22)
    b:SetText(texte)
    return b
end

local function Session()
    for i, s in ipairs(ns.Data.Sessions()) do
        if s.uid == uid then return i, s end
    end
end

-- ---------------------------------------------------------------------
-- Touches des barres d'action (recherche par nom de sort, tous rangs confondus)
-- ---------------------------------------------------------------------
local function CommandeEmplacement(slot)
    if slot <= 12 then return "ACTIONBUTTON" .. slot end
    if slot >= 25 and slot <= 36 then return "MULTIACTIONBAR3BUTTON" .. (slot - 24) end
    if slot >= 37 and slot <= 48 then return "MULTIACTIONBAR4BUTTON" .. (slot - 36) end
    if slot >= 49 and slot <= 60 then return "MULTIACTIONBAR2BUTTON" .. (slot - 48) end
    if slot >= 61 and slot <= 72 then return "MULTIACTIONBAR1BUTTON" .. (slot - 60) end
    return nil
end

local function Abreger(touche)
    return (touche:gsub("SHIFT%-", "S-"):gsub("CTRL%-", "C-"):gsub("ALT%-", "A-"))
end

local function ReleverTouches()
    touches = {}
    if not (GetActionInfo and GetBindingKey) then return end
    for slot = 1, 72 do
        local commande = CommandeEmplacement(slot)
        if commande then
            local ok, genre, id = pcall(GetActionInfo, slot)
            if ok and genre == "spell" and id then
                local nom = ns.Capture.NomSort(id)
                local okT, touche = pcall(GetBindingKey, commande)
                if nom ~= "?" and okT and touche and not touches[nom] then touches[nom] = Abreger(touche) end
            end
        end
    end
end

local function Touche(id)
    if not touches then ReleverTouches() end
    return touches[ns.Capture.NomSort(id)] or "-"
end

-- Partagé avec le HUD (touche affichée sur chaque note de la timeline).
UI.Touche = Touche
function UI.ReinitialiserTouches() touches = nil end

-- ---------------------------------------------------------------------
-- Modifications de la copie de travail
-- ---------------------------------------------------------------------
local Rafraichir

local function Modifier()
    modifie = true
    Rafraichir()
end

local function Deplacer(de, vers)
    if de == vers or not etapes[de] or vers < 1 or vers > #etapes then return end
    local e = table.remove(etapes, de)
    table.insert(etapes, vers, e)
    Modifier()
end

local function AjouterSort(id)
    if not id then return end
    local genre, d
    if ns.Cycle.SERIES[id] then
        genre, d = "serie", 0
    else
        d = DureeIncantation(id)
        genre = d > 0 and "cast" or "instant"
    end
    etapes[#etapes + 1] = { id = id, actif = true, type = genre, d = d }
    Modifier()
end

-- Sort tenu par le curseur (glissé depuis le grimoire ou une barre d'action).
local function SortDuCurseur()
    if not GetCursorInfo then return nil end
    local genre, a, b, c = GetCursorInfo()
    if genre ~= "spell" then return nil end
    local id = c
    if not id and a and b and GetSpellBookItemInfo then
        local ok, _, idLivre = pcall(GetSpellBookItemInfo, a, b)
        if ok then id = idLivre end
    end
    ClearCursor()
    return id
end

-- Ouvrir le grimoire ferme les fenêtres « à fermer avec Échap » : l'éditeur et le journal. On les rouvre
-- aussitôt, sans perdre la copie de travail ni l'état « modifié ».
local reouverture = false
local AUTRES_FENETRES = { "SalleDuTempsJournal" }

local function OuvrirGrimoire()
    local etaitModifie = modifie
    local ouvertes = {}
    for _, nom in ipairs(AUTRES_FENETRES) do
        local f = _G[nom]
        if f and f:IsShown() then ouvertes[#ouvertes + 1] = f end
    end
    reouverture = true
    local ouvert = false
    if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then
        ouvert = pcall(PlayerSpellsUtil.ToggleSpellBookFrame)
    end
    if not ouvert and ToggleSpellBook then pcall(ToggleSpellBook, BOOKTYPE_SPELL or "spell") end
    C_Timer.After(0.05, function()
        reouverture = false
        for _, f in ipairs(ouvertes) do
            if not f:IsShown() then f:Show() end
        end
        if UI.RafraichirJournal then UI.RafraichirJournal() end
        if editeur and not editeur:IsShown() then
            editeur:Show()
            modifie = etaitModifie
            Rafraichir()
        end
        if editeur then editeur:Raise() end
    end)
end

-- Durée d'un DoT, saisie au clic droit sur son type.
StaticPopupDialogs["SALLEDUTEMPS_DUREE_DOT"] = {
    text = "Durée du DoT « %s » (en secondes) :",
    button1 = "Valider",
    button2 = "Annuler",
    hasEditBox = 1,
    maxLetters = 5,
    OnShow = function(self, data)
        data = data or self.data
        local champ = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
        local e = data and etapes[data.index]
        if champ and e then
            champ:SetText(tostring(e.dot or ""))
            champ:HighlightText()
        end
    end,
    OnAccept = function(self, data)
        data = data or self.data
        local champ = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
        local e = data and etapes[data.index]
        local duree = champ and tonumber((champ:GetText() or ""):gsub(",", ".") .. "")   -- sans base : accepte 12.5
        if e and duree and duree > 0 and duree <= 600 then
            e.dot = duree
            e.typeChoisi = true
            Modifier()
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialogue = self:GetParent()
        StaticPopupDialogs["SALLEDUTEMPS_DUREE_DOT"].OnAccept(dialogue, dialogue.data)
        dialogue:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- ---------------------------------------------------------------------
-- Lignes de la liste
-- ---------------------------------------------------------------------
local lignes = {}

local function Fleche(parent, sens)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 18)
    local base = "Interface\\ChatFrame\\UI-ChatIcon-Scroll" .. sens
    b:SetNormalTexture(base .. "-Up")
    b:SetPushedTexture(base .. "-Down")
    b:SetDisabledTexture(base .. "-Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    return b
end

local function CreerLigne(parent, i)
    local l = CreateFrame("Button", nil, parent)
    l:SetSize(480, HAUTEUR_LIGNE - 2)
    l:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * HAUTEUR_LIGNE)
    l.index = i
    local fond = l:CreateTexture(nil, "BACKGROUND")
    fond:SetAllPoints()
    fond:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0.06)
    local survol = l:CreateTexture(nil, "HIGHLIGHT")
    survol:SetAllPoints()
    survol:SetColorTexture(1, 1, 1, 0.06)

    l.haut = Fleche(l, "Up")
    l.haut:SetPoint("LEFT", l, "LEFT", 2, 0)
    l.haut:SetScript("OnClick", function() Deplacer(l.index, l.index - 1) end)
    l.bas = Fleche(l, "Down")
    l.bas:SetPoint("LEFT", l, "LEFT", 20, 0)
    l.bas:SetScript("OnClick", function() Deplacer(l.index, l.index + 1) end)

    l.numero = Texte(l, "GameFontDisableSmall", "LEFT", l, "LEFT", 42, 0, 20)
    l.icone = l:CreateTexture(nil, "ARTWORK")
    l.icone:SetSize(20, 20)
    l.icone:SetPoint("LEFT", l, "LEFT", 62, 0)
    l.icone:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    l.touche = Texte(l, "GameFontHighlightSmall", "LEFT", l, "LEFT", 88, 0, 48)
    l.nom = Texte(l, "GameFontHighlightSmall", "LEFT", l, "LEFT", 140, 0, 170)

    -- Clic : type suivant. Clic droit sur un DoT : modifier sa durée.
    l.type = Bouton(l, "", 100, 20)
    l.type:SetPoint("LEFT", l, "LEFT", 314, 0)
    l.type:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    l.type:SetScript("OnClick", function(_, bouton)
        local e = etapes[l.index]
        if not e then return end
        if bouton == "RightButton" then
            if e.type == "dot" then
                StaticPopup_Show("SALLEDUTEMPS_DUREE_DOT", ns.Capture.NomSort(e.id), nil, { index = l.index })
            end
            return
        end
        local suivant = 1
        for k, t in ipairs(TYPES) do
            if t == e.type then suivant = k % #TYPES + 1 end
        end
        e.type = TYPES[suivant]
        e.typeChoisi = true   -- choix du joueur : la reconnaissance automatique des DoT ne le change plus
        if (e.type == "cast" or e.type == "canal") and (e.d or 0) == 0 then e.d = DureeIncantation(e.id) end
        if e.type == "dot" then
            e.dot = e.dot or ns.Capture.DureeDot(e.id) or DUREE_DOT_DEFAUT
            if (e.d or 0) == 0 then e.d = DureeIncantation(e.id) end
        end
        Modifier()
    end)
    l.type:SetScript("OnEnter", function(self)
        local e = etapes[l.index]
        if not (e and e.type == "dot") then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("DoT : rejoué à son expiration")
        GameTooltip:AddLine("Clic droit : modifier la durée", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    l.type:SetScript("OnLeave", function() GameTooltip:Hide() end)

    l.actif = CreateFrame("CheckButton", nil, l, "UICheckButtonTemplate")
    l.actif:SetSize(22, 22)
    l.actif:SetPoint("LEFT", l, "LEFT", 420, 0)
    l.actif:SetScript("OnClick", function(self)
        local e = etapes[l.index]
        if e then e.actif = self:GetChecked() and true or false Modifier() end
    end)

    l.retirer = Bouton(l, "X", 24, 20)
    l.retirer:SetPoint("LEFT", l, "LEFT", 450, 0)
    l.retirer:SetScript("OnClick", function()
        table.remove(etapes, l.index)
        Modifier()
    end)

    -- Info-bulle du sort et glisser-déposer pour réordonner.
    l:SetScript("OnEnter", function(self)
        local e = etapes[self.index]
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if not pcall(GameTooltip.SetSpellByID, GameTooltip, e.id) then GameTooltip:SetText(ns.Capture.NomSort(e.id)) end
        GameTooltip:AddLine("Glisser pour déplacer", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    l:SetScript("OnLeave", function() GameTooltip:Hide() end)
    l:RegisterForDrag("LeftButton")
    l:SetScript("OnDragStart", function(self)
        glisse = self.index
        self:SetAlpha(0.5)
        GameTooltip:Hide()
    end)
    l:SetScript("OnDragStop", function(self)
        self:SetAlpha(1)
        local de = glisse
        glisse = nil
        for _, autre in ipairs(lignes) do
            if autre:IsShown() and autre:IsMouseOver() then
                Deplacer(de, autre.index)
                return
            end
        end
    end)
    -- Un sort du grimoire lâché sur une ligne est ajouté à la fin.
    l:SetScript("OnReceiveDrag", function() AjouterSort(SortDuCurseur()) end)
    return l
end

local function RemplirLignes()
    local contenu = editeur.contenu
    for i, e in ipairs(etapes) do
        local l = lignes[i]
        if not l then
            l = CreerLigne(contenu, i)
            lignes[i] = l
        end
        l.numero:SetText(i .. ".")
        l.icone:SetTexture(IconeSort(e.id))
        l.icone:SetDesaturated(not e.actif)
        l.touche:SetText(Touche(e.id))
        l.nom:SetText(ns.Capture.NomSort(e.id))
        l.nom:SetTextColor(e.actif and 1 or 0.5, e.actif and 1 or 0.5, e.actif and 1 or 0.5)
        local libelle = LIBELLES[e.type] or e.type
        if e.type == "dot" then
            libelle = string.format("DoT %s s", Nombre(e.dot or 0, (e.dot or 0) % 1 == 0 and 0 or 1))
        elseif (e.type == "cast" or e.type == "canal") and (e.d or 0) > 0 then
            libelle = libelle .. " " .. Nombre(e.d, 1)
        end
        l.type:SetText(libelle)
        l.actif:SetChecked(e.actif)
        l.haut:SetEnabled(i > 1)
        l.bas:SetEnabled(i < #etapes)
        l:Show()
    end
    for i = #etapes + 1, #lignes do lignes[i]:Hide() end
    contenu:SetHeight(math.max(10, #etapes * HAUTEUR_LIGNE))
    editeur.vide:SetShown(#etapes == 0)
end

-- ---------------------------------------------------------------------
-- Aperçu et état
-- ---------------------------------------------------------------------
local function RemplirApercu()
    local ids = ns.Cycle.Actives(etapes)
    local legendes = {}
    for _, e in ipairs(etapes) do
        if e.actif then
            if e.type == "serie" then
                legendes[#legendes + 1] = "série"
            elseif e.type == "dot" then
                legendes[#legendes + 1] = "DoT"
            elseif (e.d or 0) > 0 then
                legendes[#legendes + 1] = Nombre(e.d, 1) .. " s"
            else
                legendes[#legendes + 1] = "inst."
            end
        end
    end
    for i, b in ipairs(editeur.apercu) do
        if ids[i] then
            b.tex:SetTexture(IconeSort(ids[i]))
            b.legende:SetText(legendes[i])
            b:Show()
        else
            b:Hide()
        end
    end
    local duree, actives, series = ns.Cycle.Estimer(etapes)
    local texte = string.format("%d étape%s active%s · durée estimée ≈ %s s", actives,
        actives > 1 and "s" or "", actives > 1 and "s" or "", Nombre(duree, 1))
    if series > 0 then texte = texte .. string.format(" + %d série%s de tirs", series, series > 1 and "s" or "") end
    if #ids > MAX_APERCU then texte = texte .. string.format(" (aperçu limité à %d)", MAX_APERCU) end
    editeur.resume:SetText(texte)
end

local function RemplirEtat()
    local _, s = Session()
    if modifie then
        editeur.etat:SetText("|cffff9933Modifié · non enregistré|r")
    elseif s and s.cycleEdite then
        editeur.etat:SetText("|cff66ff66Version éditée enregistrée|r le " .. (s.cycleEdite.date or "?"))
    else
        editeur.etat:SetText("|cff999999Version détectée (aucune modification enregistrée)|r")
    end
end

Rafraichir = function()
    if not editeur then return end
    RemplirApercu()
    RemplirLignes()
    RemplirEtat()
end

-- ---------------------------------------------------------------------
-- Fenêtre
-- ---------------------------------------------------------------------
local function CreerEditeur()
    local f
    local natif = pcall(function() f = CreateFrame("Frame", "SalleDuTempsEditeur", UIParent, "BasicFrameTemplateWithInset") end)
    if not (natif and f) then
        natif = false
        f = CreateFrame("Frame", "SalleDuTempsEditeur", UIParent)
        local fond = f:CreateTexture(nil, "BACKGROUND")
        fond:SetAllPoints()
        fond:SetColorTexture(0.05, 0.05, 0.08, 0.93)
        pcall(function()
            local fermer = CreateFrame("Button", nil, f, "UIPanelCloseButton")
            f.CloseButton = fermer
            fermer:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        end)
    end
    f:SetSize(LARGEUR, HAUTEUR)
    ns.FermetureDirecte(f)   -- la croix doit marcher en combat
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() UI.SauverPositionCycle(self) end)
    if UISpecialFrames then table.insert(UISpecialFrames, "SalleDuTempsEditeur") end
    f.titre = natif and (f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)) or nil
    if not (f.titre and f.titre.SetText) then f.titre = Texte(f, "GameFontNormal", "TOP", f, "TOP", 0, -6) end

    -- Aperçu de la partition
    local lApercu = Texte(f, "GameFontNormal", "TOPLEFT", f, "TOPLEFT", 18, -32)
    lApercu:SetText("Aperçu")
    f.apercu = {}
    for i = 1, MAX_APERCU do
        local b = CreateFrame("Frame", nil, f)
        b:SetSize(28, 28)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 18 + (i - 1) * 31, -50)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.legende = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.legende:SetPoint("TOP", b, "BOTTOM", 0, -2)
        f.apercu[i] = b
    end
    f.resume = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", 18, -98, 500)
    f.etat = Texte(f, "GameFontNormalSmall", "TOPLEFT", f, "TOPLEFT", 18, -116, 500)

    -- En-têtes de la liste
    local COLONNES = { { "Touche", 104 }, { "Sort", 156 }, { "Type", 330 }, { "Actif", 432 } }
    for _, c in ipairs(COLONNES) do
        local fs = Texte(f, "GameFontDisableSmall", "TOPLEFT", f, "TOPLEFT", c[2], -138)
        fs:SetText(c[1])
    end

    -- Liste défilante
    local defil
    local ok = pcall(function()
        defil = CreateFrame("ScrollFrame", "SalleDuTempsEditeurDefil", f, "UIPanelScrollFrameTemplate")
    end)
    if not (ok and defil) then
        defil = CreateFrame("ScrollFrame", "SalleDuTempsEditeurDefil", f)
        defil:EnableMouseWheel(true)
        defil:SetScript("OnMouseWheel", function(self, delta)
            local max = self:GetVerticalScrollRange()
            self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * HAUTEUR_LIGNE)))
        end)
    end
    defil:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -154)
    defil:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 150)
    local contenu = CreateFrame("Frame", nil, defil)
    contenu:SetSize(480, 10)
    defil:SetScrollChild(contenu)
    f.contenu = contenu
    f.vide = Texte(f, "GameFontDisable", "TOPLEFT", f, "TOPLEFT", 24, -170, 480)
    f.vide:SetText("Aucune étape : ajoute des sorts depuis le grimoire.")

    -- Zone d'ajout depuis le grimoire
    local zone = CreateFrame("Button", nil, f)
    zone:SetSize(LARGEUR - 36, 40)
    zone:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 100)
    local fondZone = zone:CreateTexture(nil, "BACKGROUND")
    fondZone:SetAllPoints()
    fondZone:SetColorTexture(0.3, 0.6, 1, 0.08)
    local survolZone = zone:CreateTexture(nil, "HIGHLIGHT")
    survolZone:SetAllPoints()
    survolZone:SetColorTexture(0.3, 0.6, 1, 0.12)
    local lZone = Texte(zone, "GameFontHighlightSmall", "LEFT", zone, "LEFT", 10, 0, 330)
    lZone:SetText("Glisse ici un sort du grimoire pour l'ajouter au cycle.")
    zone:SetScript("OnReceiveDrag", function() AjouterSort(SortDuCurseur()) end)
    zone:SetScript("OnMouseUp", function() AjouterSort(SortDuCurseur()) end)
    local grimoire = Bouton(zone, "Grimoire", 100)
    grimoire:SetPoint("RIGHT", zone, "RIGHT", -8, 0)
    grimoire:SetScript("OnClick", OuvrirGrimoire)

    local rappel = Texte(f, "GameFontDisableSmall", "BOTTOMLEFT", f, "BOTTOMLEFT", 18, 52, 500)
    rappel:SetText("Pense à valider ce cycle par une session (l'essai guidé arrivera au jalon 6).")

    -- Boutons
    local auto = Bouton(f, "Version auto", 110)
    auto:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 16)
    auto:SetScript("OnClick", function()
        local _, s = Session()
        if not s then return end
        etapes = ns.Cycle.Etapes(ns.Data.Cycle(s), s.sorts, ns.Capture.DureeDot)
        Modifier()
    end)

    local enregistrer = Bouton(f, "Enregistrer", 110)
    enregistrer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    enregistrer:SetScript("OnClick", function()
        local numero, s = Session()
        if not numero then return end
        ns.Data.EnregistrerEdition(numero, etapes)
        modifie = false
        ns.Print(string.format("Version éditée de « %s » enregistrée.", ns.Data.Nom(s, numero)))
        if UI.RafraichirJournal then UI.RafraichirJournal() end
        UI.ModeConsultation()
    end)

    local annuler = Bouton(f, "Annuler", 110)
    annuler:SetPoint("RIGHT", enregistrer, "LEFT", -8, 0)
    annuler:SetScript("OnClick", function() UI.ModeConsultation() end)

    -- La croix ou Échap ferment la page ; Annuler et Enregistrer reviennent à la Consultation.
    f:SetScript("OnHide", function()
        if reouverture then return end   -- fermeture provoquée par l'ouverture du grimoire
        if modifie then ns.Print("Modifications du cycle abandonnées.") end
        modifie = false
        if versConsultation then
            versConsultation = false
            local numero = Session()
            if numero then UI.OuvrirCycle(numero) end
        end
    end)
    f:Hide()
    editeur = f
end

-- Quitte le mode Édition pour la Consultation de la même session (les modifications non enregistrées
-- sont abandonnées).
function UI.ModeConsultation()
    if not (editeur and editeur:IsShown()) then return end
    versConsultation = true
    editeur:Hide()
end

-- Ouvre la session n° numero en mode Édition (même position et même taille que la Consultation).
function UI.OuvrirEditeur(numero)
    local s = ns.Data.Sessions()[numero]
    if not s then return end
    if not editeur then CreerEditeur() end
    if editeur:IsShown() then editeur:Hide() end
    -- Une seule vue de la page à la fois.
    local consultation = _G["SalleDuTempsCycle"]
    if consultation and consultation:IsShown() then consultation:Hide() end
    uid = s.uid
    etapes = ns.Data.EtapesDeTravail(s)
    modifie = false
    touches = nil
    editeur.titre:SetText("Cycle - " .. ns.Data.Nom(s, numero))
    UI.PlacerFenetreCycle(editeur)
    editeur:Show()
    editeur:Raise()
    Rafraichir()
end
