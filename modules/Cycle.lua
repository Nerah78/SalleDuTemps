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

-- Cycle : détection du cycle de rotation dans une séquence de sorts.
-- Lua pur, SANS API WoW : chargé par le jeu (via le .toc) ou hors du jeu (dofile, voir tests/).
--
-- Principe : pour chaque longueur de cycle L, chaque suite de L sorts consécutifs prise dans le début de
-- la session est un motif candidat (un proc dans la première répétition ne fausse donc pas tout).
-- La session entière est alignée sur le motif répété : les sorts de tête qui n'y entrent pas forment
-- l'ouverture ; ensuite, les sorts en trop (procs) et les sorts manquants sont comptés comme écarts.
-- On garde le motif le plus fiable ; à fiabilité presque égale, le plus court, puis l'ouverture la plus courte.

local _, ns = ...

local Cycle = {}
if ns then ns.Cycle = Cycle end

-- À incrémenter à chaque changement de règle : les cycles mis en cache dans les sessions sont recalculés.
Cycle.VERSION = 2

-- Ignorés par la détection.
Cycle.IGNORES = {
    [6603] = true,   -- Attaque (activation de l'attaque au corps à corps)
}

-- Tirs automatiques : comptés dans le cycle (grosse part des dégâts à bas niveau), mais une série de tirs
-- consécutifs ne forme qu'une étape, car leur nombre varie d'une répétition à l'autre.
Cycle.SERIES = {
    [75] = true,     -- Tir automatique
    [5019] = true,   -- Tir (baguette)
}

-- Identifiant de lancer -> identifiant sous lequel le compteur range les dégâts, quand ils diffèrent.
Cycle.DEGATS_ASSOCIES = {
    [5019] = 75,     -- les tirs de baguette sont comptés sous Tir automatique
}

Cycle.LONGUEUR_MAX = 12
Cycle.OUVERTURE_MAX = 10
Cycle.REPETITIONS_MIN = 2
Cycle.TOLERANCE = 0.02        -- écart de score sous lequel on préfère le cycle le plus court
-- Pénalité par sort du motif : un motif long peut « avaler » un proc et gagner un peu de fiabilité ;
-- il ne l'emporte que s'il explique nettement mieux la session.
Cycle.PENALITE_LONGUEUR = 0.015
Cycle.SEUIL_FIABILITE = 0.6   -- en dessous : proposer une session plus longue

-- Sorts lancés et retenus pour la détection : { { id, t, rang (index dans sorts), n (tirs de la série) } }.
-- options.degats (facultatif) : { [spellID] = dégâts } du compteur ; s'il est fourni, les sorts sans dégâts
-- (bouclier, soins, contrôle) sont écartés.
function Cycle.Jetons(sorts, options)
    options = options or {}
    local ignores = options.ignores or Cycle.IGNORES
    local degats = options.degats
    if degats and next(degats) == nil then degats = nil end
    local jetons = {}
    for rang, e in ipairs(sorts or {}) do
        local id = e.ok and e.id
        local retenu = id and not ignores[id]
        if retenu and degats and not degats[Cycle.DEGATS_ASSOCIES[id] or id] then retenu = false end
        if retenu then
            local dernier = jetons[#jetons]
            if Cycle.SERIES[id] and dernier and dernier.id == id then
                dernier.n = dernier.n + 1
            else
                jetons[#jetons + 1] = { id = id, t = e.t or 0, rang = rang, n = 1 }
            end
        end
    end
    return jetons
end

-- Le motif est-il la répétition d'un motif plus court ? (ex. A B A B)
local function Periodique(motif)
    local L = #motif
    for d = 1, L - 1 do
        if L % d == 0 then
            local repete = true
            for i = 1, L do
                if motif[i] ~= motif[(i - 1) % d + 1] then
                    repete = false
                    break
                end
            end
            if repete then return true end
        end
    end
    return false
end

-- Aligne toute la session sur le motif répété.
local function Aligner(jetons, motif)
    local L, n = #motif, #jetons
    local j = 1              -- position attendue dans le motif
    local correspondances, omissions, repetitions = 0, 0, 0
    local ouverture, ecarts, debuts = {}, {}, {}

    local function Correspond(k, jeton)
        if k == 1 then debuts[#debuts + 1] = jeton.t end
        correspondances = correspondances + 1
        if k == L then repetitions = repetitions + 1 end
        j = k % L + 1
    end

    for i = 1, n do
        local jeton = jetons[i]
        local suivant = j % L + 1
        if correspondances == 0 and jeton.id ~= motif[1] then
            -- Avant le premier sort du cycle : ouverture.
            ouverture[#ouverture + 1] = jeton.id
        elseif jeton.id == motif[j] then
            Correspond(j, jeton)
        elseif L > 1 and jeton.id == motif[suivant] then
            -- Le sort attendu a été sauté.
            omissions = omissions + 1
            ecarts[#ecarts + 1] = { genre = "omis", id = motif[j], t = jeton.t, rang = jeton.rang }
            Correspond(suivant, jeton)
        else
            -- Sort en trop (proc, erreur) : mis de côté, la position attendue ne bouge pas.
            ecarts[#ecarts + 1] = { genre = "insere", id = jeton.id, t = jeton.t, rang = jeton.rang }
        end
    end

    local duree
    if #debuts >= 2 then duree = (debuts[#debuts] - debuts[1]) / (#debuts - 1) end
    local evalues = n - #ouverture + omissions
    return {
        ouverture = ouverture,
        fiabilite = evalues > 0 and correspondances / evalues or 0,
        repetitions = repetitions,
        ecarts = ecarts,
        duree = duree,
        debutCycle = debuts[1],
    }
end

-- Détecte le cycle. sorts : séquence d'une session (format : voir Data.lua).
-- options (facultatif) : degats (voir Jetons), ignores, longueurMax, ouvertureMax, repetitionsMin.
-- Retourne nil si aucun motif ne se répète au moins repetitionsMin fois, sinon :
--   { ouverture = { spellID… }, cycle = { spellID… }, longueur, duree (s, moyenne entre deux départs de cycle),
--     repetitions (complètes), fiabilite (0 à 1), ecarts = { { genre = "insere" | "omis", id, t, rang } },
--     nbSorts (sorts retenus), debutCycle (t du premier sort du cycle) }
function Cycle.Detecter(sorts, options)
    options = options or {}
    local jetons = Cycle.Jetons(sorts, options)
    local n = #jetons
    local longueurMax = options.longueurMax or Cycle.LONGUEUR_MAX
    local ouvertureMax = options.ouvertureMax or Cycle.OUVERTURE_MAX
    local repetitionsMin = options.repetitionsMin or Cycle.REPETITIONS_MIN

    local meilleur
    for L = 1, math.min(longueurMax, math.floor(n / 2)) do
        -- Motifs candidats : fenêtres de L sorts dans l'ouverture possible et les premières répétitions.
        local vus = {}
        for p = 1, math.min(n - L + 1, ouvertureMax + 3 * L) do
            local motif = {}
            for i = 1, L do motif[i] = jetons[p + i - 1].id end
            local cle = table.concat(motif, ",")
            if not vus[cle] and not Periodique(motif) then
                vus[cle] = true
                local r = Aligner(jetons, motif)
                if r.repetitions >= repetitionsMin and #r.ouverture <= ouvertureMax then
                    local score = r.fiabilite - Cycle.PENALITE_LONGUEUR * L
                    local mieux
                    if not meilleur then
                        mieux = true
                    elseif score > meilleur.score + Cycle.TOLERANCE then
                        mieux = true
                    elseif score >= meilleur.score - Cycle.TOLERANCE then
                        -- Scores proches : le plus court, puis l'ouverture la plus courte. Un sort présent
                        -- dans une répétition sur deux (proc ou oubli, indiscernables) reste hors du cycle.
                        mieux = L < meilleur.longueur
                            or (L == meilleur.longueur and #r.ouverture < #meilleur.ouverture)
                    end
                    if mieux then
                        meilleur = {
                            ouverture = r.ouverture,
                            cycle = motif,
                            longueur = L,
                            duree = r.duree,
                            repetitions = r.repetitions,
                            fiabilite = r.fiabilite,
                            score = score,
                            ecarts = r.ecarts,
                            nbSorts = n,
                            debutCycle = r.debutCycle,
                        }
                    end
                end
            end
        end
    end
    return meilleur
end

-- ---------------------------------------------------------------------
-- Version éditée du cycle (jalon 5) : liste d'étapes modifiable, enregistrée à côté du cycle détecté.
-- Étape : { id, actif (booléen), type ("cast" | "canal" | "instant" | "serie"), d (durée d'incantation, s) }
-- ---------------------------------------------------------------------
Cycle.GCD = 1.5

-- Type et durée d'incantation d'un sort, d'après la séquence de la session.
function Cycle.TypeSort(id, sorts)
    if Cycle.SERIES[id] then return "serie", 0 end
    for _, e in ipairs(sorts or {}) do
        if e.ok and e.id == id then
            if e.k == "canal" then return "canal", e.d or 0 end
            if (e.d or 0) > 0 then return "cast", e.d end
            return "instant", 0
        end
    end
    return "instant", 0
end

-- Durée d'un DoT lue dans la description d'un sort, ou nil si ce n'en est pas un.
-- Un DoT inflige des dégâts « en / pendant / sur N sec » (anglais : « over N sec »). S'il y a plusieurs durées
-- (dégâts directs puis DoT, comme Flammes sacrées), la dernière est celle du DoT.
local MOTS_DUREE = { en = true, pendant = true, sur = true, over = true, ["for"] = true }

function Cycle.DureeDot(texte)
    if type(texte) ~= "string" or texte == "" then return nil end
    local bas = texte:lower()
    if not (bas:find("dégâts", 1, true) or bas:find("damage", 1, true)) then return nil end
    local duree
    for mot, nombre in bas:gmatch("(%a+)%s+(%d+[,%.]?%d*)%s*sec") do
        if MOTS_DUREE[mot] then duree = tonumber((nombre:gsub(",", "."))) end
    end
    return duree
end

-- Rôle d'un sort pour les points de combo (voleur), d'après sa description : "finisseur" (coup de grâce, qui
-- dépense les points), "generateur" (qui en ajoute ; second résultat : combien), ou nil.
function Cycle.TypeCombo(texte)
    if type(texte) ~= "string" or texte == "" then return nil end
    local bas = texte:lower()
    if bas:find("coup de grâce", 1, true) or bas:find("finishing move", 1, true) then return "finisseur" end
    local nombre = bas:match("(%d+)%s+points?%s+de%s+combo") or bas:match("(%d+)%s+combo%s+points?")
    if nombre then return "generateur", tonumber(nombre) end
    if bas:find("point de combo", 1, true) or bas:find("points de combo", 1, true) or bas:find("combo point", 1, true) then
        return "generateur", 1
    end
    return nil
end

-- Étapes éditables à partir d'un cycle détecté (toutes actives).
-- dureeDot (facultatif) : fonction(id) → durée du DoT en s, ou nil ; les sorts reconnus deviennent des étapes
-- de type "dot" (sauf canalisations et séries de tirs).
function Cycle.Etapes(cycle, sorts, dureeDot)
    local etapes = {}
    for i, id in ipairs(cycle and cycle.cycle or {}) do
        local genre, d = Cycle.TypeSort(id, sorts)
        local etape = { id = id, actif = true, type = genre, d = d }
        if dureeDot and genre ~= "canal" and genre ~= "serie" then
            local duree = dureeDot(id)
            if duree and duree > 0 then
                etape.type, etape.dot = "dot", duree
            end
        end
        etapes[i] = etape
    end
    return etapes
end

-- Durée estimée d'un tour de cycle : temps d'incantation (au moins un temps de recharge global) des étapes
-- actives. Les séries de tirs n'ont pas de durée fixe : elles sont comptées à part.
-- Retourne duree (s), nbActives, nbSeries.
function Cycle.Estimer(etapes, gcd)
    gcd = gcd or Cycle.GCD
    local duree, actives, series = 0, 0, 0
    for _, e in ipairs(etapes or {}) do
        if e.actif then
            actives = actives + 1
            if e.type == "serie" then
                series = series + 1
            else
                duree = duree + math.max(e.d or 0, gcd)
            end
        end
    end
    return duree, actives, series
end

-- Identifiants des étapes actives, dans l'ordre (pour l'affichage en partition).
function Cycle.Actives(etapes)
    local ids = {}
    for _, e in ipairs(etapes or {}) do
        if e.actif then ids[#ids + 1] = e.id end
    end
    return ids
end

return Cycle
