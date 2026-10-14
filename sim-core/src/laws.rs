//! Metaphysical laws (docs/GAME_DESIGN.md §4.6): Arcane Magic, Soul Power
//! and Daoist Cultivation. Each is a strength from 0 (absent) to 1 set by
//! the player. With every law at 0 the world runs exactly as before.
//!
//! - **Arcane Magic** fills regions with mana along seeded ley lines. Lineages
//!   with nervous systems can evolve Spellcasting where mana runs high;
//!   magic makes them stronger hunters and rivals. Where ley lines converge
//!   the Veil thins.
//! - **Soul Power** gives named individuals a soul that grows with age and
//!   renown. When they die their soul may persist and be reborn in a new
//!   individual, carrying part of its strength. Mass deaths release souls
//!   and tear the Veil.
//! - **Daoist Cultivation** fills regions with qi (richest in the mountains).
//!   Named individuals absorb it and break through cultivation realms, each
//!   breakthrough facing a heavenly tribulation that may kill them. Every
//!   breakthrough strains the Veil.

use crate::body;
use crate::fixed::Fx;
use crate::individual::MemoryKind;
use crate::world::{World, HEIGHT, WIDTH};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Laws {
    /// Arcane Magic: mana density, 0..1.
    pub arcane: Fx,
    /// Soul Power: soul persistence, 0..1.
    pub soul: Fx,
    /// Daoist Cultivation: qi density, 0..1.
    pub qi: Fx,
    /// Daoist Cultivation: how deadly breakthroughs are, 0..1.
    pub tribulation: Fx,
}

impl Default for Laws {
    fn default() -> Laws {
        Laws {
            arcane: Fx::ZERO,
            soul: Fx::ZERO,
            qi: Fx::ZERO,
            tribulation: Fx::ratio(3, 10),
        }
    }
}

/// Which law an action sets (`Action::SetLaw`).
pub const ARCANE: u8 = 0;
pub const SOUL: u8 = 1;
pub const QI: u8 = 2;
pub const TRIBULATION: u8 = 3;

/// Cultivation realms, from the first breakthrough upwards.
pub const REALMS: [&str; 9] = [
    "Qi Condensation",
    "Foundation Establishment",
    "Core Formation",
    "Nascent Soul",
    "Soul Transformation",
    "Void Refinement",
    "Body Integration",
    "Mahayana",
    "Tribulation Transcendence",
];

/// A soul waiting to be reborn (Soul Power).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WanderingSoul {
    /// The individual it last belonged to.
    pub from: u32,
    pub strength: Fx,
}

/// Most souls waiting at once; the oldest fade first.
const MAX_WANDERING_SOULS: usize = 64;
/// Share of soul strength carried into the next life.
const INHERITANCE: Fx = Fx::ratio(3, 4);
const MAX_SOUL: Fx = Fx::from_int(10);

