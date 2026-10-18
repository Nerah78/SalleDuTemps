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

-- Page Cycle (version simple, jalon 3) : chiffres clés, ouverture, cycle, écarts, détail par sort.
-- Ouverte à la fin d'une session ou par /sdt cycle [n].

local _, ns = ...

local UI = ns.UI or {}
ns.UI = UI

local GCD = 1.5               -- durée comptée pour un sort instantané (temps de recharge global)
local MAX_OUVERTURE = 10
local MAX_CYCLE = 12
local MAX_LIGNES = 8
local ICONE_INCONNUE = "Interface\\Icons\\INV_Misc_QuestionMark"

local page
local uidCourant     -- session affichée
local vue = "edite"  -- partition affichée : "edite" (si une version éditée existe) ou "detecte"

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

-- Icône de sort avec info-bulle.
local function CreerIcone(parent, taille)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(taille, taille)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.legende = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.legende:SetPoint("TOP", b, "BOTTOM", 0, -2)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local ok = self.id and pcall(GameTooltip.SetSpellByID, GameTooltip, self.id)
        if not ok then GameTooltip:SetText(ns.Capture.NomSort(self.id)) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function RemplirRangee(icones, ids, legendes)
    for i, b in ipairs(icones) do
        local id = ids and ids[i]
        if id then
            b.id = id
            b.tex:SetTexture(IconeSort(id))
            b.legende:SetText(legendes and legendes[i] or "")
            b:Show()
        else
            b:Hide()
        end
    end
end

-- ---------------------------------------------------------------------
-- Page Cycle à deux modes : Consultation (ce fichier) et Édition (Editeur.lua), même taille et même
-- position. On passe en Édition par « Modifier le cycle », on revient par « Annuler » ou « Enregistrer ».
-- ---------------------------------------------------------------------
UI.LARGEUR_CYCLE, UI.HAUTEUR_CYCLE = 540, 600

