//! Planetary controls (docs/GAME_DESIGN.md §4.6): day length, axial tilt,
//! moons.

use sim_core::presets::preset_actions;
use sim_core::world::ROCHE_LIMIT;
use sim_core::{Action, ActionLog, Fx, World};

fn earthlike(seed: u64) -> World {
    let mut w = World::new(seed);
    for a in preset_actions(&w, "earthlike").unwrap() {
        w.apply(a);
    }
    w
}

fn total_biomass(w: &World) -> Fx {
    w.living_species().fold(Fx::ZERO, |a, s| a + s.biomass)
}

#[test]
fn tilt_makes_seasons() {
    let mut w = earthlike(1);
    w.apply(Action::SetAxialTilt {
        degrees: Fx::from_int(40),
    });
    let north = 4 * sim_core::world::WIDTH; // a high northern row
    let tick = |w: &mut World| {
        w.apply(Action::Tick { ticks: 1 });
        w.regions[north].temperature
    };
    // Advance to a known season phase, then compare summer and winter.
    while w.tick % 4 != 0 {
        tick(&mut w);
    }
    // Each tick's climate uses the season of the tick it starts on:
    // 0 equinox, 1 northern summer, 2 equinox, 3 northern winter.
    let _equinox = tick(&mut w);
    let summer = tick(&mut w);
    let _equinox = tick(&mut w);
    let winter = tick(&mut w);
    assert!(summer > winter);
    assert_ne!(summer, winter);
    assert!(
        (summer - winter).abs() > Fx::from_int(10),
        "season swing {:?} vs {:?}",
        summer,
        winter
    );
}

#[test]
fn long_days_are_harder_on_life() {
    let mut normal = earthlike(2);
    let mut slow = earthlike(2);
    slow.apply(Action::SetDayLength {
        hours: Fx::from_int(3000),
    });
    normal.apply(Action::Tick { ticks: 600 });
    slow.apply(Action::Tick { ticks: 600 });
    assert!(slow.day_night_swing() > Fx::from_int(50));
    assert!(total_biomass(&slow) < total_biomass(&normal));
}

#[test]
fn moons_too_close_become_rings_and_same_orbits_merge() {
    let mut w = earthlike(3);
    w.apply(Action::AddMoon {
        mass: Fx::ONE,
        distance: Fx::ONE,
    });
    w.apply(Action::AddMoon {
        mass: Fx::ONE,
        distance: Fx::ratio(105, 100),
    });
    assert_eq!(
        w.planet.moons.len(),
        1,
        "moons on nearly the same orbit merge"
    );
    assert_eq!(w.planet.moons[0].mass, Fx::from_int(2));
    w.apply(Action::AddMoon {
        mass: Fx::HALF,
        distance: ROCHE_LIMIT / Fx::from_int(2),
    });
    assert_eq!(w.planet.moons.len(), 1);
    assert_eq!(w.planet.rings, Fx::HALF);
    w.apply(Action::AddMoon {
        mass: Fx::ONE,
        distance: Fx::ratio(18, 10),
    });
    assert_eq!(w.planet.moons.len(), 2);
    w.apply(Action::RemoveMoon { index: 0 });
    assert_eq!(w.planet.moons[0].distance, Fx::ratio(18, 10));
}

#[test]
fn close_massive_moons_heat_the_planet() {
    let mut calm = earthlike(4);
    let mut tidal = earthlike(4);
    tidal.apply(Action::AddMoon {
        mass: Fx::from_int(5),
        distance: Fx::ratio(4, 10),
    });
    calm.apply(Action::Tick { ticks: 4 });
    tidal.apply(Action::Tick { ticks: 4 });
    assert!(tidal.planet.tidal_strength() > Fx::from_int(50));
    assert!(tidal.mean_temperature > calm.mean_temperature + Fx::from_int(50));
}

#[test]
fn planet_controls_replay_exactly() {
    let mut w = earthlike(5);
    w.apply(Action::SetAxialTilt {
        degrees: Fx::from_int(23),
    });
    w.apply(Action::SetDayLength {
        hours: Fx::from_int(30),
    });
    w.apply(Action::AddMoon {
        mass: Fx::ONE,
        distance: Fx::ONE,
    });
    w.apply(Action::Tick { ticks: 80 });
    let replayed = World::replay(&ActionLog::from_json(&w.log().to_json()).unwrap());
    assert_eq!(w.state_hash(), replayed.state_hash());
}
