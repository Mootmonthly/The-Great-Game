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

mod revisit {
    //! The arena revisit (§6.1): objective, time limit, biome battlefields,
    //! large armies.
    use super::*;
    use sim_core::arena::{Battlefield, Biome, Ground, Vec2, HOLD_TIME, OBJECTIVE_RADIUS, TIME_LIMIT};

    fn pair() -> (CharacterSheet, CharacterSheet) {
        let pool = sheets("frozen_moon", 1, 2400);
        (pool[0].clone(), pool[pool.len() - 1].clone())
    }

    /// Both sides possessed and standing still, at chosen spots.
    fn standoff(a: CharacterSheet, b: CharacterSheet, pa: Vec2, pb: Vec2) -> Arena {
        let mut ar = Arena::new(vec![a], vec![b], 3);
        ar.units[0].pos = pa;
        ar.units[1].pos = pb;
        ar.command(ArenaCommand::Possess { team: 0, unit: Some(0) });
        ar.command(ArenaCommand::Possess { team: 1, unit: Some(1) });
        ar
    }

    #[test]
    fn holding_the_shrine_alone_wins() {
        let (a, b) = pair();
        let far = Vec2::new(Fx::ZERO, Fx::from_int(14));
        let mut ar = standoff(a, b, Vec2::default(), far);
        run(&mut ar);
        assert_eq!(ar.result, Some(ArenaResult::TeamA));
        assert_eq!(ar.ended_by, Some("objective"));
        assert!(ar.time >= HOLD_TIME && ar.time < HOLD_TIME + Fx::ONE);
    }

    #[test]
    fn at_time_out_the_costlier_survivors_win() {
        let (rich, poor) = pair();
        assert!(rich.cost.cost * 20 > poor.cost.cost * 21);
        let (pa, pb) = (Vec2::new(Fx::ZERO, -Fx::from_int(14)), Vec2::new(Fx::ZERO, Fx::from_int(14)));
        let mut ar = standoff(rich.clone(), poor, pa, pb);
        run(&mut ar);
        assert_eq!(ar.result, Some(ArenaResult::TeamA));
        assert_eq!(ar.ended_by, Some("time"));
        assert!(ar.time >= TIME_LIMIT);
        let mut even = standoff(rich.clone(), rich, pa, pb);
        run(&mut even);
        assert_eq!(even.result, Some(ArenaResult::Draw));
    }

    #[test]
    fn battlefields_follow_their_biome() {
        for biome in Biome::ALL {
            let f = Battlefield::generate(biome, 7, 40);
            assert_eq!(f, Battlefield::generate(biome, 7, 40), "deterministic");
            assert_eq!(f.patches.is_empty(), biome == Biome::Open, "{biome:?}");
            for p in &f.patches {
                assert!(p.center.length() > p.radius + OBJECTIVE_RADIUS, "the shrine stays clear");
            }
        }
        let lava = Battlefield::generate(Biome::Lava, 7, 40);
        assert!(lava.patches.iter().any(|p| p.ground == Ground::Lava));
        let sea = Battlefield::generate(Biome::Ocean, 7, 40);
        assert!(sea.patches.iter().all(|p| p.ground == Ground::Water));
        assert!(Battlefield::radius_for(1000) > Battlefield::radius_for(40) * Fx::from_int(2));
    }

    #[test]
    fn lava_burns_walkers_and_biomes_replay() {
        let pool = sheets("frozen_moon", 1, 2400);
        let lava = Battlefield::generate(Biome::Lava, 11, 2);
        let pool_spot = lava.patches.iter().find(|p| p.ground == Ground::Lava).unwrap().center;
        let walker = pool.iter().find(|s| s.speed_fly == 0).unwrap().clone();
        let mut ar = Arena::on(vec![walker.clone()], vec![walker], 11, Biome::Lava);
        ar.units[0].pos = pool_spot;
        ar.command(ArenaCommand::Possess { team: 0, unit: Some(0) });
        let hp = ar.units[0].hp;
        for _ in 0..40 {
            ar.step();
        }
        assert!(ar.units[0].hp < hp, "standing in lava burns");

        let a = pool[0..3].to_vec();
        let b = pool[3..6].to_vec();
        let mut live = Arena::on(a.clone(), b.clone(), 4, Biome::Forest);
        run(&mut live);
        let again = Arena::replay_on(a, b, 4, Biome::Forest, &live.command_log);
        assert_eq!(again.state_hash(), live.state_hash());
        assert_eq!(again.result, live.result);
    }

    #[test]
    fn armies_of_five_hundred_a_side_finish() {
        let pool = sheets("earthlike", 2, 1600);
        let cheap: Vec<CharacterSheet> = pool.iter().rev().take(5).cloned().collect();
        let side = |k: usize| (0..500).map(|i| cheap[(i + k) % cheap.len()].clone()).collect::<Vec<_>>();
        let mut ar = Arena::on(side(0), side(2), 1, Biome::Plains);
        let start = std::time::Instant::now();
        run(&mut ar);
        assert!(ar.result.is_some());
        eprintln!("500 v 500: {:?} in {:.1?} ({} ticks)", ar.ended_by, start.elapsed(), ar.tick());
    }

    #[test]
    fn worlds_choose_their_battlefield() {
        let biome = |p: &str| {
            let mut w = World::new(1);
            for a in preset_actions(&w, p).unwrap() {
                w.apply(a);
            }
            w.apply(Action::Tick { ticks: 200 });
            w.arena_biome()
        };
        assert_eq!(biome("magma_world"), Biome::Lava);
        assert_eq!(biome("frozen_moon"), Biome::Ice);
        assert!(matches!(biome("earthlike"), Biome::Plains | Biome::Forest | Biome::Ocean), "{:?}", biome("earthlike"));
    }
}
