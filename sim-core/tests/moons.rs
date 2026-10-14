//! Moon worlds (docs/GAME_DESIGN.md §4.6): each moon is a world of its own
//! that stays a moon of its planet.

use sim_core::presets::preset_actions;
use sim_core::world::{LUNAR_MASS, ROCHE_LIMIT};
use sim_core::{Action, Fx, World};

fn earthlike(seed: u64) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, "earthlike").unwrap() {
        w.apply(a);
    }
    w
}

fn on_moon(w: &mut World, action: Action) {
    w.apply(Action::OnMoon {
        moon: 0,
        action: Box::new(action),
    });
}

/// An Earth-like planet with a Mars-sized moon given an Earth-like
/// chemistry of its own. Tidally locked, it has long days; a close orbit
/// shortens them and thick air holds the heat overnight.
fn living_moon(seed: u64) -> World {
    let mut w = earthlike(seed);
    w.apply(Action::AddMoon {
        mass: Fx::from_int(8),
        distance: Fx::HALF,
    });
    for a in preset_actions(&w, "earthlike").unwrap() {
        if let Action::AddSubstanceGlobal { .. } = a {
            on_moon(&mut w, a);
        }
    }
    let nitrogen = w.substance_index("nitrogen").unwrap() as u16;
    on_moon(&mut w, Action::AddSubstanceGlobal {
        substance: nitrogen,
        amount: Fx::from_int(3),
    });
    w
}

#[test]
fn one_moon_slot_unless_more_are_bought() {
    let mut w = earthlike(1);
    for d in [1, 2] {
        w.apply(Action::AddMoon {
            mass: Fx::ONE,
            distance: Fx::from_int(d),
        });
    }
    assert_eq!(w.planet.moons.len(), 1);
    assert_eq!(w.moon_worlds.len(), 1);
    w.planet.moon_slots = 2;
    w.apply(Action::AddMoon {
        mass: Fx::ONE,
        distance: Fx::from_int(2),
    });
    assert_eq!(w.moon_worlds.len(), 2);
    // Moons have no moons.
    let moon = w.moon(0).unwrap();
    assert!(moon.planet.host.is_some());
    assert_eq!(moon.planet.moon_slots, 0);
}

#[test]
fn a_moon_is_its_own_world() {
    let mut w = living_moon(2);
    let water = w.substance_index("water").unwrap();
    let planet_water = w.regions[0].amounts[water];
    on_moon(&mut w, Action::AddSubstanceGlobal {
        substance: water as u16,
        amount: Fx::ONE,
    });
    assert_eq!(w.regions[0].amounts[water], planet_water, "the planet is untouched");
    w.apply(Action::Tick { ticks: 1600 });
    let moon = w.moon(0).unwrap();
    assert_eq!(moon.tick, w.tick, "the moon lives in step with its planet");
    assert!(moon.living_species().count() > 0, "life arises on the moon");
    assert_ne!(moon.seed, w.seed);
}

#[test]
fn the_moon_shares_its_planets_star_and_is_tidally_locked() {
    let mut w = earthlike(3);
    w.apply(Action::AddMoon {
        mass: Fx::ONE,
        distance: Fx::ONE,
    });
    w.apply(Action::SetStarDistance { au: Fx::ratio(15, 10) });
    on_moon(&mut w, Action::SetStarDistance { au: Fx::from_int(9) });
    let moon = w.moon(0).unwrap();
    assert_eq!(moon.planet.star_distance_au, Fx::ratio(15, 10));
    // The Moon's month: about 27.3 days.
    let days = moon.planet.day_length_hours / Fx::from_int(24);
    assert!((days - Fx::ratio(273, 10)).abs() < Fx::ratio(5, 10), "{days:?}");
    // Its own controls work, and its mass is the planet's moon's mass.
    on_moon(&mut w, Action::SetGravity { g: Fx::ratio(3, 10) });
    let moon = w.moon(0).unwrap();
    assert_eq!(w.planet.moons[0].mass, moon.planet.planet_mass / LUNAR_MASS);
    assert!(w.planet.moons[0].mass > Fx::ratio(15, 10), "a heavier moon");
}

#[test]
fn the_planet_heats_and_eclipses_a_close_moon() {
    let mut near = earthlike(4);
    let mut far = earthlike(4);
    near.apply(Action::AddMoon { mass: Fx::ONE, distance: Fx::ratio(4, 10) });
    far.apply(Action::AddMoon { mass: Fx::ONE, distance: Fx::ratio(18, 10) });
    let (n, f) = (near.moon(0).unwrap(), far.moon(0).unwrap());
    assert!(n.planet.tidal_strength() > f.planet.tidal_strength() * Fx::from_int(50));
    assert!(n.planet.eclipse_fraction() > f.planet.eclipse_fraction());
    assert!(n.mean_temperature > f.mean_temperature + Fx::from_int(50));
    assert!(n.stellar_flux() < near.stellar_flux());
}

#[test]
fn natural_orbits_stay_stable_and_godhand_orbits_strain() {
    let mut w = earthlike(5);
    w.apply(Action::AddMoon { mass: Fx::ONE, distance: Fx::ONE });
    let far = w.planet.moon_limit() * Fx::from_int(3);
    w.apply(Action::SetMoonOrbit { moon: 0, distance: far });
    assert_eq!(w.planet.moons[0].distance, w.planet.moon_limit(), "drawn in, not lost");
    w.apply(Action::SetMoonOrbit { moon: 0, distance: Fx::ratio(1, 10) });
    assert_eq!(w.planet.moons[0].distance, ROCHE_LIMIT);
    w.apply(Action::SetGodhand { on: true });
    w.apply(Action::SetMoonOrbit { moon: 0, distance: far });
    assert_eq!(w.planet.moons[0].distance, far);
    assert!(w.planet.strain() > Fx::ZERO);
    assert_eq!(w.moon_worlds.len(), 1);
}

#[test]
fn moon_worlds_replay_and_restore_exactly() {
    let mut w = living_moon(6);
    on_moon(&mut w, Action::SetAxialTilt { degrees: Fx::from_int(10) });
    w.apply(Action::Tick { ticks: 120 });
    assert_eq!(World::replay(w.log()).state_hash(), w.state_hash());
    let restored = World::from_snapshot(&w.snapshot()).unwrap();
    assert_eq!(restored.state_hash(), w.state_hash());
    assert_eq!(restored.moon(0).unwrap().substances.len(), w.substances.len());
    w.apply(Action::RemoveMoon { index: 0 });
    assert!(w.moon_worlds.is_empty() && w.planet.moons.is_empty());
}

