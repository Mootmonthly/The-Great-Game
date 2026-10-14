//! Wire protocol between the game client and the arena server
//! (docs/GAME_DESIGN.md §6.2–6.3).
//!
//! Messages are JSON objects, one per line, over TCP. The client builds its
//! world offline; to play online it uploads the world's action log when it
//! binds a champion, and the server replays the log to verify the champion
//! (Option B). Matches run in lockstep: clients send only commands, the
//! server runs the authoritative arena and broadcasts each tick's commands,
//! and every client steps the same deterministic arena.

pub mod client;
pub mod tls;

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sim_core::arena::{ArenaCommand, ArenaResult};
use sim_core::sheet::CharacterSheet;
use sim_core::ActionLog;
use std::io::{self, BufRead, Read, Write};

/// Bumped whenever messages or simulation rules change incompatibly.
pub const PROTOCOL_VERSION: u32 = 2;
/// Default TCP port of the arena server.
pub const DEFAULT_PORT: u16 = 7878;
/// Longest accepted message line (world logs can be large).
pub const MAX_LINE: usize = 16 << 20;
/// The server sends a state hash this often, in arena ticks.
pub const HASH_INTERVAL: u64 = 50;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChampionKind {
    /// A typical member of a species: rank and file, can be bound again.
    Species,
    /// A named individual: dies forever (§6.2a).
    Individual,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QueueMode {
    /// Rated, with permadeath.
    Ranked,
    /// Unrated, nobody dies.
    Practice,
}

/// How a champion looks: enough for a client to build its 3D model.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Appearance {
    /// Species colour, hex RGB.
    pub color: String,
    pub parts: Vec<PartLook>,
    pub otherworldly: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartLook {
    /// Part name, e.g. "limb" or "tendril".
    pub part: String,
    pub count: u8,
    /// Relative size, in thousandths.
    pub size_milli: i64,
}

/// A verified champion. The server keeps the authoritative copy; clients
/// refer to it by `token`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChampionToken {
    pub token: u64,
    pub account: String,
    pub kind: ChampionKind,
    pub world_seed: u64,
    /// Species or individual id in its home world.
    pub id: u32,
    pub name: String,
    pub cost: i64,
    pub sheet: CharacterSheet,
    pub appearance: Appearance,
    /// Server signature (HMAC-SHA256, hex) over the token's contents.
    pub signature: String,
}

/// A champion that fell in a ranked match.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fallen {
    pub token: u64,
    pub account: String,
    pub kind: ChampionKind,
    pub world_seed: u64,
    pub id: u32,
    pub name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct RatingView {
    pub rating: f64,
    pub deviation: f64,
}

/// How a client proves who it is.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Auth {
    /// A server account: the first sign-in claims the name and the server
    /// issues a secret; later sign-ins must present it.
    Account { secret: Option<String> },
    /// A Steam session ticket (GetAuthTicketForWebApi), checked by the
    /// server with Steam.
    Steam { ticket: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMsg {
    Hello {
        /// Account name, or display name for Steam sign-ins.
        name: String,
        version: u32,
        auth: Auth,
    },
    /// Verify a champion from this world log.
    Bind {
        log: ActionLog,
        kind: ChampionKind,
        id: u32,
        /// The cost the client computed; must match the server's.
        cost: i64,
    },
    /// Join a queue with these bound champions under a cost cap.
    Queue {
        mode: QueueMode,
        cap: i64,
        champions: Vec<u64>,
    },
    LeaveQueue,
    /// A command for one of your units in the current match.
    Command {
        command: ArenaCommand,
    },
    Surrender,
    Ping,
}

// Match starts carry both rosters; they are rare, so the size is fine.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMsg {
    Welcome {
        account: String,
        /// A newly issued account secret: keep it to sign in again.
        secret: Option<String>,
        rating: RatingView,
        champions: Vec<ChampionToken>,
    },
    Bound {
        champion: ChampionToken,
    },
    /// A request failed; `request` names it.
    Rejected {
        request: String,
        reason: String,
    },
    Queued {
        mode: QueueMode,
        cap: i64,
        cost: i64,
    },
    LeftQueue,
    MatchStart {
        match_id: u64,
        seed: u64,
        mode: QueueMode,
        cap: i64,
        /// Which side you play: 0 or 1.
        team: u8,
        players: [String; 2],
        /// Both rosters, in unit order; tokens map units to champions.
        rosters: [Vec<CharacterSheet>; 2],
        looks: [Vec<Appearance>; 2],
        tokens: [Vec<u64>; 2],
    },
    /// Apply these commands, then step the arena once.
    Tick {
        tick: u64,
        commands: Vec<ArenaCommand>,
    },
    /// Server state hash after `tick` steps.
    Hash {
        tick: u64,
        hash: String,
    },
    MatchEnd {
        match_id: u64,
        result: ArenaResult,
        /// The side that surrendered, if any.
        surrendered: Option<u8>,
        /// Champions lost forever (ranked only).
        fallen: Vec<Fallen>,
        rating: Option<RatingView>,
        /// Server signature over the match record.
        signature: String,
    },
    Pong,
}

/// Writes one message as a JSON line.
pub fn write_msg<W: Write, T: Serialize>(w: &mut W, msg: &T) -> io::Result<()> {
    let mut line = serde_json::to_vec(msg).map_err(io::Error::other)?;
    line.push(b'\n');
    w.write_all(&line)?;
    w.flush()
}

/// Reads one JSON-line message. `Ok(None)` at end of stream.
pub fn read_msg<R: BufRead, T: DeserializeOwned>(r: &mut R) -> io::Result<Option<T>> {
    let mut line = Vec::new();
    let n = r.by_ref().take(MAX_LINE as u64 + 1).read_until(b'\n', &mut line)?;
    if n == 0 {
        return Ok(None);
    }
    if line.len() > MAX_LINE {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "message too long"));
    }
    serde_json::from_slice(&line)
        .map(Some)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sim_core::Fx;

    #[test]
    fn messages_round_trip() {
        let msgs = vec![
            ClientMsg::Hello {
                name: "a".into(),
                version: PROTOCOL_VERSION,
                auth: Auth::Account { secret: None },
            },
            ClientMsg::Command {
                command: ArenaCommand::Steer {
                    unit: 2,
                    x: Fx::ONE,
                    z: -Fx::HALF,
                },
            },
            ClientMsg::Surrender,
        ];
        let mut buf = Vec::new();
        for m in &msgs {
            write_msg(&mut buf, m).unwrap();
        }
        let mut r = io::Cursor::new(buf);
        for m in &msgs {
            let got: ClientMsg = read_msg(&mut r).unwrap().unwrap();
            assert_eq!(&got, m);
        }
        assert!(read_msg::<_, ClientMsg>(&mut r).unwrap().is_none());
    }
}
