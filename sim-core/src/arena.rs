//! Real-time arena simulation (docs/GAME_DESIGN.md §6.1, §6.1a, §6.3).
//!
//! The same rules as the auto-battler, in real time on a circular
//! battlefield: units walk to the nearest enemy, keep apart from allies, and
//! act once per round. Players steer possessed units with commands.
//! Battlefields come from a world's biome, with terrain that slows, burns or
//! shelters units. A side wins by wiping out the other or by holding the
//! central shrine alone; after ten minutes the side with more surviving cost
//! wins. Everything is fixed-point and seeded, so the server can replay a
//! match from the two rosters, the seed, the biome and the command list, and
//! get the same result. A spatial grid keeps armies of 500 a side cheap.

use crate::fixed::Fx;
use crate::hash::StateHasher;
use crate::rng::Rng;
use serde::{Deserialize, Serialize};
use crate::sheet::{CharacterSheet, SizeCategory, DEX, WIS};

/// Simulation step: 0.1 s of arena time.
pub const TICK: Fx = Fx::ratio(1, 10);
/// One 5e round in arena seconds.
pub const ROUND: Fx = Fx::ratio(3, 2);
/// Radius of the smallest battlefield; larger armies get more room.
pub const ARENA_RADIUS: Fx = Fx::from_int(16);
/// The shrine at the centre of every battlefield.
pub const OBJECTIVE_RADIUS: Fx = Fx::from_int(3);
/// Holding the shrine alone this long (arena seconds) wins the match.
pub const HOLD_TIME: Fx = Fx::from_int(60);
/// Spatial grid cell size (arena units).
const CELL: Fx = Fx::from_int(4);
/// Breath weapons reach this far (arena units).
const BREATH_RANGE: Fx = Fx::from_int(6);
/// Reach of a Maddening Presence (30 ft.).
const PRESENCE_RANGE: Fx = Fx::from_int(6);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Vec2 {
    pub x: Fx,
    pub z: Fx,
}

impl Vec2 {
    pub fn new(x: Fx, z: Fx) -> Vec2 {
        Vec2 { x, z }
    }
    fn add(self, o: Vec2) -> Vec2 {
        Vec2::new(self.x + o.x, self.z + o.z)
    }
    fn sub(self, o: Vec2) -> Vec2 {
        Vec2::new(self.x - o.x, self.z - o.z)
    }
    fn scale(self, k: Fx) -> Vec2 {
        Vec2::new(self.x * k, self.z * k)
    }
    fn dot(self, o: Vec2) -> Fx {
        self.x * o.x + self.z * o.z
    }
    pub fn length(self) -> Fx {
        self.dot(self).sqrt()
    }
    /// This vector turned by a quarter or eighth of a turn (`eighths`
    /// of 45°, -2..=2).
    fn turned(self, eighths: i64) -> Vec2 {
        let (c, s) = match eighths {
            1 => (Fx::ratio(7071, 10000), Fx::ratio(7071, 10000)),
            -1 => (Fx::ratio(7071, 10000), -Fx::ratio(7071, 10000)),
            2 => (Fx::ZERO, Fx::ONE),
            -2 => (Fx::ZERO, -Fx::ONE),
            _ => (Fx::ONE, Fx::ZERO),
        };
        Vec2::new(self.x * c - self.z * s, self.x * s + self.z * c)
    }
    fn normalized(self) -> Vec2 {
        let l = self.length();
        if l <= Fx::ratio(1, 1000) {
            Vec2::default()
        } else {
            Vec2::new(self.x / l, self.z / l)
        }
    }
}

/// Visual and physical footprint by size category (arena units).
pub fn footprint(size: SizeCategory) -> Fx {
    match size {
        SizeCategory::Tiny => Fx::ratio(4, 10),
        SizeCategory::Small => Fx::ratio(55, 100),
        SizeCategory::Medium => Fx::ratio(75, 100),
        SizeCategory::Large => Fx::ratio(11, 10),
        SizeCategory::Huge => Fx::ratio(16, 10),
        SizeCategory::Gargantuan => Fx::ratio(225, 100),
    }
}

/// The kind of world a battlefield is modelled on (§6.1).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Biome {
    /// An empty, flat field (the local practice arena and tests).
    #[default]
    Open,
    Plains,
    Forest,
    Ocean,
    Ice,
    Lava,
    Desert,
}

