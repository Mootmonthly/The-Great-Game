//! Loot (docs/GAME_DESIGN.md §6.2a): the bodies of champions who fall in a
//! ranked match go to the winner. Their remains arrive in the winner's world
//! as a small population of the fallen being's kind, with traces of the
//! chemistry it was made of, and may seed new life there.
//!
//! The arena server issues each grant with a signature. The simulation does
//! not check it (it has no key); the server does when it replays a world
//! log that contains loot (§6.2).

use crate::fixed::Fx;
use crate::life::{Genome, Profile};
use crate::world::{Population, World, REGION_COUNT, WIDTH};
use serde::{Deserialize, Serialize};

/// What is left of a fallen champion's kind.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Remains {
    pub name: String,
    pub profile: Profile,
    pub genome: Genome,
    pub color: [u8; 3],
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LootGrant {
    pub id: u64,
    /// The winner who may use it.
    pub account: String,
    /// The fallen champion's name.
    pub from: String,
    pub remains: Remains,
    /// Biomass of the population it seeds.
    pub biomass: Fx,
    /// Pseudo-cost: the fallen champion's cost. Selling the spoil back to
    /// the server pays this much Essence (§3).
    #[serde(default)]
    pub value: u64,
    /// The gear it carried, for the winner's armoury (§5.4).
    #[serde(default)]
    pub gear: Vec<crate::equipment::Item>,
    /// Server signature (hex) over the grant with this field empty.
    pub signature: String,
}

impl LootGrant {
    /// The bytes the server signs.
    pub fn payload(&self) -> Vec<u8> {
        let mut unsigned = self.clone();
        unsigned.signature.clear();
        serde_json::to_vec(&unsigned).expect("grants serialise")
    }
}

impl World {
    /// The region where a lineage with this biochemistry would do best.
    pub fn best_region_for(&self, profile: &Profile) -> (u16, u16) {
        let best = (0..REGION_COUNT)
            .max_by_key(|&i| (self.region_life(i).fit(profile), std::cmp::Reverse(i)))
            .unwrap_or(0);
        ((best % WIDTH) as u16, (best / WIDTH) as u16)
    }

    pub(crate) fn apply_loot(&mut self, grant: &LootGrant, x: u16, y: u16) {
        let r = &grant.remains;
        let substances = self.substances.len();
        let elements = self.elements.len();
        if r.profile.medium as usize >= substances || r.profile.element as usize >= elements {
            return;
        }
        let i = crate::world::index(
            (x as usize).min(WIDTH - 1),
            (y as usize).min(crate::world::HEIGHT - 1),
        );
        // Traces of what it was made of: its medium and backbone.
        self.regions[i].amounts[r.profile.medium as usize] += Fx::HALF;
        let element = &self.elements[r.profile.element as usize];
        if let Some(s) = self
            .substances
            .iter()
            .position(|s| &s.backbone_element == element)
        {
            self.regions[i].amounts[s] += Fx::HALF;
        }
        // Its kind, carried home.
        let id = self.add_species(r.profile, r.genome.clone(), None);
        let k = self.species.len() - 1;
        self.species[k].name = format!("{} (from beyond the arena)", r.name);
        self.species[k].color = r.color;
        let biomass = grant.biomass.clamp(Fx::ratio(1, 10), Fx::from_int(20));
        self.regions[i].populations.push(Population {
            species: id,
            biomass,
        });
        // Its gear, made for its body.
        let plan = crate::equipment::BodyPlan::of(&r.genome.body, r.genome.size, r.genome.milestones);
        self.store_loot(&grant.gear, &grant.from, plan);
    }
}