/// A seeded value 0..1 at a lattice point (hashing, so it does not touch
/// the world's random stream).
fn lattice(seed: u64, salt: u64, gx: usize, gy: usize) -> Fx {
    let mut z = seed ^ salt.wrapping_mul(0xD1B5_4A32_D192_ED03)
        ^ ((gx as u64) << 32 | gy as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;
    Fx::ratio((z % 1024) as i64, 1023)
}

/// A smooth seeded field 0..1 over the map: bilinear between lattice points
/// eight regions apart (wrapping east–west).
fn smooth_field(seed: u64, salt: u64, i: usize) -> Fx {
    const CELL: usize = 8;
    let (x, y) = (i % WIDTH, i / WIDTH);
    let (gx, gy) = (x / CELL, y / CELL);
    let cols = WIDTH / CELL;
    let fx = Fx::ratio((x % CELL) as i64, CELL as i64);
    let fy = Fx::ratio((y % CELL) as i64, CELL as i64);
    let at = |gx: usize, gy: usize| lattice(seed, salt, gx % cols, gy.min(HEIGHT / CELL));
    let top = at(gx, gy) + (at(gx + 1, gy) - at(gx, gy)) * fx;
    let bottom = at(gx, gy + 1) + (at(gx + 1, gy + 1) - at(gx, gy + 1)) * fx;
    top + (bottom - top) * fy
}

impl World {
    /// Mana in a region (Arcane Magic), 0..1.
    pub fn mana(&self, i: usize) -> Fx {
        if self.laws.arcane == Fx::ZERO {
            return Fx::ZERO;
        }
        // Ley lines: the field squared, so mana gathers in a few places.
        let f = smooth_field(self.seed, 1, i);
        (self.laws.arcane * f * f * Fx::from_int(2)).min(Fx::ONE)
    }

    /// Qi in a region (Daoist Cultivation), 0..1: richest in high places.
    pub fn qi(&self, i: usize) -> Fx {
        if self.laws.qi == Fx::ZERO {
            return Fx::ZERO;
        }
        let f = smooth_field(self.seed, 2, i);
        (self.laws.qi * (f + self.regions[i].elevation) * Fx::HALF).clamp(Fx::ZERO, Fx::ONE)
    }

    pub(crate) fn set_law(&mut self, law: u8, value: Fx) {
        let v = value.clamp(Fx::ZERO, Fx::ONE);
        match law {
            ARCANE => self.laws.arcane = v,
            SOUL => self.laws.soul = v,
            QI => self.laws.qi = v,
            TRIBULATION => self.laws.tribulation = v,
            _ => {}
        }
    }

    /// Extra Veil thinning from the laws in one region: ley-line
    /// convergence (Arcane Magic).
    pub(crate) fn law_thinning(&self, i: usize) -> Fx {
        (self.mana(i) - Fx::ratio(6, 10)).max(Fx::ZERO) * Fx::ratio(8, 10)
    }

    /// Mass deaths release souls and tear the Veil (Soul Power).
    pub(crate) fn souls_released(&mut self, i: usize, biomass_lost: Fx) {
        if self.laws.soul == Fx::ZERO || biomass_lost < Fx::from_int(5) {
            return;
        }
        let tear = (biomass_lost * self.laws.soul * Fx::ratio(4, 1000)).min(Fx::ratio(15, 100));
        self.veil[i] = (self.veil[i] - tear).max(Fx::ZERO);
    }

    /// An individual died: under Soul Power its soul may persist.
    pub(crate) fn soul_departs(&mut self, k: usize) {
        if self.laws.soul == Fx::ZERO {
            return;
        }
        let strength = self.individuals[k].soul;
        if strength < Fx::ratio(1, 10) {
            return;
        }
        if self.rng.chance(self.laws.soul * Fx::ratio(8, 10)) {
            if self.souls.len() >= MAX_WANDERING_SOULS {
                self.souls.remove(0);
            }
            self.souls.push(WanderingSoul {
                from: self.individuals[k].id,
                strength,
            });
        }
    }

    /// A newborn individual may receive a waiting soul (the oldest first).
    pub(crate) fn soul_arrives(&mut self, k: usize) {
        if self.laws.soul == Fx::ZERO || self.souls.is_empty() {
            return;
        }
        let soul = self.souls.remove(0);
        let tick = self.tick;
        let ind = &mut self.individuals[k];
        ind.soul = soul.strength * INHERITANCE;
        ind.past_life = Some(soul.from);
        ind.remember(tick, MemoryKind::Reborn, Some(soul.from));
    }

    /// Each season: souls grow; cultivators absorb qi and try to break
    /// through.
    pub(crate) fn laws_season(&mut self) {
        let laws = self.laws;
        if laws.soul == Fx::ZERO && laws.qi == Fx::ZERO {
            return;
        }
        let ids: Vec<u32> = self.living_individuals().map(|x| x.id).collect();
        for id in ids {
            let Ok(k) = self.individuals.binary_search_by_key(&id, |x| x.id) else {
                continue;
            };
            if laws.soul > Fx::ZERO {
                let ind = &mut self.individuals[k];
                let growth = laws.soul * (Fx::ratio(1, 100) + ind.renown * Fx::ratio(2, 100));
                ind.soul = (ind.soul + growth).min(MAX_SOUL);
            }
            if laws.qi > Fx::ZERO {
                self.cultivate(k);
            }
        }
    }

    fn cultivate(&mut self, k: usize) {
        let ind = &self.individuals[k];
        let Some(species) = self.species_by_id(ind.species) else {
            return;
        };
        if !species.has(body::NERVOUS) || species.has(body::OTHERWORLDLY) {
            return;
        }
        let region = ind.region;
        // Calm, bright minds absorb qi best; a beast barely can.
        let calm = Fx::ONE - ind.personality.aggression;
        let gain = self.qi(region)
            * species.traits.intelligence
            * (Fx::ratio(2, 100) + calm * Fx::ratio(8, 100));
        let realm = ind.realm;
        if realm as usize >= REALMS.len() {
            return;
        }
        let ind = &mut self.individuals[k];
        ind.qi += gain;
        let threshold = Fx::from_int(1i64 << realm);
        if ind.qi < threshold {
            return;
        }
        // Breakthrough: a heavenly tribulation.
        let death = (self.laws.tribulation
            * (Fx::ratio(1, 10) + Fx::ratio(5, 100) * Fx::from_int(realm as i64)))
        .min(Fx::ratio(9, 10));
        if self.rng.chance(death) {
            self.kill_individual(k, "perished in a heavenly tribulation".into(), None);
            return;
        }
        let tick = self.tick;
        let ind = &mut self.individuals[k];
        ind.realm += 1;
        ind.qi = Fx::ZERO;
        ind.lifespan += ind.lifespan / 4;
        ind.renown += Fx::ratio(2, 10) * Fx::from_int(ind.realm as i64);
        ind.remember(tick, MemoryKind::Breakthrough, None);
        // Breaking through strains the Veil.
        let strain = Fx::ratio(3, 100) * Fx::from_int(self.individuals[k].realm as i64);
        self.veil[region] = (self.veil[region] - strain).max(Fx::ZERO);
    }

    /// Living individuals at or above a cultivation realm.
    pub fn cultivators(&self, realm: u8) -> usize {
        self.living_individuals().filter(|x| x.realm >= realm).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::REGION_COUNT;

    #[test]
    fn fields_are_smooth_and_seeded() {
        let a: Vec<Fx> = (0..REGION_COUNT).map(|i| smooth_field(3, 1, i)).collect();
        let b: Vec<Fx> = (0..REGION_COUNT).map(|i| smooth_field(3, 1, i)).collect();
        assert_eq!(a, b);
        // Neighbours differ only a little.
        for i in 0..REGION_COUNT - 1 {
            if (i + 1) % WIDTH != 0 {
                assert!((a[i] - a[i + 1]).abs() <= Fx::ratio(15, 100));
            }
        }
        assert!(a.iter().any(|&v| v > Fx::ratio(7, 10)) && a.iter().any(|&v| v < Fx::ratio(3, 10)));
    }
}
