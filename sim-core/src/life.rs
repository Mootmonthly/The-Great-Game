//! Life: the life triad, abiogenesis, population dynamics, migration and
//! speciation (docs/GAME_DESIGN.md §4.3–4.4).
//!
//! Life needs three things in a region:
//! 1. a **backbone** element whose chains are stable at the local temperature,
//! 2. a **medium**: some liquid that lets chemistry happen,
//! 3. an **energy gradient**: starlight, geothermal heat, or a fuel/oxidizer pair.
//!
//! Each combination is a biochemistry profile. Nothing is hard-coded to
//! carbon and water: any substance in the data table with the right
//! properties can take part.

use crate::fixed::Fx;
use crate::hash::StateHasher;
use crate::substance::Phase;
use crate::world::{neighbours, Population, World, REGION_COUNT};

/// Cap on simultaneously living species, to bound simulation cost.
pub const MAX_LIVING_SPECIES: usize = 256;
/// Cap on stored species records; the oldest extinct records are dropped.
const MAX_SPECIES_RECORDS: usize = 1500;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum EnergyKind {
    Light = 0,
    Geothermal = 1,
    Chemical = 2,
}

impl EnergyKind {
    pub const ALL: [EnergyKind; 3] = [
        EnergyKind::Light,
        EnergyKind::Geothermal,
        EnergyKind::Chemical,
    ];

    pub fn name(self) -> &'static str {
        match self {
            EnergyKind::Light => "Light",
            EnergyKind::Geothermal => "Geothermal",
            EnergyKind::Chemical => "Chemical",
        }
    }

    /// Word used in generated species descriptions.
    pub fn feeder(self) -> &'static str {
        match self {
            EnergyKind::Light => "Phototroph",
            EnergyKind::Geothermal => "Thermotroph",
            EnergyKind::Chemical => "Chemotroph",
        }
    }
}

/// A biochemistry profile: one answer to each part of the life triad.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Profile {
    /// Index into `World::elements`.
    pub element: u16,
    /// Index into `World::substances`.
    pub medium: u16,
    pub energy: EnergyKind,
}

/// Heritable traits of a species.
#[derive(Clone, Debug)]
pub struct Genome {
    /// Relative body mass; 1.0 is roughly human-sized.
    pub size: Fx,
    /// Preferred temperature in kelvin.
    pub temp_opt: Fx,
    /// Temperature tolerance (half-width) in kelvin.
    pub temp_tol: Fx,
    pub armor: Fx,
    pub speed: Fx,
    pub intelligence: Fx,
    /// Maximum growth rate per season.
    pub fecundity: Fx,
    pub metabolism: Fx,
}

#[derive(Clone, Debug)]
pub struct Species {
    pub id: u32,
    pub name: String,
    pub profile: Profile,
    pub genome: Genome,
    pub parent: Option<u32>,
    pub born_tick: u64,
    pub extinct_tick: Option<u64>,
    pub color: [u8; 3],
    /// Total biomass across all regions (derived each tick).
    pub biomass: Fx,
    /// Number of regions the species lives in (derived each tick).
    pub range: u32,
}

impl Species {
    pub fn is_alive(&self) -> bool {
        self.extinct_tick.is_none()
    }

    /// Competitive strength when sharing a region with other species.
    pub fn strength(&self) -> Fx {
        let g = &self.genome;
        Fx::HALF
            + g.armor
            + g.speed
            + g.intelligence * Fx::from_int(2)
            + g.size / (g.size + Fx::from_int(5))
    }

    /// Growth rate after trait trade-offs: armour and size slow breeding.
    pub fn growth_rate(&self) -> Fx {
        let g = &self.genome;
        g.fecundity * (Fx::ONE - g.armor * Fx::HALF) / (Fx::ONE + g.size * Fx::ratio(5, 100))
    }

    pub fn death_rate(&self) -> Fx {
        Fx::ratio(3, 100) + self.genome.metabolism * Fx::ratio(3, 100)
    }

    pub fn temperature_fit(&self, temp: Fx, gravity: Fx) -> Fx {
        let g = &self.genome;
        let d = (temp - g.temp_opt) / g.temp_tol;
        let mut fit = (Fx::ONE - d * d).max(Fx::ZERO);
        // Strong gravity limits how big a body can grow.
        let max_size = Fx::from_int(20) / gravity;
        if g.size > max_size {
            fit = fit * max_size / g.size;
        }
        fit
    }

