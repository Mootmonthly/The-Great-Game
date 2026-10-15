//! A blocking client for the arena server, used by the bot, tests and the
//! Godot extension. It mirrors each match locally: the server sends every
//! tick's commands, and `LockstepMatch` steps an identical arena.

use crate::{read_msg, write_msg, Appearance, Auth, ChampionKind, PartLook, ChampionToken, ClientMsg, QueueMode, ServerMsg};
use sim_core::arena::{Arena, ArenaEvent};
use sim_core::sheet::{individual_sheet, species_sheet, CharacterSheet};
use sim_core::World;
use crate::tls::{self, TlsReader, TlsWriter};
use std::io::{self, BufReader};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};

pub struct Client {
    reader: BufReader<TlsReader>,
    writer: TlsWriter,
    fingerprint: Arc<Mutex<Option<String>>>,
}

fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::UnexpectedEof, "server closed the connection")
}

/// The cost and sheet a client computes for one of its own beings.
pub fn local_sheet(world: &World, kind: ChampionKind, id: u32) -> Option<CharacterSheet> {
    match kind {
        ChampionKind::Species => world.species_by_id(id).map(|s| species_sheet(world, s)),
        ChampionKind::Individual => world
            .individual_by_id(id)
            .and_then(|i| individual_sheet(world, i)),
    }
}

/// What a being looks like, from its species' body.
pub fn appearance(world: &World, kind: ChampionKind, id: u32) -> Option<Appearance> {
    let species = match kind {
        ChampionKind::Species => world.species_by_id(id)?,
        ChampionKind::Individual => world.species_by_id(world.individual_by_id(id)?.species)?,
    };
    let c = species.color;
    Some(Appearance {
        color: format!("{:02x}{:02x}{:02x}", c[0], c[1], c[2]),
        parts: species
            .genome
            .body
            .parts
            .iter()
            .map(|p| PartLook {
                part: p.kind.name().to_string(),
                count: p.count,
                size_milli: (p.size * sim_core::Fx::from_int(1000)).round(),
            })
            .collect(),
        otherworldly: species.has(sim_core::body::OTHERWORLDLY),
    })
}

/// Where and how to sign in.
#[derive(Clone, Debug)]
pub struct Login {
    pub host: String,
    pub port: u16,
    pub name: String,
    pub auth: Auth,
    /// Pinned certificate fingerprint for this server, if known.
    pub pin: Option<String>,
}

impl Login {
    /// A server account on `host:port`, first sign-in (no secret yet).
    pub fn new(host: &str, port: u16, name: &str) -> Login {
        Login {
            host: host.into(),
            port,
            name: name.into(),
            auth: Auth::Account { secret: None },
            pin: None,
        }
    }
}

