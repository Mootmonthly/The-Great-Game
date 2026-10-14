//! GDExtension bridge: exposes the simulation to Godot as the `SimWorld`
//! class. Structured data crosses the boundary as JSON strings, which keeps
//! the binding surface small; the map overlay crosses as raw RGBA bytes.

use godot::prelude::*;
use serde_json::{json, Value};
use sim_core::presets::{preset_actions, PRESETS};
use sim_core::world::{index, HEIGHT, WIDTH};
use sim_core::{Action, ActionLog, Fx, Overlay, World};

struct GreatGameExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GreatGameExtension {}

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct SimWorld {
    world: World,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for SimWorld {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            world: World::new(1),
            base,
        }
    }
}

fn to_gstring(v: Value) -> GString {
    GString::from(v.to_string().as_str())
}

fn coord(v: i64, max: usize) -> u16 {
    v.clamp(0, max as i64 - 1) as u16
}

#[godot_api]
impl SimWorld {
    /// Starts a new world from a seed and a preset name. Returns false for an
    /// unknown preset.
    #[func]
    fn new_world(&mut self, seed: i64, preset: GString) -> bool {
        let mut world = World::new(seed as u64);
        let Some(actions) = preset_actions(&world, &preset.to_string()) else {
            return false;
        };
        for a in actions {
            world.apply(a);
        }
        self.world = world;
        true
    }

    #[func]
    fn presets_json(&self) -> GString {
        to_gstring(json!(PRESETS
            .iter()
            .map(|(k, d)| json!({"key": k, "description": d}))
            .collect::<Vec<_>>()))
    }

    #[func]
    fn substances_json(&self) -> GString {
        let list: Vec<Value> = self
            .world
            .substances
            .iter()
            .map(|s| {
                json!({
                    "key": s.key, "name": s.name, "formula": s.formula,
                    "color": format!("{:02x}{:02x}{:02x}", s.color[0], s.color[1], s.color[2]),
                })
            })
            .collect();
        to_gstring(json!(list))
    }

    #[func]
    fn width(&self) -> i64 {
        WIDTH as i64
    }

    #[func]
    fn height(&self) -> i64 {
        HEIGHT as i64
    }

    #[func]
    fn tick(&mut self, ticks: i64) {
        if ticks > 0 {
            self.world.apply(Action::Tick {
                ticks: ticks.min(10_000) as u32,
            });
        }
    }

    #[func]
    fn add_substance(&mut self, x: i64, y: i64, radius: i64, substance: i64, amount: f64) {
        self.world.apply(Action::AddSubstance {
            x: coord(x, WIDTH),
            y: coord(y, HEIGHT),
            radius: radius.clamp(0, 16) as u8,
            substance: substance.clamp(0, u16::MAX as i64) as u16,
            amount: Fx::from_f64(amount),
        });
    }

    #[func]
    fn heat_region(&mut self, x: i64, y: i64, radius: i64, kelvin: f64) {
        self.world.apply(Action::HeatRegion {
            x: coord(x, WIDTH),
            y: coord(y, HEIGHT),
            radius: radius.clamp(0, 16) as u8,
            delta: Fx::from_f64(kelvin),
        });
    }

    #[func]
    fn set_global_heat(&mut self, kelvin: f64) {
        self.world.apply(Action::SetGlobalHeat {
            kelvin: Fx::from_f64(kelvin),
        });
    }

    #[func]
    fn set_star_distance(&mut self, au: f64) {
        self.world.apply(Action::SetStarDistance {
            au: Fx::from_f64(au),
        });
    }

    #[func]
    fn set_star_luminosity(&mut self, suns: f64) {
        self.world.apply(Action::SetStarLuminosity {
            suns: Fx::from_f64(suns),
        });
    }

    #[func]
    fn set_gravity(&mut self, g: f64) {
        self.world.apply(Action::SetGravity { g: Fx::from_f64(g) });
    }

    /// RGBA8 pixels, one per region. Modes: 0 surface, 1 temperature, 2 life,
    /// 3 viability, 4+ substance amount (4 + substance index).
    #[func]
    fn overlay(&self, mode: i64) -> PackedByteArray {
        PackedByteArray::from(self.world.overlay_rgba(Overlay::from_mode(mode)).as_slice())
    }

