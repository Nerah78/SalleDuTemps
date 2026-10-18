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

-- Page Progression (Coach, jalon 8b) : courbe du DPS et de la précision d'un cycle (sessions, améliorations,
-- combats guidés), tendance récente, erreurs les plus fréquentes avec conseil.
-- Ouverte depuis la page Cycle (bouton « Progression ») ou le menu « … » du journal.

local _, ns = ...

local UI = ns.UI or {}
ns.UI = UI

local LARGEUR, HAUTEUR = 540, 580
local L_GRAPHE, H_GRAPHE = 440, 140
local MAX_POINTS = 20
local MAX_ERREURS = 5
local TENDANCE = 5
local OR = { 1, 0.82, 0 }
local VERT = { 0.4, 1, 0.4 }

local page

local function Nombre(x, decimales)
    return (string.format("%." .. (decimales or 0) .. "f", x):gsub("%.", ","))
end

local function Pourcent(x) return string.format("%d %%", math.floor(x * 100 + 0.5)) end

local function Texte(parent, police, point, relatif, pointRelatif, x, y, largeur)
    local fs = parent:CreateFontString(nil, "OVERLAY", police)
    fs:SetPoint(point, relatif, pointRelatif, x, y)
    fs:SetJustifyH("LEFT")
    if largeur then fs:SetWidth(largeur) end
    return fs
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------
-- sousNiveau : la précision est dessinée au-dessus du DPS (leurs points peuvent se superposer).
local function Serie(graphe, couleur, sousNiveau)
    local s = { points = {}, lignes = {} }
    for i = 1, MAX_POINTS do
        local p = graphe:CreateTexture(nil, "OVERLAY", nil, sousNiveau)
        p:SetSize(6, 6)
        p:SetColorTexture(couleur[1], couleur[2], couleur[3], 1)
        s.points[i] = p
        if graphe.CreateLine then
            local l = graphe:CreateLine(nil, "ARTWORK")
            l:SetThickness(2)
            l:SetColorTexture(couleur[1], couleur[2], couleur[3], 0.8)
            s.lignes[i] = l
        end
    end
    return s
end

local function CreerPage()
    local f
    local natif = pcall(function() f = CreateFrame("Frame", "SalleDuTempsProgression", UIParent, "BasicFrameTemplateWithInset") end)
    if not (natif and f) then
        natif = false
        f = CreateFrame("Frame", "SalleDuTempsProgression", UIParent)
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
    f:SetPoint("CENTER", UIParent, "CENTER", 60, 20)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if UISpecialFrames then table.insert(UISpecialFrames, "SalleDuTempsProgression") end
    f.titre = natif and (f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)) or nil
    if not (f.titre and f.titre.SetText) then f.titre = Texte(f, "GameFontNormal", "TOP", f, "TOP", 0, -6) end

    f.resume = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", 18, -32, 504)

    -- Graphe : DPS (axe de gauche, or) et précision (axe de droite, vert)
    local g = CreateFrame("Frame", nil, f)
    g:SetSize(L_GRAPHE, H_GRAPHE)
    g:SetPoint("TOPLEFT", f, "TOPLEFT", 50, -58)
    local fond = g:CreateTexture(nil, "BACKGROUND")
    fond:SetAllPoints()
    fond:SetColorTexture(1, 1, 1, 0.04)
    for k = 1, 3 do   -- repères horizontaux à 25, 50, 75 %
        local r = g:CreateTexture(nil, "BORDER")
        r:SetColorTexture(1, 1, 1, 0.08)
        r:SetHeight(1)
        r:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 0, H_GRAPHE * k / 4)
        r:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 0, H_GRAPHE * k / 4)
    end
    f.axeDps = Texte(f, "GameFontHighlightSmall", "TOPRIGHT", g, "TOPLEFT", -4, 0)
    f.axeDps:SetTextColor(OR[1], OR[2], OR[3])
    f.axePrec = Texte(f, "GameFontHighlightSmall", "TOPLEFT", g, "TOPRIGHT", 4, 0)
    f.axePrec:SetTextColor(VERT[1], VERT[2], VERT[3])
    f.axePrec:SetText("100 %")
    f.dateDebut = Texte(f, "GameFontDisableSmall", "TOPLEFT", g, "BOTTOMLEFT", 0, -4)
    f.dateFin = Texte(f, "GameFontDisableSmall", "TOPRIGHT", g, "BOTTOMRIGHT", 0, -4)
    f.dateFin:SetJustifyH("RIGHT")
    f.legende = Texte(f, "GameFontHighlightSmall", "TOP", g, "BOTTOM", 0, -20)
    f.legende:SetText("|cffffd100DPS|r · |cff66ff66Précision|r · gros points : sessions et améliorations, petits : combats guidés")
    f.legende:SetJustifyH("CENTER")
    f.vide = Texte(f, "GameFontDisable", "CENTER", g, "CENTER", 0, 0)
    f.vide:SetJustifyH("CENTER")
    f.graphe = g
    f.dps = Serie(g, OR, 1)
    f.precision = Serie(g, VERT, 2)

    -- Tendance
    local lTendance = Texte(f, "GameFontNormal", "TOPLEFT", f, "TOPLEFT", 18, -250)
    lTendance:SetText("Tendance")
    f.tendDps = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", 18, -268, 504)
    -- Ancrée sous la ligne du DPS : reste lisible si celle-ci passe sur deux lignes.
    f.tendPrec = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f.tendDps, "BOTTOMLEFT", 0, -4, 504)
    -- Temps à énergie pleine (classes à énergie seulement ; vide sinon).
    f.tendPleine = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f.tendPrec, "BOTTOMLEFT", 0, -4, 504)

    -- Erreurs les plus fréquentes
    -- Ancrées sous la tendance : la section suit si les lignes de tendance passent sur deux lignes.
    -- Les lignes d'erreur sont placées au remplissage (hauteur variable selon la présence d'un conseil).
    local lErreurs = Texte(f, "GameFontNormal", "TOPLEFT", f.tendPleine, "BOTTOMLEFT", 0, -14)
    lErreurs:SetText("Erreurs les plus fréquentes")
    f.lErreurs = lErreurs
    f.erreurs = {}
    for i = 1, MAX_ERREURS do
        local e = {}
        e.icone = f:CreateTexture(nil, "ARTWORK")
        e.icone:SetSize(18, 18)
        e.icone:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        e.titre = Texte(f, "GameFontHighlightSmall", "TOPLEFT", e.icone, "TOPRIGHT", 6, -2, 480)
        e.conseil = Texte(f, "GameFontDisableSmall", "TOPLEFT", e.titre, "BOTTOMLEFT", 0, -3, 480)
        f.erreurs[i] = e
    end
    f.sansErreur = Texte(f, "GameFontDisableSmall", "TOPLEFT", lErreurs, "BOTTOMLEFT", 0, -10, 504)

    f:Hide()
    page = f