function UI.PlacerFenetreCycle(f)
    local p = ns.db.fenetreCycle
    f:ClearAllPoints()
    if p then
        f:SetPoint(p.point, UIParent, p.pointRelatif, p.x, p.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    end
end

function UI.SauverPositionCycle(f)
    local point, _, pointRelatif, x, y = f:GetPoint()
    ns.db.fenetreCycle = { point = point, pointRelatif = pointRelatif, x = x, y = y }
end


-- Passe la session affichée en mode Édition (même position, même taille).
function UI.ModeEdition()
    for i, s in ipairs(ns.Data.Sessions()) do
        if s.uid == uidCourant then
            page:Hide()
            UI.OuvrirEditeur(i)
            return
        end
    end
end

-- ---------------------------------------------------------------------
-- Construction de la page
-- ---------------------------------------------------------------------
local function Bloc(parent, x)
    local valeur = Texte(parent, "GameFontNormalLarge", "TOPLEFT", parent, "TOPLEFT", x, -58, 150)
    local libelle = Texte(parent, "GameFontHighlightSmall", "TOPLEFT", parent, "TOPLEFT", x, -80, 150)
    return valeur, libelle
end

local function CreerPage()
    local f
    local natif = pcall(function() f = CreateFrame("Frame", "SalleDuTempsCycle", UIParent, "BasicFrameTemplateWithInset") end)
    if not (natif and f) then
        natif = false
        f = CreateFrame("Frame", "SalleDuTempsCycle", UIParent)
        local fond = f:CreateTexture(nil, "BACKGROUND")
        fond:SetAllPoints()
        fond:SetColorTexture(0.05, 0.05, 0.08, 0.93)
        pcall(function()
            local fermer = CreateFrame("Button", nil, f, "UIPanelCloseButton")
            f.CloseButton = fermer
            fermer:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        end)
    end
    f:SetSize(UI.LARGEUR_CYCLE, UI.HAUTEUR_CYCLE)
    ns.FermetureDirecte(f)   -- la croix doit marcher en combat
    f:SetFrameStrata("DIALOG")   -- au-dessus du journal (HIGH)
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() UI.SauverPositionCycle(self) end)
    if UISpecialFrames then table.insert(UISpecialFrames, "SalleDuTempsCycle") end

    f.titre = natif and (f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)) or nil
    if not (f.titre and f.titre.SetText) then f.titre = Texte(f, "GameFontNormal", "TOP", f, "TOP", 0, -6) end

    -- Même page que l'éditeur, en mode Consultation.
    local corps = CreateFrame("Frame", nil, f)
    corps:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    corps:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)

    f.sousTitre = Texte(corps, "GameFontHighlightSmall", "TOPLEFT", corps, "TOPLEFT", 18, -32, 464)

    -- Chiffres clés
    f.dps, f.dpsLibelle = Bloc(corps, 18)
    f.cycle, f.cycleLibelle = Bloc(corps, 180)
    f.fiabilite, f.fiabiliteLibelle = Bloc(corps, 342)

    f.conseil = Texte(corps, "GameFontNormalSmall", "TOPLEFT", corps, "TOPLEFT", 18, -104, 464)
    f.conseil:SetTextColor(1, 0.6, 0.2)

    -- Ouverture et cycle
    f.lOuverture = Texte(corps, "GameFontNormal", "TOPLEFT", corps, "TOPLEFT", 18, -130)
    f.lOuverture:SetText("Ouverture")
    f.icOuverture = {}
    for i = 1, MAX_OUVERTURE do
        local b = CreerIcone(corps, 26)
        b:SetPoint("TOPLEFT", corps, "TOPLEFT", 18 + (i - 1) * 30, -148)
        f.icOuverture[i] = b
    end
    f.aucuneOuverture = Texte(corps, "GameFontDisableSmall", "TOPLEFT", corps, "TOPLEFT", 18, -155)
    f.aucuneOuverture:SetText("Aucune : le cycle commence dès le premier sort.")

    f.lCycle = Texte(corps, "GameFontNormal", "TOPLEFT", corps, "TOPLEFT", 18, -186)
    f.lCycle:SetText("Cycle")
    -- Bascule entre le cycle détecté et la version éditée (si elle existe).
    f.vues = {}
    for i, v in ipairs({ { "detecte", "Détecté" }, { "edite", "Édité" } }) do
        local b = CreateFrame("Button", nil, corps, "UIPanelButtonTemplate")
        b:SetSize(70, 18)
        b:SetText(v[2])
        b:SetPoint("TOPLEFT", corps, "TOPLEFT", 70 + (i - 1) * 72, -183)
        b.valeur = v[1]
        b:SetScript("OnClick", function() vue = v[1] UI.RafraichirCycle() end)
        f.vues[i] = b
    end
    f.icCycle = {}
    for i = 1, MAX_CYCLE do
        local b = CreerIcone(corps, 34)
        b:SetPoint("TOPLEFT", corps, "TOPLEFT", 18 + (i - 1) * 38, -204)
        f.icCycle[i] = b
    end

    f.ecarts = Texte(corps, "GameFontHighlightSmall", "TOPLEFT", corps, "TOPLEFT", 18, -262, 464)
    f.aucunCycle = Texte(corps, "GameFontDisable", "TOPLEFT", corps, "TOPLEFT", 18, -210, 464)
    f.aucunCycle:SetText("Aucun cycle détecté : session trop courte ou trop irrégulière.")

    -- Détail par sort
    local lDetail = Texte(corps, "GameFontNormal", "TOPLEFT", corps, "TOPLEFT", 18, -290)
    lDetail:SetText("Détail par sort")
    local COLONNES = { { "Sort", 40, 170 }, { "Dégâts", 214, 70 }, { "Part", 288, 50 }, { "Lancers", 342, 60 }, { "DPS / s d'incant.", 406, 90 } }
    for _, col in ipairs(COLONNES) do
        local fs = Texte(corps, "GameFontDisableSmall", "TOPLEFT", corps, "TOPLEFT", col[2], -310, col[3])
        fs:SetText(col[1])
    end
    f.lignes = {}
    for i = 1, MAX_LIGNES do
        local y = -326 - (i - 1) * 20
        local ligne = {}
        ligne.icone = corps:CreateTexture(nil, "ARTWORK")
        ligne.icone:SetSize(16, 16)
        ligne.icone:SetPoint("TOPLEFT", corps, "TOPLEFT", 18, y + 2)
        ligne.icone:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        ligne.cols = {}
        for k, col in ipairs(COLONNES) do
            ligne.cols[k] = Texte(corps, "GameFontHighlightSmall", "TOPLEFT", corps, "TOPLEFT", col[2], y, col[3])
        end
        f.lignes[i] = ligne
    end
    f.sansDetail = Texte(corps, "GameFontDisableSmall", "TOPLEFT", corps, "TOPLEFT", 18, -330, 464)
    f.sansDetail:SetText("Dégâts indisponibles (compteur de dégâts illisible).")

    -- Mode comparaison (session d'amélioration) : face à la référence, puis choix.
    f.cmpTitre = Texte(corps, "GameFontNormal", "TOPLEFT", corps, "TOPLEFT", 18, -486, 504)
    f.cmpDps = Texte(corps, "GameFontHighlightSmall", "TOPLEFT", corps, "TOPLEFT", 18, -504, 504)
    f.cmpRythme = Texte(corps, "GameFontHighlightSmall", "TOPLEFT", corps, "TOPLEFT", 18, -520, 504)
    f.cmpChoix = {}
    for i, c in ipairs({ { "version", "Nouvelle version", 150 }, { "remplacer", "Remplacer la référence", 170 }, { "ignorer", "Ignorer", 90 } }) do
        local b = CreateFrame("Button", nil, corps, "UIPanelButtonTemplate")
        b:SetSize(c[3], 22)
        b:SetText(c[2])
        b.valeur = c[1]
        f.cmpChoix[i] = b
    end
    f.cmpChoix[1]:SetPoint("TOPLEFT", corps, "TOPLEFT", 16, -538)
    f.cmpChoix[2]:SetPoint("LEFT", f.cmpChoix[1], "RIGHT", 8, 0)
    f.cmpChoix[3]:SetPoint("LEFT", f.cmpChoix[2], "RIGHT", 8, 0)
    for _, b in ipairs(f.cmpChoix) do
        b:SetScript("OnClick", function() UI.ChoixComparaison(b.valeur) end)
    end
    f.cmpDecision = Texte(corps, "GameFontDisableSmall", "TOPLEFT", corps, "TOPLEFT", 18, -542, 504)

    local modifier = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    modifier:SetSize(140, 22)
    modifier:SetText("Modifier le cycle")
    modifier:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
    modifier:SetScript("OnClick", function() UI.ModeEdition() end)

    -- Progression du cycle (Coach).
    local progression = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    progression:SetSize(120, 22)
    progression:SetText("Progression")
    progression:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    progression:SetScript("OnClick", function()
        local numero = ns.Data.NumeroParUid(uidCourant)
        if numero then UI.OuvrirProgression(numero) end
    end)

    -- Session d'amélioration à partir de ce cycle (partition fixe, timeline rythmique).
    local ameliorer = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ameliorer:SetSize(120, 22)
    ameliorer:SetText("Améliorer")
    ameliorer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 14)
    ameliorer:SetScript("OnClick", function()
        for i, s in ipairs(ns.Data.Sessions()) do
            if s.uid == uidCourant then
                if ns.Session.PreparerAmelioration(i) then f:Hide() end
                return
            end
        end
    end)

    f:Hide()
    page = f
