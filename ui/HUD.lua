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

-- HUD de la session d'amélioration (jalons 6a et 6b) : bloc compact sous le personnage, déplaçable.
-- De haut en bas : titre et infos de session, jauge de mana, jugement (verdict, combo, précision), timeline.
-- Timeline : cadre « maintenant » à gauche, notes arrivant de la droite, touche sur chaque icône,
-- trait au début de chaque répétition du cycle, zone d'immobilité sous chaque incantation (longueur = temps
-- d'incantation ; les trous entre zones indiquent quand on peut bouger).

local _, ns = ...

local UI = ns.UI or {}
ns.UI = UI

local LARGEUR, HAUTEUR = 440, 150
local MAX_COMBO = 5          -- cases de points de combo (le maximum réel est relu dans le jeu)
local HAUTEUR_ZONE = 6
local Y_ZONE = -26          -- sous les icônes (centre de la bande = 0)
local VITESSE = 70          -- pixels par seconde de défilement (environ 5 s visibles)
local TAILLE_NOTE = 36
local X_MAINTENANT = 32     -- centre du cadre « maintenant » dans la bande
local MAX_NOTES = 10
local MAX_TRAITS = 4
local DUREE_VERDICT = 1.2   -- s d'affichage d'un verdict
local ICONE_INCONNUE = "Interface\\Icons\\INV_Misc_QuestionMark"

local COULEURS = {
    parfait = { 1, 0.85, 0.2 },
    bien = { 0.4, 1, 0.4 },
    juste = { 0.9, 0.9, 0.5 },
    rate = { 1, 0.3, 0.3 },
    interrompu = { 1, 0.55, 0.1 },
    hors = { 0.6, 0.6, 0.6 },
    esquive = { 0.75, 0.75, 0.75 },
}
local LIBELLES = { parfait = "PARFAIT", bien = "BIEN", juste = "JUSTE", rate = "RATÉ", interrompu = "INTERROMPU",
                   hors = "HORS PARTITION", esquive = "ESQUIVÉ · à rejouer" }
local RAISONS = { retard = "en retard", avance = "trop tôt", omis = "oublié", passee = "pas joué",
                  ecrase = "trop tôt, DoT écrasé", combo = "trop peu de points" }

local hud
local tVerdict = 0

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

local function Texte(parent, police, point, relatif, pointRelatif, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", police)
    fs:SetPoint(point, relatif, pointRelatif, x, y)
    return fs
end

-- Cadre fait de 4 traits (bordure) autour d'un cadre.
local function Bordure(f, r, g, b, epaisseur)
    epaisseur = epaisseur or 2
    for _, cote in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, epaisseur }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, epaisseur },
                            { "TOPLEFT", "BOTTOMLEFT", epaisseur, nil }, { "TOPRIGHT", "BOTTOMRIGHT", epaisseur, nil } }) do
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(r, g, b, 1)
        t:SetPoint(cote[1], f, cote[1])
        t:SetPoint(cote[2], f, cote[2])
        if cote[3] then t:SetWidth(cote[3]) end
        if cote[4] then t:SetHeight(cote[4]) end
    end
end

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------
local function SauverPosition()
    local point, _, pointRelatif, x, y = hud:GetPoint()
    ns.db.hud = { point = point, pointRelatif = pointRelatif, x = x, y = y }
end

