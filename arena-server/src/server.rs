//! The arena server (docs/GAME_DESIGN.md §6.2–6.3).
//!
//! One thread per connection reads requests; a writer thread per connection
//! sends replies. Each match runs on its own thread: it applies the players'
//! commands, steps the authoritative arena and broadcasts every tick's
//! commands, so clients step identical arenas in lockstep.

use crate::sign::{digest, Signer};
use crate::store::{Champion, Store};
use crate::verify::verify;
use net_proto::{
    read_msg, write_msg, ChampionKind, ChampionToken, ClientMsg, Fallen, QueueMode, RatingView,
    ServerMsg, HASH_INTERVAL, PROTOCOL_VERSION,
};
use sim_core::arena::{Arena, ArenaCommand, ArenaResult};
use std::collections::{HashMap, HashSet};
use std::io::{self, BufReader};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

/// Most units on one side (§6.1).
pub const MAX_UNITS: usize = 500;
/// Largest team cost cap: 500 units of the most expensive kind.
pub const MAX_CAP: i64 = 500_000;

pub struct Config {
    /// Address to listen on, e.g. "0.0.0.0:7878". Port 0 picks a free port.
    pub bind: String,
    /// Where state and the signing key are kept. `None` keeps everything in
    /// memory (tests).
    pub data_dir: Option<PathBuf>,
    /// Real time per arena tick. Zero runs matches as fast as possible.
    pub tick_interval: Duration,
}

pub struct ServerHandle {
    pub addr: SocketAddr,
}

struct Shared {
    config: Config,
    signer: Signer,
    state: Mutex<State>,
    verifying: Semaphore,
}

struct State {
    store: Store,
    online: HashMap<String, Sender<ServerMsg>>,
    queue: Vec<Waiting>,
    playing: HashMap<String, (Arc<MatchCtl>, u8)>,
    /// Tokens waiting in a queue or fighting.
    busy: HashSet<u64>,
}

struct Waiting {
    account: String,
    mode: QueueMode,
    cap: i64,
    tokens: Vec<u64>,
}

#[derive(Default)]
struct MatchCtl {
    inbox: Mutex<Vec<(u8, ArenaCommand)>>,
    surrender: [AtomicBool; 2],
}

/// Bounds how many replays run at once, so verification cannot starve
/// running matches of CPU.
struct Semaphore {
    free: Mutex<usize>,
    cv: Condvar,
}

impl Semaphore {
    fn acquire(&self) {
        let mut free = self.free.lock().unwrap();
        while *free == 0 {
            free = self.cv.wait(free).unwrap();
        }
        *free -= 1;
    }

    fn release(&self) {
        *self.free.lock().unwrap() += 1;
        self.cv.notify_one();
    }
}

impl Shared {
    fn save(&self, state: &State) {
        if let Some(dir) = &self.config.data_dir {
            if let Err(e) = state.store.save(&dir.join("state.json")) {
                eprintln!("could not save server state: {e}");
            }
        }
    }
}

fn send(state: &State, account: &str, msg: ServerMsg) {
    if let Some(tx) = state.online.get(account) {
        let _ = tx.send(msg);
    }
}

fn rejected(request: &str, reason: impl Into<String>) -> ServerMsg {
    ServerMsg::Rejected {
        request: request.into(),
        reason: reason.into(),
    }
}

