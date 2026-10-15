//! Religions (docs/GAME_DESIGN.md §4.8 level 6).

use sim_core::presets::preset_actions;
use sim_core::religion::{Character, Deity};
use sim_core::world::{TICKS_PER_YEAR, WIDTH};
use sim_core::{Action, Fx, World};

fn civ_world() -> World {
    let mut w = World::new(1);
    for a in preset_actions(&w, "frozen_moon").unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks: 3200 });
    w
}

fn capital(w: &World) -> (usize, u16, u16) {
    let k = w.civs.iter().position(|c| c.is_alive() && c.faith.is_none()).expect("a faithless people");
    let r = w.civs[k].settlements[0].region;
    (k, (r % WIDTH) as u16, (r / WIDTH) as u16)
}

#[test]
fn gifts_from_the_sky_found_a_faith_in_the_maker() {
    let mut w = civ_world();
    let (k, x, y) = capital(&w);
    let water = w.substance_index("water").unwrap() as u16;
    for _ in 0..6 {
        w.apply(Action::AddSubstance { x, y, radius: 1, substance: water, amount: Fx::ONE });
    }
    assert!(w.civs[k].awe > w.civs[k].dread);
    w.apply(Action::Tick { ticks: TICKS_PER_YEAR as u32 });
    let faith = w.civs[k].faith.and_then(|f| w.religion(f)).expect("a faith");
    assert_eq!(faith.deity, Deity::Maker);
    assert_eq!(faith.character, Character::Benevolent);
    assert_eq!(World::replay(w.log()).state_hash(), w.state_hash());
}

#[test]
fn fire_from_the_sky_breeds_a_fearful_faith() {
    let mut w = civ_world();
    let (k, x, y) = capital(&w);
    // Fire, then frost: terrifying, but the land ends as it was.
    for d in [40, -40, 40, -40] {
        w.apply(Action::HeatRegion { x, y, radius: 1, delta: Fx::from_int(d) });
    }
    assert!(w.civs[k].dread > w.civs[k].awe);
    w.apply(Action::Tick { ticks: TICKS_PER_YEAR as u32 });
    let faith = w.civs[k].faith.and_then(|f| w.religion(f)).expect("a faith");
    assert_eq!(faith.deity, Deity::Maker);
    assert_eq!(faith.character, Character::Wrathful);
}

#[test]
fn peoples_find_gods_of_their_own_and_share_them() {
    let mut w = World::new(5);
    for a in preset_actions(&w, "earthlike").unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks: 4000 });
    let living: Vec<_> = w.living_civs().collect();
    assert!(living.iter().any(|c| c.faith.is_some()), "untouched peoples still find faith");
    for c in &living {
        if let Some(r) = c.faith.and_then(|f| w.religion(f)) {
            assert_ne!(r.deity, Deity::Maker, "no miracles were worked here");
        }
    }
}