local function CreerHUD()
    local f = CreateFrame("Frame", "SalleDuTempsHUD", UIParent)
    f:SetSize(LARGEUR, HAUTEUR)
    local p = ns.db.hud
    if p then
        f:SetPoint(p.point, UIParent, p.pointRelatif, p.x, p.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, -170)
    end
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SauverPosition() end)
    local fond = f:CreateTexture(nil, "BACKGROUND")
    fond:SetAllPoints()
    fond:SetColorTexture(0, 0, 0, 0.55)

    -- Titre et infos
    f.titre = Texte(f, "GameFontNormal", "TOPLEFT", f, "TOPLEFT", 10, -8)
    f.infos = Texte(f, "GameFontHighlightSmall", "TOPRIGHT", f, "TOPRIGHT", -86, -10)
    -- « Annuler » la session d'amélioration, ou « Masquer » le Guide pour ce combat.
    local annuler = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    annuler:SetSize(70, 20)
    annuler:SetText("Annuler")
    annuler:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
    annuler:SetScript("OnClick", function()
        if ns.Session.Amelioration() then
            ns.Session.Annuler("par le joueur")
        elseif ns.Guide and ns.Guide.Actif() then
            ns.Guide.Arreter()
        end
    end)
    f.annuler = annuler

    -- Ligne de ressource : mana (bleu) ou énergie (jaune). Valeurs secrètes, mais une barre du jeu les affiche
    -- telles quelles (sondes du 2026-10-17).
    local ressource = CreateFrame("StatusBar", nil, f)
    ressource:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -30)
    ressource:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -30)
    ressource:SetHeight(10)
    ressource:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    local fondRessource = ressource:CreateTexture(nil, "BACKGROUND")
    fondRessource:SetAllPoints()
    fondRessource:SetColorTexture(0, 0, 0, 0.5)
    ressource.texte = ressource:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ressource.texte:SetPoint("CENTER", ressource, "CENTER", 0, 0)
    f.ressource = ressource

    -- Points de combo sous l'énergie : une barre 0 → max découpée en cases (la valeur peut être secrète en
    -- combat : la barre l'affiche sans que l'addon ait à la lire).
    local combo = CreateFrame("StatusBar", nil, f)
    combo:SetPoint("TOPLEFT", ressource, "BOTTOMLEFT", 0, -3)
    combo:SetPoint("TOPRIGHT", ressource, "BOTTOMRIGHT", 0, -3)
    combo:SetHeight(7)
    combo:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    combo:SetStatusBarColor(1, 0.3, 0.15)
    local fondCombo = combo:CreateTexture(nil, "BACKGROUND")
    fondCombo:SetAllPoints()
    fondCombo:SetColorTexture(0, 0, 0, 0.5)
    combo.separations = {}
    for k = 1, MAX_COMBO - 1 do
        local s = combo:CreateTexture(nil, "OVERLAY")
        s:SetColorTexture(0, 0, 0, 0.9)
        s:SetWidth(2)
        combo.separations[k] = s
    end
    f.pointsCombo = combo

    -- Jugement
    f.degats = Texte(f, "GameFontHighlightSmall", "TOPLEFT", f, "TOPLEFT", 10, -54)
    f.verdict = Texte(f, "GameFontNormalLarge", "TOP", f, "TOP", 0, -50)
    f.combo = Texte(f, "GameFontHighlightSmall", "TOPRIGHT", f, "TOPRIGHT", -10, -54)

    -- Timeline
    local bande = CreateFrame("Frame", nil, f)
    bande:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -76)
    bande:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
    bande:SetClipsChildren(true)
    local fondBande = bande:CreateTexture(nil, "BACKGROUND")
    fondBande:SetAllPoints()
    fondBande:SetColorTexture(1, 1, 1, 0.05)
    f.bande = bande

    local maintenant = CreateFrame("Frame", nil, bande)
    maintenant:SetSize(TAILLE_NOTE + 8, TAILLE_NOTE + 8)
    maintenant:SetPoint("CENTER", bande, "LEFT", X_MAINTENANT, 0)
    maintenant:SetFrameLevel(bande:GetFrameLevel() + 5)
    Bordure(maintenant, 1, 0.82, 0, 2)

    -- Zones d'immobilité : une par note visible, plus celle de l'incantation en cours.
    local function Zone()
        local z = bande:CreateTexture(nil, "ARTWORK")
        z:SetColorTexture(1, 0.6, 0.2, 0.55)
        z:SetHeight(HAUTEUR_ZONE)
        return z
    end
    f.zones = {}
    for i = 1, MAX_NOTES do f.zones[i] = Zone() end
    f.zoneCourante = Zone()

    -- Zones « sablier » (énergie, voleur) : attente avant une note, le temps que l'énergie remonte.
    f.attentes = {}
    for i = 1, MAX_NOTES do
        local a = bande:CreateTexture(nil, "BORDER")
        a:SetColorTexture(1, 0.85, 0.1, 0.18)
        a:SetHeight(TAILLE_NOTE - 6)
        f.attentes[i] = a
    end

    f.traits = {}
    for i = 1, MAX_TRAITS do
        local t = bande:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(1, 1, 1, 0.35)
        t:SetSize(2, 56)
        f.traits[i] = t
    end

    f.notes = {}
    for i = 1, MAX_NOTES do
        local n = CreateFrame("Frame", nil, bande)
        n:SetSize(TAILLE_NOTE, TAILLE_NOTE)
        n:SetFrameLevel(bande:GetFrameLevel() + 2)
        n.tex = n:CreateTexture(nil, "ARTWORK")
        n.tex:SetAllPoints()
        n.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        n.touche = n:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        n.touche:SetPoint("BOTTOMRIGHT", n, "BOTTOMRIGHT", -1, 2)
        -- Mention « DoT » : note rejouée à l'expiration du DoT.
        n.dot = n:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        n.dot:SetPoint("TOPLEFT", n, "TOPLEFT", 1, -1)
        n.dot:SetTextColor(0.75, 0.55, 1)
        n.dot:SetText("DoT")
        f.notes[i] = n
    end

    f.message = Texte(f, "GameFontHighlight", "CENTER", bande, "CENTER", 30, 0)

    f:SetScript("OnUpdate", function(self) UI.MajHUD() end)
    f:Hide()
    hud = f
