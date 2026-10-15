//! Gear looting and refitting (docs/GAME_DESIGN.md §5.4).

use sim_core::equipment::{gear_of, loadout, BodyPlan, Slot};
use sim_core::loot::{LootGrant, Remains};
use sim_core::presets::preset_actions;
use sim_core::sheet::individual_sheet;
use sim_core::{Action, Fx, World};

/// A frozen moon with a Crafting-era people, and its best-armed member.
fn armed_world() -> (World, u32) {
    let mut w = World::new(1);
    for a in preset_actions(&w, "frozen_moon").unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks: 3200 });
    let civ = w.living_civs().find(|c| w.era(c) >= 2).expect("a crafting people");
    let species = civ.species;
    let hero = w
        .living_individuals()
        .find(|x| x.species == species)
        .expect("a named member")
        .id;
    (w, hero)
}

/// A grant carrying one of `from`'s own items, as the server would sign.
fn spoil(w: &World, from: &str, id: u64) -> LootGrant {
    let s = w.living_species().max_by_key(|s| s.biomass).unwrap();
    let gear = loadout(w, s);
    LootGrant {
        id,
        account: "ann".into(),
        from: from.into(),
        remains: Remains {
            name: s.name.clone(),
            profile: s.profile,
            genome: s.genome.clone(),
            color: s.color,
        },
        biomass: Fx::ONE,
        value: 10,
        gear,
        signature: String::new(),
    }
}

#[test]
fn looted_gear_fills_the_armoury_and_arms_a_matching_body() {
    let (mut w, hero) = armed_world();
    let species = w.individual_by_id(hero).unwrap().species;
    let s = w.species_by_id(species).unwrap().clone();
    let grant = spoil(&w, "Rival", 1);
    assert!(!grant.gear.is_empty(), "the fallen carried gear");
    let (x, y) = w.best_region_for(&grant.remains.profile);
    w.apply(Action::Loot { grant: Box::new(grant.clone()), x, y });
    assert_eq!(w.armoury.len(), grant.gear.len());
    assert!(w.armoury.iter().all(|l| l.holder.is_none() && l.from == "Rival"));
    // Made for the same kind: it fits as it is.
    let plan = BodyPlan::of_species(&s);
    let item = w.armoury.iter().find(|l| l.item.fits(&l.made_for, &plan)).expect("something fits").id;
    let before = gear_of(&w, &s, w.individual_by_id(hero)).len();
    w.apply(Action::Equip { item, individual: hero });
    assert_eq!(w.armoury.iter().find(|l| l.id == item).unwrap().holder, Some(hero));
    assert_eq!(gear_of(&w, &s, w.individual_by_id(hero)).len(), before + 1);
    let sheet = individual_sheet(&w, w.individual_by_id(hero).unwrap()).unwrap();
    assert_eq!(sheet.equipment.len(), before + 1);
    w.apply(Action::Unequip { item });
    assert_eq!(w.armoury.iter().find(|l| l.id == item).unwrap().holder, None);
    assert_eq!(World::replay(w.log()).state_hash(), w.state_hash());
}

#[test]
fn ill_fitting_gear_must_be_refitted_which_takes_years() {
    let (mut w, hero) = armed_world();
    let species = w.individual_by_id(hero).unwrap().species;
    let s = w.species_by_id(species).unwrap().clone();
    let mut grant = spoil(&w, "Giant", 2);
    // Armour shaped for a different plan: a huge, eight-limbed body.
    grant.gear.retain(|g| g.slot == Slot::Body);
    assert_eq!(grant.gear.len(), 1);
    let (x, y) = w.best_region_for(&grant.remains.profile);
    w.apply(Action::Loot { grant: Box::new(grant), x, y });
    let item = w.armoury.last().unwrap().id;
    let huge = BodyPlan {
        size: sim_core::sheet::SizeCategory::Huge,
        limbs: 8,
        ..BodyPlan::of_species(&s)
    };
    w.armoury.last_mut().unwrap().made_for = huge;
    let plan = BodyPlan::of_species(&s);
    assert!(!w.armoury.last().unwrap().item.fits(&huge, &plan));
    w.apply(Action::Equip { item, individual: hero });
    assert_eq!(w.armoury.last().unwrap().holder, None, "it does not fit, so it is refused");
    let base = gear_of(&w, &s, w.individual_by_id(hero)).len();
    w.apply(Action::Refit { item, individual: hero });
    let l = w.armoury.last().unwrap();
    assert_eq!(l.holder, Some(hero));
    assert_eq!(l.made_for, plan);
    let until = l.refit_until.expect("being refitted");
    assert!(until > w.tick);
    assert_eq!(gear_of(&w, &s, w.individual_by_id(hero)).len(), base, "useless until refitted");
    w.apply(Action::Tick { ticks: (until - w.tick) as u32 });
    if w.individual_by_id(hero).unwrap().is_alive() {
        assert_eq!(gear_of(&w, &s, w.individual_by_id(hero)).len(), base + 1, "refitted gear counts");
    } else {
        assert_eq!(w.armoury.last().unwrap().holder, None, "the dead drop their gear");
    }
}

#[test]
fn the_dead_drop_their_gear_and_the_fallen_lose_it() {
    let (mut w, hero) = armed_world();
    let grant = spoil(&w, "Rival", 3);
    let (x, y) = w.best_region_for(&grant.remains.profile);
    w.apply(Action::Loot { grant: Box::new(grant), x, y });
    let species = w.individual_by_id(hero).unwrap().species;
    let plan = BodyPlan::of_species(w.species_by_id(species).unwrap());
    let item = w.armoury.iter().find(|l| l.item.fits(&l.made_for, &plan)).unwrap().id;
    w.apply(Action::Equip { item, individual: hero });
    let n = w.armoury.len();
    w.apply(Action::ChampionFell { individual: hero });
    assert_eq!(w.armoury.len(), n - 1, "the winner took it");
    assert!(w.armoury.iter().all(|l| l.holder != Some(hero)));
}
