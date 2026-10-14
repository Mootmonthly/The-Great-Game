//! Headless runner for the world simulation.
//!
//! Usage:
//!   sim-cli presets
//!   sim-cli run [--preset NAME] [--seed N] [--years N] [--every N] [--png DIR]
//!   sim-cli verify [--preset NAME] [--seed N] [--years N]
//!   sim-cli bench [--years N]

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
        "bench" => bench(
            opts.get("years")
                .and_then(|s| s.parse().ok())
                .unwrap_or(100),
        ),
        _ => {
            eprintln!("usage: sim-cli <presets|run|verify|bench> [--preset NAME] [--seed N] [--years N] [--every N] [--png DIR]");
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
        "year {:5}  T̄ {:7.1} K  P {:6.2} bar  species {:4} alive / {:5} ever  biomass {:9.1}  max size {:6.2}  max int {:4.2}",
        w.year(),
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
