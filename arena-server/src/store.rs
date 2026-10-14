//! Persistent server state: accounts, ratings, bound champions and the
//! ledger of the dead. Saved as one JSON file; written atomically.

use crate::glicko::Rating;
use net_proto::ChampionToken;
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
    /// Bound champions by token.
    pub champions: BTreeMap<u64, Champion>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Champion {
    pub token: ChampionToken,
    /// Individuals only: identity in the ledger of the dead.
    pub fingerprint: Option<u64>,
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
