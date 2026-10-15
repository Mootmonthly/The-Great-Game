//! The archetype matcher (docs/GAME_DESIGN.md §4.4): beings whose bodies
//! come close to a known fantasy archetype take its name and a signature
//! ability. Large, winged, four-limbed breathers are Dragons; many-headed
//! ones are Hydras; sapient folk become Elves, Dwarves, Orcs and the like.
//! Beings that match nothing keep their generated names: classical monsters
//! and true aliens live side by side.
//!
//! Archetypes are checked from the most specific to the most general; the
//! first that fits wins. Each signature changes the sheet (an attack, a
//! resistance, a presence, regeneration or armour), so the cost (§5.3)
//! follows it.

use crate::body::{self, PartKind};
use crate::fixed::Fx;
use crate::life::Species;
use crate::sheet::{modifier, Attack, Breath, CharacterSheet, DamageType, SizeCategory, Trait, CHA, CON, INT};
use crate::world::World;

/// What the matcher looks at.
struct Features {
    limbs: i64,
    wings: i64,
    tentacles: i64,
    eyes: i64,
    jaws: i64,
    fins: i64,
    segments: i64,
    leaves: i64,
    shell: bool,
    glands: i64,
    size: SizeCategory,
    silicon: bool,
    sapient: bool,
    nervous: bool,
    otherworldly: bool,
    humanoid: bool,
    breath: Option<DamageType>,
    swims: bool,
    aggression: Fx,
    curiosity: Fx,
    caution: bool,
}

fn features(world: &World, s: &Species, sheet: &CharacterSheet) -> Features {
    let b = &s.genome.body;
    let count = |k: PartKind| b.count(k) as i64;
    Features {
        limbs: count(PartKind::Limb),
        wings: count(PartKind::Wing),
        tentacles: count(PartKind::Tentacle) + count(PartKind::Tendril),
        eyes: count(PartKind::Eye),
        jaws: count(PartKind::Jaw),
        fins: count(PartKind::Fin),
        segments: count(PartKind::Segment),
        leaves: count(PartKind::Leaf),
        shell: count(PartKind::Shell) > 0,
        glands: count(PartKind::Gland),
        size: sheet.size,
        silicon: world.elements[s.profile.element as usize] == "Silicon",
        sapient: s.has(body::SAPIENCE),
        nervous: s.has(body::NERVOUS),
        otherworldly: s.has(body::OTHERWORLDLY),
        humanoid: b.is_humanoid(),
        breath: sheet.breath.as_ref().map(|b| b.damage),
        swims: sheet.speed_swim > 0,
        aggression: s.temperament.aggression,
        curiosity: s.temperament.curiosity,
        caution: s.temperament.fear > Fx::HALF,
    }
}

/// The archetype a being matches, if any.
fn matched(f: &Features) -> Option<&'static str> {
    use SizeCategory::*;
    let big = f.size >= Large;
    let huge = f.size >= Huge;
    Some(if f.otherworldly {
        if f.eyes >= 6 {
            "Beholder"
        } else if f.tentacles >= 4 {
            "Star Spawn"
        } else {
            return None;
        }
    } else if f.sapient {
        if huge {
            "Giant"
        } else if f.tentacles >= 2 && !f.humanoid {
            "Mind Flayer"
        } else if f.fins > 0 && f.swims {
            "Merfolk"
        } else if f.wings > 0 {
            "Aarakocra"
        } else if !f.humanoid {
            return None;
        } else if f.size <= Small && f.aggression > Fx::ratio(6, 10) {
            "Goblin"
        } else if f.size <= Small {
            "Gnome"
        } else if f.shell || f.caution {
            "Dwarf"
        } else if f.aggression > Fx::ratio(6, 10) {
            "Orc"
        } else if f.curiosity > Fx::ratio(55, 100) {
            "Elf"
        } else {
            "Human"
        }
    } else if !f.nervous {
        // A Treant is a huge woody plant: bark (a shell) and leaves.
        if f.leaves > 0 && f.shell && huge {
            "Treant"
        } else {
            return None;
        }
    } else if f.wings > 0 && f.limbs >= 4 && f.breath.is_some() && big {
        "Dragon"
    } else if f.wings > 0 && f.breath == Some(DamageType::Fire) {
        "Phoenix"
    } else if f.wings > 0 && f.limbs <= 2 && f.glands > 0 && big {
        "Wyvern"
    } else if f.jaws >= 3 && big {
        "Hydra"
    } else if f.tentacles >= 6 && f.swims && huge {
        "Kraken"
    } else if f.fins > 0 && f.segments >= 4 && f.swims && big {
        "Sea Serpent"
    } else if f.wings > 0 && f.limbs >= 2 && huge {
        "Roc"
    } else if f.wings > 0 && f.limbs >= 4 && big {
        "Griffin"
    } else if f.silicon && f.shell {
        "Golem"
    } else if f.limbs >= 8 && f.eyes >= 6 {
        "Giant Spider"
    } else if f.limbs >= 6 && f.eyes >= 2 && f.glands > 0 && f.wings == 0 {
        "Basilisk"
    } else if huge && f.shell && f.limbs >= 4 && f.aggression < Fx::HALF {
        "Behemoth"
    } else {
        return None;
    })
}

