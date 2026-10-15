//! Religions and cults (docs/GAME_DESIGN.md §4.8 level 6, §4.4a).
//!
//! Peoples explain what they cannot account for. The player's god tools
//! are real events they can witness: a people that sees enough of them
//! comes to worship their maker, as a giver if the acts helped and a
//! wrathful power if they harmed, each culture reading the same acts its
//! own way. Peoples that see no miracles find gods in their own world:
//! the sky, their ancestors (under Soul Power), the mana of the ley lines
//! (under Arcane Magic), the flow of qi (under Cultivation). Near beings
//! from beyond the Veil, cults form and call them closer.
//!
//! Faiths spread to friendly neighbours. A shared faith warms relations
//! and binds a people together; rival faiths sour them; wrathful faiths
//! go to war more readily; cults thin the Veil where they gather.

use crate::civ::distance;
use crate::fixed::Fx;
use crate::world::{World, TICKS_PER_YEAR};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Deity {
    /// The player, seen through their works.
    Maker,
    Sky,
    Ancestors,
    Mana,
    Qi,
    /// A being from beyond the Veil.
    Beyond,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Character {
    /// Worships a giver: calmer, more open.
    Benevolent,
    /// Fears and appeases: readier for war.
    Wrathful,
    /// A cult around something from beyond.
    Cult,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Religion {
    pub id: u32,
    pub name: String,
    pub deity: Deity,
    pub character: Character,
    /// The people that first held it.
    pub founder: u32,
    pub founded_tick: u64,
}

impl Religion {
    pub fn describe(&self) -> String {
        let god = match self.deity {
            Deity::Maker => "the Maker of the world",
            Deity::Sky => "the sky and its lights",
            Deity::Ancestors => "the ancestors",
            Deity::Mana => "the spirits of the ley lines",
            Deity::Qi => "the flow of qi",
            Deity::Beyond => "a being from beyond the Veil",
        };
        let how = match self.character {
            Character::Benevolent => "a giving faith",
            Character::Wrathful => "a fearful faith",
            Character::Cult => "a cult",
        };
        format!("{how} of {god}")
    }
}

/// Awe or dread a people needs to found a faith in the Maker.
const REVELATION: Fx = Fx::ONE;

impl World {
    pub fn religion(&self, id: u32) -> Option<&Religion> {
        self.religions.iter().find(|r| r.id == id)
    }

    /// A player tool touched these regions (all of them if `None`): living
    /// peoples settled there witness it. `help` is how much it helped
    /// (negative if it harmed).
    pub(crate) fn witness(&mut self, regions: Option<&[usize]>, help: Fx) {
        for c in self.civs.iter_mut().filter(|c| c.is_alive()) {
            let saw = match regions {
                None => true,
                Some(rs) => c.settlements.iter().any(|s| rs.contains(&s.region)),
            };
            if !saw {
                continue;
            }
            // Cautious peoples fear what they see; open ones marvel.
            let fear = Fx::ratio(5, 10) + c.culture.caution - c.culture.openness * Fx::HALF;
            if help >= Fx::ZERO {
                c.awe += help * (Fx::ONE - fear * Fx::HALF).max(Fx::ratio(2, 10));
                c.dread += help * fear * Fx::ratio(2, 10);
            } else {
                c.dread += -help * (Fx::ONE + fear * Fx::HALF);
            }
        }
    }

    /// Once a year: faiths are founded, spread and fade.
    pub(crate) fn update_religions(&mut self) {
        if !self.tick.is_multiple_of(TICKS_PER_YEAR) {
            return;
        }
        let living: Vec<usize> = (0..self.civs.len()).filter(|&k| self.civs[k].is_alive()).collect();
        for &k in &living {
            // Cults: a being from beyond within 3 regions of a settlement.
            let near_beyond = self.civs[k].settlements.iter().any(|s| {
                (0..self.regions.len()).any(|r| distance(r, s.region) <= 3 && self.entity_biomass(r) > Fx::ZERO)
            });
            let in_cult = self.civs[k].faith.and_then(|f| self.religion(f)).is_some_and(|r| r.character == Character::Cult);
            if near_beyond && !in_cult && self.rng.chance(Fx::ratio(1, 10)) {
                self.found_religion(k, Deity::Beyond, Character::Cult);
                continue;
            }
            if self.civs[k].faith.is_some() {
                continue;
            }
            let (awe, dread) = (self.civs[k].awe, self.civs[k].dread);
            if awe + dread >= REVELATION {
                let character = if awe >= dread { Character::Benevolent } else { Character::Wrathful };
                self.found_religion(k, Deity::Maker, character);
            } else if self.era(&self.civs[k]) >= 1 && self.rng.chance(Fx::ratio(5, 100)) {
                // A faith of their own world, shaped by its laws.
                let deity = if self.laws.soul > Fx::ratio(3, 10) {
                    Deity::Ancestors
                } else if self.laws.arcane > Fx::ratio(3, 10) {
                    Deity::Mana
                } else if self.laws.qi > Fx::ratio(3, 10) {
                    Deity::Qi
                } else {
                    Deity::Sky
                };
                let character = if self.civs[k].culture.caution > Fx::ratio(6, 10) {
                    Character::Wrathful
                } else {
                    Character::Benevolent
                };
                self.found_religion(k, deity, character);
            }
        }
        // Faiths spread to faithless or wavering neighbours who think well
        // of the believers.
        for &a in &living {
            let Some(faith) = self.civs[a].faith else { continue };
            for &b in &living {
                if a == b || self.civs[b].faith == Some(faith) {
                    continue;
                }
                let near = self.civs[a].settlements.iter().any(|x| self.civs[b].settlements.iter().any(|y| distance(x.region, y.region) <= 3));
                let friendly = self.civs[b].relations.iter().any(|r| r.other == self.civs[a].id && r.opinion > Fx::ZERO);
                let chance = if self.civs[b].faith.is_none() { Fx::ratio(10, 100) } else { Fx::ratio(2, 100) };
                if near && friendly && self.rng.chance(chance) {
                    self.civs[b].faith = Some(faith);
                }
            }
        }
        // Awe and dread fade without new signs.
        for &k in &living {
            let c = &mut self.civs[k];
            c.awe = c.awe * Fx::ratio(95, 100);
            c.dread = c.dread * Fx::ratio(95, 100);
        }
    }

    fn found_religion(&mut self, k: usize, deity: Deity, character: Character) {
        self.next_religion_id += 1;
        let id = self.next_religion_id;
        let root = self.new_name();
        let name = match (deity, character) {
            (_, Character::Cult) => format!("Cult of {root}"),
            (Deity::Maker, Character::Benevolent) => format!("Children of {root}"),
            (Deity::Maker, _) => format!("Supplicants of {root}"),
            (Deity::Ancestors, _) => format!("Way of the {root} Elders"),
            (Deity::Mana, _) => format!("{root} Mysteries"),
            (Deity::Qi, _) => format!("{root} Path"),
            _ => format!("{root} Faith"),
        };
        self.religions.push(Religion {
            id,
            name,
            deity,
            character,
            founder: self.civs[k].id,
            founded_tick: self.tick,
        });
        self.civs[k].faith = Some(id);
    }

    /// The character of a people's faith, if it has one.
    pub(crate) fn faith_character(&self, k: usize) -> Option<Character> {
        self.civs[k].faith.and_then(|f| self.religion(f)).map(|r| r.character)
    }

    /// Extra Veil thinning where cultists live (§4.4a: worship can call
    /// things in).
    pub(crate) fn cult_thinning(&self) -> Vec<Fx> {
        let mut out = vec![Fx::ZERO; self.regions.len()];
        for (k, c) in self.civs.iter().enumerate().filter(|(_, c)| c.is_alive()) {
            if self.faith_character(k) == Some(Character::Cult) {
                for s in &c.settlements {
                    out[s.region] = Fx::ratio(2, 10);
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::body;
    use crate::presets::preset_actions;
    use crate::world::Population;
    use crate::{Action, World};

    fn civ_world() -> World {
        let mut w = World::new(1);
        for a in preset_actions(&w, "frozen_moon").unwrap() {
            w.apply(a);
        }
        w.apply(Action::Tick { ticks: 3200 });
        w
    }

    #[test]
    fn beings_from_beyond_gather_cults() {
        let mut w = civ_world();
        let k = w.civs.iter().position(|c| c.is_alive()).expect("a people");
        let capital = w.civs[k].settlements[0].region;
        // A being from beyond settles beside the capital.
        let base = w.living_species().next().unwrap().clone();
        let mut genome = base.genome.clone();
        genome.milestones |= body::OTHERWORLDLY;
        let id = w.add_species(base.profile, genome, None);
        w.regions[capital].populations.push(Population { species: id, biomass: Fx::from_int(5) });
        let veil_before = w.veil[capital];
        for _ in 0..60 {
            w.apply(Action::Tick { ticks: TICKS_PER_YEAR as u32 });
            if w.faith_character(k) == Some(Character::Cult) {
                break;
            }
            // Keep it there: the test is about the cult, not the being.
            if !w.regions[capital].populations.iter().any(|p| p.species == id) {
                w.regions[capital].populations.push(Population { species: id, biomass: Fx::from_int(5) });
            }
        }
        assert_eq!(w.faith_character(k), Some(Character::Cult), "a cult forms");
        let r = w.religion(w.civs[k].faith.unwrap()).unwrap();
        assert_eq!(r.deity, Deity::Beyond);
        assert!(r.name.starts_with("Cult of"));
        assert!(w.cult_thinning()[capital] > Fx::ZERO, "cultists thin the Veil");
        let _ = veil_before;
    }
}