    /// Generated description, e.g. "Small Armored Carbon-Water Phototroph".
    pub fn description(&self, world: &World) -> String {
        let g = &self.genome;
        let size = g.size.to_f64();
        let size_word = if size < 0.05 {
            "Microbial"
        } else if size < 0.5 {
            "Tiny"
        } else if size < 2.0 {
            "Small"
        } else if size < 10.0 {
            "Medium"
        } else if size < 30.0 {
            "Large"
        } else {
            "Huge"
        };
        let mut words = vec![size_word.to_string()];
        if g.armor > Fx::ratio(5, 10) {
            words.push("Armored".into());
        }
        if g.speed > Fx::ratio(5, 10) {
            words.push("Swift".into());
        }
        if g.intelligence > Fx::ratio(5, 10) {
            words.push("Cunning".into());
        }
        words.push(format!(
            "{}-{}",
            world.elements[self.profile.element as usize],
            world.substances[self.profile.medium as usize]
                .name
                .replace(' ', "")
        ));
        words.push(self.profile.energy.feeder().into());
        words.join(" ")
    }

    pub(crate) fn hash_into(&self, h: &mut StateHasher) {
        h.u64(self.id as u64);
        h.u64(self.profile.element as u64);
        h.u64(self.profile.medium as u64);
        h.u64(self.profile.energy as u64);
        let g = &self.genome;
        for v in [
            g.size,
            g.temp_opt,
            g.temp_tol,
            g.armor,
            g.speed,
            g.intelligence,
            g.fecundity,
            g.metabolism,
        ] {
            h.i64(v.0);
        }
        h.u64(self.extinct_tick.map_or(u64::MAX, |t| t));
    }
}

/// Life-triad scores for one region, recomputed each tick.
#[derive(Clone, Debug, Default)]
pub struct RegionLife {
    /// Backbone score per element.
    pub backbone: Vec<Fx>,
    /// Medium score per substance (zero unless liquid here).
    pub medium: Vec<Fx>,
    /// Energy score per `EnergyKind`.
    pub energy: [Fx; 3],
    /// Reaction-speed multiplier: very cold chemistry is slow.
    pub kinetics: Fx,
    /// Best profile available here and its viability (0..1).
    pub best: Option<(Profile, Fx)>,
}

impl RegionLife {
    pub fn fit(&self, p: &Profile) -> Fx {
        self.backbone[p.element as usize]
            .min(self.medium[p.medium as usize])
            .min(self.energy[p.energy as usize])
            * self.kinetics
    }

    /// Fit ignoring energy: whether a predator can live here on prey alone.
    pub fn habitat(&self, p: &Profile) -> Fx {
        self.backbone[p.element as usize].min(self.medium[p.medium as usize]) * self.kinetics
    }

    pub fn viability(&self) -> Fx {
        self.best.map_or(Fx::ZERO, |(_, v)| v)
    }
}

/// Diminishing returns: 0 at 0, 0.5 at `half`, approaching 1.
fn saturate(amount: Fx, half: Fx) -> Fx {
    if amount <= Fx::ZERO {
        return Fx::ZERO;
    }
    amount / (amount + half)
}

impl World {
    pub fn region_life(&self, i: usize) -> &RegionLife {
        &self.life[i]
    }

    pub fn species_by_id(&self, id: u32) -> Option<&Species> {
        self.species
            .binary_search_by_key(&id, |s| s.id)
            .ok()
            .map(|i| &self.species[i])
    }

    pub fn living_species(&self) -> impl Iterator<Item = &Species> {
        self.species.iter().filter(|s| s.is_alive())
    }

