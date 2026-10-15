//! GDExtension bridge: exposes the simulation to Godot as the `SimWorld`
//! class. Structured data crosses the boundary as JSON strings, which keeps
//! the binding surface small; the map overlay crosses as raw RGBA bytes.

#![recursion_limit = "256"]

use godot::prelude::*;

mod net;
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
    /// The moon whose world the viewer shows and the tools change; None
    /// for the planet.
    focus: Option<usize>,
    globe: Option<sim_core::globe::GlobeMaps>,
    /// Maps of a second body (a moon, or the planet seen from its moon).
    aux_globe: Option<sim_core::globe::GlobeMaps>,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for SimWorld {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            world: World::new(1),
            focus: None,
            globe: None,
            aux_globe: None,
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
        "otherworldly": s.has(sim_core::body::OTHERWORLDLY),
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
        "class": sh.class, "equipment": sh.equipment,
        "regeneration": sh.regeneration, "pack_tactics": sh.pack_tactics,
        "cost": c.cost,
        "cost_breakdown": {
            "effective_hp": c.effective_hp.to_f64(), "damage_per_round": c.damage_per_round.to_f64(),
            "utility": c.utility.to_f64(), "stats": c.stats.to_f64(), "power": c.power.to_f64(),
        },
    })
}

impl SimWorld {
    /// The world in focus: the planet, or one of its moons.
    fn view(&self) -> &World {
        self.focus.and_then(|k| self.world.moon(k)).unwrap_or(&self.world)
    }

