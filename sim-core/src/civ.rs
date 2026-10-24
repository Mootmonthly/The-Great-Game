//! Civilizations (docs/GAME_DESIGN.md §4.5). Every sapient species founds a
//! people. Its settlements grow where the species lives and spread to
//! neighbouring regions; it advances through eras of technology (limited
//! by the materials its land provides) and, under Arcane Magic, traditions
//! of magic; its culture comes from the species' temperament and drives
//! diplomacy and war. Large, loosely bound peoples can split in two.
//!
//! Civilizations update once a year. They make their members stronger
//! where they are settled, and arm them (`equipment`).

use crate::body;
use crate::fixed::Fx;
use crate::individual::MemoryKind;
use crate::world::{neighbours, World, REGION_COUNT, TICKS_PER_YEAR, WIDTH};
use serde::{Deserialize, Serialize};

/// Technology eras and the progress needed to reach each.
pub const ERAS: [(&str, i64); 6] = [
    ("Primitive", 0),
    ("Tribal", 20),
    ("Crafting", 80),
    ("Forging", 250),
    ("Classical", 700),
    ("Industrial", 2000),
];
/// Eras that need metal; without it a people stays at Crafting.
pub const FORGING: usize = 3;
/// Traditions of magic (Arcane Magic) and the progress needed for each.
pub const ARCANA: [(&str, i64); 5] = [
    ("None", 0),
    ("Hedge Magic", 10),
    ("Rituals", 60),
    ("Arcane Schools", 250),
    ("High Magic", 800),
];
const MAX_SETTLEMENTS: usize = 40;
/// A region holds at most this many of its people's settlements: the first,
/// and daughter villages founded by it as it grows.
pub const MAX_PER_REGION: usize = 4;
/// A settlement this big (thousands) may found a daughter village nearby.
const DAUGHTER_AT: i64 = 6;
/// Settlements more than this many regions apart do not border.
const BORDER: usize = 3;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Culture {
    /// From aggression: readiness for war.
    pub militarism: Fx,
    /// From curiosity: drive to expand and learn.
    pub openness: Fx,
    /// From sociability: how well the people holds together.
    pub cohesion: Fx,
    /// From fear: defensiveness and wariness of strangers.
    pub caution: Fx,
}

impl Culture {
    fn similarity(&self, o: &Culture) -> Fx {
        let d = (self.militarism - o.militarism).abs()
            + (self.openness - o.openness).abs()
            + (self.cohesion - o.cohesion).abs()
            + (self.caution - o.caution).abs();
        Fx::ONE - d / Fx::from_int(4)
    }