impl Client {
    /// Connects over TLS and signs in. Returns the client and the server's
    /// welcome (or refusal).
    pub fn connect(login: &Login) -> io::Result<(Client, ServerMsg)> {
        let addr = (login.host.as_str(), login.port)
            .to_socket_addrs()?
            .next()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "unknown host"))?;
        let tcp = TcpStream::connect_timeout(&addr, std::time::Duration::from_secs(10))?;
        let tls = tls::connect(tcp, &login.host, login.pin.clone())?;
        let mut c = Client {
            reader: BufReader::new(tls.reader),
            writer: tls.writer,
            fingerprint: tls.seen,
        };
        c.send(&ClientMsg::Hello {
            name: login.name.clone(),
            version: crate::PROTOCOL_VERSION,
            auth: login.auth.clone(),
        })?;
        let welcome = c.recv()?;
        Ok((c, welcome))
    }

    /// The server certificate fingerprint seen during the handshake.
    pub fn fingerprint(&self) -> Option<String> {
        self.fingerprint.lock().unwrap().clone()
    }

    pub fn send(&mut self, msg: &ClientMsg) -> io::Result<()> {
        write_msg(&mut self.writer, msg)
    }

    pub fn recv(&mut self) -> io::Result<ServerMsg> {
        read_msg(&mut self.reader)?.ok_or_else(closed)
    }

    /// Binds a champion from `world`. `Ok(Err(reason))` if the server
    /// refused it.
    pub fn bind(
        &mut self,
        world: &World,
        kind: ChampionKind,
        id: u32,
    ) -> io::Result<Result<ChampionToken, String>> {
        self.bind_from(world, None, kind, id)
    }

    /// Binds a champion from moon `moon` of `world` (or the planet itself).
    pub fn bind_from(
        &mut self,
        world: &World,
        moon: Option<u8>,
        kind: ChampionKind,
        id: u32,
    ) -> io::Result<Result<ChampionToken, String>> {
        let home = match moon {
            Some(k) => world.moon(k as usize),
            None => Some(world),
        };
        let Some(sheet) = home.and_then(|w| local_sheet(w, kind, id)) else {
            return Ok(Err("no such being".into()));
        };
        self.send(&ClientMsg::Bind {
            log: world.log().clone(),
            moon,
            kind,
            id,
            cost: sheet.cost.cost,
        })?;
        loop {
            match self.recv()? {
                ServerMsg::Bound { champion } => return Ok(Ok(champion)),
                ServerMsg::Rejected { reason, .. } => return Ok(Err(reason)),
                _ => continue,
            }
        }
    }

    /// Buys from the Essence shop. Returns `Purchased` or `Rejected`.
    pub fn buy(&mut self, item: sim_core::shop::ShopItem) -> io::Result<ServerMsg> {
        self.send(&ClientMsg::Buy { item })?;
        self.reply_to("buy")
    }

    /// Sells a spoil of war back to the server. Returns `Sold` or
    /// `Rejected`.
    pub fn sell_loot(&mut self, grant: u64) -> io::Result<ServerMsg> {
        self.send(&ClientMsg::SellLoot { grant })?;
        self.reply_to("sell_loot")
    }

    fn reply_to(&mut self, request: &str) -> io::Result<ServerMsg> {
        loop {
            match self.recv()? {
                m @ (ServerMsg::Purchased { .. } | ServerMsg::Sold { .. }) => return Ok(m),
                m @ ServerMsg::Rejected { .. } if matches!(&m, ServerMsg::Rejected { request: r, .. } if r == request) => {
                    return Ok(m)
                }
                _ => continue,
            }
        }
    }

    pub fn queue(&mut self, mode: QueueMode, cap: i64, champions: Vec<u64>) -> io::Result<()> {
        self.send(&ClientMsg::Queue {
            mode,
            cap,
            champions,
        })
    }

    /// Waits for the next match to start.
    pub fn wait_for_match(&mut self) -> io::Result<Result<LockstepMatch, String>> {
        loop {
            match self.recv()? {
                msg @ ServerMsg::MatchStart { .. } => {
                    return Ok(Ok(LockstepMatch::new(&msg).expect("a match start")))
                }
                ServerMsg::Rejected { reason, .. } => return Ok(Err(reason)),
                _ => continue,
            }
        }
    }

    /// Follows a match to its end without giving commands (the arena AI
    /// fights for us). Returns the final message.
    pub fn follow(&mut self, m: &mut LockstepMatch) -> io::Result<ServerMsg> {
        loop {
            let msg = self.recv()?;
            if m.handle(&msg) {
                return Ok(msg);
            }
        }
    }
}

/// A client's copy of a running match, kept in lockstep with the server.
pub struct LockstepMatch {
    pub match_id: u64,
    pub team: u8,
    pub mode: QueueMode,
    pub players: [String; 2],
    pub tokens: [Vec<u64>; 2],
    pub arena: Arena,
    /// Set if a server hash ever disagreed with ours.
    pub desynced: bool,
    pub events: Vec<ArenaEvent>,
    pub end: Option<ServerMsg>,
}

impl LockstepMatch {
    pub fn new(start: &ServerMsg) -> Option<LockstepMatch> {
        let ServerMsg::MatchStart {
            match_id,
            seed,
            mode,
            team,
            biome,
            players,
            rosters,
            tokens,
            ..
        } = start
        else {
            return None;
        };
        Some(LockstepMatch {
            match_id: *match_id,
            team: *team,
            mode: *mode,
            players: players.clone(),
            tokens: tokens.clone(),
            arena: Arena::on(rosters[0].clone(), rosters[1].clone(), *seed, *biome),
            desynced: false,
            events: Vec::new(),
            end: None,
        })
    }

    /// Applies one server message. Returns true when the match has ended.
    pub fn handle(&mut self, msg: &ServerMsg) -> bool {
        match msg {
            ServerMsg::Tick { tick, commands } => {
                if *tick != self.arena.tick() {
                    self.desynced = true;
                }
                for c in commands {
                    self.arena.command(*c);
                }
                self.arena.step();
                self.events.extend(self.arena.take_events());
            }
            ServerMsg::Catchup { ticks } => {
                for commands in ticks {
                    for c in commands {
                        self.arena.command(*c);
                    }
                    self.arena.step();
                }
                // What happened while away is not replayed in the log.
                self.arena.take_events();
            }
            ServerMsg::Hash { tick, hash } => {
                if *tick == self.arena.tick()
                    && *hash != format!("{:016x}", self.arena.state_hash())
                {
                    self.desynced = true;
                }
            }
            ServerMsg::MatchEnd {
                match_id,
                result,
                surrendered,
                ..
            } if *match_id == self.match_id => {
                if let Some(t) = surrendered {
                    self.arena.surrender(*t);
                }
                if self.arena.result != Some(*result) {
                    self.desynced = true;
                }
                self.end = Some(msg.clone());
                return true;
            }
            _ => {}
        }
        false
    }
}
