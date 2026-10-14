//! Natural and Godhand modes and star types (docs/GAME_DESIGN.md §4.6).

use sim_core::presets::preset_actions;
use sim_core::star::StarType;
use sim_core::{Action, Fx, World};

fn earthlike(seed: u64) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, "earthlike").unwrap() {
        w.apply(a);
    }
    w
}

fn air(w: &World) -> Fx {
    w.atmosphere.iter().fold(Fx::ZERO, |a, &x| a + x)
}

fn biomass(w: &World) -> Fx {
    w.living_species().fold(Fx::ZERO, |a, s| a + s.biomass)
}

fn close(a: Fx, b: Fx, tolerance: Fx) -> bool {
    (a - b).abs() <= tolerance
}

#[test]
fn natural_gravity_follows_mass_and_radius() {
    let mut w = earthlike(1);
    assert!(!w.planet.godhand);
    w.apply(Action::SetPlanetRadius {
        earths: Fx::from_int(2),
    });
    // Same mass, twice the radius: a quarter of the gravity.
    assert!(close(w.planet.gravity, Fx::ratio(1, 4), Fx::ratio(1, 100)));
    // Asking for gravity in Natural mode changes the planet's mass instead.
    w.apply(Action::SetGravity { g: Fx::ONE });
    assert!(close(w.planet.gravity, Fx::ONE, Fx::ratio(1, 100)));
    assert!(close(w.planet.planet_mass, Fx::from_int(4), Fx::ratio(5, 100)));
    assert_eq!(w.planet.strain(), Fx::ZERO);
}

#[test]
fn natural_luminosity_follows_star_type_and_mass() {
    let mut w = earthlike(1);
    w.apply(Action::SetStarType {
        star: StarType::RedDwarf as u8,
    });
    assert_eq!(w.planet.star_type, StarType::RedDwarf);
    assert!(w.planet.star_luminosity < Fx::ratio(5, 100));
    // A brighter request is capped by what a red dwarf can be.
    w.apply(Action::SetStarLuminosity { suns: Fx::ONE });
    assert!(w.planet.star_luminosity < Fx::ratio(2, 10));
    assert!(w.planet.star_mass <= StarType::RedDwarf.info().max_mass);
    // Heavier main-sequence star: much brighter.
    w.apply(Action::SetStarType {
        star: StarType::YellowDwarf as u8,
    });
    w.apply(Action::SetStarMass {
        solar: Fx::ratio(12, 10),
    });
    assert!(w.planet.star_luminosity > Fx::ratio(17, 10));
    // Farther or lighter stars mean longer years.
    w.apply(Action::SetStarDistance {
        au: Fx::from_int(4),
    });
    assert!(w.planet.year_length() > Fx::from_int(7));
}

#[test]
fn godhand_allows_impossible_values_at_a_cost() {
    let mut natural = earthlike(3);
    let mut god = earthlike(3);
    god.apply(Action::SetGodhand { on: true });
    for w in [&mut natural, &mut god] {
        w.apply(Action::SetStarType {
            star: StarType::RedDwarf as u8,
        });
        w.apply(Action::SetStarLuminosity { suns: Fx::ONE });
        w.apply(Action::SetGravity {
            g: Fx::ratio(2, 10),
        });
    }
    // Godhand keeps the impossible star; Natural does what physics allows.
    assert_eq!(god.planet.star_luminosity, Fx::ONE);
    assert!(natural.planet.star_luminosity < Fx::ratio(2, 10));
    assert_eq!(god.planet.gravity, Fx::ratio(2, 10));
    assert!(god.planet.strain() > Fx::from_int(3));
    assert_eq!(natural.planet.strain(), Fx::ZERO);
    assert!(god.reality_strain() >= god.planet.strain());

    // Strain bleeds the atmosphere away over time.
    let before = air(&god);
    god.apply(Action::Tick { ticks: 40 });
    assert!(air(&god) < before * Fx::ratio(9, 10), "{:?} -> {:?}", before, air(&god));
}

