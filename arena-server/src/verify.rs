//! Champion verification by replay (Option B, docs/GAME_DESIGN.md §6.2).
//!
//! The client uploads its world's seed and action log. The server replays
//! it headless and rebuilds the champion's character sheet itself, so a
//! client cannot invent or edit a champion.

use net_proto::client::appearance;
use net_proto::{Appearance, ChampionKind};
use sim_core::sheet::{individual_sheet, species_sheet, CharacterSheet};
use sim_core::{Action, ActionLog, World};

/// Largest accepted log, in actions.
pub const MAX_ACTIONS: usize = 200_000;
/// Longest accepted history, in seasons (10,000 years). Bounds the CPU a
/// single verification can cost: about 4 minutes of one core at worst.
pub const MAX_TICKS: u64 = 40_000;

pub struct Verified {
    pub name: String,
    pub sheet: CharacterSheet,
    pub appearance: Appearance,
    /// Individuals only: identity for the ledger of the dead.
    pub fingerprint: Option<u64>,
}

pub fn verify(log: &ActionLog, kind: ChampionKind, id: u32, cost: i64) -> Result<Verified, String> {
    if log.actions.len() > MAX_ACTIONS {
        return Err(format!("world log too long (over {MAX_ACTIONS} actions)"));
    }
    let ticks: u64 = log
        .actions
        .iter()
        .map(|a| match a {
            Action::Tick { ticks } => *ticks as u64,
            _ => 0,
        })
        .sum();
    if ticks > MAX_TICKS {
        return Err(format!("world history too long (over {} years)", MAX_TICKS / 4));
    }
    let world = World::replay(log);
    let (name, sheet, fingerprint) = match kind {
        ChampionKind::Species => {
            let s = world
                .species_by_id(id)
                .filter(|s| s.is_alive())
                .ok_or("no such living species in this world")?;
            (s.name.clone(), species_sheet(&world, s), None)
        }
        ChampionKind::Individual => {
            let ind = world
                .individual_by_id(id)
                .filter(|x| x.is_alive())
                .ok_or("no such living individual in this world")?;
            let sheet = individual_sheet(&world, ind).ok_or("individual has no species")?;
            (ind.title(), sheet, Some(ind.fingerprint(world.seed)))
        }
    };
    if sheet.cost.cost != cost {
        return Err(format!(
            "cost mismatch: client says {cost}, replay gives {}",
            sheet.cost.cost
        ));
    }
    let appearance = appearance(&world, kind, id).ok_or("being has no species")?;
    Ok(Verified {
        name,
        sheet,
        appearance,
        fingerprint,
    })
}