fn valid_name(name: &str) -> bool {
    (1..=24).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn random_u64() -> u64 {
    let mut b = [0u8; 8];
    getrandom::getrandom(&mut b).expect("system random source");
    u64::from_le_bytes(b)
}

/// Starts the server and returns once it is listening.
pub fn start(config: Config) -> io::Result<ServerHandle> {
    let (store, signer) = match &config.data_dir {
        Some(dir) => {
            std::fs::create_dir_all(dir)?;
            (
                Store::load(&dir.join("state.json"))?,
                Signer::load_or_create(&dir.join("secret.key"))?,
            )
        }
        None => (Store::default(), Signer::random()),
    };
    let listener = TcpListener::bind(&config.bind)?;
    let addr = listener.local_addr()?;
    let cores = thread::available_parallelism().map_or(2, |n| n.get());
    let shared = Arc::new(Shared {
        config,
        signer,
        state: Mutex::new(State {
            store,
            online: HashMap::new(),
            queue: Vec::new(),
            playing: HashMap::new(),
            busy: HashSet::new(),
        }),
        verifying: Semaphore {
            free: Mutex::new((cores / 2).max(1)),
            cv: Condvar::new(),
        },
    });
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let shared = shared.clone();
            thread::spawn(move || {
                if let Err(e) = connection(&shared, stream) {
                    if e.kind() != io::ErrorKind::UnexpectedEof {
                        eprintln!("connection error: {e}");
                    }
                }
            });
        }
    });
    Ok(ServerHandle { addr })
}

fn connection(shared: &Arc<Shared>, stream: TcpStream) -> io::Result<()> {
    stream.set_nodelay(true)?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    let Some(ClientMsg::Hello { name, version }) = read_msg(&mut reader)? else {
        write_msg(&mut writer, &rejected("hello", "expected hello"))?;
        return Ok(());
    };
    if version != PROTOCOL_VERSION {
        let reason = format!("server speaks protocol {PROTOCOL_VERSION}, client {version}: update the game");
        write_msg(&mut writer, &rejected("hello", reason))?;
        return Ok(());
    }
    if !valid_name(&name) {
        write_msg(&mut writer, &rejected("hello", "names are 1–24 letters, digits, - or _"))?;
        return Ok(());
    }

    let (tx, rx) = channel::<ServerMsg>();
    {
        let mut state = shared.state.lock().unwrap();
        if state.online.contains_key(&name) {
            drop(state);
            write_msg(&mut writer, &rejected("hello", "already signed in elsewhere"))?;
            return Ok(());
        }
        state.online.insert(name.clone(), tx.clone());
        let account = state.store.account(&name).clone();
        let _ = tx.send(ServerMsg::Welcome {
            account: name.clone(),
            rating: RatingView {
                rating: account.rating.rating,
                deviation: account.rating.deviation,
            },
            champions: account.champions.values().map(|c| c.token.clone()).collect(),
        });
    }
    let writer_thread = thread::spawn(move || {
        for msg in rx {
            if write_msg(&mut writer, &msg).is_err() {
                break;
            }
        }
        let _ = writer.shutdown(std::net::Shutdown::Both);
    });

    let result = serve_client(shared, &name, &tx, &mut reader);

    // Signed out: leave the queue; walking out of a match is surrender.
    {
        let mut state = shared.state.lock().unwrap();
        state.online.remove(&name);
        leave_queue(&mut state, &name);
        if let Some((ctl, team)) = state.playing.get(&name) {
            ctl.surrender[*team as usize].store(true, Ordering::SeqCst);
        }
    }
    drop(tx);
    let _ = writer_thread.join();
    result
}

fn serve_client(
    shared: &Arc<Shared>,
    name: &str,
    tx: &Sender<ServerMsg>,
    reader: &mut BufReader<TcpStream>,
) -> io::Result<()> {
    while let Some(msg) = read_msg::<_, ClientMsg>(reader)? {
        match msg {
            ClientMsg::Hello { .. } => {
                let _ = tx.send(rejected("hello", "already signed in"));
            }
            ClientMsg::Ping => {
                let _ = tx.send(ServerMsg::Pong);
            }
            ClientMsg::Bind { log, kind, id, cost } => {
                let reply = bind(shared, name, &log, kind, id, cost);
                let _ = tx.send(reply);
            }
            ClientMsg::Queue {
                mode,
                cap,
                champions,
            } => queue(shared, name, mode, cap, champions),
            ClientMsg::LeaveQueue => {
                let mut state = shared.state.lock().unwrap();
                leave_queue(&mut state, name);
                send(&state, name, ServerMsg::LeftQueue);
            }
            ClientMsg::Command { command } => {
                let state = shared.state.lock().unwrap();
                if let Some((ctl, team)) = state.playing.get(name) {
                    ctl.inbox.lock().unwrap().push((*team, command));
                }
            }
            ClientMsg::Surrender => {
                let state = shared.state.lock().unwrap();
                if let Some((ctl, team)) = state.playing.get(name) {
                    ctl.surrender[*team as usize].store(true, Ordering::SeqCst);
                }
            }
        }
    }
    Ok(())
}