end

-- ---------------------------------------------------------------------
-- Mise à jour
-- ---------------------------------------------------------------------
-- Zone d'immobilité d'une note (incantation ou canalisation) commençant à x : x → x + durée × vitesse.
local function Placer(zone, note, x, largeur)
    if not note or (note.type ~= "cast" and note.type ~= "canal") or (note.d or 0) <= 0 then
        zone:Hide()
        return
    end
    local debut = math.max(0, x)
    local fin = math.min(largeur, x + note.d * VITESSE)
    if fin <= debut then
        zone:Hide()
        return
    end
    zone:ClearAllPoints()
    zone:SetPoint("LEFT", hud.bande, "LEFT", debut, Y_ZONE)
    zone:SetWidth(fin - debut)
    zone:Show()
end

-- Ligne de ressource : mana ou énergie, et points de combo pour les classes qui en ont. Valeurs secrètes
-- passées telles quelles aux barres. La rage (guerrier) viendra avec la suite du jalon 7.
local MANA, ENERGIE, COMBO = 0, 3, 4   -- Enum.PowerType
local RESSOURCES = {
    [MANA] = { libelle = "Mana", couleur = { 0.2, 0.45, 1 } },
    [ENERGIE] = { libelle = "Énergie", couleur = { 1, 0.85, 0.1 } },
}
-- Repli si le type de ressource est secret : d'après la classe (druide en forme : à traiter avec la rage).
local RESSOURCE_PAR_CLASSE = { PRIEST = MANA, MAGE = MANA, WARLOCK = MANA, SHAMAN = MANA, PALADIN = MANA,
                               HUNTER = MANA, DRUID = MANA, ROGUE = ENERGIE }
local CLASSES_COMBO = { ROGUE = true, DRUID = true }

local function TypeRessource()
    local ok, typeRessource = pcall(UnitPowerType, "player")
    local lisible = ok and ns.Lisible(typeRessource)
    if lisible ~= nil and lisible ~= false then return lisible end
    return RESSOURCE_PAR_CLASSE[select(2, UnitClass("player")) or ""]
end

