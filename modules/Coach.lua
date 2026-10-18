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

-- Coach (jalon 8b) : progression d'un cycle et erreurs les plus fréquentes.
-- Lua pur, SANS API WoW (testable hors du jeu, voir tests/test_coach.lua).
--
-- Lignée d'un cycle : la session racine, les sessions d'amélioration et versions qui en descendent
-- (s.reference), et les combats guidés sur l'une d'elles (SalleDuTempsDB.combatsGuides).

local _, ns = ...

local Coach = {}
if ns then ns.Coach = Coach end

Coach.CONSEILS = {
    omis = "Souvent oublié : repère-le sur la timeline avant qu'il n'arrive, ou place-le sur une touche facile.",
    passee = "Il passe sans être joué : enchaîne-le dès la fin du sort précédent.",
    retard = "Lancé en retard : appuie juste avant la fin du sort précédent (jusqu'à 0,4 s d'avance compte comme Parfait).",
    avance = "Lancé trop tôt : attends la fin du temps de recharge global.",
    interrompu = "Interrompu : ne bouge pas pendant son incantation (zone orange de la timeline).",
    ecrase = "DoT relancé alors qu'il était encore actif : attends sa note, elle arrive à son expiration.",
    combo = "Coup de grâce lancé avec trop peu de points de combo : si une attaque a été esquivée ou parée, "
        .. "ajoute une attaque avant lui.",
}
Coach.LIBELLES = {
    omis = "oublié", passee = "pas joué", retard = "en retard", avance = "trop tôt", interrompu = "interrompu",
    ecrase = "écrasé", combo = "trop peu de points",
}

-- Identifiants (uid) de la lignée : la racine et toutes les sessions qui en descendent.
function Coach.Lignee(sessions, uidRacine)
    local membres = { [uidRacine] = true }
    local ajoute = true
    while ajoute do
        ajoute = false
        for _, s in ipairs(sessions or {}) do
            if s.uid and not membres[s.uid] and s.reference and membres[s.reference] then
                membres[s.uid] = true
                ajoute = true
            end
        end
    end
    return membres
end

-- Racine de la lignée d'une session : on remonte les références tant que la session référencée existe.
function Coach.Racine(sessions, uid)
    local parUid = {}
    for _, s in ipairs(sessions or {}) do
        if s.uid then parUid[s.uid] = s end
    end
    local vus = {}
    while parUid[uid] and parUid[uid].reference and parUid[parUid[uid].reference] and not vus[uid] do
        vus[uid] = true
        uid = parUid[uid].reference
    end
    return uid
end

-- Points de progression, du plus ancien au plus récent :
-- { date, genre ("session" | "amelioration" | "guide"), nom, dps, precision, pleine (s à énergie pleine) }.
-- La date « AAAA-MM-JJ HH:MM » sert de clé de tri (à égalité, l'ordre d'enregistrement est gardé).
function Coach.Points(sessions, combats, uidRacine)
    local membres = Coach.Lignee(sessions, uidRacine)
    local points = {}
    for _, s in ipairs(sessions or {}) do
        if s.uid and membres[s.uid] then
            points[#points + 1] = {
                date = s.date or "", genre = s.reference and "amelioration" or "session",
                nom = s.nom or s.etiquette, dps = s.dps, precision = s.jugement and s.jugement.precision,
                pleine = s.energiePleine, ordre = #points,
            }
        end
    end
    for _, c in ipairs(combats or {}) do
        if c.uid and membres[c.uid] then
            points[#points + 1] = { date = c.date or "", genre = "guide", nom = "Combat guidé", dps = c.dps,
                                    precision = c.precision, pleine = c.energiePleine, ordre = #points }
        end
    end
    table.sort(points, function(a, b)
        if a.date ~= b.date then return a.date < b.date end
        return a.ordre < b.ordre
    end)
    for _, p in ipairs(points) do p.ordre = nil end
    return points
end

-- Tendance d'une mesure (« dps » ou « precision ») : moyenne des n derniers points qui l'ont, contre la
-- moyenne des n précédents. Retourne recente, ancienne (nil s'il n'y a pas assez de points), nombre récent.
function Coach.Tendance(points, cle, n)
    n = n or 5
    local valeurs = {}
    for _, p in ipairs(points) do
        if p[cle] then valeurs[#valeurs + 1] = p[cle] end
    end
    local function Moyenne(debut, fin)
        if fin < debut or debut < 1 then return nil end
        local total = 0
        for i = debut, fin do total = total + valeurs[i] end
        return total / (fin - debut + 1)
    end
    local nb = #valeurs
    if nb == 0 then return nil end
    local recente = Moyenne(math.max(1, nb - n + 1), nb)
    local ancienne = Moyenne(math.max(1, nb - 2 * n + 1), nb - n)
    return recente, ancienne, math.min(n, nb)
end

-- Erreurs cumulées de la lignée, par sort, triées de la plus fréquente à la moins fréquente :
-- { { id, total, parRaison = { omis = n, ... }, raison (la plus fréquente), sources (sessions ou combats
-- où le sort a été en erreur), conseil } }.
function Coach.Erreurs(sessions, combats, uidRacine, max)
    local membres = Coach.Lignee(sessions, uidRacine)
    local parSort = {}
    local function Ajouter(erreurs)
        for id, raisons in pairs(erreurs or {}) do
            local e = parSort[id] or { id = id, total = 0, parRaison = {}, sources = 0 }
            local dansCetteSource = false
            for raison, n in pairs(raisons) do
                if n > 0 then
                    e.parRaison[raison] = (e.parRaison[raison] or 0) + n
                    e.total = e.total + n
                    dansCetteSource = true
                end
            end
            if dansCetteSource then e.sources = e.sources + 1 end
            parSort[id] = e
        end
    end
    local sources = 0
    for _, s in ipairs(sessions or {}) do
        if s.uid and membres[s.uid] and s.jugement then
            sources = sources + 1
            Ajouter(s.jugement.erreurs)
        end
    end
    for _, c in ipairs(combats or {}) do
        if c.uid and membres[c.uid] then
            sources = sources + 1
            Ajouter(c.erreurs)
        end
    end
    local liste = {}
    for _, e in pairs(parSort) do
        if e.total > 0 then
            local meilleure, n = nil, 0
            for raison, k in pairs(e.parRaison) do
                if k > n or (k == n and raison < meilleure) then meilleure, n = raison, k end
            end
            e.raison = meilleure
            e.conseil = Coach.CONSEILS[meilleure]
            liste[#liste + 1] = e
        end
    end
    table.sort(liste, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.id < b.id
    end)
    if max then
        for i = #liste, max + 1, -1 do liste[i] = nil end
    end
    return liste, sources
end

return Coach
