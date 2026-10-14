//! Named individuals: persistent beings with their own brains, personalities,
//! relationships and memories (docs/GAME_DESIGN.md §4.8, level 2).
//!
//! Individuals are part of the main simulation, not of the camera view, so
//! server replay covers them and they behave the same whether or not anyone
//! is watching. They appear once a species has a nervous system.

use crate::body;
use crate::brain::{self, input, output, Brain, Temperament, INPUTS};
use crate::fixed::Fx;
use crate::hash::StateHasher;
use crate::world::{neighbours, World, TICKS_PER_YEAR};

/// Living named individuals per world.
pub const MAX_LIVING_INDIVIDUALS: usize = 300;
/// Stored records, living and dead; the oldest dead are dropped first.
const MAX_RECORDS: usize = 600;
const MAX_RELATIONS: usize = 8;
const MAX_MEMORIES: usize = 12;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemoryKind {
    Born,
    Befriended,
    Defeated,
    WasDefeated,
    Killed,
    Migrated,
    Fled,
    MournedFriend,
    WitnessedHorror,
}

impl MemoryKind {
    pub fn describe(self) -> &'static str {
        match self {
            MemoryKind::Born => "was born",
            MemoryKind::Befriended => "befriended",
            MemoryKind::Defeated => "defeated",
            MemoryKind::WasDefeated => "was defeated by",
            MemoryKind::Killed => "killed",
            MemoryKind::Migrated => "moved to new lands",
            MemoryKind::Fled => "fled danger",
            MemoryKind::MournedFriend => "mourned the death of",
            MemoryKind::WitnessedHorror => "glimpsed a being from beyond the Veil",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Memory {
    pub tick: u64,
    pub kind: MemoryKind,
    pub other: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Relation {
    pub other: u32,
    /// -1 (hatred) .. 1 (deep bond).
    pub affinity: Fx,
    pub kin: bool,
}

#[derive(Clone, Debug)]
pub struct Individual {
    pub id: u32,
    pub species: u32,
    pub name: String,
    pub region: usize,
    pub born_tick: u64,
    pub lifespan: u64,
    pub parent: Option<u32>,
    /// Personal variant of the species brain.
    pub brain: Brain,
    pub personality: Temperament,
    pub health: Fx,
    /// Fame from deeds; feeds Charisma and later champion backstories.
    pub renown: Fx,
    pub relations: Vec<Relation>,
    pub memories: Vec<Memory>,
    pub last_action: Option<usize>,
    pub death_tick: Option<u64>,
    pub cause_of_death: Option<String>,
}

impl Individual {
    pub fn is_alive(&self) -> bool {
        self.death_tick.is_none()
    }

    pub fn age_years(&self, tick: u64) -> u64 {
        (self.death_tick.unwrap_or(tick) - self.born_tick) / TICKS_PER_YEAR
    }

    pub fn friends(&self) -> usize {
        self.relations
            .iter()
            .filter(|r| r.affinity >= Fx::HALF)
            .count()
    }

    pub fn enemies(&self) -> usize {
        self.relations
            .iter()
            .filter(|r| r.affinity <= -Fx::HALF)
            .count()
    }

    /// Preview of the Charisma score (1–30) a character sheet would give:
    /// sociability, friendships and renown.
    pub fn charisma(&self) -> i64 {
        let social = self.personality.sociability * Fx::from_int(10);
        let friends = Fx::from_int(self.friends().min(6) as i64) * Fx::ratio(15, 10);
        let fame = (self.renown * Fx::from_int(4)).min(Fx::from_int(8));
        (Fx::from_int(3) + social + friends + fame)
            .to_int()
            .clamp(1, 30)
    }

    /// Epithet earned from personality and deeds, e.g. "the Bold".
    pub fn epithet(&self) -> Option<&'static str> {
        let p = &self.personality;
        let kills = self
            .memories
            .iter()
            .filter(|m| m.kind == MemoryKind::Killed)
            .count();
        if kills >= 2 {
            Some("the Slayer")
        } else if self.renown >= Fx::ONE && p.aggression > Fx::ratio(6, 10) {
            Some("the Fierce")
        } else if self.friends() >= 4 {
            Some("the Beloved")
        } else if self.renown >= Fx::ONE {
            Some("the Renowned")
        } else if p.fear < Fx::ratio(25, 100) {
            Some("the Bold")
        } else if p.curiosity > Fx::ratio(75, 100) {
            Some("the Wanderer")
        } else {
            None
        }
    }

    pub fn title(&self) -> String {
        match self.epithet() {
            Some(e) => format!("{} {}", self.name, e),
            None => self.name.clone(),
        }
    }

    fn remember(&mut self, tick: u64, kind: MemoryKind, other: Option<u32>) {
        self.memories.push(Memory { tick, kind, other });
        if self.memories.len() > MAX_MEMORIES {
            // Keep the birth memory; forget the oldest event after it.
            self.memories.remove(1);
        }
    }

    pub fn affinity(&self, other: u32) -> Fx {
        self.relations
            .iter()
            .find(|r| r.other == other)
            .map_or(Fx::ZERO, |r| r.affinity)
    }

    /// Changes affinity towards `other`, creating the relation if needed.
    /// Returns (before, after).
    fn adjust(&mut self, other: u32, delta: Fx, kin: bool) -> (Fx, Fx) {
        if let Some(r) = self.relations.iter_mut().find(|r| r.other == other) {
            let before = r.affinity;
            r.affinity = (r.affinity + delta).clamp(-Fx::ONE, Fx::ONE);
            r.kin |= kin;
            return (before, r.affinity);
        }
        if self.relations.len() >= MAX_RELATIONS {
            // Forget the weakest non-kin bond to make room.
            let weakest = self
                .relations
                .iter()
                .enumerate()
                .filter(|(_, r)| !r.kin)
                .min_by_key(|(_, r)| (r.affinity.abs(), r.other))
                .map(|(i, _)| i);
            match weakest {
                Some(i) => {
                    self.relations.remove(i);
                }
                None => return (Fx::ZERO, Fx::ZERO),
            }
        }
        let after = delta.clamp(-Fx::ONE, Fx::ONE);
        self.relations.push(Relation {
            other,
            affinity: after,
            kin,
        });
        (Fx::ZERO, after)
    }

    pub(crate) fn hash_into(&self, h: &mut StateHasher) {
        h.u64(self.id as u64);
        h.u64(self.species as u64);
        h.u64(self.region as u64);
        h.u64(self.lifespan);
        h.i64(self.health.0);
        h.i64(self.renown.0);
        self.brain.hash_into(h);
        for r in &self.relations {
            h.u64(r.other as u64);
            h.i64(r.affinity.0);
        }
        h.u64(self.memories.len() as u64);
        h.u64(self.death_tick.map_or(u64::MAX, |t| t));
    }
}

impl World {
    pub fn individual_by_id(&self, id: u32) -> Option<&Individual> {
        self.individuals
            .binary_search_by_key(&id, |x| x.id)
            .ok()
            .map(|i| &self.individuals[i])
    }

    pub fn living_individuals(&self) -> impl Iterator<Item = &Individual> {
        self.individuals.iter().filter(|x| x.is_alive())
    }

    pub(crate) fn update_individuals(&mut self) {
        self.spawn_individuals();
        self.individuals_act();
        while self.individuals.len() > MAX_RECORDS {
            match self.individuals.iter().position(|x| !x.is_alive()) {
                Some(i) => {
                    self.individuals.remove(i);
                }
                None => break,
            }
        }
    }

    /// Individuals appear in small family groups among species that have a
    /// nervous system.
    fn spawn_individuals(&mut self) {
        let mut living = self.living_individuals().count();
        for _ in 0..4 {
            if living >= MAX_LIVING_INDIVIDUALS {
                return;
            }
            let region = self.rng.below(self.regions.len() as u64) as usize;
            let candidate = self.regions[region]
                .populations
                .iter()
                .filter(|p| p.biomass >= Fx::ONE)
                .filter_map(|p| self.species_by_id(p.species).map(|s| (p, s)))
                .filter(|(_, s)| s.has(body::NERVOUS))
                .max_by_key(|(p, s)| (p.biomass, std::cmp::Reverse(s.id)))
                .map(|(_, s)| (s.id, s.genome.size, s.genome.brain.clone()));
            let Some((species, size, species_brain)) = candidate else {
                continue;
            };
            let group = (1 + self.rng.below(3) as usize).min(MAX_LIVING_INDIVIDUALS - living);
            let mut first: Option<u32> = None;
            for _ in 0..group {
                let id = self.next_individual_id;
                self.next_individual_id += 1;
                let brain =
                    species_brain.mutated(&mut self.rng, Fx::ratio(3, 10), Fx::ratio(3, 10));
                let years = (Fx::from_int(10) + Fx::from_int(15) * size.sqrt())
                    * self.rng.range(Fx::ratio(7, 10), Fx::ratio(13, 10));
                let lifespan = (years.clamp(Fx::from_int(5), Fx::from_int(300))
                    * Fx::from_int(TICKS_PER_YEAR as i64))
                .to_int() as u64;
                let mut ind = Individual {
                    id,
                    species,
                    name: self.new_name(),
                    region,
                    born_tick: self.tick,
                    lifespan,
                    parent: None,
                    personality: brain::temperament(&brain),
                    brain,
                    health: Fx::ONE,
                    renown: Fx::ZERO,
                    relations: Vec::new(),
                    memories: Vec::new(),
                    last_action: None,
                    death_tick: None,
                    cause_of_death: None,
                };
                ind.remember(self.tick, MemoryKind::Born, None);
                // Members of a group are siblings.
                if let Some(sib) = first {
                    ind.adjust(sib, Fx::HALF, true);
                    let si = self.individual_index(sib);
                    self.individuals[si].adjust(id, Fx::HALF, true);
                } else {
                    first = Some(id);
                }
                self.individuals.push(ind);
                living += 1;
            }
        }
    }

    fn individual_index(&self, id: u32) -> usize {
        self.individuals
            .binary_search_by_key(&id, |x| x.id)
            .expect("known individual")
    }

    /// Living individuals currently in a region, in id order.
    fn individuals_in(&self, region: usize) -> Vec<usize> {
        (0..self.individuals.len())
            .filter(|&k| self.individuals[k].is_alive() && self.individuals[k].region == region)
            .collect()
    }

    fn kill_individual(&mut self, k: usize, cause: String, killer: Option<u32>) {
        let tick = self.tick;
        let id = self.individuals[k].id;
        self.individuals[k].death_tick = Some(tick);
        self.individuals[k].cause_of_death = Some(cause);
        // Friends mourn, and hold a grudge against the killer.
        let friends: Vec<u32> = self.individuals[k]
            .relations
            .iter()
            .filter(|r| r.affinity >= Fx::ratio(4, 10))
            .map(|r| r.other)
            .collect();
        for f in friends {
            if let Ok(fi) = self.individuals.binary_search_by_key(&f, |x| x.id) {
                if !self.individuals[fi].is_alive() {
                    continue;
                }
                self.individuals[fi].remember(tick, MemoryKind::MournedFriend, Some(id));
                if let Some(killer) = killer {
                    if killer != f {
                        self.individuals[fi].adjust(killer, -Fx::ratio(6, 10), false);
                    }
                }
            }
        }
    }

    fn combat_power(&mut self, k: usize) -> Fx {
        let ind = &self.individuals[k];
        let (strength, size) = self
            .species_by_id(ind.species)
            .map_or((Fx::ONE, Fx::ONE), |s| (s.strength(), s.genome.size));
        let base = strength
            * (Fx::ONE + size.sqrt() * Fx::ratio(2, 10))
            * (Fx::HALF + ind.health)
            * (Fx::ratio(75, 100) + ind.personality.aggression * Fx::HALF);
        base * self.rng.range(Fx::ratio(6, 10), Fx::ratio(14, 10))
    }

    fn individuals_act(&mut self) {
        let tick = self.tick;
        let ids: Vec<u32> = self.living_individuals().map(|x| x.id).collect();
        for id in ids {
            let k = self.individual_index(id);
            if !self.individuals[k].is_alive() {
                continue;
            }
            let (species_id, region) = (self.individuals[k].species, self.individuals[k].region);
            let Some(species) = self.species_by_id(species_id).cloned() else {
                self.kill_individual(k, "its kind vanished".into(), None);
                continue;
            };

            if tick - self.individuals[k].born_tick >= self.individuals[k].lifespan {
                self.kill_individual(k, "old age".into(), None);
                continue;
            }

            // If its species no longer lives here, move or perish.
            let present = |w: &World, r: usize| {
                w.regions[r]
                    .populations
                    .iter()
                    .any(|p| p.species == species_id)
            };
            if !present(self, region) {
                match neighbours(region).find(|&r| present(self, r)) {
                    Some(r) => self.individuals[k].region = r,
                    None => {
                        self.kill_individual(k, "its homeland died out".into(), None);
                        continue;
                    }
                }
            }
            let region = self.individuals[k].region;

            // Senses.
            let size = species.genome.size;
            let ratio = Fx::from_int(3);
            let (mut threat, mut prey) = (Fx::ZERO, Fx::ZERO);
            let native = !species.has(body::OTHERWORLDLY);
            for p in &self.regions[region].populations {
                if let Some(other) = self.species_by_id(p.species) {
                    if native && other.has(body::OTHERWORLDLY) {
                        // Whatever its size, a thing from beyond is terrifying.
                        threat += p.biomass * Fx::from_int(3);
                    } else if other.genome.size >= size * ratio && other.traits.offense > Fx::ratio(2, 10)
                    {
                        threat += p.biomass;
                    } else if other.genome.size * ratio <= size {
                        prey += p.biomass;
                    }
                }
            }
            if native
                && self.entity_biomass(region) > Fx::ZERO
                && !self.individuals[k]
                    .memories
                    .iter()
                    .any(|m| m.kind == MemoryKind::WitnessedHorror)
            {
                self.individuals[k].remember(tick, MemoryKind::WitnessedHorror, None);
            }
            let others: Vec<usize> = self
                .individuals_in(region)
                .into_iter()
                .filter(|&o| o != k)
                .collect();
            let me = &self.individuals[k];
            let kin_here = others
                .iter()
                .any(|&o| self.individuals[o].species == species_id);
            let stranger_here = others.iter().any(|&o| {
                self.individuals[o].species != species_id
                    || me.affinity(self.individuals[o].id) < Fx::ZERO
            });
            let food = self.life[region].fit(&species.profile);
            let sat = |x: Fx| x / (x + Fx::from_int(5));
            let mut x = [Fx::ZERO; INPUTS];
            x[input::FOOD] = food;
            x[input::THREAT] = sat(threat);
            x[input::PREY] = sat(prey);
            x[input::STRANGER] = if stranger_here { Fx::ONE } else { Fx::ZERO };
            x[input::KIN] = if kin_here { Fx::ONE } else { Fx::ZERO };
            x[input::HUNGER] = Fx::ONE - food.min(Fx::ONE);
            x[input::INJURY] = Fx::ONE - me.health;
            x[input::BIAS] = Fx::ONE;
            let action = me.brain.decide(&x);
            self.individuals[k].last_action = Some(action);

            match action {
                output::APPROACH => {
                    // Seek better land, or friends.
                    let score = |w: &World, r: usize| {
                        let friends = w
                            .individuals_in(r)
                            .iter()
                            .filter(|&&o| w.individuals[k].affinity(w.individuals[o].id) > Fx::ZERO)
                            .count();
                        w.life[r].fit(&species.profile)
                            + Fx::ratio(3, 10) * Fx::from_int(friends as i64)
                    };
                    let here = score(self, region);
                    let best = neighbours(region)
                        .map(|r| (score(self, r), r))
                        .filter(|(s, r)| *s > here && present(self, *r))
                        .max_by_key(|(s, r)| (*s, std::cmp::Reverse(*r)));
                    if let Some((_, r)) = best {
                        self.individuals[k].region = r;
                        self.individuals[k].remember(tick, MemoryKind::Migrated, None);
                    }
                }
                output::FLEE => {
                    if threat > Fx::ZERO || self.individuals[k].health < Fx::HALF {
                        let options: Vec<usize> =
                            neighbours(region).filter(|&r| present(self, r)).collect();
                        if !options.is_empty() {
                            let r = options[self.rng.below(options.len() as u64) as usize];
                            self.individuals[k].region = r;
                            self.individuals[k].remember(tick, MemoryKind::Fled, None);
                        }
                    }
                }
                output::ATTACK => {
                    // Picks the one it likes least.
                    let target = others.iter().copied().min_by_key(|&o| {
                        (
                            self.individuals[k].affinity(self.individuals[o].id),
                            self.individuals[o].id,
                        )
                    });
                    if let Some(t) = target {
                        self.fight(k, t);
                    }
                }
                _ => {
                    // Socialise with the one it likes most.
                    let target = others.iter().copied().max_by_key(|&o| {
                        (
                            self.individuals[k].affinity(self.individuals[o].id),
                            std::cmp::Reverse(self.individuals[o].id),
                        )
                    });
                    if let Some(t) = target {
                        let (a, b) = (self.individuals[k].id, self.individuals[t].id);
                        let warmth = (self.individuals[k].personality.sociability
                            + self.individuals[t].personality.sociability)
                            * Fx::ratio(15, 100);
                        let same_kind = self.individuals[t].species == species_id;
                        let warmth = if same_kind { warmth } else { warmth * Fx::HALF };
                        let (before, after) = self.individuals[k].adjust(b, warmth, false);
                        self.individuals[t].adjust(a, warmth, false);
                        if before < Fx::HALF && after >= Fx::HALF {
                            self.individuals[k].remember(tick, MemoryKind::Befriended, Some(b));
                            self.individuals[t].remember(tick, MemoryKind::Befriended, Some(a));
                        }
                        self.individuals[k].renown += Fx::ratio(2, 1000);
                    }
                }
            }
            let ind = &mut self.individuals[k];
            if ind.is_alive() {
                ind.health = (ind.health + Fx::ratio(5, 100)).min(Fx::ONE);
            }
        }
    }

    fn fight(&mut self, a: usize, b: usize) {
        let tick = self.tick;
        let (pa, pb) = (self.combat_power(a), self.combat_power(b));
        let (winner, loser) = if pa >= pb { (a, b) } else { (b, a) };
        let (wid, lid) = (self.individuals[winner].id, self.individuals[loser].id);
        let wound = Fx::ratio(25, 100) + self.rng.unit() * Fx::ratio(3, 10);
        self.individuals[loser].health -= wound;
        self.individuals[winner].adjust(lid, -Fx::ratio(4, 10), false);
        self.individuals[loser].adjust(wid, -Fx::ratio(4, 10), false);
        let gain = Fx::ratio(1, 10) + self.individuals[loser].renown * Fx::ratio(2, 10);
        self.individuals[winner].renown += gain;
        self.individuals[winner].remember(tick, MemoryKind::Defeated, Some(lid));
        self.individuals[loser].remember(tick, MemoryKind::WasDefeated, Some(wid));
        if self.individuals[loser].health <= Fx::ZERO {
            self.individuals[winner].remember(tick, MemoryKind::Killed, Some(lid));
            let cause = format!("slain by {}", self.individuals[winner].name);
            self.kill_individual(loser, cause, Some(wid));
        }
    }
}