-- jeu, maintenant : partition en cours, pour afficher l'énergie CALCULÉE à côté de la vraie (diagnostic,
-- 2026-10-17 : la timeline faisait attendre alors que la barre affichait 83).
local function MajRessource(jeu, maintenant)
    local typeRessource = TypeRessource()
    local info = RESSOURCES[typeRessource]
    local barre = hud.ressource
    local calcul = jeu and ns.Partition.EnergieCalculee(jeu, maintenant)
    local lue   -- énergie déduite de la largeur remplie de la barre, si le jeu la laisse lire
    barre:SetShown(info ~= nil)
    if info then
        barre:SetStatusBarColor(info.couleur[1], info.couleur[2], info.couleur[3])
        pcall(barre.SetMinMaxValues, barre, 0, UnitPowerMax("player", typeRessource))
        pcall(barre.SetValue, barre, UnitPower("player", typeRessource))
        -- La valeur de la barre est secrète ; la largeur de sa partie remplie l'est peut-être pas.
        if typeRessource == ENERGIE then
            local okL, largeurRemplie = pcall(function() return barre:GetStatusBarTexture():GetWidth() end)
            local largeur = ns.Lisible(barre:GetWidth())
            local maximum = ns.Lisible(UnitPowerMax("player", typeRessource))
            largeurRemplie = okL and ns.Lisible(largeurRemplie)
            if largeurRemplie and largeur and largeur > 0 and maximum and maximum > 0 then
                lue = largeurRemplie / largeur * maximum
            end
        end
        if lue and jeu then
            -- Énergie réelle lisible : le calcul s'y recale (au plus deux fois par seconde).
            hud.dernierRecalage = hud.dernierRecalage or 0
            if GetTime() - hud.dernierRecalage > 0.5 and ns.Partition.RecalerEnergie(jeu, maintenant, lue, 5) then
                hud.dernierRecalage = GetTime()
                calcul = ns.Partition.EnergieCalculee(jeu, maintenant)
            end
        end
        local ok
        if calcul and typeRessource == ENERGIE then
            local suffixe = lue and string.format(" · lu %d", math.floor(lue + 0.5)) or ""
            -- Points de combo estimés (diagnostic, quand le jeu ne les laisse pas lire) et alerte d'énergie pleine.
            local points, combosLus = ns.Capture.PointsCombo()
            if not combosLus then suffixe = suffixe .. string.format(" · combo estimé %d", points) end
            if ns.Capture.EnergiePleine() then suffixe = suffixe .. " · |cffff5555PLEINE|r" end
            ok = pcall(barre.texte.SetFormattedText, barre.texte, info.libelle .. " %d · calcul %d" .. suffixe,
                UnitPower("player", typeRessource), math.floor(calcul + 0.5))
            if not ok then
                barre.texte:SetFormattedText("%s · calcul %d%s", info.libelle, math.floor(calcul + 0.5), suffixe)
                ok = true
            end
        else
            ok = pcall(barre.texte.SetFormattedText, barre.texte, info.libelle .. " %d", UnitPower("player", typeRessource))
        end
        if not ok then barre.texte:SetText(info.libelle) end
    end

    -- Points de combo (voleur, druide en forme de félin) : sous l'énergie.
    local combo = hud.pointsCombo
    local avecCombo = CLASSES_COMBO[select(2, UnitClass("player")) or ""] == true and typeRessource == ENERGIE
    combo:SetShown(avecCombo)
    if not avecCombo then return end
    local maximum = ns.Lisible(UnitPowerMax("player", COMBO))
    if not maximum or maximum <= 0 then maximum = MAX_COMBO end
    pcall(combo.SetMinMaxValues, combo, 0, maximum)
    pcall(combo.SetValue, combo, UnitPower("player", COMBO))
    -- Séparations entre les cases.
    local largeur = combo:GetWidth()
    for k, s in ipairs(combo.separations) do
        if k < maximum and largeur and largeur > 0 then
            s:ClearAllPoints()
            s:SetPoint("TOP", combo, "TOPLEFT", largeur * k / maximum, 0)
            s:SetPoint("BOTTOM", combo, "BOTTOMLEFT", largeur * k / maximum, 0)
            s:Show()
        else
            s:Hide()
        end
    end
end