    pub(crate) fn update_life_scores(&mut self) {
        let flux = self.stellar_flux();
        let p = self.pressure;
        let mut life = Vec::with_capacity(REGION_COUNT);
        for (i, r) in self.regions.iter().enumerate() {
            let t = r.temperature;
            let y = i / crate::world::WIDTH;

            let mut backbone = vec![Fx::ZERO; self.elements.len()];
            let mut medium = vec![Fx::ZERO; self.substances.len()];
            let mut fuel = Fx::ZERO;
            let mut oxidizer = Fx::ZERO;
            for (s, sub) in self.substances.iter().enumerate() {
                let local = r.amounts[s];
                let air = self.atmosphere[s];
                if sub.backbone_stable_at(t) {
                    let e = self
                        .elements
                        .iter()
                        .position(|e| *e == sub.backbone_element)
                        .unwrap();
                    let score = sub.backbone * saturate(local + air * Fx::HALF, Fx::ONE);
                    backbone[e] = backbone[e].max(score);
                }
                if local > Fx::ZERO && sub.phase(t, p) == Phase::Liquid {
                    medium[s] = sub.solvent * saturate(local, Fx::ONE);
                }
                let available = saturate(local + air, Fx::ONE);
                fuel += sub.fuel * available;
                oxidizer += sub.oxidizer * available;
            }
            let light = saturate(flux * World::insolation(y), Fx::ratio(3, 10));
            let geothermal = r.geothermal * Fx::ratio(7, 10);
            let chemical = fuel.min(oxidizer).min(Fx::ONE);
            let energy = [light, geothermal, chemical];
            let kinetics = (t / Fx::from_int(250)).clamp(Fx::ratio(1, 10), Fx::ONE);

            let mut cell = RegionLife {
                backbone,
                medium,
                energy,
                kinetics,
                best: None,
            };
            let mut best: Option<(Profile, Fx)> = None;
            for e in 0..self.elements.len() {
                for m in 0..self.substances.len() {
                    if cell.medium[m] == Fx::ZERO || cell.backbone[e] == Fx::ZERO {
                        continue;
                    }
                    for kind in EnergyKind::ALL {
                        let prof = Profile {
                            element: e as u16,
                            medium: m as u16,
                            energy: kind,
                        };
                        let v = cell.fit(&prof);
                        if v > Fx::ZERO && best.is_none_or(|(_, bv)| v > bv) {
                            best = Some((prof, v));
                        }
                    }
                }
            }
            cell.best = best;
            life.push(cell);
        }
        self.life = life;
    }

    fn species_index(&self, id: u32) -> usize {
        self.species
            .binary_search_by_key(&id, |s| s.id)
            .expect("population refers to a known species")
    }

    fn living_count(&self) -> usize {
        self.species.iter().filter(|s| s.is_alive()).count()
    }

    fn new_species_name(&mut self) -> String {
        const SYLLABLES: [&str; 24] = [
            "ka", "zor", "ul", "mi", "threx", "on", "va", "gil", "sy", "dra", "no", "quel", "pha",
            "rin", "tu", "esh", "bo", "lix", "an", "vor", "ce", "mur", "ix", "ta",
        ];
        let count = 2 + self.rng.below(2);
        let mut name = String::new();
        for _ in 0..count {
            name.push_str(SYLLABLES[self.rng.below(SYLLABLES.len() as u64) as usize]);
        }
        let mut c = name.chars();
        match c.next() {
            Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
            None => name,
        }
    }

    fn new_color(&mut self) -> [u8; 3] {
        // Bright, saturated colours: one channel high, one low, one random.
        let hi = 200 + self.rng.below(56) as u8;
        let lo = 30 + self.rng.below(60) as u8;
        let mid = 60 + self.rng.below(160) as u8;
        match self.rng.below(6) {
            0 => [hi, mid, lo],
            1 => [hi, lo, mid],
            2 => [mid, hi, lo],
            3 => [lo, hi, mid],
            4 => [mid, lo, hi],
            _ => [lo, mid, hi],
        }
    }

    fn add_species(&mut self, profile: Profile, genome: Genome, parent: Option<u32>) -> u32 {
        let id = self.next_species_id;
        self.next_species_id += 1;
        let name = self.new_species_name();
        let color = self.new_color();
        self.species.push(Species {
            id,
            name,
            profile,
            genome,
            parent,
            born_tick: self.tick,
            extinct_tick: None,
            color,
            biomass: Fx::ZERO,
            range: 0,
        });
        id
    }

    pub(crate) fn update_life(&mut self) {
        self.abiogenesis();
        self.population_dynamics();
        self.migration();
        self.speciation();
        self.census();
    }

    /// Life arises spontaneously in empty, viable regions.
    fn abiogenesis(&mut self) {
        for i in 0..REGION_COUNT {
            if !self.regions[i].populations.is_empty() || self.living_count() >= MAX_LIVING_SPECIES
            {
                continue;
            }
            let Some((profile, v)) = self.life[i].best else {
                continue;
            };
            if v < Fx::ratio(15, 100) || !self.rng.chance(v * Fx::ratio(3, 10000)) {
                continue;
            }
            let genome = Genome {
                size: Fx::ratio(1, 100),
                temp_opt: self.regions[i].temperature,
                temp_tol: Fx::from_int(30),
                armor: Fx::ZERO,
                speed: Fx::ratio(5, 100),
                intelligence: Fx::ZERO,
                fecundity: Fx::ratio(3, 10),
                metabolism: Fx::ONE,
            };
            let id = self.add_species(profile, genome, None);
            self.regions[i].populations.push(Population {
                species: id,
                biomass: Fx::HALF,
            });
        }
    }

