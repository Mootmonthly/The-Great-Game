//! Character sheets and cost (docs/GAME_DESIGN.md §5).

use sim_core::battle::{battle, win_rate};
use sim_core::presets::preset_actions;
use sim_core::sheet::{
    cost, species_sheet, Attack, Breath, CharacterSheet, CostBreakdown, DamageType, SizeCategory,
    DEX,
};
use sim_core::{Action, World};

fn run_preset(preset: &str, seed: u64, ticks: u32) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, preset).unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks });
    w
}

fn blank(name: &str, hp: i64, ac: i64, attacks: Vec<Attack>) -> CharacterSheet {
    CharacterSheet {
        name: name.into(),
        creature_type: "Humanoid".into(),
        size: SizeCategory::Medium,
        alignment: "Neutral".into(),
        abilities: [10; 6],
        armor_class: ac,
        hit_dice: 1,
        hit_points: hp,
        speed_walk: 30,
        speed_swim: 10,
        speed_fly: 0,
        speed_burrow: 0,
        proficiency: 2,
        senses: vec![],
        languages: vec![],
        resistances: vec![],
        immunities: vec![],
        vulnerabilities: vec![],
        attacks,
        breath: None,
        traits: vec![],
        regeneration: 0,
        pack_tactics: false,
        frighten_dc: None,
        class: None,
        equipment: vec![],
        cost: CostBreakdown::default(),
    }
}

/// Calibration anchors from §5.3: a commoner costs 1, an ancient-dragon-like
/// being about 250–350.
#[test]
fn cost_calibration_anchors() {
    let club = Attack {
        name: "Club".into(),
        to_hit: 2,
        dice: 1,
        die: 4,
        bonus: 0,
        damage: DamageType::Bludgeoning,
        uses: 1,
    };
    let commoner = blank("Commoner", 4, 10, vec![club]);
    assert_eq!(cost(&commoner).cost, 1);

    let bite = Attack {
        name: "Bite".into(),
        to_hit: 17,
        dice: 2,
        die: 10,
        bonus: 10,
        damage: DamageType::Piercing,
        uses: 1,
    };
    let claw = Attack {
        name: "Claw".into(),
        to_hit: 17,
        dice: 2,
        die: 6,
        bonus: 10,
        damage: DamageType::Slashing,
        uses: 2,
    };
    let mut dragon = blank("Ancient dragon", 546, 22, vec![bite, claw]);
    dragon.size = SizeCategory::Gargantuan;
    dragon.abilities = [30, 10, 29, 18, 15, 23];
    dragon.speed_fly = 80;
    dragon.immunities = vec![DamageType::Fire];
    dragon.senses = vec!["darkvision 120 ft.".into()];
    dragon.breath = Some(Breath {
        name: "Fire Breath".into(),
        dice: 26,
        damage: DamageType::Fire,
        save_ability: DEX,
        dc: 24,
        targets: 3,
    });
    let c = cost(&dragon).cost;
    println!("ancient dragon costs {c}");
    assert!((250..=350).contains(&c), "ancient dragon costs {c}");
}

#[test]
fn every_species_has_a_valid_sheet() {
    for preset in ["earthlike", "frozen_moon", "magma_world"] {
        let w = run_preset(preset, 1, 1600);
        for s in w.living_species() {
            let sh = species_sheet(&w, s);
            assert!((1..=1000).contains(&sh.cost.cost));
            assert!(sh.hit_points >= 1 && sh.armor_class >= 5);
            assert!(sh.abilities.iter().all(|a| (1..=40).contains(a)));
            assert!(!sh.attacks.is_empty());
            assert_eq!(sh, species_sheet(&w, s), "sheets are deterministic");
        }
    }
}

#[test]
fn magma_life_shrugs_off_fire() {
    let w = run_preset("magma_world", 1, 800);
    let s = w.living_species().max_by_key(|s| s.biomass).unwrap();
    let sh = species_sheet(&w, s);
    assert!(sh.immunities.contains(&DamageType::Fire));
    assert_eq!(
        sh.creature_type == "Ooze" || sh.creature_type == "Elemental",
        true,
        "{}",
        sh.creature_type
    );
}

#[test]
fn battles_are_deterministic_and_favour_the_stronger_side() {
    let w = run_preset("earthlike", 1, 2400);
    let mut sheets: Vec<CharacterSheet> =
        w.living_species().map(|s| species_sheet(&w, s)).collect();
    sheets.sort_by_key(|s| s.cost.cost);
    let weak = &sheets[0];
    let strong = sheets.last().unwrap();
    assert!(strong.cost.cost > weak.cost.cost * 5);
    assert_eq!(battle(&[strong], &[weak], 7), battle(&[strong], &[weak], 7));
    assert!(win_rate(&[strong], &[weak], 10, 1) > 0.9);
}