end

-- ---------------------------------------------------------------------
-- Remplissage
-- ---------------------------------------------------------------------
local function RemplirDetail(s)
    local lignes = page.lignes
    local liste = {}
    if s.parSort and s.degats and s.degats > 0 then
        for id, montant in pairs(s.parSort) do liste[#liste + 1] = { id = id, montant = montant } end
        table.sort(liste, function(a, b) return a.montant > b.montant end)
    end
    -- Lancers et temps d'incantation par sort, d'après la séquence.
    local lancers, tempsIncant = {}, {}
    for _, e in ipairs(s.sorts or {}) do
        if e.ok and e.id then
            lancers[e.id] = (lancers[e.id] or 0) + 1
            tempsIncant[e.id] = (tempsIncant[e.id] or 0) + math.max(e.d or 0, GCD)
        end
    end
    -- Lancers rangés sous un autre identifiant que leurs dégâts (ex. tirs de baguette).
    for idLancer, idDegats in pairs(ns.Cycle.DEGATS_ASSOCIES) do
        if lancers[idLancer] then
            lancers[idDegats] = (lancers[idDegats] or 0) + lancers[idLancer]
            tempsIncant[idDegats] = (tempsIncant[idDegats] or 0) + tempsIncant[idLancer]
        end
    end
    page.sansDetail:SetShown(#liste == 0)
    for i, ligne in ipairs(lignes) do
        local x = liste[i]
        local visible = x ~= nil
        ligne.icone:SetShown(visible)
        for _, col in ipairs(ligne.cols) do col:SetShown(visible) end
        if visible then
            ligne.icone:SetTexture(IconeSort(x.id))
            ligne.cols[1]:SetText(ns.Capture.NomSort(x.id))
            ligne.cols[2]:SetText(tostring(x.montant))
            ligne.cols[3]:SetText(Pourcent(x.montant / s.degats))
            ligne.cols[4]:SetText(lancers[x.id] and tostring(lancers[x.id]) or "-")
            ligne.cols[5]:SetText(tempsIncant[x.id] and Nombre(x.montant / tempsIncant[x.id], 1) or "-")
        end
    end
end

-- Bloc de comparaison avec la référence (sessions d'amélioration seulement).
local function RemplirComparaison(s)
    local visible = s.reference ~= nil
    page.cmpTitre:SetShown(visible)
    page.cmpDps:SetShown(visible)
    page.cmpRythme:SetShown(visible)
    page.cmpDecision:SetShown(visible and s.decision ~= nil)
    for _, b in ipairs(page.cmpChoix) do b:SetShown(visible and s.decision == nil) end
    if not visible then return end

    page.cmpTitre:SetText("Comparaison avec « " .. (s.referenceNom or "la référence") .. " »")
    if s.dps and s.referenceDps and s.referenceDps > 0 then
        local ecart = (s.dps - s.referenceDps) / s.referenceDps
        local couleur = ecart >= 0 and "|cff66ff66" or "|cffff6666"
        page.cmpDps:SetText(string.format("DPS : %s contre %s pour la référence (%s%s%s|r)%s", Nombre(s.dps, 1),
            Nombre(s.referenceDps, 1), couleur, ecart >= 0 and "+" or "", Pourcent(ecart),
            s.ecourtee and " · session écourtée, peu comparable" or ""))
    else
        page.cmpDps:SetText("DPS : comparaison indisponible")
    end
    local j = s.jugement
    if j then
        page.cmpRythme:SetText(string.format("Rythme : précision %s · %d parfait, %d bien, %d juste, %d raté, %d interrompu · combo max %d%s",
            j.precision and Pourcent(j.precision) or "-", j.compte.parfait, j.compte.bien, j.compte.juste, j.compte.rate,
            j.compte.interrompu or 0, j.comboMax, j.compte.hors > 0 and string.format(" · %d hors partition", j.compte.hors) or ""))
    else
        page.cmpRythme:SetText("Rythme : non mesuré")
    end
    if s.decision == "version" then
        page.cmpDecision:SetText("Gardée comme nouvelle version.")
    elseif s.decision == "remplace" then
        page.cmpDecision:SetText("A remplacé la référence.")
    end
end

local function Remplir(numero, s)
    local r = s.cycle
    page.titre:SetText(string.format("Cycle - %s", ns.Data.Nom(s, numero)))
    page.sousTitre:SetText(string.format("%s · %s%s · %s%s", s.date or "?", s.cible or "?",
        s.mannequin and "" or " (pas un mannequin)", ns.Data.DureeTexte(s),
        (s.etiquette or "") ~= "" and (" · « " .. s.etiquette .. " »") or ""))

    -- DPS et écart avec la meilleure session
    if s.dps then
        page.dps:SetText(Nombre(s.dps, 1))
        local meilleur = ns.Data.MeilleurDPS(s.classe, s.type, s)
        if meilleur then
            local ecart = (s.dps - meilleur) / meilleur
            page.dpsLibelle:SetText(string.format("DPS · meilleur %s (%s%s)", Nombre(meilleur, 1), ecart >= 0 and "+" or "", Pourcent(ecart)))
        else
            page.dpsLibelle:SetText("DPS · première session de ce type")
        end
    else
        page.dps:SetText("-")
        page.dpsLibelle:SetText("DPS indisponible")
    end

    local conseil = ""
    if r then
        page.cycle:SetText(string.format("%d étape%s", r.longueur, r.longueur > 1 and "s" or ""))
        page.cycleLibelle:SetText(r.duree and ("cycle de " .. Nombre(r.duree, 1) .. " s") or "cycle")
        page.fiabilite:SetText(string.format("%d × · %s", r.repetitions, Pourcent(r.fiabilite)))
        page.fiabiliteLibelle:SetText("répétitions · fiabilité")
        if r.fiabilite < ns.Cycle.SEUIL_FIABILITE then
            conseil = "Fiabilité faible : le cycle est peut-être long (DoT de 15 s ou plus). Essaie une session de 2 min."
        end
    else
        page.cycle:SetText("-")
        page.cycleLibelle:SetText("aucun cycle")
        page.fiabilite:SetText("-")
        page.fiabiliteLibelle:SetText("répétitions · fiabilité")
        conseil = "Pas de cycle repéré : essaie une session plus longue, en gardant la même rotation."
    end
    page.conseil:SetText(conseil)

    -- Ouverture, cycle (détecté ou édité), écarts
    local edite = s.cycleEdite
    local montrerEdite = edite ~= nil and vue == "edite"
    page.lOuverture:SetShown(r ~= nil)
    page.lCycle:SetShown(r ~= nil or edite ~= nil)
    page.aucunCycle:SetShown(r == nil and not montrerEdite)
    page.ecarts:SetShown(r ~= nil or montrerEdite)
    page.aucuneOuverture:SetShown(r ~= nil and #r.ouverture == 0)
    for _, b in ipairs(page.vues) do
        b:SetShown(edite ~= nil)
        if (b.valeur == "edite") == montrerEdite then
            b:LockHighlight()
            b:SetAlpha(1)
        else
            b:UnlockHighlight()
            b:SetAlpha(0.45)
        end
    end
    RemplirRangee(page.icOuverture, r and r.ouverture)
    local legendes = {}
    if montrerEdite then
        -- Mêmes DoT reconnus que dans l'éditeur et la partition (description du sort).
        local etapesEditees = ns.Data.CompleterDots(edite.etapes)
        for _, e in ipairs(etapesEditees) do
            if e.actif then
                if e.type == "serie" then
                    legendes[#legendes + 1] = "série"
                elseif e.type == "dot" then
                    legendes[#legendes + 1] = "DoT " .. Nombre(e.dot or 0, 0) .. " s"
                else
                    legendes[#legendes + 1] = (e.d or 0) > 0 and (Nombre(e.d, 1) .. " s") or "inst."
                end
            end
        end
        local duree, actives, series = ns.Cycle.Estimer(etapesEditees)
        page.ecarts:SetText(string.format("Version éditée le %s · %d étapes actives · durée estimée ≈ %s s%s.",
            edite.date or "?", actives, Nombre(duree, 1),
            series > 0 and string.format(" + %d série%s de tirs", series, series > 1 and "s" or "") or ""))
        RemplirRangee(page.icCycle, ns.Cycle.Actives(etapesEditees), legendes)
    elseif r then
        -- Durée d'incantation de chaque sort du cycle, d'après la séquence.
        local duree = {}
        for _, e in ipairs(s.sorts or {}) do
            if e.ok and e.id and duree[e.id] == nil then duree[e.id] = e.d or 0 end
        end
        for i, id in ipairs(r.cycle) do
            local d = duree[id] or 0
            if ns.Cycle.SERIES[id] then
                legendes[i] = "série"
            else
                legendes[i] = d > 0 and (Nombre(d, 1) .. " s") or "inst."
            end
        end
        local inseres, omis = 0, 0
        for _, e in ipairs(r.ecarts) do
            if e.genre == "omis" then omis = omis + 1 else inseres = inseres + 1 end
        end
        page.ecarts:SetText(string.format("Écarts : %d (%d sort%s en trop, %d oublié%s) sur %d étapes jouées.",
            inseres + omis, inseres, inseres > 1 and "s" or "", omis, omis > 1 and "s" or "", r.nbSorts))
        RemplirRangee(page.icCycle, r.cycle, legendes)
    else
        RemplirRangee(page.icCycle, nil)
    end

    RemplirDetail(s)
    RemplirComparaison(s)
end

-- Ouvre la page Cycle d'une session (la dernière par défaut).
function UI.OuvrirCycle(numero)
    local sessions = ns.Data.Sessions()
    numero = numero or #sessions
    local s = sessions[numero]
    if not s then
        ns.Print(#sessions == 0 and "Aucune session enregistrée." or ("Pas de session n° " .. tostring(numero) .. "."))
        return
    end
    ns.Data.Cycle(s)
    if not page then CreerPage() end
    -- Une seule vue de la page à la fois : quitter l'édition (modifications non enregistrées abandonnées).
    local edition = _G["SalleDuTempsEditeur"]
    if edition and edition:IsShown() then edition:Hide() end
    if s.uid ~= uidCourant then vue = "edite" end   -- nouvelle session : version éditée d'abord
    uidCourant = s.uid
    Remplir(numero, s)
    UI.PlacerFenetreCycle(page)
    page:Show()
    page:Raise()
end

-- ---------------------------------------------------------------------
-- Choix du mode comparaison : nouvelle version, remplacer la référence, ignorer
-- ---------------------------------------------------------------------
-- Nom actuel de la référence (elle a pu être renommée), sinon celui figé au moment de la session.
local function NomReference(s)
    local numRef, ref = ns.Data.NumeroParUid(s.reference)
    if ref then return ns.Data.Nom(ref, numRef) end
    return s.referenceNom or "la référence"
end

local function AppliquerChoix(choix)
    local numero, s = ns.Data.NumeroParUid(uidCourant)
    if not numero then return end
    local nomRef = NomReference(s)
    ns.Data.DecisionComparaison(numero, choix)
    if choix == "version" then
        ns.Print(string.format("Session gardée comme nouvelle version : « %s ».", s.nom))
    elseif choix == "remplacer" then
        ns.Print(string.format("La session remplace « %s ».", nomRef))
    else
        ns.Print("Session d'amélioration ignorée et supprimée.")
    end
    UI.RafraichirCycle()
    if UI.RafraichirJournal then UI.RafraichirJournal() end
end

StaticPopupDialogs["SALLEDUTEMPS_REMPLACER"] = {
    text = "Remplacer « %s » par cette session ?\nL'ancienne référence sera supprimée.",
    button1 = "Remplacer",
    button2 = "Annuler",
    OnAccept = function() AppliquerChoix("remplacer") end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
}

StaticPopupDialogs["SALLEDUTEMPS_IGNORER"] = {
    text = "Ignorer cette session d'amélioration ?\nElle sera supprimée.",
    button1 = "Ignorer",
    button2 = "Annuler",
    OnAccept = function() AppliquerChoix("ignorer") end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function UI.ChoixComparaison(choix)
    local _, s = ns.Data.NumeroParUid(uidCourant)
    if not s then return end
    if choix == "remplacer" then
        StaticPopup_Show("SALLEDUTEMPS_REMPLACER", NomReference(s))
    elseif choix == "ignorer" then
        StaticPopup_Show("SALLEDUTEMPS_IGNORER")
    else
        AppliquerChoix(choix)
    end
end

-- Rafraîchit la page Cycle si elle est ouverte (après une édition, un changement de vue).
function UI.RafraichirCycle()
    if not (page and page:IsShown()) then return end
    for i, s in ipairs(ns.Data.Sessions()) do
        if s.uid == uidCourant then
            Remplir(i, s)
            return
        end
    end
    page:Hide()   -- session supprimée
end
