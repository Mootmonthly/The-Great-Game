//! A blocking client for the arena server, used by the bot, tests and the
//! Godot extension. It mirrors each match locally: the server sends every
//! tick's commands, and `LockstepMatch` steps an identical arena.

use crate::{read_msg, write_msg, ChampionKind, ChampionToken, ClientMsg, QueueMode, ServerMsg};
use sim_core::arena::{Arena, ArenaEvent};
use sim_core::sheet::{individual_sheet, species_sheet, CharacterSheet};
use sim_core::World;
use std::io::{self, BufReader};
use std::net::{TcpStream, ToSocketAddrs};

pub struct Client {
    reader: BufReader<TcpStream>,
    writer: TcpStream,
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

impl Client {
    /// Connects and signs in. Returns the client and the server's welcome.
    pub fn connect<A: ToSocketAddrs>(addr: A, name: &str) -> io::Result<(Client, ServerMsg)> {
        let stream = TcpStream::connect(addr)?;
        stream.set_nodelay(true)?;
        let mut c = Client {
            reader: BufReader::new(stream.try_clone()?),
            writer: stream,
        };
        c.send(&ClientMsg::Hello {
            name: name.to_string(),
            version: crate::PROTOCOL_VERSION,
        })?;
        let welcome = c.recv()?;
        Ok((c, welcome))
    }

    /// Splits off the raw stream, e.g. to read on another thread.
    pub fn into_parts(self) -> (BufReader<TcpStream>, TcpStream) {
        (self.reader, self.writer)
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
        let Some(sheet) = local_sheet(world, kind, id) else {
            return Ok(Err("no such being".into()));
        };
        self.send(&ClientMsg::Bind {
            log: world.log().clone(),
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
            arena: Arena::new(rosters[0].clone(), rosters[1].clone(), *seed),
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
