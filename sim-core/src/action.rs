//! Player actions.
//!
//! A world is fully described by its seed plus the ordered list of actions the
//! player took. Saving a world means saving that list; the server verifies a
//! champion by replaying it (docs/GAME_DESIGN.md §6.2). Every value is stored
//! as fixed-point raw bits, never as a float.

use crate::fixed::Fx;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Action {
    /// Advance the simulation by `ticks` seasons.
    Tick { ticks: u32 },
    /// Add `amount` units of a substance to every region within `radius`.
    AddSubstance {
        x: u16,
        y: u16,
        radius: u8,
        substance: u16,
        amount: Fx,
    },
    /// Add `amount` units of a substance to every region of the planet.
    AddSubstanceGlobal { substance: u16, amount: Fx },
    /// Change local temperature by `delta` kelvin within `radius`.
    HeatRegion {
        x: u16,
        y: u16,
        radius: u8,
        delta: Fx,
    },
    /// Planet-wide temperature offset in kelvin.
    SetGlobalHeat { kelvin: Fx },
    /// Distance from the star in astronomical units.
    SetStarDistance { au: Fx },
    /// Star luminosity relative to the Sun.
    SetStarLuminosity { suns: Fx },
    /// Surface gravity relative to Earth.
    SetGravity { g: Fx },
    /// Length of a day in hours.
    SetDayLength { hours: Fx },
    /// Axial tilt in degrees (0–90).
    SetAxialTilt { degrees: Fx },
    /// Adds a moon: mass in lunar masses, distance in Earth–Moon distances.
    AddMoon { mass: Fx, distance: Fx },
    /// Removes the moon at `index` (moons are sorted by distance).
    RemoveMoon { index: u8 },
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionLog {
    pub seed: u64,
    pub actions: Vec<Action>,
}

impl ActionLog {
    pub fn new(seed: u64) -> ActionLog {
        ActionLog {
            seed,
            actions: Vec::new(),
        }
    }

    /// Appends an action, merging consecutive ticks so long play sessions
    /// produce small logs.
    pub fn push(&mut self, action: Action) {
        if let (Some(Action::Tick { ticks: prev }), Action::Tick { ticks }) =
            (self.actions.last_mut(), &action)
        {
            if let Some(sum) = prev.checked_add(*ticks) {
                *prev = sum;
                return;
            }
        }
        self.actions.push(action);
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("action log serialises")
    }

    pub fn from_json(json: &str) -> Result<ActionLog, String> {
        serde_json::from_str(json).map_err(|e| e.to_string())
    }
}
