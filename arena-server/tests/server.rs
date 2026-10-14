//! End-to-end tests: a real server on a local port and real clients.

use arena_server::server::{start, Config};
use net_proto::client::{local_sheet, Client, Login, LockstepMatch};
use net_proto::{Auth, ChampionKind, ClientMsg, QueueMode, ServerMsg};
use sim_core::arena::{ArenaCommand, ArenaResult};
use sim_core::presets::preset_actions;
use sim_core::{Action, World};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

fn server(data: Option<PathBuf>) -> SocketAddr {
    server_paced(data, Duration::ZERO)
}

fn server_paced(data: Option<PathBuf>, tick_interval: Duration) -> SocketAddr {
    start(Config::local("127.0.0.1:0", data, tick_interval))
        .unwrap()
        .addr
}

fn world(seed: u64) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, "frozen_moon").unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks: 800 });
    w
}

fn login(addr: SocketAddr, name: &str) -> Login {
    Login::new("127.0.0.1", addr.port(), name)
}

fn connect(addr: SocketAddr, name: &str) -> Client {
    connect_secret(addr, name).0
}

/// Signs in for the first time; returns the issued account secret.
fn connect_secret(addr: SocketAddr, name: &str) -> (Client, String) {
    let (c, welcome) = Client::connect(&login(addr, name)).unwrap();
    let ServerMsg::Welcome {
        secret: Some(secret),
        ..
    } = welcome
    else {
        panic!("{welcome:?}")
    };
    (c, secret)
}

fn individuals(w: &World, n: usize) -> Vec<u32> {
    let mut ids: Vec<u32> = w.living_individuals().map(|i| i.id).collect();
    ids.sort();
    ids.truncate(n);
    assert!(!ids.is_empty(), "the test world has named individuals");
    ids
}

fn biggest_species(w: &World) -> u32 {
    w.living_species().max_by_key(|s| (s.biomass, s.id)).unwrap().id
}

/// Both clients follow the match to its end.
fn play(a: &mut Client, b: &mut Client) -> (LockstepMatch, LockstepMatch) {
    let mut ma = a.wait_for_match().unwrap().unwrap();
    let mut mb = b.wait_for_match().unwrap().unwrap();
    assert_eq!(ma.match_id, mb.match_id);
    std::thread::scope(|s| {
        s.spawn(|| b.follow(&mut mb).unwrap());
        a.follow(&mut ma).unwrap();
    });
    (ma, mb)
}

