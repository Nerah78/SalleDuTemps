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

-- Analyse hors du jeu des sessions enregistrées, et export en traces de test.
-- Usage : lua tests/analyser_sauvegarde.lua <chemin de SalleDuTemps.lua> [exporter]
--   Sans « exporter » : affiche le cycle détecté pour chaque session.
--   Avec « exporter » : écrit aussi chaque session dans tests/traces/session_<n>.lua.

local dossier = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local Cycle = dofile(dossier .. "/../modules/Cycle.lua")

local chemin, action = arg[1], arg[2]
if not chemin then
    print("Usage : lua tests/analyser_sauvegarde.lua <chemin de SalleDuTemps.lua> [exporter]")
    os.exit(1)
end
dofile(chemin)
local sessions = SalleDuTempsDB and SalleDuTempsDB.sessions or {}

local function Liste(t)
    local parties = {}
    for i, v in ipairs(t or {}) do parties[i] = tostring(v) end
    return table.concat(parties, " ")
end

local function Exporter(n, s)
    local f = assert(io.open(dossier .. "/traces/session_" .. n .. ".lua", "w"))
    f:write(string.format("-- Trace réelle : %s niveau %s, %s, %d s, cible %s.\n",
        tostring(s.classe), tostring(s.niveau), tostring(s.date), s.duree or 0, tostring(s.cible)))
    f:write(string.format("return {\n    classe = %q,\n    duree = %d,\n", tostring(s.classe), s.duree or 0))
    if s.parSort then
        local parties = {}
        for id, montant in pairs(s.parSort) do parties[#parties + 1] = string.format("[%d] = %d", id, montant) end
        table.sort(parties)
        f:write("    parSort = { " .. table.concat(parties, ", ") .. " },\n")
    end
    f:write("    sorts = {\n")
    for _, e in ipairs(s.sorts or {}) do
        f:write(string.format("        { t = %.3f, id = %s, d = %s, k = %q, ok = %s%s },\n",
            e.t or 0, tostring(e.id), tostring(e.d or 0), tostring(e.k), tostring(e.ok),
            e.fin and string.format(", fin = %.3f", e.fin) or ""))
    end
    f:write("    },\n}\n")
    f:close()
end

for n, s in ipairs(sessions) do
    local r = Cycle.Detecter(s.sorts, { degats = s.parSort })
    print(string.format("Session %d (%s, %d s, %s) : %d sorts", n, tostring(s.date), s.duree or 0, tostring(s.cible), #(s.sorts or {})))
    if r then
        print(string.format("  ouverture : %s", Liste(r.ouverture)))
        print(string.format("  cycle (%d sorts, %.1f s) : %s", r.longueur, r.duree or 0, Liste(r.cycle)))
        print(string.format("  répétitions : %d, fiabilité : %d %%, écarts : %d", r.repetitions, math.floor(r.fiabilite * 100 + 0.5), #r.ecarts))
    else
        print("  aucun cycle détecté")
    end
    if action == "exporter" then Exporter(n, s) end
end
