//! The archetype matcher (docs/GAME_DESIGN.md §4.4).

use sim_core::presets::preset_actions;
use sim_core::sheet::species_sheet;
use sim_core::{body, Action, World};

fn world(preset: &str, seed: u64, ticks: u32) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, preset).unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks });
    w
}

#[test]
fn classical_monsters_and_true_aliens_live_side_by_side() {
    let w = world("frozen_moon", 1, 4000);
    let sheets: Vec<_> = w.living_species().map(|s| (s, species_sheet(&w, s))).collect();
    let matched = sheets.iter().filter(|(_, sh)| sh.archetype.is_some()).count();
    assert!(matched > 0, "some beings match an archetype");
    assert!(matched * 4 < sheets.len(), "most stay alien: {matched} of {}", sheets.len());
    for (s, sh) in &sheets {
        let Some(a) = &sh.archetype else { continue };
        // Each archetype brings its signature ability.
        assert!(sh.traits.len() >= 2, "{a} has a signature trait");
        if a == "Dragon" {
            assert!(sh.breath.is_some() && sh.speed_fly > 0 && sh.frighten_dc.is_some());
        }
        if ["Elf", "Dwarf", "Orc", "Goblin", "Gnome", "Human", "Giant"].contains(&a.as_str()) {
            assert!(s.has(body::SAPIENCE), "{a} is a people");
        }
    }
}

#[test]
fn archetype_sheets_are_costed_with_their_signature() {
    let w = world("frozen_moon", 1, 4000);
    let s = w
        .living_species()
        .find(|s| species_sheet(&w, s).archetype.is_some())
        .expect("an archetype");
    let sh = species_sheet(&w, s);
    // The cost is computed after the signature ability is added.
    assert_eq!(sim_core::sheet::cost(&sh), sh.cost);
    assert_eq!(species_sheet(&w, s), sh, "deterministic");
}
