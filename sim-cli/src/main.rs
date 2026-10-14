//! Headless runner for the world simulation.
//!
//! Usage:
//!   sim-cli presets
//!   sim-cli run [--preset NAME] [--seed N] [--years N] [--every N] [--png DIR]
//!   sim-cli verify [--preset NAME] [--seed N] [--years N]
//!   sim-cli bench [--years N]
//!   sim-cli balance [--years N]   check that cost predicts battle results
//!   sim-cli sheets [--preset NAME] [--seed N] [--years N]   print character sheets

use sim_core::presets::{preset_actions, PRESETS};
use sim_core::world::{HEIGHT, WIDTH};
use sim_core::{Action, Fx, Overlay, World};
use std::collections::HashMap;
use std::path::Path;
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("help");
    let opts = parse_opts(&args[1.min(args.len())..]);
    let preset = opts
        .get("preset")
        .cloned()
        .unwrap_or_else(|| "earthlike".into());
    let seed: u64 = opts.get("seed").and_then(|s| s.parse().ok()).unwrap_or(1);
    let years: u64 = opts
        .get("years")
        .and_then(|s| s.parse().ok())
        .unwrap_or(200);

    let code = match command {
        "presets" => {
            for (name, desc) in PRESETS {
                println!("{name:14} {desc}");
            }
            0
        }
        "run" => {
            let every: u64 = opts.get("every").and_then(|s| s.parse().ok()).unwrap_or(25);
            run(
                &preset,
                seed,
                years,
                every,
                opts.get("png").map(String::as_str),
            )
        }
        "verify" => verify(&preset, seed, years),
        "balance" => balance(
            opts.get("years")
                .and_then(|s| s.parse().ok())
                .unwrap_or(800),
        ),
        "sheets" => sheets(&preset, seed, years),
        "bench" => bench(
            opts.get("years")
                .and_then(|s| s.parse().ok())
                .unwrap_or(100),
        ),
        _ => {
            eprintln!("usage: sim-cli <presets|run|verify|bench|balance|sheets> [--preset NAME] [--seed N] [--years N] [--every N] [--png DIR]");
            2
        }
    };
    std::process::exit(code);
}

fn parse_opts(args: &[String]) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if let Some(key) = a.strip_prefix("--") {
            map.insert(key.to_string(), it.next().cloned().unwrap_or_default());
        }
    }
    map
}

fn start(preset: &str, seed: u64) -> Option<World> {
    let mut world = World::new(seed);
    let Some(actions) = preset_actions(&world, preset) else {
        eprintln!("unknown preset '{preset}'; run `sim-cli presets` for the list");
        return None;
    };
    for a in actions {
        world.apply(a);
    }
    Some(world)
}

fn summary_line(w: &World) -> String {
    let living: Vec<_> = w.living_species().collect();
    let biomass = living.iter().fold(Fx::ZERO, |a, s| a + s.biomass);
    let max_size = living
        .iter()
        .map(|s| s.genome.size)
        .max()
        .unwrap_or(Fx::ZERO);
    let max_int = living
        .iter()
        .map(|s| s.traits.intelligence)
        .max()
        .unwrap_or(Fx::ZERO);
    format!(
        "year {:5}  sapient {:3}  T̄ {:7.1} K  P {:6.2} bar  species {:4} alive / {:5} ever  biomass {:9.1}  max size {:6.2}  max int {:4.2}",
        w.year(),
        living
            .iter()
            .filter(|s| s.has(sim_core::body::SAPIENCE))
            .count(),
        w.mean_temperature.to_f64(),
        w.pressure.to_f64(),
        living.len(),
        w.species.last().map_or(0, |s| s.id),
        biomass.to_f64(),
        max_size.to_f64(),
        max_int.to_f64(),
    )
}

fn print_milestones(w: &World) {
    println!("\nMilestones reached (living species):");
    for m in &sim_core::body::MILESTONES {
        let n = w
            .living_species()
            .filter(|s| s.genome.milestones & m.flag != 0)
            .count();
        println!("  {:18} {n}", m.name);
    }
}

fn print_individuals(w: &World, n: usize) {
    let mut living: Vec<_> = w.living_individuals().collect();
    println!(
        "\nNamed individuals: {} alive, {} on record",
        living.len(),
        w.individuals.len()
    );
    living.sort_by(|a, b| b.renown.cmp(&a.renown).then(a.id.cmp(&b.id)));
    for x in living.iter().take(n) {
        let species = w
            .species_by_id(x.species)
            .map_or("?".to_string(), |s| s.name.clone());
        println!(
            "  {:28} {:12} age {:3}  CHA {:2}  renown {:5.2}  friends {} enemies {}  ({})",
            x.title(),
            species,
            x.age_years(w.tick),
            x.charisma(),
            x.renown.to_f64(),
            x.friends(),
            x.enemies(),
            x.personality.describe()
        );
    }
}

