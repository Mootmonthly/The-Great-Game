//! Starting presets. Each preset is just a list of ordinary player actions,
//! so worlds started from a preset replay and verify like any other.

use crate::action::Action;
use crate::fixed::Fx;
use crate::world::World;

pub const PRESETS: [(&str, &str); 5] = [
    ("blank", "Blank petri dish: bare rock, no atmosphere"),
    (
        "earthlike",
        "Temperate water world with a nitrogen-oxygen sky",
    ),
    (
        "frozen_moon",
        "Distant, cold, low gravity: methane seas and ammonia",
    ),
    (
        "sulfur_world",
        "Hot volcanic world with molten sulfur pools",
    ),
    (
        "magma_world",
        "Scorching world close to its star: molten silicate oceans",
    ),
];

pub fn preset_actions(world: &World, name: &str) -> Option<Vec<Action>> {
    let sub = |key: &str| world.substance_index(key).expect("preset substance exists") as u16;
    let add = |key: &str, milli: i64| Action::AddSubstanceGlobal {
        substance: sub(key),
        amount: Fx::ratio(milli, 1000),
    };
    let planet = |au_milli: i64, lum_milli: i64, g_milli: i64| {
        vec![
            Action::SetStarDistance {
                au: Fx::ratio(au_milli, 1000),
            },
            Action::SetStarLuminosity {
                suns: Fx::ratio(lum_milli, 1000),
            },
            Action::SetGravity {
                g: Fx::ratio(g_milli, 1000),
            },
        ]
    };
    let mut actions = match name {
        "blank" => planet(1000, 1000, 1000),
        "earthlike" => {
            let mut a = planet(1000, 1000, 1000);
            a.extend([
                add("silicate", 4000),
                add("iron", 1000),
                add("water", 2500),
                add("carbon", 500),
                add("nitrogen", 780),
                add("oxygen", 210),
                add("co2", 40),
                add("methane", 20),
            ]);
            a
        }
        "frozen_moon" => {
            let mut a = planet(6000, 1000, 300);
            a.extend([
                add("water", 2000),
                add("silicate", 2000),
                add("nitrogen", 4000),
                add("methane", 1500),
                add("ammonia", 1200),
                add("carbon", 300),
                add("hydrogen", 300),
            ]);
            a
        }
        "sulfur_world" => {
            let mut a = planet(550, 1000, 800);
            a.extend([
                add("silicate", 3000),
                add("iron", 1500),
                add("sulfur", 2500),
                add("co2", 600),
                add("carbon", 300),
                add("silicon", 300),
                add("oxygen", 100),
            ]);
            a
        }
        "magma_world" => {
            let mut a = planet(60, 1500, 1500);
            a.extend([
                add("silicate", 6000),
                add("silicon", 1500),
                add("iron", 2000),
                add("sulfur", 500),
                add("co2", 300),
            ]);
            a
        }
        _ => return None,
    };
    // Let the climate and substance cycle settle for a few years.
    actions.push(Action::Tick { ticks: 40 });
    Some(actions)
}
