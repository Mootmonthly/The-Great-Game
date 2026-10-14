//! The Veil and extradimensional beings (docs/GAME_DESIGN.md §4.4a).

use sim_core::presets::preset_actions;
use sim_core::sheet::species_sheet;
use sim_core::star::StarType;
use sim_core::veil::BREACH_THRESHOLD;
use sim_core::{body, Action, Fx, World};

fn earthlike(seed: u64, years: u32) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, "earthlike").unwrap() {
        w.apply(a);
    }
    w.apply(Action::Tick { ticks: years * 4 });
    w
}

fn entities(w: &World) -> usize {
    w.living_species()
        .filter(|s| s.has(body::OTHERWORLDLY))
        .count()
}

fn ever(w: &World) -> usize {
    w.species
        .iter()
        .filter(|s| s.has(body::OTHERWORLDLY))
        .count()
}

#[test]
fn an_ordinary_world_stays_sealed() {
    let w = earthlike(1, 300);
    assert_eq!(w.veil_min(), Fx::ONE);
    assert_eq!(ever(&w), 0);
}

#[test]
fn an_open_veil_lets_things_through() {
    let mut w = earthlike(2, 150);
    w.apply(Action::SetVeilLaw { openness: Fx::ONE });
    w.apply(Action::Tick { ticks: 120 });
    assert!(w.veil_min() < BREACH_THRESHOLD);
    assert!(w.last_breach_tick.is_some());
    assert!(entities(&w) > 0);
    for s in w.living_species().filter(|s| s.has(body::OTHERWORLDLY)) {
        assert!(s.genome.body.count(body::PartKind::Tendril) > 0);
        let sheet = species_sheet(&w, s);
        assert_eq!(sheet.creature_type, "Aberration");
        assert!(sheet.frighten_dc.is_some());
        assert!(sheet.attacks.iter().any(|a| a.name == "Mind Lash"));
        assert!((1..=1000).contains(&sheet.cost.cost));
    }
}

#[test]
fn beings_from_beyond_fade_when_the_veil_is_sealed_again() {
    let mut w = earthlike(3, 150);
    w.apply(Action::SetVeilLaw { openness: Fx::ONE });
    w.apply(Action::Tick { ticks: 120 });
    assert!(entities(&w) > 0);
    w.apply(Action::SetVeilLaw { openness: Fx::ZERO });
    w.apply(Action::Tick { ticks: 200 });
    assert_eq!(entities(&w), 0);
    assert!(w.veil_min() > Fx::ratio(9, 10));
}

#[test]
fn they_feed_on_minds() {
    let nervous = |w: &World| {
        w.living_species()
            .filter(|s| s.has(body::NERVOUS) && !s.has(body::OTHERWORLDLY))
            .fold(Fx::ZERO, |a, s| a + s.biomass)
    };
    let mut calm = earthlike(4, 200);
    let mut haunted = earthlike(4, 200);
    haunted.apply(Action::SetVeilLaw { openness: Fx::ONE });
    calm.apply(Action::Tick { ticks: 600 });
    haunted.apply(Action::Tick { ticks: 600 });
    assert!(
        nervous(&haunted) < nervous(&calm) * Fx::ratio(9, 10),
        "{:?} vs {:?}",
        nervous(&haunted),
        nervous(&calm)
    );
}

#[test]
fn physics_alone_can_thin_the_veil() {
    // Natural neutron star: thinner, but still holding.
    let mut natural = earthlike(5, 0);
    natural.apply(Action::SetStarType {
        star: StarType::NeutronStar as u8,
    });
    natural.apply(Action::Tick { ticks: 40 });
    assert!(natural.veil_min() < Fx::ratio(8, 10));
    assert!(natural.veil_min() > BREACH_THRESHOLD);

    // Godhand: a neutron star shining like the Sun breaks physics badly.
    let mut god = earthlike(5, 0);
    god.apply(Action::SetGodhand { on: true });
    god.apply(Action::SetStarType {
        star: StarType::NeutronStar as u8,
    });
    god.apply(Action::SetStarLuminosity { suns: Fx::ONE });
    god.apply(Action::Tick { ticks: 200 });
    assert_eq!(god.veil_law, Fx::ZERO);
    assert!(god.veil_min() < BREACH_THRESHOLD);
    assert!(ever(&god) > 0);
}

#[test]
fn many_moons_thin_the_veil() {
    let mut w = earthlike(6, 0);
    w.planet.moon_slots = 6; // Bought with Essence.
    for k in 0..6 {
        w.apply(Action::AddMoon {
            mass: Fx::ratio(1, 10),
            distance: Fx::ratio(5 + k * 2, 10),
        });
    }
    w.apply(Action::Tick { ticks: 40 });
    assert!(w.veil_thinning() > Fx::ratio(15, 100));
    assert!(w.veil_min() < Fx::ONE);
}

#[test]
fn veil_worlds_replay_identically() {
    let mut w = earthlike(7, 100);
    w.apply(Action::SetVeilLaw {
        openness: Fx::ratio(9, 10),
    });
    w.apply(Action::Tick { ticks: 100 });
    let replayed = World::replay(w.log());
    assert_eq!(replayed.state_hash(), w.state_hash());
}

#[test]
fn maddening_presence_frightens_arena_foes() {
    use sim_core::arena::Arena;
    let mut w = earthlike(2, 150);
    w.apply(Action::SetVeilLaw { openness: Fx::ONE });
    w.apply(Action::Tick { ticks: 120 });
    let horror = w
        .living_species()
        .find(|s| s.has(body::OTHERWORLDLY))
        .map(|s| species_sheet(&w, s))
        .unwrap();
    let natives: Vec<_> = w
        .living_species()
        .filter(|s| s.has(body::NERVOUS) && !s.has(body::OTHERWORLDLY))
        .take(4)
        .map(|s| species_sheet(&w, s))
        .collect();
    let mut arena = Arena::new(vec![horror], natives, 9);
    let mut frightened = false;
    for _ in 0..600 {
        arena.step();
        frightened |= arena.units.iter().any(|u| u.team == 1 && u.frightened);
    }
    assert!(frightened);
}