    /// Logistic growth. Species compete only with others of similar body
    /// size; much larger species hunt much smaller ones. Size classes are
    /// separate niches, which lets large creatures evolve alongside microbes.
    fn population_dynamics(&mut self) {
        let gravity = self.planet.gravity;
        // A predator must be at least this many times bigger than its prey.
        let prey_ratio = Fx::from_int(3);
        for i in 0..REGION_COUNT {
            if self.regions[i].populations.is_empty() {
                continue;
            }
            let temp = self.regions[i].temperature;
            let pops = self.regions[i].populations.clone();
            let n = pops.len();
            struct Info {
                strength: Fx,
                r: Fx,
                death: Fx,
                fit: Fx,
                habitat: Fx,
                size: Fx,
                vulnerability: Fx,
                hunting: Fx,
            }
            let info: Vec<Info> = pops
                .iter()
                .map(|p| {
                    let s = &self.species[self.species_index(p.species)];
                    let tf = s.temperature_fit(temp, gravity);
                    Info {
                        strength: s.strength(),
                        r: s.growth_rate(),
                        death: s.death_rate(),
                        fit: self.life[i].fit(&s.profile) * tf,
                        habitat: self.life[i].habitat(&s.profile) * tf,
                        size: s.genome.size,
                        vulnerability: Fx::ONE - s.genome.armor * Fx::HALF,
                        hunting: Fx::HALF + s.genome.speed,
                    }
                })
                .collect();

            let mut eaten = vec![Fx::ZERO; n];
            let mut prey_food = vec![Fx::ZERO; n];
            for k in 0..n {
                if info[k].habitat <= Fx::ZERO {
                    continue;
                }
                let prey: Vec<usize> = (0..n)
                    .filter(|&j| info[j].size * prey_ratio <= info[k].size)
                    .collect();
                let food = prey.iter().fold(Fx::ZERO, |a, &j| {
                    a + pops[j].biomass * info[j].vulnerability
                });
                if food <= Fx::ZERO {
                    continue;
                }
                prey_food[k] = food;
                let intake = pops[k].biomass * Fx::ratio(15, 100) * info[k].hunting * food
                    / (food + Fx::from_int(5));
                for &j in &prey {
                    eaten[j] += intake * pops[j].biomass * info[j].vulnerability / food;
                }
            }

            let mut next = Vec::with_capacity(n);
            for k in 0..n {
                let me = &info[k];
                let b = pops[k].biomass;
                let capacity = Fx::from_int(50) * me.fit + prey_food[k] * Fx::HALF * me.habitat;
                let new_b = if capacity <= Fx::ZERO {
                    b - b * Fx::ratio(3, 10)
                } else {
                    let mut load = Fx::ZERO;
                    for j in 0..n {
                        let similar = info[j].size * prey_ratio > me.size
                            && me.size * prey_ratio > info[j].size;
                        if similar {
                            load += pops[j].biomass * info[j].strength / me.strength;
                        }
                    }
                    let growth = me.r * b * (Fx::ONE - load / capacity);
                    let stress = Fx::ONE - (capacity / Fx::from_int(50)).min(Fx::ONE);
                    b + growth - me.death * b * stress
                };
                let new_b = new_b - eaten[k];
                if new_b > Fx::ratio(2, 100) {
                    next.push(Population {
                        species: pops[k].species,
                        biomass: new_b,
                    });
                }
            }
            self.regions[i].populations = next;
        }
    }

    /// Some biomass spreads to a neighbouring region that suits the species.
    fn migration(&mut self) {
        let mut moves: Vec<(usize, usize, u32, Fx)> = Vec::new();
        for i in 0..REGION_COUNT {
            for k in 0..self.regions[i].populations.len() {
                let p = self.regions[i].populations[k].clone();
                if p.biomass < Fx::HALF {
                    continue;
                }
                let s = &self.species[self.species_index(p.species)];
                let frac = Fx::ratio(2, 100) + s.genome.speed * Fx::ratio(1, 10);
                let profile = s.profile;
                let ns: Vec<usize> = neighbours(i).collect();
                let j = ns[self.rng.below(ns.len() as u64) as usize];
                if self.life[j].fit(&profile) > Fx::ZERO {
                    moves.push((i, j, p.species, p.biomass * frac));
                }
            }
        }
        for (from, to, species, amount) in moves {
            if let Some(p) = self.regions[from]
                .populations
                .iter_mut()
                .find(|p| p.species == species)
            {
                p.biomass -= amount;
            }
            match self.regions[to]
                .populations
                .iter_mut()
                .find(|p| p.species == species)
            {
                Some(p) => p.biomass += amount,
                None => self.regions[to].populations.push(Population {
                    species,
                    biomass: amount,
                }),
            }
        }
    }

