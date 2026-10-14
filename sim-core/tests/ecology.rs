//! Food chain (docs/GAME_DESIGN.md §4.4): plants hold the light niche,
//! animals graze them, and sapience pulls bodies towards a humanoid plan.

use sim_core::body::{Body, PartKind, LIMBS, MULTICELLULAR, NERVOUS, SAPIENCE};
use sim_core::presets::preset_actions;
use sim_core::rng::Rng;
use sim_core::{body, Action, Fx, World};

#[test]
fn plants_persist_beside_the_animals_that_graze_them() {
    let mut w = World::new(1);
    for a in preset_actions(&w, "earthlike").unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks: 1600 });
    let biomass = |plants: bool| {
        w.living_species()
            .filter(|s| s.has(MULTICELLULAR) && s.has(NERVOUS) != plants)
            .fold(Fx::ZERO, |a, s| a + s.biomass)
    };
    let (plants, animals) = (biomass(true), biomass(false));
    assert!(plants > Fx::from_int(1000), "plants {plants:?}");
    assert!(animals > Fx::from_int(1000), "animals {animals:?}");
    assert!(plants * Fx::from_int(3) > animals, "plants {plants:?} animals {animals:?}");
    // Plants are named as plants; animals that do not hunt graze.
    let plant = w
        .living_species()
        .find(|s| s.has(MULTICELLULAR) && !s.has(NERVOUS) && s.profile.energy == sim_core::life::EnergyKind::Light)
        .unwrap();
    let d = plant.description(&w);
    assert!(d.ends_with("Plant") || d.ends_with("Bloom"), "{d}");
}

#[test]
fn sapience_pulls_bodies_towards_a_humanoid_plan() {
    let mut body = Body::default();
    body.grow(PartKind::Segment, 5, Fx::ONE, None);
    body.grow(PartKind::Limb, 8, Fx::ONE, None);
    body.grow(PartKind::Eye, 6, Fx::ONE, None);
    body.grow(PartKind::Fin, 2, Fx::ONE, None);
    body.grow(PartKind::Tentacle, 2, Fx::ONE, None);
    assert!(!body.is_humanoid());
    let mut rng = Rng::new(3);
    for _ in 0..30 {
        body.humanize(&mut rng, MULTICELLULAR | NERVOUS | LIMBS | SAPIENCE, Fx::HALF);
    }
    assert!(body.is_humanoid(), "{body:?}");
    assert_eq!(body.count(PartKind::Eye), 2);
    // Without limbs it cannot grow any: tentacled peoples stay tentacled.
    let mut squid = Body::default();
    squid.grow(PartKind::Tentacle, 4, Fx::ONE, None);
    for _ in 0..30 {
        squid.humanize(&mut rng, MULTICELLULAR | NERVOUS | body::SAPIENCE, Fx::HALF);
    }
    assert_eq!(squid.count(PartKind::Limb), 0);
    assert_eq!(squid.count(PartKind::Tentacle), 4);
}
