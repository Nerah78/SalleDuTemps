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

-- Tests de modules/Coach.lua, hors du jeu : lua tests/test_coach.lua

local dossier = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local Coach = dofile(dossier .. "/../modules/Coach.lua")

local reussis, echecs = 0, 0
local function Verifier(nom, condition, detail)
    if condition then
        reussis = reussis + 1
    else
        echecs = echecs + 1
        print("ÉCHEC : " .. nom .. (detail and (" (" .. tostring(detail) .. ")") or ""))
    end
end
local function Proche(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 1e-9 end

-- Lignée : 1 (racine) ← 2 (amélioration) ← 3 (amélioration de l'amélioration) ; 4 sans lien.
local sessions = {
    { uid = 1, date = "2026-10-17 11:27", dps = 30, nom = "Test 01" },
    { uid = 2, date = "2026-10-17 12:37", dps = 33, reference = 1,
      jugement = { precision = 0.6, erreurs = { [970] = { omis = 2 }, [15262] = { interrompu = 1 } } } },
    { uid = 4, date = "2026-10-17 13:00", dps = 50, nom = "Autre cycle" },
    { uid = 3, date = "2026-10-17 14:00", dps = 36, reference = 2,
      jugement = { precision = 0.8, erreurs = { [970] = { omis = 1, retard = 1 } } } },
}
local combats = {
    { uid = 3, date = "2026-10-17 15:00", precision = 0.9, dps = 38, erreurs = { [2944] = { passee = 1 } } },
    { uid = 4, date = "2026-10-17 15:10", precision = 0.1, erreurs = { [1] = { omis = 9 } } },   -- autre lignée
    { uid = 1, date = "2026-10-17 12:00", precision = 0.5, erreurs = {} },
}

-- 1. Lignée
do
    local m = Coach.Lignee(sessions, 1)
    Verifier("lignée : racine et descendants", m[1] and m[2] and m[3] and not m[4])
    local m2 = Coach.Lignee(sessions, 2)
    Verifier("lignée : depuis une amélioration", m2[2] and m2[3] and not m2[1])
end

-- 1 bis. Racine : depuis l'amélioration d'une amélioration, on remonte à la session 1.
do
    Verifier("racine : remonte la lignée", Coach.Racine(sessions, 3) == 1)
    Verifier("racine : session sans référence", Coach.Racine(sessions, 4) == 4)
    local orphelin = { { uid = 7, reference = 99 } }   -- référence supprimée
    Verifier("racine : référence disparue", Coach.Racine(orphelin, 7) == 7)
end

-- 2. Points, dans l'ordre chronologique, sans l'autre lignée
do
    local p = Coach.Points(sessions, combats, 1)
    Verifier("points : 5", #p == 5, #p)
    local ordre = {}
    for i, x in ipairs(p) do ordre[i] = x.genre end
    Verifier("points : ordre et genres", table.concat(ordre, ",") == "session,guide,amelioration,amelioration,guide",
        table.concat(ordre, ","))
    Verifier("points : précision d'une amélioration", Proche(p[3].precision, 0.6))
    Verifier("points : DPS d'un combat guidé", p[5].dps == 38)
end

-- 3. Tendance : précisions 0,5 ; 0,6 ; 0,8 ; 0,9 → sur 2 : récente 0,85, ancienne 0,55
do
    local p = Coach.Points(sessions, combats, 1)
    local recente, ancienne, n = Coach.Tendance(p, "precision", 2)
    Verifier("tendance : précision", Proche(recente, 0.85) and Proche(ancienne, 0.55) and n == 2,
        tostring(recente) .. " / " .. tostring(ancienne))
    local r1, a1 = Coach.Tendance(p, "precision", 5)
    Verifier("tendance : pas assez de points pour comparer", Proche(r1, 0.7) and a1 == nil, tostring(a1))
    Verifier("tendance : aucune valeur", Coach.Tendance({}, "dps") == nil)
end

-- 4. Erreurs les plus fréquentes, avec conseil
do
    local liste, sources = Coach.Erreurs(sessions, combats, 1)
    Verifier("erreurs : sources (2 sessions jugées + 2 combats)", sources == 4, sources)
    Verifier("erreurs : 3 sorts", #liste == 3, #liste)
    Verifier("erreurs : Douleur en tête", liste[1].id == 970 and liste[1].total == 4, liste[1].id)
    Verifier("erreurs : raison dominante et conseil", liste[1].raison == "omis" and liste[1].conseil == Coach.CONSEILS.omis)
    Verifier("erreurs : nombre de sources", liste[1].sources == 2, liste[1].sources)
    Verifier("erreurs : autre lignée exclue", (function()
        for _, e in ipairs(liste) do if e.id == 1 then return false end end
        return true
    end)())
    Verifier("erreurs : limite", #Coach.Erreurs(sessions, combats, 1, 2) == 2)
end

print(string.format("%d tests réussis, %d échecs", reussis, echecs))
if echecs > 0 then os.exit(1) end