fn print_top_species(w: &World, n: usize) {
    let mut living: Vec<_> = w.living_species().collect();
    living.sort_by(|a, b| b.biomass.cmp(&a.biomass).then(a.id.cmp(&b.id)));
    println!("\nTop species:");
    for s in living.iter().take(n) {
        let names: Vec<String> = w.substances.iter().map(|x| x.name.clone()).collect();
        println!(
            "  #{:<5} {:14} {:44} biomass {:8.1}  regions {:4}  size {:6.2}  T opt {:6.1} K\n         body: {}; temperament: {}",
            s.id,
            s.name,
            s.description(w),
            s.biomass.to_f64(),
            s.range,
            s.genome.size.to_f64(),
            s.genome.temp_opt.to_f64(),
            s.genome.body.describe(&names),
            s.temperament.describe()
        );
    }
}

fn run(preset: &str, seed: u64, years: u64, every: u64, png_dir: Option<&str>) -> i32 {
    let Some(mut world) = start(preset, seed) else {
        return 2;
    };
    println!("preset {preset}, seed {seed}");
    println!("{}", summary_line(&world));
    let t0 = Instant::now();
    let ticks_per_year = sim_core::world::TICKS_PER_YEAR as u32;
    for y in 1..=years {
        world.apply(Action::Tick {
            ticks: ticks_per_year,
        });
        if every > 0 && y % every == 0 {
            println!("{}", summary_line(&world));
        }
    }
    let elapsed = t0.elapsed();
    print_milestones(&world);
    print_individuals(&world, 8);
    print_top_species(&world, 10);
    println!(
        "\nLife map (letters = dominant species, '.' = viable but empty):\n{}",
        world.ascii_map()
    );
    println!("state hash {:016x}", world.state_hash());
    println!(
        "simulated {years} years in {:.2} s ({:.2} ms per sim-year)",
        elapsed.as_secs_f64(),
        elapsed.as_secs_f64() * 1000.0 / years.max(1) as f64
    );
    if let Some(dir) = png_dir {
        std::fs::create_dir_all(dir).expect("create png dir");
        for (name, overlay) in [
            ("surface", Overlay::Surface),
            ("temperature", Overlay::Temperature),
            ("life", Overlay::Life),
            ("viability", Overlay::Viability),
            ("veil", Overlay::Veil),
            ("mana", Overlay::Mana),
            ("qi", Overlay::Qi),
            ("civilizations", Overlay::Civilizations),
        ] {
            let path = Path::new(dir).join(format!("{preset}_{seed}_{name}.png"));
            write_png(&path, &world.overlay_rgba(overlay), 8);
            println!("wrote {}", path.display());
        }
    }
    0
}

/// Runs a world, then rebuilds it from its action log and checks that both
/// hashes match: the core of replay verification.
fn verify(preset: &str, seed: u64, years: u64) -> i32 {
    let Some(mut world) = start(preset, seed) else {
        return 2;
    };
    for _ in 0..years {
        world.apply(Action::Tick {
            ticks: sim_core::world::TICKS_PER_YEAR as u32,
        });
    }
    let json = world.log().to_json();
    let log = sim_core::ActionLog::from_json(&json).expect("log round-trips");
    let replayed = World::replay(&log);
    let (a, b) = (world.state_hash(), replayed.state_hash());
    println!(
        "original  {a:016x}\nreplayed  {b:016x}\nlog size  {} bytes, {} actions",
        json.len(),
        log.actions.len()
    );
    if a == b {
        println!("OK: replay matches");
        0
    } else {
        println!("MISMATCH: simulation is not deterministic");
        1
    }
}

fn bench(years: u64) -> i32 {
    for (name, _) in PRESETS {
        let mut world = start(name, 1).expect("preset exists");
        let t0 = Instant::now();
        for _ in 0..years {
            world.apply(Action::Tick {
                ticks: sim_core::world::TICKS_PER_YEAR as u32,
            });
        }
        let ms = t0.elapsed().as_secs_f64() * 1000.0 / years as f64;
        println!(
            "{name:14} {ms:8.2} ms per sim-year  ({} species alive)",
            world.living_species().count()
        );
    }
    0
}

fn write_png(path: &Path, rgba: &[u8], scale: usize) {
    let (w, h) = (WIDTH * scale, HEIGHT * scale);
    let mut data = vec![0u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let src = ((y / scale) * WIDTH + x / scale) * 4;
            let dst = (y * w + x) * 4;
            data[dst..dst + 4].copy_from_slice(&rgba[src..src + 4]);
        }
    }
    let file = std::fs::File::create(path).expect("create png");
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w as u32, h as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header()
        .and_then(|mut wr| wr.write_image_data(&data))
        .expect("write png");
}

