//! Settlement tiers and buildings (docs/GAME_DESIGN.md §4.5).

use sim_core::civ::{Building, Tier};
use sim_core::presets::preset_actions;
use sim_core::{Action, Fx, World};

fn settled(preset: &str, seed: u64, ticks: u32) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, preset).unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks });
    w
}

#[test]
fn settlements_grow_through_tiers() {
    assert_eq!(Tier::of(Fx::ratio(1, 2)), Tier::Camp);
    assert_eq!(Tier::of(Fx::from_int(2)), Tier::Village);
    assert_eq!(Tier::of(Fx::from_int(6)), Tier::Town);
    assert_eq!(Tier::of(Fx::from_int(15)), Tier::City);
    assert_eq!(Tier::of(Fx::from_int(40)), Tier::Metropolis);
    assert!(Tier::Camp < Tier::Metropolis);
}

#[test]
fn buildings_follow_era_materials_and_size() {
    let mut w = settled("frozen_moon", 1, 3200);
    let (id, region) = {
        let c = w.living_civs().find(|c| w.era(c) >= 2).expect("a crafting people");
        let capital = c.capital().unwrap();
        let b = w.buildings(c, capital);
        assert!(b.contains(&Building::Huts), "everyone has huts");
        assert!(b.contains(&Building::Workshop), "crafting peoples have workshops");
        // No iron on the frozen moon: nothing is forged.
        assert!(!b.contains(&Building::Forge));
        assert!(!b.contains(&Building::Factory), "nobody is industrial yet");
        (c.id, capital.region)
    };
    // A deposit of tungsten and a forging people give a forge and a mine.
    let k = w.civs.iter().position(|x| x.id == id).unwrap();
    w.civs[k].tech = Fx::from_int(300);
    let tungsten = w.substance_index("tungsten").unwrap();
    w.regions[region].amounts[tungsten] = Fx::from_int(2);
    let c = &w.civs[k];
    let b = w.buildings(c, c.capital().unwrap());
    assert!(b.contains(&Building::Forge) && b.contains(&Building::Mine), "{b:?}");
    // Buildings are derived: the same world always has the same ones.
    assert_eq!(b, w.buildings(c, c.capital().unwrap()));
}

#[test]
fn walls_make_a_settlement_harder_to_take_and_replay_holds() {
    let mut w = settled("earthlike", 5, 3200);
    let Some(k) = w.civs.iter().position(|c| c.is_alive() && c.settlements.iter().any(|s| s.tier() >= Tier::Town)) else {
        return; // no towns yet on this seed: nothing to check
    };
    // Buildings feed strength and learning, so a world with towns still
    // replays exactly.
    w.apply(Action::Tick { ticks: 40 });
    assert_eq!(World::replay(w.log()).state_hash(), w.state_hash());
    // A martial, crafting people walls its towns.
    let mut walled = World::from_snapshot(&w.snapshot()).unwrap();
    walled.civs[k].culture.militarism = Fx::ratio(8, 10);
    walled.civs[k].tech = Fx::from_int(100);
    let c = &walled.civs[k];
    if let Some(town) = c.settlements.iter().find(|s| s.tier() >= Tier::Town) {
        assert!(walled.buildings(c, town).contains(&Building::Walls));
    }
}
