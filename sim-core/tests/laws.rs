//! Metaphysical laws (docs/GAME_DESIGN.md §4.6) and earned classes (§5.5).

use sim_core::individual::{Memory, MemoryKind};
use sim_core::presets::preset_actions;
use sim_core::sheet::{class_of, individual_sheet, Class};
use sim_core::{body, laws, Action, Fx, World};

fn frozen_moon(seed: u64) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, "frozen_moon").unwrap() {
        w.apply(a);
    }
    w
}

fn set(w: &mut World, law: u8, percent: i64) {
    w.apply(Action::SetLaw {
        law,
        value: Fx::ratio(percent, 100),
    });
}

#[test]
fn laws_at_zero_change_nothing() {
    let mut plain = frozen_moon(1);
    let mut zeroed = frozen_moon(1);
    for law in [laws::ARCANE, laws::SOUL, laws::QI] {
        set(&mut zeroed, law, 0);
    }
    plain.apply(Action::Tick { ticks: 400 });
    zeroed.apply(Action::Tick { ticks: 400 });
    assert_eq!(plain.state_hash(), zeroed.state_hash());
}

#[test]
fn arcane_magic_breeds_spellcasters_and_thins_the_veil() {
    let mut w = frozen_moon(1);
    set(&mut w, laws::ARCANE, 100);
    w.apply(Action::Tick { ticks: 1200 });
    let casters: Vec<_> = w
        .living_species()
        .filter(|s| s.has(body::SPELLCASTING))
        .collect();
    assert!(!casters.is_empty(), "spellcasting evolves where mana runs high");
    let sheet = sim_core::sheet::species_sheet(&w, casters[0]);
    assert!(sheet.attacks.iter().any(|a| a.name == "Mana Bolt"));
    // Ley-line convergence thins the Veil, but magic alone does not open it.
    assert!(w.veil_min() < Fx::ratio(9, 10));
    assert!(w.veil_min() > sim_core::veil::BREACH_THRESHOLD);
    assert!((0..sim_core::world::REGION_COUNT).any(|i| w.mana(i) > Fx::ratio(8, 10)));
}

#[test]
fn souls_are_reborn_under_soul_power() {
    let mut w = frozen_moon(1);
    set(&mut w, laws::SOUL, 100);
    w.apply(Action::Tick { ticks: 1200 });
    let reborn: Vec<_> = w
        .living_individuals()
        .filter(|i| i.past_life.is_some())
        .collect();
    assert!(!reborn.is_empty());
    let r = reborn[0];
    assert!(r.soul > Fx::ZERO);
    assert!(r.memories.iter().any(|m| m.kind == MemoryKind::Reborn));
    let sheet = individual_sheet(&w, r).unwrap();
    assert!(sheet.traits.iter().any(|t| t.name == "Old Soul"));
}

#[test]
fn cultivators_break_through_and_tribulations_kill() {
    let realms = |trib: i64| {
        let mut w = frozen_moon(1);
        set(&mut w, laws::QI, 100);
        set(&mut w, laws::TRIBULATION, trib);
        w.apply(Action::Tick { ticks: 1600 });
        let deaths = w
            .individuals
            .iter()
            .filter(|i| i.cause_of_death.as_deref() == Some("perished in a heavenly tribulation"))
            .count();
        (w.cultivators(1), deaths, w)
    };
    let (safe, safe_deaths, w) = realms(0);
    assert!(safe > 0, "individuals reach the first realm");
    assert_eq!(safe_deaths, 0);
    let c = w.living_individuals().find(|i| i.realm >= 1).unwrap();
    let sheet = individual_sheet(&w, c).unwrap();
    assert!(sheet.attacks.iter().any(|a| a.name == "Qi Strike"));
    assert!(sheet.class.as_deref().unwrap().starts_with("Cultivator"));
    let (_, deadly_deaths, _) = realms(100);
    assert!(deadly_deaths > 0, "deadly tribulations kill cultivators");
}

#[test]
fn classes_are_earned_from_life_stories() {
    let mut w = frozen_moon(1);
    w.apply(Action::Tick { ticks: 800 });
    let ind = w.living_individuals().next().unwrap().clone();
    let species = w.species_by_id(ind.species).unwrap().clone();
    let with = |kinds: &[MemoryKind]| {
        let mut i = ind.clone();
        i.memories = kinds
            .iter()
            .map(|&kind| Memory {
                tick: 0,
                kind,
                other: None,
            })
            .collect();
        i
    };
    let fighter = with(&[MemoryKind::Defeated, MemoryKind::Killed, MemoryKind::Defeated]);
    assert_eq!(class_of(&w, &species, &fighter, 10, 10), Some(Class::Fighter));
    let rogue = with(&[MemoryKind::Fled, MemoryKind::Fled]);
    assert_eq!(class_of(&w, &species, &rogue, 10, 10), Some(Class::Rogue));
    let nobody = with(&[]);
    assert_eq!(class_of(&w, &species, &nobody, 18, 18), None);

    // Magic classes need the law.
    let mut scholar = nobody.clone();
    scholar.personality.curiosity = Fx::ONE;
    let mut sapient = species.clone();
    sapient.genome.milestones |= body::SAPIENCE;
    assert_eq!(class_of(&w, &sapient, &scholar, 16, 10), None);
    set(&mut w, laws::ARCANE, 50);
    assert_eq!(class_of(&w, &sapient, &scholar, 16, 10), Some(Class::Wizard));
    let mut caster = species.clone();
    caster.genome.milestones |= body::SPELLCASTING;
    assert_eq!(class_of(&w, &caster, &nobody, 8, 14), Some(Class::Sorcerer));
    let horror = with(&[MemoryKind::WitnessedHorror]);
    assert_eq!(class_of(&w, &species, &horror, 10, 10), Some(Class::Warlock));
}

#[test]
fn laws_replay_identically() {
    let mut w = frozen_moon(2);
    for law in [laws::ARCANE, laws::SOUL, laws::QI] {
        set(&mut w, law, 80);
    }
    w.apply(Action::Tick { ticks: 600 });
    assert_eq!(World::replay(w.log()).state_hash(), w.state_hash());
    let snap = World::from_snapshot(&w.snapshot()).unwrap();
    assert_eq!(snap.state_hash(), w.state_hash());
}