    /// Occasionally a local population splits off as a new species, adapted
    /// to its region.
    fn speciation(&mut self) {
        for i in 0..REGION_COUNT {
            let mut k = 0;
            while k < self.regions[i].populations.len() {
                let p = self.regions[i].populations[k].clone();
                k += 1;
                if p.biomass < Fx::from_int(2) || self.living_count() >= MAX_LIVING_SPECIES {
                    continue;
                }
                // Speciation slows as the planet fills with species.
                let crowding =
                    Fx::ONE - Fx::ratio(self.living_count() as i64, MAX_LIVING_SPECIES as i64);
                if !self.rng.chance(Fx::ratio(3, 1000) * crowding) {
                    continue;
                }
                let parent = self.species[self.species_index(p.species)].clone();
                let temp = self.regions[i].temperature;
                let mut profile = parent.profile;
                // Sometimes a lineage switches to the best energy source here.
                if let Some((best, _)) = self.life[i].best {
                    if best.energy != profile.energy && self.rng.chance(Fx::ratio(1, 10)) {
                        profile.energy = best.energy;
                    }
                }
                let g = &parent.genome;
                let unit = Fx::ONE;
                // Usually a small change in body size; occasionally a leap into a
                // new size class, which can open up predation.
                let growth = if self.rng.chance(Fx::ratio(2, 10)) {
                    self.rng.range(Fx::ratio(25, 10), Fx::from_int(5))
                } else {
                    self.rng.range(Fx::ratio(85, 100), Fx::ratio(125, 100))
                };
                let size = (g.size * growth).clamp(Fx::ratio(1, 1000), Fx::from_int(500));
                let genome = Genome {
                    size,
                    temp_opt: g.temp_opt
                        + (temp - g.temp_opt) * Fx::HALF
                        + self.rng.spread() * Fx::from_int(10),
                    temp_tol: (g.temp_tol * self.rng.range(Fx::ratio(9, 10), Fx::ratio(11, 10)))
                        .clamp(Fx::from_int(5), Fx::from_int(400)),
                    armor: (g.armor + self.rng.spread() * Fx::ratio(8, 100)).clamp(Fx::ZERO, unit),
                    speed: (g.speed + self.rng.spread() * Fx::ratio(8, 100)).clamp(Fx::ZERO, unit),
                    // Bigger bodies can afford bigger brains.
                    intelligence: (g.intelligence
                        + self.rng.spread() * Fx::ratio(5, 100)
                        + Fx::ratio(1, 100) * size / (size + Fx::ONE))
                        .clamp(Fx::ZERO, unit),
                    fecundity: (g.fecundity * self.rng.range(Fx::ratio(9, 10), Fx::ratio(11, 10)))
                        .clamp(Fx::ratio(5, 100), Fx::ratio(6, 10)),
                    metabolism: (g.metabolism
                        * self.rng.range(Fx::ratio(9, 10), Fx::ratio(11, 10)))
                    .clamp(Fx::ratio(2, 10), Fx::from_int(3)),
                };
                let id = self.add_species(profile, genome, Some(parent.id));
                let split = p.biomass / Fx::from_int(4);
                self.regions[i].populations[k - 1].biomass -= split;
                self.regions[i].populations.push(Population {
                    species: id,
                    biomass: split,
                });
            }
        }
    }

    /// Recomputes species totals, marks extinctions and trims old records.
    fn census(&mut self) {
        for s in &mut self.species {
            s.biomass = Fx::ZERO;
            s.range = 0;
        }
        for i in 0..REGION_COUNT {
            for k in 0..self.regions[i].populations.len() {
                let p = self.regions[i].populations[k].clone();
                let idx = self.species_index(p.species);
                self.species[idx].biomass += p.biomass;
                self.species[idx].range += 1;
            }
        }
        let tick = self.tick;
        for s in &mut self.species {
            if s.is_alive() && s.range == 0 {
                s.extinct_tick = Some(tick);
            }
        }
        while self.species.len() > MAX_SPECIES_RECORDS {
            match self.species.iter().position(|s| !s.is_alive()) {
                Some(i) => {
                    self.species.remove(i);
                }
                None => break,
            }
        }
    }
}