impl Biome {
    pub const ALL: [Biome; 7] = [
        Biome::Open,
        Biome::Plains,
        Biome::Forest,
        Biome::Ocean,
        Biome::Ice,
        Biome::Lava,
        Biome::Desert,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Biome::Open => "Open field",
            Biome::Plains => "Plains",
            Biome::Forest => "Forest",
            Biome::Ocean => "Archipelago",
            Biome::Ice => "Ice field",
            Biome::Lava => "Lava field",
            Biome::Desert => "Rocky desert",
        }
    }
}

/// Terrain on a battlefield.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Ground {
    /// Slows walkers to 40%; swimmers and fliers move freely.
    Water,
    /// Burns walkers each round (2d6 fire, after resistances).
    Lava,
    /// Slows walkers to 70%.
    Ice,
    /// Cover: +2 AC; slows large walkers to 80%.
    Trees,
    /// Impassable to walkers.
    Rock,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Patch {
    pub ground: Ground,
    pub center: Vec2,
    pub radius: Fx,
}

/// A battlefield: its size and terrain, generated from a biome and seed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Battlefield {
    pub biome: Biome,
    pub radius: Fx,
    pub patches: Vec<Patch>,
}

impl Battlefield {
    /// Room for `units` in total: the smallest field holds about 60.
    pub fn radius_for(units: usize) -> Fx {
        (Fx::from_int(units as i64).sqrt() * Fx::ratio(16, 10)).max(ARENA_RADIUS)
    }

    /// Terrain patches for a biome. The shrine and both deployment zones
    /// stay clear.
    pub fn generate(biome: Biome, seed: u64, units: usize) -> Battlefield {
        let radius = Battlefield::radius_for(units);
        let mut rng = Rng::new(seed ^ 0xB10E_F1E1_D000_0000);
        // (ground, how many, size range as fractions of the field radius)
        let recipe: &[(Ground, i64, i64, i64)] = match biome {
            Biome::Open => &[],
            Biome::Plains => &[(Ground::Trees, 3, 6, 10), (Ground::Water, 1, 8, 12)],
            Biome::Forest => &[(Ground::Trees, 10, 8, 14), (Ground::Water, 1, 5, 8)],
            Biome::Ocean => &[(Ground::Water, 7, 14, 22)],
            Biome::Ice => &[(Ground::Ice, 7, 10, 18), (Ground::Water, 2, 5, 8)],
            Biome::Lava => &[(Ground::Lava, 6, 6, 12), (Ground::Rock, 4, 3, 5)],
            Biome::Desert => &[(Ground::Rock, 9, 3, 6), (Ground::Trees, 1, 4, 6)],
        };
        let mut patches = Vec::new();
        for &(ground, count, lo, hi) in recipe {
            let mut placed = 0;
            let mut tries = 0;
            while placed < count && tries < count * 20 {
                tries += 1;
                let r = radius * Fx::ratio(lo, 100) + radius * Fx::ratio(hi - lo, 100) * rng.unit();
                let angle_x = rng.unit() * Fx::from_int(2) - Fx::ONE;
                let angle_z = rng.unit() * Fx::from_int(2) - Fx::ONE;
                let dir = Vec2::new(angle_x, angle_z).normalized();
                let dist = radius * (Fx::ratio(15, 100) + Fx::ratio(75, 100) * rng.unit());
                let center = dir.scale(dist);
                // Keep the shrine and the deployment bands (|z| > 45% of
                // the radius) free of hazards and walls.
                let clear_shrine = center.length() > r + OBJECTIVE_RADIUS + Fx::ONE;
                let blocks_spawn = matches!(ground, Ground::Lava | Ground::Rock | Ground::Water)
                    && center.z.abs() + r > radius * Fx::ratio(45, 100);
                if clear_shrine && !blocks_spawn {
                    patches.push(Patch { ground, center, radius: r });
                    placed += 1;
                }
            }
        }
        Battlefield {
            biome,
            radius,
            patches,
        }
    }

    /// The terrain at a point (the last patch wins where they overlap).
    pub fn ground_at(&self, p: Vec2) -> Option<Ground> {
        self.patches
            .iter()
            .rev()
            .find(|q| p.sub(q.center).length() <= q.radius)
            .map(|q| q.ground)
    }
}

/// Buckets living units by position so neighbour queries stay local.
#[derive(Clone, Debug, Default)]
struct Grid {
    origin: Fx,
    width: i64,
    cells: Vec<Vec<usize>>,
}

