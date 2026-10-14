//! The Essence shop (docs/GAME_DESIGN.md §3). Players spend Essence on
//! the server; each purchase that changes a world arrives as a grant the
//! server signs, logged in the world like loot. The simulation does not
//! check signatures (it has no key); the server does when it replays a
//! world (§6.2).

use crate::fixed::Fx;
use crate::substance::{ShopClass, Substance};
use crate::world::{brush, World, MAX_MOONS};
use serde::{Deserialize, Serialize};

/// Price of one more moon slot for a world.
pub const MOON_PRICE: u64 = 10_000;
/// Price of one more home world.
pub const PLANET_PRICE: u64 = 50_000;
/// Essence for a ranked win.
pub const WIN_ESSENCE: u64 = 500;
/// A deposit adds this much of the element to each region it covers.
pub const DEPOSIT_AMOUNT: Fx = Fx::from_int(2);
pub const DEPOSIT_RADIUS: u8 = 2;

/// Proposed deposit prices by element class (owner to confirm).
pub fn deposit_price(class: ShopClass) -> u64 {
    match class {
        ShopClass::HeavyMetal => 1_000,
        ShopClass::RareEarth => 2_000,
        ShopClass::Radioactive => 3_000,
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ShopItem {
    /// A deposit of a shop element (by substance key) in one place.
    Deposit { substance: String },
    /// One more moon slot for a world.
    MoonSlot,
    /// One more home world for the account (no world effect).
    PlanetSlot,
}

impl ShopItem {
    /// Price in Essence, or None if the item is not for sale.
    pub fn price(&self, world: &World) -> Option<u64> {
        self.price_in(&world.substances)
    }

    /// Price in Essence from a substance table.
    pub fn price_in(&self, substances: &[Substance]) -> Option<u64> {
        match self {
            ShopItem::Deposit { substance } => substances
                .iter()
                .find(|s| &s.key == substance)
                .and_then(|s| s.shop)
                .map(deposit_price),
            ShopItem::MoonSlot => Some(MOON_PRICE),
            ShopItem::PlanetSlot => Some(PLANET_PRICE),
        }
    }
}

/// Everything for sale: (item, display name, price).
pub fn catalogue(world: &World) -> Vec<(ShopItem, String, u64)> {
    let mut items: Vec<(ShopItem, String, u64)> = world
        .substances
        .iter()
        .filter_map(|s| {
            let class = s.shop?;
            Some((
                ShopItem::Deposit {
                    substance: s.key.clone(),
                },
                format!("{} deposit ({})", s.name, class.name().to_lowercase()),
                deposit_price(class),
            ))
        })
        .collect();
    items.push((ShopItem::MoonSlot, "Extra moon".into(), MOON_PRICE));
    items.push((ShopItem::PlanetSlot, "Extra planet".into(), PLANET_PRICE));
    items
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShopGrant {
    pub id: u64,
    /// The buyer who may use it.
    pub account: String,
    pub item: ShopItem,
    /// Server signature (hex) over the grant with this field empty.
    pub signature: String,
}

impl ShopGrant {
    /// The bytes the server signs.
    pub fn payload(&self) -> Vec<u8> {
        let mut unsigned = self.clone();
        unsigned.signature.clear();
        serde_json::to_vec(&unsigned).expect("grants serialise")
    }
}

impl World {
    pub(crate) fn apply_purchase(&mut self, grant: &ShopGrant, x: u16, y: u16) {
        match &grant.item {
            ShopItem::Deposit { substance } => {
                let Some(s) = self.substance_index(substance) else {
                    return;
                };
                if self.substances[s].shop.is_none() {
                    return;
                }
                for i in brush(x, y, DEPOSIT_RADIUS) {
                    self.regions[i].amounts[s] += DEPOSIT_AMOUNT;
                }
            }
            ShopItem::MoonSlot => {
                if self.planet.host.is_none() {
                    self.planet.moon_slots = (self.planet.moon_slots + 1).min(MAX_MOONS as u8);
                }
            }
            ShopItem::PlanetSlot => {}
        }
    }

    /// Radioactive elements in a region (units of uranium and thorium).
    pub fn radioactivity(&self, i: usize) -> Fx {
        self.substances
            .iter()
            .zip(&self.regions[i].amounts)
            .filter(|(s, _)| s.shop == Some(ShopClass::Radioactive))
            .fold(Fx::ZERO, |a, (_, amount)| a + *amount)
            .min(Fx::from_int(10))
    }
}
