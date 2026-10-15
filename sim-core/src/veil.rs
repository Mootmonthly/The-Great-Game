//! The Veil and extradimensional beings (docs/GAME_DESIGN.md §4.4a).
//!
//! Each region has a Veil strength from 0 (wide open) to 1 (sealed). The
//! Veil law, reality strain (Godhand settings, neutron stars, crushing
//! gravity) and eclipses from many moons thin it everywhere; seeded "fault
//! lines" make some places thinner than others, and beings already through
//! hold the door open where they live. Where the Veil falls below
//! `BREACH_THRESHOLD`, things can come through.
//!
//! Beings from beyond ignore the life triad. They feed on the minds of
//! nearby species with nervous systems, draining them, and fade away where
//! the Veil is strong.

use crate::body::{self, Body, PartKind};
use crate::brain::Brain;
use crate::fixed::Fx;
use crate::life::{EnergyKind, Genome, Profile};
use crate::world::{neighbours, Population, World, REGION_COUNT};

/// Below this Veil strength a region can be breached.
pub const BREACH_THRESHOLD: Fx = Fx::ratio(1, 2);
/// Most kinds of beings from beyond alive at once.
pub const MAX_ENTITY_SPECIES: usize = 8;

/// Seeded weakness of a region's Veil, 0..1. Derived by hashing, so it does
/// not touch the world's random stream.
fn fault(seed: u64, i: usize) -> Fx {
    let mut z = seed ^ (i as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ 0x005E_ED0F_7E11;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;
    Fx::ratio((z % 1000) as i64, 1000)
}

impl World {
    /// Planet-wide thinning of the Veil, 0 (none) .. 1.
    pub fn veil_thinning(&self) -> Fx {
        let law = self.veil_law * Fx::ratio(8, 10);
        let strain = self.reality_strain();
        let physics = strain / (strain + Fx::from_int(3)) * Fx::ratio(8, 10);
        // Frequent eclipses: every moon beyond the second, and, on a moon,
        // the planet hiding the sun.
        let extra_moons = (self.planet.moons.len() as i64 - 2).max(0);
        let eclipses = (Fx::ratio(5, 100) * Fx::from_int(extra_moons)
            + self.planet.eclipse_fraction() * Fx::from_int(5))
        .min(Fx::ratio(3, 10));
        (law + physics + eclipses).min(Fx::ONE)
    }

    /// Veil strength of a region, 0 (open) .. 1 (sealed).
    pub fn veil(&self, i: usize) -> Fx {
        self.veil[i]
    }

    /// Weakest point of the Veil anywhere on the planet.
    pub fn veil_min(&self) -> Fx {
        self.veil.iter().copied().min().unwrap_or(Fx::ONE)
    }

    pub fn veil_mean(&self) -> Fx {
        self.veil.iter().fold(Fx::ZERO, |a, &v| a + v) / Fx::from_int(REGION_COUNT as i64)
    }

    pub fn is_otherworldly(&self, species: u32) -> bool {
        self.species_by_id(species)
            .is_some_and(|s| s.has(body::OTHERWORLDLY))
    }

    /// Biomass of beings from beyond in a region.
    pub fn entity_biomass(&self, i: usize) -> Fx {
        self.regions[i]
            .populations
            .iter()
            .filter(|p| self.is_otherworldly(p.species))
            .fold(Fx::ZERO, |a, p| a + p.biomass)
    }

    /// Moves each region's Veil toward its target strength.
    pub(crate) fn update_veil(&mut self) {
        let thinning = self.veil_thinning();
        let cults = self.cult_thinning();
        for (i, cult) in cults.iter().enumerate() {
            // Fault lines: from 0.7× to 1.3× the planet-wide thinning.
            let local = thinning * (Fx::ratio(7, 10) + fault(self.seed, i) * Fx::ratio(6, 10))
                + self.law_thinning(i)
                + *cult;
            let held_open = if self.entity_biomass(i) > Fx::ZERO {
                Fx::ratio(1, 10)
            } else {
                Fx::ZERO
            };
            let target = (Fx::ONE - local - held_open).clamp(Fx::ZERO, Fx::ONE);
            let v = self.veil[i];
            self.veil[i] = v + (target - v) * Fx::ratio(2, 10);
        }
    }

    /// Where the Veil is thin, something may come through.
    pub(crate) fn breaches(&mut self) {
        let gaps: Vec<Fx> = self
            .veil
            .iter()
            .map(|&v| (BREACH_THRESHOLD - v).max(Fx::ZERO))
            .collect();
        let total = gaps.iter().fold(Fx::ZERO, |a, &g| a + g);
        if total == Fx::ZERO {
            return;
        }
        let chance = (total * Fx::ratio(2, 10000)).min(Fx::ratio(25, 100));
        if !self.rng.chance(chance) {
            return;
        }
        // Thinner regions are likelier breach points.
        let mut pick = self.rng.unit() * total;
        let mut region = 0;
        for (i, &g) in gaps.iter().enumerate() {
            if g == Fx::ZERO {
                continue;
            }
            region = i;
            if pick < g {
                break;
            }
            pick -= g;
        }
        self.last_breach_tick = Some(self.tick);
        let living: Vec<u32> = self
            .living_species()
            .filter(|s| s.has(body::OTHERWORLDLY))
            .map(|s| s.id)
            .collect();
        let id = if living.len() >= MAX_ENTITY_SPECIES {
            // Kin of something already here comes through.
            living[self.rng.below(living.len() as u64) as usize]
        } else {
            let genome = self.entity_genome(region);
            let profile = Profile {
                element: 0,
                medium: 0,
                energy: EnergyKind::Chemical,
            };
            self.add_species(profile, genome, None)
        };
        let pops = &mut self.regions[region].populations;
        match pops.iter_mut().find(|p| p.species == id) {
            Some(p) => p.biomass += Fx::from_int(2),
            None => pops.push(Population {
                species: id,
                biomass: Fx::from_int(2),
            }),
        }
    }

    /// A body and mind from beyond: eye clusters, tendrils, phase membranes
    /// and voids, at any size.
    fn entity_genome(&mut self, region: usize) -> Genome {
        let mut body = Body::default();
        body.grow(PartKind::Segment, 1 + self.rng.below(3) as u8, Fx::ONE, None);
        let eyes = 2 + self.rng.below(7) as u8;
        body.grow(PartKind::Eye, eyes, self.rng.range(Fx::ratio(3, 10), Fx::ratio(15, 10)), None);
        body.grow(
            PartKind::Brain,
            1,
            self.rng.range(Fx::ONE, Fx::from_int(3)),
            None,
        );
        body.grow(
            PartKind::Tendril,
            2 + self.rng.below(9) as u8,
            self.rng.range(Fx::ratio(5, 10), Fx::from_int(2)),
            None,
        );
        if self.rng.chance(Fx::ratio(6, 10)) {
            body.grow(PartKind::PhaseMembrane, 1, self.rng.range(Fx::ratio(5, 10), Fx::from_int(2)), None);
        }
        if self.rng.chance(Fx::ratio(4, 10)) {
            body.grow(PartKind::Void, 1, self.rng.range(Fx::ratio(5, 10), Fx::from_int(2)), None);
        }
        if self.rng.chance(Fx::ratio(3, 10)) {
            body.grow(PartKind::Jaw, 1 + self.rng.below(3) as u8, Fx::ONE, None);
        }
        // Size from a few kilograms to far beyond anything native.
        let size = self.rng.range(-Fx::ONE, Fx::ratio(53, 10)).exp2();
        Genome {
            size,
            temp_opt: self.regions[region].temperature,
            temp_tol: Fx::from_int(1000),
            fecundity: Fx::ratio(15, 100),
            metabolism: Fx::HALF,
            milestones: body::MULTICELLULAR | body::NERVOUS | body::OTHERWORLDLY,
            body,
            // An alien mind: random wiring, unrelated to any native brain.
            brain: Brain::random(&mut self.rng),
        }
    }

    /// Beings from beyond feed on minds, not chemistry. Called for each
    /// region after native population dynamics.
    pub(crate) fn entity_dynamics(&mut self) {
        for i in 0..REGION_COUNT {
            if !self.regions[i]
                .populations
                .iter()
                .any(|p| self.is_otherworldly(p.species))
            {
                continue;
            }
            let veil = self.veil[i];
            // Minds nearby: biomass of native species with nervous systems,
            // weighted by intelligence.
            let mut minds = Fx::ZERO;
            for p in &self.regions[i].populations {
                let s = &self.species[self.species_index(p.species)];
                if s.has(body::NERVOUS) && !s.has(body::OTHERWORLDLY) {
                    minds += p.biomass * (Fx::ONE + s.traits.intelligence * Fx::from_int(2));
                }
            }
            let open = Fx::ONE - veil;
            let capacity = minds * Fx::HALF + open * open * Fx::from_int(4);
            let mut drain = Fx::ZERO;
            let n = self.regions[i].populations.len();
            for k in 0..n {
                let p = self.regions[i].populations[k].clone();
                if !self.is_otherworldly(p.species) {
                    continue;
                }
                let s = &self.species[self.species_index(p.species)];
                let r = s.growth_rate();
                let b = p.biomass;
                // A strong Veil starves them of whatever sustains them.
                let fade = Fx::ratio(3, 100) + veil * veil * Fx::ratio(25, 100);
                let growth = if capacity > Fx::ZERO {
                    r * b * (Fx::ONE - b / capacity)
                } else {
                    Fx::ZERO
                };
                self.regions[i].populations[k].biomass = b + growth - b * fade;
                drain += b * Fx::ratio(1, 10) * s.hunting();
            }
            // The drain falls on minds in proportion to their share.
            if drain > Fx::ZERO && minds > Fx::ZERO {
                let share = (drain / minds).min(Fx::ratio(3, 10));
                for k in 0..n {
                    let id = self.regions[i].populations[k].species;
                    let s = &self.species[self.species_index(id)];
                    if s.has(body::NERVOUS) && !s.has(body::OTHERWORLDLY) {
                        let p = &mut self.regions[i].populations[k];
                        p.biomass -= p.biomass * share;
                    }
                }
            }
            self.regions[i]
                .populations
                .retain(|p| p.biomass > Fx::ratio(2, 100));
        }
    }

    /// Beings from beyond spread toward minds and thin places.
    pub(crate) fn entity_target(&self, j: usize) -> bool {
        self.veil[j] < Fx::ratio(8, 10)
            || self.regions[j].populations.iter().any(|p| {
                self.species_by_id(p.species)
                    .is_some_and(|s| s.has(body::NERVOUS) && !s.has(body::OTHERWORLDLY))
            })
    }

    /// Whether a being from beyond lives in a region or next to it.
    pub fn horror_near(&self, i: usize) -> bool {
        std::iter::once(i)
            .chain(neighbours(i))
            .any(|r| self.entity_biomass(r) > Fx::ZERO)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn faults_vary_and_are_deterministic() {
        let a: Vec<Fx> = (0..50).map(|i| fault(7, i)).collect();
        let b: Vec<Fx> = (0..50).map(|i| fault(7, i)).collect();
        assert_eq!(a, b);
        assert!(a.iter().any(|&f| f < Fx::ratio(3, 10)));
        assert!(a.iter().any(|&f| f > Fx::ratio(7, 10)));
    }
}