impl Grid {
    fn build(units: &[ArenaUnit], radius: Fx) -> Grid {
        let origin = -radius - CELL;
        let width = ((radius * Fx::from_int(2) + CELL * Fx::from_int(2)) / CELL).to_int() + 1;
        let mut cells = vec![Vec::new(); (width * width) as usize];
        let mut g = Grid {
            origin,
            width,
            cells: Vec::new(),
        };
        for (i, u) in units.iter().enumerate() {
            if u.alive {
                let (cx, cz) = g.cell(u.pos);
                cells[(cz * width + cx) as usize].push(i);
            }
        }
        g.cells = cells;
        g
    }

    fn cell(&self, p: Vec2) -> (i64, i64) {
        let c = |v: Fx| ((v - self.origin) / CELL).to_int().clamp(0, self.width - 1);
        (c(p.x), c(p.z))
    }

    /// Units in the cells overlapping the square of half-side `range`
    /// around `p`, in cell order (deterministic).
    fn near(&self, p: Vec2, range: Fx) -> impl Iterator<Item = usize> + '_ {
        let (x0, z0) = self.cell(Vec2::new(p.x - range, p.z - range));
        let (x1, z1) = self.cell(Vec2::new(p.x + range, p.z + range));
        (z0..=z1).flat_map(move |z| (x0..=x1).flat_map(move |x| self.cells[(z * self.width + x) as usize].iter().copied()))
    }
}