fn token_payload(t: &ChampionToken) -> Vec<u8> {
    let mut unsigned = t.clone();
    unsigned.signature.clear();
    serde_json::to_vec(&unsigned).expect("tokens serialise")
}

fn bind(
    shared: &Shared,
    account: &str,
    log: &sim_core::ActionLog,
    kind: ChampionKind,
    id: u32,
    cost: i64,
) -> ServerMsg {
    shared.verifying.acquire();
    let verified = verify(log, kind, id, cost);
    shared.verifying.release();
    let v = match verified {
        Ok(v) => v,
        Err(reason) => return rejected("bind", reason),
    };

    let mut state = shared.state.lock().unwrap();
    if let Some(fp) = v.fingerprint {
        if state.store.dead.contains(&fp) {
            return rejected("bind", format!("{} died in the arena", v.name));
        }
        let elsewhere = state.store.accounts.iter().any(|(name, a)| {
            name != account && a.champions.values().any(|c| c.fingerprint == Some(fp))
        });
        if elsewhere {
            return rejected("bind", format!("{} is bound by another player", v.name));
        }
        // Binding the same individual again refreshes its sheet.
        let old: Vec<u64> = state
            .store
            .account(account)
            .champions
            .values()
            .filter(|c| c.fingerprint == Some(fp))
            .map(|c| c.token.token)
            .collect();
        if old.iter().any(|t| state.busy.contains(t)) {
            return rejected("bind", format!("{} is queued or fighting", v.name));
        }
        for t in old {
            state.store.account(account).champions.remove(&t);
        }
    }
    state.store.next_token += 1;
    let mut token = ChampionToken {
        token: state.store.next_token,
        account: account.to_string(),
        kind,
        world_seed: log.seed,
        id,
        name: v.name,
        cost,
        sheet: v.sheet,
        signature: String::new(),
    };
    token.signature = shared.signer.sign(&token_payload(&token));
    state.store.account(account).champions.insert(
        token.token,
        Champion {
            token: token.clone(),
            fingerprint: v.fingerprint,
        },
    );
    shared.save(&state);
    ServerMsg::Bound { champion: token }
}

fn leave_queue(state: &mut State, account: &str) {
    let mut freed = Vec::new();
    state.queue.retain(|w| {
        if w.account == account {
            freed.extend(w.tokens.iter().copied());
            false
        } else {
            true
        }
    });
    for t in freed {
        state.busy.remove(&t);
    }
}