#[test]
fn ranked_match_verifies_plays_in_lockstep_and_kills_forever() {
    let dir = std::env::temp_dir().join(format!("arena-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let addr = server(Some(dir.clone()));
    let mut wa = world(1);
    let wb = world(2);
    let (mut a, alice_secret) = connect_secret(addr, "alice");
    let mut b = connect(addr, "bob");

    let mut ta = Vec::new();
    for id in individuals(&wa, 3) {
        ta.push(a.bind(&wa, ChampionKind::Individual, id).unwrap().unwrap());
    }
    ta.push(
        a.bind(&wa, ChampionKind::Species, biggest_species(&wa))
            .unwrap()
            .unwrap(),
    );
    let mut tb = Vec::new();
    for _ in 0..3 {
        // Rank and file: the same species can be bound many times.
        tb.push(
            b.bind(&wb, ChampionKind::Species, biggest_species(&wb))
                .unwrap()
                .unwrap(),
        );
    }
    let cap = 1000;
    a.queue(QueueMode::Ranked, cap, ta.iter().map(|t| t.token).collect())
        .unwrap();
    b.queue(QueueMode::Ranked, cap, tb.iter().map(|t| t.token).collect())
        .unwrap();
    let (ma, mb) = play(&mut a, &mut b);
    assert!(!ma.desynced && !mb.desynced, "lockstep held");
    assert_eq!(ma.arena.state_hash(), mb.arena.state_hash());

    let Some(ServerMsg::MatchEnd {
        result,
        fallen,
        rating,
        ..
    }) = ma.end.clone()
    else {
        panic!()
    };
    assert_ne!(result, ArenaResult::Draw);
    assert!(rating.is_some());
    // Everyone who fell in our copy of the arena is reported as fallen.
    let dead_units = ma.arena.units.iter().filter(|u| !u.alive).count();
    assert_eq!(fallen.len(), dead_units);
    assert!(!fallen.is_empty());

    // A fallen individual can never be bound again, even from an
    // unchanged copy of its world.
    let dead_individual = fallen
        .iter()
        .find(|f| f.account == "alice" && f.kind == ChampionKind::Individual);
    if let Some(f) = dead_individual {
        let again = a.bind(&wa, ChampionKind::Individual, f.id).unwrap();
        assert!(again.unwrap_err().contains("died in the arena"));
        // Logged at home, the world replays without them.
        wa.apply(Action::ChampionFell { individual: f.id });
        assert!(!wa.individual_by_id(f.id).unwrap().is_alive());
    }

    // State survives a restart.
    drop(a);
    drop(b);
    std::thread::sleep(Duration::from_millis(200));
    let addr2 = server(Some(dir.clone()));
    let mut alice = login(addr2, "alice");
    alice.auth = Auth::Account {
        secret: Some(alice_secret),
    };
    let (_c, welcome) = Client::connect(&alice).unwrap();
    let ServerMsg::Welcome {
        rating: r2,
        champions,
        ..
    } = welcome
    else {
        panic!()
    };
    assert_eq!(r2, rating.unwrap());
    let alive_tokens = ta
        .iter()
        .filter(|t| !fallen.iter().any(|f| f.token == t.token))
        .count();
    assert_eq!(champions.len(), alive_tokens);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn forged_and_invalid_requests_are_refused() {
    let addr = server(None);
    let w = world(1);
    let mut a = connect(addr, "carol");
    let id = individuals(&w, 1)[0];
    let real = local_sheet(&w, ChampionKind::Individual, id).unwrap().cost.cost;

    // Lying about the cost.
    a.send(&ClientMsg::Bind {
        log: w.log().clone(),
        kind: ChampionKind::Individual,
        id,
        cost: real + 50,
    })
    .unwrap();
    let ServerMsg::Rejected { reason, .. } = a.recv().unwrap() else {
        panic!()
    };
    assert!(reason.contains("cost mismatch"), "{reason}");

    // A being that does not exist.
    assert!(a
        .bind(&w, ChampionKind::Species, 999_999)
        .unwrap()
        .is_err());

    // Editing the world log changes the world: the champion is gone or
    // different, so the claimed cost no longer matches.
    let mut forged = w.log().clone();
    let before_history = forged.actions.len() - 1;
    forged.actions.insert(
        before_history,
        Action::SetGravity {
            g: sim_core::Fx::ratio(1, 10),
        },
    );
    a.send(&ClientMsg::Bind {
        log: forged,
        kind: ChampionKind::Individual,
        id,
        cost: real,
    })
    .unwrap();
    assert!(matches!(a.recv().unwrap(), ServerMsg::Rejected { .. }));

    // Over the cap, someone else's token, or nothing at all.
    let t = a.bind(&w, ChampionKind::Individual, id).unwrap().unwrap();
    for (cap, tokens) in [(1, vec![t.token]), (100, vec![424242]), (100, vec![])] {
        a.queue(QueueMode::Ranked, cap.max(t.cost - 1), tokens).unwrap();
        assert!(matches!(a.recv().unwrap(), ServerMsg::Rejected { .. }));
    }

    // One sign-in per account.
    let (_dup, reply) = Client::connect(&login(addr, "carol")).unwrap();
    assert!(matches!(reply, ServerMsg::Rejected { .. }));
}

#[test]
fn names_are_claimed_with_a_secret() {
    let addr = server(None);
    let (first, secret) = connect_secret(addr, "frank");
    drop(first);
    std::thread::sleep(Duration::from_millis(100));
    // Without the secret, or with a wrong one, the name is taken.
    for wrong in [None, Some("deadbeef".to_string())] {
        let mut l = login(addr, "frank");
        l.auth = Auth::Account { secret: wrong };
        let (_c, reply) = Client::connect(&l).unwrap();
        let ServerMsg::Rejected { reason, .. } = reply else {
            panic!("{reply:?}")
        };
        assert!(reason.contains("taken"), "{reason}");
    }
    // With it, welcome back (and no new secret).
    let mut l = login(addr, "frank");
    l.auth = Auth::Account {
        secret: Some(secret),
    };
    let (c, reply) = Client::connect(&l).unwrap();
    assert!(matches!(reply, ServerMsg::Welcome { secret: None, .. }), "{reply:?}");
    // The connection is encrypted, with a certificate fingerprint to pin.
    assert!(c.fingerprint().is_some_and(|f| f.len() == 95));
    // Steam sign-in is refused when the server has no Steam key.
    let mut l = login(addr, "anyone");
    l.auth = Auth::Steam {
        ticket: "abcd".into(),
    };
    let (_c, reply) = Client::connect(&l).unwrap();
    assert!(matches!(reply, ServerMsg::Rejected { .. }));
}

#[test]
fn surrender_and_practice() {
    // Real-time pacing, so the surrender lands before the fight is over.
    let addr = server_paced(None, Duration::from_millis(20));
    let w = world(2);
    let mut a = connect(addr, "dave");
    let mut b = connect(addr, "erin");
    let s = biggest_species(&w);
    let ta = a.bind(&w, ChampionKind::Species, s).unwrap().unwrap();
    let tb = b.bind(&w, ChampionKind::Species, s).unwrap().unwrap();
    let ti = b
        .bind(&w, ChampionKind::Individual, individuals(&w, 1)[0])
        .unwrap()
        .unwrap();

    // Practice: nobody dies, ratings do not move.
    a.queue(QueueMode::Practice, 500, vec![ta.token]).unwrap();
    b.queue(QueueMode::Practice, 500, vec![tb.token, ti.token])
        .unwrap();
    let (ma, _) = play(&mut a, &mut b);
    let Some(ServerMsg::MatchEnd { fallen, rating, .. }) = ma.end else {
        panic!()
    };
    assert!(fallen.is_empty() && rating.is_none());

    // Surrender: the other side wins at once; survivors go home.
    a.queue(QueueMode::Ranked, 500, vec![ta.token]).unwrap();
    b.queue(QueueMode::Ranked, 500, vec![tb.token, ti.token])
        .unwrap();
    let mut ma = a.wait_for_match().unwrap().unwrap();
    let mut mb = b.wait_for_match().unwrap().unwrap();
    // Commands for the other side's units are ignored.
    let enemy = if ma.team == 0 { ma.tokens[0].len() } else { 0 };
    a.send(&ClientMsg::Command {
        command: ArenaCommand::Possess {
            team: 1 - ma.team,
            unit: Some(enemy),
        },
    })
    .unwrap();
    b.send(&ClientMsg::Surrender).unwrap();
    let end = a.follow(&mut ma).unwrap();
    b.follow(&mut mb).unwrap();
    let ServerMsg::MatchEnd {
        result,
        surrendered,
        fallen,
        ..
    } = end
    else {
        panic!()
    };
    assert_eq!(surrendered, Some(mb.team));
    let winner = if ma.team == 0 {
        ArenaResult::TeamA
    } else {
        ArenaResult::TeamB
    };
    assert_eq!(result, winner);
    assert!(fallen.is_empty(), "surrender this early: nobody had fallen yet");
    assert!(!ma.desynced && !mb.desynced);
    assert!(!ma.arena.units.iter().any(|u| u.possessed));
}
