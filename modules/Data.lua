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

-- Data : lecture et écriture de SalleDuTempsDB (réglages de session, sessions enregistrées).
--
-- Format d'une session enregistrée (SalleDuTempsDB.sessions[i]) :
--   date, horodatage (time()), etiquette, duree (s, choisie), type ("mono" | "multi"),
--   classe, niveau, cible, npcID, mannequin (booléen),
--   sorts = { { t (s depuis le départ), id (spellID ou nil si secret), d (durée d'incantation, 0 si instantané),
--               k ("cast" | "canal" | "instant"), ok (true : lancé, false : interrompu ou échoué) } },
--   degats, dureeCombat (s, selon le compteur), dps, nbCombats, parSort = { [spellID] = dégâts },
--   manaFin (part de mana restante, 0 à 1, si lisible), erreurCompteur,
--   uid (identifiant stable, l'index change après une suppression), nom (donné dans le journal),
--   cycle et cycleVersion (cache de Cycle.Detecter, recalculé si l'algorithme change),
--   cycleEdite = { etapes = { { id, actif, type, d, dot, typeChoisi } }, date } : version éditée, à côté du
--   cycle détecté (type "dot" : dot = durée du DoT en s ; typeChoisi : type fixé à la main dans l'éditeur),
--   reference (uid de la session améliorée) et jugement = { compte = { parfait, bien, juste, rate, hors },
--   precision, comboMax, notesJouees } pour une session d'amélioration,
--   ecourtee et dureeJouee (s) si le combat s'est terminé avant la fin et que le joueur l'a enregistrée,
--   referenceNom et referenceDps (copie figée de la référence), decision ("version" | "remplace") une fois
--   le choix fait en mode comparaison.
--
-- Cycles actifs dans le Guide : SalleDuTempsDB.actifs[classe][type] = uid (un par classe et type de combat).

local _, ns = ...

local Data = {}
ns.Data = Data

-- Durée affichée : « 60 s » ou « 9 s sur 15 (écourtée) ».
function Data.DureeTexte(s)
    if s.ecourtee then return string.format("%d s sur %d (écourtée)", s.dureeJouee or 0, s.duree or 0) end
    return string.format("%d s", s.duree or 0)
end

local MAX_SESSIONS = 200

local REGLAGES_DEFAUT = { duree = 60, type = "mono", etiquette = "" }

function Data.Reglages()
    local r = ns.db.reglages or {}
    for cle, valeur in pairs(REGLAGES_DEFAUT) do
        if r[cle] == nil then r[cle] = valeur end
    end
    ns.db.reglages = r
    return r
end

function Data.EnregistrerReglages(r)
    ns.db.reglages = { duree = r.duree, type = r.type, etiquette = r.etiquette }
end

function Data.Sessions()
    ns.db.sessions = ns.db.sessions or {}
    return ns.db.sessions
end

local function NouvelUid()
    ns.db.prochainUid = (ns.db.prochainUid or 0) + 1
    return ns.db.prochainUid
end

-- Au chargement : identifiant stable pour les sessions enregistrées avant le jalon 4.
function Data.Migrer()
    for _, s in ipairs(Data.Sessions()) do
        if not s.uid then s.uid = NouvelUid() end
    end
end

-- ---------------------------------------------------------------------
-- Personnage (la sauvegarde est commune au compte) : « Nom-Royaume ».
-- ---------------------------------------------------------------------
function Data.Personnage()
    local nom = ns.Lisible(UnitName("player")) or "?"
    local royaume = GetRealmName and ns.Lisible(GetRealmName()) or ""
    return royaume ~= "" and (nom .. "-" .. royaume) or nom
end

-- Session du personnage connecté ? Les anciennes sessions, sans personnage enregistré, sont rattachées
-- par leur classe.
function Data.EstAMoi(s)
    if s.personnage then return s.personnage == Data.Personnage() end
    return s.classe == select(2, UnitClass("player"))
end

-- À la connexion : les anciennes sessions sans personnage, de la classe du personnage connecté, lui sont
-- attribuées (une seule fois).
function Data.AttribuerSessions()
    local moi, classe = Data.Personnage(), select(2, UnitClass("player"))
    if moi == "?" then return end
    for _, s in ipairs(Data.Sessions()) do
        if not s.personnage and s.classe == classe then s.personnage = moi end
    end
end

-- ---------------------------------------------------------------------
-- Cycles actifs dans le Guide (un par classe et type de combat)
-- ---------------------------------------------------------------------
function Data.EstActif(s)
    local actifs = ns.db.actifs and ns.db.actifs[s.classe or "?"]
    return actifs ~= nil and actifs[s.type or "mono"] == s.uid
end

-- Définit la session comme active pour sa classe et son type, ou la retire si elle l'était déjà.
function Data.BasculerActif(s)
    ns.db.actifs = ns.db.actifs or {}
    local classe = s.classe or "?"
    ns.db.actifs[classe] = ns.db.actifs[classe] or {}
    local actifs = ns.db.actifs[classe]
    if actifs[s.type or "mono"] == s.uid then
        actifs[s.type or "mono"] = nil
        return false
    end
    actifs[s.type or "mono"] = s.uid
    return true
end

-- Ajoute une session et retourne son numéro. Au-delà de MAX_SESSIONS, la plus ancienne non active est retirée.
function Data.AjouterSession(session)
    local sessions = Data.Sessions()
    session.uid = session.uid or NouvelUid()
    sessions[#sessions + 1] = session
    while #sessions > MAX_SESSIONS do
        local retiree = false
        for i, s in ipairs(sessions) do
            if not Data.EstActif(s) then
                table.remove(sessions, i)
                retiree = true
                break
            end
        end
        if not retiree then break end
    end
    return #sessions
end

-- ---------------------------------------------------------------------
-- Journal : nom, meilleur DPS, cycle, duplication, suppression
-- ---------------------------------------------------------------------
function Data.Nom(s, numero)
    if s.nom and s.nom ~= "" then return s.nom end
    if s.etiquette and s.etiquette ~= "" then return s.etiquette end
    return "Session n° " .. tostring(numero or "?")
end

function Data.Renommer(numero, nom)
    local s = Data.Sessions()[numero]
    if s then s.nom = strtrim(nom or "") end
end

-- Meilleur DPS des sessions de même classe et même type, en excluant éventuellement une session.
function Data.MeilleurDPS(classe, type, sauf)
    local meilleur
    for _, s in ipairs(Data.Sessions()) do
        if s ~= sauf and s.dps and s.classe == classe and s.type == type then
            if not meilleur or s.dps > meilleur then meilleur = s.dps end
        end
    end
    return meilleur
end

function Data.EstMeilleurDPS(s)
    return s.dps ~= nil and s.dps == Data.MeilleurDPS(s.classe, s.type)
end

-- Cycle détecté de la session, recalculé seulement si l'algorithme a changé depuis.
function Data.Cycle(s)
    if s.cycleVersion ~= ns.Cycle.VERSION then
        local ok, r = pcall(ns.Cycle.Detecter, s.sorts, { degats = s.parSort })
        if not ok then
            ns.Print("Détection du cycle : erreur (" .. tostring(r) .. ")")
            return nil
        end
        s.cycle, s.cycleVersion = r, ns.Cycle.VERSION
    end
    return s.cycle
end

local function Copie(valeur)
    if type(valeur) ~= "table" then return valeur end
    local copie = {}
    for k, v in pairs(valeur) do copie[k] = Copie(v) end
    return copie
end
Data.Copie = Copie

-- Version éditée du cycle (nil si aucune).
function Data.CycleEdite(s)
    return s.cycleEdite
end

function Data.EnregistrerEdition(numero, etapes)
    local s = Data.Sessions()[numero]
    if not s then return end
    s.cycleEdite = { etapes = Copie(etapes), date = date("%Y-%m-%d %H:%M") }
end

-- DoT reconnus automatiquement (description du sort) dans des étapes, sauf celles dont le joueur a choisi le
-- type dans l'éditeur (typeChoisi). Retourne une copie.
function Data.CompleterDots(etapes)
    local resultat = Copie(etapes or {})
    for _, e in ipairs(resultat) do
        if not e.typeChoisi and e.type ~= "dot" and e.type ~= "canal" and e.type ~= "serie" then
            local duree = ns.Capture.DureeDot(e.id)
            if duree then e.type, e.dot = "dot", duree end
        end
    end
    return resultat
end

-- Étapes de travail pour l'éditeur : la version éditée si elle existe, sinon le cycle détecté.
function Data.EtapesDeTravail(s)
    if s.cycleEdite then return Data.CompleterDots(s.cycleEdite.etapes) end
    return ns.Cycle.Etapes(Data.Cycle(s), s.sorts, ns.Capture.DureeDot)
end

-- Duplique une session (base pour l'éditeur du jalon 5) ; retourne le numéro de la copie.
function Data.Dupliquer(numero)
    local s = Data.Sessions()[numero]
    if not s then return nil end
    local copie = Copie(s)
    copie.uid = nil
    copie.nom = Data.Nom(s, numero) .. " (copie)"
    return Data.AjouterSession(copie)
end

function Data.NumeroParUid(uid)
    for i, s in ipairs(Data.Sessions()) do
        if s.uid == uid then return i, s end
    end
end

-- Choix en mode comparaison, pour la session d'amélioration n° numero :
--   "version"   : gardée comme nouvelle version de la référence (« Nom v2 »…), qui reste en place ;
--   "remplacer" : prend la place de la référence (nom, version éditée, statut actif) ; la référence est supprimée ;
--   "ignorer"   : la session d'amélioration est supprimée.
-- Dans les deux premiers cas, la version éditée de la référence est reprise, pour pouvoir réaméliorer.
function Data.DecisionComparaison(numero, choix)
    local s = Data.Sessions()[numero]
    if not s then return end
    if choix == "ignorer" then
        Data.Supprimer(numero)
        return
    end
    local numRef, ref = Data.NumeroParUid(s.reference)
    local nomRef = ref and Data.Nom(ref, numRef) or s.referenceNom or "Cycle"
    if ref and ref.cycleEdite and not s.cycleEdite then s.cycleEdite = Copie(ref.cycleEdite) end
    if choix == "version" then
        local version = 2
        if ref then
            ref.versions = (ref.versions or 1) + 1
            version = ref.versions
        end
        s.nom = string.format("%s v%d", nomRef, version)
        s.decision = "version"
    elseif choix == "remplacer" then
        s.nom = nomRef
        s.decision = "remplace"
        if ref then
            if Data.EstActif(ref) and not Data.EstActif(s) then Data.BasculerActif(s) end
            Data.Supprimer(numRef)
        end
    end
end

function Data.Supprimer(numero)
    local sessions = Data.Sessions()
    local s = sessions[numero]
    if not s then return end
    if Data.EstActif(s) then Data.BasculerActif(s) end
    table.remove(sessions, numero)
end