    /// Applies a tool action to the world in focus.
    fn act(&mut self, action: Action) {
        match self.focus {
            Some(k) if k < self.world.moon_worlds.len() => self.world.apply(Action::OnMoon {
                moon: k as u8,
                action: Box::new(action),
            }),
            _ => self.world.apply(action),
        }
    }
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
        self.focus = None;
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
                    // Shop elements are bought with Essence, not added with the free tools.
                    "shop": s.shop.map(|c| c.name()),
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
        self.act(Action::AddSubstance {
            x: coord(x, WIDTH),
            y: coord(y, HEIGHT),
            radius: radius.clamp(0, 16) as u8,
            substance: substance.clamp(0, u16::MAX as i64) as u16,
            amount: Fx::from_f64(amount),
        });
    }

    #[func]
    fn heat_region(&mut self, x: i64, y: i64, radius: i64, kelvin: f64) {
        self.act(Action::HeatRegion {
            x: coord(x, WIDTH),
            y: coord(y, HEIGHT),
            radius: radius.clamp(0, 16) as u8,
            delta: Fx::from_f64(kelvin),
        });
    }

    #[func]
    fn set_global_heat(&mut self, kelvin: f64) {
        self.act(Action::SetGlobalHeat {
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
        self.act(Action::SetDayLength {
            hours: Fx::from_f64(hours),
        });
    }

    #[func]
    fn set_axial_tilt(&mut self, degrees: f64) {
        self.act(Action::SetAxialTilt {
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
            let i = index as usize;
            self.focus = match self.focus {
                Some(f) if f == i => None,
                Some(f) if f > i => Some(f - 1),
                f => f,
            };
        }
    }

    #[func]
    fn set_gravity(&mut self, g: f64) {
        self.act(Action::SetGravity { g: Fx::from_f64(g) });
    }

    /// Natural mode (false) or Godhand mode (true).
    #[func]
    fn set_godhand(&mut self, on: bool) {
        self.world.apply(Action::SetGodhand { on });
    }

    /// Star type by index into `stars_json`.
    #[func]
    fn set_star_type(&mut self, star: i64) {
        if (0..sim_core::star::STARS.len() as i64).contains(&star) {
            self.world.apply(Action::SetStarType { star: star as u8 });
        }
    }

    #[func]
    fn set_star_mass(&mut self, solar: f64) {
        self.world.apply(Action::SetStarMass {
            solar: Fx::from_f64(solar),
        });
    }

    #[func]
    fn set_planet_radius(&mut self, earths: f64) {
        self.act(Action::SetPlanetRadius {
            earths: Fx::from_f64(earths),
        });
    }

    /// The Veil law (§4.4a), in percent: 0 sealed .. 100 wide open.
    #[func]
    fn set_veil_law(&mut self, percent: f64) {
        self.act(Action::SetVeilLaw {
            openness: Fx::from_f64(percent / 100.0),
        });
    }

    /// The Arcane Magic law, in percent: 0 absent .. 100 at full strength.
    #[func]
    fn set_law_arcane(&mut self, percent: f64) {
        self.act(Action::SetLaw {
            law: sim_core::laws::ARCANE,
            value: Fx::from_f64(percent / 100.0),
        });
    }

    /// The Soul Power law, in percent: 0 absent .. 100 at full strength.
    #[func]
    fn set_law_soul(&mut self, percent: f64) {
        self.act(Action::SetLaw {
            law: sim_core::laws::SOUL,
            value: Fx::from_f64(percent / 100.0),
        });
    }

    /// The Daoist Cultivation law, in percent: 0 absent .. 100 at full strength.
    #[func]
    fn set_law_qi(&mut self, percent: f64) {
        self.act(Action::SetLaw {
            law: sim_core::laws::QI,
            value: Fx::from_f64(percent / 100.0),
        });
    }

    /// How deadly cultivation breakthroughs are (Daoist Cultivation), in
    /// percent: 0 never deadly .. 100 most deadly.
    #[func]
    fn set_law_tribulation(&mut self, percent: f64) {
        self.act(Action::SetLaw {
            law: sim_core::laws::TRIBULATION,
            value: Fx::from_f64(percent / 100.0),
        });
    }

    /// The star types, in index order.
    #[func]
    fn stars_json(&self) -> GString {
        let stars: Vec<Value> = sim_core::star::STARS
            .iter()
            .map(|s| {
                json!({
                    "name": s.name, "description": s.description,
                    "mass": s.mass.to_f64(), "min_mass": s.min_mass.to_f64(),
                    "max_mass": s.max_mass.to_f64(), "luminosity": s.luminosity.to_f64(),
                    "light_quality": s.light_quality.to_f64(), "radiation": s.radiation.to_f64(),
                    "flares": s.flares, "color": hex(s.color),
                })
            })
            .collect();
        to_gstring(json!(stars))
    }

    /// RGBA8 pixels, one per region. Modes: 0 surface, 1 temperature, 2 life,
    /// 3 viability, 4 Veil, 5 mana, 6 qi, 7 civilizations, 8+ substance amount (8 + substance index).
    #[func]
    fn overlay(&self, mode: i64) -> PackedByteArray {
        PackedByteArray::from(self.view().overlay_rgba(Overlay::from_mode(mode)).as_slice())
    }

    #[func]
    fn status_json(&self) -> GString {
        let w = self.view();
        let p = &w.planet;
        let atmosphere: Vec<Value> = w
            .substances
            .iter()
            .zip(&w.atmosphere)
            .filter(|(_, a)| **a > Fx::ratio(1, 1000))
            .map(|(s, a)| json!({"name": s.name, "column": a.to_f64()}))
            .collect();
        let living_civs: Vec<_> = w.living_civs().collect();
        let wars = living_civs
            .iter()
            .enumerate()
            .flat_map(|(k, a)| living_civs[k + 1..].iter().map(move |b| a.at_war_with(b.id) || b.at_war_with(a.id)))
            .filter(|war| *war)
            .count();
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
            "godhand": p.godhand,
            "star_type": p.star_type as u8,
            "star_name": p.star_type.info().name,
            "star_color": hex(p.star_type.info().color),
            "star_mass": p.star_mass.to_f64(),
            "planet_mass": p.planet_mass.to_f64(),
            "planet_radius": p.planet_radius.to_f64(),
            "year_length": p.year_length().to_f64(),
            "moon_limit": p.moon_limit().to_f64(),
            "radiation": w.surface_radiation().to_f64(),
            "harmful_radiation": w.harmful_radiation().to_f64(),
            "strain": p.strain().to_f64(),
            "reality_strain": w.reality_strain().to_f64(),
            "last_flare_year": p.last_flare_tick.map_or(-1, |t| (t / 4) as i64),
            "veil_law": w.veil_law.to_f64() * 100.0,
            "veil_thinning": w.veil_thinning().to_f64(),
            "veil_min": w.veil_min().to_f64(),
            "veil_mean": w.veil_mean().to_f64(),
            "entity_species": w.living_species().filter(|s| s.has(sim_core::body::OTHERWORLDLY)).count(),
            "last_breach_year": w.last_breach_tick.map_or(-1, |t| (t / 4) as i64),
            "law_arcane": w.laws.arcane.to_f64() * 100.0,
            "law_soul": w.laws.soul.to_f64() * 100.0,
            "law_qi": w.laws.qi.to_f64() * 100.0,
            "law_tribulation": w.laws.tribulation.to_f64() * 100.0,
            "spellcasting_species": w.living_species().filter(|s| s.has(sim_core::body::SPELLCASTING)).count(),
            "reborn": w.living_individuals().filter(|x| x.past_life.is_some()).count(),
            "cultivators": w.cultivators(1),
            "souls_waiting": w.souls.len(),
            "global_heat": p.global_heat.to_f64(),
            "day_length": p.day_length_hours.to_f64(),
            "axial_tilt": p.axial_tilt_deg.to_f64(),
            "moons": p.moons.iter().map(|m| json!({"mass": m.mass.to_f64(), "distance": m.distance.to_f64()})).collect::<Vec<_>>(),
            "rings": p.rings.to_f64(),
            "tidal_strength": p.tidal_strength().to_f64(),
            "day_night_swing": w.day_night_swing().to_f64(),
            "living_species": w.living_species().count(),
            "living_individuals": w.living_individuals().count(),
            "civilizations": living_civs.len(),
            "wars": wars,
            "species_ever": w.species.last().map_or(0, |s| s.id),
            "atmosphere": atmosphere,
            "hash": format!("{:016x}", w.state_hash()),
            "focus": self.focus.map_or(-1, |k| k as i64),
            "moon_slots": self.world.planet.moon_slots,
            "eclipse": p.eclipse_fraction().to_f64(),
            "host": p.host.map(|h| json!({
                "planet_mass": h.mass.to_f64(),
                "planet_radius": h.radius.to_f64(),
                "distance": h.distance.to_f64(),
                "tidally_locked": !p.godhand,
            })),
        }))
    }

    #[func]
    fn region_json(&self, x: i64, y: i64) -> GString {
        let w = self.view();
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
        let settlement = w.settlement_at(i).map(|(c, s)| {
            json!({"name": s.name, "civ": c.name, "civ_id": c.id, "population": s.population.to_f64()})
        });
        to_gstring(json!({
            "x": x, "y": y,
            "settlement": settlement,
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
            "veil": w.veil(i).to_f64(),
            "mana": w.mana(i).to_f64(),
            "qi": w.qi(i).to_f64(),
            "substances": substances,
            "best_profile": best,
            "populations": pops,
        }))
    }

    /// Living species sorted by biomass, largest first.
    #[func]
    fn species_json(&self, limit: i64) -> GString {
        let w = self.view();
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
        let w = self.view();
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
        let w = self.view();
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

    /// Civilizations: the living ones first (largest first), then the fallen
    /// (most recent first).
    #[func]
    fn civilizations_json(&self) -> GString {
        let w = self.view();
        let tpy = sim_core::world::TICKS_PER_YEAR;
        let mut civs: Vec<_> = w.civs.iter().collect();
        civs.sort_by(|a, b| {
            b.is_alive()
                .cmp(&a.is_alive())
                .then(b.fallen_tick.cmp(&a.fallen_tick))
                .then(b.population().cmp(&a.population()))
                .then(a.id.cmp(&b.id))
        });
        let name_of = |id: u32| w.civilization(id).map_or("a forgotten people".to_string(), |c| c.name.clone());
        let list: Vec<Value> = civs
            .iter()
            .map(|c| {
                let species = w.species_by_id(c.species);
                let related = |keep: &dyn Fn(&sim_core::civ::Relation) -> bool| {
                    c.relations
                        .iter()
                        .filter(|r| keep(r) && w.civilization(r.other).is_some_and(|o| o.is_alive()))
                        .map(|r| name_of(r.other))
                        .collect::<Vec<_>>()
                };
                let half = Fx::ratio(1, 2);
                json!({
                    "id": c.id, "name": c.name,
                    "species": species.map(|s| s.name.clone()), "species_id": c.species,
                    "color": hex(c.color),
                    "era": sim_core::civ::ERAS[w.era(c)].0,
                    "arcana": sim_core::civ::ARCANA[w.arcana_level(c)].0,
                    "settlements": c.settlements.len(),
                    "capital": c.capital().map(|s| s.name.clone()),
                    "population": c.population().to_f64(),
                    "culture": c.culture.describe(),
                    "founded_year": c.founded_tick / tpy,
                    "fallen_year": c.fallen_tick.map(|t| t / tpy),
                    "parent": c.parent.map(name_of),
                    "battles_won": c.battles_won, "battles_lost": c.battles_lost,
                    "wars": related(&|r| r.at_war),
                    "allies": related(&|r| r.opinion >= half),
                    "rivals": related(&|r| r.opinion <= -half && !r.at_war),
                })
            })
            .collect();
        to_gstring(json!(list))
    }

    /// Living named individuals, most renowned first.
    #[func]
    fn individuals_json(&self, limit: i64) -> GString {
        let w = self.view();
        let mut living: Vec<_> = w.living_individuals().collect();
        living.sort_by(|a, b| b.renown.cmp(&a.renown).then(a.id.cmp(&b.id)));
        let list: Vec<Value> = living
            .iter()
            .take(limit.max(0) as usize)
            .map(|x| {
                let species = w.species_by_id(x.species);
                let sheet = sim_core::sheet::individual_sheet(w, x);
                json!({
                    "id": x.id, "title": x.title(), "name": x.name,
                    "species": species.map(|s| s.name.clone()), "species_id": x.species,
                    "color": species.map(|s| hex(s.color)),
                    "x": x.region % WIDTH, "y": x.region / WIDTH,
                    "age": x.age_years(w.tick), "charisma": x.charisma(), "renown": x.renown.to_f64(),
                    "friends": x.friends(), "enemies": x.enemies(),
                    "personality": x.personality.describe(),
                    "last_action": x.last_action.map(|a| sim_core::brain::output::NAMES[a]),
                    "cost": sheet.as_ref().map(|sh| sh.cost.cost),
                    "class": sheet.and_then(|sh| sh.class),
                })
            })
            .collect();
        to_gstring(json!(list))
    }

    /// Everything about one individual: relationships and life story.
    /// Returns "null" if no record exists.
    #[func]
    fn individual_json(&self, id: i64) -> GString {
        let w = self.view();
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
        let class = sim_core::sheet::individual_sheet(w, x).and_then(|sh| sh.class);
        to_gstring(json!({
            "id": x.id, "title": x.title(), "alive": x.is_alive(),
            "species": species.map(|s| s.name.clone()), "species_id": x.species,
            "species_description": species.map(|s| s.description(w)),
            "x": x.region % WIDTH, "y": x.region / WIDTH,
            "age": x.age_years(w.tick), "lifespan_years": x.lifespan / tpy,
            "health": x.health.to_f64(), "renown": x.renown.to_f64(), "charisma": x.charisma(),
            "personality": p.describe(),
            "class": class, "soul": x.soul.to_f64(),
            "realm": x.realm.checked_sub(1).and_then(|r| sim_core::laws::REALMS.get(r as usize)),
            "past_life": x.past_life.and_then(|o| w.individual_by_id(o)).map(|o| o.title()),
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
        self.globe = Some(self.view().globe_maps(w, h));
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

    /// RGBA8: RGB the colour of the people holding each place, A city
    /// lights.
    #[func]
    fn globe_info(&self) -> PackedByteArray {
        self.globe.as_ref().map_or_else(PackedByteArray::new, |g| {
            PackedByteArray::from(g.info.as_slice())
        })
    }

    /// Builds the maps of another body: moon `index`, or the planet itself
    /// for -1 (to show beside a focused moon). Read them with `aux_*`.
    /// Returns false if there is no such body.
    #[func]
    fn build_body_globe(&mut self, index: i64, width: i64, height: i64) -> bool {
        let body = match usize::try_from(index) {
            Ok(k) => self.world.moon(k),
            Err(_) => Some(&self.world),
        };
        let Some(body) = body else {
            return false;
        };
        let (w, h) = (width.clamp(16, 4096) as usize, height.clamp(8, 2048) as usize);
        self.aux_globe = Some(body.globe_maps(w, h));
        true
    }

    #[func]
    fn aux_albedo(&self) -> PackedByteArray {
        self.aux_globe.as_ref().map_or_else(PackedByteArray::new, |g| PackedByteArray::from(g.albedo.as_slice()))
    }

    #[func]
    fn aux_data(&self) -> PackedByteArray {
        self.aux_globe.as_ref().map_or_else(PackedByteArray::new, |g| PackedByteArray::from(g.data.as_slice()))
    }

    #[func]
    fn aux_info(&self) -> PackedByteArray {
        self.aux_globe.as_ref().map_or_else(PackedByteArray::new, |g| PackedByteArray::from(g.info.as_slice()))
    }

    /// Marks for the globe of the world in focus: {"marks": [{kind:
    /// "capital"|"settlement"|"hero", x, y, name, color, size}], "wars":
    /// [{x1, y1, x2, y2, color_a, color_b}]}. `heroes` is how many of the
    /// most renowned individuals to include.
    #[func]
    fn globe_markers_json(&self, heroes: i64) -> GString {
        use sim_core::globe::MarkerKind;
        let (marks, wars) = self.view().globe_markers(heroes.clamp(0, 300) as usize);
        let marks: Vec<Value> = marks
            .iter()
            .map(|m| {
                json!({
                    "kind": match m.kind { MarkerKind::Capital => "capital", MarkerKind::Settlement => "settlement", MarkerKind::Hero => "hero" },
                    "x": m.region % WIDTH, "y": m.region / WIDTH,
                    "name": m.name, "color": hex(m.color), "size": m.size,
                })
            })
            .collect();
        let wars: Vec<Value> = wars
            .iter()
            .map(|w| {
                json!({
                    "x1": w.from % WIDTH, "y1": w.from / WIDTH, "x2": w.to % WIDTH, "y2": w.to / WIDTH,
                    "color_a": hex(w.color_a), "color_b": hex(w.color_b),
                })
            })
            .collect();
        to_gstring(json!({"marks": marks, "wars": wars}))
    }

    /// A one-line summary of a region for hovering: its name on the map,
    /// whose land it is, what lives there.
    #[func]
    fn region_summary(&self, x: i64, y: i64) -> GString {
        let w = self.view();
        let i = index(coord(x, WIDTH) as usize, coord(y, HEIGHT) as usize);
        let r = &w.regions[i];
        let mut bits = vec![format!("{:.0} K", r.temperature.to_f64())];
        if let Some(c) = w.living_civs().find(|c| c.settlements.iter().any(|s| s.region == i)) {
            let s = c.settlements.iter().find(|s| s.region == i).unwrap();
            bits.push(format!("{} of the {} ({:.1}k)", s.name, c.name, s.population.to_f64()));
        }
        if let Some((id, total)) = w.dominant_species(i) {
            if let Some(sp) = w.species_by_id(id) {
                bits.push(format!("{} ({:.0} biomass)", sp.name, total.to_f64()));
            }
        } else {
            bits.push("lifeless".into());
        }
        let heroes = w.living_individuals().filter(|x| x.region == i).count();
        if heroes > 0 {
            bits.push(format!("{heroes} named being{}", if heroes == 1 { "" } else { "s" }));
        }
        GString::from(bits.join(" · ").as_str())
    }

    #[func]
    fn atmosphere_json(&self) -> GString {
        let a = self.view().atmosphere_look();
        to_gstring(json!({
            "color": a.color, "thickness": a.thickness, "clouds": a.clouds,
            "cloud_color": a.cloud_color, "sunlight": a.sunlight,
            "veil_open": (Fx::ONE - self.view().veil_mean()).to_f64(),
            "star_color": hex(self.view().planet.star_type.info().color),
        }))
    }

    /// Character sheet (§5) of a species ("species") or a named individual
    /// ("individual"). Returns "null" if no record exists.
    #[func]
    fn sheet_json(&self, kind: GString, id: i64) -> GString {
        let w = self.view();
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

    /// A champion from this world died in a ranked match: log its death so
    /// the world replays without it (§6.2a).
    /// `moon` is the moon it lived on, or -1 for the planet.
    #[func]
    fn champion_fell(&mut self, individual: i64, moon: i64) {
        if individual < 0 {
            return;
        }
        let fell = Action::ChampionFell {
            individual: individual as u32,
        };
        self.world.apply(match u8::try_from(moon) {
            Ok(moon) => Action::OnMoon {
                moon,
                action: Box::new(fell),
            },
            Err(_) => fell,
        });
    }

    /// Brings looted remains (a grant from the arena server, as JSON) into
    /// this world, in the region that suits them best. Returns the new
    /// species' name, or "" if the grant is unreadable.
    #[func]
    fn apply_loot(&mut self, grant_json: GString) -> GString {
        let Ok(grant) = serde_json::from_str::<sim_core::loot::LootGrant>(&grant_json.to_string()) else {
            return GString::new();
        };
        let (x, y) = self.world.best_region_for(&grant.remains.profile);
        self.world.apply(Action::Loot {
            grant: Box::new(grant),
            x,
            y,
        });
        self.world
            .species
            .last()
            .map_or(GString::new(), |s| GString::from(s.name.as_str()))
    }

    /// Everything in the Essence shop: [{item, name, price}], where `item`
    /// is the JSON to pass to `ArenaNet.buy`.
    #[func]
    fn shop_catalogue_json(&self) -> GString {
        let items: Vec<Value> = sim_core::shop::catalogue(&self.world)
            .into_iter()
            .map(|(item, name, price)| json!({"item": item, "name": name, "price": price}))
            .collect();
        to_gstring(json!(items))
    }

    /// Logs a shop purchase (a grant from the server, as JSON) in the world.
    /// A deposit lands around region (x, y) of the world in focus; a moon
    /// slot goes to the planet. Returns false if the grant is unreadable.
    #[func]
    fn apply_purchase(&mut self, grant_json: GString, x: i64, y: i64) -> bool {
        let Ok(grant) = serde_json::from_str::<sim_core::shop::ShopGrant>(&grant_json.to_string()) else {
            return false;
        };
        let deposit = matches!(grant.item, sim_core::shop::ShopItem::Deposit { .. });
        let action = Action::Purchase {
            grant: Box::new(grant),
            x: coord(x, WIDTH),
            y: coord(y, HEIGHT),
        };
        if deposit {
            self.act(action);
        } else {
            self.world.apply(action);
        }
        true
    }

    /// Ids of the loot and shop grants already logged in this world (its
    /// moons included): {"loot": [..], "purchases": [..]}.
    #[func]
    fn used_grants_json(&self) -> GString {
        let (mut loot, mut purchases) = (Vec::new(), Vec::new());
        for a in &self.world.log().actions {
            let a = match a {
                Action::OnMoon { action, .. } => action.as_ref(),
                a => a,
            };
            match a {
                Action::Loot { grant, .. } => loot.push(grant.id),
                Action::Purchase { grant, .. } => purchases.push(grant.id),
                _ => {}
            }
        }
        to_gstring(json!({"loot": loot, "purchases": purchases}))
    }

    /// The planet's seed (champion tokens name their home planet by it).
    #[func]
    fn seed(&self) -> i64 {
        self.world.seed as i64
    }

    /// Shows and edits the world of moon `index`, or the planet for -1.
    /// Returns false (and keeps the focus) for a moon that does not exist.
    /// Time, the star and the moons themselves always belong to the planet.
    #[func]
    fn focus_moon(&mut self, index: i64) -> bool {
        if index < 0 {
            self.focus = None;
            return true;
        }
        if (index as usize) < self.world.moon_worlds.len() {
            self.focus = Some(index as usize);
            true
        } else {
            false
        }
    }

    /// The moon in focus, or -1 for the planet.
    #[func]
    fn focused_moon(&self) -> i64 {
        self.focus.map_or(-1, |k| k as i64)
    }

    /// Moves moon `index` to a new orbit (Earth–Moon distances).
    #[func]
    fn set_moon_orbit(&mut self, index: i64, distance: f64) {
        if let Ok(moon) = u8::try_from(index) {
            self.world.apply(Action::SetMoonOrbit {
                moon,
                distance: Fx::from_f64(distance),
            });
        }
    }

    /// The planet's moons and a summary of the world on each.
    #[func]
    fn moons_json(&self) -> GString {
        let p = &self.world.planet;
        let moons: Vec<Value> = p
            .moons
            .iter()
            .zip(&self.world.moon_worlds)
            .enumerate()
            .map(|(k, (m, w))| {
                json!({
                    "index": k,
                    "mass": m.mass.to_f64(),
                    "distance": m.distance.to_f64(),
                    "month_hours": sim_core::world::Planet::moon_period_hours(p.planet_mass, w.planet.planet_mass, m.distance).to_f64(),
                    "gravity": w.planet.gravity.to_f64(),
                    "radius": w.planet.planet_radius.to_f64(),
                    "day_length": w.planet.day_length_hours.to_f64(),
                    "mean_temperature": w.mean_temperature.to_f64(),
                    "pressure": w.pressure.to_f64(),
                    "eclipse": w.planet.eclipse_fraction().to_f64(),
                    "tidal_strength": w.planet.tidal_strength().to_f64(),
                    "living_species": w.living_species().count(),
                    "living_individuals": w.living_individuals().count(),
                    "civilizations": w.living_civs().count(),
                })
            })
            .collect();
        to_gstring(json!({"moons": moons, "slots": p.moon_slots, "focus": self.focus.map_or(-1, |k| k as i64)}))
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
                self.focus = None;
                true
            }
            Err(e) => {
                godot_error!("could not load world log: {e}");
                false
            }
        }
    }
}

/// Real-time arena match run by the Rust core (`sim_core::arena`). Godot
/// only renders it and forwards player commands, so the same match can be
/// replayed on a server from the rosters, seed and command log.
#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct ArenaSim {
    teams: [Vec<sim_core::sheet::CharacterSheet>; 2],
    arena: Option<sim_core::arena::Arena>,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for ArenaSim {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            teams: [Vec::new(), Vec::new()],
            arena: None,
            base,
        }
    }
}

#[godot_api]
impl ArenaSim {
    /// Adds a champion to a team (0 = player, 1 = rival) before `start`,
    /// using the character sheet of a species ("species") or named
    /// individual ("individual") from `world`, or from its moon `moon`
    /// (-1 for the planet).
    #[func]
    fn add_unit(&mut self, world: Gd<SimWorld>, kind: GString, id: i64, team: i64, moon: i64) -> bool {
        if self.arena.is_some() || !(0..=1).contains(&team) {
            return false;
        }
        let planet = world.bind();
        let Some(w) = (match usize::try_from(moon) {
            Ok(k) => planet.world.moon(k),
            Err(_) => Some(&planet.world),
        }) else {
            return false;
        };
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
            Some(s) => {
                self.teams[team as usize].push(s);
                true
            }
            None => false,
        }
    }

    #[func]
    fn start(&mut self, seed: i64) {
        let [a, b] = std::mem::take(&mut self.teams);
        self.arena = Some(sim_core::arena::Arena::new(a, b, seed as u64));
    }

    /// Advances `ticks` steps of 0.1 s.
    #[func]
    fn step(&mut self, ticks: i64) {
        if let Some(a) = self.arena.as_mut() {
            for _ in 0..ticks.clamp(0, 1000) {
                a.step();
            }
        }
    }

    /// Possess one of your units, or release with -1.
    #[func]
    fn possess(&mut self, unit: i64) {
        if let Some(a) = self.arena.as_mut() {
            a.command(sim_core::arena::ArenaCommand::Possess {
                team: 0,
                unit: (unit >= 0).then_some(unit as usize),
            });
        }
    }

    #[func]
    fn steer(&mut self, unit: i64, x: f64, z: f64) {
        if let (Some(a), true) = (self.arena.as_mut(), unit >= 0) {
            a.command(sim_core::arena::ArenaCommand::Steer {
                unit: unit as usize,
                x: Fx::from_f64(x),
                z: Fx::from_f64(z),
            });
        }
    }

    #[func]
    fn attack(&mut self, unit: i64) {
        if let (Some(a), true) = (self.arena.as_mut(), unit >= 0) {
            a.command(sim_core::arena::ArenaCommand::Attack {
                unit: unit as usize,
            });
        }
    }

    #[func]
    fn breathe(&mut self, unit: i64) {
        if let (Some(a), true) = (self.arena.as_mut(), unit >= 0) {
            a.command(sim_core::arena::ArenaCommand::Breathe {
                unit: unit as usize,
            });
        }
    }

    /// Positions, facing, hit points and status of every unit, plus the
    /// arena clock and result ("a", "b", "draw" or null).
    #[func]
    fn state_json(&self) -> GString {
        match self.arena.as_ref() {
            Some(a) => to_gstring(arena_state(a, 0)),
            None => GString::from("null"),
        }
    }

    /// Readable log lines for events since the last call.
    #[func]
    fn events_json(&mut self) -> GString {
        let Some(a) = self.arena.as_mut() else {
            return GString::from("[]");
        };
        let events = a.take_events();
        to_gstring(json!(event_lines(a, &events)))
    }

    /// Number of player commands recorded (they make the match replayable).
    #[func]
    fn command_count(&self) -> i64 {
        self.arena
            .as_ref()
            .map_or(0, |a| a.command_log.len() as i64)
    }
}