fn print_sheet(sh: &sim_core::sheet::CharacterSheet) {
    use sim_core::sheet::{modifier, ABILITY_NAMES};
    println!(
        "== {} == {} {}, {}  [cost {}]",
        sh.name,
        sh.size.name(),
        sh.creature_type,
        sh.alignment,
        sh.cost.cost
    );
    println!(
        "   AC {}  HP {} ({}d{})  speed {} ft.{}{}{}",
        sh.armor_class,
        sh.hit_points,
        sh.hit_dice,
        sh.size.hit_die(),
        sh.speed_walk,
        if sh.speed_swim > 0 {
            format!(", swim {}", sh.speed_swim)
        } else {
            String::new()
        },
        if sh.speed_fly > 0 {
            format!(", fly {}", sh.speed_fly)
        } else {
            String::new()
        },
        if sh.speed_burrow > 0 {
            format!(", burrow {}", sh.speed_burrow)
        } else {
            String::new()
        },
    );
    let scores: Vec<String> = ABILITY_NAMES
        .iter()
        .zip(sh.abilities)
        .map(|(n, v)| format!("{n} {v} ({:+})", modifier(v)))
        .collect();
    println!("   {}", scores.join("  "));
    let list = |v: &[sim_core::sheet::DamageType]| {
        v.iter().map(|d| d.name()).collect::<Vec<_>>().join(", ")
    };
    if !sh.resistances.is_empty() {
        println!("   Resistances: {}", list(&sh.resistances));
    }
    if !sh.immunities.is_empty() {
        println!("   Immunities: {}", list(&sh.immunities));
    }
    if !sh.vulnerabilities.is_empty() {
        println!("   Vulnerabilities: {}", list(&sh.vulnerabilities));
    }
    println!("   Senses: {}", sh.senses.join(", "));
    for t in &sh.traits {
        println!("   {}. {}", t.name, t.text);
    }
    for a in &sh.attacks {
        println!("   {}", a.describe());
    }
    if let Some(b) = &sh.breath {
        println!("   {}", b.describe());
    }
    let c = &sh.cost;
    println!(
        "   cost: effective HP {:.0} × damage/round {:.1} → power {:.1} (utility +{:.0}%, stats ×{:.2})",
        c.effective_hp.to_f64(),
        c.damage_per_round.to_f64(),
        c.power.to_f64(),
        c.utility.to_f64() * 100.0,
        c.stats.to_f64()
    );
}

fn sheets(preset: &str, seed: u64, years: u64) -> i32 {
    let Some(mut world) = start(preset, seed) else {
        return 2;
    };
    world.apply(Action::Tick {
        ticks: (years * sim_core::world::TICKS_PER_YEAR) as u32,
    });
    let mut living: Vec<_> = world.living_species().collect();
    living.sort_by(|a, b| b.biomass.cmp(&a.biomass).then(a.id.cmp(&b.id)));
    for s in living.iter().take(6) {
        print_sheet(&sim_core::sheet::species_sheet(&world, s));
        println!();
    }
    let mut costly: Vec<_> = living
        .iter()
        .map(|s| sim_core::sheet::species_sheet(&world, s))
        .collect();
    costly.sort_by_key(|sh| std::cmp::Reverse(sh.cost.cost));
    println!("Most expensive species:");
    for sh in costly.iter().take(3) {
        print_sheet(sh);
        println!();
    }
    if let Some(x) = world.living_individuals().max_by_key(|x| (x.renown, x.id)) {
        println!("Most renowned individual:");
        if let Some(sh) = sim_core::sheet::individual_sheet(&world, x) {
            print_sheet(&sh);
        }
    }
    0
}

fn ranks(v: &[f64]) -> Vec<f64> {
    let mut idx: Vec<usize> = (0..v.len()).collect();
    idx.sort_by(|&a, &b| v[a].partial_cmp(&v[b]).unwrap());
    let mut r = vec![0.0; v.len()];
    let mut i = 0;
    while i < idx.len() {
        let mut j = i;
        while j + 1 < idx.len() && v[idx[j + 1]] == v[idx[i]] {
            j += 1;
        }
        let avg = (i + j) as f64 / 2.0;
        for k in i..=j {
            r[idx[k]] = avg;
        }
        i = j + 1;
    }
    r
}

fn pearson(x: &[f64], y: &[f64]) -> f64 {
    let n = x.len() as f64;
    let (mx, my) = (x.iter().sum::<f64>() / n, y.iter().sum::<f64>() / n);
    let cov: f64 = x.iter().zip(y).map(|(a, b)| (a - mx) * (b - my)).sum();
    let vx: f64 = x.iter().map(|a| (a - mx).powi(2)).sum();
    let vy: f64 = y.iter().map(|b| (b - my).powi(2)).sum();
    cov / (vx * vy).sqrt()
}

