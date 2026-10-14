//! The Essence shop (docs/GAME_DESIGN.md §3): elements and moon slots
//! bought with Essence arrive as grants logged in the world.

use sim_core::equipment::loadout;
use sim_core::presets::preset_actions;
use sim_core::shop::{catalogue, ShopGrant, ShopItem, DEPOSIT_AMOUNT, MOON_PRICE, PLANET_PRICE};
use sim_core::world::WIDTH;
use sim_core::{Action, Fx, World};

fn preset(name: &str, seed: u64) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, name).unwrap() {
        w.apply(a);
    }
    w
}

fn buy(w: &mut World, item: ShopItem, region: usize) {
    let grant = ShopGrant {
        id: w.log().actions.len() as u64,
        account: "ann".into(),
        item,
        signature: String::new(),
    };
    w.apply(Action::Purchase {
        grant: Box::new(grant),
        x: (region % WIDTH) as u16,
        y: (region / WIDTH) as u16,
    });
}

fn deposit(key: &str) -> ShopItem {
    ShopItem::Deposit {
        substance: key.into(),
    }
}

#[test]
fn shop_elements_are_bought_not_conjured() {
    let mut w = preset("earthlike", 1);
    let gold = w.substance_index("gold").unwrap();
    w.apply(Action::AddSubstanceGlobal {
        substance: gold as u16,
        amount: Fx::ONE,
    });
    assert!(w.regions.iter().all(|r| r.amounts[gold] == Fx::ZERO), "the free tools cannot add gold");
    let here = 16 * WIDTH + 20;
    buy(&mut w, deposit("gold"), here);
    assert_eq!(w.regions[here].amounts[gold], DEPOSIT_AMOUNT);
    assert_eq!(w.regions[0].amounts[gold], Fx::ZERO, "a deposit is local");
    // Iron is not a shop element: it stays free.
    buy(&mut w, deposit("iron"), here);
    let iron = w.substance_index("iron").unwrap();
    assert!(w.regions[here].amounts[iron] < DEPOSIT_AMOUNT);
    assert_eq!(World::replay(w.log()).state_hash(), w.state_hash());
}

#[test]
fn the_catalogue_lists_elements_moons_and_planets() {
    let w = World::new(1);
    let items = catalogue(&w);
    let price = |item: &ShopItem| items.iter().find(|(i, _, _)| i == item).map(|(_, _, p)| *p);
    assert_eq!(price(&ShopItem::MoonSlot), Some(MOON_PRICE));
    assert_eq!(price(&ShopItem::PlanetSlot), Some(PLANET_PRICE));
    for key in ["gold", "tungsten", "rare_earths", "uranium", "thorium"] {
        assert!(price(&deposit(key)).is_some(), "{key} is for sale");
    }
    assert_eq!(price(&deposit("water")), None);
    assert_eq!(deposit("water").price(&w), None);
    assert_eq!(items.len(), 7);
}

#[test]
fn a_bought_moon_slot_allows_a_second_moon() {
    let mut w = preset("earthlike", 2);
    let add = |w: &mut World, d: i64| {
        w.apply(Action::AddMoon {
            mass: Fx::ONE,
            distance: Fx::from_int(d),
        })
    };
    add(&mut w, 1);
    add(&mut w, 2);
    assert_eq!(w.moon_worlds.len(), 1);
    buy(&mut w, ShopItem::MoonSlot, 0);
    add(&mut w, 2);
    assert_eq!(w.moon_worlds.len(), 2);
    assert_eq!(w.planet.moon_slots, 2);
}

#[test]
fn radioactive_deposits_heat_and_irradiate() {
    let mut w = preset("earthlike", 3);
    let here = 16 * WIDTH + 30;
    let before = w.regions[here].temperature;
    buy(&mut w, deposit("uranium"), here);
    assert!(w.radioactivity(here) > Fx::ONE);
    assert!(w.regions[here].temperature > before + Fx::from_int(10));
    assert_eq!(w.radioactivity(0), Fx::ZERO);
}

#[test]
fn metals_and_rare_earths_advance_civilizations() {
    // The frozen moon has no iron: its peoples stop before forging.
    let mut w = preset("frozen_moon", 1);
    w.apply(Action::Tick { ticks: 3200 });
    let k = w.civs.iter().position(|c| c.is_alive()).expect("a people");
    let home = w.civs[k].settlements[0].region;
    w.civs[k].tech = Fx::from_int(300);
    assert!(w.era(&w.civs[k]) < sim_core::civ::FORGING);
    buy(&mut w, deposit("tungsten"), home);
    assert_eq!(w.era(&w.civs[k]), sim_core::civ::FORGING, "tungsten can be forged");
    let s = w.species_by_id(w.civs[k].species).unwrap();
    assert!(loadout(&w, s).iter().any(|g| g.name.contains("ungsten")));
    // Rare earths speed invention.
    let tech = w.civs[k].tech;
    let mut plain = World::from_snapshot(&w.snapshot()).unwrap();
    buy(&mut w, deposit("rare_earths"), home);
    w.apply(Action::Tick { ticks: 40 });
    plain.apply(Action::Tick { ticks: 40 });
    let (gain, plain_gain) = (w.civs[k].tech - tech, plain.civs[k].tech - tech);
    assert!(gain > plain_gain, "{gain:?} vs {plain_gain:?}");
}
