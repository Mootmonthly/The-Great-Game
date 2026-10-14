//! Online play: `NetClient` talks to the arena server (net-proto) on
//! background threads and mirrors the running match in lockstep. It offers
//! the same rendering interface as `ArenaSim`, so the arena scene draws
//! online and local matches the same way.

use crate::{arena_state, event_lines, to_gstring, SimWorld};
use godot::prelude::*;
use net_proto::client::{local_sheet, LockstepMatch};
use net_proto::{read_msg, tls, write_msg, Auth, ChampionKind, ClientMsg, QueueMode, ServerMsg, PROTOCOL_VERSION};
use serde_json::{json, Value};
use sim_core::arena::ArenaCommand;
use sim_core::Fx;
use std::io::BufReader;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Duration;

enum Incoming {
    Msg(Box<ServerMsg>),
    /// The server certificate fingerprint, after the handshake.
    Certificate(String),
    Closed(String),
}

struct Target {
    host: String,
    port: u16,
    name: String,
    auth: Auth,
    pin: Option<String>,
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct NetClient {
    out: Option<Sender<ClientMsg>>,
    inc: Option<Receiver<Incoming>>,
    current: Option<LockstepMatch>,
    log: Vec<String>,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for NetClient {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            out: None,
            inc: None,
            current: None,
            log: Vec::new(),
            base,
        }
    }
}

fn run_connection(t: Target, out: Receiver<ClientMsg>, inc: Sender<Incoming>) {
    let stream = (t.host.as_str(), t.port)
        .to_socket_addrs()
        .map_err(|e| e.to_string())
        .and_then(|mut a| a.next().ok_or_else(|| "unknown host".to_string()))
        .and_then(|a| {
            TcpStream::connect_timeout(&a, Duration::from_secs(5)).map_err(|e| e.to_string())
        })
        .and_then(|tcp| tls::connect(tcp, &t.host, t.pin.clone()).map_err(|e| e.to_string()));
    let conn = match stream {
        Ok(c) => c,
        Err(e) => {
            let _ = inc.send(Incoming::Closed(format!("could not connect: {e}")));
            return;
        }
    };
    let mut writer = conn.writer;
    let seen = conn.seen;
    std::thread::spawn(move || {
        let hello = ClientMsg::Hello {
            name: t.name,
            version: PROTOCOL_VERSION,
            auth: t.auth,
        };
        if write_msg(&mut writer, &hello).is_ok() {
            for msg in out {
                if write_msg(&mut writer, &msg).is_err() {
                    break;
                }
            }
        }
        // Dropping the client (or a write error) closes the connection,
        // which also ends the reader below.
        writer.shutdown();
    });
    let mut reader = BufReader::new(conn.reader);
    let mut first = true;
    loop {
        match read_msg::<_, ServerMsg>(&mut reader) {
            Ok(Some(msg)) => {
                if first {
                    first = false;
                    if let Some(fp) = seen.lock().unwrap().clone() {
                        let _ = inc.send(Incoming::Certificate(fp));
                    }
                }
                if inc.send(Incoming::Msg(Box::new(msg))).is_err() {
                    return;
                }
            }
            Ok(None) => {
                let _ = inc.send(Incoming::Closed("the server closed the connection".into()));
                return;
            }
            Err(e) => {
                let _ = inc.send(Incoming::Closed(format!("connection lost: {e}")));
                return;
            }
        }
    }
}

fn nonempty(s: &GString) -> Option<String> {
    Some(s.to_string()).filter(|s| !s.is_empty())
}

impl NetClient {
    fn start(&mut self, host: &GString, port: i64, name: &GString, auth: Auth, pin: &GString) {
        let (otx, orx) = channel();
        let (itx, irx) = channel();
        self.out = Some(otx);
        self.inc = Some(irx);
        self.current = None;
        let target = Target {
            host: host.to_string(),
            port: port.clamp(1, 65535) as u16,
            name: name.to_string(),
            auth,
            pin: nonempty(pin),
        };
        std::thread::spawn(move || run_connection(target, orx, itx));
    }

    fn send(&self, msg: ClientMsg) -> bool {
        self.out.as_ref().is_some_and(|tx| tx.send(msg).is_ok())
    }

    fn my_team(&self) -> u8 {
        self.current.as_ref().map_or(0, |m| m.team)
    }

    fn command(&self, command: ArenaCommand) {
        if self.current.as_ref().is_some_and(|m| m.end.is_none()) {
            self.send(ClientMsg::Command { command });
        }
    }
}

#[godot_api]
impl NetClient {
    /// Connects over TLS in the background and signs in as `name` with the
    /// account `secret` ("" for a first sign-in, which claims the name).
    /// `pin` is the server's certificate fingerprint from an earlier visit
    /// ("" if none). Replies arrive through `poll`.
    #[func]
    fn connect_to(&mut self, host: GString, port: i64, name: GString, secret: GString, pin: GString) {
        let auth = Auth::Account {
            secret: nonempty(&secret),
        };
        self.start(&host, port, &name, auth, &pin);
    }

    /// Signs in with a Steam Web API ticket (hex, from the Steamworks SDK's
    /// GetAuthTicketForWebApi).
    #[func]
    fn connect_steam(&mut self, host: GString, port: i64, display_name: GString, ticket: GString, pin: GString) {
        let auth = Auth::Steam {
            ticket: ticket.to_string(),
        };
        self.start(&host, port, &display_name, auth, &pin);
    }