#[derive(Clone, Debug)]
pub struct ArenaUnit {
    pub sheet: CharacterSheet,
    pub team: u8,
    pub pos: Vec2,
    pub facing: Vec2,
    pub hp: i64,
    pub alive: bool,
    pub breath_ready: bool,
    pub cooldown: Fx,
    pub radius: Fx,
    /// Arena units per second.
    pub speed: Fx,
    /// Steered by a player instead of the AI.
    pub possessed: bool,
    /// Frightened this round: attacks roll with disadvantage.
    pub frightened: bool,
    /// Player steering for the current tick (unit vector or zero).
    steer: Vec2,
    flies: bool,
    swims: bool,
    /// Fire immunity: lava does not hurt it.
    fireproof: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ArenaEvent {
    Hit {
        attacker: usize,
        target: usize,
        attack: String,
        damage: i64,
    },
    Miss {
        attacker: usize,
        target: usize,
        attack: String,
    },
    Breath {
        attacker: usize,
        name: String,
        targets: Vec<(usize, i64)>,
    },
    Fell {
        unit: usize,
        by: usize,
    },
}

/// A player command, recorded so the server can replay the match.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ArenaCommand {
    /// Take control of a unit, or release it (`None`).
    Possess {
        team: u8,
        unit: Option<usize>,
    },
    /// Steering direction for a possessed unit, held until changed.
    Steer {
        unit: usize,
        x: Fx,
        z: Fx,
    },
    Attack {
        unit: usize,
    },
    Breathe {
        unit: usize,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ArenaResult {
    TeamA,
    TeamB,
    Draw,
}

pub struct Arena {
    pub units: Vec<ArenaUnit>,
    pub time: Fx,
    pub result: Option<ArenaResult>,
    pub field: Battlefield,
    /// How long each side has held the shrine alone without a break.
    pub hold: [Fx; 2],
    /// How the match ended, for the log: "wipe-out", "objective",
    /// "time" or "surrender".
    pub ended_by: Option<&'static str>,
    alive_count: [usize; 2],
    /// Initiative order: higher Dexterity first, ties by index.
    order: Vec<usize>,
    grid: Grid,
    /// Largest unit radius, to widen neighbour queries.
    max_radius: Fx,
    rng: Rng,
    events: Vec<ArenaEvent>,
    /// Every command applied, with the tick it applied on.
    pub command_log: Vec<(u64, ArenaCommand)>,
    tick: u64,
}

fn d(rng: &mut Rng, sides: i64) -> i64 {
    1 + rng.below(sides.max(1) as u64) as i64
}

fn roll(rng: &mut Rng, dice: i64, sides: i64) -> i64 {
    (0..dice).map(|_| d(rng, sides)).sum()
}

/// The match ends after this many seconds of arena time (10 minutes).
pub const TIME_LIMIT: Fx = Fx::from_int(600);

impl Arena {
    /// A match on an open field.
    pub fn new(team_a: Vec<CharacterSheet>, team_b: Vec<CharacterSheet>, seed: u64) -> Arena {
        Arena::on(team_a, team_b, seed, Biome::Open)
    }

    /// A match on a battlefield of this biome. The teams line up in ranks
    /// on opposite sides; bigger armies get wider ranks and more room.
    pub fn on(team_a: Vec<CharacterSheet>, team_b: Vec<CharacterSheet>, seed: u64, biome: Biome) -> Arena {
        let total = team_a.len() + team_b.len();
        let field = Battlefield::generate(biome, seed, total);
        let radius = field.radius;
        let mut units = Vec::new();
        for (team, sheets) in [(0u8, team_a), (1u8, team_b)] {
            let side = if team == 0 { -Fx::ONE } else { Fx::ONE };
            let n = sheets.len().max(1);
            let cols = (Fx::from_int(n as i64 * 3).sqrt().to_int() as usize).max(8);
            for (i, sheet) in sheets.into_iter().enumerate() {
                let row = (i / cols) as i64;
                let col = (i % cols) as i64;
                let half = cols as i64 - 1;
                let pos = Vec2::new(
                    Fx::ratio(26 * (2 * col - half), 20),
                    side * (radius * Fx::ratio(55, 100) + Fx::ratio(26 * row, 10)),
                );
                let best = sheet
                    .speed_walk
                    .max(sheet.speed_swim)
                    .max(sheet.speed_fly)
                    .max(10);
                let sheet_flies = sheet.speed_fly > 0;
                let sheet_swims = sheet.speed_swim > 0;
                let sheet_fireproof = sheet.immunities.contains(&crate::sheet::DamageType::Fire);
                units.push(ArenaUnit {
                    radius: footprint(sheet.size),
                    speed: Fx::ratio(6, 10) + Fx::ratio(best, 12),
                    hp: sheet.hit_points,
                    sheet,
                    team,
                    pos,
                    facing: Vec2::new(Fx::ZERO, -side),
                    alive: true,
                    breath_ready: true,
                    cooldown: Fx::ZERO,
                    possessed: false,
                    frightened: false,
                    steer: Vec2::default(),
                    flies: sheet_flies,
                    swims: sheet_swims,
                    fireproof: sheet_fireproof,
                });
            }
        }
        // Units that do not fit stand at the edge, still inside.
        for u in &mut units {
            let r = u.pos.length();
            if r > radius {
                u.pos = u.pos.scale(radius / r);
            }
        }
        let mut order: Vec<usize> = (0..units.len()).collect();
        order.sort_by_key(|&i| (std::cmp::Reverse(units[i].sheet.modifier(DEX)), i));
        let alive_count = [0u8, 1u8].map(|t| units.iter().filter(|u| u.team == t).count());
        let max_radius = units.iter().map(|u| u.radius).max().unwrap_or(Fx::ONE);
        let grid = Grid::build(&units, radius);
        Arena {
            units,
            time: Fx::ZERO,
            result: None,
            field,
            hold: [Fx::ZERO; 2],
            ended_by: None,
            alive_count,
            order,
            grid,
            max_radius,
            rng: Rng::new(seed),
            events: Vec::new(),
            command_log: Vec::new(),
            tick: 0,
        }
    }

    /// Ticks stepped so far.
    pub fn tick(&self) -> u64 {
        self.tick
    }

    /// Ends the match early: `team` gives up and the other side wins.
    pub fn surrender(&mut self, team: u8) {
        if self.result.is_none() {
            self.result = Some(if team == 0 {
                ArenaResult::TeamB
            } else {
                ArenaResult::TeamA
            });
            self.ended_by = Some("surrender");
        }
    }

    /// Total cost of a side's living units.
    pub fn surviving_cost(&self, team: u8) -> i64 {
        self.units
            .iter()
            .filter(|u| u.alive && u.team == team)
            .map(|u| u.sheet.cost.cost)
            .sum()
    }

    /// Hash of the match state. Lockstep clients compare it with the
    /// server's to detect desyncs.
    pub fn state_hash(&self) -> u64 {
        let mut h = StateHasher::new();
        h.u64(self.tick);
        h.u64(self.rng.state());
        for u in &self.units {
            h.i64(u.pos.x.0);
            h.i64(u.pos.z.0);
            h.i64(u.hp);
            h.i64(u.cooldown.0);
            h.u64(u.alive as u64 | (u.possessed as u64) << 1 | (u.breath_ready as u64) << 2);
        }
        h.i64(self.hold[0].0);
        h.i64(self.hold[1].0);
        h.finish()
    }

    /// Events since the last call.
    pub fn take_events(&mut self) -> Vec<ArenaEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn alive(&self, team: u8) -> usize {
        self.alive_count[team as usize]
    }

    /// The closest living enemy: searched outwards through the grid, ties
    /// broken by index.
    fn nearest_enemy(&self, i: usize) -> Option<usize> {
        let me = &self.units[i];
        if self.alive_count[1 - me.team as usize] == 0 {
            return None;
        }
        let mut range = CELL;
        loop {
            let best = self
                .grid
                .near(me.pos, range + self.max_radius)
                .filter(|&j| self.units[j].alive && self.units[j].team != me.team)
                .map(|j| {
                    let d = self.units[j].pos.sub(me.pos);
                    (d.dot(d), j)
                })
                .min();
            match best {
                // Anything closer lies within the square searched.
                Some((d2, j)) if d2 <= range * range => return Some(j),
                Some((_, j)) if range > self.field.radius * Fx::from_int(3) => return Some(j),
                _ if range > self.field.radius * Fx::from_int(3) => {
                    // Positions moved off the grid: fall back to a scan.
                    return (0..self.units.len())
                        .filter(|&j| self.units[j].alive && self.units[j].team != me.team)
                        .min_by_key(|&j| {
                            let d = self.units[j].pos.sub(me.pos);
                            (d.dot(d), j)
                        });
                }
                _ => range = range * Fx::from_int(2),
            }
        }
    }

    /// Terrain effects for a unit at `p`: (speed factor, AC bonus).
    fn terrain(&self, i: usize, p: Vec2) -> (Fx, i64) {
        let u = &self.units[i];
        if u.flies {
            return match self.field.ground_at(p) {
                Some(Ground::Trees) => (Fx::ONE, 2),
                _ => (Fx::ONE, 0),
            };
        }
        match self.field.ground_at(p) {
            Some(Ground::Water) if !u.swims => (Fx::ratio(4, 10), 0),
            Some(Ground::Ice) => (Fx::ratio(7, 10), 0),
            Some(Ground::Trees) => {
                let big = matches!(u.sheet.size, SizeCategory::Large | SizeCategory::Huge | SizeCategory::Gargantuan);
                (if big { Fx::ratio(8, 10) } else { Fx::ONE }, 2)
            }
            _ => (Fx::ONE, 0),
        }
    }

    /// Whether a walker should not step onto `p`: walls, and lava unless
    /// fireproof.
    fn avoid(&self, i: usize, p: Vec2) -> bool {
        let u = &self.units[i];
        if u.flies {
            return false;
        }
        match self.field.ground_at(p) {
            Some(Ground::Rock) => true,
            Some(Ground::Lava) => !u.fireproof,
            _ => false,
        }
    }

    fn reach(&self, a: usize, b: usize) -> Fx {
        self.units[a].radius + self.units[b].radius + Fx::ratio(6, 10)
    }

    pub fn command(&mut self, c: ArenaCommand) {
        self.command_log.push((self.tick, c));
        match c {
            ArenaCommand::Possess { team, unit } => {
                for u in self.units.iter_mut().filter(|u| u.team == team) {
                    u.possessed = false;
                    u.steer = Vec2::default();
                }
                if let Some(i) = unit {
                    if let Some(u) = self.units.get_mut(i) {
                        if u.team == team && u.alive {
                            u.possessed = true;
                        }
                    }
                }
            }
            ArenaCommand::Steer { unit, x, z } => {
                if let Some(u) = self.units.get_mut(unit) {
                    if u.possessed {
                        u.steer = Vec2::new(x, z).normalized();
                    }
                }
            }
            ArenaCommand::Attack { unit } => {
                if self
                    .units
                    .get(unit)
                    .is_some_and(|u| u.possessed && u.alive && u.cooldown <= Fx::ZERO)
                {
                    if let Some(t) = self.nearest_enemy(unit) {
                        let dist = self.units[t].pos.sub(self.units[unit].pos).length();
                        if dist <= self.reach(unit, t) + Fx::HALF {
                            self.units[unit].cooldown = ROUND;
                            self.attack(unit, t);
                        }
                    }
                }
            }
            ArenaCommand::Breathe { unit } => {
                if self.units.get(unit).is_some_and(|u| {
                    u.possessed
                        && u.alive
                        && u.breath_ready
                        && u.sheet.breath.is_some()
                        && u.cooldown <= Fx::ZERO
                }) {
                    self.units[unit].cooldown = ROUND;
                    self.breathe(unit);
                }
            }
        }
    }

    fn hurt(&mut self, target: usize, amount: i64, by: usize) {
        let t = &mut self.units[target];
        t.hp -= amount;
        if t.hp <= 0 && t.alive {
            t.alive = false;
            t.possessed = false;
            self.alive_count[t.team as usize] -= 1;
            self.events.push(ArenaEvent::Fell { unit: target, by });
        }
    }

    fn attack(&mut self, i: usize, target: usize) {
        let allies = self.alive(self.units[i].team);
        let attacks = self.units[i].sheet.attacks.clone();
        let pack = self.units[i].sheet.pack_tactics && allies > 1;
        let frightened = self.units[i].frightened;
        for a in &attacks {
            for _ in 0..a.uses {
                if !self.units[target].alive {
                    return;
                }
                let mut natural = d(&mut self.rng, 20);
                if frightened {
                    natural = natural.min(d(&mut self.rng, 20));
                }
                let bonus = a.to_hit + if pack { 2 } else { 0 };
                let ac = self.units[target].sheet.armor_class + self.terrain(target, self.units[target].pos).1;
                if natural == 1 || (natural != 20 && natural + bonus < ac) {
                    self.events.push(ArenaEvent::Miss {
                        attacker: i,
                        target,
                        attack: a.name.clone(),
                    });
                    continue;
                }
                let dice = if natural == 20 { a.dice * 2 } else { a.dice };
                let raw = (roll(&mut self.rng, dice, a.die) + a.bonus).max(1);
                let damage = self.units[target].sheet.damage_taken(raw, a.damage);
                self.events.push(ArenaEvent::Hit {
                    attacker: i,
                    target,
                    attack: a.name.clone(),
                    damage,
                });
                self.hurt(target, damage, i);
            }
        }
    }

    /// Whether an enemy's Maddening Presence frightens unit `i` this round:
    /// a Wisdom save against the strongest presence within range.
    fn presence_frightens(&mut self, i: usize) -> bool {
        let me = self.units[i].pos;
        let dc = self
            .grid
            .near(me, PRESENCE_RANGE + self.max_radius)
            .map(|j| &self.units[j])
            .filter(|u| {
                u.alive
                    && u.team != self.units[i].team
                    && u.pos.sub(me).length() <= PRESENCE_RANGE + u.radius
            })
            .filter_map(|u| u.sheet.frighten_dc)
            .max();
        match dc {
            Some(dc) => d(&mut self.rng, 20) + self.units[i].sheet.modifier(WIS) < dc,
            None => false,
        }
    }

    /// Breath hits the closest enemies in front of the breather.
    fn breathe(&mut self, i: usize) {
        let Some(b) = self.units[i].sheet.breath.clone() else {
            return;
        };
        self.units[i].breath_ready = false;
        let damage = roll(&mut self.rng, b.dice, 6);
        let me = self.units[i].pos;
        let facing = self.units[i].facing;
        let mut targets: Vec<usize> = self
            .grid
            .near(me, BREATH_RANGE + self.max_radius)
            .filter(|&j| {
                let u = &self.units[j];
                let to = u.pos.sub(me);
                u.alive
                    && u.team != self.units[i].team
                    && to.length() <= BREATH_RANGE + u.radius
                    && facing.dot(to.normalized()) > Fx::ratio(3, 10)
            })
            .collect();
        targets.sort_by_key(|&j| {
            let to = self.units[j].pos.sub(me);
            (to.dot(to), j)
        });
        targets.truncate(b.targets as usize);
        let mut hits = Vec::new();
        for t in targets {
            let save = d(&mut self.rng, 20) + self.units[t].sheet.modifier(b.save_ability);
            let dealt = if save >= b.dc { damage / 2 } else { damage };
            let taken = self.units[t].sheet.damage_taken(dealt, b.damage);
            hits.push((t, taken));
            self.hurt(t, taken, i);
        }
        self.events.push(ArenaEvent::Breath {
            attacker: i,
            name: b.name.clone(),
            targets: hits,
        });
    }

    /// Advances one tick (0.1 s).
    pub fn step(&mut self) {
        if self.result.is_some() {
            return;
        }
        self.tick += 1;
        self.time += TICK;
        let order = std::mem::take(&mut self.order);
        for &i in &order {
            if !self.units[i].alive {
                continue;
            }
            self.units[i].cooldown -= TICK;
            let Some(target) = self.nearest_enemy(i) else {
                break;
            };
            let to_target = self.units[target].pos.sub(self.units[i].pos);
            let dist = to_target.length();
            let reach = self.reach(i, target);
            let team = self.units[i].team as usize;
            // While the enemy holds the shrine, go and contest it.
            let contest = self.hold[1 - team] > Fx::ZERO
                && dist > reach
                && self.units[i].pos.length() > OBJECTIVE_RADIUS;
            let (slow, _) = self.terrain(i, self.units[i].pos);
            if self.units[i].possessed {
                let steer = self.units[i].steer;
                if steer != Vec2::default() {
                    let u = &self.units[i];
                    let next = u.pos.add(steer.scale(u.speed * slow * Fx::ratio(12, 10) * TICK));
                    if !matches!(self.field.ground_at(next), Some(Ground::Rock)) || u.flies {
                        let u = &mut self.units[i];
                        u.facing = steer;
                        u.pos = next;
                    }
                }
            } else if dist > reach || contest {
                // Walk towards the target (or the shrine), pushed apart by
                // nearby allies, around walls and lava.
                let goal = if contest {
                    Vec2::default().sub(self.units[i].pos)
                } else {
                    to_target
                };
                let mut dir = goal.normalized();
                let me = self.units[i].pos;
                let my_r = self.units[i].radius;
                for j in self.grid.near(me, my_r + self.max_radius) {
                    let o = &self.units[j];
                    if j == i || !o.alive || o.team != self.units[i].team {
                        continue;
                    }
                    let away = me.sub(o.pos);
                    let gap = away.length();
                    if gap < my_r + o.radius && gap > Fx::ratio(1, 1000) {
                        dir = dir.add(away.normalized().scale(Fx::ratio(6, 10)));
                    }
                }
                let dir = dir.normalized();
                let step = self.units[i].speed * slow * TICK;
                let ahead = (step * Fx::from_int(4)).max(Fx::ONE);
                let chosen = [0i64, 1, -1, 2, -2]
                    .into_iter()
                    .map(|e| dir.turned(e))
                    .find(|d| !self.avoid(i, me.add(d.scale(ahead))));
                if let Some(d) = chosen {
                    let u = &mut self.units[i];
                    u.facing = d;
                    u.pos = u.pos.add(d.scale(step));
                }
            } else {
                self.units[i].facing = to_target.normalized();
            }
            // Stay inside the battlefield and out of walls.
            let radius = self.field.radius;
            let u = &mut self.units[i];
            let r = u.pos.length();
            if r > radius {
                u.pos = u.pos.scale(radius / r);
            }
            if !self.units[i].flies {
                if let Some(rock) = self
                    .field
                    .patches
                    .iter()
                    .find(|q| q.ground == Ground::Rock && self.units[i].pos.sub(q.center).length() < q.radius)
                    .copied()
                {
                    let out = self.units[i].pos.sub(rock.center).normalized();
                    let out = if out == Vec2::default() { Vec2::new(Fx::ONE, Fx::ZERO) } else { out };
                    self.units[i].pos = rock.center.add(out.scale(rock.radius + Fx::ratio(1, 100)));
                }
            }

            if self.units[i].possessed || self.units[i].cooldown > Fx::ZERO {
                continue;
            }
            // One action per round.
            self.units[i].cooldown = ROUND;
            self.units[i].frightened = self.presence_frightens(i);
            if !self.units[i].breath_ready && d(&mut self.rng, 6) >= 5 {
                self.units[i].breath_ready = true;
            }
            let regen = self.units[i].sheet.regeneration;
            if regen > 0 {
                let u = &mut self.units[i];
                u.hp = (u.hp + regen).min(u.sheet.hit_points);
            }
            if self.units[i].breath_ready
                && self.units[i].sheet.breath.is_some()
                && dist < BREATH_RANGE
            {
                self.breathe(i);
            } else if dist <= reach {
                self.attack(i, target);
            }
        }
        // Lava burns every walker standing in it, once a round.
        if self.tick.is_multiple_of(15) {
            for &i in &order {
                let u = &self.units[i];
                if u.alive && !u.flies && self.field.ground_at(u.pos) == Some(Ground::Lava) {
                    let raw = roll(&mut self.rng, 2, 6);
                    let burn = self.units[i].sheet.damage_taken(raw, crate::sheet::DamageType::Fire);
                    if burn > 0 {
                        self.hurt(i, burn, i);
                    }
                }
            }
        }
        self.order = order;
        self.grid = Grid::build(&self.units, self.field.radius);

        // The shrine: held by a side that alone has units on it.
        let mut on = [false; 2];
        for j in self.grid.near(Vec2::default(), OBJECTIVE_RADIUS + self.max_radius) {
            let u = &self.units[j];
            if u.alive && u.pos.length() <= OBJECTIVE_RADIUS + u.radius {
                on[u.team as usize] = true;
            }
        }
        for t in 0..2 {
            self.hold[t] = if on[t] && !on[1 - t] {
                self.hold[t] + TICK
            } else {
                Fx::ZERO
            };
        }

        let (a, b) = (self.alive(0), self.alive(1));
        let (result, by) = match (a, b) {
            (0, 0) => (Some(ArenaResult::Draw), "wipe-out"),
            (_, 0) => (Some(ArenaResult::TeamA), "wipe-out"),
            (0, _) => (Some(ArenaResult::TeamB), "wipe-out"),
            _ if self.hold[0] >= HOLD_TIME => (Some(ArenaResult::TeamA), "objective"),
            _ if self.hold[1] >= HOLD_TIME => (Some(ArenaResult::TeamB), "objective"),
            _ if self.time >= TIME_LIMIT => {
                // Time: more surviving cost wins; within 5% is a draw.
                let (ca, cb) = (self.surviving_cost(0), self.surviving_cost(1));
                let r = if (ca - cb).abs() * 20 <= ca.max(cb) {
                    ArenaResult::Draw
                } else if ca > cb {
                    ArenaResult::TeamA
                } else {
                    ArenaResult::TeamB
                };
                (Some(r), "time")
            }
            _ => (None, ""),
        };
        if result.is_some() {
            self.result = result;
            self.ended_by = Some(by);
        }
    }

    /// Replays a match from its rosters, seed and command log. The server
    /// uses this to verify a reported result.
    pub fn replay(
        team_a: Vec<CharacterSheet>,
        team_b: Vec<CharacterSheet>,
        seed: u64,
        log: &[(u64, ArenaCommand)],
    ) -> Arena {
        Arena::replay_on(team_a, team_b, seed, Biome::Open, log)
    }

    /// Replays a match fought on a battlefield of `biome`.
    pub fn replay_on(
        team_a: Vec<CharacterSheet>,
        team_b: Vec<CharacterSheet>,
        seed: u64,
        biome: Biome,
        log: &[(u64, ArenaCommand)],
    ) -> Arena {
        let mut arena = Arena::on(team_a, team_b, seed, biome);
        let mut next = 0;
        while arena.result.is_none() {
            while next < log.len() && log[next].0 == arena.tick {
                arena.command(log[next].1);
                next += 1;
            }
            arena.step();
        }
        arena
    }
}

impl crate::world::World {
    /// The battlefield biome this world's champions fight on at home: lava
    /// for molten worlds, archipelagos for sea worlds, ice for frozen ones,
    /// forest where plants thrive, rocky desert where little liquid lies,
    /// otherwise plains.
    pub fn arena_biome(&self) -> Biome {
        use crate::world::REGION_COUNT;
        let n = Fx::from_int(REGION_COUNT as i64);
        let wet = (0..REGION_COUNT)
            .filter(|&i| self.liquid_total(i) > Fx::ratio(2, 10))
            .count() as i64;
        let wet = Fx::from_int(wet) / n;
        let plants = self
            .living_species()
            .filter(|s| s.has(crate::body::MULTICELLULAR) && !s.has(crate::body::NERVOUS))
            .fold(Fx::ZERO, |a, s| a + s.biomass);
        if self.mean_temperature > Fx::from_int(700) {
            Biome::Lava
        } else if self.mean_temperature < Fx::from_int(250) {
            Biome::Ice
        } else if wet > Fx::ratio(65, 100) {
            Biome::Ocean
        } else if wet < Fx::ratio(10, 100) {
            Biome::Desert
        } else if plants > Fx::from_int(3000) {
            Biome::Forest
        } else {
            Biome::Plains
        }
    }
}
