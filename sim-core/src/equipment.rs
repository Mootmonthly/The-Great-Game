//! Equipment (docs/GAME_DESIGN.md §5.4). Civilizations arm their people.
//! Gear fits body parts, not body types: hands hold weapons and shields,
//! tentacles hold blades, jaws take fang caps, bodies wear armour, wings
//! carry blades, glands take breath foci and sapient minds use spell foci.
//! What it is made of depends on the materials in the civilization's lands
//! and its era; magic traditions enchant it.

use crate::body::{self, Body, PartKind};
use crate::civ::{Civilization, FORGING};
use crate::fixed::Fx;
use crate::individual::Individual;
use crate::life::Species;
use crate::sheet::{DamageType, SizeCategory};
use crate::world::{World, TICKS_PER_YEAR};
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
    /// Material grade 0–4; refitting takes grade + 1 years.
    #[serde(default)]
    pub grade: i64,
}

/// The shape gear is made for (§5.4): armour is shaped to the whole plan;
/// other gear needs the part it attaches to, on a body of the same size.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BodyPlan {
    pub size: SizeCategory,
    pub limbs: u8,
    pub tentacles: u8,
    pub wings: u8,
    pub jaws: u8,
    pub glands: u8,
    pub sapient: bool,
}

impl BodyPlan {
    pub fn of(b: &Body, size: Fx, milestones: u16) -> BodyPlan {
        let n = |k: PartKind| b.count(k);
        BodyPlan {
            size: SizeCategory::from_size(size),
            limbs: n(PartKind::Limb),
            tentacles: n(PartKind::Tentacle),
            wings: n(PartKind::Wing),
            jaws: n(PartKind::Jaw),
            glands: n(PartKind::Gland),
            sapient: milestones & body::SAPIENCE != 0,
        }
    }

    pub fn of_species(s: &Species) -> BodyPlan {
        BodyPlan::of(&s.genome.body, s.genome.size, s.genome.milestones)
    }

    pub fn describe(&self) -> String {
        let mut bits = vec![self.size.name().to_lowercase()];
        for (n, what) in [(self.limbs, "limb"), (self.tentacles, "tentacle"), (self.wings, "wing"), (self.jaws, "jaw"), (self.glands, "gland")] {
            if n > 0 {
                bits.push(format!("{n} {what}{}", if n == 1 { "" } else { "s" }));
            }
        }
        bits.join(", ")
    }
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
            grade: 0,
        }
    }

    /// Whether gear made for `made_for` fits a body of plan `wearer`.
    pub fn fits(&self, made_for: &BodyPlan, wearer: &BodyPlan) -> bool {
        if made_for.size != wearer.size {
            return false;
        }
        match self.slot {
            Slot::Body => {
                made_for.limbs == wearer.limbs && made_for.wings == wearer.wings && made_for.tentacles == wearer.tentacles
            }
            Slot::Hand => wearer.limbs >= 2,
            Slot::Tentacle => wearer.tentacles >= 2,
            Slot::Jaw => wearer.jaws > 0,
            Slot::Wing => wearer.wings > 0,
            Slot::Gland => wearer.glands > 0,
            Slot::Mind => wearer.sapient,
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
    let mut items: Vec<Item> = Vec::new();
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
    for it in &mut items {
        it.grade = grade;
    }
    items
}

/// Gear taken from a fallen champion (§5.4). It lives in a world's armoury
/// and may be carried by one named individual at a time.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Looted {
    pub id: u32,
    pub item: Item,
    /// The champion it was taken from.
    pub from: String,
    pub made_for: BodyPlan,
    /// The named individual carrying it, if any.
    pub holder: Option<u32>,
    /// Being refitted until this tick; useless until then.
    pub refit_until: Option<u64>,
}

/// Refitting gear to a new body takes this long: grade + 1 years.
pub fn refit_ticks(item: &Item) -> u64 {
    (item.grade.max(0) as u64 + 1) * TICKS_PER_YEAR
}

/// Everything a being carries: its people's gear, plus any looted gear a
/// named individual holds that fits it and is not being refitted.
pub fn gear_of(world: &World, species: &Species, ind: Option<&Individual>) -> Vec<Item> {
    let mut items = loadout(world, species);
    if let Some(x) = ind {
        let plan = BodyPlan::of_species(species);
        items.extend(
            world
                .armoury
                .iter()
                .filter(|l| l.holder == Some(x.id) && l.refit_until.is_none_or(|t| t <= world.tick) && l.item.fits(&l.made_for, &plan))
                .map(|l| l.item.clone()),
        );
    }
    items
}

impl World {
    /// Puts looted gear into the armoury.
    pub(crate) fn store_loot(&mut self, gear: &[Item], from: &str, made_for: BodyPlan) {
        for item in gear {
            self.next_item_id += 1;
            self.armoury.push(Looted {
                id: self.next_item_id,
                item: item.clone(),
                from: from.to_string(),
                made_for,
                holder: None,
                refit_until: None,
            });
        }
    }

    fn looted_index(&self, item: u32) -> Option<usize> {
        self.armoury.iter().position(|l| l.id == item)
    }

    fn wearer_plan(&self, individual: u32) -> Option<BodyPlan> {
        let x = self.individual_by_id(individual).filter(|x| x.is_alive())?;
        self.species_by_id(x.species).map(BodyPlan::of_species)
    }

    /// Gives a looted item to a living named individual, if it fits.
    pub(crate) fn equip(&mut self, item: u32, individual: u32) {
        let (Some(k), Some(plan)) = (self.looted_index(item), self.wearer_plan(individual)) else {
            return;
        };
        let l = &self.armoury[k];
        if l.holder.is_some() || l.refit_until.is_some_and(|t| t > self.tick) || !l.item.fits(&l.made_for, &plan) {
            return;
        }
        self.armoury[k].holder = Some(individual);
    }

    /// Returns a looted item to the armoury.
    pub(crate) fn unequip(&mut self, item: u32) {
        if let Some(k) = self.looted_index(item) {
            self.armoury[k].holder = None;
        }
    }

    /// Has the individual's people refit an item to its body. Needs a
    /// civilization of the Crafting era or later; takes grade + 1 years,
    /// during which the individual carries the useless item.
    pub(crate) fn refit(&mut self, item: u32, individual: u32) {
        let (Some(k), Some(plan)) = (self.looted_index(item), self.wearer_plan(individual)) else {
            return;
        };
        let species = self.individual_by_id(individual).map(|x| x.species).unwrap_or(0);
        let crafting = self.civ_of_species(species).is_some_and(|c| self.era(c) >= 2);
        let l = &self.armoury[k];
        let free = l.holder.is_none() || l.holder == Some(individual);
        if !crafting || !free || l.refit_until.is_some_and(|t| t > self.tick) {
            return;
        }
        let until = self.tick + refit_ticks(&l.item);
        let l = &mut self.armoury[k];
        l.made_for = plan;
        l.holder = Some(individual);
        l.refit_until = Some(until);
    }

    /// A named individual died at home: its gear goes back to the armoury.
    pub(crate) fn drop_gear(&mut self, individual: u32) {
        for l in self.armoury.iter_mut().filter(|l| l.holder == Some(individual)) {
            l.holder = None;
            l.refit_until = None;
        }
    }

    /// A champion fell in the arena: the winner looted its gear.
    pub(crate) fn lose_gear(&mut self, individual: u32) {
        self.armoury.retain(|l| l.holder != Some(individual));
    }
}
