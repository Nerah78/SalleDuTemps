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

-- Journal des cycles (jalon 4) : une carte par session (nom, date, type, partition miniature, DPS,
-- étapes, fiabilité, badges « Actif » et « Meilleur DPS »), filtres mono / multi, tri, menu « … »,
-- sélection de 2 cycles pour comparaison. Clic sur une carte : page Cycle.

local _, ns = ...

local UI = ns.UI or {}
ns.UI = UI

local LARGEUR, HAUTEUR = 660, 540
local LARGEUR_CARTE, HAUTEUR_CARTE, ESPACE = 600, 64, 4
local MAX_MINIATURE = 12
local ICONE_INCONNUE = "Interface\\Icons\\INV_Misc_QuestionMark"

local journal, menu, comparaison
local cartes = {}
local filtre, tri = "tous", "date"
local tousPersonnages = false   -- par défaut, seules les sessions du personnage connecté
local selection = {}   -- uid des sessions cochées pour comparaison (2 au plus, dans l'ordre de sélection)

-- ---------------------------------------------------------------------
-- Utilitaires
-- ---------------------------------------------------------------------
local function Nombre(x, decimales)
    return (string.format("%." .. (decimales or 0) .. "f", x):gsub("%.", ","))
end

local function Pourcent(x) return string.format("%d %%", math.floor(x * 100 + 0.5)) end

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

-- strate : le journal est la fenêtre de fond ("HIGH") ; la page Cycle, la comparaison, le panneau
-- de session et les confirmations ("DIALOG") passent toujours au-dessus.
local function Fenetre(nom, largeur, hauteur, strate)
    local f
    local natif = pcall(function() f = CreateFrame("Frame", nom, UIParent, "BasicFrameTemplateWithInset") end)
    if not (natif and f) then
        natif = false
        f = CreateFrame("Frame", nom, UIParent)
        local fond = f:CreateTexture(nil, "BACKGROUND")
        fond:SetAllPoints()
        fond:SetColorTexture(0.05, 0.05, 0.08, 0.93)
        pcall(function()
            local fermer = CreateFrame("Button", nil, f, "UIPanelCloseButton")
            f.CloseButton = fermer
            fermer:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        end)
    end
    f:SetSize(largeur, hauteur)
    ns.FermetureDirecte(f)   -- la croix doit marcher en combat
    f:SetFrameStrata(strate or "DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if UISpecialFrames then table.insert(UISpecialFrames, nom) end
    f.titre = natif and (f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)) or nil
    if not (f.titre and f.titre.SetText) then f.titre = Texte(f, "GameFontNormal", "TOP", f, "TOP", 0, -6) end
    f:Hide()
    return f
end

local function NumeroParUid(uid)
    for i, s in ipairs(ns.Data.Sessions()) do
        if s.uid == uid then return i, s end
    end
end

-- ---------------------------------------------------------------------
-- Liste affichée : filtre puis tri
-- ---------------------------------------------------------------------
local function Liste()
    local liste = {}
    for i, s in ipairs(ns.Data.Sessions()) do
        if (filtre == "tous" or s.type == filtre) and (tousPersonnages or ns.Data.EstAMoi(s)) then
            liste[#liste + 1] = { numero = i, s = s }
        end
    end
    local function Valeur(x)
        if tri == "dps" then return x.s.dps or -1 end
        if tri == "fiabilite" then
            local c = ns.Data.Cycle(x.s)
            return c and c.fiabilite or -1
        end
        return x.s.horodatage or 0
    end
    table.sort(liste, function(a, b)
        local va, vb = Valeur(a), Valeur(b)
        if va ~= vb then return va > vb end
        return a.numero > b.numero
    end)
    return liste
end

-- ---------------------------------------------------------------------
-- Fenêtres de confirmation (renommer, supprimer)
-- ---------------------------------------------------------------------
local function ChampSaisie(dialogue)
    return dialogue.editBox or dialogue.EditBox or (dialogue.GetEditBox and dialogue:GetEditBox())
end

StaticPopupDialogs["SALLEDUTEMPS_RENOMMER"] = {
    text = "Nouveau nom du cycle :",
    button1 = "Renommer",
    button2 = "Annuler",
    hasEditBox = 1,
    maxLetters = 40,
    OnShow = function(self, data)
        data = data or self.data
        local champ = ChampSaisie(self)
        if champ and data then
            champ:SetText(data.nom or "")
            champ:HighlightText()
        end
    end,
    OnAccept = function(self, data)
        data = data or self.data
        local champ = ChampSaisie(self)
        local numero = data and NumeroParUid(data.uid)
        if champ and numero then
            ns.Data.Renommer(numero, champ:GetText())
            UI.RafraichirJournal()
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialogue = self:GetParent()
        StaticPopupDialogs["SALLEDUTEMPS_RENOMMER"].OnAccept(dialogue, dialogue.data)
        dialogue:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["SALLEDUTEMPS_SUPPRIMER"] = {
    text = "Supprimer « %s » ? Cette action est définitive.",
    button1 = "Supprimer",
    button2 = "Annuler",
    OnAccept = function(self, data)
        data = data or self.data
        local numero = data and NumeroParUid(data.uid)
        if numero then
            ns.Data.Supprimer(numero)
            for i, uid in ipairs(selection) do
                if uid == data.uid then table.remove(selection, i) break end
            end
            UI.RafraichirJournal()
            if UI.RafraichirCycle then UI.RafraichirCycle() end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
}

-- ---------------------------------------------------------------------
-- Menu « … » d'une carte
-- ---------------------------------------------------------------------
local ACTIONS = {
    { "ouvrir", "Ouvrir" },
    { "modifier", "Modifier le cycle" },
    { "ameliorer", "Améliorer" },
    { "progression", "Progression" },
    { "actif", "Définir comme actif" },
    { "dupliquer", "Dupliquer" },
    { "renommer", "Renommer" },
    { "supprimer", "Supprimer" },
}

local function Agir(action, uid)
    menu:Hide()
    local numero, s = NumeroParUid(uid)
    if not numero then return end
    if action == "ouvrir" then
        UI.OuvrirCycle(numero)
    elseif action == "modifier" then
        UI.OuvrirEditeur(numero)
    elseif action == "ameliorer" then
        if ns.Session.PreparerAmelioration(numero) then journal:Hide() end
    elseif action == "progression" then
        UI.OuvrirProgression(numero)
    elseif action == "actif" then
        local actif = ns.Data.BasculerActif(s)
        ns.Print(string.format("« %s » %s.", ns.Data.Nom(s, numero),
            actif and ("est le cycle actif (" .. (s.type == "multi" and "multi-cibles" or "mono-cible") .. ")") or "n'est plus actif"))
        UI.RafraichirJournal()
    elseif action == "dupliquer" then
        ns.Data.Dupliquer(numero)
        UI.RafraichirJournal()
    elseif action == "renommer" then
        StaticPopup_Show("SALLEDUTEMPS_RENOMMER", nil, nil, { uid = uid, nom = ns.Data.Nom(s, numero) })
    elseif action == "supprimer" then
        StaticPopup_Show("SALLEDUTEMPS_SUPPRIMER", ns.Data.Nom(s, numero), nil, { uid = uid })
    end
end

local function CreerMenu()
    local m = CreateFrame("Frame", nil, UIParent)
    m:SetSize(170, #ACTIONS * 20 + 8)
    m:SetFrameStrata("FULLSCREEN_DIALOG")
    local fond = m:CreateTexture(nil, "BACKGROUND")
    fond:SetAllPoints()
    fond:SetColorTexture(0.08, 0.08, 0.1, 0.97)
    m.entrees = {}
    for i, a in ipairs(ACTIONS) do
        local b = CreateFrame("Button", nil, m)
        b:SetSize(162, 20)
        b:SetPoint("TOPLEFT", m, "TOPLEFT", 4, -4 - (i - 1) * 20)
        b:SetNormalFontObject("GameFontHighlightSmall")
        b:SetDisabledFontObject("GameFontDisableSmall")
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:SetText(a[2])
        local fs = b:GetFontString()
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", b, "LEFT", 6, 0)
        b.action = a[1]
        b:SetScript("OnClick", function(self) Agir(self.action, m.uid) end)
        m.entrees[a[1]] = b
    end
    m:Hide()
    menu = m
end

local function OuvrirMenu(bouton, s)
    if not menu then CreerMenu() end
    if menu:IsShown() and menu.uid == s.uid then
        menu:Hide()
        return
    end
    menu.uid = s.uid
    menu.entrees.actif:SetText(ns.Data.EstActif(s) and "Retirer le statut actif" or "Définir comme actif")
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", bouton, "BOTTOMRIGHT", 0, -2)
    menu:Show()
end

-- ---------------------------------------------------------------------
-- Comparaison de deux cycles
-- ---------------------------------------------------------------------
local function CreerColonne(f, x)
    local c = {}
    c.nom = Texte(f, "GameFontNormal", "TOPLEFT", f, "TOPLEFT", x, -36, 200)
    c.infos = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", x, -56, 200)
    c.dps = Texte(f, "GameFontNormalLarge", "TOPLEFT", f, "TOPLEFT", x, -80, 200)
    c.cycle = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", x, -106, 200)
    c.fiabilite = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", x, -124, 200)
    c.icones = {}
    for i = 1, MAX_MINIATURE do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetSize(15, 15)
        t:SetPoint("TOPLEFT", f, "TOPLEFT", x + (i - 1) * 16, -146)
        t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        c.icones[i] = t
    end
    return c
end

local function RemplirColonne(c, numero, s)
    local r = ns.Data.Cycle(s)
    c.nom:SetText(ns.Data.Nom(s, numero))
    c.infos:SetText(string.format("%s · %s", s.date or "?", ns.Data.DureeTexte(s)))
    c.dps:SetText(s.dps and (Nombre(s.dps, 1) .. " DPS") or "DPS -")
    c.cycle:SetText(r and string.format("%d étapes · %s s", r.longueur, r.duree and Nombre(r.duree, 1) or "?") or "Aucun cycle")
    c.fiabilite:SetText(r and string.format("%d répétitions · fiabilité %s", r.repetitions, Pourcent(r.fiabilite)) or "")
    for i, t in ipairs(c.icones) do
        local id = r and r.cycle[i]
        if id then
            t:SetTexture(IconeSort(id))
            t:Show()
        else
            t:Hide()
        end
    end
end

local function OuvrirComparaison()
    if #selection < 2 then return end
    local nA, a = NumeroParUid(selection[1])
    local nB, b = NumeroParUid(selection[2])
    if not (nA and nB) then return end
    if not comparaison then
        comparaison = Fenetre("SalleDuTempsComparaison", 460, 220)
        comparaison:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
        comparaison.titre:SetText("Comparaison de deux cycles")
        comparaison.a = CreerColonne(comparaison, 20)
        comparaison.b = CreerColonne(comparaison, 240)
        comparaison.ecart = Texte(comparaison, "GameFontNormal", "BOTTOMLEFT", comparaison, "BOTTOMLEFT", 20, 18, 420)
    end
    RemplirColonne(comparaison.a, nA, a)
    RemplirColonne(comparaison.b, nB, b)
    if a.dps and b.dps and a.dps > 0 then
        local ecart = (b.dps - a.dps) / a.dps
        comparaison.ecart:SetText(string.format("Écart de DPS du second sur le premier : %s%s",
            ecart >= 0 and "+" or "", Pourcent(ecart)))
    else
        comparaison.ecart:SetText("Écart de DPS : indisponible")
    end
    comparaison:Show()
end

-- ---------------------------------------------------------------------
-- Cartes
-- ---------------------------------------------------------------------
local function MajSelection()
    journal.selection:SetText(string.format("Sélection pour comparaison : %d / 2", #selection))
    journal.comparer:SetEnabled(#selection == 2)
end

local function BasculerSelection(uid, coche)
    for i, u in ipairs(selection) do
        if u == uid then table.remove(selection, i) break end
    end
    if coche then
        selection[#selection + 1] = uid
        if #selection > 2 then table.remove(selection, 1) end
    end
    UI.RafraichirJournal()
end

local function CreerCarte(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(LARGEUR_CARTE, HAUTEUR_CARTE)
    c:RegisterForClicks("LeftButtonUp")
    local fond = c:CreateTexture(nil, "BACKGROUND")
    fond:SetAllPoints()
    fond:SetColorTexture(1, 1, 1, 0.05)
    local survol = c:CreateTexture(nil, "HIGHLIGHT")
    survol:SetAllPoints()
    survol:SetColorTexture(1, 1, 1, 0.07)

    c.case = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate")
    c.case:SetSize(24, 24)
    c.case:SetPoint("LEFT", c, "LEFT", 4, 0)
    c.case:SetScript("OnClick", function(self) BasculerSelection(c.uid, self:GetChecked()) end)

    c.nom = Texte(c, "GameFontNormal", "TOPLEFT", c, "TOPLEFT", 34, -7)
    c.badges = Texte(c, "GameFontHighlightSmall", "LEFT", c.nom, "RIGHT", 8, 0)
    c.infos = Texte(c, "GameFontHighlightSmall", "TOPLEFT", c, "TOPLEFT", 34, -25, 400)
    c.icones = {}
    for i = 1, MAX_MINIATURE do
        local t = c:CreateTexture(nil, "ARTWORK")
        t:SetSize(16, 16)
        t:SetPoint("TOPLEFT", c, "TOPLEFT", 34 + (i - 1) * 18, -41)
        t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        c.icones[i] = t
    end
    c.sansCycle = Texte(c, "GameFontDisableSmall", "TOPLEFT", c, "TOPLEFT", 34, -43)
    c.sansCycle:SetText("Aucun cycle détecté")

    c.dps = Texte(c, "GameFontNormalLarge", "TOPRIGHT", c, "TOPRIGHT", -40, -10)
    c.dps:SetJustifyH("RIGHT")
    c.resume = Texte(c, "GameFontHighlightSmall", "TOPRIGHT", c, "TOPRIGHT", -40, -34)
    c.resume:SetJustifyH("RIGHT")

    c.plus = Bouton(c, "...", 28, 20)
    c.plus:SetPoint("TOPRIGHT", c, "TOPRIGHT", -6, -6)
    c.plus:SetScript("OnClick", function(self)
        local _, s = NumeroParUid(c.uid)
        if s then OuvrirMenu(self, s) end
    end)

    c:SetScript("OnClick", function()
        if menu then menu:Hide() end
        local numero = NumeroParUid(c.uid)
        if numero then UI.OuvrirCycle(numero) end
    end)
    return c
end

local function RemplirCarte(c, numero, s)
    c.uid = s.uid
    local r = ns.Data.Cycle(s)
    c.nom:SetText(ns.Data.Nom(s, numero))
    local badges = {}
    if ns.Data.EstActif(s) then badges[#badges + 1] = "|cff66ff66Actif|r" end
    if ns.Data.EstMeilleurDPS(s) then badges[#badges + 1] = "|cffffd100Meilleur DPS|r" end
    if s.cycleEdite then badges[#badges + 1] = "|cff66ccffÉdité|r" end
    c.badges:SetText(table.concat(badges, "  "))
    c.infos:SetText(string.format("%s%s · %s · %s · %s",
        tousPersonnages and ((s.personnage or s.classe or "?") .. " · ") or "", s.date or "?",
        s.type == "multi" and "Multi-cibles" or "Mono-cible", s.cible or "?", ns.Data.DureeTexte(s)))
    -- Partition miniature : la version éditée si elle existe, sinon le cycle détecté.
    local ids = s.cycleEdite and ns.Cycle.Actives(s.cycleEdite.etapes) or (r and r.cycle)
    for i, t in ipairs(c.icones) do
        local id = ids and ids[i]
        if id then
            t:SetTexture(IconeSort(id))
            t:Show()
        else
            t:Hide()
        end
    end
    c.sansCycle:SetShown(ids == nil or #ids == 0)
    c.dps:SetText(s.dps and (Nombre(s.dps, 1) .. " DPS") or "DPS -")
    c.resume:SetText(r and string.format("%d étapes · %s", r.longueur, Pourcent(r.fiabilite)) or "")
    local coche = false
    for _, uid in ipairs(selection) do if uid == s.uid then coche = true end end
    c.case:SetChecked(coche)
end

-- ---------------------------------------------------------------------
-- Fenêtre du journal
-- ---------------------------------------------------------------------
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

local function CreerJournal()
    local f = Fenetre("SalleDuTempsJournal", LARGEUR, HAUTEUR, "HIGH")
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    f.titre:SetText("La Salle du Temps - Journal des cycles")

    -- Filtres
    local lFiltre = Texte(f, "GameFontNormalSmall", "TOPLEFT", f, "TOPLEFT", 18, -38)
    lFiltre:SetText("Afficher")
    f.filtres = {}
    for i, v in ipairs({ { "tous", "Tous" }, { "mono", "Mono" }, { "multi", "Multi" } }) do
        local b = Bouton(f, v[2], 58)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 70 + (i - 1) * 60, -32)
        b.valeur = v[1]
        b:SetScript("OnClick", function() filtre = v[1] UI.RafraichirJournal() end)
        f.filtres[i] = b
    end

    -- Tri
    local lTri = Texte(f, "GameFontNormalSmall", "TOPLEFT", f, "TOPLEFT", 270, -38)
    lTri:SetText("Trier")
    f.tris = {}
    for i, v in ipairs({ { "date", "Date" }, { "dps", "DPS" }, { "fiabilite", "Fiabilité" } }) do
        local b = Bouton(f, v[2], 66)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 306 + (i - 1) * 68, -32)
        b.valeur = v[1]
        b:SetScript("OnClick", function() tri = v[1] UI.RafraichirJournal() end)
        f.tris[i] = b
    end

    local nouvelle = Bouton(f, "Nouvelle session", 120)
    nouvelle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -32)
    nouvelle:SetScript("OnClick", function()
        f:Hide()
        UI.BasculerPanneau()
    end)

    -- Comparaison
    f.selection = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", 18, -66)
    f.comparer = Bouton(f, "Comparer", 90)
    f.comparer:SetPoint("TOPLEFT", f, "TOPLEFT", 220, -61)

    -- Sessions de tous les personnages du compte (la sauvegarde est commune) ou seulement du personnage connecté.
    local tous = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    tous:SetSize(24, 24)
    tous:SetPoint("TOPLEFT", f, "TOPLEFT", 330, -60)
    tous:SetScript("OnClick", function(self)
        tousPersonnages = self:GetChecked() and true or false
        UI.RafraichirJournal()
    end)
    local lTous = Texte(f, "GameFontHighlightSmall", "LEFT", tous, "RIGHT", 2, 0)
    lTous:SetText("Tous les personnages")
    f.comparer:SetScript("OnClick", OuvrirComparaison)
    f.vide = Texte(f, "GameFontDisable", "TOPLEFT", f, "TOPLEFT", 24, -110, 600)
    f.vide:SetText("Aucune session pour ce personnage : lance une nouvelle session pour commencer.")

    -- Liste défilante
    local defil
    local ok = pcall(function()
        defil = CreateFrame("ScrollFrame", "SalleDuTempsJournalDefil", f, "UIPanelScrollFrameTemplate")
    end)
    if not (ok and defil) then
        defil = CreateFrame("ScrollFrame", "SalleDuTempsJournalDefil", f)
        defil:EnableMouseWheel(true)
        defil:SetScript("OnMouseWheel", function(self, delta)
            local max = self:GetVerticalScrollRange()
            self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 40)))
        end)
    end
    defil:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -92)
    defil:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 14)
    local contenu = CreateFrame("Frame", nil, defil)
    contenu:SetSize(LARGEUR_CARTE, 10)
    defil:SetScrollChild(contenu)
    f.contenu = contenu

    f:SetScript("OnHide", function() if menu then menu:Hide() end end)
    journal = f
end

function UI.RafraichirJournal()
    if not (journal and journal:IsShown()) then return end
    if menu then menu:Hide() end
    MarquerChoix(journal.filtres, filtre)
    MarquerChoix(journal.tris, tri)
    -- Retire de la sélection les sessions disparues.
    for i = #selection, 1, -1 do
        if not NumeroParUid(selection[i]) then table.remove(selection, i) end
    end
    MajSelection()

    local liste = Liste()
    journal.vide:SetShown(#liste == 0)
    for i, x in ipairs(liste) do
        local c = cartes[i]
        if not c then
            c = CreerCarte(journal.contenu)
            c:SetPoint("TOPLEFT", journal.contenu, "TOPLEFT", 0, -(i - 1) * (HAUTEUR_CARTE + ESPACE))
            cartes[i] = c
        end
        RemplirCarte(c, x.numero, x.s)
        c:Show()
    end
    for i = #liste + 1, #cartes do cartes[i]:Hide() end
    journal.contenu:SetHeight(math.max(10, #liste * (HAUTEUR_CARTE + ESPACE)))
end

function UI.BasculerJournal()
    if not journal then CreerJournal() end
    if journal:IsShown() then
        journal:Hide()
    else
        journal:Show()
        UI.RafraichirJournal()
    end
end
