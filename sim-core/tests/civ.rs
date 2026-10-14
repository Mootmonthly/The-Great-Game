//! Civilizations (docs/GAME_DESIGN.md §4.5) and equipment (§5.4).

use sim_core::equipment::loadout;
use sim_core::individual::{Memory, MemoryKind};
use sim_core::presets::preset_actions;
use sim_core::sheet::{class_of, species_sheet, Class};
use sim_core::{body, Action, World};
use std::sync::OnceLock;

/// A frozen moon after 800 years: sapient peoples, settlements, a war.
fn world() -> &'static World {
    static W: OnceLock<World> = OnceLock::new();
    W.get_or_init(|| {
        let mut w = World::new(1);
        for a in preset_actions(&w, "frozen_moon").unwrap() {
            w.apply(a);
        }
        w.apply(Action::Tick { ticks: 3200 });
        w
    })
}

#[test]
fn sapient_species_found_civilizations() {
    let w = world();
    assert!(w.living_civs().count() > 0);
    for c in w.living_civs() {
        let s = w.species_by_id(c.species).unwrap();
        assert!(s.has(body::SAPIENCE), "only sapient species found peoples");
        assert!(!c.settlements.is_empty());
        for st in &c.settlements {
            assert!(
                w.regions[st.region].populations.iter().any(|p| p.species == c.species),
                "settlements stand where the people live"
            );
        }
        // No two peoples share a region.
        for o in w.living_civs().filter(|o| o.id != c.id) {
            assert!(!o.settlements.iter().any(|x| c.settlements.iter().any(|y| y.region == x.region)));
        }
    }
    assert!(w.civs.iter().map(|c| c.battles_won + c.battles_lost).sum::<u32>() > 0, "peoples go to war");
}

#[test]
fn civilizations_arm_their_people_from_their_lands() {
    let w = world();
    let armed: Vec<_> = w.living_civs().filter(|c| w.era(c) >= 1).collect();
    assert!(!armed.is_empty(), "some people has left the Primitive era");
    let c = armed[0];
    let s = w.species_by_id(c.species).unwrap();
    let gear = loadout(w, s);
    assert!(gear.iter().any(|g| g.armor > 0), "armour");
    // This moon has no iron: nothing is forged from it.
    assert!(!gear.iter().any(|g| g.name.to_lowercase().contains("iron")));
    let sheet = species_sheet(w, s);
    assert_eq!(sheet.equipment.len(), gear.len());
    assert!(!sheet.equipment.is_empty());
    // Beings without a civilization carry nothing.
    let wild = w
        .living_species()
        .find(|s| w.civ_of_species(s.id).is_none())
        .unwrap();
    assert!(loadout(w, wild).is_empty());
}

#[test]
fn war_veterans_become_fighters() {
    let w = world();
    let ind = w.living_individuals().next().unwrap().clone();
    let species = w.species_by_id(ind.species).unwrap();
    let mut vet = ind.clone();
    vet.memories = vec![
        Memory {
            tick: 0,
            kind: MemoryKind::FoughtInWar,
            other: None,
        };
        3
    ];
    assert_eq!(class_of(w, species, &vet, 10, 10), Some(Class::Fighter));
}

#[test]
fn civilizations_replay_identically() {
    let w = world();
    assert_eq!(World::replay(w.log()).state_hash(), w.state_hash());
    assert_eq!(World::from_snapshot(&w.snapshot()).unwrap().state_hash(), w.state_hash());
}
