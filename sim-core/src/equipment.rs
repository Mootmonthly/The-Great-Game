//! Equipment (docs/GAME_DESIGN.md §5.4). Civilizations arm their people.
//! Gear fits body parts, not body types: hands hold weapons and shields,
//! tentacles hold blades, jaws take fang caps, bodies wear armour, wings
//! carry blades, glands take breath foci and sapient minds use spell foci.
//! What it is made of depends on the materials in the civilization's lands
//! and its era; magic traditions enchant it.

use crate::body::{self, PartKind};
use crate::civ::{Civilization, FORGING};
use crate::life::Species;
use crate::sheet::DamageType;
use crate::world::World;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Slot {
    Hand,
    Tentacle,
    Jaw,
    Body,
    Wing,
    Gland,
    Mind,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub name: String,
    pub slot: Slot,
    /// A weapon's damage die and type (one die per hit).
    pub die: i64,
    pub damage: Option<DamageType>,
    /// Hits per round with this weapon.
    pub uses: i64,
    pub to_hit: i64,
    pub damage_bonus: i64,
    pub armor: i64,
    pub breath_dice: i64,
    pub spell_to_hit: i64,
}

impl Item {
    fn new(name: String, slot: Slot) -> Item {
        Item {
            name,
            slot,
            die: 0,
            damage: None,
            uses: 0,
            to_hit: 0,
            damage_bonus: 0,
            armor: 0,
            breath_dice: 0,
            spell_to_hit: 0,
        }
    }

    pub fn describe(&self) -> String {
        let mut bits = Vec::new();
        if let Some(d) = self.damage {
            let times = if self.uses > 1 {
                format!(" ×{}", self.uses)
            } else {
                String::new()
            };
            bits.push(format!("1d{} {}{}", self.die, d.name(), times));
        }
        if self.armor > 0 {
            bits.push(format!("+{} AC", self.armor));
        }
        if self.damage_bonus > 0 && self.damage.is_none() {
            bits.push(format!("+{} bite damage", self.damage_bonus));
        }
        if self.breath_dice > 0 {
            bits.push(format!("+{}d6 breath", self.breath_dice));
        }
        if self.spell_to_hit > 0 {
            bits.push(format!("+{} to hit with spells", self.spell_to_hit));
        }
        format!("{} ({})", self.name, bits.join(", "))
    }
}

/// What a civilization makes its gear from: name and grade 0–3.
pub fn material(world: &World, civ: &Civilization, species: &Species) -> (&'static str, i64) {
    let era = world.era(civ);
    let element = world.elements[species.profile.element as usize].as_str();
    if era >= FORGING && world.civ_has(civ, "tungsten") {
        ("tungsten", 4)
    } else if era >= FORGING && world.civ_has(civ, "iron") {
        ("iron", 3)
    } else if era >= 2 && element == "Silicon" {
        ("crystal", 2)
    } else if era >= 2 && world.civ_has(civ, "silicate") {
        ("obsidian", 1)
    } else if world.civ_has(civ, "carbon") {
        ("bone and wood", 0)
    } else {
        ("chitin", 0)
    }
}

fn capitalise(s: &str) -> String {
    let mut c = s.chars();
    c.next()
        .map_or_else(String::new, |f| f.to_uppercase().collect::<String>() + c.as_str())
}

/// The gear a member of this species carries, made by its civilization.
/// Beings without a civilization, and peoples still Primitive, carry none.
pub fn loadout(world: &World, species: &Species) -> Vec<Item> {
    let Some(civ) = world.civ_of_species(species.id) else {
        return Vec::new();
    };
    let era = world.era(civ) as i64;
    if era < 1 || species.has(body::OTHERWORLDLY) {
        return Vec::new();
    }
    let (mat, grade) = material(world, civ, species);
    let arcana = world.arcana_level(civ) as i64;
    // Gold carries enchantments well: magic traditions with gold enchant
    // their gear a level sooner and make better spell foci.
    let gold = world.civ_has(civ, "gold") as i64;
    let enchanted = arcana + gold >= 3;
    let prefix = if enchanted { "enchanted " } else { "" };
    let b = &species.genome.body;
    let culture = civ.culture;
    let mut items = Vec::new();
    let weapon_die = |base: i64| (base + 2 * grade).min(12);

    let limbs = b.count(PartKind::Limb);
    if limbs >= 2 {
        let (kind, base, damage) = if culture.militarism > crate::fixed::Fx::ratio(6, 10) {
            ("war axe", 8, DamageType::Slashing)
        } else if culture.openness > crate::fixed::Fx::ratio(6, 10) {
            ("spear", 6, DamageType::Piercing)
        } else {
            ("sword", 6, DamageType::Slashing)
        };
        let mut w = Item::new(capitalise(&format!("{prefix}{mat} {kind}")), Slot::Hand);
        w.die = weapon_die(base);
        w.damage = Some(damage);
        w.uses = 1;
        w.to_hit = era / 2 + enchanted as i64;
        w.damage_bonus = 2 * enchanted as i64;
        items.push(w);
        if limbs >= 4 && culture.caution > crate::fixed::Fx::HALF {
            let mut s = Item::new(capitalise(&format!("{mat} shield")), Slot::Hand);
            s.armor = 2 + grade / 2;
            items.push(s);
        }
    }
    let tentacles = b.count(PartKind::Tentacle);
    if tentacles >= 2 {
        let mut t = Item::new(capitalise(&format!("{prefix}{mat} tentacle blades")), Slot::Tentacle);
        t.die = weapon_die(4);
        t.damage = Some(DamageType::Piercing);
        t.uses = (tentacles as i64 / 2).min(3);
        t.to_hit = era / 2 + enchanted as i64;
        t.damage_bonus = 2 * enchanted as i64;
        items.push(t);
    }
    let mut armour = Item::new(capitalise(&format!("{mat} armour")), Slot::Body);
    armour.armor = 1 + grade + era / 2;
    items.push(armour);
    if era >= 2 && b.count(PartKind::Jaw) > 0 {
        let mut f = Item::new(capitalise(&format!("{mat} fang caps")), Slot::Jaw);
        f.damage_bonus = 1 + grade;
        items.push(f);
    }
    if era >= FORGING as i64 && b.count(PartKind::Wing) > 0 {
        let mut w = Item::new(capitalise(&format!("{prefix}{mat} wing blades")), Slot::Wing);
        w.die = weapon_die(6);
        w.damage = Some(DamageType::Slashing);
        w.uses = 1;
        w.to_hit = era / 2 + enchanted as i64;
        items.push(w);
    }
    if era >= 4 && b.count(PartKind::Gland) > 0 {
        let mut g = Item::new(capitalise(&format!("{mat} breath focus")), Slot::Gland);
        g.breath_dice = 2;
        items.push(g);
    }
    if arcana >= 2 && species.has(body::SAPIENCE) {
        let focus_mat = if gold > 0 { "gold" } else { mat };
        let mut m = Item::new(capitalise(&format!("{focus_mat} spell focus")), Slot::Mind);
        m.spell_to_hit = 1 + arcana / 2 + gold;
        items.push(m);
    }
    items
}