/// Positions, facing, hit points and status of every unit, plus the arena
/// clock, the result ("a", "b", "draw" or null) and which side is yours.
fn arena_state(a: &sim_core::arena::Arena, my_team: u8) -> Value {
    let units: Vec<Value> = a
        .units
        .iter()
        .map(|u| {
            json!({
                "x": u.pos.x.to_f64(), "z": u.pos.z.to_f64(),
                "fx": u.facing.x.to_f64(), "fz": u.facing.z.to_f64(),
                "hp": u.hp, "max_hp": u.sheet.hit_points, "alive": u.alive, "team": u.team,
                "possessed": u.possessed, "breath_ready": u.breath_ready, "has_breath": u.sheet.breath.is_some(),
                "radius": u.radius.to_f64(), "name": u.sheet.name, "size": u.sheet.size.name(),
                "speed": u.speed.to_f64(),
            })
        })
        .collect();
    let result = a.result.map(|r| match r {
        sim_core::arena::ArenaResult::TeamA => "a",
        sim_core::arena::ArenaResult::TeamB => "b",
        sim_core::arena::ArenaResult::Draw => "draw",
    });
    json!({"time": a.time.to_f64(), "result": result, "units": units, "my_team": my_team})
}

/// Readable log lines for arena events.
fn event_lines(a: &sim_core::arena::Arena, events: &[sim_core::arena::ArenaEvent]) -> Vec<String> {
    let name = |i: usize| a.units[i].sheet.name.clone();
    events
        .iter()
        .filter_map(|e| match e {
            sim_core::arena::ArenaEvent::Breath {
                attacker,
                name: breath,
                targets,
            } => Some(format!(
                "{} uses {} ({} {}).",
                name(*attacker),
                breath,
                targets.len(),
                if targets.len() == 1 { "target" } else { "targets" }
            )),
            sim_core::arena::ArenaEvent::Fell { unit, by } => Some(format!(
                "{} [color=#cc6666]falls[/color] to {}.",
                name(*unit),
                name(*by)
            )),
            _ => None,
        })
        .collect()
}
