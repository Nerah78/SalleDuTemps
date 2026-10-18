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

-- Partition : notes de la session d'amélioration et jugement du rythme (jalon 6a).
-- Lua pur, SANS API WoW (testable hors du jeu, voir tests/).
--
-- Partition fixe : la suite des notes ne change pas pendant la session. Le tempo, lui, se recale sur le
-- sort joué : l'heure attendue d'une note = moment où la précédente a été jouée + sa durée. Sans ce recalage,
-- un seul retard décalerait toute la suite (on ne peut pas rattraper : chaque sort coûte au moins un GCD).
-- Série de tirs = temps libre : c'est le joueur qui décide quand il arrête de tirer (mana, cooldowns) ; le sort
-- qui suit une série est jugé sur l'ordre seulement, et aucune note n'est déclarée ratée pendant la série.

local _, ns = ...

local Partition = {}
if ns then ns.Partition = Partition end

-- Sorts dont une série de lancers consécutifs forme une seule note (tirs automatiques).
local SERIES = { [75] = true, [5019] = true }
Partition.SERIES = SERIES

Partition.GCD = 1.5
Partition.DUREE_SERIE = 3   -- durée par défaut d'une série de tirs, sans mesure dans la session de référence

-- Seuils de jugement (spécification, section 6 ; à ajuster en jeu). écart = joué - attendu (s).
Partition.SEUILS = {
    avance = 0.4,     -- jusqu'à 0,4 s en avance : Parfait (file d'attente des sorts)
    parfait = 0.12,
    bien = 0.25,
    juste = 0.35,
}
Partition.POINTS = { parfait = 1, bien = 0.7, juste = 0.4, rate = 0, interrompu = 0 }
-- Note qui attend l'énergie : le joueur réagit à la barre au lieu d'enchaîner un sort en file d'attente ; son
-- retard est jugé avec cette marge de réaction en moins (voleur, temps de recharge global d'1 s, 2026-10-17).
Partition.MARGE_REACTION = 0.2
Partition.COMBO_MAX = 5

-- ---------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------

-- Durée moyenne d'une série de tirs dans une séquence : du premier tir au sort suivant (hors tirs).
function Partition.DureeSerie(sorts)
    local total, nombre, debut = 0, 0, nil
    for _, e in ipairs(sorts or {}) do
        if e.ok and e.id then
            if SERIES[e.id] then
                debut = debut or e.t
            elseif debut then
                total, nombre, debut = total + (e.t - debut), nombre + 1, nil
            end
        end
    end
    if nombre == 0 then return Partition.DUREE_SERIE end
    return total / nombre
end

local function DureeNote(etape, options)
    if etape.type == "serie" then return options.dureeSerie or Partition.DUREE_SERIE end
    return math.max(etape.d or 0, options.gcd or Partition.GCD)
end

-- ---------------------------------------------------------------------
-- DoT (dégâts sur la durée, 2026-10-17) : une étape de type "dot" porte sa durée (e.dot, s). Elle n'a pas de
-- place fixe dans le cycle : elle est rejouée à son expiration (en avance de son temps d'incantation, pour
-- s'appliquer pile à l'expiration) et passe alors avant les sorts de remplissage, qui gardent leur ordre.
-- Sans étape DoT, la partition est une simple suite, comme avant.
-- ---------------------------------------------------------------------
Partition.HORIZON = 90   -- s de partition replanifiés d'avance quand le cycle contient des DoT

-- Plan : remplissage (dans l'ordre) et DoT (un par sort, dans l'ordre d'apparition).
local function Plan(cycle, options)
    local plan = { fillers = {}, dots = {}, ordreDots = {}, options = options }
    for _, e in ipairs(cycle or {}) do
        if e.actif ~= false then
            if e.type == "dot" and (e.dot or 0) > 0 then
                if not plan.dots[e.id] then
                    plan.dots[e.id] = e
                    plan.ordreDots[#plan.ordreDots + 1] = e
                end
            else
                plan.fillers[#plan.fillers + 1] = e
            end
        end
    end
    return plan
end

-- Expiration d'un DoT lancé à t : il s'applique à la fin de son incantation, puis dure e.dot secondes.
local function Expiration(etape, t) return t + (etape.d or 0) + etape.dot end

-- ---------------------------------------------------------------------
-- Énergie (voleur, jalon 7, 2026-10-17) : options.energie = { max, regen (par s), depart }. L'énergie réelle est
-- secrète : elle est CALCULÉE (régénération continue, coût de chaque sort : étape.cout). Une note n'arrive que
-- quand l'énergie calculée suffit ; l'attente est gardée dans note.attente (zone « sablier » du HUD).
-- Sans options.energie, rien ne change.
-- ---------------------------------------------------------------------
local function EnergieA(energie, depuis, t, en)
    return math.min(en.max, energie + en.regen * math.max(0, t - depuis))
end

-- Ajoute à notes la suite de la partition, de t jusqu'à tFin, d'après l'état simulé
-- sim = { filler (prochain sort de remplissage), rep (répétition en cours), dots = { [id] = expiration } }.
-- sim est modifié (expirations prévues) : passer une copie de l'état réel.
local function Prolonger(plan, sim, notes, t, tFin)
    local options = plan.options
    local function Echeance(e)   -- heure de lancer pour que le DoT s'applique à l'expiration
        local exp = sim.dots[e.id]
        if not exp then return -math.huge end   -- jamais posé : dû tout de suite
        return exp - (e.d or 0)
    end
    local function Du(instant)   -- DoT dû à cet instant (échéance la plus ancienne), ou nil
        local meilleur, ech
        for _, e in ipairs(plan.ordreDots) do
            local x = Echeance(e)
            if x <= instant + 1e-9 and (not meilleur or x < ech) then meilleur, ech = e, x end
        end
        return meilleur
    end
    local function ProchaineEcheance()
        local ech
        for _, e in ipairs(plan.ordreDots) do
            local x = Echeance(e)
            if not ech or x < ech then ech = x end
        end
        return ech
    end
    local en = options.energie
    local function Ajouter(e, duree, debutRep, fillerIndex)
        local dot = plan.dots[e.id]
        local attente
        if en then
            -- Attendre que l'énergie suffise : la note précédente s'allonge d'autant.
            local energie = EnergieA(sim.energie, sim.energieT, t, en)
            local cout = e.cout or 0
            if energie < cout then
                attente = (cout - energie) / en.regen
                if notes[#notes] then notes[#notes].duree = notes[#notes].duree + attente end
                t = t + attente
                energie = cout
            end
            sim.energie, sim.energieT = energie - cout, t
        end
        notes[#notes + 1] = { id = e.id, type = e.type, d = e.d or 0, duree = duree, base = duree, t = t,
                              rep = sim.rep, debutRep = debutRep, fillerIndex = fillerIndex,
                              dot = dot and dot.dot or nil, cout = e.cout, attente = attente,
                              genere = e.genere, finisseur = e.finisseur }
        if dot then sim.dots[e.id] = Expiration(dot, t) end
        t = t + duree
    end

    if #plan.fillers == 0 then
        if #plan.ordreDots == 0 then return t end
        -- Cycle fait seulement de DoT : on attend chaque échéance (l'attente allonge la note précédente).
        sim.rep = math.max(sim.rep, 1)
        local garde = 0
        while t < tFin and garde < 10000 do
            garde = garde + 1
            local e = Du(t)
            if e then
                Ajouter(e, DureeNote(e, options), false, nil)
            else
                local ech = ProchaineEcheance()
                if notes[#notes] then notes[#notes].duree = notes[#notes].duree + (ech - t) end
                t = ech
            end
        end
        return t
    end

    while t < tFin do
        local k = sim.filler
        if k == 1 then sim.rep = sim.rep + 1 end
        -- DoT dus d'abord.
        local e = Du(t)
        while e do
            Ajouter(e, DureeNote(e, options), false, nil)
            e = Du(t)
        end
        local f = plan.fillers[k]
        local duree = DureeNote(f, options)
        if f.type == "serie" and #plan.ordreDots > 0 then
            -- Une série de tirs s'arrête à l'échéance du prochain DoT.
            local ech = ProchaineEcheance()
            if ech then duree = math.max(options.gcd or Partition.GCD, math.min(duree, ech - t)) end
        end
        Ajouter(f, duree, k == 1, k)
        sim.filler = k % #plan.fillers + 1
    end
    return t
end

-- Notes de la partition : l'ouverture (facultative), puis le cycle jusqu'à couvrir dureeTotale.
-- ouverture, cycle : listes d'étapes { id, type, d, actif, dot } (format de Cycle.Etapes) ; seules les actives
-- comptent. options : dureeTotale (s), gcd, dureeSerie.
-- Note : { id, type, d, duree (s jusqu'à la note suivante), t (heure prévue), rep (0 = ouverture), debutRep,
--          fillerIndex (place dans le remplissage), dot (durée du DoT, nil sinon) }.
-- Le plan (remplissage, DoT) est rangé dans notes.plan pour la replanification en cours de jeu.
function Partition.Construire(ouverture, cycle, options)
    options = options or {}
    local plan = Plan(cycle, options)
    local notes, t = {}, 0
    local en = options.energie
    local sim = { filler = 1, rep = 0, dots = {}, energie = en and en.depart or 0, energieT = 0 }
    for _, e in ipairs(ouverture or {}) do
        if e.actif ~= false then
            local duree = DureeNote(e, options)
            local dot = plan.dots[e.id]
            local attente
            if en then
                local energie = EnergieA(sim.energie, sim.energieT, t, en)
                if energie < (e.cout or 0) then
                    attente = ((e.cout or 0) - energie) / en.regen
                    if notes[#notes] then notes[#notes].duree = notes[#notes].duree + attente end
                    t = t + attente
                    energie = e.cout or 0
                end
                sim.energie, sim.energieT = energie - (e.cout or 0), t
            end
            notes[#notes + 1] = { id = e.id, type = e.type, d = e.d or 0, duree = duree, base = duree, t = t,
                                  rep = 0, debutRep = false, dot = dot and dot.dot or nil, cout = e.cout,
                                  attente = attente, genere = e.genere, finisseur = e.finisseur }
            if dot then sim.dots[e.id] = Expiration(dot, t) end
            t = t + duree
        end
    end
    Prolonger(plan, sim, notes, t, options.dureeTotale or 60)
    notes.plan = plan
    return notes
end

-- Nombre de répétitions du cycle qui commencent avant la fin de la session.
function Partition.Repetitions(notes, dureeTotale)
    local n = 0
    for _, note in ipairs(notes) do
        if note.debutRep and note.t < dureeTotale then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------
-- Jugement
-- ---------------------------------------------------------------------

function Partition.Classer(ecart)
    local s = Partition.SEUILS
    if ecart >= -s.avance and ecart <= s.parfait then return "parfait" end
    local a = math.abs(ecart)
    if a < s.bien then return "bien" end
    if a < s.juste then return "juste" end
    return "rate"
end

-- Partition FIXE (session d'amélioration) ou VIVANTE (Guide en combat normal, jalon 8) :
-- la partition vivante se recale sur ce qui est joué. Un sort qui correspond à une note plus loin dans le
-- cycle (fenêtre de recherche) y fait sauter la partition (notes sautées comptées comme oubliées), et le
-- premier sort du combat peut prendre la partition en cours de cycle, sans pénalité.
-- egal (facultatif) : compare deux identifiants de sort (ex. par nom, pour ignorer les rangs).
-- options (facultatif) : vivante (booléen), fenetre (nombre de notes cherchées au-delà de la note attendue :
-- 1 en partition fixe, 8 par défaut en partition vivante).
function Partition.Nouvelle(notes, egal, options)
    options = options or {}
    local plan = notes.plan
    local en = plan and plan.options and plan.options.energie
    local avecDots = plan ~= nil and #plan.ordreDots > 0
    return {
        notes = notes,
        plan = plan,
        avecDots = avecDots,
        en = en,                                       -- énergie calculée (voleur), nil sinon
        energie = en and en.depart or 0,               -- énergie calculée à l'instant energieT
        energieT = nil,                                -- nil avant le premier sort
        dynamique = avecDots or en ~= nil,             -- partition replanifiée en cours de jeu
        dots = {},          -- [id] = expiration réelle des DoT posés
        manques = {},       -- [id] = true : DoT dû déjà compté « pas joué » (compté une seule fois)
        pc = 0,             -- points de combo prévus : générateurs joués depuis le dernier coup de grâce (voleur)
        filler = 1,         -- prochain sort de remplissage
        rep = 0,            -- répétition du dernier sort de remplissage joué
        i = 1,              -- note attendue
        attendu = nil,      -- heure attendue de la note i (nil avant le premier sort)
        egal = egal or function(a, b) return a == b end,
        vivante = options.vivante and true or false,
        fenetre = options.fenetre or (options.vivante and 8 or 1),
        serie = nil,        -- identifiant de la série de tirs en cours
        combo = 0, comboMax = 0,
        compte = { parfait = 0, bien = 0, juste = 0, rate = 0, interrompu = 0, hors = 0, esquive = 0 },
        reprise = nil,      -- true après une perte de contrôle : marge de réaction sur la note suivante
        points = 0, juges = 0,
        erreurs = {},       -- [spellID] = { omis, passee, retard, avance, interrompu } (Coach)
        dernier = nil,      -- dernière note jugée { index, genre, raison, id, t, interrompu }
    }
end

-- id et raison (facultatifs) : alimentent les erreurs par sort pour le Coach.
local function Noter(etat, genre, id, raison)
    etat.compte[genre] = etat.compte[genre] + 1
    if genre == "hors" then return end
    if (genre == "rate" or genre == "interrompu") and id then
        local e = etat.erreurs[id] or {}
        local cle = raison or genre
        e[cle] = (e[cle] or 0) + 1
        etat.erreurs[id] = e
    end
    etat.juges = etat.juges + 1
    etat.points = etat.points + Partition.POINTS[genre]
    if genre == "rate" or genre == "interrompu" then
        etat.combo = 0
    else
        etat.combo = etat.combo + 1
        if etat.combo > etat.comboMax then etat.comboMax = etat.combo end
    end
end

-- Précision : moyenne des points des notes jugées (0 à 1), nil si aucune.
function Partition.Precision(etat)
    if etat.juges == 0 then return nil end
    return etat.points / etat.juges
end

-- Passe la note i (ratée ou jouée) ; la suivante est attendue à « depart » + durée de la note.
-- Durée de base (sans l'attente d'énergie ou d'échéance de DoT ajoutée à l'affichage) : l'attente est
-- recalculée par la replanification, d'après l'état réel.
local function Suivante(etat, depart)
    local note = etat.notes[etat.i]
    etat.attendu = depart + (note.base or note.duree)
    etat.i = etat.i + 1
end

-- Cycle avec DoT : refait la suite de la partition à partir de la note i, d'après l'état réel
-- (expirations des DoT posés, prochain sort de remplissage). Sans DoT : rien à faire.
local function Replanifier(etat)
    if not etat.dynamique then return end
    local notes = etat.notes
    local reste = {}   -- notes d'ouverture pas encore jouées : gardées en tête
    for k = etat.i, #notes do
        if notes[k].rep == 0 then reste[#reste + 1] = notes[k] end
    end
    for k = #notes, etat.i, -1 do notes[k] = nil end
    local t = etat.attendu or 0
    local sim = { filler = etat.filler, rep = etat.rep, dots = {} }
    for id, exp in pairs(etat.dots) do sim.dots[id] = exp end
    if etat.en then
        sim.energie = etat.energieT and EnergieA(etat.energie, etat.energieT, t, etat.en) or etat.energie
        sim.energieT = t
    end
    for _, n in ipairs(reste) do
        n.t = t
        notes[#notes + 1] = n
        local dot = etat.plan.dots[n.id]
        if dot then sim.dots[n.id] = Expiration(dot, t) end
        if etat.en then sim.energie = math.max(0, sim.energie - (n.cout or 0)) end
        t = t + n.duree
    end
    if etat.en then sim.energieT = t end
    Prolonger(etat.plan, sim, notes, t, t + Partition.HORIZON)
    -- Une attente (énergie, ou échéance d'un DoT) avant la première note replanifiée allonge une note déjà
    -- jouée, hors de la partition refaite : l'heure attendue reprend donc celle de cette première note.
    if etat.attendu and notes[etat.i] and notes[etat.i].t > etat.attendu then etat.attendu = notes[etat.i].t end
end

-- Dépense d'énergie d'un sort lancé à t. Le sort est parti : l'énergie suffisait, même si le calcul disait
-- le contraire (il se recale alors sur le coût).
local function Depenser(etat, t, cout)
    local en = etat.en
    if not en then return end
    local energie = etat.energieT and EnergieA(etat.energie, etat.energieT, t, en) or en.depart
    cout = cout or 0
    if energie < cout then energie = cout end
    etat.energie, etat.energieT = energie - cout, t
end

-- Énergie calculée à l'instant t (nil si la partition n'a pas d'énergie). Pour l'affichage et le diagnostic.
function Partition.EnergieCalculee(etat, t)
    if not etat.en then return nil end
    if not etat.energieT then return etat.energie end
    return EnergieA(etat.energie, etat.energieT, t, etat.en)
end

-- Énergie réelle connue à l'instant t (lue sur la barre du HUD, si le jeu le permet) : le calcul s'y recale.
-- Retourne true si un recalage a eu lieu (écart d'au moins « seuil »).
function Partition.RecalerEnergie(etat, t, valeur, seuil)
    if not etat.en or not valeur then return false end
    local calcul = Partition.EnergieCalculee(etat, t)
    if calcul and math.abs(calcul - valeur) < (seuil or 5) then return false end
    etat.energie, etat.energieT = math.max(0, math.min(etat.en.max, valeur)), t
    Replanifier(etat)
    return true
end

-- Énergie pleine (le jeu ne signale plus de gains) : le calcul est recalé au maximum à l'instant t.
function Partition.EnergiePleine(etat, t)
    if not etat.en then return end
    etat.energie, etat.energieT = etat.en.max, t
    Replanifier(etat)
end

-- Après une note de remplissage jouée ou passée : le prochain sort de remplissage est le suivant.
local function AvancerRemplissage(etat, note)
    if etat.dynamique and note.fillerIndex then
        etat.filler = note.fillerIndex % #etat.plan.fillers + 1
        etat.rep = note.rep
    end
end

-- DoT du plan correspondant à ce sort (par nom), ou nil.
local function DotDuSort(etat, id)
    if not etat.avecDots then return nil end
    for _, e in ipairs(etat.plan.ordreDots) do
        if etat.egal(id, e.id) then return e end
    end
end

-- Un sort a été lancé à l'instant t (s depuis le départ de la session). dureeSort (facultatif) : son temps
-- d'incantation ; un sort hors partition repousse la note attendue d'autant (au moins un GCD).
-- Retourne la liste des verdicts produits : { genre = "parfait" | "bien" | "juste" | "rate" | "hors",
-- ecart, note (index), id, raison ("retard", "omis", "avance") }.
-- coutSort (facultatif) : coût en énergie du sort (voleur), pour un sort qui n'est pas dans la partition.
-- comboSort (facultatif) : points de combo du joueur au lancer (voleur), pour juger un coup de grâce.
function Partition.Jouer(etat, id, t, dureeSort, coutSort, comboSort)
    local verdicts = Partition.Avancer(etat, t)   -- notes passées avant ce sort
    if SERIES[id] and etat.serie == id then return verdicts end   -- tir suivant de la série en cours
    local note = etat.notes[etat.i]
    if not note then return verdicts end   -- partition terminée

    local function Juger(index, attendu)
        local n = etat.notes[index]
        -- Seul l'ordre compte après une série de tirs (temps libre) et pour la série elle-même : le premier tir
        -- automatique part au rythme du jeu (1,6 à 1,8 s après le sort précédent, mesuré), pas du joueur.
        local ecart = (attendu and not etat.serie and n.type ~= "serie") and (t - attendu) or 0
        -- Note qui attendait l'énergie, ou première note après une perte de contrôle : marge de réaction.
        if (n.attente or etat.reprise) and ecart > 0 then ecart = math.max(0, ecart - Partition.MARGE_REACTION) end
        etat.reprise = nil
        local comboAvant, comboMaxAvant = etat.combo, etat.comboMax
        local genre = Partition.Classer(ecart)
        -- DoT relancé un peu avant son échéance (moins d'un GCD) : accepté ; au-delà, c'est « écrasé » (plus haut).
        if n.dot and ecart < 0 then genre = "parfait" end
        -- Note qui attendait l'énergie, jouée plus tôt : l'énergie était là (le calcul était trop prudent).
        if n.attente and ecart < 0 then genre = "parfait" end
        Depenser(etat, t, n.cout or coutSort)
        local raison
        if genre == "rate" then raison = ecart > 0 and "retard" or "avance" end
        -- Coup de grâce lancé avec moins de points de combo que prévu. Prévu : les points des générateurs JOUÉS
        -- (dans la partition) depuis le coup de grâce précédent ; un générateur oublié est déjà compté « oublié »,
        -- il ne pénalise pas une deuxième fois. Reste l'attaque esquivée ou parée, qui ne donne pas de point.
        local prevu = n.finisseur and etat.pc or nil
        if prevu and comboSort and comboSort < prevu then genre, raison = "rate", "combo" end
        Noter(etat, genre, n.id, raison)
        verdicts[#verdicts + 1] = { genre = genre, ecart = ecart, note = index, id = n.id, raison = raison,
                                    combo = prevu and comboSort, comboPrevu = prevu }
        etat.dernier = { index = index, genre = genre, raison = raison, id = n.id, t = t, pcAvant = etat.pc,
                         comboAvant = comboAvant, comboMaxAvant = comboMaxAvant }
        if n.finisseur then
            etat.pc = 0
        elseif n.genere then
            etat.pc = math.min(etat.plan and etat.plan.options.comboMax or Partition.COMBO_MAX, etat.pc + n.genere)
        end
        AvancerRemplissage(etat, n)
        local dot = etat.avecDots and etat.plan.dots[n.id]
        if dot then
            etat.dernier.dotAvant = etat.dots[n.id]
            etat.dots[n.id] = Expiration(dot, t)
            etat.manques[n.id] = nil
        end
        Suivante(etat, t)
        etat.serie = SERIES[id] and id or nil
        Replanifier(etat)
    end

    if etat.avecDots then
        local dot = DotDuSort(etat, id)
        if dot then
            local exp = etat.dots[dot.id]
            if exp and exp - (t + (dot.d or 0)) > Partition.GCD then
                -- Relancé plus d'un GCD avant l'expiration : des dégâts du DoT précédent sont écrasés.
                Noter(etat, "rate", dot.id, "ecrase")
                verdicts[#verdicts + 1] = { genre = "rate", id = dot.id, raison = "ecrase",
                                            ecart = (t + (dot.d or 0)) - exp }
                etat.dots[dot.id] = Expiration(dot, t)
                Depenser(etat, t, dot.cout or coutSort)
                etat.serie = nil
                if etat.attendu then
                    etat.attendu = math.max(etat.attendu, t + math.max(dureeSort or dot.d or 0, Partition.GCD))
                end
                Replanifier(etat)
                return verdicts
            end
            -- DoT dû (ou presque) : joué maintenant, à sa place ou non. Il est jugé par rapport à son échéance.
            local k
            for j = etat.i, #etat.notes do
                if etat.egal(id, etat.notes[j].id) then k = j break end
            end
            if k == etat.i then
                Juger(etat.i, etat.attendu)
            else
                local n = k and table.remove(etat.notes, k) or { id = dot.id, type = "dot", d = dot.d or 0,
                    duree = DureeNote(dot, etat.plan.options), dot = dot.dot, rep = etat.rep }
                table.insert(etat.notes, etat.i, n)
                local echeance = exp and (exp - (dot.d or 0)) or etat.attendu
                Juger(etat.i, echeance)
            end
            return verdicts
        end

        -- Sort de remplissage : cherché dans la fenêtre, en ignorant les notes de DoT (elles restent dues et
        -- seront replanifiées) ; seuls les sorts de remplissage sautés comptent comme oubliés.
        local trouvee, sautes = nil, 0
        for k = etat.i, #etat.notes do
            local n = etat.notes[k]
            if not (n.dot and etat.plan.dots[n.id]) then
                if etat.egal(id, n.id) then
                    trouvee = k
                    break
                end
                sautes = sautes + 1
                if sautes > etat.fenetre then break end
            end
        end
        if trouvee then
            local premier = etat.vivante and etat.attendu == nil and etat.juges == 0
            local attendu = etat.attendu
            for k = etat.i, trouvee - 1 do
                local n = etat.notes[k]
                if not premier and not (n.dot and etat.plan.dots[n.id]) then
                    Noter(etat, "rate", n.id, "omis")
                    verdicts[#verdicts + 1] = { genre = "rate", note = k, id = n.id, raison = "omis" }
                    AvancerRemplissage(etat, n)
                end
            end
            for k = trouvee - 1, etat.i, -1 do table.remove(etat.notes, k) end
            Juger(etat.i, (not premier) and attendu or nil)
        elseif SERIES[id] then
            etat.serie = id
        else
            Noter(etat, "hors")
            verdicts[#verdicts + 1] = { genre = "hors", id = id }
            etat.serie = nil
            Depenser(etat, t, coutSort)
            if etat.attendu then
                etat.attendu = math.max(etat.attendu, t + math.max(dureeSort or 0, Partition.GCD))
                Replanifier(etat)
            end
        end
        return verdicts
    end

    -- Cycle sans DoT. Note correspondante : l'attendue, ou une suivante dans la fenêtre de recherche.
    local trouvee
    for k = etat.i, math.min(#etat.notes, etat.i + etat.fenetre) do
        if etat.egal(id, etat.notes[k].id) then
            trouvee = k
            break
        end
    end

    if trouvee == etat.i then
        Juger(etat.i, etat.attendu)
    elseif trouvee and etat.vivante and etat.attendu == nil and etat.juges == 0 then
        -- Partition vivante, premier sort du combat : on la prend là où le joueur commence, sans pénalité.
        etat.i = trouvee
        Juger(trouvee, nil)
    elseif trouvee then
        -- Notes sautées : oubliées ; le sort joué est jugé à la place de la première (le joueur enchaîne
        -- directement : les sorts sautés n'ont pas consommé de temps).
        for k = etat.i, trouvee - 1 do
            Noter(etat, "rate", etat.notes[k].id, "omis")
            verdicts[#verdicts + 1] = { genre = "rate", note = k, id = etat.notes[k].id, raison = "omis" }
        end
        local attendu = etat.attendu
        etat.i = trouvee
        Juger(trouvee, attendu)
    elseif SERIES[id] then
        -- Tir automatique hors de sa place : ignoré (il continue tout seul).
        etat.serie = id
    else
        -- Sort hors partition (proc, bouclier, soin) : il prend du temps, la note attendue est repoussée.
        Noter(etat, "hors")
        verdicts[#verdicts + 1] = { genre = "hors", id = id }
        etat.serie = nil
        Depenser(etat, t, coutSort)
        if etat.attendu then
            etat.attendu = math.max(etat.attendu, t + math.max(dureeSort or 0, Partition.GCD))
            Replanifier(etat)   -- partition à énergie : la suite dépend de l'énergie restante
        end
    end
    return verdicts
end

-- Dernière note jugée, si c'est bien ce sort et qu'elle n'a pas déjà été reprise (interrompue ou esquivée).
local function DerniereNote(etat, id)
    local d = etat.dernier
    if not d or d.interrompu or d.index ~= etat.i - 1 or not etat.egal(id, d.id) then return nil end
    return d
end

-- Retire le verdict de la note d (il ne compte plus, son erreur non plus).
local function AnnulerVerdict(etat, d)
    etat.compte[d.genre] = etat.compte[d.genre] - 1
    etat.points = etat.points - Partition.POINTS[d.genre]
    etat.juges = etat.juges - 1
    local e = d.raison and etat.erreurs[d.id]
    if e and (e[d.raison] or 0) > 0 then e[d.raison] = e[d.raison] - 1 end
    d.interrompu = true
end

-- La note d redevient la note attendue, à l'heure « attendu ».
local function Rejouer(etat, d, attendu)
    etat.i = d.index
    etat.attendu = attendu
    etat.serie = nil
    if d.pcAvant then etat.pc = d.pcAvant end
    if etat.dynamique then
        -- Le sort ne s'est pas appliqué : DoT remis à son expiration d'avant, remplissage remis sur cette note.
        local note = etat.notes[d.index]
        if etat.avecDots and etat.plan.dots[d.id] then etat.dots[d.id] = d.dotAvant end
        if note and note.fillerIndex then
            etat.filler = note.fillerIndex
            etat.rep = note.fillerIndex == 1 and note.rep - 1 or note.rep
        end
        Replanifier(etat)
    end
end

-- Incantation de la dernière note jugée interrompue (déplacement pendant la zone d'immobilité, ou autre cause)
-- à l'instant t. Son verdict est remplacé par « interrompu » (0 point, combo remis à zéro), et la note doit être
-- rejouée : elle redevient la note attendue, tout de suite. Sans effet si le sort n'est pas la dernière note
-- jugée ou si elle a déjà été déclarée interrompue (déplacement puis interruption du même sort).
function Partition.Interrompre(etat, id, t)
    local d = DerniereNote(etat, id)
    if not d then return {} end
    AnnulerVerdict(etat, d)
    Noter(etat, "interrompu", d.id)
    Rejouer(etat, d, t)
    return { { genre = "interrompu", note = d.index, id = d.id } }
end

-- Coup de la dernière note jugée esquivé, paré ou raté (repéré par les points de combo, à l'instant t) : ce n'est
-- pas une faute du joueur. Son verdict est retiré sans pénalité (la série de notes réussies est rétablie), la
-- note est à rejouer avant de passer à la suivante (après le temps de recharge global), et « rendu » d'énergie
-- est rendu (le jeu rend l'essentiel du coût d'un coup qui n'a pas porté).
function Partition.Esquiver(etat, id, t, rendu)
    local d = DerniereNote(etat, id)
    if not d then return {} end
    AnnulerVerdict(etat, d)
    if d.comboAvant then etat.combo, etat.comboMax = d.comboAvant, d.comboMaxAvant end
    etat.compte.esquive = (etat.compte.esquive or 0) + 1
    if etat.en and rendu and rendu > 0 then
        etat.energie = math.min(etat.en.max, Partition.EnergieCalculee(etat, t) + rendu)
        etat.energieT = t
    end
    local gcd = etat.plan and etat.plan.options.gcd or Partition.GCD
    Rejouer(etat, d, math.max(t, d.t + gcd))
    return { { genre = "esquive", note = d.index, id = d.id } }
end

-- Perte de contrôle (étourdi…) à l'instant t : la partition attend. La note attendue reste due « maintenant »
-- (rien n'est déclaré passé), et la première note jouée ensuite a la marge de réaction.
function Partition.Pause(etat, t)
    if not etat.attendu then return end
    if etat.attendu < t then etat.attendu = t end
    etat.reprise = true
end

-- Le temps passe (t : s depuis le départ). Une note non jouée quand l'heure de la suivante arrive est ratée.
-- Retourne la liste des verdicts produits.
function Partition.Avancer(etat, t)
    local verdicts = {}
    if etat.serie then return verdicts end   -- série de tirs en cours : temps libre
    while etat.attendu do
        local note = etat.notes[etat.i]
        if not note or t <= etat.attendu + note.duree then break end
        local dotDu = etat.avecDots and note.dot and etat.plan.dots[note.id]
        if dotDu and etat.manques[note.id] then
            -- DoT toujours pas relancé : déjà compté, il reste en tête de partition sans nouvelle pénalité.
        else
            Noter(etat, "rate", note.id, "passee")
            verdicts[#verdicts + 1] = { genre = "rate", note = etat.i, id = note.id, raison = "passee" }
            if dotDu then etat.manques[note.id] = true end
        end
        AvancerRemplissage(etat, note)
        etat.serie = nil
        Suivante(etat, etat.attendu)
        Replanifier(etat)   -- un DoT non posé reste dû : il revient en tête
    end
    return verdicts
end

-- Heures attendues des n prochaines notes (pour l'affichage) : { { index, note, t } }.
-- Avant le premier sort, la première note est attendue « maintenant » (tmaintenant).
function Partition.Prochaines(etat, n, tmaintenant)
    local liste = {}
    local t = etat.attendu or tmaintenant or 0
    for k = etat.i, math.min(#etat.notes, etat.i + n - 1) do
        local note = etat.notes[k]
        liste[#liste + 1] = { index = k, note = note, t = t }
        t = t + note.duree
    end
    return liste
end

return Partition