/// Checks the cost formula against the auto-battler (roadmap Phase 1 exit
/// criterion: cost should predict win rate, r > 0.8).
fn balance(years: u64) -> i32 {
    use sim_core::battle::win_rate;
    use sim_core::sheet::{species_sheet, CharacterSheet};
    let mut pool: Vec<CharacterSheet> = Vec::new();
    for preset in ["earthlike", "frozen_moon", "sulfur_world", "magma_world"] {
        for seed in 1..=2 {
            let mut w = start(preset, seed).expect("preset exists");
            w.apply(Action::Tick {
                ticks: (years * sim_core::world::TICKS_PER_YEAR) as u32,
            });
            pool.extend(w.living_species().map(|s| species_sheet(&w, s)));
        }
    }
    println!(
        "{} species sheets from 4 presets × 2 seeds at year {years}",
        pool.len()
    );
    let mut buckets = [0usize; 6];
    for sh in &pool {
        let c = sh.cost.cost;
        let b = match c {
            1 => 0,
            2..=5 => 1,
            6..=20 => 2,
            21..=100 => 3,
            101..=300 => 4,
            _ => 5,
        };
        buckets[b] += 1;
    }
    println!(
        "cost spread: 1: {}  2-5: {}  6-20: {}  21-100: {}  101-300: {}  >300: {}",
        buckets[0], buckets[1], buckets[2], buckets[3], buckets[4], buckets[5]
    );

    // Sample a panel spread across the cost range.
    let mut rng = sim_core::rng::Rng::new(42);
    let mut sample: Vec<&CharacterSheet> = Vec::new();
    let mut by_cost: Vec<&CharacterSheet> = pool.iter().collect();
    by_cost.sort_by_key(|s| s.cost.cost);
    let step = (by_cost.len() / 150).max(1);
    for (i, s) in by_cost.iter().enumerate() {
        if i % step == 0 {
            sample.push(s);
        }
    }
    // Duels: each being against random opponents.
    let mut costs = Vec::new();
    let mut rates = Vec::new();
    for (i, a) in sample.iter().enumerate() {
        let mut total = 0.0;
        let opponents = 24;
        for k in 0..opponents {
            let b = sample[rng.below(sample.len() as u64) as usize];
            total += win_rate(&[*a], &[b], 4, (i * 1000 + k) as u64);
        }
        costs.push(a.cost.cost as f64);
        rates.push(total / opponents as f64);
    }
    let spearman = pearson(&ranks(&costs), &ranks(&rates));
    println!("duels: {} beings × 24 opponents × 4 games", sample.len());
    println!("Spearman rank correlation, cost vs win rate: {spearman:.3}  (target > 0.8)");

    // Pairwise: does the more expensive side win?
    let (mut agree, mut pairs) = (0, 0);
    for k in 0..600 {
        let a = sample[rng.below(sample.len() as u64) as usize];
        let b = sample[rng.below(sample.len() as u64) as usize];
        let (ca, cb) = (a.cost.cost as f64, b.cost.cost as f64);
        if ca.max(cb) < 1.5 * ca.min(cb) {
            continue;
        }
        pairs += 1;
        let wr = win_rate(&[a], &[b], 6, 90_000 + k);
        if (wr > 0.5) == (ca > cb) {
            agree += 1;
        }
    }
    println!(
        "pairs with ≥1.5× cost gap: the pricier side won {agree} of {pairs} ({:.0}%)",
        100.0 * agree as f64 / pairs.max(1) as f64
    );

    // Armies: k cheap units against one unit costing about k times as much.
    let mut army_rates = Vec::new();
    for k in 0..400 {
        let x = sample[rng.below(sample.len() as u64) as usize];
        let n = 3 + rng.below(8) as i64;
        let target = x.cost.cost * n;
        if !(3..=40).contains(&x.cost.cost) {
            continue;
        }
        let Some(y) = sample
            .iter()
            .filter(|y| (y.cost.cost - target).abs() * 10 <= target)
            .min_by_key(|y| (y.cost.cost - target).abs())
        else {
            continue;
        };
        let army: Vec<&CharacterSheet> = (0..n).map(|_| x).collect();
        army_rates.push(win_rate(&army, &[*y], 6, 200_000 + k));
        if army_rates.len() >= 40 {
            break;
        }
    }
    if !army_rates.is_empty() {
        let mean = army_rates.iter().sum::<f64>() / army_rates.len() as f64;
        println!("armies of n cheap units vs one unit of n× the cost: army win rate {:.0}% over {} match-ups (50% = fair)", mean * 100.0, army_rates.len());
    }
    0
}
