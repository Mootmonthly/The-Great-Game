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
    globe: Option<sim_core::globe::GlobeMaps>,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for SimWorld {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            world: World::new(1),
            globe: None,
            base,
        }
    }
}

fn to_gstring(v: Value) -> GString {
    GString::from(v.to_string().as_str())
}

fn hex(c: [u8; 3]) -> String {
    format!("{:02x}{:02x}{:02x}", c[0], c[1], c[2])
}

fn substance_names(w: &World) -> Vec<String> {
    w.substances.iter().map(|s| s.name.clone()).collect()
}

fn species_summary(w: &World, s: &sim_core::life::Species) -> Value {
    let g = &s.genome;
    json!({
        "id": s.id, "name": s.name, "description": s.description(w), "color": hex(s.color),
        "biomass": s.biomass.to_f64(), "regions": s.range, "alive": s.is_alive(),
        "size": g.size.to_f64(), "temp_opt": g.temp_opt.to_f64(), "temp_tol": g.temp_tol.to_f64(),
        "body": g.body.describe(&substance_names(w)),
        "milestones": sim_core::body::milestone_names(g.milestones),
        "temperament": s.temperament.describe(),
        "parent": s.parent, "born_year": s.born_tick / sim_core::world::TICKS_PER_YEAR,
        "cost": sim_core::sheet::species_sheet(w, s).cost.cost,
    })
}

