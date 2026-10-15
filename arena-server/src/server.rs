//! The arena server (docs/GAME_DESIGN.md §6.2–6.3).
//!
//! One thread per connection reads requests; a writer thread per connection
//! sends replies. Each match runs on its own thread: it applies the players'
//! commands, steps the authoritative arena and broadcasts every tick's
//! commands, so clients step identical arenas in lockstep.

use crate::sign::{digest, hex, Signer};
use crate::steam::SteamConfig;
use crate::store::{Champion, Store};
use crate::verify::{verify_with, Checkpoints};
use net_proto::{
    read_msg, write_msg, Auth, ChampionKind, ChampionToken, ClientMsg, Fallen, QueueMode, RatingView,
    ServerMsg, HASH_INTERVAL, PROTOCOL_VERSION,
};
use sim_core::arena::{Arena, ArenaCommand, ArenaResult};
use sim_core::loot::LootGrant;
use sim_core::shop::{ShopGrant, ShopItem, WIN_ESSENCE};
use sim_core::Fx;
use std::collections::{HashMap, HashSet};
use std::io::{self, BufReader};
use net_proto::tls::{TlsReader, TlsServer};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

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
    /// Allow server accounts (name plus server-issued secret).
    pub allow_accounts: bool,
    /// Steam sign-in, if configured.
    pub steam: Option<SteamConfig>,
    /// PEM certificate chain and key. Without them the server makes a
    /// self-signed certificate (kept in `data_dir`).
    pub tls_pem: Option<(PathBuf, PathBuf)>,
    /// How long a disconnected player may take to rejoin a running match
    /// before it counts as surrender.
    pub reconnect_grace: Duration,
}

/// Default time to rejoin a match after losing the connection.
pub const RECONNECT_GRACE: Duration = Duration::from_secs(30);

impl Config {
    /// A local server with server accounts and no Steam.
    pub fn local(bind: &str, data_dir: Option<PathBuf>, tick_interval: Duration) -> Config {
        Config {
            bind: bind.into(),
            data_dir,
            tick_interval,
            allow_accounts: true,
            steam: None,
            tls_pem: None,
            reconnect_grace: RECONNECT_GRACE,
        }
    }
}

pub struct ServerHandle {
    pub addr: SocketAddr,
    /// Fingerprint of the server's TLS certificate.
    pub fingerprint: String,
}

struct Shared {
    config: Config,
    tls: TlsServer,
    checkpoints: Checkpoints,
    signer: Signer,
    state: Mutex<State>,
    verifying: Semaphore,
    /// The substance table, for shop prices.
    substances: Vec<sim_core::substance::Substance>,
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

struct MatchCtl {
    inbox: Mutex<Vec<(u8, ArenaCommand)>>,
    surrender: [AtomicBool; 2],
    feed: Mutex<Feed>,
}

/// The live feed of a match. Ticks are recorded and sent under this lock,
/// so a player who rejoins gets the full history and then every new tick,
/// with no gap and no repeat.
struct Feed {
    senders: [Option<Sender<ServerMsg>>; 2],
    starts: [Option<ServerMsg>; 2],
    history: Vec<Vec<ArenaCommand>>,
    away_since: [Option<Instant>; 2],
}

impl MatchCtl {
    fn send_all(&self, msg: ServerMsg) {
        let mut feed = self.feed.lock().unwrap();
        if let ServerMsg::Tick { commands, .. } = &msg {
            feed.history.push(commands.clone());
        }
        for tx in feed.senders.iter().flatten() {
            let _ = tx.send(msg.clone());
        }
    }

    /// The player on `team` lost their connection: the AI takes over their
    /// units while the grace period runs.
    fn left(&self, team: u8) {
        let mut feed = self.feed.lock().unwrap();
        feed.senders[team as usize] = None;
        feed.away_since[team as usize] = Some(Instant::now());
        self.inbox
            .lock()
            .unwrap()
            .push((team, ArenaCommand::Possess { team, unit: None }));
    }

