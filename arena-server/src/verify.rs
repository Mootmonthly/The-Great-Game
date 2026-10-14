//! Champion verification by replay (Option B, docs/GAME_DESIGN.md §6.2).
//!
//! The client uploads its world's seed and action log. The server replays
//! it headless and rebuilds the champion's character sheet itself, so a
//! client cannot invent or edit a champion.

use net_proto::client::appearance;
use net_proto::{Appearance, ChampionKind};
use sha2::{Digest, Sha256};
use crate::sign::Signer;
use sim_core::loot::Remains;
use sim_core::sheet::{individual_sheet, species_sheet, CharacterSheet};
use sim_core::{Action, ActionLog, World};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

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
    /// Actions skipped by resuming from a checkpoint (0 = full replay).
    pub resumed_from: usize,
    pub remains: Remains,
    /// Loot grants used in this world's history.
    pub loot: Vec<u64>,
}

/// Checks every loot grant in the log: signed by this server, granted to
/// this account, and used once.
pub fn check_loot(signer: &Signer, account: &str, log: &ActionLog) -> Result<Vec<u64>, String> {
    let mut ids = Vec::new();
    for a in &log.actions {
        if let Action::Loot { grant, .. } = a {
            if !signer.verify(&grant.payload(), &grant.signature) {
                return Err("the world contains loot this server never granted".into());
            }
            if grant.account != account {
                return Err("the world contains another player's loot".into());
            }
            if ids.contains(&grant.id) {
                return Err("the world uses the same loot twice".into());
            }
            ids.push(grant.id);
        }
    }
    Ok(ids)
}

/// Hash of the first `n` actions of a log.
fn prefix_hash(log: &ActionLog, n: usize) -> String {
    let mut h = Sha256::new();
    h.update(log.seed.to_le_bytes());
    for a in &log.actions[..n] {
        h.update(serde_json::to_vec(a).expect("actions serialise"));
        h.update(b"\n");
    }
    crate::sign::hex(&h.finalize())
}

struct Checkpoint {
    actions: usize,
    prefix: String,
    /// In memory, or `None` when it lives on disk.
    snapshot: Option<Vec<u8>>,
}

/// The last verified state of each player's worlds (§6.2: "the next
/// verification replays only from the last checkpoint"). A bind whose log
/// extends a checkpointed log resumes from the snapshot instead of
/// replaying the whole history. Snapshots never leave the server, so they
/// need no signature.
pub struct Checkpoints {
    dir: Option<PathBuf>,
    index: Mutex<HashMap<(String, u64), Checkpoint>>,
}

impl Checkpoints {
    pub fn new(dir: Option<PathBuf>) -> Checkpoints {
        if let Some(d) = &dir {
            let _ = std::fs::create_dir_all(d);
        }
        Checkpoints {
            dir,
            index: Mutex::new(HashMap::new()),
        }
    }

    fn path(&self, account: &str, seed: u64) -> Option<PathBuf> {
        self.dir
            .as_ref()
            .map(|d| d.join(format!("{account}-{seed}.json")))
    }

    /// A world resumed from the best checkpoint for this log, if any.
    fn resume(&self, account: &str, log: &ActionLog) -> Option<(World, usize)> {
        let key = (account.to_string(), log.seed);
        let (n, prefix, in_memory) = {
            let index = self.index.lock().unwrap();
            let c = index.get(&key)?;
            (c.actions, c.prefix.clone(), c.snapshot.clone())
        };
        // The log merges consecutive ticks, so the checkpoint's last tick
        // may have grown since: compare everything before it, then check
        // the last action is the same or a longer tick.
        if n == 0 || n > log.actions.len() || prefix_hash(log, n - 1) != prefix {
            return None;
        }
        let bytes = match in_memory {
            Some(b) => b,
            None => std::fs::read(self.path(account, log.seed)?).ok()?,
        };
        let mut world = World::from_snapshot(&bytes).ok()?;
        if world.log().actions.len() != n {
            return None;
        }
        let saved = world.log().actions[n - 1].clone();
        match (&saved, &log.actions[n - 1]) {
            (a, b) if a == b => {}
            (Action::Tick { ticks: a }, Action::Tick { ticks: b }) if b > a => {
                world.apply(Action::Tick { ticks: b - a });
            }
            _ => return None,
        }
        Some((world, n))
    }