fn sheet_to_json(sh: &sim_core::sheet::CharacterSheet) -> Value {
    use sim_core::sheet::{modifier, ABILITY_NAMES};
    let names = |v: &[sim_core::sheet::DamageType]| v.iter().map(|d| d.name()).collect::<Vec<_>>();
    let abilities: Vec<Value> = ABILITY_NAMES
        .iter()
        .zip(sh.abilities)
        .map(|(n, v)| json!({"name": n, "score": v, "modifier": modifier(v)}))
        .collect();
    let c = &sh.cost;
    json!({
        "name": sh.name, "type": sh.creature_type, "size": sh.size.name(), "alignment": sh.alignment,
        "armor_class": sh.armor_class, "hit_points": sh.hit_points, "hit_dice": sh.hit_dice, "hit_die": sh.size.hit_die(),
        "speed": {"walk": sh.speed_walk, "swim": sh.speed_swim, "fly": sh.speed_fly, "burrow": sh.speed_burrow},
        "proficiency": sh.proficiency, "abilities": abilities,
        "senses": sh.senses, "languages": sh.languages,
        "resistances": names(&sh.resistances), "immunities": names(&sh.immunities), "vulnerabilities": names(&sh.vulnerabilities),
        "traits": sh.traits.iter().map(|t| json!({"name": t.name, "text": t.text})).collect::<Vec<_>>(),
        "actions": sh.attacks.iter().map(|a| a.describe()).chain(sh.breath.iter().map(|b| b.describe())).collect::<Vec<_>>(),
        "attacks": sh.attacks.iter().map(|a| json!({
            "name": a.name, "to_hit": a.to_hit, "dice": a.dice, "die": a.die, "bonus": a.bonus,
            "damage": a.damage.name(), "uses": a.uses,
        })).collect::<Vec<_>>(),
        "breath": sh.breath.as_ref().map(|b| json!({
            "name": b.name, "dice": b.dice, "damage": b.damage.name(), "dc": b.dc,
            "save_ability": b.save_ability, "targets": b.targets,
        })),
        "regeneration": sh.regeneration, "pack_tactics": sh.pack_tactics,
        "cost": c.cost,
        "cost_breakdown": {
            "effective_hp": c.effective_hp.to_f64(), "damage_per_round": c.damage_per_round.to_f64(),
            "utility": c.utility.to_f64(), "stats": c.stats.to_f64(), "power": c.power.to_f64(),
        },
    })
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
    fn set_day_length(&mut self, hours: f64) {
        self.world.apply(Action::SetDayLength {
            hours: Fx::from_f64(hours),
        });
    }

    #[func]
    fn set_axial_tilt(&mut self, degrees: f64) {
        self.world.apply(Action::SetAxialTilt {
            degrees: Fx::from_f64(degrees),
        });
    }

    /// Mass in lunar masses, distance in Earth–Moon distances.
    #[func]
    fn add_moon(&mut self, mass: f64, distance: f64) {
        self.world.apply(Action::AddMoon {
            mass: Fx::from_f64(mass),
            distance: Fx::from_f64(distance),
        });
    }

    #[func]
    fn remove_moon(&mut self, index: i64) {
        if (0..=255).contains(&index) {
            self.world.apply(Action::RemoveMoon { index: index as u8 });
        }
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
            "day_length": p.day_length_hours.to_f64(),
            "axial_tilt": p.axial_tilt_deg.to_f64(),
            "moons": p.moons.iter().map(|m| json!({"mass": m.mass.to_f64(), "distance": m.distance.to_f64()})).collect::<Vec<_>>(),
            "rings": p.rings.to_f64(),
            "tidal_strength": p.tidal_strength().to_f64(),
            "day_night_swing": w.day_night_swing().to_f64(),
            "living_species": w.living_species().count(),
            "living_individuals": w.living_individuals().count(),
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
        // Look of the place, for the local 3D view.
        let (mut liquid, mut ice, mut liquid_color, mut top) = (0.0, 0.0, None, 0.0);
        for (sub, a) in w.substances.iter().zip(&r.amounts) {
            let a = a.to_f64();
            match sub.phase(r.temperature, w.pressure) {
                sim_core::substance::Phase::Liquid => {
                    liquid += a;
                    if a > top {
                        top = a;
                        liquid_color = Some(sub.color);
                    }
                }
                sim_core::substance::Phase::Solid if sub.melt_k < Fx::from_int(400) => ice += a,
                _ => {}
            }
        }
        let look = w.atmosphere_look();
        let here: Vec<Value> = w
            .living_individuals()
            .filter(|x| x.region == i)
            .map(|x| json!({"id": x.id, "title": x.title(), "species_id": x.species}))
            .collect();
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
            "liquid_amount": liquid,
            "liquid_color": liquid_color.map(hex),
            "ice_amount": ice,
            "sky_color": look.color,
            "atmosphere": look.thickness,
            "sunlight": look.sunlight,
            "individuals_here": here,
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
            .map(|s| species_summary(w, s))
            .collect();
        to_gstring(json!(list))
    }

    /// Everything about one species, including its ancestry. Returns "null"
    /// if no record exists.
    #[func]
    fn species_detail_json(&self, id: i64) -> GString {
        let w = &self.world;
        let Some(s) = w.species_by_id(id as u32) else {
            return GString::from("null");
        };
        let mut v = species_summary(w, s);
        let names = substance_names(w);
        let parts: Vec<Value> = s
            .genome
            .body
            .parts
            .iter()
            .map(|p| {
                json!({
                    "part": p.kind.name(), "count": p.count, "size": p.size.to_f64(),
                    "substance": p.substance.and_then(|i| names.get(i as usize)).cloned(),
                    "substance_color": p.substance.and_then(|i| w.substances.get(i as usize)).map(|x| hex(x.color)),
                })
            })
            .collect();
        let mut ancestors = Vec::new();
        let mut cursor = s.parent;
        while let Some(pid) = cursor {
            match w.species_by_id(pid) {
                Some(a) => {
                    ancestors.push(json!({"id": a.id, "name": a.name, "description": a.description(w), "alive": a.is_alive()}));
                    cursor = a.parent;
                }
                None => {
                    ancestors.push(json!({"id": pid, "name": "(forgotten ancestor)", "description": "", "alive": false}));
                    break;
                }
            }
            if ancestors.len() >= 40 {
                break;
            }
        }
        let children = w.species.iter().filter(|c| c.parent == Some(s.id)).count();
        let t = &s.traits;
        let tm = &s.temperament;
        let obj = v.as_object_mut().expect("summary is an object");
        obj.insert("parts".into(), json!(parts));
        obj.insert("ancestors".into(), json!(ancestors));
        obj.insert("children".into(), json!(children));
        obj.insert("traits".into(), json!({
            "armor": t.armor.to_f64(), "speed": t.speed.to_f64(), "intelligence": t.intelligence.to_f64(),
            "offense": t.offense.to_f64(), "perception": t.perception.to_f64(), "photosynthesis": t.photosynthesis.to_f64(),
        }));
        obj.insert(
            "temperament_values".into(),
            json!({
                "aggression": tm.aggression.to_f64(), "fear": tm.fear.to_f64(),
                "curiosity": tm.curiosity.to_f64(), "sociability": tm.sociability.to_f64(),
            }),
        );
        obj.insert(
            "profile".into(),
            json!({
                "backbone": w.elements[s.profile.element as usize],
                "medium": w.substances[s.profile.medium as usize].name,
                "energy": s.profile.energy.name(),
            }),
        );
        obj.insert(
            "individuals".into(),
            json!(w.living_individuals().filter(|x| x.species == s.id).count()),
        );
        to_gstring(v)
    }

    /// Family tree data: the `limit` largest living species plus all their
    /// recorded ancestors, oldest first.
    #[func]
    fn tree_json(&self, limit: i64) -> GString {
        let w = &self.world;
        let mut living: Vec<_> = w.living_species().collect();
        living.sort_by(|a, b| b.biomass.cmp(&a.biomass).then(a.id.cmp(&b.id)));
        let mut ids: Vec<u32> = Vec::new();
        for s in living.iter().take(limit.max(0) as usize) {
            let mut cursor = Some(s.id);
            while let Some(id) = cursor {
                if ids.contains(&id) {
                    break;
                }
                match w.species_by_id(id) {
                    Some(x) => {
                        ids.push(id);
                        cursor = x.parent;
                    }
                    None => break,
                }
            }
        }
        ids.sort();
        let tpy = sim_core::world::TICKS_PER_YEAR;
        let nodes: Vec<Value> = ids
            .iter()
            .filter_map(|&id| w.species_by_id(id))
            .map(|s| {
                json!({
                    "id": s.id, "parent": s.parent, "name": s.name, "color": hex(s.color),
                    "born_year": s.born_tick / tpy, "extinct_year": s.extinct_tick.map(|t| t / tpy),
                    "milestones": s.genome.milestones.count_ones(), "alive": s.is_alive(),
                })
            })
            .collect();
        to_gstring(json!({"year": w.year(), "nodes": nodes}))
    }

    /// Living named individuals, most renowned first.
    #[func]
    fn individuals_json(&self, limit: i64) -> GString {
        let w = &self.world;
        let mut living: Vec<_> = w.living_individuals().collect();
        living.sort_by(|a, b| b.renown.cmp(&a.renown).then(a.id.cmp(&b.id)));
        let list: Vec<Value> = living
            .iter()
            .take(limit.max(0) as usize)
            .map(|x| {
                let species = w.species_by_id(x.species);
                json!({
                    "id": x.id, "title": x.title(), "name": x.name,
                    "species": species.map(|s| s.name.clone()), "species_id": x.species,
                    "color": species.map(|s| hex(s.color)),
                    "x": x.region % WIDTH, "y": x.region / WIDTH,
                    "age": x.age_years(w.tick), "charisma": x.charisma(), "renown": x.renown.to_f64(),
                    "friends": x.friends(), "enemies": x.enemies(),
                    "personality": x.personality.describe(),
                    "last_action": x.last_action.map(|a| sim_core::brain::output::NAMES[a]),
                    "cost": sim_core::sheet::individual_sheet(w, x).map(|sh| sh.cost.cost),
                })
            })
            .collect();
        to_gstring(json!(list))
    }

    /// Everything about one individual: relationships and life story.
    /// Returns "null" if no record exists.
    #[func]
    fn individual_json(&self, id: i64) -> GString {
        let w = &self.world;
        let Some(x) = w.individual_by_id(id as u32) else {
            return GString::from("null");
        };
        let name_of = |other: u32| {
            w.individual_by_id(other)
                .map_or("someone forgotten".to_string(), |o| o.title())
        };
        let relations: Vec<Value> = x
            .relations
            .iter()
            .map(|r| json!({"id": r.other, "name": name_of(r.other), "affinity": r.affinity.to_f64(), "kin": r.kin,
                "alive": w.individual_by_id(r.other).is_some_and(|o| o.is_alive())}))
            .collect();
        let tpy = sim_core::world::TICKS_PER_YEAR;
        let memories: Vec<Value> = x
            .memories
            .iter()
            .map(|m| {
                let text = match m.other {
                    Some(o) => format!("{} {}", m.kind.describe(), name_of(o)),
                    None => m.kind.describe().to_string(),
                };
                json!({"year": m.tick / tpy, "text": text})
            })
            .collect();
        let species = w.species_by_id(x.species);
        let p = &x.personality;
        to_gstring(json!({
            "id": x.id, "title": x.title(), "alive": x.is_alive(),
            "species": species.map(|s| s.name.clone()), "species_id": x.species,
            "species_description": species.map(|s| s.description(w)),
            "x": x.region % WIDTH, "y": x.region / WIDTH,
            "age": x.age_years(w.tick), "lifespan_years": x.lifespan / tpy,
            "health": x.health.to_f64(), "renown": x.renown.to_f64(), "charisma": x.charisma(),
            "personality": p.describe(),
            "temperament_values": {"aggression": p.aggression.to_f64(), "fear": p.fear.to_f64(),
                "curiosity": p.curiosity.to_f64(), "sociability": p.sociability.to_f64()},
            "relations": relations, "memories": memories,
            "cause_of_death": x.cause_of_death,
            "last_action": x.last_action.map(|a| sim_core::brain::output::NAMES[a]),
        }))
    }

    /// Builds the globe maps at `width` × `height` pixels; read them with
    /// `globe_albedo` and `globe_data`.
    #[func]
    fn build_globe(&mut self, width: i64, height: i64) {
        let (w, h) = (
            width.clamp(16, 4096) as usize,
            height.clamp(8, 2048) as usize,
        );
        self.globe = Some(self.world.globe_maps(w, h));
    }

    /// RGBA8: surface colour, alpha = liquid mask.
    #[func]
    fn globe_albedo(&self) -> PackedByteArray {
        self.globe.as_ref().map_or_else(PackedByteArray::new, |g| {
            PackedByteArray::from(g.albedo.as_slice())
        })
    }

    /// RGBA8: R height, G ice, B glow, A liquid depth.
    #[func]
    fn globe_data(&self) -> PackedByteArray {
        self.globe.as_ref().map_or_else(PackedByteArray::new, |g| {
            PackedByteArray::from(g.data.as_slice())
        })
    }

    #[func]
    fn atmosphere_json(&self) -> GString {
        let a = self.world.atmosphere_look();
        to_gstring(json!({
            "color": a.color, "thickness": a.thickness, "clouds": a.clouds,
            "cloud_color": a.cloud_color, "sunlight": a.sunlight,
        }))
    }

    /// Character sheet (§5) of a species ("species") or a named individual
    /// ("individual"). Returns "null" if no record exists.
    #[func]
    fn sheet_json(&self, kind: GString, id: i64) -> GString {
        let w = &self.world;
        let sheet = match kind.to_string().as_str() {
            "species" => w
                .species_by_id(id as u32)
                .map(|s| sim_core::sheet::species_sheet(w, s)),
            "individual" => w
                .individual_by_id(id as u32)
                .and_then(|x| sim_core::sheet::individual_sheet(w, x)),
            _ => None,
        };
        match sheet {
            Some(sh) => to_gstring(sheet_to_json(&sh)),
            None => GString::from("null"),
        }
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