    #[func]
    fn status_json(&self) -> GString {
        let w = &self.world;
        let p = &w.planet;
        let atmosphere: Vec<Value> = w
            .substances
            .iter()
            .zip(&w.atmosphere)
            .filter(|(_, a)| **a > Fx::ratio(1, 1000))
            .map(|(s, a)| json!({"name": s.name, "column": a.to_f64()}))
            .collect();
        to_gstring(json!({
            "seed": w.seed,
            "tick": w.tick,
            "year": w.year(),
            "mean_temperature": w.mean_temperature.to_f64(),
            "pressure": w.pressure.to_f64(),
            "stellar_flux": w.stellar_flux().to_f64(),
            "star_distance": p.star_distance_au.to_f64(),
            "star_luminosity": p.star_luminosity.to_f64(),
            "gravity": p.gravity.to_f64(),
            "global_heat": p.global_heat.to_f64(),
            "living_species": w.living_species().count(),
            "species_ever": w.species.last().map_or(0, |s| s.id),
            "atmosphere": atmosphere,
            "hash": format!("{:016x}", w.state_hash()),
        }))
    }

    #[func]
    fn region_json(&self, x: i64, y: i64) -> GString {
        let w = &self.world;
        let i = index(coord(x, WIDTH) as usize, coord(y, HEIGHT) as usize);
        let r = &w.regions[i];
        let life = w.region_life(i);
        let substances: Vec<Value> = w
            .substances
            .iter()
            .zip(&r.amounts)
            .filter(|(_, a)| **a > Fx::ratio(1, 100))
            .map(|(s, a)| json!({"name": s.name, "amount": a.to_f64(), "phase": format!("{:?}", s.phase(r.temperature, w.pressure))}))
            .collect();
        let mut pops: Vec<Value> = r
            .populations
            .iter()
            .filter_map(|p| {
                let s = w.species_by_id(p.species)?;
                Some(json!({"id": s.id, "name": s.name, "description": s.description(w), "biomass": p.biomass.to_f64()}))
            })
            .collect();
        pops.sort_by(|a, b| {
            b["biomass"]
                .as_f64()
                .partial_cmp(&a["biomass"].as_f64())
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let best = life.best.map(|(p, v)| {
            json!({
                "backbone": w.elements[p.element as usize],
                "medium": w.substances[p.medium as usize].name,
                "energy": p.energy.name(),
                "viability": v.to_f64(),
            })
        });
        to_gstring(json!({
            "x": x, "y": y,
            "temperature": r.temperature.to_f64(),
            "elevation": r.elevation.to_f64(),
            "geothermal": r.geothermal.to_f64(),
            "substances": substances,
            "best_profile": best,
            "populations": pops,
        }))
    }

    /// Living species sorted by biomass, largest first.
    #[func]
    fn species_json(&self, limit: i64) -> GString {
        let w = &self.world;
        let mut living: Vec<_> = w.living_species().collect();
        living.sort_by(|a, b| b.biomass.cmp(&a.biomass).then(a.id.cmp(&b.id)));
        let list: Vec<Value> = living
            .iter()
            .take(limit.max(0) as usize)
            .map(|s| {
                let g = &s.genome;
                json!({
                    "id": s.id, "name": s.name, "description": s.description(w),
                    "color": format!("{:02x}{:02x}{:02x}", s.color[0], s.color[1], s.color[2]),
                    "biomass": s.biomass.to_f64(), "regions": s.range,
                    "size": g.size.to_f64(), "temp_opt": g.temp_opt.to_f64(), "temp_tol": g.temp_tol.to_f64(),
                    "armor": g.armor.to_f64(), "speed": g.speed.to_f64(), "intelligence": g.intelligence.to_f64(),
                    "parent": s.parent, "born_year": s.born_tick / sim_core::world::TICKS_PER_YEAR,
                })
            })
            .collect();
        to_gstring(json!(list))
    }

    /// The action log as JSON: everything needed to rebuild this world.
    #[func]
    fn save_log(&self) -> GString {
        GString::from(self.world.log().to_json().as_str())
    }

    /// Rebuilds the world by replaying a saved action log.
    #[func]
    fn load_log(&mut self, json: GString) -> bool {
        match ActionLog::from_json(&json.to_string()) {
            Ok(log) => {
                self.world = World::replay(&log);
                true
            }
            Err(e) => {
                godot_error!("could not load world log: {e}");
                false
            }
        }
    }
}
