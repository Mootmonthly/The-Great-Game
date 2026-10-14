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

use serde::{Deserialize, Serialize};
use crate::body::{self, Body, BodyTraits, PartKind};
use crate::brain::{self, Brain, Temperament};
use crate::fixed::Fx;
use crate::hash::StateHasher;
use crate::substance::Phase;
use crate::world::{neighbours, Population, World, REGION_COUNT};

/// Cap on simultaneously living species, to bound simulation cost.
pub const MAX_LIVING_SPECIES: usize = 400;
/// Cap on stored species records; the oldest extinct records are dropped.
const MAX_SPECIES_RECORDS: usize = 1500;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
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
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Profile {
    /// Index into `World::elements`.
    pub element: u16,
    /// Index into `World::substances`.
    pub medium: u16,
    pub energy: EnergyKind,
}

/// Heritable traits of a species.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Genome {
    /// Relative body mass; 1.0 is roughly human-sized.
    pub size: Fx,
    /// Preferred temperature in kelvin.
    pub temp_opt: Fx,
    /// Temperature tolerance (half-width) in kelvin.
    pub temp_tol: Fx,
    /// Maximum growth rate per season.
    pub fecundity: Fx,
    pub metabolism: Fx,
    /// Evolutionary milestones reached (flags from `body`).
    pub milestones: u16,
    pub body: Body,
    pub brain: Brain,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
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
    /// Derived from the body when the species appears.
    pub traits: BodyTraits,
    /// Measured from the brain when the species appears.
    pub temperament: Temperament,
}

impl Species {
    pub fn is_alive(&self) -> bool {
        self.extinct_tick.is_none()
    }

    pub fn has(&self, milestone: u16) -> bool {
        self.genome.milestones & milestone != 0
    }

    /// How strongly temperament shows in behaviour: microbes only have
    /// chemical instincts; a nervous system makes behaviour matter.
    pub fn behaviour_weight(&self) -> Fx {
        if self.has(body::NERVOUS) {
            Fx::ONE
        } else {
            Fx::ratio(3, 10)
        }
    }

    /// Limbs or tentacles that can handle objects.
    pub fn has_manipulators(&self) -> bool {
        let b = &self.genome.body;
        b.count(PartKind::Limb) + b.count(PartKind::Tentacle) >= 2
    }

    /// Competitive strength when sharing a region with other species.
    /// Social species cooperate, which makes them stronger as a group.
    pub fn strength(&self) -> Fx {
        let t = &self.traits;
        let size = self.genome.size;
        let solo = Fx::HALF
            + t.armor
            + t.speed
            + t.intelligence * Fx::from_int(2)
            + t.offense * Fx::HALF
            + size / (size + Fx::from_int(5));
        // Clever, social species with manipulators use tools and cooperate.
        let tools = if self.has_manipulators() {
            t.intelligence * self.temperament.sociability * Fx::from_int(2)
        } else {
            Fx::ZERO
        };
        solo * (Fx::ONE + self.temperament.sociability * self.behaviour_weight() * Fx::ratio(4, 10))
            + tools
    }

    /// Ability to catch prey: weapons, speed and aggression.
    pub fn hunting(&self) -> Fx {
        let t = &self.traits;
        (Fx::ratio(3, 10) + t.speed * Fx::ratio(6, 10) + t.offense)
            * (Fx::ratio(7, 10)
                + self.temperament.aggression * self.behaviour_weight() * Fx::ratio(6, 10))
    }

    /// Share of this species' biomass predators can reach: armour, speed and
    /// a tendency to flee all help.
    pub fn vulnerability(&self) -> Fx {
        let t = &self.traits;
        let w = self.behaviour_weight();
        (Fx::ONE - t.armor * Fx::HALF)
            * (Fx::ONE - t.speed * Fx::ratio(3, 10))
            * (Fx::ONE - self.temperament.fear * w * Fx::ratio(3, 10))
    }

