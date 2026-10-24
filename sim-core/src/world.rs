//! The world: planet parameters, regions, climate and the substance cycle.
//!
//! Phase 0 runs only the regional layer (L1 in docs/GAME_DESIGN.md §4.1) on a
//! 2D equirectangular grid. One tick is one season; four ticks make a year.

use serde::{Deserialize, Serialize};
use crate::action::{Action, ActionLog};
use crate::fixed::Fx;
use crate::hash::StateHasher;
use crate::individual::Individual;
use crate::life::{RegionLife, Species};
use crate::rng::Rng;
use crate::star::StarType;
use crate::substance::{default_substances, Phase, Substance};

pub const WIDTH: usize = 64;
pub const HEIGHT: usize = 32;
pub const REGION_COUNT: usize = WIDTH * HEIGHT;
pub const TICKS_PER_YEAR: u64 = 4;

/// Liquids pool in low regions: one unit of liquid raises the surface by this
/// fraction of the full elevation range.
const LIQUID_DEPTH_PER_UNIT: Fx = Fx::ratio(1, 6);

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Planet {
    pub star_distance_au: Fx,
    pub star_luminosity: Fx,
    pub gravity: Fx,
    pub global_heat: Fx,
    /// Length of a day in hours. Long days mean hot days and cold nights.
    pub day_length_hours: Fx,
    /// Axial tilt in degrees. Tilt makes seasons.
    pub axial_tilt_deg: Fx,
    pub moons: Vec<Moon>,
    /// Mass (in lunar masses) of rings left by moons torn apart.
    pub rings: Fx,
    /// Godhand mode: every value is set freely, even impossible ones.
    /// Natural mode (false): linked values follow physics.
    pub godhand: bool,
    pub star_type: StarType,
    /// Star mass in solar masses.
    pub star_mass: Fx,
    /// Planet mass and radius relative to Earth.
    pub planet_mass: Fx,
    pub planet_radius: Fx,
    /// Tick of the most recent stellar flare, if any.
    pub last_flare_tick: Option<u64>,
    /// How many moons this world may hold: one free, more bought with
    /// Essence (§3).
    #[serde(default = "one")]
    pub moon_slots: u8,
    /// For a moon's world: the planet it orbits.
    #[serde(default)]
    pub host: Option<Host>,
}

fn one() -> u8 {
    1
}

/// The planet a moon world orbits, as the moon sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Host {
    /// Planet mass and radius relative to Earth.
    pub mass: Fx,
    pub radius: Fx,
    /// Orbit in Earth–Moon distances.
    pub distance: Fx,
}

/// The Moon's mass in Earth masses.
pub const LUNAR_MASS: Fx = Fx::ratio(123, 10000);
/// A rocky moon's density relative to Earth's (the Moon: 3.34 / 5.51).
const MOON_DENSITY: Fx = Fx::ratio(606, 1000);

/// A moon. Mass in lunar masses, distance in Earth–Moon distances.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Moon {
    pub mass: Fx,
    pub distance: Fx,
}

/// Moons closer than this (Earth–Moon distances) are torn apart into rings
/// (roughly the Roche limit).
pub const ROCHE_LIMIT: Fx = Fx::ratio(3, 10);
pub const MAX_MOONS: usize = 12;

impl Default for Planet {
    fn default() -> Planet {
        Planet {
            star_distance_au: Fx::ONE,
            star_luminosity: Fx::ONE,
            gravity: Fx::ONE,
            global_heat: Fx::ZERO,
            day_length_hours: Fx::from_int(24),
            axial_tilt_deg: Fx::ZERO,
            moons: Vec::new(),
            rings: Fx::ZERO,
            godhand: false,
            star_type: StarType::YellowDwarf,
            star_mass: Fx::ONE,
            planet_mass: Fx::ONE,
            planet_radius: Fx::ONE,
            last_flare_tick: None,
            moon_slots: 1,
            host: None,
        }
    }
}

impl Planet {
    /// Surface gravity physics gives: mass / radius².
    pub fn natural_gravity(&self) -> Fx {
        self.planet_mass / (self.planet_radius * self.planet_radius)
    }

    pub fn natural_luminosity(&self) -> Fx {
        self.star_type.natural_luminosity(self.star_mass)
    }

    /// Orbital period in Earth years (Kepler: √(d³ / M)).
    pub fn year_length(&self) -> Fx {
        let d = self.star_distance_au;
        (d * d * d / self.star_mass).sqrt()
    }

    /// Farthest stable moon orbit, in Earth–Moon distances: about half the
    /// planet's Hill sphere (3.9 Earth–Moon distances for Earth).
    pub fn moon_limit(&self) -> Fx {
        let ratio = self.planet_mass / self.star_mass;
        let cube_root = (ratio.log2() / Fx::from_int(3)).exp2();
        Fx::ratio(195, 100) * self.star_distance_au * cube_root
    }

    /// Harmful radiation reaching the top of the atmosphere, relative to
    /// what the Sun delivers to Earth.
    pub fn radiation_flux(&self) -> Fx {
        let d = self.star_distance_au;
        self.star_type.info().radiation / Fx::ratio(2, 10) / (d * d)
    }

