//! `arena-server serve` runs the dedicated server. `arena-server bot` is a
//! headless player: it evolves a world, binds champions, queues and lets
//! the arena AI fight, which is handy for testing a server.

use arena_server::server::{start, Config};
use net_proto::client::{local_sheet, Client};
use net_proto::{ChampionKind, QueueMode, ServerMsg, DEFAULT_PORT};
use sim_core::presets::preset_actions;
use sim_core::{Action, World};
use std::path::PathBuf;
use std::time::Duration;

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
}

fn num<T: std::str::FromStr>(args: &[String], name: &str, default: T) -> T {
    arg(args, name).and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn usage() -> ! {
    eprintln!(
        "usage:
  arena-server serve [--port {DEFAULT_PORT}] [--data server-data] [--speed 1]
  arena-server bot [--host 127.0.0.1] [--port {DEFAULT_PORT}] --name NAME
                   [--preset frozen_moon] [--seed 1] [--years 300] [--cap 300]
                   [--mode ranked|practice]"
    );
    std::process::exit(2)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => serve(&args),
        Some("bot") => bot(&args),
        _ => usage(),
    }
}

fn serve(args: &[String]) {
    let port: u16 = num(args, "--port", DEFAULT_PORT);
    let speed: f64 = num(args, "--speed", 1.0);
    let data = arg(args, "--data").unwrap_or_else(|| "server-data".into());
    let tick = if speed > 0.0 {
        Duration::from_secs_f64(0.1 / speed)
    } else {
        Duration::ZERO
    };
    let handle = start(Config {
        bind: format!("0.0.0.0:{port}"),
        data_dir: Some(PathBuf::from(&data)),
        tick_interval: tick,
    })
    .unwrap_or_else(|e| {
        eprintln!("could not start the server: {e}");
        std::process::exit(1)
    });
    println!("arena server listening on {} (state in {data}/)", handle.addr);
    loop {
        std::thread::park();
    }
}

fn bot(args: &[String]) {
    let host = arg(args, "--host").unwrap_or_else(|| "127.0.0.1".into());
    let port: u16 = num(args, "--port", DEFAULT_PORT);
    let name = arg(args, "--name").unwrap_or_else(|| usage());
    let preset = arg(args, "--preset").unwrap_or_else(|| "frozen_moon".into());
    let seed: u64 = num(args, "--seed", 1);
    let years: u32 = num(args, "--years", 300);
    let cap: i64 = num(args, "--cap", 300);
    let mode = match arg(args, "--mode").as_deref() {
        Some("practice") => QueueMode::Practice,
        _ => QueueMode::Ranked,
    };

    println!("evolving {preset} (seed {seed}) for {years} years…");
    let mut world = World::new(seed);
    for a in preset_actions(&world, &preset).unwrap_or_else(|| usage()) {
        world.apply(a);
    }
    world.apply(Action::Tick { ticks: years * 4 });

    let (mut client, welcome) = Client::connect((host.as_str(), port), &name).unwrap_or_else(|e| {
        eprintln!("could not connect: {e}");
        std::process::exit(1)
    });
    if let ServerMsg::Rejected { reason, .. } = &welcome {
        eprintln!("server refused: {reason}");
        std::process::exit(1)
    }
    println!("signed in as {name}");

    // Strongest affordable champions: named individuals first, then the
    // largest species as rank and file.
    let mut picks: Vec<(ChampionKind, u32, i64)> = Vec::new();
    for ind in world.living_individuals() {
        if let Some(sh) = local_sheet(&world, ChampionKind::Individual, ind.id) {
            picks.push((ChampionKind::Individual, ind.id, sh.cost.cost));
        }
    }
    for s in world.living_species() {
        if let Some(sh) = local_sheet(&world, ChampionKind::Species, s.id) {
            picks.push((ChampionKind::Species, s.id, sh.cost.cost));
        }
    }
    picks.sort_by_key(|p| std::cmp::Reverse(p.2));
    let mut tokens = Vec::new();
    let mut total = 0;
    for (kind, id, cost) in picks {
        if total + cost > cap || tokens.len() >= 8 {
            continue;
        }
        match client.bind(&world, kind, id) {
            Ok(Ok(t)) => {
                println!("bound {} ({:?}, cost {})", t.name, kind, t.cost);
                total += t.cost;
                tokens.push(t.token);
            }
            Ok(Err(reason)) => println!("could not bind: {reason}"),
            Err(e) => {
                eprintln!("connection lost: {e}");
                std::process::exit(1)
            }
        }
    }
    if tokens.is_empty() {
        eprintln!("no champion fits under the cap");
        std::process::exit(1)
    }
    client.queue(mode, cap, tokens).expect("queue");
    println!("queued ({mode:?}, cap {cap}, team cost {total}); waiting for an opponent…");
    let mut m = match client.wait_for_match().expect("connection") {
        Ok(m) => m,
        Err(reason) => {
            eprintln!("queue refused: {reason}");
            std::process::exit(1)
        }
    };
    println!(
        "match {} against {}",
        m.match_id,
        m.players[1 - m.team as usize]
    );
    let end = client.follow(&mut m).expect("connection");
    if let ServerMsg::MatchEnd {
        result,
        fallen,
        rating,
        ..
    } = end
    {
        println!("result: {result:?} (we were team {})", m.team);
        for f in &fallen {
            match f.kind {
                ChampionKind::Individual => println!("fell forever: {} ({})", f.name, f.account),
                ChampionKind::Species => println!("lost a {} ({})", f.name, f.account),
            }
            if f.account == name && f.kind == ChampionKind::Individual && f.world_seed == seed {
                world.apply(Action::ChampionFell { individual: f.id });
            }
        }
        if let Some(r) = rating {
            println!("rating now {:.0} ± {:.0}", r.rating, r.deviation);
        }
        println!(
            "lockstep: {}",
            if m.desynced { "DESYNC" } else { "in sync with the server" }
        );
    }
}
