//! Character sheets and cost (docs/GAME_DESIGN.md §5).
//!
//! Every species, and every named individual, gets a sheet in the style of
//! the 5e System Reference Document: ability scores, armour class, hit
//! points, speeds, senses, resistances, attacks and traits, all derived from
//! its body parts, brain and biochemistry. Nothing is assigned by hand.
//!
//! The sheet's cost (1–1000) comes from its combat power. All maths is
//! fixed-point, so the server can recompute any sheet and cost exactly from
//! the same genome (replay verification, §6.2).

use crate::body::{self, PartKind};
use crate::fixed::Fx;
use crate::individual::Individual;
use crate::life::{EnergyKind, Species};
use crate::world::World;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum SizeCategory {
    Tiny,
    Small,
    Medium,
    Large,
    Huge,
    Gargantuan,
}

impl SizeCategory {
    pub fn from_size(size: Fx) -> SizeCategory {
        if size < Fx::ratio(1, 10) {
            SizeCategory::Tiny
        } else if size < Fx::HALF {
            SizeCategory::Small
        } else if size < Fx::from_int(2) {
            SizeCategory::Medium
        } else if size < Fx::from_int(8) {
            SizeCategory::Large
        } else if size < Fx::from_int(32) {
            SizeCategory::Huge
        } else {
            SizeCategory::Gargantuan
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            SizeCategory::Tiny => "Tiny",
            SizeCategory::Small => "Small",
            SizeCategory::Medium => "Medium",
            SizeCategory::Large => "Large",
            SizeCategory::Huge => "Huge",
            SizeCategory::Gargantuan => "Gargantuan",
        }
    }

    pub fn hit_die(self) -> i64 {
        match self {
            SizeCategory::Tiny => 4,
            SizeCategory::Small => 6,
            SizeCategory::Medium => 8,
            SizeCategory::Large => 10,
            SizeCategory::Huge => 12,
            SizeCategory::Gargantuan => 20,
        }
    }