fn queue(shared: &Arc<Shared>, account: &str, mode: QueueMode, cap: i64, tokens: Vec<u64>) {
    let mut state = shared.state.lock().unwrap();
    let reject = |state: &State, reason: &str| send(state, account, rejected("queue", reason));
    if state.playing.contains_key(account) {
        return reject(&state, "already in a match");
    }
    if state.queue.iter().any(|w| w.account == account) {
        return reject(&state, "already queued");
    }
    if !(1..=MAX_CAP).contains(&cap) {
        return reject(&state, "cost cap out of range");
    }
    if tokens.is_empty() || tokens.len() > MAX_UNITS {
        return reject(&state, "pick 1 to 500 champions");
    }
    let unique: HashSet<u64> = tokens.iter().copied().collect();
    if unique.len() != tokens.len() {
        return reject(&state, "a champion was picked twice");
    }
    let mut cost = 0;
    for t in &tokens {
        let Some(c) = state.store.account(account).champions.get(t) else {
            return reject(&state, "unknown champion");
        };
        cost += c.token.cost;
        if state.busy.contains(t) {
            return reject(&state, "a champion is already queued or fighting");
        }
    }
    if cost > cap {
        return reject(&state, "team costs more than the cap");
    }
    for t in &tokens {
        state.busy.insert(*t);
    }
    let rating = state.store.account(account).rating.rating;
    // The closest-rated opponent waiting in the same queue.
    let opponent = state
        .queue
        .iter()
        .enumerate()
        .filter(|(_, w)| w.mode == mode && w.cap == cap)
        .min_by(|(_, a), (_, b)| {
            let ra = state.store.accounts.get(&a.account).map_or(1500.0, |x| x.rating.rating);
            let rb = state.store.accounts.get(&b.account).map_or(1500.0, |x| x.rating.rating);
            (ra - rating).abs().total_cmp(&(rb - rating).abs())
        })
        .map(|(i, _)| i);
    let me = Waiting {
        account: account.to_string(),
        mode,
        cap,
        tokens,
    };
    match opponent {
        Some(i) => {
            let other = state.queue.remove(i);
            start_match(shared, &mut state, other, me);
        }
        None => {
            state.queue.push(me);
            send(&state, account, ServerMsg::Queued { mode, cap, cost });
        }
    }
}

struct MatchInfo {
    id: u64,
    seed: u64,
    mode: QueueMode,
    players: [String; 2],
    tokens: [Vec<u64>; 2],
    rosters: [Vec<sim_core::sheet::CharacterSheet>; 2],
    senders: [Option<Sender<ServerMsg>>; 2],
    ctl: Arc<MatchCtl>,
}

fn start_match(shared: &Arc<Shared>, state: &mut State, a: Waiting, b: Waiting) {
    state.store.next_match += 1;
    let id = state.store.next_match;
    let seed = random_u64();
    let roster = |state: &mut State, w: &Waiting| -> Vec<_> {
        let acc = state.store.account(&w.account);
        w.tokens
            .iter()
            .map(|t| acc.champions[t].token.sheet.clone())
            .collect()
    };
    let rosters = [roster(state, &a), roster(state, &b)];
    let ctl = Arc::new(MatchCtl::default());
    state.playing.insert(a.account.clone(), (ctl.clone(), 0));
    state.playing.insert(b.account.clone(), (ctl.clone(), 1));
    let players = [a.account, b.account];
    let tokens = [a.tokens, b.tokens];
    for team in 0..2u8 {
        send(
            state,
            &players[team as usize],
            ServerMsg::MatchStart {
                match_id: id,
                seed,
                mode: a.mode,
                cap: a.cap,
                team,
                players: players.clone(),
                rosters: rosters.clone(),
                tokens: tokens.clone(),
            },
        );
    }
    let info = MatchInfo {
        id,
        seed,
        mode: a.mode,
        senders: [
            state.online.get(&players[0]).cloned(),
            state.online.get(&players[1]).cloned(),
        ],
        players,
        tokens,
        rosters,
        ctl,
    };
    shared.save(state);
    let shared = shared.clone();
    thread::spawn(move || run_match(&shared, info));
}

/// Whether `team` may give this command: only for its own units.
fn allowed(arena: &Arena, team: u8, c: &mut ArenaCommand) -> bool {
    let own = |unit: usize| arena.units.get(unit).is_some_and(|u| u.team == team);
    match c {
        ArenaCommand::Possess { team: t, unit } => {
            *t = team;
            unit.is_none_or(own)
        }
        ArenaCommand::Steer { unit, .. }
        | ArenaCommand::Attack { unit }
        | ArenaCommand::Breathe { unit } => own(*unit),
    }
}

