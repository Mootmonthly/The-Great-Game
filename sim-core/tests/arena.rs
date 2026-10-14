//! Real-time arena in the Rust core (docs/GAME_DESIGN.md §6.1a, §6.3).

use sim_core::arena::{Arena, ArenaCommand, ArenaResult};
use sim_core::presets::preset_actions;
use sim_core::sheet::{species_sheet, CharacterSheet};
use sim_core::{Action, Fx, World};

fn sheets(preset: &str, seed: u64, ticks: u32) -> Vec<CharacterSheet> {
    let mut w = World::new(seed);
    for a in preset_actions(&w, preset).unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks });
    let mut v: Vec<CharacterSheet> = w.living_species().map(|s| species_sheet(&w, s)).collect();
    v.sort_by_key(|s| std::cmp::Reverse(s.cost.cost));
    v
}

fn run(arena: &mut Arena) {
    for _ in 0..20_000 {
        if arena.result.is_some() {
            break;
        }
        arena.step();
    }
}

#[test]
fn matches_are_deterministic() {
    let pool = sheets("frozen_moon", 1, 2400);
    let a = pool[0..3].to_vec();
    let b = pool[3..7].to_vec();
    let mut x = Arena::new(a.clone(), b.clone(), 9);
    let mut y = Arena::new(a, b, 9);
    run(&mut x);
    run(&mut y);
    assert!(x.result.is_some());
    assert_eq!(x.result, y.result);
    assert_eq!(x.time, y.time);
    let hp = |ar: &Arena| ar.units.iter().map(|u| u.hp).collect::<Vec<_>>();
    assert_eq!(hp(&x), hp(&y));
}

#[test]
fn the_much_stronger_team_wins() {
    let pool = sheets("earthlike", 1, 2400);
    let strong = pool[0].clone();
    let weak = pool.last().unwrap().clone();
    assert!(strong.cost.cost >= weak.cost.cost * 5);
    let mut wins = 0;
    for seed in 0..10 {
        let mut ar = Arena::new(vec![strong.clone()], vec![weak.clone()], seed);
        run(&mut ar);
        if ar.result == Some(ArenaResult::TeamA) {
            wins += 1;
        }
    }
    assert!(wins >= 9, "strong side won {wins} of 10");
}

#[test]
fn possessed_units_follow_steering_and_matches_replay() {
    let pool = sheets("frozen_moon", 2, 2400);
    let a = pool[0..2].to_vec();
    let b = pool[2..5].to_vec();
    let mut live = Arena::new(a.clone(), b.clone(), 5);
    live.command(ArenaCommand::Possess {
        team: 0,
        unit: Some(0),
    });
    let start = live.units[0].pos;
    live.command(ArenaCommand::Steer {
        unit: 0,
        x: Fx::ONE,
        z: Fx::ZERO,
    });
    for _ in 0..20 {
        live.step();
    }
    assert!(live.units[0].pos.x > start.x, "possessed unit moved east");
    live.command(ArenaCommand::Steer {
        unit: 0,
        x: Fx::ZERO,
        z: Fx::ONE,
    });
    for _ in 0..30 {
        live.step();
        live.command(ArenaCommand::Attack { unit: 0 });
        live.command(ArenaCommand::Breathe { unit: 0 });
    }
    live.command(ArenaCommand::Possess {
        team: 0,
        unit: None,
    });
    run(&mut live);
    let replayed = Arena::replay(a, b, 5, &live.command_log);
    assert_eq!(live.result, replayed.result);
    assert_eq!(live.time, replayed.time);
    assert_eq!(
        live.units.iter().map(|u| (u.hp, u.pos)).collect::<Vec<_>>(),
        replayed
            .units
            .iter()
            .map(|u| (u.hp, u.pos))
            .collect::<Vec<_>>()
    );
}
