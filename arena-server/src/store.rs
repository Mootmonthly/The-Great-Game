//! Persistent server state: accounts, ratings, bound champions and the
//! ledger of the dead. Saved as one JSON file; written atomically.

use crate::glicko::Rating;
use net_proto::ChampionToken;
use sim_core::loot::Remains;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Account {
    /// SHA-256 of the account secret (server accounts only).
    #[serde(default)]
    pub secret_hash: Option<String>,
    pub rating: Rating,
    pub wins: u32,
    pub losses: u32,
    pub draws: u32,
    /// Essence, earned by defeating players.
    #[serde(default)]
    pub essence: u64,
    /// Bound champions by token.
    pub champions: BTreeMap<u64, Champion>,
    /// Extra home worlds bought with Essence (one world is free).
    #[serde(default)]
    pub extra_planets: u8,
    /// Seeds of the home worlds champions have been bound from.
    #[serde(default)]
    pub worlds: Vec<u64>,
    /// Spoils of war not yet brought home or sold: grant id → value.
    #[serde(default)]
    pub spoils: BTreeMap<u64, u64>,
}

impl Account {
    /// How many home worlds this account may bind champions from.
    pub fn planet_slots(&self) -> u8 {
        self.extra_planets.saturating_add(1)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Champion {
    pub token: ChampionToken,
    /// Individuals only: identity in the ledger of the dead.
    pub fingerprint: Option<u64>,
    /// What the winner loots if this champion falls.
    #[serde(default)]
    pub remains: Option<Remains>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Store {
    pub accounts: BTreeMap<String, Account>,
    /// Fingerprints of named individuals that died in ranked matches. They
    /// can never be bound again, from any account or any replay of their
    /// world (§6.2a).
    pub dead: BTreeSet<u64>,
    pub next_token: u64,
    pub next_match: u64,
    #[serde(default)]
    pub next_grant: u64,
    /// Loot grants already brought into a world: grant id → world seed. A
    /// grant enriches one world only.
    #[serde(default)]
    pub redeemed: BTreeMap<u64, u64>,
    /// Loot grants sold back to the server: deleted, never to enter a world.
    #[serde(default)]
    pub sold: BTreeSet<u64>,
    /// Shop grants already used in a world: grant id → world seed.
    #[serde(default)]
    pub purchases_used: BTreeMap<u64, u64>,
}

impl Store {
    pub fn load(path: &Path) -> std::io::Result<Store> {
        match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Store::default()),
            Err(e) => Err(e),
        }
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?)?;
        std::fs::rename(tmp, path)
    }

    pub fn account(&mut self, name: &str) -> &mut Account {
        self.accounts.entry(name.to_string()).or_default()
    }
}