function UI.MajHUD()
    -- Deux sources : la session d'amélioration (partition fixe) ou le Guide en combat normal (partition vivante).
    local am = ns.Session.Amelioration()
    local etat = ns.Session.Etat()
    local guide = not am and ns.Guide and ns.Guide.Actif()
    if guide then
        am, etat = guide, "enCours"
    end
    if not am or etat == "inactif" then
        hud:Hide()
        return
    end
    if guide then ns.Guide.Avancer() else ns.Session.AvancerPartition() end
    local jeu = am.jeu
    local maintenant = guide and ns.Guide.Ecoule() or ns.Session.Ecoule()
    hud.annuler:SetText(guide and "Masquer" or "Annuler")

    -- Titre et infos
    hud.titre:SetText((guide and "Guide · " or "Amélioration · ") .. (am.nom or "?"))
    local note = jeu.notes[jeu.i]
    local position
    if not note then
        position = "Partition terminée"
    elseif note.rep == 0 then
        position = "Ouverture"
    elseif guide then
        position = string.format("Cycle %d", note.rep)
    else
        position = string.format("Cycle %d/%d", note.rep, am.repetitions or 0)
    end
    local restant = not guide and ns.Session.Restant()
    if restant then
        position = position .. string.format(" · %d:%02d", math.floor(restant / 60), math.floor(restant % 60))
    end
    hud.infos:SetText(position)

    -- Dégâts en direct (valeur secrète affichée telle quelle) et combo
    if etat == "enCours" and UI.AfficherDegats then
        UI.AfficherDegats(hud.degats, ns.Capture.DegatsEnDirect())
    else
        hud.degats:SetText("")
    end
    local precision = ns.Partition.Precision(jeu)
    hud.combo:SetText(string.format("Combo ×%d · %s", jeu.combo, precision and string.format("%d %%", math.floor(precision * 100 + 0.5)) or "-"))
    hud.verdict:SetAlpha(math.max(0, 1 - (GetTime() - tVerdict) / DUREE_VERDICT))

    -- Message d'état
    if guide and not guide.debut then
        hud.message:SetText("Cycle actif : à toi de jouer")
    elseif etat == "attente" then
        hud.message:SetText("En attente du premier sort sur la cible…")
    elseif etat == "decision" then
        hud.message:SetText("|cffff9933Combat terminé avant la fin|r : enregistrer ?")
    elseif etat == "fin" then
        hud.message:SetText("|cff66ff66Terminé|r : arrête d'attaquer")
    elseif ns.Capture.SousControle() then
        hud.message:SetText("|cffff9933Perte de contrôle|r : partition en pause")
    else
        hud.message:SetText("")
    end

    MajRessource(jeu, maintenant)

    -- Notes, zones d'immobilité et traits de début de cycle
    local largeur = hud.bande:GetWidth()
    local prochaines = (etat == "fin" or etat == "decision") and {} or ns.Partition.Prochaines(jeu, MAX_NOTES, maintenant)
    local traits = 0
    for i, n in ipairs(hud.notes) do
        local x = prochaines[i] and (X_MAINTENANT + (prochaines[i].t - maintenant) * VITESSE)
        local zone = hud.zones[i]
        if x and x < largeur + TAILLE_NOTE then
            local p = prochaines[i]
            n:ClearAllPoints()
            n:SetPoint("CENTER", hud.bande, "LEFT", x, 0)
            n.tex:SetTexture(IconeSort(p.note.id))
            n.touche:SetText(UI.Touche and UI.Touche(p.note.id) or "")
            n.dot:SetShown(p.note.dot ~= nil)
            n:Show()
            Placer(zone, p.note, x, largeur)
            -- Attente d'énergie avant la note : de (x - attente) jusqu'au bord gauche de l'icône.
            local a = hud.attentes[i]
            local attente = p.note.attente
            if attente and attente > 0 then
                local debut = math.max(0, x - attente * VITESSE)
                local fin = math.max(debut, x - TAILLE_NOTE / 2)
                a:ClearAllPoints()
                a:SetPoint("LEFT", hud.bande, "LEFT", debut, 0)
                a:SetWidth(math.max(1, fin - debut))
                a:SetShown(fin > debut)
            else
                a:Hide()
            end
            if p.note.debutRep and traits < MAX_TRAITS then
                traits = traits + 1
                local t = hud.traits[traits]
                t:ClearAllPoints()
                t:SetPoint("CENTER", hud.bande, "LEFT", x - TAILLE_NOTE / 2 - 4, 0)
                t:Show()
            end
        else
            n:Hide()
            zone:Hide()
            hud.attentes[i]:Hide()
        end
    end
    for i = traits + 1, MAX_TRAITS do hud.traits[i]:Hide() end

    -- Zone de l'incantation en cours : part du moment où la note a été jouée et se réduit vers « maintenant ».
    local d = jeu.dernier
    local enCours = ns.Capture.Incantation()
    if etat == "enCours" and enCours and d and not d.interrompu then
        local note = jeu.notes[d.index]
        Placer(hud.zoneCourante, note, X_MAINTENANT + (d.t - maintenant) * VITESSE, largeur)
    else
        hud.zoneCourante:Hide()
    end
end

-- Verdicts produits par la partition (le dernier est affiché).
function UI.Verdicts(verdicts)
    if not hud then return end
    local v = verdicts[#verdicts]
    if not v then return end
    local texte = LIBELLES[v.genre] or v.genre
    if v.raison and RAISONS[v.raison] then texte = texte .. " · " .. RAISONS[v.raison] end
    if v.raison == "combo" then
        texte = texte .. string.format(" (%d sur %d)", v.combo or 0, v.comboPrevu or 0)
    elseif v.ecart and v.genre ~= "hors" and math.abs(v.ecart) >= 0.01 then
        texte = texte .. string.format("  %s%s s", v.ecart > 0 and "+" or "", Nombre(v.ecart, 2))
    end
    local c = COULEURS[v.genre] or COULEURS.hors
    hud.verdict:SetText(texte)
    hud.verdict:SetTextColor(c[1], c[2], c[3])
    tVerdict = GetTime()
end

function UI.AfficherHUD()
    if not hud then CreerHUD() end
    hud.verdict:SetText("")
    hud:Show()
    UI.MajHUD()
end

function UI.MasquerHUD()
    if hud then hud:Hide() end
end
