//! Real-time arena simulation (docs/GAME_DESIGN.md §6.1a, §6.3).
//!
//! The same rules as the auto-battler, in real time on a flat circular
//! arena: units walk to the nearest enemy, keep apart from allies, and act
//! once per round. Players steer possessed units with commands. Everything
//! is fixed-point and seeded, so the server can replay a match from the two
//! rosters, the seed and the command list, and get the same result.

use crate::fixed::Fx;
use crate::rng::Rng;
use crate::sheet::{CharacterSheet, SizeCategory, DEX, WIS};

/// Simulation step: 0.1 s of arena time.
pub const TICK: Fx = Fx::ratio(1, 10);
/// One 5e round in arena seconds.
pub const ROUND: Fx = Fx::ratio(3, 2);
pub const ARENA_RADIUS: Fx = Fx::from_int(16);
/// Breath weapons reach this far (arena units).
const BREATH_RANGE: Fx = Fx::from_int(6);
/// Reach of a Maddening Presence (30 ft.).
const PRESENCE_RANGE: Fx = Fx::from_int(6);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
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
    fn length(self) -> Fx {
        self.dot(self).sqrt()
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
}

#[derive(Clone, Debug, PartialEq, Eq)]
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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArenaResult {
    TeamA,
    TeamB,
    Draw,
}

pub struct Arena {
    pub units: Vec<ArenaUnit>,
    pub time: Fx,
    pub result: Option<ArenaResult>,
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

/// Draw after this many seconds of arena time.
const TIME_LIMIT: Fx = Fx::from_int(600);

impl Arena {
    /// Lines the teams up on opposite sides, eight to a row.
    pub fn new(team_a: Vec<CharacterSheet>, team_b: Vec<CharacterSheet>, seed: u64) -> Arena {
        let mut units = Vec::new();
        for (team, sheets) in [(0u8, team_a), (1u8, team_b)] {
            let side = if team == 0 { -Fx::ONE } else { Fx::ONE };
            for (i, sheet) in sheets.into_iter().enumerate() {
                let row = (i / 8) as i64;
                let col = (i % 8) as i64;
                let pos = Vec2::new(
                    Fx::ratio(26 * (2 * col - 7), 20),
                    side * (ARENA_RADIUS * Fx::ratio(55, 100) + Fx::ratio(26 * row, 10)),
                );
                let best = sheet
                    .speed_walk
                    .max(sheet.speed_swim)
                    .max(sheet.speed_fly)
                    .max(10);
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
                });
            }
        }
        Arena {
            units,
            time: Fx::ZERO,
            result: None,
            rng: Rng::new(seed),
            events: Vec::new(),
            command_log: Vec::new(),
            tick: 0,
        }
    }

    /// Events since the last call.
    pub fn take_events(&mut self) -> Vec<ArenaEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn alive(&self, team: u8) -> usize {
        self.units
            .iter()
            .filter(|u| u.alive && u.team == team)
            .count()
    }

    fn nearest_enemy(&self, i: usize) -> Option<usize> {
        let me = &self.units[i];
        (0..self.units.len())
            .filter(|&j| self.units[j].alive && self.units[j].team != me.team)
            .min_by_key(|&j| {
                let d = self.units[j].pos.sub(me.pos);
                (d.dot(d), j)
            })
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
                let ac = self.units[target].sheet.armor_class;
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
            .units
            .iter()
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
        let mut targets: Vec<usize> = (0..self.units.len())
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
        // Initiative: higher Dexterity acts first each tick; ties by index.
        let mut order: Vec<usize> = (0..self.units.len()).collect();
        order.sort_by_key(|&i| (std::cmp::Reverse(self.units[i].sheet.modifier(DEX)), i));
        for i in order {
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
            if self.units[i].possessed {
                let steer = self.units[i].steer;
                if steer != Vec2::default() {
                    let u = &mut self.units[i];
                    u.facing = steer;
                    u.pos = u.pos.add(steer.scale(u.speed * Fx::ratio(12, 10) * TICK));
                }
            } else if dist > reach {
                // Walk towards the target, pushed apart by nearby allies.
                let mut dir = to_target.normalized();
                for j in 0..self.units.len() {
                    let o = &self.units[j];
                    if j == i || !o.alive || o.team != self.units[i].team {
                        continue;
                    }
                    let away = self.units[i].pos.sub(o.pos);
                    let gap = away.length();
                    if gap < self.units[i].radius + o.radius && gap > Fx::ratio(1, 1000) {
                        dir = dir.add(away.normalized().scale(Fx::ratio(6, 10)));
                    }
                }
                let dir = dir.normalized();
                let u = &mut self.units[i];
                u.facing = dir;
                u.pos = u.pos.add(dir.scale(u.speed * TICK));
            } else {
                self.units[i].facing = to_target.normalized();
            }
            // Stay inside the arena.
            let u = &mut self.units[i];
            let r = u.pos.length();
            if r > ARENA_RADIUS {
                u.pos = u.pos.scale(ARENA_RADIUS / r);
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
        let (a, b) = (self.alive(0), self.alive(1));
        self.result = match (a, b) {
            (0, 0) => Some(ArenaResult::Draw),
            (_, 0) => Some(ArenaResult::TeamA),
            (0, _) => Some(ArenaResult::TeamB),
            _ if self.time >= TIME_LIMIT => Some(ArenaResult::Draw),
            _ => None,
        };
    }

    /// Replays a match from its rosters, seed and command log. The server
    /// uses this to verify a reported result.
    pub fn replay(
        team_a: Vec<CharacterSheet>,
        team_b: Vec<CharacterSheet>,
        seed: u64,
        log: &[(u64, ArenaCommand)],
    ) -> Arena {
        let mut arena = Arena::new(team_a, team_b, seed);
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
