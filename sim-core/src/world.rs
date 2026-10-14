//! The world: planet parameters, regions, climate and the substance cycle.
//!
//! Phase 0 runs only the regional layer (L1 in docs/GAME_DESIGN.md §4.1) on a
//! 2D equirectangular grid. One tick is one season; four ticks make a year.

use crate::action::{Action, ActionLog};
use crate::fixed::Fx;
use crate::hash::StateHasher;
use crate::life::{RegionLife, Species};
use crate::rng::Rng;
use crate::substance::{default_substances, Phase, Substance};

pub const WIDTH: usize = 64;
pub const HEIGHT: usize = 32;
pub const REGION_COUNT: usize = WIDTH * HEIGHT;
pub const TICKS_PER_YEAR: u64 = 4;

/// Liquids pool in low regions: one unit of liquid raises the surface by this
/// fraction of the full elevation range.
const LIQUID_DEPTH_PER_UNIT: Fx = Fx::ratio(1, 6);

#[derive(Clone, Debug)]
pub struct Planet {
    pub star_distance_au: Fx,
    pub star_luminosity: Fx,
    pub gravity: Fx,
    pub global_heat: Fx,
}

impl Default for Planet {
    fn default() -> Planet {
        Planet {
            star_distance_au: Fx::ONE,
            star_luminosity: Fx::ONE,
            gravity: Fx::ONE,
            global_heat: Fx::ZERO,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Population {
    pub species: u32,
    pub biomass: Fx,
}

#[derive(Clone, Debug)]
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

pub struct World {
    pub seed: u64,
    pub tick: u64,
    pub planet: Planet,
    pub substances: Vec<Substance>,
    /// Distinct backbone elements (e.g. Carbon, Silicon), derived from the
    /// substance table.
    pub elements: Vec<String>,
    pub regions: Vec<Region>,
    /// Atmospheric column of each substance, in units per region.
    pub atmosphere: Vec<Fx>,
    /// Surface pressure in bar (derived each tick).
    pub pressure: Fx,
    pub mean_temperature: Fx,
    pub species: Vec<Species>,
    pub(crate) next_species_id: u32,
    pub(crate) life: Vec<RegionLife>,
    pub(crate) rng: Rng,
    log: ActionLog,
}

impl World {
    pub fn new(seed: u64) -> World {
        let substances = default_substances();
        let mut elements: Vec<String> = Vec::new();
        for s in &substances {
            if !s.backbone_element.is_empty() && !elements.contains(&s.backbone_element) {
                elements.push(s.backbone_element.clone());
            }
        }
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
            life: Vec::new(),
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
                if *substance >= n {
                    return;
                }
                for i in brush(*x, *y, *radius) {
                    let a = &mut self.regions[i].amounts[*substance as usize];
                    *a = (*a + *amount).max(Fx::ZERO);
                }
            }
            Action::AddSubstanceGlobal { substance, amount } => {
                if *substance >= n {
                    return;
                }
                for r in &mut self.regions {
                    let a = &mut r.amounts[*substance as usize];
                    *a = (*a + *amount).max(Fx::ZERO);
                }
            }
            Action::HeatRegion {
                x,
                y,
                radius,
                delta,
            } => {
                for i in brush(*x, *y, *radius) {
                    let h = &mut self.regions[i].heat_offset;
                    *h = (*h + *delta).clamp(Fx::from_int(-2000), Fx::from_int(5000));
                }
            }
            Action::SetGlobalHeat { kelvin } => {
                self.planet.global_heat = (*kelvin).clamp(Fx::from_int(-500), Fx::from_int(3000));
            }
            Action::SetStarDistance { au } => {
                self.planet.star_distance_au = (*au).clamp(Fx::ratio(1, 100), Fx::from_int(100));
            }
            Action::SetStarLuminosity { suns } => {
                self.planet.star_luminosity = (*suns).clamp(Fx::ratio(1, 1000), Fx::from_int(1000));
            }
            Action::SetGravity { g } => {
                self.planet.gravity = (*g).clamp(Fx::ratio(1, 100), Fx::from_int(50));
            }
        }
        if !matches!(action, Action::Tick { .. }) {
            // Show the effect of tool use immediately, without advancing time.
            self.update_climate();
            self.update_life_scores();
        }
        self.log.push(action);
    }

    /// Advances one season.
    fn step(&mut self) {
        self.update_climate();
        self.update_substance_cycle();
        self.update_climate();
        self.update_life_scores();
        self.update_life();
        self.tick += 1;
    }

    /// Stellar flux relative to Earth at the equator.
    pub fn stellar_flux(&self) -> Fx {
        let d = self.planet.star_distance_au;
        self.planet.star_luminosity / (d * d)
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
        let l = self.planet.star_luminosity;
        let t_eq = Fx::from_int(278) * l.sqrt().sqrt() / self.planet.star_distance_au.sqrt();
        // Greenhouse warming saturates for very thick atmospheres.
        let gh_mult = Fx::ONE + Fx::ratio(3, 2) * gh / (gh + Fx::ratio(6, 10));
        // Thick atmospheres carry heat to the poles.
        let spread = Fx::ONE / (Fx::ONE + self.pressure / Fx::from_int(2));

        let mut sum = Fx::ZERO;
        for y in 0..HEIGHT {
            let insol = Fx::ONE + (World::insolation(y) - Fx::ONE) * spread;
            let t_row = t_eq * insol.max(Fx::ratio(1, 100)).sqrt().sqrt() * gh_mult;
            for x in 0..WIDTH {
                let r = &mut self.regions[y * WIDTH + x];
                let geo = r.geothermal * r.geothermal * Fx::from_int(60);
                let lapse = r.elevation * Fx::from_int(25);
                let t = t_row + geo - lapse + r.heat_offset + self.planet.global_heat;
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

    fn liquid_total(&self, i: usize) -> Fx {
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
