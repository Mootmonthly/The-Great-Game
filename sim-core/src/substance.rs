//! Substances: elements and molecules, loaded from `data/substances.json`.

use crate::fixed::Fx;
use serde::Deserialize;

/// The default substance table, compiled into the library so every build
/// uses the same data.
pub const DEFAULT_SUBSTANCES_JSON: &str = include_str!("../../data/substances.json");

#[derive(Clone, Debug, Deserialize)]
struct RawSubstance {
    key: String,
    name: String,
    formula: String,
    molar_mass: i64,
    melt_k: i64,
    boil_k: i64,
    solvent: i64,
    backbone: i64,
    backbone_element: String,
    backbone_min_k: i64,
    backbone_max_k: i64,
    fuel: i64,
    oxidizer: i64,
    greenhouse: i64,
    color: String,
    #[serde(default)]
    shop: String,
}

#[derive(Deserialize)]
struct RawTable {
    substances: Vec<RawSubstance>,
}

#[derive(Clone, Debug)]
pub struct Substance {
    pub key: String,
    pub name: String,
    pub formula: String,
    pub molar_mass: Fx,
    pub melt_k: Fx,
    pub boil_k: Fx,
    /// 0..1: how well it works as a medium for life when liquid.
    pub solvent: Fx,
    /// 0..1: how well it supplies structural chains for life.
    pub backbone: Fx,
    pub backbone_element: String,
    pub backbone_min_k: Fx,
    pub backbone_max_k: Fx,
    /// 0..1: chemical energy released when burnt with an oxidizer.
    pub fuel: Fx,
    pub oxidizer: Fx,
    /// 0..1: warming strength as an atmospheric gas.
    pub greenhouse: Fx,
    pub color: [u8; 3],
    /// Elements bought with Essence (§3); the free tools cannot add them.
    pub shop: Option<ShopClass>,
}

/// The shop's element classes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShopClass {
    HeavyMetal,
    RareEarth,
    Radioactive,
}

impl ShopClass {
    fn parse(s: &str) -> Result<Option<ShopClass>, String> {
        Ok(match s {
            "" => None,
            "heavy_metal" => Some(ShopClass::HeavyMetal),
            "rare_earth" => Some(ShopClass::RareEarth),
            "radioactive" => Some(ShopClass::Radioactive),
            other => return Err(format!("unknown shop class {other}")),
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            ShopClass::HeavyMetal => "Heavy metal",
            ShopClass::RareEarth => "Rare earth",
            ShopClass::Radioactive => "Radioactive element",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Solid,
    Liquid,
    Gas,
}

impl Substance {
    /// Boiling point adjusted for surface pressure (bar). Simplified: real
    /// curves follow Clausius–Clapeyron; this keeps the shape (lower pressure,
    /// lower boiling point) with integer maths.
    pub fn boil_at(&self, pressure: Fx) -> Fx {
        let p = pressure.min(Fx::from_int(4));
        self.boil_k * (Fx::ratio(85, 100) + Fx::ratio(15, 100) * p)
    }

    pub fn phase(&self, temp: Fx, pressure: Fx) -> Phase {
        if temp < self.melt_k {
            return Phase::Solid;
        }
        // Below the triple-point pressure (~0.006 bar for water) a liquid
        // cannot exist: it boils away as soon as it melts.
        if pressure < Fx::ratio(6, 1000) {
            return Phase::Gas;
        }
        if temp < self.boil_at(pressure).max(self.melt_k) {
            Phase::Liquid
        } else {
            Phase::Gas
        }
    }

    pub fn backbone_stable_at(&self, temp: Fx) -> bool {
        self.backbone > Fx::ZERO && temp >= self.backbone_min_k && temp <= self.backbone_max_k
    }
}

pub fn load_substances(json: &str) -> Result<Vec<Substance>, String> {
    let table: RawTable = serde_json::from_str(json).map_err(|e| e.to_string())?;
    table
        .substances
        .into_iter()
        .map(|r| {
            let color = u32::from_str_radix(&r.color, 16)
                .map_err(|e| format!("substance {}: bad color: {e}", r.key))?;
            let shop = ShopClass::parse(&r.shop).map_err(|e| format!("substance {}: {e}", r.key))?;
            Ok(Substance {
                key: r.key,
                name: r.name,
                formula: r.formula,
                molar_mass: Fx::from_int(r.molar_mass),
                melt_k: Fx::from_int(r.melt_k),
                boil_k: Fx::from_int(r.boil_k),
                solvent: Fx::ratio(r.solvent, 100),
                backbone: Fx::ratio(r.backbone, 100),
                backbone_element: r.backbone_element,
                backbone_min_k: Fx::from_int(r.backbone_min_k),
                backbone_max_k: Fx::from_int(r.backbone_max_k),
                fuel: Fx::ratio(r.fuel, 100),
                oxidizer: Fx::ratio(r.oxidizer, 100),
                greenhouse: Fx::ratio(r.greenhouse, 100),
                color: [(color >> 16) as u8, (color >> 8) as u8, color as u8],
                shop,
            })
        })
        .collect()
}

pub fn default_substances() -> Vec<Substance> {
    load_substances(DEFAULT_SUBSTANCES_JSON).expect("built-in substance table is valid")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn water_phases_at_one_bar() {
        let subs = default_substances();
        let water = subs.iter().find(|s| s.key == "water").unwrap();
        let one_bar = Fx::ONE;
        assert_eq!(water.phase(Fx::from_int(250), one_bar), Phase::Solid);
        assert_eq!(water.phase(Fx::from_int(300), one_bar), Phase::Liquid);
        assert_eq!(water.phase(Fx::from_int(400), one_bar), Phase::Gas);
        // No liquid water in near-vacuum.
        assert_eq!(
            water.phase(Fx::from_int(300), Fx::ratio(1, 1000)),
            Phase::Gas
        );
    }
}