    /// Growth rate after trait trade-offs: armour, size and complex bodies
    /// slow breeding.
    pub fn growth_rate(&self) -> Fx {
        let g = &self.genome;
        g.fecundity * (Fx::ONE - self.traits.armor * Fx::HALF)
            / (Fx::ONE + g.size * Fx::ratio(5, 100))
            / (Fx::ONE + self.traits.complexity * Fx::ratio(4, 100))
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

    /// Generated description, e.g. "Medium Winged Clawed Carbon-Water Hunter".
    pub fn description(&self, world: &World) -> String {
        let g = &self.genome;
        let t = &self.traits;
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
        if self.has(body::OTHERWORLDLY) {
            words.push("Otherworldly".into());
            if g.body.count(PartKind::Eye) >= 4 {
                words.push("Many-eyed".into());
            }
            if g.body.count(PartKind::Tendril) > 0 {
                words.push("Tendrilled".into());
            }
            if g.body.count(PartKind::Void) > 0 {
                words.push("Hollow".into());
            }
            words.push("Veil-born Horror".into());
            return words.join(" ");
        }
        if self.has(body::SAPIENCE) {
            words.push("Sapient".into());
        }
        let b = &g.body;
        if b.count(PartKind::Wing) > 0 {
            words.push("Winged".into());
        }
        if t.armor > Fx::ratio(4, 10) {
            words.push("Armored".into());
        }
        if b.count(PartKind::Claw) > 0 {
            words.push("Clawed".into());
        }
        if b.count(PartKind::Tentacle) > 0 {
            words.push("Tentacled".into());
        }
        if let Some(gland) = b.part(PartKind::Gland) {
            if let Some(sub) = gland
                .substance
                .and_then(|i| world.substances.get(i as usize))
            {
                words.push(format!("{}-spitting", sub.name.replace(' ', "")));
            }
        }
        if t.intelligence > Fx::HALF {
            words.push("Cunning".into());
        }
        words.push(format!(
            "{}-{}",
            world.elements[self.profile.element as usize],
            world.substances[self.profile.medium as usize]
                .name
                .replace(' ', "")
        ));
        let role = if t.offense > Fx::ratio(3, 10) {
            "Hunter"
        } else if self.has(body::MULTICELLULAR) && self.profile.energy == EnergyKind::Light {
            if b.count(PartKind::Leaf) > 0 {
                "Bloom"
            } else {
                "Grazer"
            }
        } else {
            self.profile.energy.feeder()
        };
        words.push(role.into());
        words.join(" ")
    }

    pub(crate) fn hash_into(&self, h: &mut StateHasher) {
        h.u64(self.id as u64);
        h.u64(self.profile.element as u64);
        h.u64(self.profile.medium as u64);
        h.u64(self.profile.energy as u64);
        let g = &self.genome;
        for v in [g.size, g.temp_opt, g.temp_tol, g.fecundity, g.metabolism] {
            h.i64(v.0);
        }
        h.u64(g.milestones as u64);
        g.body.hash_into(h);
        g.brain.hash_into(h);
        h.u64(self.extinct_tick.map_or(u64::MAX, |t| t));
    }
}

/// Life-triad scores for one region, recomputed each tick.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
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
        // Tides from moons stir and heat the planet: extra energy everywhere.
        let tidal_energy = (self.planet.tidal_strength() * Fx::ratio(5, 100)).min(Fx::HALF);
        // Red and dim stars give light that is poorer for photosynthesis.
        let light_quality = self.planet.star_type.info().light_quality;
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
            let light = saturate(flux * World::insolation(y), Fx::ratio(3, 10)) * light_quality;
            let geothermal = (r.geothermal * Fx::ratio(7, 10) + tidal_energy).min(Fx::ONE);
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

    pub(crate) fn species_index(&self, id: u32) -> usize {
        self.species
            .binary_search_by_key(&id, |s| s.id)
            .expect("population refers to a known species")
    }

    fn living_count(&self) -> usize {
        self.species.iter().filter(|s| s.is_alive()).count()
    }