    pub fn describe(&self) -> String {
        let mut words = Vec::new();
        let high = Fx::ratio(6, 10);
        let low = Fx::ratio(35, 100);
        if self.militarism > high {
            words.push("warlike");
        } else if self.militarism < low {
            words.push("peaceful");
        }
        if self.openness > high {
            words.push("expansive");
        } else if self.openness < low {
            words.push("insular");
        }
        if self.cohesion > high {
            words.push("united");
        } else if self.cohesion < low {
            words.push("fractious");
        }
        if self.caution > high {
            words.push("wary");
        }
        if words.is_empty() {
            "moderate".into()
        } else {
            words.join(", ")
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Settlement {
    pub region: usize,
    pub name: String,
    /// Population in thousands: its share of the species' biomass in the
    /// region.
    pub population: Fx,
    pub founded_tick: u64,
    /// Share of its people in the region (the shares of one people's
    /// settlements in a region add up to one).
    pub share: Fx,
}

/// How big a settlement is, from its population (thousands).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Tier {
    Camp,
    Village,
    Town,
    City,
    Metropolis,
}

impl Tier {
    pub fn of(population: Fx) -> Tier {
        let p = population.to_f64();
        if p >= 30.0 {
            Tier::Metropolis
        } else if p >= 12.0 {
            Tier::City
        } else if p >= 4.0 {
            Tier::Town
        } else if p >= 1.0 {
            Tier::Village
        } else {
            Tier::Camp
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Tier::Camp => "Camp",
            Tier::Village => "Village",
            Tier::Town => "Town",
            Tier::City => "City",
            Tier::Metropolis => "Metropolis",
        }
    }
}

impl Settlement {
    pub fn tier(&self) -> Tier {
        Tier::of(self.population)
    }
}

/// What a settlement has raised. Buildings follow from the people's era,
/// the materials and water around the settlement, its culture and its
/// size, so they need no storage and replay exactly (§4.5).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Building {
    Huts,
    Longhouse,
    Palisade,
    Workshop,
    Granary,
    Walls,
    Forge,
    Mine,
    Harbour,
    Market,
    Library,
    Barracks,
    Shrine,
    Temple,
    Tower,
    Aqueduct,
    Factory,
}

impl Building {
    pub fn name(self) -> &'static str {
        match self {
            Building::Huts => "Huts",
            Building::Longhouse => "Longhouse",
            Building::Palisade => "Palisade",
            Building::Workshop => "Workshop",
            Building::Granary => "Granary",
            Building::Walls => "Walls",
            Building::Forge => "Forge",
            Building::Mine => "Mine",
            Building::Harbour => "Harbour",
            Building::Market => "Market",
            Building::Library => "Library",
            Building::Barracks => "Barracks",
            Building::Shrine => "Shrine",
            Building::Temple => "Temple",
            Building::Tower => "Wizard's tower",
            Building::Aqueduct => "Aqueduct",
            Building::Factory => "Factory",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Relation {
    pub other: u32,
    /// -1 hostile .. 1 friendly.
    pub opinion: Fx,
    pub at_war: bool,
    pub war_since: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Civilization {
    pub id: u32,
    pub species: u32,
    pub name: String,
    pub color: [u8; 3],
    pub founded_tick: u64,
    pub fallen_tick: Option<u64>,
    /// The civilization it split from, if any.
    pub parent: Option<u32>,
    pub culture: Culture,
    pub settlements: Vec<Settlement>,
    pub tech: Fx,
    pub arcana: Fx,
    pub relations: Vec<Relation>,
    pub battles_won: u32,
    pub battles_lost: u32,
    /// The religion it holds, if any (§4.8).
    #[serde(default)]
    pub faith: Option<u32>,
    /// Wonder and fear at the player's works, towards a faith in the Maker.
    #[serde(default)]
    pub awe: Fx,
    #[serde(default)]
    pub dread: Fx,
}

fn level(table: &[(&str, i64)], points: Fx) -> usize {
    table
        .iter()
        .rposition(|(_, t)| points >= Fx::from_int(*t))
        .unwrap_or(0)
}

/// Regions apart (east–west wraps).
pub fn distance(a: usize, b: usize) -> usize {
    let (ax, ay) = (a % WIDTH, a / WIDTH);
    let (bx, by) = (b % WIDTH, b / WIDTH);
    let dx = ax.abs_diff(bx);
    dx.min(WIDTH - dx) + ay.abs_diff(by)
}

impl Civilization {
    pub fn is_alive(&self) -> bool {
        self.fallen_tick.is_none()
    }

    pub fn population(&self) -> Fx {
        self.settlements
            .iter()
            .fold(Fx::ZERO, |a, s| a + s.population)
    }

    pub fn capital(&self) -> Option<&Settlement> {
        self.settlements.first()
    }

    fn relation_mut(&mut self, other: u32) -> &mut Relation {
        if let Some(k) = self.relations.iter().position(|r| r.other == other) {
            return &mut self.relations[k];
        }
        self.relations.push(Relation {
            other,
            opinion: Fx::ZERO,
            at_war: false,
            war_since: 0,
        });
        self.relations.last_mut().unwrap()
    }

    pub fn at_war_with(&self, other: u32) -> bool {
        self.relations.iter().any(|r| r.other == other && r.at_war)
    }

    fn borders(&self, other: &Civilization) -> bool {
        self.settlements.iter().any(|a| {
            other
                .settlements
                .iter()
                .any(|b| distance(a.region, b.region) <= BORDER)
        })
    }
}

impl World {
    pub fn civilization(&self, id: u32) -> Option<&Civilization> {
        self.civs.iter().find(|c| c.id == id)
    }

    pub fn living_civs(&self) -> impl Iterator<Item = &Civilization> {
        self.civs.iter().filter(|c| c.is_alive())
    }

    /// The living civilization a species belongs to, if any. A species
    /// split by a schism belongs to the older one here.
    pub fn civ_of_species(&self, species: u32) -> Option<&Civilization> {
        self.living_civs().find(|c| c.species == species)
    }

    /// The technology era of a civilization (index into `ERAS`), capped at
    /// Crafting without a forgeable metal (iron or tungsten) in its lands.
    pub fn era(&self, c: &Civilization) -> usize {
        let raw = level(&ERAS, c.tech);
        if raw >= FORGING && !self.civ_has(c, "iron") && !self.civ_has(c, "tungsten") {
            FORGING - 1
        } else {
            raw
        }
    }

    pub fn arcana_level(&self, c: &Civilization) -> usize {
        level(&ARCANA, c.arcana)
    }

    /// The buildings of a settlement (§4.5): by era, materials, water,
    /// culture, magic and size. Derived, never stored.
    pub fn buildings(&self, c: &Civilization, s: &Settlement) -> Vec<Building> {
        let era = self.era(c);
        let tier = s.tier();
        let culture = c.culture;
        let arcana = self.arcana_level(c);
        let here = |key: &str| self.substance_index(key).is_some_and(|k| self.regions[s.region].amounts[k] >= Fx::ratio(2, 10));
        let water_near = neighbours(s.region).chain(std::iter::once(s.region)).any(|r| self.liquid_total(r) > Fx::ratio(2, 10));
        let mut out = vec![Building::Huts];
        if era >= 1 && culture.cohesion > Fx::ratio(4, 10) {
            out.push(Building::Longhouse);
        }
        if era >= 1 && culture.militarism > Fx::HALF && tier >= Tier::Village {
            out.push(Building::Palisade);
        }
        if era >= 2 {
            out.push(Building::Workshop);
        }
        if era >= 2 && tier >= Tier::Village {
            out.push(Building::Granary);
        }
        if era >= 2 && tier >= Tier::Town && (culture.militarism > Fx::ratio(4, 10) || culture.caution > Fx::HALF) {
            out.push(Building::Walls);
        }
        if era >= FORGING && (here("iron") || here("tungsten")) {
            out.push(Building::Forge);
        }
        if era >= 2 && ["iron", "gold", "tungsten", "rare_earths", "uranium", "thorium"].iter().any(|k| here(k)) {
            out.push(Building::Mine);
        }
        if era >= 2 && tier >= Tier::Town && water_near {
            out.push(Building::Harbour);
        }
        if era >= 4 && tier >= Tier::Town && culture.openness > Fx::ratio(4, 10) {
            out.push(Building::Market);
        }
        if era >= 4 && tier >= Tier::City && culture.openness > Fx::HALF {
            out.push(Building::Library);
        }
        if era >= FORGING && tier >= Tier::Town && culture.militarism > Fx::ratio(55, 100) {
            out.push(Building::Barracks);
        }
        if arcana >= 2 && tier >= Tier::Village {
            out.push(Building::Shrine);
        }
        // A people with a faith raises temples to it (§4.8).
        if c.faith.is_some() && era >= 1 && tier >= Tier::Town {
            out.push(Building::Temple);
        }
        if arcana >= 3 && tier >= Tier::Town {
            out.push(Building::Tower);
        }
        if era >= 4 && tier >= Tier::City && water_near {
            out.push(Building::Aqueduct);
        }
        if era >= 5 && tier >= Tier::City {
            out.push(Building::Factory);
        }
        out
    }

    /// Whether any settlement's region holds a useful amount of a substance.
    pub fn civ_has(&self, c: &Civilization, key: &str) -> bool {
        let Some(s) = self.substance_index(key) else {
            return false;
        };
        c.settlements
            .iter()
            .any(|st| self.regions[st.region].amounts[s] >= Fx::ratio(2, 10))
    }

    /// Strength bonus for each region a civilization has settled:
    /// (species, multiplier). Tools and organisation make a people
    /// stronger at home.
    pub(crate) fn settled_bonus(&self) -> Vec<Option<(u32, Fx)>> {
        let mut out = vec![None; REGION_COUNT];
        for c in self.living_civs() {
            let bonus = Fx::ONE + Fx::ratio(15, 100) * Fx::from_int(self.era(c) as i64);
            for s in &c.settlements {
                // Walls and barracks make a settlement harder to take; the
                // best defended settlement in a region counts.
                let b = self.buildings(c, s);
                let defence = Fx::ratio(10, 100) * Fx::from_int(b.contains(&Building::Walls) as i64 + b.contains(&Building::Barracks) as i64);
                let m = bonus + defence;
                if out[s.region].is_none_or(|(_, o)| m > o) {
                    out[s.region] = Some((c.species, m));
                }
            }
        }
        out
    }

    fn species_biomass(&self, region: usize, species: u32) -> Fx {
        self.regions[region]
            .populations
            .iter()
            .filter(|p| p.species == species)
            .fold(Fx::ZERO, |a, p| a + p.biomass)
    }

    fn settled(&self, region: usize) -> bool {
        self.living_civs()
            .any(|c| c.settlements.iter().any(|s| s.region == region))
    }

    /// Once a year: found, grow, advance, split, deal and fight.
    pub(crate) fn update_civilizations(&mut self) {
        if !self.tick.is_multiple_of(TICKS_PER_YEAR) {
            return;
        }
        self.found_civilizations();
        for k in 0..self.civs.len() {
            if self.civs[k].is_alive() {
                self.grow_civilization(k);
            }
        }
        self.update_religions();
        self.diplomacy();
        self.wars();
    }

    fn found_civilizations(&mut self) {
        let candidates: Vec<u32> = self
            .living_species()
            .filter(|s| {
                s.has(body::SAPIENCE) && !s.has(body::OTHERWORLDLY) && s.biomass >= Fx::from_int(3)
            })
            .map(|s| s.id)
            .filter(|&id| self.civ_of_species(id).is_none())
            .collect();
        for species in candidates {
            let Some(capital) = (0..REGION_COUNT)
                .filter(|&r| !self.settled(r))
                .max_by_key(|&r| (self.species_biomass(r, species), std::cmp::Reverse(r)))
            else {
                continue;
            };
            if self.species_biomass(capital, species) < Fx::ONE {
                continue;
            }
            let t = self.species_by_id(species).unwrap().temperament;
            let culture = Culture {
                militarism: t.aggression,
                openness: t.curiosity,
                cohesion: t.sociability,
                caution: t.fear,
            };
            self.new_civilization(species, culture, None, vec![capital]);
        }
    }

    fn new_civilization(
        &mut self,
        species: u32,
        culture: Culture,
        parent: Option<u32>,
        regions: Vec<usize>,
    ) -> u32 {
        let id = self.next_civ_id;
        self.next_civ_id += 1;
        let name = self.new_name();
        let color = self.species_by_id(species).map_or([200; 3], |s| s.color);
        // Schisms take on a shifted shade so the map tells them apart.
        let color = if parent.is_some() {
            [color[2], color[0], color[1]]
        } else {
            color
        };
        let settlements = regions
            .into_iter()
            .map(|region| Settlement {
                region,
                name: self.new_name(),
                population: self.species_biomass(region, species),
                founded_tick: self.tick,
                share: Fx::ONE,
            })
            .collect();
        self.civs.push(Civilization {
            id,
            species,
            name,
            color,
            founded_tick: self.tick,
            fallen_tick: None,
            parent,
            culture,
            settlements,
            tech: Fx::ZERO,
            arcana: Fx::ZERO,
            relations: Vec::new(),
            battles_won: 0,
            battles_lost: 0,
            faith: None,
            awe: Fx::ZERO,
            dread: Fx::ZERO,
        });
        id
    }

    /// Sets each settlement's population from its share of the people in
    /// its region.
    fn settle_populations(&mut self, k: usize) {
        let species = self.civs[k].species;
        let pops: Vec<Fx> = self.civs[k]
            .settlements
            .iter()
            .map(|s| self.species_biomass(s.region, species) * s.share)
            .collect();
        for (s, p) in self.civs[k].settlements.iter_mut().zip(pops) {
            s.population = p;
        }
    }

    /// Rescales a people's shares so they add up to one in every region it
    /// holds (after settlements are lost, taken or founded).
    fn normalise_shares(&mut self, k: usize) {
        let c = &mut self.civs[k];
        for i in 0..c.settlements.len() {
            let region = c.settlements[i].region;
            if c.settlements[..i].iter().any(|s| s.region == region) {
                continue;
            }
            let total = c.settlements.iter().filter(|s| s.region == region).fold(Fx::ZERO, |a, s| a + s.share);
            if total > Fx::ZERO && total != Fx::ONE {
                for s in c.settlements.iter_mut().filter(|s| s.region == region) {
                    s.share = s.share / total;
                }
            }
        }
    }

    fn grow_civilization(&mut self, k: usize) {
        let species = self.civs[k].species;
        // Settlements follow the people: they shrink, grow or are lost.
        self.settle_populations(k);
        self.civs[k].settlements.retain(|s| s.population >= Fx::HALF);
        if self.civs[k].settlements.is_empty() {
            self.civs[k].fallen_tick = Some(self.tick);
            return;
        }
        self.normalise_shares(k);
        self.settle_populations(k);

        // Expansion into neighbouring land where the species lives.
        let culture = self.civs[k].culture;
        if self.civs[k].settlements.len() < MAX_SETTLEMENTS
            && self
                .rng
                .chance(Fx::ratio(15, 100) + culture.openness * Fx::ratio(3, 10))
        {
            let mut best: Option<(Fx, usize)> = None;
            for s in &self.civs[k].settlements {
                for r in neighbours(s.region) {
                    let b = self.species_biomass(r, species);
                    if b >= Fx::ONE && !self.settled(r) && best.is_none_or(|(bb, br)| (b, r) > (bb, br))
                    {
                        best = Some((b, r));
                    }
                }
            }
            if let Some((b, region)) = best {
                let name = self.new_name();
                self.civs[k].settlements.push(Settlement {
                    region,
                    name,
                    population: b,
                    founded_tick: self.tick,
                    share: Fx::ONE,
                });
            }
        }

        // A big settlement sends out a daughter village within its own
        // region, taking a quarter of its people.
        let big = self.civs[k]
            .settlements
            .iter()
            .enumerate()
            .filter(|(_, s)| s.population >= Fx::from_int(DAUGHTER_AT))
            .filter(|(_, s)| self.civs[k].settlements.iter().filter(|o| o.region == s.region).count() < MAX_PER_REGION)
            .max_by_key(|(i, s)| (s.population, std::cmp::Reverse(*i)))
            .map(|(i, _)| i);
        if let Some(i) = big {
            if self.civs[k].settlements.len() < MAX_SETTLEMENTS
                && self.rng.chance(Fx::ratio(20, 100) + culture.openness * Fx::ratio(2, 10))
            {
                let name = self.new_name();
                let parent = &mut self.civs[k].settlements[i];
                let give = parent.share * Fx::ratio(1, 4);
                parent.share -= give;
                let region = parent.region;
                let population = parent.population * Fx::ratio(1, 4);
                parent.population -= population;
                self.civs[k].settlements.push(Settlement {
                    region,
                    name,
                    population,
                    founded_tick: self.tick,
                    share: give,
                });
            }
        }

        // Progress: technology for everyone, magic under Arcane Magic.
        // Bigger peoples learn faster, with diminishing returns: from
        // stone tools to industry takes more than a thousand years.
        let pop = self.civs[k].population();
        let mut learning = pop.sqrt() * (Fx::ratio(3, 10) + culture.openness) * Fx::ratio(1, 10);
        // Rare earths in their lands speed invention; so do libraries and
        // markets (a tenth each, up to half again).
        if self.civ_has(&self.civs[k], "rare_earths") {
            learning = learning * Fx::ratio(13, 10);
        }
        let learned: usize = self.civs[k]
            .settlements
            .iter()
            .map(|s| {
                let b = self.buildings(&self.civs[k], s);
                b.contains(&Building::Library) as usize + b.contains(&Building::Market) as usize
            })
            .sum();
        learning = learning * (Fx::ONE + Fx::ratio(learned.min(5) as i64, 10));
        self.civs[k].tech += learning;
        if self.laws.arcane > Fx::ZERO {
            let caster = self
                .species_by_id(species)
                .is_some_and(|s| s.has(body::SPELLCASTING));
            let mana = self.civs[k]
                .settlements
                .iter()
                .fold(Fx::ZERO, |a, s| a + self.mana(s.region))
                / Fx::from_int(self.civs[k].settlements.len() as i64);
            let gift = if caster { Fx::from_int(2) } else { Fx::ONE };
            self.civs[k].arcana += learning * (mana + Fx::ratio(1, 10)) * gift;
        }

        // Schism: a sprawling, fractious people splits in two.
        let n = self.civs[k].settlements.len();
        // A shared faith holds a people together; a cult tears at it.
        let faith_bond = match self.faith_character(k) {
            Some(crate::religion::Character::Cult) => -Fx::ratio(1, 10),
            Some(_) => Fx::ratio(15, 100),
            None => Fx::ZERO,
        };
        if n >= 12
            && culture.cohesion + faith_bond < Fx::ratio(4, 10)
            && self.rng.chance(Fx::ratio(5, 100))
        {
            let capital = self.civs[k].settlements[0].region;
            let mut order: Vec<usize> = (1..n).collect();
            order.sort_by_key(|&i| {
                (
                    std::cmp::Reverse(distance(capital, self.civs[k].settlements[i].region)),
                    i,
                )
            });
            let leaving: Vec<usize> = order[..n / 2].to_vec();
            let mut regions: Vec<usize> = leaving
                .iter()
                .map(|&i| self.civs[k].settlements[i].region)
                .collect();
            regions.sort();
            self.civs[k]
                .settlements
                .retain(|s| !regions.contains(&s.region));
            let drift = |rng: &mut crate::rng::Rng, v: Fx| {
                (v + rng.spread() * Fx::ratio(2, 10)).clamp(Fx::ZERO, Fx::ONE)
            };
            let new_culture = Culture {
                militarism: drift(&mut self.rng, culture.militarism),
                openness: drift(&mut self.rng, culture.openness),
                cohesion: drift(&mut self.rng, culture.cohesion),
                caution: drift(&mut self.rng, culture.caution),
            };
            let parent = self.civs[k].id;
            let tech = self.civs[k].tech;
            let arcana = self.civs[k].arcana;
            let id = self.new_civilization(species, new_culture, Some(parent), regions);
            let child = self.civs.len() - 1;
            self.civs[child].tech = tech;
            self.civs[child].arcana = arcana;
            // Splits begin with bad blood.
            self.civs[k].relation_mut(id).opinion = -Fx::ratio(3, 10);
            self.civs[child].relation_mut(parent).opinion = -Fx::ratio(3, 10);
        }
    }

    fn diplomacy(&mut self) {
        let living: Vec<usize> = (0..self.civs.len())
            .filter(|&k| self.civs[k].is_alive())
            .collect();
        for (x, &a) in living.iter().enumerate() {
            for &b in &living[x + 1..] {
                if !self.civs[a].borders(&self.civs[b]) {
                    continue;
                }
                let (ca, cb) = (self.civs[a].culture, self.civs[b].culture);
                let kin = self.civs[a].species == self.civs[b].species;
                // Shared faith warms relations; rival faiths sour them.
                let faith = match (self.civs[a].faith, self.civs[b].faith) {
                    (Some(x), Some(y)) if x == y => Fx::ratio(4, 100),
                    (Some(_), Some(_)) => -Fx::ratio(3, 100),
                    _ => Fx::ZERO,
                };
                let drift = (ca.similarity(&cb) - Fx::HALF) * Fx::ratio(1, 10)
                    - if kin { Fx::ZERO } else { Fx::ratio(5, 100) }
                    - (ca.caution + cb.caution) * Fx::ratio(2, 100)
                    + faith;
                let (ida, idb) = (self.civs[a].id, self.civs[b].id);
                let tick = self.tick;
                let opinion = {
                    let r = self.civs[a].relation_mut(idb);
                    r.opinion = (r.opinion + drift).clamp(-Fx::ONE, Fx::ONE);
                    r.opinion
                };
                self.civs[b].relation_mut(ida).opinion = opinion;
                let at_war = self.civs[a].at_war_with(idb);
                // Wrathful faiths go to war more readily.
                let zeal = |k: usize| if self.faith_character(k) == Some(crate::religion::Character::Wrathful) { Fx::ratio(1, 10) } else { Fx::ZERO };
                let warlike = (ca.militarism + zeal(a)).max(cb.militarism + zeal(b));
                // Hatred breeds war; how often depends on how warlike the
                // more martial side is. Truly peaceful peoples never start one.
                if !at_war
                    && opinion < -Fx::ratio(4, 10)
                    && warlike > Fx::ratio(35, 100)
                    && self.rng.chance(warlike * Fx::ratio(1, 10))
                {
                    for (k, other) in [(a, idb), (b, ida)] {
                        let r = self.civs[k].relation_mut(other);
                        r.at_war = true;
                        r.war_since = tick;
                    }
                } else if at_war {
                    let years = (tick - self.civs[a].relation_mut(idb).war_since) / TICKS_PER_YEAR;
                    if years >= 10 || self.rng.chance(Fx::ratio(1, 10)) {
                        for (k, other) in [(a, idb), (b, ida)] {
                            let r = self.civs[k].relation_mut(other);
                            r.at_war = false;
                            r.opinion = r.opinion.max(-Fx::ratio(2, 10));
                        }
                    }
                }
            }
        }
    }

    fn power(&self, k: usize) -> Fx {
        let c = &self.civs[k];
        c.population()
            * Fx::from_int(1 + self.era(c) as i64)
            * (Fx::HALF + c.culture.militarism)
    }

    fn wars(&mut self) {
        let living: Vec<usize> = (0..self.civs.len())
            .filter(|&k| self.civs[k].is_alive())
            .collect();
        for (x, &a) in living.iter().enumerate() {
            for &b in &living[x + 1..] {
                if !self.civs[a].at_war_with(self.civs[b].id) {
                    continue;
                }
                let pa = self.power(a) * self.rng.range(Fx::ratio(7, 10), Fx::ratio(13, 10));
                let pb = self.power(b) * self.rng.range(Fx::ratio(7, 10), Fx::ratio(13, 10));
                let (winner, loser) = if pa >= pb { (a, b) } else { (b, a) };
                self.battle(winner, loser);
            }
        }
    }

    /// One year's fighting: the loser's settlement nearest the winner is
    /// ravaged and, if small, taken (by kin) or razed (by strangers).
    fn battle(&mut self, winner: usize, loser: usize) {
        let Some((li, wr)) = self.civs[loser]
            .settlements
            .iter()
            .enumerate()
            .flat_map(|(i, s)| {
                self.civs[winner]
                    .settlements
                    .iter()
                    .map(move |w| (distance(s.region, w.region), i, w.region))
            })
            .min()
            .map(|(_, i, w)| (i, w))
        else {
            return;
        };
        let region = self.civs[loser].settlements[li].region;
        let loser_species = self.civs[loser].species;
        let tick = self.tick;
        // The fighting kills.
        for p in &mut self.regions[region].populations {
            if p.species == loser_species {
                p.biomass = p.biomass * Fx::ratio(6, 10);
            }
        }
        // Those who lived through it remember.
        for r in [region, wr] {
            for ind in self.individuals.iter_mut().filter(|i| i.is_alive() && i.region == r) {
                ind.remember(tick, MemoryKind::FoughtInWar, None);
            }
        }
        self.civs[winner].battles_won += 1;
        self.civs[loser].battles_lost += 1;
        // A region falls as a whole: every settlement the loser has there
        // is taken (by kin) or razed (by strangers) if together they are
        // small and the loser holds land elsewhere.
        let held = self.civs[loser].settlements.iter().filter(|s| s.region == region);
        let small = held.fold(Fx::ZERO, |a, s| a + s.population) < Fx::from_int(3);
        let elsewhere = self.civs[loser].settlements.iter().any(|s| s.region != region);
        if small && elsewhere {
            let (lost, kept): (Vec<Settlement>, Vec<Settlement>) =
                std::mem::take(&mut self.civs[loser].settlements).into_iter().partition(|s| s.region == region);
            self.civs[loser].settlements = kept;
            if self.civs[winner].species == loser_species {
                self.civs[winner].settlements.extend(lost);
            }
        }
    }

    /// Every settlement in a region, the first-founded first (one people
    /// holds a region, so they all share a civilization).
    pub fn settlements_at(&self, region: usize) -> Vec<(&Civilization, &Settlement)> {
        self.living_civs()
            .flat_map(|c| c.settlements.iter().filter(move |s| s.region == region).map(move |s| (c, s)))
            .collect()
    }

    /// The first-founded settlement in a region, for the viewer.
    pub fn settlement_at(&self, region: usize) -> Option<(&Civilization, &Settlement)> {
        self.living_civs().find_map(|c| {
            c.settlements
                .iter()
                .find(|s| s.region == region)
                .map(|s| (c, s))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::HEIGHT;

    #[test]
    fn distances_wrap_east_west() {
        let a = 0;
        let b = WIDTH - 1;
        assert_eq!(distance(a, b), 1);
        assert_eq!(distance(0, WIDTH * (HEIGHT - 1)), HEIGHT - 1);
    }

    #[test]
    fn eras_by_progress() {
        assert_eq!(level(&ERAS, Fx::ZERO), 0);
        assert_eq!(level(&ERAS, Fx::from_int(100)), 2);
        assert_eq!(level(&ERAS, Fx::from_int(5000)), 5);
    }
}
