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

-- Guide (jalon 8a) : en combat normal, hors session, le HUD suit le cycle « Actif » de la classe avec une
-- partition VIVANTE (recalée sur ce qui est joué : départ en cours de cycle, notes sautées, procs).
-- Démarre à l'entrée en combat, s'arrête à la sortie. /sdt guide l'active ou le coupe.

local _, ns = ...

local Guide = {}
ns.Guide = Guide

local Print = function(msg) ns.Print(msg) end

local DUREE_PARTITION = 600   -- s de partition construits d'avance (un combat normal dure bien moins)
-- On n'entre en combat qu'après le premier sort (fin de l'incantation, ou juste après un instantané) :
-- les sorts des dernières secondes sont gardés hors combat, puis rejoués quand le Guide démarre.
local FENETRE_RATTRAPAGE = 6

local guide   -- { uid, nom, notes, jeu, debut } pendant un combat guidé, nil sinon
local tampon = {}   -- sorts récents hors Guide : { etape, spellID, castGUID, duree, t }

function Guide.Actif() return guide end

function Guide.Active()
    return ns.db.guide ~= false   -- activé par défaut
end

local function UI(fonction, ...)
    if ns.UI and ns.UI[fonction] then ns.UI[fonction](...) end
end

-- Cycle actif de la classe du joueur : mono-cible d'abord, sinon multi-cibles.
function Guide.CycleActif()
    local classe = select(2, UnitClass("player"))
    local actifs = ns.db.actifs and ns.db.actifs[classe or "?"]
    if not actifs then return nil end
    for _, type in ipairs({ "mono", "multi" }) do
        local numero, s = ns.Data.NumeroParUid(actifs[type])
        if numero then return numero, s end
    end
end

-- Temps écoulé depuis le premier sort du combat (0 avant).
function Guide.Ecoule()
    if guide and guide.debut then return GetTime() - guide.debut end
    return 0
end

function Guide.Demarrer()
    if guide or not Guide.Active() or ns.Session.Etat() ~= "inactif" then return end
    local numero, s = Guide.CycleActif()
    if not numero then return end
    local notes = ns.Session.ConstruirePartition(s, DUREE_PARTITION)
    if not notes then return end
    -- Fenêtre de recalage : au plus un cycle moins une note, pour qu'un sort joué dans le désordre ne fasse
    -- jamais sauter un cycle entier (chaque sort du cycle revient au moins une fois par cycle).
    local longueur = 0
    for _, n in ipairs(notes) do
        if n.rep == 1 then longueur = longueur + 1 end
    end
    guide = {
        uid = s.uid,
        nom = ns.Data.Nom(s, numero):gsub("^Amélioration · ", ""),
        notes = notes,
        jeu = ns.Partition.Nouvelle(notes, ns.Session.MemeSort,
            { vivante = true, fenetre = math.max(1, math.min(8, longueur - 1)) }),
        -- Énergie pleine comptée dès l'entrée en combat (une ouverture tardive gaspille aussi la régénération).
        pleinDebut = ns.Capture.UtiliseEnergie() and ns.Capture.TempsPlein() or nil,
    }
    UI("ReinitialiserTouches")
    UI("AfficherHUD")
    -- Rattrapage : le sort qui a lancé le combat (et ceux juste avant) devient le début de la partition.
    local limite = GetTime() - FENETRE_RATTRAPAGE
    local recents = tampon
    tampon = {}
    for _, e in ipairs(recents) do
        if e.t >= limite then Guide.SurSort(e.etape, e.spellID, e.castGUID, e.duree, e.t) end
    end
end

-- Fin du combat (ou session qui démarre, ou bouton Masquer) : le bilan est gardé pour le Coach (jalon 8b).
-- finCombat : sortie de combat ; le DPS du combat est alors lu dans le compteur de dégâts (lisible hors combat),
-- dans sa dernière session, celle du combat qui vient de finir.
function Guide.Arreter(finCombat)
    if not guide then return end
    local jeu = guide.jeu
    if jeu.juges > 0 then
        ns.db.combatsGuides = ns.db.combatsGuides or {}
        local liste = ns.db.combatsGuides
        local bilan = {
            uid = guide.uid,
            date = date("%Y-%m-%d %H:%M"),
            duree = math.floor(Guide.Ecoule() + 0.5),
            precision = ns.Partition.Precision(jeu),
            compte = ns.Data.Copie(jeu.compte),
            comboMax = jeu.comboMax,
            erreurs = ns.Data.Copie(jeu.erreurs),
            energiePleine = ns.Session.TempsPleinDepuis(guide.pleinDebut),
        }
        liste[#liste + 1] = bilan
        while #liste > 500 do table.remove(liste, 1) end
        if finCombat then
            C_Timer.After(1, function()
                local r = ns.Capture.LireCompteur(ns.Capture.DernierIdCompteur() - 1)
                if r and r.nbCombats == 1 and r.duree > 0 then
                    bilan.dps, bilan.degats = r.total / r.duree, r.total
                end
            end)
        end
    end
    guide = nil
    UI("MasquerHUD")
end

-- Sorts du joueur (appelé par Capture) : jugés contre la partition vivante.
function Guide.SurSort(etape, spellID, castGUID, duree, t)
    if not spellID or ns.Session.Etat() ~= "inactif" then return end
    if not guide then
        -- Hors Guide : gardé quelques secondes, au cas où ce sort lance le combat.
        tampon[#tampon + 1] = { etape = etape, spellID = spellID, castGUID = castGUID, duree = duree, t = t }
        while tampon[1] and tampon[1].t < t - FENETRE_RATTRAPAGE do table.remove(tampon, 1) end
        return
    end
    local verdicts
    if etape == "Début" or etape == "Canal." or etape == "Instant" then
        guide.debut = guide.debut or t
        local cout, combo = ns.Session.InfosEnergie(spellID)
        verdicts = ns.Partition.Jouer(guide.jeu, spellID, t - guide.debut, duree, cout, combo)
    elseif guide.debut and etape == "Esquivé" then
        verdicts = ns.Partition.Esquiver(guide.jeu, spellID, t - guide.debut, ns.Session.Rendu(spellID))
    elseif guide.debut and (etape == "Déplacement" or etape == "Interrompu" or etape == "Échec") then
        verdicts = ns.Partition.Interrompre(guide.jeu, spellID, t - guide.debut)
    end
    if verdicts and #verdicts > 0 then UI("Verdicts", verdicts) end
end

-- Le temps passe : notes non jouées à temps (appelé par le HUD).
function Guide.Avancer()
    if not (guide and guide.debut) then return end
    local verdicts = ns.Session.FaireAvancer(guide.jeu, GetTime() - guide.debut)
    if #verdicts > 0 then UI("Verdicts", verdicts) end
end

function Guide.Basculer()
    ns.db.guide = not Guide.Active()
    if not Guide.Active() then Guide.Arreter() end
    local _, s = Guide.CycleActif()
    Print("Guide en combat " .. (Guide.Active() and "activé" or "coupé") .. "." ..
        (Guide.Active() and (s and (" Cycle suivi : « " .. ns.Data.Nom(s) .. " ».")
            or " Aucun cycle actif : choisis-en un dans le journal (menu « … », Définir comme actif).") or ""))
end

local cadre = CreateFrame("Frame")
cadre:RegisterEvent("PLAYER_REGEN_DISABLED")
cadre:RegisterEvent("PLAYER_REGEN_ENABLED")
cadre:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        local ok, err = pcall(Guide.Demarrer)
        if not ok then Print("Guide : erreur (" .. tostring(err) .. ")") end
    else
        Guide.Arreter(true)
    end
end)