end

-- ---------------------------------------------------------------------
-- Remplissage
-- ---------------------------------------------------------------------
-- Place une série de valeurs (nil = trou) sur le graphe ; valeurMax : haut de l'axe ; n : nombre de points.
-- n est passé explicitement : la longueur (#) d'une liste à trous n'est pas fiable en Lua.
local function Tracer(serie, valeurs, genres, valeurMax, n)
    local precedent
    for i = 1, MAX_POINTS do
        local p, l = serie.points[i], serie.lignes[i]
        local v = valeurs[i]
        if i <= n and v and valeurMax > 0 then
            local x = n > 1 and (i - 1) / (n - 1) * L_GRAPHE or L_GRAPHE / 2
            local y = math.min(1, v / valeurMax) * H_GRAPHE
            p:ClearAllPoints()
            p:SetPoint("CENTER", page.graphe, "BOTTOMLEFT", x, y)
            -- Combats guidés en points plus petits ; la précision un peu plus petite que le DPS, pour que les
            -- deux restent visibles quand ils se superposent.
            local taille = (genres[i] == "guide" and 5 or 8) - (serie == page.precision and 2 or 0)
            p:SetSize(taille, taille)
            p:Show()
            if l and precedent then
                l:SetStartPoint("BOTTOMLEFT", page.graphe, precedent[1], precedent[2])
                l:SetEndPoint("BOTTOMLEFT", page.graphe, x, y)
                l:Show()
            elseif l then
                l:Hide()
            end
            precedent = { x, y }
        else
            p:Hide()
            if l then l:Hide() end
        end
    end
end

-- format : affiche une valeur ; formatEcart : affiche un écart (sans signe) ; inverse : une baisse est un
-- progrès (temps à énergie pleine).
local function TexteTendance(libelle, recente, ancienne, n, format, formatEcart, inverse)
    if not recente then return libelle .. " : pas encore de mesure." end
    local texte = n > 1
        and string.format("%s : %s en moyenne sur les %d dernières mesures", libelle, format(recente), n)
        or string.format("%s : %s sur la dernière mesure", libelle, format(recente))
    if ancienne then
        local ecart = recente - ancienne
        local mieux
        if inverse then mieux = ecart <= 0 else mieux = ecart >= 0 end
        local couleur = mieux and "|cff66ff66" or "|cffff6666"
        texte = texte .. string.format(", contre %s avant (%s%s%s|r).", format(ancienne), couleur,
            ecart >= 0 and "+" or "-", formatEcart(math.abs(ecart)))
    else
        texte = texte .. " (trop peu de mesures pour comparer)."
    end
    return texte
end

local function Remplir(uidRacine)
    local sessions = ns.Data.Sessions()
    local combats = ns.db.combatsGuides or {}
    local numero, racine = ns.Data.NumeroParUid(uidRacine)
    local nom = racine and ns.Data.Nom(racine, numero) or "Cycle"
    page.titre:SetText("Progression - " .. nom)

    local tous = ns.Coach.Points(sessions, combats, uidRacine)
    local nbSessions, nbGuides = 0, 0
    for _, p in ipairs(tous) do
        if p.genre == "guide" then nbGuides = nbGuides + 1 else nbSessions = nbSessions + 1 end
    end
    page.resume:SetText(string.format("%d session%s et %d combat%s guidé%s%s.", nbSessions, nbSessions > 1 and "s" or "",
        nbGuides, nbGuides > 1 and "s" or "", nbGuides > 1 and "s" or "",
        tous[1] and (" depuis le " .. tous[1].date) or ""))

    -- Graphe : les MAX_POINTS derniers points
    local points = {}
    for i = math.max(1, #tous - MAX_POINTS + 1), #tous do points[#points + 1] = tous[i] end
    local dps, prec, genres, maxDps = {}, {}, {}, 0
    for i, p in ipairs(points) do
        dps[i], prec[i], genres[i] = p.dps, p.precision, p.genre
        if p.dps and p.dps > maxDps then maxDps = p.dps end
    end
    maxDps = maxDps * 1.1
    page.axeDps:SetText(maxDps > 0 and (Nombre(maxDps, 0) .. " DPS") or "")
    Tracer(page.dps, dps, genres, maxDps, #points)
    Tracer(page.precision, prec, genres, 1, #points)
    page.dateDebut:SetText(points[1] and points[1].date or "")
    page.dateFin:SetText(#points > 1 and points[#points].date or "")
    page.vide:SetShown(#points == 0)
    page.vide:SetText("Pas encore de mesure : fais une session, une amélioration ou un combat guidé.")

    -- Tendance
    local function UnDps(x) return Nombre(x, 1) end
    local r, a, n = ns.Coach.Tendance(tous, "dps", TENDANCE)
    page.tendDps:SetText(TexteTendance("DPS", r, a, n, UnDps, UnDps))
    r, a, n = ns.Coach.Tendance(tous, "precision", TENDANCE)
    page.tendPrec:SetText(TexteTendance("Précision", r, a, n, Pourcent, function(x)
        local points = math.floor(x * 100 + 0.5)
        return string.format("%d point%s", points, points > 1 and "s" or "")
    end))
    r, a, n = ns.Coach.Tendance(tous, "pleine", TENDANCE)
    local function Secondes(x) return Nombre(x, 1) .. " s" end
    page.tendPleine:SetText(r and TexteTendance("Énergie pleine", r, a, n, Secondes, Secondes, true) or "")

    -- Erreurs
    local erreurs, sources = ns.Coach.Erreurs(sessions, combats, uidRacine, MAX_ERREURS)
    local conseilsDonnes = {}   -- un même conseil n'est affiché qu'une fois
    local y = 8                 -- décalage sous le titre de la section
    for i, ligne in ipairs(page.erreurs) do
        ligne.icone:ClearAllPoints()
        ligne.icone:SetPoint("TOPLEFT", page.lErreurs, "BOTTOMLEFT", 0, -y)
        local e = erreurs[i]
        local visible = e ~= nil
        ligne.icone:SetShown(visible)
        ligne.titre:SetShown(visible)
        ligne.conseil:SetShown(visible)
        if visible then
            local parties = {}
            for raison, k in pairs(e.parRaison) do
                parties[#parties + 1] = string.format("%s %d fois", ns.Coach.LIBELLES[raison] or raison, k)
            end
            table.sort(parties)
            local okI, icone = pcall(C_Spell and C_Spell.GetSpellTexture or GetSpellTexture, e.id)
            ligne.icone:SetTexture(okI and icone or "Interface\\Icons\\INV_Misc_QuestionMark")
            ligne.titre:SetText(string.format("%s : %s (dans %d sur %d)", ns.Capture.NomSort(e.id),
                table.concat(parties, ", "), e.sources, sources))
            if e.conseil and not conseilsDonnes[e.conseil] then
                conseilsDonnes[e.conseil] = true
                ligne.conseil:SetText(e.conseil)
                ligne.conseil:Show()
                y = y + 52   -- titre + conseil (jusqu'à deux lignes)
            else
                ligne.conseil:Hide()
                y = y + 24   -- titre seul
            end
        end
    end
    page.sansErreur:SetShown(#erreurs == 0)
    page.sansErreur:SetText(sources > 0 and "Aucune erreur relevée : continue comme ça."
        or "Les erreurs apparaîtront après une session d'amélioration ou un combat guidé.")
end

-- Ouvre la progression de la lignée de la session n° numero.
function UI.OuvrirProgression(numero)
    local s = ns.Data.Sessions()[numero]
    if not s then return end
    if not page then CreerPage() end
    Remplir(ns.Coach.Racine(ns.Data.Sessions(), s.uid))
    page:Show()
    page:Raise()
end