    /// How far Godhand settings are from what physics allows. Zero in
    /// Natural mode. Strain has harsh side effects and thins the Veil.
    pub fn strain(&self) -> Fx {
        if !self.godhand {
            return Fx::ZERO;
        }
        let off = |actual: Fx, natural: Fx| (actual / natural.max(Fx::ratio(1, 10000))).log2().abs();
        let limit = self.moon_limit();
        let unstable = self
            .moons
            .iter()
            .filter(|m| m.distance > limit || m.distance < ROCHE_LIMIT)
            .count() as i64;
        (off(self.gravity, self.natural_gravity()) + off(self.star_luminosity, self.natural_luminosity()) + Fx::ratio(unstable, 2))
            .min(Fx::from_int(20))
    }

    /// In Natural mode, recomputes linked values and keeps moons between
    /// the Roche limit and the stable limit. A moon is drawn in, never
    /// lost, when the stable limit shrinks: each moon is a world.
    pub fn enforce_natural(&mut self) {
        if self.godhand {
            return;
        }
        self.gravity = self.natural_gravity().clamp(Fx::ratio(1, 100), Fx::from_int(50));
        self.star_luminosity = self.natural_luminosity();
        let limit = self.moon_limit().max(ROCHE_LIMIT);
        for m in &mut self.moons {
            m.distance = m.distance.clamp(ROCHE_LIMIT, limit);
        }
    }

    /// Tidal strength relative to Earth's Moon: Σ mass / distance³. A moon
    /// world also feels its planet: tidally locked, it flexes only a
    /// little (5% of the planet's pull), as Io does.
    pub fn tidal_strength(&self) -> Fx {
        let moons = self.moons.iter().fold(Fx::ZERO, |acc, m| {
            let d = m.distance.max(ROCHE_LIMIT);
            acc + m.mass / (d * d * d)
        });
        let host = self.host.map_or(Fx::ZERO, |h| {
            let d = h.distance.max(ROCHE_LIMIT);
            h.mass / LUNAR_MASS / (d * d * d) * Fx::ratio(5, 100)
        });
        moons + host
    }

    /// For a moon world: the share of each orbit spent in the planet's
    /// shadow, radius / (π × distance × 60.3 Earth radii).
    pub fn eclipse_fraction(&self) -> Fx {
        self.host.map_or(Fx::ZERO, |h| {
            let d = h.distance.max(Fx::ratio(5, 100));
            (h.radius / (Fx::ratio(314159, 100000) * d * Fx::ratio(603, 10))).min(Fx::HALF)
        })
    }