fn attack(name: &str, to_hit: i64, dice: i64, die: i64, bonus: i64, damage: DamageType) -> Attack {
    Attack {
        name: name.into(),
        to_hit,
        dice: dice.max(1),
        die,
        bonus,
        damage,
        uses: 1,
    }
}

/// Gives the sheet its archetype name and signature ability.
pub fn apply(world: &World, s: &Species, sheet: &mut CharacterSheet) {
    let f = features(world, s, sheet);
    let Some(name) = matched(&f) else {
        return;
    };
    let prof = sheet.proficiency;
    let hd = sheet.hit_dice;
    let best = sheet.attacks.iter().map(|a| a.to_hit).max().unwrap_or(prof);
    let cha = sheet.modifier(CHA);
    let mut gain = |name: &str, text: String| sheet.traits.push(Trait { name: name.into(), text });
    let (signature, text): (&str, String) = match name {
        "Dragon" => ("Frightful Presence", "Creatures within 30 ft. must succeed on a Wisdom save or be frightened.".into()),
        "Phoenix" => ("Rekindle", "Fire mends it: immune to fire and regenerates.".into()),
        "Wyvern" => ("Venomous Stinger", "A barbed tail drips poison.".into()),
        "Hydra" => ("Many Heads", "Bites with every head, and lost heads grow back.".into()),
        "Kraken" => ("Crushing Grip", "Its arms crush whatever they hold.".into()),
        "Sea Serpent" => ("Tail Crush", "Coils and lashes with its long body.".into()),
        "Roc" => ("Diving Talons", "Drops from the sky onto its prey.".into()),
        "Griffin" => ("Pounce", "Leaps upon its prey with beak and claws.".into()),
        "Golem" => ("Stone Body", "Living rock shrugs off blows (+2 AC, resists weapons).".into()),
        "Giant Spider" => ("Venomous Bite", "Its fangs carry a paralysing venom.".into()),
        "Basilisk" => ("Petrifying Gaze", "Those who meet its eyes stiffen with dread.".into()),
        "Behemoth" => ("Trample", "Tramples whatever stands in its way; hard to wound.".into()),
        "Treant" => ("Living Wood", "Bark turns blows and roots heal it, but fire bites deep.".into()),
        "Beholder" => ("Eye Rays", "Each eye fires a ray of force.".into()),
        "Star Spawn" => ("Unravelling Touch", "Its tendrils unmake flesh.".into()),
        "Giant" => ("Rock Throw", "Hurls boulders at distant foes.".into()),
        "Mind Flayer" => ("Mind Blast", "A wave of psychic force stuns those around it.".into()),
        "Merfolk" => ("Child of the Sea", "Swims swiftly and fights well in water.".into()),
        "Aarakocra" => ("Dive Strike", "Strikes from above.".into()),
        "Goblin" => ("Nimble Escape", "Slippery and hard to pin down (+1 AC).".into()),
        "Gnome" => ("Gnome Cunning", "A quick mind resists magic and madness.".into()),
        "Dwarf" => ("Dwarven Resilience", "Stout and hard to poison.".into()),
        "Orc" => ("Relentless", "Fights on through wounds that would fell others.".into()),
        "Elf" => ("Keen Senses", "Sharp-eyed and quick with a blade or bow.".into()),
        _ => ("Versatile", "Adaptable and ambitious.".into()),
    };
    gain(signature, text);
    match name {
        "Dragon" | "Basilisk" => sheet.frighten_dc = Some(sheet.frighten_dc.unwrap_or(0).max(8 + prof + cha.max(0))),
        "Phoenix" => {
            if !sheet.immunities.contains(&DamageType::Fire) {
                sheet.immunities.push(DamageType::Fire);
            }
            sheet.resistances.retain(|d| *d != DamageType::Fire);
            sheet.vulnerabilities.retain(|d| *d != DamageType::Fire);
            sheet.regeneration += (hd / 3).max(1);
        }
        "Wyvern" | "Giant Spider" => sheet.attacks.push(attack(signature, best, hd / 3 + 1, 8, 0, DamageType::Poison)),
        "Hydra" => {
            if let Some(bite) = sheet.attacks.iter_mut().find(|a| a.name.contains("Bite")) {
                bite.uses += (f.jaws - 1).min(3);
            }
            sheet.regeneration += (hd / 4).max(1);
        }
        "Kraken" | "Sea Serpent" | "Behemoth" => {
            sheet.attacks.push(attack(signature, best, hd / 3 + 1, 10, 0, DamageType::Bludgeoning));
            if name == "Behemoth" && !sheet.resistances.contains(&DamageType::Bludgeoning) {
                sheet.resistances.push(DamageType::Bludgeoning);
            }
        }
        "Roc" | "Griffin" | "Aarakocra" => sheet.attacks.push(attack(signature, best, hd / 4 + 1, 8, 0, DamageType::Slashing)),
        "Golem" | "Treant" => {
            if name == "Golem" {
                sheet.armor_class += 2;
            }
            for d in [DamageType::Bludgeoning, DamageType::Piercing] {
                if !sheet.resistances.contains(&d) {
                    sheet.resistances.push(d);
                }
            }
            if name == "Treant" {
                sheet.regeneration += (hd / 4).max(1);
                if !sheet.immunities.contains(&DamageType::Fire) && !sheet.vulnerabilities.contains(&DamageType::Fire) {
                    sheet.resistances.retain(|d| *d != DamageType::Fire);
                    sheet.vulnerabilities.push(DamageType::Fire);
                }
            }
        }
        "Beholder" => sheet.attacks.push(Attack {
            uses: (f.eyes / 3).clamp(1, 3),
            ..attack(signature, prof + sheet.modifier(INT).max(0), 1 + hd / 6, 8, 0, DamageType::Force)
        }),
        "Star Spawn" => sheet.attacks.push(attack(signature, best, hd / 4 + 1, 8, 0, DamageType::Necrotic)),
        "Giant" => sheet.attacks.push(attack(signature, best, hd / 4 + 2, 10, 0, DamageType::Bludgeoning)),
        "Mind Flayer" => {
            if sheet.breath.is_none() {
                sheet.breath = Some(Breath {
                    name: signature.into(),
                    dice: (hd / 2 + 1).max(2),
                    damage: DamageType::Psychic,
                    save_ability: INT,
                    dc: 8 + prof + sheet.modifier(INT).max(0),
                    targets: 3,
                });
            }
        }
        "Merfolk" => sheet.speed_swim = sheet.speed_swim.max(40) + 10,
        "Goblin" => sheet.armor_class += 1,
        "Gnome" => {
            if !sheet.resistances.contains(&DamageType::Psychic) && !sheet.immunities.contains(&DamageType::Psychic) {
                sheet.resistances.push(DamageType::Psychic);
            }
        }
        "Dwarf" => {
            if !sheet.resistances.contains(&DamageType::Poison) && !sheet.immunities.contains(&DamageType::Poison) {
                sheet.resistances.push(DamageType::Poison);
            }
        }
        "Orc" => sheet.hit_points += hd.max(1) + modifier(sheet.abilities[CON]).max(0) * 2,
        "Elf" => {
            for a in sheet.attacks.iter_mut().filter(|a| !a.name.contains("Bolt") && !a.name.contains("Blast")) {
                a.to_hit += 1;
            }
            if !sheet.senses.iter().any(|s| s.starts_with("darkvision")) {
                sheet.senses.insert(0, "darkvision 60 ft.".into());
            }
        }
        _ => {}
    }
    sheet.resistances.sort();
    sheet.resistances.dedup();
    sheet.archetype = Some(name.to_string());
}