    fn damage_die(self) -> i64 {
        match self {
            SizeCategory::Tiny | SizeCategory::Small => 4,
            SizeCategory::Medium => 6,
            SizeCategory::Large => 8,
            SizeCategory::Huge => 10,
            SizeCategory::Gargantuan => 12,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum DamageType {
    Bludgeoning,
    Piercing,
    Slashing,
    Fire,
    Cold,
    Acid,
    Poison,
    Lightning,
    Thunder,
    Psychic,
}

impl DamageType {
    pub fn name(self) -> &'static str {
        match self {
            DamageType::Bludgeoning => "bludgeoning",
            DamageType::Piercing => "piercing",
            DamageType::Slashing => "slashing",
            DamageType::Fire => "fire",
            DamageType::Cold => "cold",
            DamageType::Acid => "acid",
            DamageType::Poison => "poison",
            DamageType::Lightning => "lightning",
            DamageType::Thunder => "thunder",
            DamageType::Psychic => "psychic",
        }
    }

    /// What a gland channelling this substance breathes.
    fn from_substance(key: &str) -> DamageType {
        match key {
            "ammonia" => DamageType::Acid,
            "co2" | "nitrogen" | "water" => DamageType::Cold,
            "iron" | "silicon" => DamageType::Lightning,
            "sulfur" => DamageType::Poison,
            _ => DamageType::Fire,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attack {
    pub name: String,
    pub to_hit: i64,
    pub dice: i64,
    pub die: i64,
    pub bonus: i64,
    pub damage: DamageType,
    /// Times this attack is made each round.
    pub uses: i64,
}

impl Attack {
    /// Average damage of one hit.
    pub fn average(&self) -> Fx {
        (Fx::ratio(self.dice * (self.die + 1), 2) + Fx::from_int(self.bonus)).max(Fx::ONE)
    }

    pub fn describe(&self) -> String {
        let bonus = match self.bonus {
            0 => String::new(),
            b if b > 0 => format!(" + {b}"),
            b => format!(" − {}", -b),
        };
        let times = if self.uses > 1 {
            format!(" (×{})", self.uses)
        } else {
            String::new()
        };
        format!(
            "{}{}: {:+} to hit, {}d{}{} {} damage",
            self.name,
            times,
            self.to_hit,
            self.dice,
            self.die,
            bonus,
            self.damage.name()
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Breath {
    pub name: String,
    pub dice: i64,
    pub damage: DamageType,
    /// Ability used for the saving throw (index into `abilities`).
    pub save_ability: usize,
    pub dc: i64,
    /// Most targets caught in the area.
    pub targets: i64,
}

impl Breath {
    pub fn average(&self) -> Fx {
        Fx::ratio(self.dice * 7, 2)
    }

    pub fn describe(&self) -> String {
        format!(
            "{} (recharge 5–6): {}d6 {} damage, DC {} {} save for half",
            self.name,
            self.dice,
            self.damage.name(),
            self.dc,
            ABILITY_NAMES[self.save_ability]
        )
    }
}

pub const ABILITY_NAMES: [&str; 6] = ["STR", "DEX", "CON", "INT", "WIS", "CHA"];
pub const STR: usize = 0;
pub const DEX: usize = 1;
pub const CON: usize = 2;
pub const INT: usize = 3;
pub const WIS: usize = 4;
pub const CHA: usize = 5;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Trait {
    pub name: String,
    pub text: String,
}

/// How the cost was reached, so the UI can explain it (§5.3).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CostBreakdown {
    /// Hit points adjusted for armour class and resistances.
    pub effective_hp: Fx,
    /// Expected damage per round against armour class 15.
    pub damage_per_round: Fx,
    /// Bonus fraction for mobility, senses and special traits.
    pub utility: Fx,
    /// Small bonus for high ability scores.
    pub stats: Fx,
    pub power: Fx,
    pub cost: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CharacterSheet {
    pub name: String,
    pub creature_type: String,
    pub size: SizeCategory,
    pub alignment: String,
    /// Indexed by STR, DEX, CON, INT, WIS, CHA.
    pub abilities: [i64; 6],
    pub armor_class: i64,
    pub hit_dice: i64,
    pub hit_points: i64,
    pub speed_walk: i64,
    pub speed_swim: i64,
    pub speed_fly: i64,
    pub speed_burrow: i64,
    pub proficiency: i64,
    pub senses: Vec<String>,
    pub languages: Vec<String>,
    pub resistances: Vec<DamageType>,
    pub immunities: Vec<DamageType>,
    pub vulnerabilities: Vec<DamageType>,
    pub attacks: Vec<Attack>,
    pub breath: Option<Breath>,
    pub traits: Vec<Trait>,
    /// Regains this many hit points at the start of each turn (sunlight).
    pub regeneration: i64,
    /// +2 to hit while an ally fights alongside.
    pub pack_tactics: bool,
    /// Wisdom save DC against being frightened by its presence, if any.
    pub frighten_dc: Option<i64>,
    pub cost: CostBreakdown,
}

pub fn modifier(score: i64) -> i64 {
    (score - 10).div_euclid(2)
}

impl CharacterSheet {
    pub fn modifier(&self, ability: usize) -> i64 {
        modifier(self.abilities[ability])
    }

    pub fn has_trait(&self, name: &str) -> bool {
        self.traits.iter().any(|t| t.name == name)
    }

    /// Damage multiplier against a damage type: ×0, ×½, ×1 or ×2.
    pub fn damage_taken(&self, damage: i64, kind: DamageType) -> i64 {
        if self.immunities.contains(&kind) {
            0
        } else if self.resistances.contains(&kind) {
            damage / 2
        } else if self.vulnerabilities.contains(&kind) {
            damage * 2
        } else {
            damage
        }
    }
}

/// Chance that an attack with `to_hit` hits armour class `ac` (5%–95%).
pub fn hit_chance(to_hit: i64, ac: i64) -> Fx {
    Fx::ratio(21 + to_hit - ac, 20).clamp(Fx::ratio(5, 100), Fx::ratio(95, 100))
}

fn clamp_score(v: Fx, max: i64) -> i64 {
    v.round().clamp(1, max)
}

fn round5(v: Fx) -> i64 {
    (v / Fx::from_int(5)).round() * 5
}

/// The sheet of a typical member of a species.
pub fn species_sheet(world: &World, species: &Species) -> CharacterSheet {
    build(world, species, None)
}

/// The sheet of a named individual: its species' body with its own mind and
/// standing.
pub fn individual_sheet(world: &World, individual: &Individual) -> Option<CharacterSheet> {
    let species = world.species_by_id(individual.species)?;
    Some(build(world, species, Some(individual)))
}

fn build(world: &World, s: &Species, ind: Option<&Individual>) -> CharacterSheet {
    let g = &s.genome;
    let b = &g.body;
    let t = &s.traits;
    let nervous = s.has(body::NERVOUS);
    let sapient = s.has(body::SAPIENCE);
    let otherworldly = s.has(body::OTHERWORLDLY);
    let temperament = ind.map_or(s.temperament, |i| i.personality);
    let size = g.size;
    let category = SizeCategory::from_size(size);
    let l = size.log2();
    let limbs = b.count(PartKind::Limb) as i64;
    let element = world.elements[s.profile.element as usize].as_str();
    let medium_key = world.substances[s.profile.medium as usize].key.as_str();

    // Ability scores. A human-sized, unremarkable body scores about 10.
    let strength = clamp_score(
        Fx::from_int(10)
            + l * Fx::from_int(2)
            + Fx::from_int(if limbs > 0 { 2 } else { 0 })
            + t.offense * Fx::from_int(3),
        40,
    );
    let dexterity = clamp_score(
        Fx::from_int(10) + (t.speed - Fx::ratio(3, 10)) * Fx::from_int(12)
            - l.max(Fx::ZERO) * Fx::ratio(8, 10),
        30,
    );
    let constitution = clamp_score(
        Fx::from_int(10) + l * Fx::ratio(15, 10) + t.armor * Fx::from_int(5),
        40,
    );
    let intelligence = clamp_score(
        Fx::ONE
            + t.intelligence * Fx::from_int(20)
            + Fx::from_int(if sapient || otherworldly { 4 } else { 0 }),
        30,
    );
    let caution = if nervous {
        (Fx::ONE - temperament.curiosity) * Fx::from_int(4)
    } else {
        Fx::ZERO
    };
    let age_bonus = ind.map_or(Fx::ZERO, |i| {
        Fx::from_int(i.age_years(world.tick).min(60) as i64) / Fx::from_int(20)
    });
    let wisdom = clamp_score(
        Fx::from_int(6) + t.perception * Fx::from_int(8) + caution + age_bonus,
        30,
    );
    // An overwhelming presence: beings from beyond are hard to ignore.
    let presence = if otherworldly { 6 } else { 0 };
    let charisma = match ind {
        Some(i) => (i.charisma() + presence).min(30),
        None if otherworldly => clamp_score(
            Fx::from_int(8 + presence) + temperament.sociability * Fx::from_int(6),
            30,
        ),
        None if nervous => clamp_score(
            Fx::from_int(2) + temperament.sociability * Fx::from_int(10),
            30,
        ),
        None => 1,
    };
    let abilities = [
        strength,
        dexterity,
        constitution,
        intelligence,
        wisdom,
        charisma,
    ];

    // Hit dice grow with body mass: about 1 for a person, 9 for an elephant,
    // 22 for an ancient dragon.
    let hit_dice = (l * Fx::ratio(55, 100)).exp2().round().max(1);
    let die = category.hit_die();
    let con_mod = modifier(constitution);
    let hit_points = (hit_dice * ((die + 1) / 2 + con_mod)).max(1);
    let proficiency = (2 + hit_dice / 8).clamp(2, 9);
    // A phase membrane leaves part of the body elsewhere: harder to hit.
    let phased = if b.count(PartKind::PhaseMembrane) > 0 { 2 } else { 0 };
    let armor_class =
        (10 + modifier(dexterity) + (t.armor * Fx::from_int(9)).round() + phased).clamp(5, 30);

    // Speeds in feet.
    let speed_scale =
        |base: i64, range: i64| round5(Fx::from_int(base) + t.speed * Fx::from_int(range));
    let speed_walk = if limbs > 0 {
        speed_scale(20, 40)
    } else if otherworldly {
        speed_scale(10, 30)
    } else if b.count(PartKind::Segment) >= 2 && b.count(PartKind::Fin) == 0 {
        10
    } else {
        0
    };
    let speed_swim = if b.count(PartKind::Fin) > 0 {
        speed_scale(20, 40)
    } else {
        10
    };
    let speed_fly = if b.count(PartKind::Wing) > 0 {
        speed_scale(30, 60)
    } else if otherworldly {
        // Drifts, unbound by gravity.
        speed_scale(10, 30)
    } else {
        0
    };
    let speed_burrow = if b.count(PartKind::Segment) >= 4 && limbs == 0 {
        10
    } else {
        0
    };

    // Biochemistry decides resistances.
    let mut resistances = Vec::new();
    let mut immunities = Vec::new();
    let mut vulnerabilities = Vec::new();
    if g.temp_opt < Fx::from_int(200) {
        resistances.push(DamageType::Cold);
        vulnerabilities.push(DamageType::Fire);
    } else if g.temp_opt > Fx::from_int(600) {
        immunities.push(DamageType::Fire);
        vulnerabilities.push(DamageType::Cold);
    }
    match element {
        "Silicon" => {
            if !immunities.contains(&DamageType::Fire) {
                resistances.push(DamageType::Fire);
            }
            vulnerabilities.push(DamageType::Thunder);
        }
        "Sulfur" => immunities.push(DamageType::Poison),
        _ => {}
    }
    if medium_key == "ammonia" {
        resistances.push(DamageType::Acid);
    }
    if t.armor > Fx::ratio(6, 10) {
        resistances.extend([
            DamageType::Bludgeoning,
            DamageType::Piercing,
            DamageType::Slashing,
        ]);
    }
    if !nervous {
        immunities.push(DamageType::Psychic);
    }
    if otherworldly {
        // Ordinary weapons only half touch it; its chemistry is not ours.
        resistances.retain(|r| *r != DamageType::Cold && *r != DamageType::Acid);
        immunities.retain(|r| *r != DamageType::Fire && *r != DamageType::Poison);
        vulnerabilities.clear();
        resistances.extend([
            DamageType::Bludgeoning,
            DamageType::Piercing,
            DamageType::Slashing,
            DamageType::Psychic,
        ]);
    }
    resistances.sort();
    resistances.dedup();
    vulnerabilities.retain(|v| !resistances.contains(v) && !immunities.contains(v));

    // Senses.
    let eyes = b.count(PartKind::Eye);
    let mut senses = Vec::new();
    if otherworldly && eyes >= 4 {
        senses.push("truesight 60 ft.".to_string());
    } else if otherworldly {
        senses.push("darkvision 120 ft.".to_string());
    } else if !nervous {
        senses.push("blindsight 10 ft. (blind beyond)".to_string());
    } else if eyes == 0 {
        senses.push("tremorsense 30 ft.".to_string());
    } else if eyes >= 4 {
        senses.push("darkvision 120 ft.".to_string());
    } else if t.perception > Fx::ratio(3, 10) {
        senses.push("darkvision 60 ft.".to_string());
    }
    let keen = t.perception > Fx::ratio(6, 10);
    let passive = 10 + modifier(wisdom) + if keen { proficiency } else { 0 };
    senses.push(format!("passive Perception {passive}"));

    let languages = if otherworldly {
        vec!["telepathy 120 ft.".to_string()]
    } else if sapient {
        if b.count(PartKind::Jaw) == 0 {
            vec![format!("{} (telepathy 60 ft.)", s.name)]
        } else {
            vec![s.name.clone()]
        }
    } else {
        Vec::new()
    };

    // Attacks from weapon parts. Small, quick bodies fight with agility.
    let attack_mod = modifier(strength).max(modifier(dexterity));
    let to_hit = proficiency + attack_mod;
    let ddie = category.damage_die();
    let smaller = (ddie - 2).max(4);
    let mut attacks = Vec::new();
    if let Some(jaw) = b.part(PartKind::Jaw) {
        let dice = if Fx::from_int(jaw.count as i64) * jaw.size >= Fx::from_int(2) {
            2
        } else {
            1
        };
        attacks.push(Attack {
            name: "Bite".into(),
            to_hit,
            dice,
            die: ddie,
            bonus: attack_mod,
            damage: DamageType::Piercing,
            uses: 1,
        });
    }
    if let Some(claw) = b.part(PartKind::Claw) {
        attacks.push(Attack {
            name: "Claw".into(),
            to_hit,
            dice: 1,
            die: smaller,
            bonus: attack_mod,
            damage: DamageType::Slashing,
            uses: (claw.count as i64).min(2),
        });
    }
    if let Some(tendril) = b.part(PartKind::Tendril) {
        attacks.push(Attack {
            name: "Tendril".into(),
            to_hit,
            dice: 1,
            die: smaller,
            bonus: attack_mod,
            damage: DamageType::Bludgeoning,
            uses: (tendril.count as i64 / 2).clamp(1, 3),
        });
    }
    if otherworldly {
        let int_mod = modifier(intelligence);
        attacks.push(Attack {
            name: "Mind Lash".into(),
            to_hit: proficiency + int_mod.max(attack_mod),
            dice: 1 + hit_dice / 4,
            die: 8,
            bonus: int_mod.max(0),
            damage: DamageType::Psychic,
            uses: 1,
        });
    }
    if let Some(tentacle) = b.part(PartKind::Tentacle) {
        attacks.push(Attack {
            name: "Tentacle".into(),
            to_hit,
            dice: 1,
            die: smaller,
            bonus: attack_mod,
            damage: DamageType::Bludgeoning,
            uses: (tentacle.count as i64 / 2).clamp(1, 2),
        });
    }
    if attacks.is_empty() {
        attacks.push(Attack {
            name: "Slam".into(),
            to_hit,
            dice: 1,
            die: smaller,
            bonus: attack_mod,
            damage: DamageType::Bludgeoning,
            uses: 1,
        });
    }
    // Big, coordinated bodies strike more often.
    if category >= SizeCategory::Large && t.intelligence > Fx::ratio(15, 100) {
        attacks[0].uses += 1;
    }

    let void = b.part(PartKind::Void).map(|_| Breath {
        name: "Void Pulse".into(),
        dice: (hit_dice / 2 + 1).max(2),
        damage: DamageType::Psychic,
        save_ability: WIS,
        dc: 8 + proficiency + modifier(charisma),
        targets: if category >= SizeCategory::Huge { 3 } else { 2 },
    });
    let breath = void.or_else(|| b
        .part(PartKind::Gland)
        .and_then(|gland| gland.substance)
        .map(|sub| {
            let substance = &world.substances[sub as usize];
            let damage = DamageType::from_substance(&substance.key);
            Breath {
                name: format!("{} Breath", substance.name),
                dice: (hit_dice / 2 + 1).max(2),
                damage,
                save_ability: if damage == DamageType::Poison {
                    CON
                } else {
                    DEX
                },
                dc: 8 + proficiency + con_mod,
                targets: if category >= SizeCategory::Huge { 3 } else { 2 },
            }
        }));

    // Traits.
    let mut traits = Vec::new();
    let mut regeneration = 0;
    if b.count(PartKind::Leaf) > 0 && s.profile.energy == EnergyKind::Light {
        regeneration = (hit_dice / 2).max(1);
        traits.push(Trait {
            name: "Sunfed".into(),
            text: format!(
                "Regains {regeneration} hit point{} at the start of its turn in sunlight.",
                if regeneration == 1 { "" } else { "s" }
            ),
        });
    }
    let pack_tactics = nervous && temperament.sociability > Fx::ratio(6, 10);
    if pack_tactics {
        traits.push(Trait {
            name: "Pack Tactics".into(),
            text: "+2 to hit while an ally fights alongside it.".into(),
        });
    }
    if keen {
        traits.push(Trait {
            name: "Keen Senses".into(),
            text: "Proficient in Perception.".into(),
        });
    }
    if speed_fly > 0 {
        traits.push(Trait {
            name: "Flyby".into(),
            text: "Provokes no opportunity attacks when it flies out of reach.".into(),
        });
    }
    if !s.has(body::MULTICELLULAR) {
        traits.push(Trait {
            name: "Amorphous".into(),
            text: "Can move through spaces as narrow as 1 inch.".into(),
        });
    }
    if otherworldly {
        traits.push(Trait {
            name: "Otherworldly".into(),
            text: "Does not eat, breathe or age as native life does. It feeds on nearby minds."
                .into(),
        });
        traits.push(Trait {
            name: "Maddening Presence".into(),
            text: format!(
                "Creatures that start their turn within 30 ft. and can see it must succeed on a DC {} Wisdom save or be frightened until the end of their next turn.",
                8 + proficiency + modifier(charisma)
            ),
        });
        if b.count(PartKind::PhaseMembrane) > 0 {
            traits.push(Trait {
                name: "Phase Membrane".into(),
                text: "Part of its body is always elsewhere (+2 AC).".into(),
            });
        }
    }
    if sapient {
        traits.push(Trait {
            name: "Tool User".into(),
            text: "Can wield weapons and wear armour made by its people.".into(),
        });
    }

    let creature_type = if otherworldly {
        "Aberration"
    } else if !s.has(body::MULTICELLULAR) {
        "Ooze"
    } else if sapient {
        "Humanoid"
    } else if b.count(PartKind::Wing) > 0
        && limbs >= 4
        && breath.is_some()
        && size >= Fx::from_int(4)
    {
        "Dragon"
    } else if element != "Carbon" {
        "Elemental"
    } else if !nervous && b.count(PartKind::Leaf) > 0 {
        "Plant"
    } else if breath.is_some() || (t.offense > Fx::ratio(4, 10) && category >= SizeCategory::Large)
    {
        "Monstrosity"
    } else {
        "Beast"
    };

    let alignment = if otherworldly {
        "Unknowable".to_string()
    } else if !sapient {
        "Unaligned".to_string()
    } else {
        let order = if temperament.sociability > Fx::ratio(6, 10) {
            "Lawful"
        } else if temperament.curiosity > Fx::ratio(6, 10) {
            "Chaotic"
        } else {
            "Neutral"
        };
        let morals = if temperament.aggression > Fx::ratio(65, 100) {
            "Evil"
        } else if temperament.aggression < Fx::ratio(35, 100) {
            "Good"
        } else {
            "Neutral"
        };
        if order == "Neutral" && morals == "Neutral" {
            "True Neutral".into()
        } else {
            format!("{order} {morals}")
        }
    };

    let mut sheet = CharacterSheet {
        name: ind.map_or_else(|| s.name.clone(), |i| i.title()),
        creature_type: creature_type.to_string(),
        size: category,
        alignment,
        abilities,
        armor_class,
        hit_dice,
        hit_points,
        speed_walk,
        speed_swim,
        speed_fly,
        speed_burrow,
        proficiency,
        senses,
        languages,
        resistances,
        immunities,
        vulnerabilities,
        attacks,
        breath,
        traits,
        regeneration,
        pack_tactics,
        frighten_dc: otherworldly.then(|| 8 + proficiency + modifier(charisma)),
        cost: CostBreakdown::default(),
    };
    sheet.cost = cost(&sheet);
    sheet
}

/// Converts combat power to cost. Calibrated so a 5e-style commoner costs 1
/// and an ancient-dragon-like being about 300 (§5.3).
const COST_PER_POWER: Fx = Fx::ratio(85, 100);

/// Cost from combat power (§5.3).
///
/// In a fight, A beats B when A's effective HP × damage per round exceeds
/// B's. Power is the square root of that product, which makes it additive
/// under Lanchester's square law: ten units of power 10 are about as strong
/// together as one unit of power 100. Cost is linear in power, so armies of
/// cheap units and single expensive champions are fairly priced against each
/// other at the same total cost.
pub fn cost(sheet: &CharacterSheet) -> CostBreakdown {
    let reference_ac = 15;
    let reference_to_hit = 7;
    let mut attacks_dpr = Fx::ZERO;
    for a in &sheet.attacks {
        let to_hit = a.to_hit + if sheet.pack_tactics { 2 } else { 0 };
        attacks_dpr += hit_chance(to_hit, reference_ac) * a.average() * Fx::from_int(a.uses);
    }
    let dpr = match &sheet.breath {
        // Breath recharges about one round in three; a failed save takes
        // full damage, a success half.
        Some(b) => {
            let breath = b.average() * Fx::ratio(8, 10);
            if breath > attacks_dpr {
                (breath + attacks_dpr * Fx::from_int(2)) / Fx::from_int(3)
            } else {
                attacks_dpr
            }
        }
        None => attacks_dpr,
    };

    let mut toughness = Fx::ONE
        + Fx::ratio(sheet.resistances.len() as i64, 10)
        + Fx::ratio(sheet.immunities.len() as i64, 5)
        - Fx::ratio(sheet.vulnerabilities.len() as i64, 10);
    toughness = toughness.clamp(Fx::ratio(7, 10), Fx::from_int(2));
    let regen = Fx::ONE + Fx::ratio(sheet.regeneration, sheet.hit_points.max(1)) * Fx::from_int(3);
    let effective_hp = Fx::from_int(sheet.hit_points)
        / hit_chance(reference_to_hit, sheet.armor_class)
        * Fx::ratio(65, 100)
        * toughness
        * regen;

    let mut utility = Fx::ZERO;
    if sheet.speed_fly > 0 {
        utility += Fx::ratio(15, 100);
    }
    if sheet.speed_swim > 10 {
        utility += Fx::ratio(5, 100);
    }
    if sheet.speed_burrow > 0 {
        utility += Fx::ratio(5, 100);
    }
    if sheet
        .senses
        .iter()
        .any(|s| s.starts_with("darkvision") || s.starts_with("tremorsense"))
    {
        utility += Fx::ratio(5, 100);
    }
    if sheet.senses.iter().any(|s| s.starts_with("truesight")) {
        utility += Fx::ratio(1, 10);
    }
    if sheet.has_trait("Maddening Presence") {
        utility += Fx::ratio(15, 100);
    }
    if sheet.has_trait("Tool User") {
        utility += Fx::ratio(1, 10);
    }
    let stat_sum: i64 = sheet.abilities.iter().map(|a| (a - 10).max(0)).sum();
    let stats = Fx::ONE + Fx::ratio(stat_sum, 1000);

    let power = (effective_hp * dpr).sqrt() * (Fx::ONE + utility) * stats;
    let cost = (power * COST_PER_POWER).round().clamp(1, 1000);
    CostBreakdown {
        effective_hp,
        damage_per_round: dpr,
        utility,
        stats,
        power,
        cost,
    }
}