    pub(crate) fn new_name(&mut self) -> String {
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

    pub(crate) fn add_species(&mut self, profile: Profile, genome: Genome, parent: Option<u32>) -> u32 {
        let id = self.next_species_id;
        self.next_species_id += 1;
        let name = self.new_name();
        let color = self.new_color();
        self.species.push(Species {
            id,
            name,
            profile,
            parent,
            born_tick: self.tick,
            extinct_tick: None,
            color,
            biomass: Fx::ZERO,
            range: 0,
            traits: genome.body.traits(genome.size),
            temperament: brain::temperament(&genome.brain),
            genome,
        });
        id
    }

    pub(crate) fn update_life(&mut self) {
        self.abiogenesis();
        self.population_dynamics();
        self.entity_dynamics();
        self.migration();
        self.speciation();
        self.census();
        self.awakening();
    }

    /// Sapience can also arise within an existing species: a clever, social
    /// species with manipulators may awaken in any season, not only when a
    /// new species splits off. This makes sapience nearly certain on a
    /// stable, Earth-like world given enough time.
    fn awakening(&mut self) {
        // Each sapient species already alive makes another awakening less
        // likely: the first peoples crowd out would-be rivals.
        let mut sapient = self
            .living_species()
            .filter(|s| s.has(body::SAPIENCE))
            .count() as i64;
        for k in 0..self.species.len() {
            let s = &self.species[k];
            if !s.is_alive()
                || s.has(body::SAPIENCE)
                || s.has(body::OTHERWORLDLY)
                || !s.has(body::NERVOUS)
                || s.biomass < Fx::from_int(5)
                || s.traits.intelligence < Fx::ratio(35, 100)
                || !s.has_manipulators()
                || s.temperament.sociability < Fx::ratio(4, 10)
            {
                continue;
            }
            if self
                .rng
                .chance(Fx::ratio(3, 1000) / Fx::from_int((1 + sapient) * (1 + sapient)))
            {
                sapient += 1;
                let s = &mut self.species[k];
                s.genome.milestones |= body::SAPIENCE;
                s.genome.body.grow(PartKind::Brain, 1, Fx::ONE, None);
                s.traits = s.genome.body.traits(s.genome.size);
            }
        }
    }

    /// Life arises spontaneously in empty, viable regions.
    fn abiogenesis(&mut self) {
        let mut living = self.living_count();
        for i in 0..REGION_COUNT {
            if !self.regions[i].populations.is_empty() || living >= MAX_LIVING_SPECIES {
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
                fecundity: Fx::ratio(3, 10),
                metabolism: Fx::ONE,
                milestones: 0,
                body: Body::default(),
                brain: Brain::random(&mut self.rng),
            };
            let id = self.add_species(profile, genome, None);
            living += 1;
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
        // Radiation kills; armour shields.
        let radiation_harm = (self.harmful_radiation() * Fx::ratio(5, 100)).min(Fx::HALF);
        let swing = self.day_night_swing();
        // A predator must be at least this many times bigger than its prey.
        let prey_ratio = Fx::from_int(3);
        for i in 0..REGION_COUNT {
            if self.regions[i].populations.is_empty() {
                continue;
            }
            let temp = self.regions[i].temperature;
            // Beings from beyond follow their own rules (`entity_dynamics`).
            let (entities, pops): (Vec<Population>, Vec<Population>) = self.regions[i]
                .populations
                .iter()
                .cloned()
                .partition(|p| self.is_otherworldly(p.species));
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
                    // Long days: life must survive both the hot day and the
                    // cold night.
                    let tf = if swing > Fx::ZERO {
                        (s.temperature_fit(temp + swing, gravity)
                            + s.temperature_fit(temp - swing, gravity))
                            * Fx::HALF
                    } else {
                        s.temperature_fit(temp, gravity)
                    };
                    // Light-catching fronds boost light-fed species.
                    let photo = if s.profile.energy == EnergyKind::Light {
                        Fx::ONE + s.traits.photosynthesis * Fx::HALF
                    } else {
                        Fx::ONE
                    };
                    Info {
                        strength: s.strength(),
                        r: s.growth_rate(),
                        death: s.death_rate() + radiation_harm * (Fx::ONE - s.traits.armor * Fx::HALF),
                        fit: self.life[i].fit(&s.profile) * tf * photo,
                        habitat: self.life[i].habitat(&s.profile) * tf,
                        size: s.genome.size,
                        vulnerability: s.vulnerability(),
                        hunting: s.hunting(),
                    }
                })
                .collect();

            // Work in size order so prey (much smaller) and rivals (similar
            // size) are contiguous ranges, summed with prefix sums: O(n log n)
            // instead of comparing every pair.
            let mut order: Vec<usize> = (0..n).collect();
            order.sort_by(|&a, &b| {
                info[a]
                    .size
                    .cmp(&info[b].size)
                    .then(pops[a].species.cmp(&pops[b].species))
            });
            let sizes: Vec<Fx> = order.iter().map(|&k| info[k].size).collect();
            // prefix[x] = sum over the first x species in size order.
            let mut prey_prefix = vec![Fx::ZERO; n + 1];
            let mut rival_prefix = vec![Fx::ZERO; n + 1];
            for (x, &k) in order.iter().enumerate() {
                prey_prefix[x + 1] = prey_prefix[x] + pops[k].biomass * info[k].vulnerability;
                rival_prefix[x + 1] = rival_prefix[x] + pops[k].biomass * info[k].strength;
            }
            // Number of species (in size order) with size * prey_ratio <= limit.
            let count_prey = |limit: Fx| sizes.partition_point(|&sz| sz * prey_ratio <= limit);

            let mut prey_food = vec![Fx::ZERO; n];
            let mut load_sum = vec![Fx::ZERO; n];
            // intake per unit of available prey, accumulated so each prey
            // species can look up how hard it is hunted.
            let mut pressure_at = vec![Fx::ZERO; n + 1];
            for k in 0..n {
                let size = info[k].size;
                let prey_count = count_prey(size);
                // Rivals: size within a factor of prey_ratio either way.
                let lo = sizes.partition_point(|&sz| sz * prey_ratio <= size);
                let hi = sizes.partition_point(|&sz| sz < size * prey_ratio);
                load_sum[k] = rival_prefix[hi] - rival_prefix[lo];
                if info[k].habitat <= Fx::ZERO || prey_count == 0 {
                    continue;
                }
                let food = prey_prefix[prey_count];
                if food <= Fx::ZERO {
                    continue;
                }
                prey_food[k] = food;
                let intake = pops[k].biomass * Fx::ratio(15, 100) * info[k].hunting * food
                    / (food + Fx::from_int(5));
                // Applies to every prey in size-order positions 0..prey_count.
                pressure_at[prey_count] += intake / food;
            }
            // A prey at size-order position x is hunted by every predator
            // whose prey range extends past x: suffix sum of pressure_at.
            let mut eaten = vec![Fx::ZERO; n];
            let mut pressure = Fx::ZERO;
            for x in (0..n).rev() {
                pressure += pressure_at[x + 1];
                let j = order[x];
                eaten[j] = pressure * pops[j].biomass * info[j].vulnerability;
            }

            let mut next = Vec::with_capacity(n);
            for k in 0..n {
                let me = &info[k];
                let b = pops[k].biomass;
                let capacity = Fx::from_int(50) * me.fit + prey_food[k] * Fx::HALF * me.habitat;
                let new_b = if capacity <= Fx::ZERO {
                    b - b * Fx::ratio(3, 10)
                } else {
                    let load = load_sum[k] / me.strength;
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
            next.extend(entities);
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
                let frac = Fx::ratio(2, 100)
                    + s.traits.speed * Fx::ratio(1, 10)
                    + s.temperament.curiosity * s.behaviour_weight() * Fx::ratio(5, 100);
                let profile = s.profile;
                let otherworldly = s.has(body::OTHERWORLDLY);
                let ns: Vec<usize> = neighbours(i).collect();
                let j = ns[self.rng.below(ns.len() as u64) as usize];
                let suits = if otherworldly {
                    self.entity_target(j)
                } else {
                    self.life[j].fit(&profile) > Fx::ZERO
                };
                if suits {
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
        // Radiation drives mutation: harsh stars speed up speciation.
        let mutagen = Fx::ONE + self.harmful_radiation().min(Fx::from_int(3));
        let mut living = self.living_count();
        for i in 0..REGION_COUNT {
            let mut k = 0;
            while k < self.regions[i].populations.len() {
                let p = self.regions[i].populations[k].clone();
                k += 1;
                if p.biomass < Fx::from_int(2) || self.is_otherworldly(p.species) {
                    continue;
                }
                // Speciation slows as the planet fills with species.
                // Never below a floor, so a full planet keeps evolving: new
                // species then replace old ones through competition.
                let crowding = (Fx::ONE - Fx::ratio(living as i64, MAX_LIVING_SPECIES as i64))
                    .max(Fx::ratio(25, 100));
                // Sapient lineages split into new species far less often:
                // a handful of peoples, not hundreds.
                let parent_sapient =
                    self.species[self.species_index(p.species)].has(body::SAPIENCE);
                let rate = if parent_sapient {
                    Fx::ratio(3, 10000)
                } else {
                    Fx::ratio(3, 1000)
                };
                if !self.rng.chance(rate * crowding * mutagen) {
                    continue;
                }
                let parent = self.species[self.species_index(p.species)].clone();
                let mut profile = parent.profile;
                // Sometimes a lineage switches to the best energy source here.
                if let Some((best, _)) = self.life[i].best {
                    if best.energy != profile.energy && self.rng.chance(Fx::ratio(1, 10)) {
                        profile.energy = best.energy;
                    }
                }
                let genome = self.offspring_genome(&parent, i, p.biomass);
                let id = self.add_species(profile, genome, Some(parent.id));
                living += 1;
                let split = p.biomass / Fx::from_int(4);
                self.regions[i].populations[k - 1].biomass -= split;
                self.regions[i].populations.push(Population {
                    species: id,
                    biomass: split,
                });
            }
        }
    }

    /// The substance a new gland would use here: the most reactive substance
    /// present in the region.
    fn gland_substance(&self, i: usize) -> Option<u16> {
        let r = &self.regions[i];
        let mut best: Option<(u16, Fx)> = None;
        for (s, sub) in self.substances.iter().enumerate() {
            let amount = r.amounts[s] + self.atmosphere[s];
            if amount < Fx::ratio(5, 100) {
                continue;
            }
            let score = (sub.fuel + sub.oxidizer) * amount.min(Fx::ONE);
            if score > Fx::ZERO && best.is_none_or(|(_, b)| score > b) {
                best = Some((s as u16, score));
            }
        }
        best.map(|(s, _)| s)
    }

    /// Whether a lineage in region `i` can reach a milestone now. Each
    /// milestone needs its predecessors plus suitable conditions.
    fn milestone_possible(&self, parent: &Species, flag: u16, i: usize, biomass: Fx) -> bool {
        match flag {
            body::MULTICELLULAR => biomass >= Fx::from_int(4),
            body::SKELETON => {
                self.life[i].backbone[parent.profile.element as usize] >= Fx::ratio(15, 100)
            }
            body::GLANDS => self.gland_substance(i).is_some(),
            body::FLIGHT => {
                self.planet.gravity <= Fx::from_int(2) && self.pressure >= Fx::ratio(15, 100)
            }
            body::SAPIENCE => {
                parent.traits.intelligence >= Fx::ratio(35, 100)
                    && parent.has_manipulators()
                    && parent.temperament.sociability >= Fx::ratio(4, 10)
            }
            _ => true,
        }
    }

    fn offspring_genome(&mut self, parent: &Species, i: usize, biomass: Fx) -> Genome {
        let g = &parent.genome;
        let temp = self.regions[i].temperature;
        let mut milestones = g.milestones;
        let mut body = g.body.clone();
        let gland = self.gland_substance(i);

        // At most one milestone per speciation event.
        for m in &body::MILESTONES {
            if milestones & m.flag != 0 || milestones & m.requires != m.requires {
                continue;
            }
            let chance = if m.flag == body::SAPIENCE {
                Fx::ratio(5, 100)
            } else {
                Fx::ratio(8, 100)
            };
            if !self.milestone_possible(parent, m.flag, i, biomass) || !self.rng.chance(chance) {
                continue;
            }
            milestones |= m.flag;
            match m.flag {
                body::MULTICELLULAR => body.grow(PartKind::Segment, 2, Fx::ONE, None),
                body::NERVOUS => {
                    body.grow(PartKind::Eye, 2, Fx::HALF, None);
                    body.grow(PartKind::Brain, 1, Fx::HALF, None);
                }
                body::GLANDS => body.grow(PartKind::Gland, 1, Fx::ONE, gland),
                body::LIMBS => body.grow(PartKind::Limb, 4, Fx::ONE, None),
                body::FLIGHT => body.grow(PartKind::Wing, 2, Fx::ONE, None),
                body::SAPIENCE => body.grow(PartKind::Brain, 1, Fx::ONE, None),
                _ => {}
            }
            break;
        }
        if self.rng.chance(Fx::HALF) {
            body.mutate(&mut self.rng, milestones, gland);
        }
        // Brains are costly but pay off in competition. As with hands, social
        // life and brains on Earth, manipulators and sociability feed back
        // into bigger brains, so lineages with both converge on sapience.
        if milestones & body::NERVOUS != 0 {
            let mut chance = Fx::ratio(15, 100);
            if parent.has_manipulators() {
                chance += Fx::ratio(15, 100);
                if parent.temperament.sociability >= Fx::ratio(45, 100) {
                    chance += Fx::ratio(2, 10);
                }
            }
            if self.rng.chance(chance) {
                body.enlarge(PartKind::Brain, Fx::ratio(12, 10));
            }
        }

        // Usually a small change in body size; occasionally a leap into a new
        // size class, which can open up predation.
        let growth = if self.rng.chance(Fx::ratio(2, 10)) {
            self.rng.range(Fx::ratio(25, 10), Fx::from_int(5))
        } else {
            self.rng.range(Fx::ratio(85, 100), Fx::ratio(125, 100))
        };
        let size = (g.size * growth).clamp(Fx::ratio(1, 1000), body::size_cap(milestones));
        let wobble = |rng: &mut crate::rng::Rng| rng.range(Fx::ratio(9, 10), Fx::ratio(11, 10));
        Genome {
            size,
            temp_opt: g.temp_opt
                + (temp - g.temp_opt) * Fx::HALF
                + self.rng.spread() * Fx::from_int(10),
            temp_tol: (g.temp_tol * wobble(&mut self.rng))
                .clamp(Fx::from_int(5), Fx::from_int(400)),
            fecundity: (g.fecundity * wobble(&mut self.rng))
                .clamp(Fx::ratio(5, 100), Fx::ratio(6, 10)),
            metabolism: (g.metabolism * wobble(&mut self.rng))
                .clamp(Fx::ratio(2, 10), Fx::from_int(3)),
            milestones,
            body,
            brain: g
                .brain
                .mutated(&mut self.rng, Fx::ratio(2, 10), Fx::ratio(4, 10)),
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
        // Over the hard cap, the rarest species die out. This keeps the
        // simulation bounded without freezing evolution on a full planet.
        let mut living = self.living_count();
        while living > MAX_LIVING_SPECIES + 100 {
            let Some(k) = self
                .species
                .iter()
                .enumerate()
                .filter(|(_, s)| s.is_alive())
                .min_by_key(|(_, s)| (s.biomass, s.id))
                .map(|(k, _)| k)
            else {
                break;
            };
            let id = self.species[k].id;
            self.species[k].extinct_tick = Some(tick);
            self.species[k].biomass = Fx::ZERO;
            self.species[k].range = 0;
            for r in &mut self.regions {
                r.populations.retain(|p| p.species != id);
            }
            living -= 1;
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