#[test]
fn distant_moons_escape_in_natural_but_not_godhand() {
    let mut natural = earthlike(4);
    let mut god = earthlike(4);
    god.apply(Action::SetGodhand { on: true });
    let far = natural.planet.moon_limit() * Fx::from_int(3);
    for w in [&mut natural, &mut god] {
        w.apply(Action::AddMoon {
            mass: Fx::ONE,
            distance: far,
        });
    }
    assert!(natural.planet.moons.is_empty());
    assert_eq!(god.planet.moons.len(), 1);
    assert!(god.planet.strain() > Fx::ZERO);
    // Switching back to Natural lets it go.
    god.apply(Action::SetGodhand { on: false });
    assert!(god.planet.moons.is_empty());
    assert_eq!(god.planet.strain(), Fx::ZERO);
}

#[test]
fn red_dwarf_flares_strip_the_atmosphere() {
    let mut w = earthlike(5);
    w.apply(Action::SetStarType {
        star: StarType::RedDwarf as u8,
    });
    // Close in, so the planet stays warm.
    w.apply(Action::SetStarDistance {
        au: Fx::ratio(12, 100),
    });
    let before = air(&w);
    w.apply(Action::Tick { ticks: 200 });
    assert!(w.planet.last_flare_tick.is_some());
    assert!(air(&w) < before * Fx::ratio(8, 10), "{:?} -> {:?}", before, air(&w));
}

#[test]
fn neutron_star_radiation_harms_life_unless_the_air_is_thick() {
    let mut calm = earthlike(6);
    let mut harsh = earthlike(6);
    calm.apply(Action::Tick { ticks: 400 });
    harsh.apply(Action::Tick { ticks: 400 });
    harsh.apply(Action::SetGodhand { on: true });
    harsh.apply(Action::SetStarType {
        star: StarType::NeutronStar as u8,
    });
    // Keep the light and warmth of the Sun; only the radiation changes.
    harsh.apply(Action::SetStarLuminosity { suns: Fx::ONE });
    harsh.apply(Action::Tick { ticks: 1 });
    assert!(harsh.harmful_radiation() > Fx::ONE);
    assert_eq!(calm.harmful_radiation(), Fx::ZERO);
    assert!(harsh.reality_strain() >= Fx::from_int(2));
    // A thick enough sky shields the surface.
    let mut shielded = earthlike(6);
    shielded.apply(Action::SetGodhand { on: true });
    shielded.apply(Action::SetStarType {
        star: StarType::NeutronStar as u8,
    });
    shielded.apply(Action::SetStarLuminosity { suns: Fx::ONE });
    let nitrogen = shielded.substance_index("nitrogen").unwrap() as u16;
    shielded.apply(Action::AddSubstanceGlobal {
        substance: nitrogen,
        amount: Fx::from_int(60),
    });
    shielded.apply(Action::Tick { ticks: 1 });
    assert!(shielded.harmful_radiation() < harsh.harmful_radiation() / Fx::from_int(4));
    calm.apply(Action::Tick { ticks: 100 });
    harsh.apply(Action::Tick { ticks: 100 });
    assert!(
        biomass(&harsh) < biomass(&calm),
        "{:?} vs {:?}",
        biomass(&harsh),
        biomass(&calm)
    );
}

#[test]
fn star_settings_replay_identically() {
    let mut w = earthlike(7);
    w.apply(Action::SetStarType {
        star: StarType::OrangeDwarf as u8,
    });
    w.apply(Action::SetStarDistance {
        au: Fx::ratio(6, 10),
    });
    w.apply(Action::SetGodhand { on: true });
    w.apply(Action::SetGravity {
        g: Fx::ratio(15, 10),
    });
    w.apply(Action::Tick { ticks: 80 });
    let replayed = World::replay(w.log());
    assert_eq!(replayed.state_hash(), w.state_hash());
}
