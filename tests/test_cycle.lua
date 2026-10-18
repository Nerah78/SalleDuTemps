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

-- Tests de modules/Cycle.lua, hors du jeu : lua tests/test_cycle.lua
-- Rejoue aussi chaque trace de tests/traces/ listée dans TRACES.

local dossier = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local Cycle = dofile(dossier .. "/../modules/Cycle.lua")

local reussis, echecs = 0, 0

local function Verifier(nom, condition, detail)
    if condition then
        reussis = reussis + 1
    else
        echecs = echecs + 1
        print("ÉCHEC : " .. nom .. (detail and (" (" .. detail .. ")") or ""))
    end
end

local function Liste(t)
    local parties = {}
    for i, v in ipairs(t or {}) do parties[i] = tostring(v) end
    return "{" .. table.concat(parties, ",") .. "}"
end

local function Egales(a, b) return Liste(a) == Liste(b) end

-- Séquence de sorts à partir d'une liste d'identifiants, un sort toutes les 1,5 s.
local function Sequence(ids)
    local sorts = {}
    for i, id in ipairs(ids) do
        sorts[i] = { t = (i - 1) * 1.5, id = id, d = 0, k = "instant", ok = true }
    end
    return sorts
end

local function Repeter(motif, fois, dans)
    dans = dans or {}
    for _ = 1, fois do
        for _, id in ipairs(motif) do dans[#dans + 1] = id end
    end
    return dans
end

-- Identifiants fictifs : DoT 1, Feu 2, Instant 3, ouverture 10 et 11, proc 9.
local MOTIF = { 1, 2, 2, 3, 2, 2 }

-- 1. Exemple de la spécification : ouverture de 2 sorts, puis 6 fois le cycle de 6 sorts.
do
    local ids = Repeter(MOTIF, 6, { 10, 11 })
    local r = Cycle.Detecter(Sequence(ids))
    Verifier("spec : cycle trouvé", r ~= nil)
    if r then
        Verifier("spec : cycle", Egales(r.cycle, MOTIF), Liste(r.cycle))
        Verifier("spec : ouverture", Egales(r.ouverture, { 10, 11 }), Liste(r.ouverture))
        Verifier("spec : répétitions", r.repetitions == 6, tostring(r.repetitions))
        Verifier("spec : fiabilité", r.fiabilite == 1, tostring(r.fiabilite))
        Verifier("spec : durée", r.duree and math.abs(r.duree - 9) < 1e-6, tostring(r.duree))
        Verifier("spec : aucun écart", #r.ecarts == 0, tostring(#r.ecarts))
    end
end

-- 2. Un seul sort répété (ex. Éclair de givre en boucle).
do
    local r = Cycle.Detecter(Sequence(Repeter({ 5 }, 20)))
    Verifier("spam : cycle d'un sort", r and r.longueur == 1 and r.cycle[1] == 5, r and Liste(r.cycle))
    Verifier("spam : 20 répétitions", r and r.repetitions == 20, r and tostring(r.repetitions))
end

-- 3. Procs insérés au hasard : mis de côté sans casser la détection.
do
    local ids = Repeter(MOTIF, 6)
    table.insert(ids, 5, 9)
    table.insert(ids, 18, 9)
    table.insert(ids, 31, 9)
    local r = Cycle.Detecter(Sequence(ids))
    Verifier("procs : cycle", r and Egales(r.cycle, MOTIF), r and Liste(r.cycle))
    Verifier("procs : sans ouverture", r and #r.ouverture == 0, r and Liste(r.ouverture))
    Verifier("procs : 3 écarts insérés", r and #r.ecarts == 3 and r.ecarts[1].genre == "insere", r and tostring(#r.ecarts))
    Verifier("procs : fiabilité > 0,9", r and r.fiabilite > 0.9, r and tostring(r.fiabilite))
end

-- 4. Un sort oublié dans une répétition.
do
    local ids = Repeter(MOTIF, 6)
    table.remove(ids, 15)   -- un « Feu » de la 3e répétition
    local r = Cycle.Detecter(Sequence(ids))
    Verifier("omission : cycle", r and Egales(r.cycle, MOTIF), r and Liste(r.cycle))
    local omis = 0
    for _, e in ipairs(r and r.ecarts or {}) do if e.genre == "omis" then omis = omis + 1 end end
    Verifier("omission : 1 sort omis", omis == 1, tostring(omis))
end

-- 5. Baguette : une série de tirs consécutifs compte pour une étape du cycle, quel que soit le nombre de tirs.
do
    local ids = {}
    for rep = 1, 4 do
        for _, id in ipairs(MOTIF) do ids[#ids + 1] = id end
        for _ = 1, rep + 1 do ids[#ids + 1] = 5019 end   -- 2, 3, 4 puis 5 tirs
    end
    local r = Cycle.Detecter(Sequence(ids))
    local attendu = { 1, 2, 2, 3, 2, 2, 5019 }
    Verifier("baguette : série dans le cycle", r and Egales(r.cycle, attendu) and r.nbSorts == 28,
        r and (Liste(r.cycle) .. " / " .. r.nbSorts))
end

-- 9. Sorts sans dégâts (bouclier 50, soin 51) écartés quand les dégâts du compteur sont fournis.
do
    local ids = {}
    for rep = 1, 5 do
        for _, id in ipairs(MOTIF) do ids[#ids + 1] = id end
        ids[#ids + 1] = rep % 2 == 0 and 50 or 51
    end
    local r = Cycle.Detecter(Sequence(ids), { degats = { [1] = 100, [2] = 300, [3] = 50 } })
    Verifier("sans dégâts : écartés", r and Egales(r.cycle, MOTIF) and #r.ecarts == 0, r and Liste(r.cycle))
    -- Sans dégâts fournis (compteur illisible), rien n'est écarté.
    local r2 = Cycle.Detecter(Sequence(ids))
    Verifier("sans dégâts : compteur absent", r2 and r2.nbSorts == 35, r2 and tostring(r2.nbSorts))
end

-- 6. Sorts interrompus (ok = false) ignorés.
do
    local sorts = Sequence(Repeter(MOTIF, 4))
    table.insert(sorts, 4, { t = 4, id = 2, d = 2.5, k = "cast", ok = false })
    local r = Cycle.Detecter(sorts)
    Verifier("interrompu : ignoré", r and Egales(r.cycle, MOTIF) and #r.ecarts == 0, r and Liste(r.cycle))
end

-- 7. Séquence trop courte : pas de cycle.
do
    Verifier("court : rien", Cycle.Detecter(Sequence({ 1, 2, 3 })) == nil)
    Verifier("vide : rien", Cycle.Detecter({}) == nil)
end

-- 8. Pas de rotation décalée : sans ouverture, le cycle commence au premier sort.
do
    local r = Cycle.Detecter(Sequence(Repeter({ 1, 2, 3 }, 5)))
    Verifier("rotation : début au premier sort", r and Egales(r.cycle, { 1, 2, 3 }) and #r.ouverture == 0, r and Liste(r.cycle))
end

-- 10. Version éditée : étapes tirées du cycle détecté, types, estimation de durée.
do
    local sorts = {
        { t = 0, id = 1, d = 2.5, k = "cast", ok = true },
        { t = 2.5, id = 2, d = 0, k = "instant", ok = true },
        { t = 4, id = 3, d = 3, k = "canal", ok = true },
        { t = 7, id = 5019, d = 0, k = "instant", ok = true },
    }
    local etapes = Cycle.Etapes({ cycle = { 1, 2, 3, 5019 } }, sorts)
    Verifier("édition : 4 étapes", #etapes == 4, tostring(#etapes))
    Verifier("édition : types", etapes[1].type == "cast" and etapes[2].type == "instant"
        and etapes[3].type == "canal" and etapes[4].type == "serie",
        etapes[1].type .. "," .. etapes[2].type .. "," .. etapes[3].type .. "," .. etapes[4].type)
    local duree, actives, series = Cycle.Estimer(etapes)
    -- 2,5 (incantation) + 1,5 (instantané = GCD) + 3 (canalisation) ; la série est comptée à part.
    Verifier("édition : durée estimée", math.abs(duree - 7) < 1e-9 and actives == 4 and series == 1,
        string.format("%s / %d / %d", tostring(duree), actives, series))
    etapes[2].actif = false
    local duree2, actives2 = Cycle.Estimer(etapes)
    Verifier("édition : étape désactivée", math.abs(duree2 - 5.5) < 1e-9 and actives2 == 3, tostring(duree2))
    Verifier("édition : actives", Egales(Cycle.Actives(etapes), { 1, 3, 5019 }), Liste(Cycle.Actives(etapes)))
    Verifier("édition : sans cycle", #Cycle.Etapes(nil, sorts) == 0)
end

-- 11. DoT : durée lue dans la description, étapes de type "dot".
do
    local D = Cycle.DureeDot
    Verifier("dot : Mot de l'ombre : Douleur", D("Une douleur intense inflige 66 points de dégâts d'Ombre en 18 sec.") == 18)
    Verifier("dot : Peste dévorante", D("Afflige la cible d'une maladie qui inflige 152 points de dégâts d'Ombre en 24 sec.") == 24)
    Verifier("dot : Flammes sacrées (dernière durée)", D("Purifie la cible et lui inflige 84 à 105 points de dégâts du Sacré, puis 21 points de dégâts supplémentaires en 10 sec.") == 10)
    Verifier("dot : décimale", D("Inflige 40 points de dégâts de Feu pendant 12,5 sec.") == 12.5)
    Verifier("dot : anglais", D("Causes 66 Shadow damage over 18 sec.") == 18)
    Verifier("dot : dégâts directs seuls", D("Inflige 18 à 22 points de dégâts de Feu.") == nil)
    Verifier("dot : soin sur la durée exclu", D("Rend 45 points de vie en 15 sec.") == nil)
    Verifier("dot : texte absent", D(nil) == nil and D("") == nil)

    local sorts = {
        { t = 0, id = 970, d = 0, k = "instant", ok = true },
        { t = 1.5, id = 15407, d = 3, k = "canal", ok = true },
        { t = 4.5, id = 5019, d = 0, k = "instant", ok = true },
        { t = 6, id = 585, d = 2.5, k = "cast", ok = true },
    }
    local durees = { [970] = 18, [15407] = 3, [5019] = 4 }
    local etapes = Cycle.Etapes({ cycle = { 970, 15407, 5019, 585 } }, sorts, function(id) return durees[id] end)
    Verifier("dot : étape DoT", etapes[1].type == "dot" and etapes[1].dot == 18)
    Verifier("dot : canalisation et série gardées", etapes[2].type == "canal" and etapes[3].type == "serie")
    Verifier("dot : sort sans DoT inchangé", etapes[4].type == "cast" and etapes[4].dot == nil)
    Verifier("dot : sans fonction, rien ne change", Cycle.Etapes({ cycle = { 970 } }, sorts)[1].type == "instant")
end

-- 12. Points de combo : rôle du sort lu dans sa description.
do
    local T = Cycle.TypeCombo
    local role, n = T("Une attaque instantanée qui inflige les dégâts de l'arme plus 3. Ajoute 1 point de combo.")
    Verifier("combo : générateur", role == "generateur" and n == 1, tostring(role))
    role, n = T("Ajoute 2 points de combo.")
    Verifier("combo : générateur de 2 points", role == "generateur" and n == 2)
    Verifier("combo : coup de grâce", T("Coup de grâce qui inflige des dégâts, selon les points de combo :\n1 point : 6-10 dégâts") == "finisseur")
    Verifier("combo : anglais", T("Finishing move that causes damage per combo point") == "finisseur"
        and T("An instant strike that causes 3 damage. Awards 1 combo point.") == "generateur")
    Verifier("combo : sans rapport", T("Inflige 18 à 22 points de dégâts de Feu.") == nil and T(nil) == nil)
end

-- Traces réelles (tests/traces/*.lua, chacune retourne une session) : la détection ne doit pas planter.
-- Données de jeu personnelles, gardées hors du dépôt (.gitignore) : une trace absente est ignorée.
local TRACES = { "pretre_test_10s", "pretre_60s_araignee" }
for _, nom in ipairs(TRACES) do
    local chemin = dossier .. "/traces/" .. nom .. ".lua"
    local present = io.open(chemin, "r")
    if present then present:close() end
    local ok, session = false, nil
    if present then ok, session = pcall(dofile, chemin) else print("trace " .. nom .. " absente : ignorée") end
    if present then Verifier("trace " .. nom .. " : chargée", ok, not ok and tostring(session) or nil) end
    if ok then
        local okD, r = pcall(Cycle.Detecter, session.sorts, { degats = session.parSort })
        Verifier("trace " .. nom .. " : détection", okD, not okD and tostring(r) or nil)
        if okD and session.attendu then
            Verifier("trace " .. nom .. " : cycle attendu", r and Egales(r.cycle, session.attendu), r and Liste(r.cycle) or "nil")
        end
    end
end

print(string.format("%d tests réussis, %d échecs", reussis, echecs))
if echecs > 0 then os.exit(1) end