    /// The player on `team` is back: replay the match so far to them, then
    /// resume the live feed.
    fn rejoin(&self, team: u8, tx: &Sender<ServerMsg>) {
        let mut feed = self.feed.lock().unwrap();
        if let Some(start) = feed.starts[team as usize].clone() {
            let _ = tx.send(start);
        }
        let _ = tx.send(ServerMsg::Catchup {
            ticks: feed.history.clone(),
        });
        feed.senders[team as usize] = Some(tx.clone());
        feed.away_since[team as usize] = None;
    }
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
    let tls = match (&config.tls_pem, &config.data_dir) {
        (Some((cert, key)), _) => TlsServer::from_pem(&std::fs::read(cert)?, &std::fs::read(key)?)?,
        (None, Some(dir)) => TlsServer::self_signed_in(dir)?,
        (None, None) => TlsServer::ephemeral()?,
    };
    let fingerprint = tls.fingerprint.clone();
    let listener = TcpListener::bind(&config.bind)?;
    let addr = listener.local_addr()?;
    let cores = thread::available_parallelism().map_or(2, |n| n.get());
    let checkpoints = Checkpoints::new(config.data_dir.as_ref().map(|d| d.join("checkpoints")));
    let shared = Arc::new(Shared {
        config,
        tls,
        checkpoints,
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
        substances: sim_core::substance::default_substances(),
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
    Ok(ServerHandle { addr, fingerprint })
}

fn connection(shared: &Arc<Shared>, stream: TcpStream) -> io::Result<()> {
    let (reader, mut writer) = shared.tls.accept(stream)?;
    let mut reader = BufReader::new(reader);
    let Some(ClientMsg::Hello {
        name,
        version,
        auth,
    }) = read_msg(&mut reader)?
    else {
        write_msg(&mut writer, &rejected("hello", "expected hello"))?;
        return Ok(());
    };
    if version != PROTOCOL_VERSION {
        let reason = format!("server speaks protocol {PROTOCOL_VERSION}, client {version}: update the game");
        write_msg(&mut writer, &rejected("hello", reason))?;
        return Ok(());
    }
    // Who is this? Steam vouches for Steam accounts; server accounts prove
    // themselves with the secret issued when the name was claimed.
    let (name, secret) = match auth {
        Auth::Steam { ticket } => {
            let Some(steam) = &shared.config.steam else {
                write_msg(&mut writer, &rejected("hello", "this server does not use Steam sign-in"))?;
                return Ok(());
            };
            match crate::steam::authenticate(steam, &ticket) {
                Ok(id) => (format!("steam_{id}"), None),
                Err(reason) => {
                    write_msg(&mut writer, &rejected("hello", reason))?;
                    return Ok(());
                }
            }
        }
        Auth::Account { secret } => {
            if !shared.config.allow_accounts {
                write_msg(&mut writer, &rejected("hello", "this server only accepts Steam sign-in"))?;
                return Ok(());
            }
            if !valid_name(&name) || name.starts_with("steam_") {
                write_msg(&mut writer, &rejected("hello", "names are 1–24 letters, digits, - or _"))?;
                return Ok(());
            }
            (name, secret)
        }
    };

    let (tx, rx) = channel::<ServerMsg>();
    {
        let mut state = shared.state.lock().unwrap();
        if state.online.contains_key(&name) {
            drop(state);
            write_msg(&mut writer, &rejected("hello", "already signed in elsewhere"))?;
            return Ok(());
        }
        let is_steam = name.starts_with("steam_");
        let account = state.store.account(&name);
        let mut issued = None;
        if !is_steam {
            match (&account.secret_hash, &secret) {
                (Some(hash), Some(s)) if *hash == digest(s.as_bytes()) => {}
                (Some(_), _) => {
                    drop(state);
                    write_msg(&mut writer, &rejected("hello", "this name is taken (wrong or missing account secret)"))?;
                    return Ok(());
                }
                // First sign-in claims the name.
                (None, _) => {
                    let mut b = [0u8; 24];
                    getrandom::getrandom(&mut b).expect("system random source");
                    let s = hex(&b);
                    account.secret_hash = Some(digest(s.as_bytes()));
                    issued = Some(s);
                }
            }
        }
        let account = account.clone();
        state.online.insert(name.clone(), tx.clone());
        let resuming = state.playing.contains_key(&name);
        if issued.is_some() {
            shared.save(&state);
        }
        let _ = tx.send(ServerMsg::Welcome {
            account: name.clone(),
            secret: issued,
            resuming,
            rating: RatingView {
                rating: account.rating.rating,
                deviation: account.rating.deviation,
            },
            essence: account.essence,
            champions: account.champions.values().map(|c| c.token.clone()).collect(),
            planet_slots: account.planet_slots(),
            spoils: account.spoils.values().cloned().collect(),
            purchases: account.purchases.values().cloned().collect(),
        });
        if let Some((ctl, team)) = state.playing.get(&name) {
            ctl.rejoin(*team, &tx);
        }
    }
    let writer_thread = thread::spawn(move || {
        for msg in rx {
            if write_msg(&mut writer, &msg).is_err() {
                break;
            }
        }
        writer.shutdown();
    });

    let result = serve_client(shared, &name, &tx, &mut reader);

    // Signed out: leave the queue. A match keeps running; if the player
    // does not rejoin within the grace period, it counts as surrender.
    {
        let mut state = shared.state.lock().unwrap();
        state.online.remove(&name);
        leave_queue(&mut state, &name);
        if let Some((ctl, team)) = state.playing.get(&name) {
            ctl.left(*team);
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
    reader: &mut BufReader<TlsReader>,
) -> io::Result<()> {
    while let Some(msg) = read_msg::<_, ClientMsg>(reader)? {
        match msg {
            ClientMsg::Hello { .. } => {
                let _ = tx.send(rejected("hello", "already signed in"));
            }
            ClientMsg::Ping => {
                let _ = tx.send(ServerMsg::Pong);
            }
            ClientMsg::Bind {
                log,
                moon,
                kind,
                id,
                cost,
            } => {
                let reply = bind(shared, name, &log, moon, kind, id, cost);
                let _ = tx.send(reply);
            }
            ClientMsg::Buy { item } => {
                let reply = buy(shared, name, item);
                let _ = tx.send(reply);
            }
            ClientMsg::SellLoot { grant } => {
                let reply = sell_loot(shared, name, grant);
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

/// Spends Essence in the shop (§3).
fn buy(shared: &Shared, account: &str, item: ShopItem) -> ServerMsg {
    let Some(price) = item.price_in(&shared.substances) else {
        return rejected("buy", "that is not for sale");
    };
    let mut state = shared.state.lock().unwrap();
    let acc = state.store.account(account);
    if acc.essence < price {
        return rejected("buy", format!("it costs {price} Essence; you have {}", acc.essence));
    }
    if item == ShopItem::PlanetSlot && acc.planet_slots() == u8::MAX {
        return rejected("buy", "you have every planet slot there is");
    }
    acc.essence -= price;
    let grant = match item {
        ShopItem::PlanetSlot => {
            acc.extra_planets += 1;
            None
        }
        _ => {
            state.store.next_grant += 1;
            let mut g = ShopGrant {
                id: state.store.next_grant,
                account: account.to_string(),
                item: item.clone(),
                signature: String::new(),
            };
            g.signature = shared.signer.sign(&g.payload());
            state.store.account(account).purchases.insert(g.id, g.clone());
            Some(g)
        }
    };
    let acc = state.store.account(account);
    let (essence, planet_slots) = (acc.essence, acc.planet_slots());
    shared.save(&state);
    ServerMsg::Purchased {
        item,
        grant,
        essence,
        planet_slots,
    }
}

/// Sells a spoil of war back to the server for its value; the grant is
/// deleted and can never enter a world.
fn sell_loot(shared: &Shared, account: &str, grant: u64) -> ServerMsg {
    let mut state = shared.state.lock().unwrap();
    if state.store.redeemed.contains_key(&grant) {
        return rejected("sell_loot", "those spoils are already in a world");
    }
    let Some(value) = state.store.account(account).spoils.remove(&grant).map(|g| g.value) else {
        return rejected("sell_loot", "you hold no such spoils");
    };
    state.store.sold.insert(grant);
    let acc = state.store.account(account);
    acc.essence += value;
    let essence = acc.essence;
    shared.save(&state);
    ServerMsg::Sold {
        grant,
        essence_gained: value,
        essence,
    }
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
    moon: Option<u8>,
    kind: ChampionKind,
    id: u32,
    cost: i64,
) -> ServerMsg {
    shared.verifying.acquire();
    let verified = verify_with(Some(&shared.checkpoints), &shared.signer, account, log, moon, kind, id, cost);
    shared.verifying.release();
    let v = match verified {
        Ok(v) => v,
        Err(reason) => return rejected("bind", reason),
    };

    let mut state = shared.state.lock().unwrap();
    // A loot grant enriches one world only, and a sold one none.
    for g in &v.loot {
        if state.store.sold.contains(g) {
            return rejected("bind", "this world uses spoils that were sold back to the server");
        }
        if state.store.redeemed.get(g).is_some_and(|seed| *seed != log.seed) {
            return rejected("bind", "this world uses loot already brought into another world");
        }
    }
    for g in &v.purchases {
        if state.store.purchases_used.get(g).is_some_and(|seed| *seed != log.seed) {
            return rejected("bind", "this world uses a purchase already used in another world");
        }
    }
    // Champions come from the account's home worlds: one free, more bought.
    let acc = state.store.account(account);
    if !acc.worlds.contains(&log.seed) {
        if acc.worlds.len() >= acc.planet_slots() as usize {
            return rejected(
                "bind",
                format!(
                    "your army draws on {} home world(s); buy another planet ({} Essence) to bind champions from a new one",
                    acc.planet_slots(),
                    sim_core::shop::PLANET_PRICE
                ),
            );
        }
        acc.worlds.push(log.seed);
    }
    for g in &v.loot {
        state.store.redeemed.insert(*g, log.seed);
        // Brought home: no longer for sale.
        state.store.account(account).spoils.remove(g);
    }
    for g in &v.purchases {
        state.store.purchases_used.insert(*g, log.seed);
        state.store.account(account).purchases.remove(g);
    }
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
        moon,
        biome: v.biome,
        id,
        name: v.name,
        cost,
        sheet: v.sheet,
        appearance: v.appearance,
        signature: String::new(),
    };
    token.signature = shared.signer.sign(&token_payload(&token));
    state.store.account(account).champions.insert(
        token.token,
        Champion {
            token: token.clone(),
            fingerprint: v.fingerprint,
            remains: Some(v.remains),
            gear: v.gear,
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
    biome: sim_core::arena::Biome,
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
    let look = |state: &mut State, w: &Waiting| -> Vec<_> {
        let acc = state.store.account(&w.account);
        w.tokens
            .iter()
            .map(|t| acc.champions[t].token.appearance.clone())
            .collect()
    };
    let looks = [look(state, &a), look(state, &b)];
    // The battlefield is one side's home biome, by the match seed.
    let home = |state: &mut State, w: &Waiting| {
        let acc = state.store.account(&w.account);
        w.tokens.first().map_or(sim_core::arena::Biome::Plains, |t| acc.champions[t].token.biome)
    };
    let biome = if seed.is_multiple_of(2) { home(state, &a) } else { home(state, &b) };
    let players = [a.account, b.account];
    let tokens = [a.tokens, b.tokens];
    let starts = [0u8, 1].map(|team| ServerMsg::MatchStart {
        match_id: id,
        seed,
        mode: a.mode,
        cap: a.cap,
        team,
        biome,
        players: players.clone(),
        rosters: rosters.clone(),
        looks: looks.clone(),
        tokens: tokens.clone(),
    });
    let senders = [
        state.online.get(&players[0]).cloned(),
        state.online.get(&players[1]).cloned(),
    ];
    for (tx, start) in senders.iter().zip(&starts) {
        if let Some(tx) = tx {
            let _ = tx.send(start.clone());
        }
    }
    let ctl = Arc::new(MatchCtl {
        inbox: Mutex::new(Vec::new()),
        surrender: Default::default(),
        feed: Mutex::new(Feed {
            senders,
            starts: starts.map(Some),
            history: Vec::new(),
            away_since: [None, None],
        }),
    });
    state.playing.insert(players[0].clone(), (ctl.clone(), 0));
    state.playing.insert(players[1].clone(), (ctl.clone(), 1));
    let info = MatchInfo {
        id,
        seed,
        mode: a.mode,
        players,
        tokens,
        rosters,
        biome,
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
    let mut arena = Arena::on(info.rosters[0].clone(), info.rosters[1].clone(), info.seed, info.biome);
    let broadcast = |msg: ServerMsg| info.ctl.send_all(msg);
    let grace = shared.config.reconnect_grace;
    let mut surrendered = None;
    loop {
        if !shared.config.tick_interval.is_zero() {
            thread::sleep(shared.config.tick_interval);
        }
        // Surrender is checked before commands, so nothing changes in the
        // arena that the clients do not see.
        // Gone too long: that is surrender.
        {
            let feed = info.ctl.feed.lock().unwrap();
            for t in 0..2 {
                if feed.away_since[t].is_some_and(|since| since.elapsed() > grace) {
                    info.ctl.surrender[t].store(true, Ordering::SeqCst);
                }
            }
        }
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

    let winner = match result {
        ArenaResult::TeamA => Some(0usize),
        ArenaResult::TeamB => Some(1usize),
        ArenaResult::Draw => None,
    };
    // Permadeath: the fallen are gone (ranked only). The winner loots the
    // bodies of the loser's fallen (§6.2a) and earns Essence for the win (§3).
    let mut fallen = Vec::new();
    let mut loot = Vec::new();
    let essence_gained = if ranked && winner.is_some() { WIN_ESSENCE } else { 0 };
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
                if let (Some(w), Some(remains)) = (winner, c.remains.clone()) {
                    if w != team {
                        state.store.next_grant += 1;
                        let value = c.token.cost.max(1) as u64;
                        let mut grant = LootGrant {
                            id: state.store.next_grant,
                            account: info.players[w].clone(),
                            from: c.token.name.clone(),
                            remains,
                            biomass: Fx::ONE + Fx::ratio(c.token.cost, 20),
                            value,
                            gear: c.gear.clone(),
                            signature: String::new(),
                        };
                        grant.signature = shared.signer.sign(&grant.payload());
                        state.store.account(&info.players[w]).spoils.insert(grant.id, grant.clone());
                        loot.push(grant);
                    }
                }
                fallen.push(Fallen {
                    token,
                    account: account.clone(),
                    kind: c.token.kind,
                    world_seed: c.token.world_seed,
                    moon: c.token.moon,
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
    if let Some(w) = winner {
        state.store.account(&info.players[w]).essence += essence_gained;
    }
    let balances = [
        state.store.account(&info.players[0]).essence,
        state.store.account(&info.players[1]).essence,
    ];
    for p in &info.players {
        state.playing.remove(p);
    }
    shared.save(&state);
    drop(state);

    let record = serde_json::json!({
        "match_id": info.id, "seed": info.seed, "players": info.players,
        "tokens": info.tokens, "result": result, "surrendered": surrendered,
        "fallen": fallen, "ticks": arena.tick(), "ended_by": arena.ended_by, "biome": info.biome, "essence_gained": essence_gained,
        "loot": loot.iter().map(|g| g.id).collect::<Vec<_>>(),
        "commands": digest(&serde_json::to_vec(&arena.command_log).unwrap_or_default()),
    });
    let signature = shared.signer.sign(record.to_string().as_bytes());
    let senders = info.ctl.feed.lock().unwrap().senders.clone();
    for (team, (tx, rating)) in senders.iter().zip(ratings).enumerate() {
        let won = winner == Some(team);
        if let Some(tx) = tx {
            let _ = tx.send(ServerMsg::MatchEnd {
                match_id: info.id,
                result,
                surrendered,
                fallen: fallen.clone(),
                ended_by: arena.ended_by.map(str::to_string).or(surrendered.map(|_| "surrender".to_string())),
                rating,
                essence_gained: if won { essence_gained } else { 0 },
                essence: balances[team],
                loot: if won { loot.clone() } else { Vec::new() },
                signature: signature.clone(),
            });
        }
    }
}