fn run_match(shared: &Arc<Shared>, info: MatchInfo) {
    let mut arena = Arena::new(info.rosters[0].clone(), info.rosters[1].clone(), info.seed);
    let broadcast = |msg: ServerMsg| {
        for tx in info.senders.iter().flatten() {
            let _ = tx.send(msg.clone());
        }
    };
    let mut surrendered = None;
    loop {
        if !shared.config.tick_interval.is_zero() {
            thread::sleep(shared.config.tick_interval);
        }
        // Surrender is checked before commands, so nothing changes in the
        // arena that the clients do not see.
        if let Some(t) = (0..2u8).find(|&t| info.ctl.surrender[t as usize].load(Ordering::SeqCst)) {
            surrendered = Some(t);
            arena.surrender(t);
            break;
        }
        let pending = std::mem::take(&mut *info.ctl.inbox.lock().unwrap());
        let mut applied = Vec::new();
        for (team, mut c) in pending {
            if allowed(&arena, team, &mut c) {
                arena.command(c);
                applied.push(c);
            }
        }
        let tick = arena.tick();
        arena.step();
        broadcast(ServerMsg::Tick {
            tick,
            commands: applied,
        });
        if arena.tick().is_multiple_of(HASH_INTERVAL) {
            broadcast(ServerMsg::Hash {
                tick: arena.tick(),
                hash: format!("{:016x}", arena.state_hash()),
            });
        }
        if arena.result.is_some() {
            break;
        }
    }
    finish(shared, &info, &arena, surrendered);
}

fn finish(shared: &Shared, info: &MatchInfo, arena: &Arena, surrendered: Option<u8>) {
    let result = arena.result.unwrap_or(ArenaResult::Draw);
    let ranked = info.mode == QueueMode::Ranked;
    let mut state = shared.state.lock().unwrap();

    // Permadeath: the fallen are gone (ranked only).
    let mut fallen = Vec::new();
    for team in 0..2 {
        // Units are in roster order, team A first.
        let base = if team == 0 { 0 } else { info.tokens[0].len() };
        for (k, &token) in info.tokens[team].iter().enumerate() {
            state.busy.remove(&token);
            let alive = arena.units[base + k].alive;
            if alive || !ranked {
                continue;
            }
            let account = &info.players[team];
            if let Some(c) = state.store.account(account).champions.remove(&token) {
                if let Some(fp) = c.fingerprint {
                    state.store.dead.insert(fp);
                }
                fallen.push(Fallen {
                    token,
                    account: account.clone(),
                    kind: c.token.kind,
                    world_seed: c.token.world_seed,
                    id: c.token.id,
                    name: c.token.name,
                });
            }
        }
    }

    let mut ratings = [None, None];
    if ranked {
        let score = match result {
            ArenaResult::TeamA => [1.0, 0.0],
            ArenaResult::TeamB => [0.0, 1.0],
            ArenaResult::Draw => [0.5, 0.5],
        };
        let before = [
            state.store.account(&info.players[0]).rating,
            state.store.account(&info.players[1]).rating,
        ];
        for t in 0..2 {
            let acc = state.store.account(&info.players[t]);
            acc.rating = before[t].update(before[1 - t], score[t]);
            match score[t] {
                s if s > 0.75 => acc.wins += 1,
                s if s < 0.25 => acc.losses += 1,
                _ => acc.draws += 1,
            }
            ratings[t] = Some(RatingView {
                rating: acc.rating.rating,
                deviation: acc.rating.deviation,
            });
        }
    }
    for p in &info.players {
        state.playing.remove(p);
    }
    shared.save(&state);
    drop(state);

    let record = serde_json::json!({
        "match_id": info.id, "seed": info.seed, "players": info.players,
        "tokens": info.tokens, "result": result, "surrendered": surrendered,
        "fallen": fallen, "ticks": arena.tick(),
        "commands": digest(&serde_json::to_vec(&arena.command_log).unwrap_or_default()),
    });
    let signature = shared.signer.sign(record.to_string().as_bytes());
    for (tx, rating) in info.senders.iter().zip(ratings) {
        if let Some(tx) = tx {
            let _ = tx.send(ServerMsg::MatchEnd {
                match_id: info.id,
                result,
                surrendered,
                fallen: fallen.clone(),
                rating,
                signature: signature.clone(),
            });
        }
    }
}
