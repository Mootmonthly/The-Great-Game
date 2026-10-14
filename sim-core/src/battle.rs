//! Headless auto-battler (roadmap Phase 1): fights character sheets against
//! each other with 5e-style rounds, so the cost formula can be checked
//! against actual results. Deterministic for a given seed.
//!
//! Simplifications: no positioning or movement, targets are picked at random,
//! and breath weapons hit several random enemies.

use crate::rng::Rng;
use crate::sheet::{CharacterSheet, DEX};

const MAX_ROUNDS: u32 = 200;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    TeamA,
    TeamB,
    Draw,
}

struct Fighter<'a> {
    sheet: &'a CharacterSheet,
    team: u8,
    hp: i64,
    breath_ready: bool,
    initiative: i64,
}

fn d(rng: &mut Rng, sides: i64) -> i64 {
    1 + rng.below(sides.max(1) as u64) as i64
}

fn roll(rng: &mut Rng, dice: i64, sides: i64) -> i64 {
    (0..dice).map(|_| d(rng, sides)).sum()
}

fn alive_on(fighters: &[Fighter], team: u8) -> Vec<usize> {
    (0..fighters.len())
        .filter(|&i| fighters[i].team == team && fighters[i].hp > 0)
        .collect()
}

/// Fights two teams to the end (or a draw after 200 rounds).
pub fn battle(team_a: &[&CharacterSheet], team_b: &[&CharacterSheet], seed: u64) -> Outcome {
    let mut rng = Rng::new(seed);
    let mut fighters: Vec<Fighter> = Vec::new();
    for (team, members) in [(0u8, team_a), (1u8, team_b)] {
        for s in members.iter() {
            let initiative = d(&mut rng, 20) + s.modifier(DEX);
            fighters.push(Fighter {
                sheet: s,
                team,
                hp: s.hit_points,
                breath_ready: true,
                initiative,
            });
        }
    }
    let mut order: Vec<usize> = (0..fighters.len()).collect();
    order.sort_by_key(|&i| (std::cmp::Reverse(fighters[i].initiative), i));

    for _ in 0..MAX_ROUNDS {
        for &i in &order {
            if fighters[i].hp <= 0 {
                continue;
            }
            let team = fighters[i].team;
            let enemies = alive_on(&fighters, 1 - team);
            if enemies.is_empty() {
                break;
            }
            let allies = alive_on(&fighters, team).len();
            let sheet = fighters[i].sheet;

            // Start of turn: recharge and regenerate.
            if !fighters[i].breath_ready && d(&mut rng, 6) >= 5 {
                fighters[i].breath_ready = true;
            }
            if sheet.regeneration > 0 {
                fighters[i].hp = (fighters[i].hp + sheet.regeneration).min(sheet.hit_points);
            }

            let attacks_avg: i64 = sheet
                .attacks
                .iter()
                .map(|a| a.average().round() * a.uses)
                .sum();
            let use_breath = fighters[i].breath_ready
                && sheet.breath.as_ref().is_some_and(|b| {
                    b.average().round() * b.targets.min(enemies.len() as i64) >= attacks_avg
                });
            if use_breath {
                let b = sheet.breath.as_ref().expect("checked above");
                fighters[i].breath_ready = false;
                let damage = roll(&mut rng, b.dice, 6);
                let mut targets = enemies.clone();
                for _ in 0..b.targets {
                    if targets.is_empty() {
                        break;
                    }
                    let t = targets.remove(rng.below(targets.len() as u64) as usize);
                    let save = d(&mut rng, 20) + fighters[t].sheet.modifier(b.save_ability);
                    let dealt = if save >= b.dc { damage / 2 } else { damage };
                    fighters[t].hp -= fighters[t].sheet.damage_taken(dealt, b.damage);
                }
            } else {
                for a in &sheet.attacks {
                    for _ in 0..a.uses {
                        let enemies = alive_on(&fighters, 1 - team);
                        if enemies.is_empty() {
                            break;
                        }
                        let t = enemies[rng.below(enemies.len() as u64) as usize];
                        let natural = d(&mut rng, 20);
                        let bonus = a.to_hit
                            + if sheet.pack_tactics && allies > 1 {
                                2
                            } else {
                                0
                            };
                        let hit = natural == 20
                            || (natural != 1 && natural + bonus >= fighters[t].sheet.armor_class);
                        if !hit {
                            continue;
                        }
                        let dice = if natural == 20 { a.dice * 2 } else { a.dice };
                        let damage = (roll(&mut rng, dice, a.die) + a.bonus).max(1);
                        fighters[t].hp -= fighters[t].sheet.damage_taken(damage, a.damage);
                    }
                }
            }
        }
        let a_alive = !alive_on(&fighters, 0).is_empty();
        let b_alive = !alive_on(&fighters, 1).is_empty();
        match (a_alive, b_alive) {
            (true, false) => return Outcome::TeamA,
            (false, true) => return Outcome::TeamB,
            (false, false) => return Outcome::Draw,
            _ => {}
        }
    }
    Outcome::Draw
}

/// Share of `games` won by `a` against `b` (draws count half), with seats
/// alternated so initiative luck evens out.
pub fn win_rate(a: &[&CharacterSheet], b: &[&CharacterSheet], games: u32, seed: u64) -> f64 {
    let mut score = 0.0;
    for g in 0..games {
        let s = seed.wrapping_mul(1_000_003).wrapping_add(g as u64);
        score += match battle(a, b, s) {
            Outcome::TeamA => 1.0,
            Outcome::Draw => 0.5,
            Outcome::TeamB => 0.0,
        };
    }
    score / games as f64
}
