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

-- Tests de modules/Partition.lua, hors du jeu : lua tests/test_partition.lua

local dossier = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local P = dofile(dossier .. "/../modules/Partition.lua")

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

local function Genres(verdicts)
    local g = {}
    for i, v in ipairs(verdicts) do g[i] = v.genre .. (v.raison and ("/" .. v.raison) or "") end
    return table.concat(g, ",")
end

-- Étapes fictives : A instantané (1), B incantation 2,5 s (2), Tir en série (5019), ouverture O (9).
local A = { id = 1, type = "instant", d = 0, actif = true }
local B = { id = 2, type = "cast", d = 2.5, actif = true }
local TIR = { id = 5019, type = "serie", d = 0, actif = true }
local O = { id = 9, type = "instant", d = 0, actif = true }

-- 1. Construction : ouverture puis cycle répété jusqu'à la durée de la session.
do
    local notes = P.Construire({ O }, { B, A, TIR }, { dureeTotale = 20, dureeSerie = 3 })
    -- O 1,5 s, puis cycles de 7 s commençant à 1,5 ; 8,5 ; 15,5 (le suivant, 22,5, dépasse 20 s).
    Verifier("construction : 10 notes", #notes == 10, #notes)
    Verifier("construction : ouverture", notes[1].id == 9 and notes[1].rep == 0)
    Verifier("construction : heures", Proche(notes[2].t, 1.5) and Proche(notes[5].t, 8.5) and Proche(notes[8].t, 15.5),
        string.format("%s %s %s", notes[2].t, notes[5].t, notes[8].t))
    Verifier("construction : durée série", Proche(notes[4].duree, 3))
    Verifier("construction : répétitions", P.Repetitions(notes, 20) == 3, P.Repetitions(notes, 20))
    local inactif = { id = 3, type = "instant", d = 0, actif = false }
    Verifier("construction : étape inactive ignorée", #P.Construire(nil, { A, inactif }, { dureeTotale = 3 }) == 2)
    Verifier("construction : cycle vide", #P.Construire(nil, {}, { dureeTotale = 10 }) == 0)
end

-- 2. Classement des écarts.
do
    Verifier("classer : avance 0,3 = parfait", P.Classer(-0.3) == "parfait")
    Verifier("classer : 0,1 = parfait", P.Classer(0.1) == "parfait")
    Verifier("classer : 0,2 = bien", P.Classer(0.2) == "bien")
    Verifier("classer : 0,3 = juste", P.Classer(0.3) == "juste")
    Verifier("classer : 0,5 = raté", P.Classer(0.5) == "rate")
    Verifier("classer : avance 0,5 = raté", P.Classer(-0.5) == "rate")
end

local function Etat(dureeTotale)
    return P.Nouvelle(P.Construire(nil, { A, B }, { dureeTotale = dureeTotale or 40 }))
end

-- 3. Jeu parfait : A 0 ; B 1,5 ; A 4 ; B 5,5.
do
    local e = Etat()
    local g = {}
    for _, coup in ipairs({ { 1, 0 }, { 2, 1.5 }, { 1, 4 }, { 2, 5.5 } }) do
        g[#g + 1] = Genres(P.Jouer(e, coup[1], coup[2]))
    end
    Verifier("parfait : verdicts", table.concat(g, ";") == "parfait;parfait;parfait;parfait", table.concat(g, ";"))
    Verifier("parfait : combo 4", e.combo == 4 and e.comboMax == 4, e.combo)
    Verifier("parfait : précision 100 %", Proche(P.Precision(e), 1), P.Precision(e))
end

-- 4. Retard puis recalage : B joué 0,3 s en retard (juste), A suivant attendu à 1,8 + 2,5 = 4,3.
do
    local e = Etat()
    P.Jouer(e, 1, 0)
    local v = P.Jouer(e, 2, 1.8)
    Verifier("retard : juste", Genres(v) == "juste" and Proche(v[1].ecart, 0.3), Genres(v))
    Verifier("retard : recalage", Genres(P.Jouer(e, 1, 4.3)) == "parfait")
end

-- 5. Note sautée : A, puis A de nouveau à la place de B → B ratée (omise), A jugé à la place de B.
do
    local e = Etat()
    P.Jouer(e, 1, 0)
    local v = P.Jouer(e, 1, 1.5)
    Verifier("omission : verdicts", Genres(v) == "rate/omis,parfait", Genres(v))
    Verifier("omission : combo repart", e.combo == 1, e.combo)
end

-- 6. Note passée : B jamais joué ; à 4,1 s (après 1,5 + 2,5), B est ratée et A attendu à 4,0.
do
    local e = Etat()
    P.Jouer(e, 1, 0)
    Verifier("passée : pas encore à 3,9 s", Genres(P.Avancer(e, 3.9)) == "")
    Verifier("passée : ratée à 4,1 s", Genres(P.Avancer(e, 4.1)) == "rate/passee")
    Verifier("passée : A attendu à 4,0", Proche(e.attendu, 4.0) and e.notes[e.i].id == 1, e.attendu)
end

-- 7. Sort hors partition : signalé, combo conservé, note attendue inchangée.
do
    local e = Etat()
    P.Jouer(e, 1, 0)
    local v = P.Jouer(e, 99, 0.8)
    Verifier("hors : verdict", Genres(v) == "hors", Genres(v))
    Verifier("hors : combo conservé", e.combo == 1 and e.compte.hors == 1)
    -- Le sort hors partition (instantané, à 0,8 s) coûte un GCD : B est repoussé de 1,5 à 2,3.
    Verifier("hors : B repoussé", Proche(e.attendu, 2.3), e.attendu)
    Verifier("hors : B joué après", Genres(P.Jouer(e, 2, 2.3)) == "parfait")
end

-- 7 bis. Sort hors partition avec incantation : la note attendue est repoussée de sa durée.
do
    local e = Etat()
    P.Jouer(e, 1, 0)
    P.Jouer(e, 99, 1.5, 3.5)
    Verifier("hors incanté : B repoussé à 5,0", Proche(e.attendu, 5.0), e.attendu)
    Verifier("hors incanté : rien de raté à 6 s", Genres(P.Avancer(e, 6)) == "")
end

-- 8. Série de tirs : une seule note, tirs suivants ignorés, sort suivant attendu après la durée de série.
do
    local e = P.Nouvelle(P.Construire(nil, { A, TIR }, { dureeTotale = 30, dureeSerie = 3 }))
    P.Jouer(e, 1, 0)
    Verifier("série : premier tir jugé", Genres(P.Jouer(e, 5019, 1.5)) == "parfait")
    Verifier("série : tirs suivants ignorés", Genres(P.Jouer(e, 5019, 3.0)) == "" and Genres(P.Jouer(e, 5019, 4.4)) == "")
    Verifier("série : sort suivant à 4,5", Genres(P.Jouer(e, 1, 4.5)) == "parfait")
    -- La série suivante reprend après le GCD du sort (4,5 + 1,5 = 6,0), comme en jeu.
    Verifier("série : nouvelle série jugée", Genres(P.Jouer(e, 5019, 6.0)) == "parfait")
end

-- 8 ter. Série de tirs = temps libre : rien n'est raté pendant la série, le sort suivant est jugé sur l'ordre.
do
    local e = P.Nouvelle(P.Construire(nil, { A, TIR }, { dureeTotale = 30, dureeSerie = 3 }))
    P.Jouer(e, 1, 0)
    P.Jouer(e, 5019, 1.5)
    Verifier("temps libre : rien de raté pendant la série", Genres(P.Avancer(e, 20)) == "")
    local v = P.Jouer(e, 1, 20)
    Verifier("temps libre : sort suivant jugé sur l'ordre", Genres(v) == "parfait" and v[1].ecart == 0, Genres(v))
    -- La série suivante est attendue à 21,5 et ratée une fois sa durée (3 s) écoulée : à 24,5.
    Verifier("temps libre : le rythme reprend ensuite", Genres(P.Avancer(e, 24.4)) == "" and Genres(P.Avancer(e, 24.6)) == "rate/passee")
end

-- 8 quinquies. La série elle-même est jugée sur l'ordre : premier tir 0,3 s après l'heure attendue, pas de retard.
do
    local e = P.Nouvelle(P.Construire(nil, { A, TIR }, { dureeTotale = 30, dureeSerie = 3 }))
    P.Jouer(e, 1, 0)
    local v = P.Jouer(e, 5019, 1.8)
    Verifier("série : premier tir sans chrono", Genres(v) == "parfait" and v[1].ecart == 0, Genres(v))
end

-- 8 bis. Tir automatique alors qu'un sort est attendu : ignoré, sans verdict ni « hors partition ».
do
    local e = Etat()
    P.Jouer(e, 1, 0)
    Verifier("tir hors place : ignoré", Genres(P.Jouer(e, 5019, 0.9)) == "" and e.compte.hors == 0)
    Verifier("tir hors place : B toujours attendu", Genres(P.Jouer(e, 2, 1.5)) == "parfait")
end

-- 8 quater. Interruption (déplacement pendant l'incantation de B) : verdict remplacé, combo à zéro, B à rejouer.
do
    local e = Etat()
    P.Jouer(e, 1, 0)
    P.Jouer(e, 2, 1.5)                    -- B parfait, combo 2
    local v = P.Interrompre(e, 2, 2.2)
    Verifier("interruption : verdict", Genres(v) == "interrompu", Genres(v))
    Verifier("interruption : comptes", e.compte.parfait == 1 and e.compte.interrompu == 1 and e.juges == 2, e.compte.parfait)
    Verifier("interruption : combo à zéro", e.combo == 0)
    Verifier("interruption : B de nouveau attendu, tout de suite", e.notes[e.i].id == 2 and Proche(e.attendu, 2.2))
    Verifier("interruption : une seule fois", Genres(P.Interrompre(e, 2, 2.3)) == "")
    Verifier("interruption : B rejoué", Genres(P.Jouer(e, 2, 2.3)) == "parfait")
    Verifier("interruption : précision", Proche(P.Precision(e), 2 / 3), P.Precision(e))
    Verifier("interruption : autre sort sans effet", Genres(P.Interrompre(e, 1, 3)) == "")
end

-- 12. Partition vivante (Guide, jalon 8) : cycle A, B, C, D (étapes instantanées).
local C = { id = 3, type = "instant", d = 0, actif = true }
local D = { id = 4, type = "instant", d = 0, actif = true }
local B1 = { id = 2, type = "instant", d = 0, actif = true }
local function Vivante()
    return P.Nouvelle(P.Construire(nil, { A, B1, C, D }, { dureeTotale = 60 }), nil, { vivante = true })
end
do
    local e = Vivante()
    local v = P.Jouer(e, 3, 0)
    Verifier("vivante : départ en cours de cycle sans pénalité", Genres(v) == "parfait" and e.compte.rate == 0, Genres(v))
    Verifier("vivante : la suite est D", e.notes[e.i].id == 4)
end
do
    local e = Vivante()
    P.Jouer(e, 1, 0)
    local v = P.Jouer(e, 4, 1.5)
    Verifier("vivante : B et C sautés", Genres(v) == "rate/omis,rate/omis,parfait", Genres(v))
    Verifier("vivante : erreurs par sort", e.erreurs[2].omis == 1 and e.erreurs[3].omis == 1)
    Verifier("vivante : reprise sur A", Genres(P.Jouer(e, 1, 3.0)) == "parfait")
end
do
    -- Partition fixe : la même situation donne un sort hors partition (fenêtre d'une note).
    local e = P.Nouvelle(P.Construire(nil, { A, B1, C, D }, { dureeTotale = 60 }))
    P.Jouer(e, 1, 0)
    Verifier("fixe : D trop loin = hors partition", Genres(P.Jouer(e, 4, 1.5)) == "hors")
end
do
    -- Erreurs : note passée, puis interruption qui annule un verdict raté.
    local e = Etat()
    P.Jouer(e, 1, 0)
    P.Avancer(e, 4.1)
    Verifier("erreurs : note passée comptée", e.erreurs[2] and e.erreurs[2].passee == 1)
    local e2 = Etat()
    P.Jouer(e2, 1, 0)
    P.Jouer(e2, 2, 2.0)           -- B en retard (0,5 s) : raté
    P.Interrompre(e2, 2, 2.5)
    Verifier("erreurs : retard remplacé par interruption", e2.erreurs[2].retard == 0 and e2.erreurs[2].interrompu == 1)
end

-- 13. DoT (dégâts sur la durée) : rejoués à leur expiration, avant le remplissage.
local DOT = { id = 7, type = "dot", d = 0, dot = 10, actif = true }          -- instantané, 10 s
local CDOT = { id = 8, type = "dot", d = 2, dot = 6, actif = true }          -- incantation 2 s, puis 6 s
local function NotesDot(cycle, duree) return P.Construire(nil, cycle, { dureeTotale = duree or 60 }) end
local function Ids(notes, de, a)
    local t = {}
    for k = de, a do t[#t + 1] = notes[k] and (notes[k].id .. "@" .. notes[k].t) or "-" end
    return table.concat(t, " ")
end
do
    local n = NotesDot({ DOT, A }, 20)
    -- DOT à 0 (expire à 10), A toutes les 1,5 s ; à 10,5 le DOT est dû : il passe avant A.
    Verifier("dot : premier posé d'abord", n[1].id == 7 and n[1].dot == 10)
    Verifier("dot : rejoué à son expiration", n[8].id == 7 and Proche(n[8].t, 10.5), Ids(n, 1, 9))
    local c = NotesDot({ CDOT, A }, 20)
    -- CDOT de 0 à 2, expire à 8 ; à lancer à 6 (8 - 2 s d'incantation) : A à 2 ; 3,5 ; 5, puis CDOT à 6,5.
    Verifier("dot à incantation : en avance de son incantation", c[5].id == 8 and Proche(c[5].t, 6.5), Ids(c, 1, 6))
    local seul = NotesDot({ DOT }, 30)
    Verifier("dot seul : attente jusqu'à l'échéance", Proche(seul[1].duree, 10) and Proche(seul[2].t, 10), Ids(seul, 1, 3))
end
do
    -- Jeu parfait : DOT, A ×6, DOT à 10,5.
    local e = P.Nouvelle(NotesDot({ DOT, A }))
    local coups = { { 7, 0 }, { 1, 1.5 }, { 1, 3 }, { 1, 4.5 }, { 1, 6 }, { 1, 7.5 }, { 1, 9 }, { 7, 10.5 } }
    local g = {}
    for _, c in ipairs(coups) do g[#g + 1] = Genres(P.Jouer(e, c[1], c[2])) end
    Verifier("dot : jeu parfait", table.concat(g, ";") == "parfait;parfait;parfait;parfait;parfait;parfait;parfait;parfait",
        table.concat(g, ";"))
end
do
    -- Relancé 7 s avant l'expiration : écrasé (trop tôt), expiration recalée, A attendu après le GCD.
    local e = P.Nouvelle(NotesDot({ DOT, A }))
    P.Jouer(e, 7, 0)
    P.Jouer(e, 1, 1.5)
    local v = P.Jouer(e, 7, 3)
    Verifier("dot écrasé : verdict", Genres(v) == "rate/ecrase", Genres(v))
    Verifier("dot écrasé : erreur relevée", e.erreurs[7] and e.erreurs[7].ecrase == 1)
    Verifier("dot écrasé : nouvelle expiration", Proche(e.dots[7], 13))
    Verifier("dot écrasé : A attendu à 4,5", e.notes[e.i].id == 1 and Proche(e.attendu, 4.5), tostring(e.attendu))
end
do
    -- Relancé 1 s avant l'expiration (moins d'un GCD) : accepté, même s'il passe devant A.
    local e = P.Nouvelle(NotesDot({ DOT, A }))
    P.Jouer(e, 7, 0)
    for _, t in ipairs({ 1.5, 3, 4.5, 6, 7.5 }) do P.Jouer(e, 1, t) end
    local v = P.Jouer(e, 7, 9)
    Verifier("dot un peu tôt : accepté", Genres(v) == "parfait", Genres(v))
    Verifier("dot un peu tôt : A ensuite", e.notes[e.i].id == 1 and Proche(e.attendu, 10.5))
end
do
    -- DOT oublié : A joué à sa place sans pénalité, puis le DOT est compté « pas joué » une seule fois.
    local e = P.Nouvelle(NotesDot({ DOT, A }))
    P.Jouer(e, 7, 0)
    for _, t in ipairs({ 1.5, 3, 4.5, 6, 7.5, 9 }) do P.Jouer(e, 1, t) end
    Verifier("dot oublié : A joué devant", Genres(P.Jouer(e, 1, 10.5)) == "parfait")
    Verifier("dot oublié : revient en tête", e.notes[e.i].id == 7)
    Verifier("dot oublié : compté une fois", Genres(P.Avancer(e, 13.6)) == "rate/passee" and Genres(P.Avancer(e, 15.2)) == "")
    Verifier("dot oublié : relancé ensuite", Genres(P.Jouer(e, 7, 15.3)) == "juste", Genres(P.Jouer(e, 1, 16.8)))
end
do
    -- DoT à incantation interrompu : il n'est pas posé, il redevient dû tout de suite.
    local e = P.Nouvelle(NotesDot({ CDOT, A }))
    P.Jouer(e, 8, 0)
    Verifier("dot interrompu : expiration posée", Proche(e.dots[8], 8))
    Verifier("dot interrompu : verdict", Genres(P.Interrompre(e, 8, 1)) == "interrompu")
    Verifier("dot interrompu : de nouveau dû", e.dots[8] == nil and e.notes[e.i].id == 8 and Proche(e.attendu, 1))
end

-- 14. Énergie (voleur) : 100 au départ, +10/s, GCD 1 s. Attaque pernicieuse (11) 45, Éviscération (12) 35.
local SS = { id = 11, type = "instant", d = 0, cout = 45, actif = true }
local EV = { id = 12, type = "instant", d = 0, cout = 35, actif = true }
local ENERGIE = { max = 100, regen = 10, depart = 100 }
local function NotesEnergie() return P.Construire(nil, { SS, SS, EV }, { dureeTotale = 30, gcd = 1, energie = ENERGIE }) end
do
    local n = NotesEnergie()
    -- 0 : SS (100 → 55) ; 1 : SS (65 → 20) ; 2 : EV, 30 < 35, attente 0,5 s → 2,5 (35 → 0) ;
    -- 3,5 : SS, 10 < 45, attente 3,5 s → 7,0.
    Verifier("énergie : sans attente au départ", Proche(n[1].t, 0) and Proche(n[2].t, 1) and n[2].attente == nil)
    Verifier("énergie : attente avant Éviscération", Proche(n[3].t, 2.5) and Proche(n[3].attente, 0.5), Ids(n, 1, 4))
    Verifier("énergie : attente avant la SS suivante", Proche(n[4].t, 7) and Proche(n[4].attente, 3.5), Ids(n, 1, 5))
    Verifier("énergie : la note d'avant s'allonge", Proche(n[2].duree, 1.5) and Proche(n[3].duree, 4.5))
end
do
    -- Jeu au rythme de l'énergie : tout est parfait, l'attente n'est pas une faute.
    local e = P.Nouvelle(NotesEnergie())
    local g = {}
    for _, c in ipairs({ { 11, 0 }, { 11, 1 }, { 12, 2.5 }, { 11, 7 } }) do g[#g + 1] = Genres(P.Jouer(e, c[1], c[2])) end
    Verifier("énergie : jeu au rythme", table.concat(g, ";") == "parfait;parfait;parfait;parfait", table.concat(g, ";"))
end
do
    -- La SS suivante jouée à 5 au lieu de 7 : l'énergie était là (calcul trop prudent) → parfait, calcul recalé.
    local e = P.Nouvelle(NotesEnergie())
    P.Jouer(e, 11, 0)
    P.Jouer(e, 11, 1)
    P.Jouer(e, 12, 2.5)
    local v = P.Jouer(e, 11, 5)
    Verifier("énergie : plus tôt que le calcul → parfait", Genres(v) == "parfait", Genres(v))
    Verifier("énergie : calcul recalé (0 après la dépense)", Proche(e.energie, 0) and Proche(e.energieT, 5), tostring(e.energie))
end
do
    -- Énergie pleine signalée par le jeu : recalage à 100, plus d'attente prévue pour la note suivante.
    local e = P.Nouvelle(NotesEnergie())
    P.Jouer(e, 11, 0)                 -- calcul : 55
    P.Jouer(e, 11, 1)                 -- calcul : 20
    P.EnergiePleine(e, 1.5)
    Verifier("énergie pleine : recalage", Proche(e.energie, 100))
    Verifier("énergie pleine : Éviscération sans attente", e.notes[e.i].id == 12 and e.notes[e.i].attente == nil,
        tostring(e.notes[e.i].attente))
end
do
    -- Sort hors partition coûteux : il dépense de l'énergie, la suite attend davantage.
    local e = P.Nouvelle(NotesEnergie())
    P.Jouer(e, 11, 0)                 -- 55
    P.Jouer(e, 99, 0.5, 0, 40)        -- hors partition, 40 d'énergie : 60 - 40 = 20
    Verifier("hors coûteux : énergie dépensée", Proche(e.energie, 20), tostring(e.energie))
    Verifier("hors coûteux : la SS suivante attend", e.notes[e.i].id == 11 and e.notes[e.i].attente ~= nil)
end

-- 14 bis. Recalage sur une énergie réelle lue (barre du HUD) : seulement au-delà du seuil.
do
    local e = P.Nouvelle(NotesEnergie())
    P.Jouer(e, 11, 0)                 -- calcul : 55 à 0 s, donc 60 à 0,5 s
    Verifier("lue : écart sous le seuil ignoré", P.RecalerEnergie(e, 0.5, 62, 5) == false)
    Verifier("lue : écart au-delà du seuil recalé", P.RecalerEnergie(e, 0.5, 20, 5) == true and Proche(P.EnergieCalculee(e, 0.5), 20))
    Verifier("lue : la note suivante attend désormais", e.notes[e.i].attente ~= nil, tostring(e.notes[e.i].attente))
end

-- 14 ter. Marge de réaction sur les notes qui attendent l'énergie (Éviscération attendue à 2,5 après 0,5 s
-- d'attente) ; les autres notes n'en ont pas.
do
    local function JusquA(tEv)
        local e = P.Nouvelle(NotesEnergie())
        P.Jouer(e, 11, 0)
        P.Jouer(e, 11, 1)
        return P.Jouer(e, 12, tEv)
    end
    Verifier("marge : +0,3 s → parfait", Genres(JusquA(2.8)) == "parfait", Genres(JusquA(2.8)))
    Verifier("marge : +0,45 s → juste", Genres(JusquA(2.95)) == "juste", Genres(JusquA(2.95)))
    Verifier("marge : +0,6 s → raté", Genres(JusquA(3.1)) == "rate/retard", Genres(JusquA(3.1)))
    local e = P.Nouvelle(NotesEnergie())
    P.Jouer(e, 11, 0)
    Verifier("marge : pas pour une note sans attente", Genres(P.Jouer(e, 11, 1.3)) == "juste")
end

-- 14 quater. Points de combo : Attaque pernicieuse génère 1 point, Éviscération est un coup de grâce.
local SSg = { id = 11, type = "instant", d = 0, cout = 45, actif = true, genere = 1 }
local EVf = { id = 12, type = "instant", d = 0, cout = 35, actif = true, finisseur = true }
local function NotesCombo() return P.Construire(nil, { SSg, SSg, EVf }, { dureeTotale = 30, gcd = 1, energie = ENERGIE }) end
do
    local e = P.Nouvelle(NotesCombo())
    P.Jouer(e, 11, 0, 0, 45, nil)
    P.Jouer(e, 11, 1, 0, 45, nil)
    local v = P.Jouer(e, 12, 2.5, 0, 35, 2)
    Verifier("combo : 2 points comme prévu → parfait", Genres(v) == "parfait", Genres(v))
    Verifier("combo : remis à zéro après le coup de grâce", e.pc == 0, e.pc)
end
do
    local e = P.Nouvelle(NotesCombo())
    P.Jouer(e, 11, 0)
    P.Jouer(e, 11, 1)
    local v = P.Jouer(e, 12, 2.5, 0, 35, 1)   -- une attaque esquivée : 1 point seulement
    Verifier("combo : 1 point sur 2 → raté", Genres(v) == "rate/combo" and v[1].combo == 1 and v[1].comboPrevu == 2,
        Genres(v))
    Verifier("combo : compté dans les erreurs", e.erreurs[12] and e.erreurs[12].combo == 1)
end
do
    local e = P.Nouvelle(NotesCombo())
    P.Jouer(e, 11, 0)
    local v = P.Jouer(e, 12, 1, 0, 35, 1)     -- 2e Attaque pernicieuse oubliée : pas de double peine
    Verifier("combo : générateur oublié compté une seule fois", Genres(v) == "rate/omis,parfait", Genres(v))
end
do
    local e = P.Nouvelle(NotesCombo())
    P.Jouer(e, 11, 0)
    P.Jouer(e, 11, 1)
    local v = P.Jouer(e, 12, 2.5, 0, 35, nil) -- points inconnus : pas de jugement des points
    Verifier("combo : points inconnus ignorés", Genres(v) == "parfait", Genres(v))
end

-- 14 quinquies. Coup esquivé : pas de faute, note à rejouer, énergie rendue (80 % de 45 = 36).
do
    local e = P.Nouvelle(NotesCombo())
    P.Jouer(e, 11, 0)                         -- 100 → 55
    local v = P.Esquiver(e, 11, 0.5, 36)      -- 60 + 36 = 96 à 0,5 s
    Verifier("esquive : verdict", Genres(v) == "esquive", Genres(v))
    Verifier("esquive : sans pénalité", e.juges == 0 and e.combo == 0 and e.compte.esquive == 1)
    Verifier("esquive : note à rejouer", e.i == 1 and e.notes[1].id == 11 and Proche(e.attendu, 1), e.attendu)
    Verifier("esquive : énergie rendue", Proche(P.EnergieCalculee(e, 0.5), 96), P.EnergieCalculee(e, 0.5))
    Verifier("esquive : une seule fois", Genres(P.Esquiver(e, 11, 0.6, 36)) == "")
    local g = { Genres(P.Jouer(e, 11, 1)), Genres(P.Jouer(e, 11, 2)) }
    Verifier("esquive : la suite reprend", table.concat(g, ";") == "parfait;parfait" and e.pc == 2, table.concat(g, ";"))
    Verifier("esquive : précision intacte", Proche(P.Precision(e), 1), P.Precision(e))
end

-- 14 sexies. Perte de contrôle : la partition attend, rien n'est passé, marge de réaction à la reprise.
do
    local e = Etat()
    P.Jouer(e, 1, 0)                          -- B attendu à 1,5
    P.Pause(e, 5)
    Verifier("pause : rien de passé", Genres(P.Avancer(e, 5.1)) == "")
    Verifier("pause : B attendu à la reprise", Proche(e.attendu, 5))
    local v = P.Jouer(e, 2, 5.4)              -- 0,4 s après la reprise, 0,2 pardonnée
    Verifier("pause : marge de réaction", Genres(v) == "bien", Genres(v))
end

-- 9. Durée moyenne des séries mesurée dans une séquence.
do
    local sorts = {
        { t = 10, id = 5019, ok = true }, { t = 11.7, id = 5019, ok = true }, { t = 13.4, id = 5019, ok = true },
        { t = 15, id = 1, ok = true },
        { t = 20, id = 5019, ok = true }, { t = 21.5, id = 5019, ok = true },
        { t = 23, id = 2, ok = true },
    }
    Verifier("durée série : moyenne 4 s", Proche(P.DureeSerie(sorts), 4), P.DureeSerie(sorts))
    Verifier("durée série : défaut", Proche(P.DureeSerie({}), P.DUREE_SERIE))
end

-- 10. Comparaison par nom (rangs différents d'un même sort).
do
    local e = P.Nouvelle(P.Construire(nil, { A, B }, { dureeTotale = 10 }), function(a, b) return a % 100 == b % 100 end)
    Verifier("égalité : rang supérieur accepté", Genres(P.Jouer(e, 101, 0)) == "parfait")
end

-- 11. Affichage : avant le premier sort, la première note est attendue « maintenant ».
do
    local e = Etat()
    local liste = P.Prochaines(e, 3, 0)
    Verifier("prochaines : 3 notes", #liste == 3 and Proche(liste[1].t, 0) and Proche(liste[2].t, 1.5) and Proche(liste[3].t, 4))
    P.Jouer(e, 1, 0.2)
    Verifier("prochaines : recalées", Proche(P.Prochaines(e, 1)[1].t, 1.7))
end

print(string.format("%d tests réussis, %d échecs", reussis, echecs))
if echecs > 0 then os.exit(1) end