    /// A moon's orbital period around its planet, in hours (Kepler: the
    /// Moon's 27.3 days × √(distance³ / total mass), masses in Earths).
    pub fn moon_period_hours(planet_mass: Fx, moon_mass_earths: Fx, distance: Fx) -> Fx {
        let total = (planet_mass + moon_mass_earths).max(Fx::ratio(1, 1000)) / (Fx::ONE + LUNAR_MASS);
        let d = distance.max(Fx::ratio(5, 100));
        Fx::ratio(2732, 100) * Fx::from_int(24) * (d * d * d / total).sqrt()
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Population {
    pub species: u32,
    pub biomass: Fx,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Region {
    /// 0..1, generated from the seed.
    pub elevation: Fx,
    /// 0..1, volcanic and tidal heat from below.
    pub geothermal: Fx,
    /// Player heating or cooling in kelvin.
    pub heat_offset: Fx,
    /// Surface temperature in kelvin (derived each tick).
    pub temperature: Fx,
    /// Non-gaseous substance amounts held in this region, by substance index.
    pub amounts: Vec<Fx>,
    pub populations: Vec<Population>,
}

#[derive(Serialize, Deserialize)]
pub struct World {
    pub seed: u64,
    pub tick: u64,
    pub planet: Planet,
    /// The substance table; not stored in snapshots (it is data).
    #[serde(skip)]
    pub substances: Vec<Substance>,
    /// Distinct backbone elements (e.g. Carbon, Silicon), derived from the
    /// substance table.
    #[serde(skip)]
    pub elements: Vec<String>,
    pub regions: Vec<Region>,
    /// Atmospheric column of each substance, in units per region.
    pub atmosphere: Vec<Fx>,
    /// Surface pressure in bar (derived each tick).
    pub pressure: Fx,
    pub mean_temperature: Fx,
    pub species: Vec<Species>,
    pub(crate) next_species_id: u32,
    /// Named individuals, living and recently dead, in id order.
    pub individuals: Vec<Individual>,
    pub(crate) next_individual_id: u32,
    pub(crate) life: Vec<RegionLife>,
    /// Veil strength per region, 0 (open) .. 1 (sealed). See `veil`.
    pub(crate) veil: Vec<Fx>,
    /// The Veil law: 0 sealed .. 1 wide open.
    pub veil_law: Fx,
    /// Metaphysical laws (§4.6).
    #[serde(default)]
    pub laws: crate::laws::Laws,
    /// Souls waiting to be reborn (Soul Power).
    #[serde(default)]
    pub souls: Vec<crate::laws::WanderingSoul>,
    /// Civilizations, living and fallen (§4.5).
    #[serde(default)]
    pub civs: Vec<crate::civ::Civilization>,
    /// Gear looted from fallen champions (§5.4).
    #[serde(default)]
    pub armoury: Vec<crate::equipment::Looted>,
    /// Religions and cults, living and dead (§4.8).
    #[serde(default)]
    pub religions: Vec<crate::religion::Religion>,
    #[serde(default)]
    pub(crate) next_religion_id: u32,
    #[serde(default)]
    pub(crate) next_item_id: u32,
    #[serde(default)]
    pub(crate) next_civ_id: u32,
    /// The worlds of this planet's moons, in the order of `planet.moons`.
    #[serde(default)]
    pub moon_worlds: Vec<World>,
    #[serde(default)]
    pub(crate) moons_made: u32,
    pub last_breach_tick: Option<u64>,
    pub(crate) rng: Rng,
    log: ActionLog,
}

/// Backbone elements in substance-table order.
fn elements_of(substances: &[Substance]) -> Vec<String> {
    let mut elements: Vec<String> = Vec::new();
    for s in substances {
        if !s.backbone_element.is_empty() && !elements.contains(&s.backbone_element) {
            elements.push(s.backbone_element.clone());
        }
    }
    elements
}

/// Bumped whenever the world's stored form or rules change, so old
/// snapshots are not trusted.
const SNAPSHOT_VERSION: u32 = 9;

#[derive(Serialize)]
struct SnapshotRef<'a> {
    version: u32,
    world: &'a World,
}

#[derive(Deserialize)]
struct SnapshotOwned {
    version: u32,
    world: World,
}

impl World {
    /// The full world state, to resume later without replaying its log.
    pub fn snapshot(&self) -> Vec<u8> {
        serde_json::to_vec(&SnapshotRef {
            version: SNAPSHOT_VERSION,
            world: self,
        })
        .expect("worlds serialise")
    }

    /// Restores a world saved by `snapshot`. It continues exactly as the
    /// original would have.
    pub fn from_snapshot(bytes: &[u8]) -> Result<World, String> {
        let s: SnapshotOwned = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        if s.version != SNAPSHOT_VERSION {
            return Err("snapshot from another version".into());
        }
        let mut w = s.world;
        w.restore_tables()?;
        Ok(w)
    }

    /// Reloads the data tables a snapshot leaves out, moons included.
    fn restore_tables(&mut self) -> Result<(), String> {
        self.substances = default_substances();
        self.elements = elements_of(&self.substances);
        if self.regions.iter().any(|r| r.amounts.len() != self.substances.len())
            || self.atmosphere.len() != self.substances.len()
        {
            return Err("snapshot does not match the substance table".into());
        }
        for m in &mut self.moon_worlds {
            m.restore_tables()?;
        }
        Ok(())
    }

    pub fn new(seed: u64) -> World {
        let substances = default_substances();
        let elements = elements_of(&substances);
        let mut rng = Rng::new(seed);
        let elevation = value_noise(
            &mut rng,
            &[
                (8, 4, Fx::ratio(6, 10)),
                (16, 8, Fx::ratio(3, 10)),
                (32, 16, Fx::ratio(1, 10)),
            ],
        );
        let geo_raw = value_noise(
            &mut rng,
            &[(12, 6, Fx::ratio(7, 10)), (32, 16, Fx::ratio(3, 10))],
        );
        let n = substances.len();
        let regions = (0..REGION_COUNT)
            .map(|i| {
                // Sharpen geothermal noise into a few hot spots.
                let g = geo_raw[i];
                let geothermal = (g * g * g * g * Fx::from_int(3)).min(Fx::ONE);
                Region {
                    elevation: elevation[i],
                    geothermal,
                    heat_offset: Fx::ZERO,
                    temperature: Fx::ZERO,
                    amounts: vec![Fx::ZERO; n],
                    populations: Vec::new(),
                }
            })
            .collect();
        let mut world = World {
            seed,
            tick: 0,
            planet: Planet::default(),
            elements,
            regions,
            atmosphere: vec![Fx::ZERO; n],
            pressure: Fx::ZERO,
            mean_temperature: Fx::ZERO,
            species: Vec::new(),
            next_species_id: 1,
            individuals: Vec::new(),
            next_individual_id: 1,
            life: Vec::new(),
            veil: vec![Fx::ONE; REGION_COUNT],
            veil_law: Fx::ZERO,
            laws: crate::laws::Laws::default(),
            souls: Vec::new(),
            civs: Vec::new(),
            armoury: Vec::new(),
            next_item_id: 0,
            religions: Vec::new(),
            next_religion_id: 0,
            next_civ_id: 1,
            moon_worlds: Vec::new(),
            moons_made: 0,
            last_breach_tick: None,
            rng,
            log: ActionLog::new(seed),
            substances,
        };
        world.update_climate();
        world.update_life_scores();
        world
    }

    /// Rebuilds a world from a saved action log.
    pub fn replay(log: &ActionLog) -> World {
        let mut world = World::new(log.seed);
        for a in &log.actions {
            world.apply(a.clone());
        }
        world
    }

    pub fn log(&self) -> &ActionLog {
        &self.log
    }

    pub fn year(&self) -> u64 {
        self.tick / TICKS_PER_YEAR
    }

    pub fn substance_index(&self, key: &str) -> Option<usize> {
        self.substances.iter().position(|s| s.key == key)
    }

    pub fn apply(&mut self, action: Action) {
        let n = self.substances.len() as u16;
        match &action {
            Action::Tick { ticks } => {
                for _ in 0..*ticks {
                    self.step();
                }
            }
            Action::AddSubstance {
                x,
                y,
                radius,
                substance,
                amount,
            } => {
                if *substance >= n || self.bought_only(*substance, *amount) {
                    return;
                }
                let touched = brush(*x, *y, *radius);
                for &i in &touched {
                    let a = &mut self.regions[i].amounts[*substance as usize];
                    *a = (*a + *amount).max(Fx::ZERO);
                }
                // Gifts from the sky are miracles; taking things away is not
                // kind. (§4.8 religion)
                self.witness(Some(&touched), (*amount).clamp(-Fx::ONE, Fx::ONE) * Fx::ratio(3, 10));
            }
            Action::AddSubstanceGlobal { substance, amount } => {
                if *substance >= n || self.bought_only(*substance, *amount) {
                    return;
                }
                for r in &mut self.regions {
                    let a = &mut r.amounts[*substance as usize];
                    *a = (*a + *amount).max(Fx::ZERO);
                }
                self.witness(None, (*amount).clamp(-Fx::ONE, Fx::ONE) * Fx::ratio(2, 10));
            }
            Action::HeatRegion {
                x,
                y,
                radius,
                delta,
            } => {
                let touched = brush(*x, *y, *radius);
                for &i in &touched {
                    let h = &mut self.regions[i].heat_offset;
                    *h = (*h + *delta).clamp(Fx::from_int(-2000), Fx::from_int(5000));
                }
                // Fire and frost from the sky: a gentle touch is a blessing,
                // a fierce one a terror.
                let fierce = (*delta).abs() / Fx::from_int(20);
                self.witness(Some(&touched), Fx::ratio(2, 10) - fierce.min(Fx::from_int(2)));
            }
            Action::SetGlobalHeat { kelvin } => {
                let change = (*kelvin - self.planet.global_heat).abs();
                self.planet.global_heat = (*kelvin).clamp(Fx::from_int(-500), Fx::from_int(3000));
                self.witness(None, -(change / Fx::from_int(50)).min(Fx::from_int(2)));
            }
            Action::SetStarDistance { au } => {
                self.planet.star_distance_au = (*au).clamp(Fx::ratio(1, 100), Fx::from_int(100));
            }
            Action::SetStarLuminosity { suns } => {
                let suns = (*suns).clamp(Fx::ratio(1, 10000), Fx::from_int(100_000));
                if self.planet.godhand {
                    self.planet.star_luminosity = suns;
                } else {
                    // Natural: brightness comes from the star's mass.
                    self.planet.star_mass = self.planet.star_type.mass_for_luminosity(suns);
                }
            }
            Action::SetGravity { g } => {
                let g = (*g).clamp(Fx::ratio(1, 100), Fx::from_int(50));
                if self.planet.godhand {
                    self.planet.gravity = g;
                } else {
                    // Natural: gravity comes from mass; keep the radius.
                    let r = self.planet.planet_radius;
                    self.planet.planet_mass = (g * r * r).clamp(Fx::ratio(1, 1000), Fx::from_int(5000));
                }
            }
            Action::SetGodhand { on } => self.planet.godhand = *on,
            Action::SetStarType { star } => {
                let kind = StarType::from_index(*star);
                self.planet.star_type = kind;
                self.planet.star_mass = kind.info().mass;
                self.planet.star_luminosity = kind.natural_luminosity(kind.info().mass);
            }
            Action::SetStarMass { solar } => {
                let info = self.planet.star_type.info();
                self.planet.star_mass = if self.planet.godhand {
                    (*solar).clamp(Fx::ratio(5, 100), Fx::from_int(100))
                } else {
                    (*solar).clamp(info.min_mass, info.max_mass)
                };
            }
            Action::SetPlanetRadius { earths } => {
                self.planet.planet_radius = (*earths).clamp(Fx::ratio(1, 10), Fx::from_int(20));
            }
            Action::SetDayLength { hours } => {
                self.planet.day_length_hours = (*hours).clamp(Fx::ONE, Fx::from_int(10_000));
            }
            Action::SetAxialTilt { degrees } => {
                self.planet.axial_tilt_deg = (*degrees).clamp(Fx::ZERO, Fx::from_int(90));
            }
            Action::AddMoon { mass, distance } => self.add_moon(*mass, *distance),
            Action::SetMoonOrbit { moon, distance } => {
                if let Some(m) = self.planet.moons.get_mut(*moon as usize) {
                    m.distance = (*distance).clamp(Fx::ratio(5, 100), Fx::from_int(50));
                }
                self.planet.enforce_natural();
                self.sort_moons();
            }
            Action::OnMoon { moon, action } => {
                let allowed = matches!(
                    **action,
                    Action::AddSubstance { .. }
                        | Action::AddSubstanceGlobal { .. }
                        | Action::HeatRegion { .. }
                        | Action::SetGlobalHeat { .. }
                        | Action::SetGravity { .. }
                        | Action::SetDayLength { .. }
                        | Action::SetAxialTilt { .. }
                        | Action::SetPlanetRadius { .. }
                        | Action::SetVeilLaw { .. }
                        | Action::SetLaw { .. }
                        | Action::ChampionFell { .. }
                        | Action::Loot { .. }
                        | Action::Purchase { .. }
                        | Action::Equip { .. }
                        | Action::Unequip { .. }
                        | Action::Refit { .. }
                );
                if let (true, Some(m)) = (allowed, self.moon_worlds.get_mut(*moon as usize)) {
                    m.apply((**action).clone());
                }
            }
            Action::ChampionFell { individual } => self.champion_fell(*individual),
            Action::Loot { grant, x, y } => self.apply_loot(grant, *x, *y),
            Action::Purchase { grant, x, y } => self.apply_purchase(grant, *x, *y),
            Action::Equip { item, individual } => self.equip(*item, *individual),
            Action::Unequip { item } => self.unequip(*item),
            Action::Refit { item, individual } => self.refit(*item, *individual),
            Action::SetLaw { law, value } => self.set_law(*law, *value),
            Action::SetVeilLaw { openness } => {
                self.veil_law = (*openness).clamp(Fx::ZERO, Fx::ONE);
            }
            Action::RemoveMoon { index } => {
                if (*index as usize) < self.planet.moons.len() {
                    self.planet.moons.remove(*index as usize);
                    self.moon_worlds.remove(*index as usize);
                }
            }
        }
        self.planet.enforce_natural();
        self.sync_moons();
        if !matches!(action, Action::Tick { .. }) {
            // Show the effect of tool use immediately, without advancing time.
            self.update_climate();
            self.update_life_scores();
            for m in &mut self.moon_worlds {
                m.planet.enforce_natural();
                m.update_climate();
                m.update_life_scores();
            }
        }
        self.log.push(action);
    }

    /// Shop elements cannot be added with the free tools, only bought
    /// (§3). Taking them away is free.
    fn bought_only(&self, substance: u16, amount: Fx) -> bool {
        amount > Fx::ZERO && self.substances[substance as usize].shop.is_some()
    }

    /// Adds a moon and the world on it. Too close and it is torn into
    /// rings. It needs a free moon slot and its own orbit; moons have no
    /// moons of their own.
    fn add_moon(&mut self, mass: Fx, distance: Fx) {
        if self.planet.host.is_some() {
            return;
        }
        let mass = mass.clamp(Fx::ratio(1, 100), Fx::from_int(50));
        let distance = distance.clamp(Fx::ratio(5, 100), Fx::from_int(50));
        if distance < ROCHE_LIMIT {
            self.planet.rings += mass;
            return;
        }
        let slots = (self.planet.moon_slots as usize).min(MAX_MOONS);
        if self.planet.moons.len() >= slots
            || self
                .planet
                .moons
                .iter()
                .any(|m| (m.distance - distance).abs() * Fx::from_int(10) < distance)
        {
            return;
        }
        self.moons_made += 1;
        let seed = Rng::new(self.seed ^ (self.moons_made as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)).next_u64();
        let mut world = World::new(seed);
        // Born now: its seasons follow the planet's year.
        world.tick = self.tick;
        let earths = mass * LUNAR_MASS;
        world.planet.planet_mass = earths;
        world.planet.planet_radius = ((earths / MOON_DENSITY).log2() / Fx::from_int(3))
            .exp2()
            .clamp(Fx::ratio(1, 10), Fx::from_int(20));
        self.planet.moons.push(Moon { mass, distance });
        self.moon_worlds.push(world);
        self.planet.enforce_natural();
        self.sort_moons();
    }

    /// Keeps moons and their worlds in distance order, together.
    fn sort_moons(&mut self) {
        let mut order: Vec<usize> = (0..self.planet.moons.len()).collect();
        order.sort_by_key(|&k| (self.planet.moons[k].distance, k));
        let moons: Vec<Moon> = order.iter().map(|&k| self.planet.moons[k]).collect();
        let mut worlds: Vec<Option<World>> = std::mem::take(&mut self.moon_worlds).into_iter().map(Some).collect();
        self.moon_worlds = order.iter().filter_map(|&k| worlds[k].take()).collect();
        self.planet.moons = moons;
    }

    /// A moon shares its planet's star and mode; the planet feels the
    /// moon's mass; in Natural mode the moon is tidally locked.
    fn sync_moons(&mut self) {
        let p = &mut self.planet;
        for (m, orbit) in self.moon_worlds.iter_mut().zip(p.moons.iter_mut()) {
            let mp = &mut m.planet;
            mp.star_distance_au = p.star_distance_au;
            mp.star_luminosity = p.star_luminosity;
            mp.star_type = p.star_type;
            mp.star_mass = p.star_mass;
            mp.godhand = p.godhand;
            mp.moon_slots = 0;
            mp.host = Some(Host {
                mass: p.planet_mass,
                radius: p.planet_radius,
                distance: orbit.distance,
            });
            if !p.godhand {
                mp.day_length_hours = Planet::moon_period_hours(p.planet_mass, mp.planet_mass, orbit.distance)
                    .clamp(Fx::ONE, Fx::from_int(10_000));
            }
            orbit.mass = (mp.planet_mass / LUNAR_MASS).max(Fx::ratio(1, 100));
        }
    }

    /// The world of the moon at `index`.
    pub fn moon(&self, index: usize) -> Option<&World> {
        self.moon_worlds.get(index)
    }

    /// Advances one season.
    fn step(&mut self) {
        self.planet.enforce_natural();
        self.sync_moons();
        self.stellar_weather();
        self.update_climate();
        self.update_substance_cycle();
        self.update_climate();
        self.update_life_scores();
        self.update_veil();
        self.breaches();
        self.update_life();
        self.update_individuals();
        self.update_civilizations();
        self.tick += 1;
        self.sync_moons();
        for m in &mut self.moon_worlds {
            m.step();
        }
    }

    /// Flares and Godhand strain strip atmosphere.
    fn stellar_weather(&mut self) {
        let mut loss = (self.planet.strain() * Fx::ratio(4, 1000)).min(Fx::ratio(5, 100));
        if self.planet.star_type.info().flares && self.rng.chance(Fx::ratio(5, 100)) {
            self.planet.last_flare_tick = Some(self.tick);
            loss += (Fx::ratio(3, 100) / self.planet.gravity).min(Fx::ratio(2, 10));
        }
        if loss > Fx::ZERO {
            for a in &mut self.atmosphere {
                let lost = *a * loss;
                *a -= lost;
            }
        }
    }

    /// Radiation reaching the surface after atmospheric shielding.
    pub fn surface_radiation(&self) -> Fx {
        self.planet.radiation_flux() / (Fx::ONE + self.pressure * Fx::from_int(2))
    }

    /// Radiation above what life shrugs off (an airless Earth's dose).
    /// Harms populations and speeds up mutation.
    pub fn harmful_radiation(&self) -> Fx {
        (self.surface_radiation() - Fx::ONE).max(Fx::ZERO)
    }

    /// How strained reality is here: Godhand strain plus extreme physics
    /// (neutron stars, crushing gravity). Feeds the Veil later (§4.4a).
    pub fn reality_strain(&self) -> Fx {
        let mut s = self.planet.strain();
        if self.planet.star_type == StarType::NeutronStar {
            s += Fx::from_int(2);
        }
        if self.planet.gravity > Fx::from_int(5) {
            s += (self.planet.gravity / Fx::from_int(5)).log2();
        }
        s
    }

    /// Extra day–night temperature swing (kelvin, half-amplitude) from days
    /// longer than Earth's. Thick atmospheres hold heat overnight.
    pub fn day_night_swing(&self) -> Fx {
        let ratio = (self.planet.day_length_hours / Fx::from_int(24)).sqrt();
        ((ratio - Fx::ONE).max(Fx::ZERO) * Fx::from_int(20) / (Fx::ONE + self.pressure))
            .min(Fx::from_int(400))
    }

    /// Stellar flux relative to Earth at the equator, less what the
    /// planet hides from its moon in eclipses.
    pub fn stellar_flux(&self) -> Fx {
        let d = self.planet.star_distance_au;
        self.sunlight() / (d * d)
    }

    /// The star's brightness as this world sees it on average.
    fn sunlight(&self) -> Fx {
        self.planet.star_luminosity * (Fx::ONE - self.planet.eclipse_fraction())
    }

    /// Latitude factor 0 (equator) .. 1 (pole) for a row.
    pub fn latitude(y: usize) -> Fx {
        let half = Fx::ratio(HEIGHT as i64, 2);
        ((Fx::from_int(y as i64) + Fx::HALF - half) / half).abs()
    }

    /// Raw insolation multiplier for a row, before atmospheric heat transport.
    pub fn insolation(y: usize) -> Fx {
        let lat = World::latitude(y);
        (Fx::ratio(12, 10) - Fx::ratio(9, 10) * lat * lat).max(Fx::ratio(5, 100))
    }

    fn update_climate(&mut self) {
        let g = self.planet.gravity;
        let mut column = Fx::ZERO;
        let mut gh = Fx::ZERO;
        for (i, s) in self.substances.iter().enumerate() {
            column += self.atmosphere[i];
            gh += self.atmosphere[i] * s.greenhouse;
        }
        self.pressure = column * g;

        // Equilibrium temperature: 278 K × L^¼ / √d (Earth without greenhouse).
        let l = self.sunlight();
        let t_eq = Fx::from_int(278) * l.sqrt().sqrt() / self.planet.star_distance_au.sqrt();
        // Greenhouse warming saturates for very thick atmospheres.
        let gh_mult = Fx::ONE + Fx::ratio(3, 2) * gh / (gh + Fx::ratio(6, 10));
        // Thick atmospheres carry heat to the poles.
        let spread = Fx::ONE / (Fx::ONE + self.pressure / Fx::from_int(2));

        // Seasons: tilt warms one hemisphere and cools the other, swapping
        // twice a year. Thick atmospheres damp them.
        let season = [0, 1, 0, -1][(self.tick % TICKS_PER_YEAR) as usize];
        // Longer years give seasons more time to bite.
        let year_factor = self.planet.year_length().sqrt().clamp(Fx::ratio(3, 10), Fx::from_int(3));
        let season_amp = self.planet.axial_tilt_deg / Fx::from_int(23) * Fx::from_int(15) * spread * year_factor;
        // Tidal heating from moons, like Io's volcanoes.
        let tidal_heat = (self.planet.tidal_strength() * Fx::from_int(2)).min(Fx::from_int(300))
            // Godhand strain shakes the crust: quakes and volcanism.
            + self.planet.strain() * Fx::from_int(8);

        let mut sum = Fx::ZERO;
        for y in 0..HEIGHT {
            let insol = Fx::ONE + (World::insolation(y) - Fx::ONE) * spread;
            let mut t_row = t_eq * insol.max(Fx::ratio(1, 100)).sqrt().sqrt() * gh_mult;
            if season != 0 {
                let half = Fx::ratio(HEIGHT as i64, 2);
                let north = (half - Fx::from_int(y as i64) - Fx::HALF) / half;
                t_row += season_amp * north * Fx::from_int(season);
            }
            t_row += tidal_heat;
            for x in 0..WIDTH {
                let r = &mut self.regions[y * WIDTH + x];
                let geo = r.geothermal * r.geothermal * Fx::from_int(60);
                let lapse = r.elevation * Fx::from_int(25);
                // Decaying uranium and thorium warm the ground around them.
                let radiogenic = self
                    .substances
                    .iter()
                    .zip(&r.amounts)
                    .filter(|(s, _)| s.shop == Some(crate::substance::ShopClass::Radioactive))
                    .fold(Fx::ZERO, |a, (_, amount)| a + *amount)
                    .min(Fx::from_int(10))
                    * Fx::from_int(8);
                let t = t_row + geo + radiogenic - lapse + r.heat_offset + self.planet.global_heat;
                r.temperature = t.max(Fx::from_int(3));
                sum += r.temperature;
            }
        }
        self.mean_temperature = sum / Fx::from_int(REGION_COUNT as i64);
    }

    /// Evaporation, condensation, liquid flow and atmospheric escape.
    fn update_substance_cycle(&mut self) {
        let n = self.substances.len();
        let p = self.pressure;
        let region_count = Fx::from_int(REGION_COUNT as i64);

        for s in 0..n {
            let sub = &self.substances[s];
            // Evaporate: gas-phase material leaves the surface.
            let mut evaporated = Fx::ZERO;
            let mut condensing = 0i64;
            for r in &mut self.regions {
                match sub.phase(r.temperature, p) {
                    Phase::Gas => {
                        let moved = r.amounts[s] * Fx::ratio(6, 10);
                        r.amounts[s] -= moved;
                        evaporated += moved;
                    }
                    _ => condensing += 1,
                }
            }
            self.atmosphere[s] += evaporated / region_count;

            // Condense: cold regions pull the gas back down (rain, snow, frost).
            if condensing > 0 && self.atmosphere[s] > Fx::ZERO {
                let rate = Fx::ratio(3, 10);
                let per_region = self.atmosphere[s] * rate;
                for r in &mut self.regions {
                    if sub.phase(r.temperature, p) != Phase::Gas {
                        r.amounts[s] += per_region;
                    }
                }
                self.atmosphere[s] -= per_region * Fx::from_int(condensing) / region_count;
                self.atmosphere[s] = self.atmosphere[s].max(Fx::ZERO);
            }

            // Escape: light gases leak to space from hot, low-gravity worlds.
            let index = self.mean_temperature / (self.planet.gravity * sub.molar_mass);
            let threshold = Fx::from_int(40);
            if index > threshold {
                let loss = ((index - threshold) / index * Fx::ratio(2, 100)).min(Fx::ratio(5, 100));
                let lost = self.atmosphere[s] * loss;
                self.atmosphere[s] -= lost;
            }
        }

        self.flow_liquids();
    }

    pub(crate) fn liquid_total(&self, i: usize) -> Fx {
        let r = &self.regions[i];
        let mut total = Fx::ZERO;
        for (s, sub) in self.substances.iter().enumerate() {
            if r.amounts[s] > Fx::ZERO && sub.phase(r.temperature, self.pressure) == Phase::Liquid {
                total += r.amounts[s];
            }
        }
        total
    }

    /// Height of the liquid surface (or bare ground) in a region.
    pub fn surface_level(&self, i: usize) -> Fx {
        self.regions[i].elevation + self.liquid_total(i) * LIQUID_DEPTH_PER_UNIT
    }

    /// Liquids run downhill into the lowest neighbouring region.
    fn flow_liquids(&mut self) {
        let n = self.substances.len();
        let levels: Vec<Fx> = (0..REGION_COUNT).map(|i| self.surface_level(i)).collect();
        let totals: Vec<Fx> = (0..REGION_COUNT).map(|i| self.liquid_total(i)).collect();
        let mut delta = vec![Fx::ZERO; REGION_COUNT * n];
        for i in 0..REGION_COUNT {
            if totals[i] <= Fx::ZERO {
                continue;
            }
            let mut lowest = i;
            for j in neighbours(i) {
                if levels[j] < levels[lowest] {
                    lowest = j;
                }
            }
            if lowest == i {
                continue;
            }
            // Move half the height difference, so neighbours level out.
            let diff = (levels[i] - levels[lowest]) / LIQUID_DEPTH_PER_UNIT / Fx::from_int(2);
            let moving = diff.min(totals[i]) * Fx::HALF;
            let share = moving / totals[i];
            for s in 0..n {
                let sub = &self.substances[s];
                let r = &self.regions[i];
                if r.amounts[s] > Fx::ZERO
                    && sub.phase(r.temperature, self.pressure) == Phase::Liquid
                {
                    let m = r.amounts[s] * share;
                    delta[i * n + s] -= m;
                    delta[lowest * n + s] += m;
                }
            }
        }
        for i in 0..REGION_COUNT {
            for s in 0..n {
                let a = &mut self.regions[i].amounts[s];
                *a = (*a + delta[i * n + s]).max(Fx::ZERO);
            }
        }
    }

    /// Hash of the full simulation state. Equal hashes mean equal worlds.
    pub fn state_hash(&self) -> u64 {
        let mut h = StateHasher::new();
        h.u64(self.seed);
        h.u64(self.tick);
        h.u64(self.rng.state());
        h.i64(self.planet.star_distance_au.0);
        h.i64(self.planet.star_luminosity.0);
        h.i64(self.planet.gravity.0);
        h.i64(self.planet.global_heat.0);
        h.i64(self.planet.day_length_hours.0);
        h.i64(self.planet.axial_tilt_deg.0);
        h.i64(self.planet.rings.0);
        h.u64(self.planet.godhand as u64);
        h.u64(self.planet.star_type as u64);
        h.i64(self.planet.star_mass.0);
        h.i64(self.planet.planet_mass.0);
        h.i64(self.planet.planet_radius.0);
        h.i64(self.veil_law.0);
        for v in [self.laws.arcane, self.laws.soul, self.laws.qi, self.laws.tribulation] {
            h.i64(v.0);
        }
        for s in &self.souls {
            h.u64(s.from as u64);
            h.i64(s.strength.0);
        }
        for c in &self.civs {
            h.u64(c.id as u64);
            h.u64(c.species as u64);
            h.i64(c.tech.0);
            h.i64(c.arcana.0);
            h.u64(c.fallen_tick.map_or(u64::MAX, |t| t));
            h.u64(c.faith.map_or(u64::MAX, |f| f as u64));
            h.i64(c.awe.0);
            h.i64(c.dread.0);
            for s in &c.settlements {
                h.u64(s.region as u64);
                h.i64(s.population.0);
                h.i64(s.share.0);
            }
            for r in &c.relations {
                h.u64(r.other as u64 | (r.at_war as u64) << 40 | (r.allied as u64) << 41);
                h.i64(r.opinion.0);
            }
        }
        h.u64(self.last_breach_tick.map_or(u64::MAX, |t| t));
        h.u64(self.planet.moon_slots as u64 | (self.moons_made as u64) << 8);
        for m in &self.moon_worlds {
            h.u64(m.state_hash());
        }
        for v in &self.veil {
            h.i64(v.0);
        }
        for m in &self.planet.moons {
            h.i64(m.mass.0);
            h.i64(m.distance.0);
        }
        for a in &self.atmosphere {
            h.i64(a.0);
        }
        for r in &self.regions {
            h.i64(r.heat_offset.0);
            h.i64(r.temperature.0);
            for a in &r.amounts {
                h.i64(a.0);
            }
            for p in &r.populations {
                h.u64(p.species as u64);
                h.i64(p.biomass.0);
            }
        }
        for s in &self.species {
            s.hash_into(&mut h);
        }
        for x in &self.individuals {
            x.hash_into(&mut h);
        }
        for l in &self.armoury {
            h.u64(l.id as u64 | (l.holder.unwrap_or(u32::MAX) as u64) << 32);
            h.u64(l.refit_until.unwrap_or(u64::MAX));
            h.bytes(l.item.name.as_bytes());
        }
        h.finish()
    }
}

pub fn index(x: usize, y: usize) -> usize {
    y * WIDTH + x
}

/// Four neighbours; the map wraps east-west but not over the poles.
pub fn neighbours(i: usize) -> impl Iterator<Item = usize> {
    let x = i % WIDTH;
    let y = i / WIDTH;
    let west = index((x + WIDTH - 1) % WIDTH, y);
    let east = index((x + 1) % WIDTH, y);
    let north = if y > 0 { Some(index(x, y - 1)) } else { None };
    let south = if y + 1 < HEIGHT {
        Some(index(x, y + 1))
    } else {
        None
    };
    [Some(west), Some(east), north, south].into_iter().flatten()
}

/// Region indices within `radius` of (x, y), wrapping east-west.
pub fn brush(x: u16, y: u16, radius: u8) -> Vec<usize> {
    let (x, y, r) = (x as i64, y as i64, radius as i64);
    let mut out = Vec::new();
    for dy in -r..=r {
        for dx in -r..=r {
            if dx * dx + dy * dy > r * r {
                continue;
            }
            let ny = y + dy;
            if ny < 0 || ny >= HEIGHT as i64 {
                continue;
            }
            let nx = (x + dx).rem_euclid(WIDTH as i64);
            out.push(index(nx as usize, ny as usize));
        }
    }
    out
}

/// Multi-octave value noise in 0..1, wrapping east-west.
fn value_noise(rng: &mut Rng, octaves: &[(usize, usize, Fx)]) -> Vec<Fx> {
    let mut out = vec![Fx::ZERO; REGION_COUNT];
    for &(gw, gh, weight) in octaves {
        let grid: Vec<Fx> = (0..gw * (gh + 1)).map(|_| rng.unit()).collect();
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                let fx = Fx::ratio((x * gw) as i64, WIDTH as i64);
                let fy = Fx::ratio((y * gh) as i64, (HEIGHT - 1) as i64);
                let x0 = fx.to_int() as usize;
                let y0 = (fy.to_int() as usize).min(gh - 1);
                let tx = smooth(fx - Fx::from_int(x0 as i64));
                let ty = smooth(fy - Fx::from_int(y0 as i64));
                let at = |gx: usize, gy: usize| grid[gy * gw + gx % gw];
                let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * tx;
                let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * tx;
                out[index(x, y)] += (top + (bottom - top) * ty) * weight;
            }
        }
    }
    out
}

fn smooth(t: Fx) -> Fx {
    t * t * (Fx::from_int(3) - Fx::from_int(2) * t)
}
