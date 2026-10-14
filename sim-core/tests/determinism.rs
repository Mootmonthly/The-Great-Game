//! Replay verification depends on these properties (docs/GAME_DESIGN.md §6.2).

use sim_core::life::EnergyKind;
use sim_core::presets::preset_actions;
use sim_core::{Action, ActionLog, Fx, World};

fn run_preset(preset: &str, seed: u64, ticks: u32) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, preset).unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks });
    w
}

#[test]
fn same_seed_and_actions_give_same_world() {
    let a = run_preset("earthlike", 7, 120);
    let b = run_preset("earthlike", 7, 120);
    assert_eq!(a.state_hash(), b.state_hash());
}

#[test]
fn different_seeds_give_different_worlds() {
    let a = run_preset("earthlike", 1, 40);
    let b = run_preset("earthlike", 2, 40);
    assert_ne!(a.state_hash(), b.state_hash());
}

#[test]
fn replay_from_saved_log_matches() {
    let mut w = run_preset("earthlike", 3, 60);
    let water = w.substance_index("water").unwrap() as u16;
    w.apply(Action::AddSubstance {
        x: 10,
        y: 10,
        radius: 3,
        substance: water,
        amount: Fx::from_int(5),
    });
    w.apply(Action::HeatRegion {
        x: 40,
        y: 5,
        radius: 2,
        delta: Fx::from_int(-30),
    });
    w.apply(Action::Tick { ticks: 60 });
    let log = ActionLog::from_json(&w.log().to_json()).unwrap();
    let replayed = World::replay(&log);
    assert_eq!(w.state_hash(), replayed.state_hash());
}

#[test]
fn tick_actions_merge_in_log() {
    let mut w = World::new(1);
    for _ in 0..10 {
        w.apply(Action::Tick { ticks: 1 });
    }
    assert_eq!(w.log().actions, vec![Action::Tick { ticks: 10 }]);
}

/// Locks the simulation output. If this fails after an intentional change to
/// the simulation rules, update the constant: old save files will no longer
/// replay identically. If it fails on one platform only, the simulation is not
/// cross-platform deterministic and that is a bug.
#[test]
fn golden_hash() {
    let w = run_preset("earthlike", 1, 200);
    assert_eq!(
        format!("{:016x}", w.state_hash()),
        GOLDEN_EARTHLIKE_SEED1_200
    );
}

const GOLDEN_EARTHLIKE_SEED1_200: &str = "99bf8dca0566b007";

/// Same check on a world with named individuals, brains and relationships.
#[test]
fn golden_hash_with_individuals() {
    let w = run_preset("frozen_moon", 1, 2400);
    assert!(w.living_individuals().count() > 0);
    assert_eq!(
        format!("{:016x}", w.state_hash()),
        GOLDEN_FROZEN_MOON_SEED1_600
    );
}

const GOLDEN_FROZEN_MOON_SEED1_600: &str = "ec9e0fe550e480a3";

#[test]
fn different_chemistry_gives_different_life() {
    let earth = run_preset("earthlike", 1, 400);
    let magma = run_preset("magma_world", 1, 400);
    let dominant = |w: &World| {
        let s = w
            .living_species()
            .max_by_key(|s| s.biomass)
            .expect("life emerged");
        (
            w.elements[s.profile.element as usize].clone(),
            w.substances[s.profile.medium as usize].key.clone(),
        )
    };
    assert_eq!(
        dominant(&earth),
        ("Carbon".to_string(), "water".to_string())
    );
    assert_eq!(
        dominant(&magma),
        ("Silicon".to_string(), "silicate".to_string())
    );
}

#[test]
fn blank_world_stays_lifeless() {
    let w = run_preset("blank", 1, 200);
    assert_eq!(w.living_species().count(), 0);
}

#[test]
fn evolution_produces_larger_creatures() {
    let w = run_preset("earthlike", 1, 1200);
    let max = w.living_species().map(|s| s.genome.size).max().unwrap();
    assert!(max > Fx::from_int(1), "largest species size {max:?}");
}

#[test]
fn cold_world_uses_other_energy_than_light() {
    let w = run_preset("frozen_moon", 1, 400);
    let s = w
        .living_species()
        .max_by_key(|s| s.biomass)
        .expect("life emerged");
    assert_ne!(s.profile.energy, EnergyKind::Light);
}

#[test]
fn milestones_are_reached_in_order() {
    use sim_core::body::{MILESTONES, MULTICELLULAR, NERVOUS};
    let w = run_preset("earthlike", 1, 1600);
    assert!(w
        .living_species()
        .any(|s| s.genome.milestones & NERVOUS != 0));
    for s in w.living_species() {
        for m in &MILESTONES {
            if s.genome.milestones & m.flag != 0 {
                assert_eq!(
                    s.genome.milestones & m.requires,
                    m.requires,
                    "{} skipped a prerequisite",
                    s.name
                );
            }
        }
        if s.genome.milestones & MULTICELLULAR == 0 {
            assert!(
                s.genome.size <= Fx::ratio(5, 100),
                "single cells stay microscopic"
            );
        }
    }
}

#[test]
fn named_individuals_form_relationships() {
    let w = run_preset("earthlike", 1, 2400);
    let living: Vec<_> = w.living_individuals().collect();
    assert!(
        !living.is_empty(),
        "individuals appear once nervous systems evolve"
    );
    assert!(living.iter().any(|x| !x.relations.is_empty()));
    assert!(w.individuals.iter().any(|x| x.memories.len() > 1));
    for x in &living {
        assert!((1..=30).contains(&x.charisma()));
        assert!(w.species_by_id(x.species).is_some());
    }
}

/// Design rule (docs/GAME_DESIGN.md §4.4): an unmodified Earth-like world
/// should almost always produce sapient life given time.
#[test]
fn earthlike_worlds_reach_sapience() {
    use sim_core::body::SAPIENCE;
    let handles: Vec<_> = (1..=3u64)
        .map(|seed| {
            std::thread::spawn(move || {
                let w = run_preset("earthlike", seed, 4000);
                (
                    seed,
                    w.living_species()
                        .filter(|s| s.genome.milestones & SAPIENCE != 0)
                        .count(),
                )
            })
        })
        .collect();
    for h in handles {
        let (seed, sapient) = h.join().unwrap();
        assert!(
            sapient > 0,
            "earthlike seed {seed} has no sapient species after 1000 years"
        );
    }
}