    fn store(&self, account: &str, world: &World) {
        let log = world.log();
        let bytes = world.snapshot();
        let mut snapshot = Some(bytes);
        if let Some(path) = self.path(account, log.seed) {
            if std::fs::write(&path, snapshot.as_ref().unwrap()).is_ok() {
                snapshot = None;
            }
        }
        self.index.lock().unwrap().insert(
            (account.to_string(), log.seed),
            Checkpoint {
                actions: log.actions.len(),
                prefix: prefix_hash(log, log.actions.len().saturating_sub(1)),
                snapshot,
            },
        );
    }
}

/// Verifies with no checkpoints (a full replay) and no loot.
pub fn verify(log: &ActionLog, kind: ChampionKind, id: u32, cost: i64) -> Result<Verified, String> {
    verify_with(None, &Signer::random(), "", log, kind, id, cost)
}

pub fn verify_with(
    checkpoints: Option<&Checkpoints>,
    signer: &Signer,
    account: &str,
    log: &ActionLog,
    kind: ChampionKind,
    id: u32,
    cost: i64,
) -> Result<Verified, String> {
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
    let loot = check_loot(signer, account, log)?;
    let (world, resumed_from) = match checkpoints.and_then(|c| c.resume(account, log)) {
        Some((mut world, n)) => {
            for a in &log.actions[n..] {
                world.apply(a.clone());
            }
            (world, n)
        }
        None => (World::replay(log), 0),
    };
    if let Some(c) = checkpoints {
        c.store(account, &world);
    }
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
    let species_id = match kind {
        ChampionKind::Species => id,
        ChampionKind::Individual => world.individual_by_id(id).map_or(0, |i| i.species),
    };
    let s = world.species_by_id(species_id).ok_or("being has no species")?;
    let remains = Remains {
        name: s.name.clone(),
        profile: s.profile,
        genome: s.genome.clone(),
        color: s.color,
    };
    Ok(Verified {
        name,
        sheet,
        appearance,
        fingerprint,
        resumed_from,
        remains,
        loot,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use sim_core::presets::preset_actions;

    #[test]
    fn checkpoints_resume_and_agree_with_full_replays() {
        let mut w = World::new(1);
        for a in preset_actions(&w, "frozen_moon").unwrap() {
            w.apply(a);
        }
        w.apply(Action::Tick { ticks: 800 });
        let cps = Checkpoints::new(None);
        let signer = Signer::random();
        let id = w.living_individuals().next().expect("individuals").id;
        let cost = |w: &World| individual_sheet(w, w.individual_by_id(id).unwrap()).unwrap().cost.cost;
        let first = verify_with(Some(&cps), &signer, "ann", w.log(), ChampionKind::Individual, id, cost(&w)).unwrap();
        assert_eq!(first.resumed_from, 0);

        // The world goes on; the next bind resumes from the checkpoint.
        w.apply(Action::Tick { ticks: 8 });
        let Some(id2) = w.living_individuals().map(|i| i.id).next() else {
            return;
        };
        let c2 = individual_sheet(&w, w.individual_by_id(id2).unwrap()).unwrap().cost.cost;
        let resumed = verify_with(Some(&cps), &signer, "ann", w.log(), ChampionKind::Individual, id2, c2).unwrap();
        assert!(resumed.resumed_from > 0);
        let full = verify(w.log(), ChampionKind::Individual, id2, c2).unwrap();
        assert_eq!(resumed.sheet, full.sheet);

        // A different history (an edit in the past) cannot use it.
        let mut forked = w.log().clone();
        forked.actions.insert(1, Action::SetGlobalHeat { kelvin: sim_core::Fx::ONE });
        let r = verify_with(Some(&cps), &signer, "ann", &forked, ChampionKind::Species, 1, 0);
        assert!(r.map_or(true, |v| v.resumed_from == 0));
        // Nor another account.
        let other = verify_with(Some(&cps), &signer, "bob", w.log(), ChampionKind::Individual, id2, c2).unwrap();
        assert_eq!(other.resumed_from, 0);
    }
}