    #[func]
    fn close_connection(&mut self) {
        self.out = None;
        self.inc = None;
    }

    #[func]
    fn is_open(&self) -> bool {
        self.out.is_some()
    }

    /// Messages from the server since the last call, as a JSON array.
    /// Arena ticks are applied to the local match copy, not returned.
    #[func]
    fn poll(&mut self) -> GString {
        let mut out: Vec<Value> = Vec::new();
        let mut closed = None;
        if let Some(rx) = &self.inc {
            while let Ok(incoming) = rx.try_recv() {
                match incoming {
                    Incoming::Closed(reason) => {
                        closed = Some(reason);
                        break;
                    }
                    Incoming::Certificate(fp) => {
                        out.push(json!({"type": "certificate", "fingerprint": fp}));
                    }
                    Incoming::Msg(msg) => match msg.as_ref() {
                        ServerMsg::MatchStart { .. } => {
                            self.current = LockstepMatch::new(&msg);
                            self.log.clear();
                            out.push(serde_json::to_value(&msg).unwrap_or(Value::Null));
                        }
                        ServerMsg::Tick { .. } | ServerMsg::Hash { .. } | ServerMsg::Catchup { .. } => {
                            if let Some(m) = self.current.as_mut() {
                                m.handle(&msg);
                                let events = std::mem::take(&mut m.events);
                                self.log.extend(event_lines(&m.arena, &events));
                            }
                        }
                        ServerMsg::MatchEnd { .. } => {
                            let mut v = serde_json::to_value(&msg).unwrap_or(Value::Null);
                            if let Some(m) = self.current.as_mut() {
                                m.handle(&msg);
                                v["desynced"] = json!(m.desynced);
                                v["team"] = json!(m.team);
                            }
                            out.push(v);
                        }
                        _ => out.push(serde_json::to_value(&msg).unwrap_or(Value::Null)),
                    },
                }
            }
        }
        if let Some(reason) = closed {
            self.out = None;
            self.inc = None;
            out.push(json!({"type": "disconnected", "reason": reason}));
        }
        to_gstring(json!(out))
    }

    /// Asks the server to verify a champion from `world` ("species" or
    /// "individual"). The server replays the world's log to check it.
    /// `moon` is the moon the being lives on, or -1 for the planet.
    #[func]
    fn bind(&mut self, world: Gd<SimWorld>, kind: GString, id: i64, moon: i64) -> bool {
        let kind = match kind.to_string().as_str() {
            "species" => ChampionKind::Species,
            "individual" => ChampionKind::Individual,
            _ => return false,
        };
        let w = &world.bind().world;
        let moon = u8::try_from(moon).ok();
        let home = match moon {
            Some(k) => w.moon(k as usize),
            None => Some(w),
        };
        let Some(sheet) = home.and_then(|h| local_sheet(h, kind, id as u32)) else {
            return false;
        };
        self.send(ClientMsg::Bind {
            log: w.log().clone(),
            moon,
            kind,
            id: id as u32,
            cost: sheet.cost.cost,
        })
    }

    /// Joins the "ranked" or "practice" queue with these champion tokens.
    #[func]
    fn queue(&mut self, mode: GString, cap: i64, tokens: PackedInt64Array) -> bool {
        let mode = if mode == "practice" {
            QueueMode::Practice
        } else {
            QueueMode::Ranked
        };
        self.send(ClientMsg::Queue {
            mode,
            cap,
            champions: tokens.as_slice().iter().map(|&t| t as u64).collect(),
        })
    }

    #[func]
    fn leave_queue(&mut self) {
        self.send(ClientMsg::LeaveQueue);
    }

    #[func]
    fn surrender(&mut self) {
        self.send(ClientMsg::Surrender);
    }

    /// Your side in the current match: 0 or 1.
    #[func]
    fn team(&self) -> i64 {
        self.my_team() as i64
    }

    // The same rendering interface as `ArenaSim`.

    #[func]
    fn state_json(&self) -> GString {
        match &self.current {
            Some(m) => to_gstring(arena_state(&m.arena, m.team)),
            None => GString::from("null"),
        }
    }

    #[func]
    fn events_json(&mut self) -> GString {
        to_gstring(json!(std::mem::take(&mut self.log)))
    }

    /// Online, the server sets the pace: ticks arrive through `poll`.
    #[func]
    fn step(&mut self, _ticks: i64) {}

    #[func]
    fn possess(&mut self, unit: i64) {
        self.command(ArenaCommand::Possess {
            team: self.my_team(),
            unit: (unit >= 0).then_some(unit as usize),
        });
    }

    #[func]
    fn steer(&mut self, unit: i64, x: f64, z: f64) {
        if unit >= 0 {
            self.command(ArenaCommand::Steer {
                unit: unit as usize,
                x: Fx::from_f64(x),
                z: Fx::from_f64(z),
            });
        }
    }

    #[func]
    fn attack(&mut self, unit: i64) {
        if unit >= 0 {
            self.command(ArenaCommand::Attack {
                unit: unit as usize,
            });
        }
    }

    #[func]
    fn breathe(&mut self, unit: i64) {
        if unit >= 0 {
            self.command(ArenaCommand::Breathe {
                unit: unit as usize,
            });
        }
    }
}
