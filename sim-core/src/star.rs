//! Star types (docs/GAME_DESIGN.md §4.6).
//!
//! The star sets how much light the planet gets, how useful that light is
//! for life, and how much harmful radiation comes with it. In Natural mode a
//! main-sequence star's luminosity follows from its mass; giants and stellar
//! remnants have their own fixed brightness per unit mass.

use serde::{Deserialize, Serialize};
use crate::fixed::Fx;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum StarType {
    RedDwarf = 0,
    OrangeDwarf = 1,
    YellowDwarf = 2,
    WhiteStar = 3,
    BlueGiant = 4,
    RedGiant = 5,
    WhiteDwarf = 6,
    NeutronStar = 7,
}

pub struct StarInfo {
    pub kind: StarType,
    pub name: &'static str,
    pub description: &'static str,
    /// Typical mass and the allowed range, in solar masses.
    pub mass: Fx,
    pub min_mass: Fx,
    pub max_mass: Fx,
    /// Luminosity at the typical mass, in suns.
    pub luminosity: Fx,
    /// Main-sequence stars brighten steeply with mass (L ∝ M^3.5).
    pub main_sequence: bool,
    /// 0..1: how much of the light suits photosynthesis-like chemistry.
    pub light_quality: Fx,
    /// Harmful radiation output relative to the Sun's.
    pub radiation: Fx,
    /// Frequent flares that strip atmospheres (red dwarfs).
    pub flares: bool,
    /// Light colour for the globe, RGB 0..255.
    pub color: [u8; 3],
}

const fn ratio(n: i64, d: i64) -> Fx {
    Fx::ratio(n, d)
}

pub const STARS: [StarInfo; 8] = [
    StarInfo {
        kind: StarType::RedDwarf,
        name: "Red dwarf",
        description: "Small, dim and long-lived. Its reddish light is poor for photosynthesis, and frequent flares strip thin atmospheres.",
        mass: ratio(3, 10),
        min_mass: ratio(1, 10),
        max_mass: ratio(1, 2),
        luminosity: ratio(15, 1000),
        main_sequence: true,
        light_quality: ratio(5, 10),
        radiation: ratio(6, 10),
        flares: true,
        color: [255, 150, 100],
    },
    StarInfo {
        kind: StarType::OrangeDwarf,
        name: "Orange dwarf",
        description: "Steady and long-lived, slightly cooler than the Sun. Often considered the best home for life.",
        mass: ratio(7, 10),
        min_mass: ratio(1, 2),
        max_mass: ratio(8, 10),
        luminosity: ratio(25, 100),
        main_sequence: true,
        light_quality: ratio(85, 100),
        radiation: ratio(2, 10),
        flares: false,
        color: [255, 205, 150],
    },
    StarInfo {
        kind: StarType::YellowDwarf,
        name: "Yellow dwarf",
        description: "A Sun-like star.",
        mass: Fx::ONE,
        min_mass: ratio(8, 10),
        max_mass: ratio(12, 10),
        luminosity: Fx::ONE,
        main_sequence: true,
        light_quality: Fx::ONE,
        radiation: ratio(2, 10),
        flares: false,
        color: [255, 244, 225],
    },
    StarInfo {
        kind: StarType::WhiteStar,
        name: "White star",
        description: "Hotter and brighter than the Sun, with strong ultraviolet light.",
        mass: ratio(16, 10),
        min_mass: ratio(12, 10),
        max_mass: ratio(25, 10),
        luminosity: Fx::from_int(5),
        main_sequence: true,
        light_quality: Fx::ONE,
        radiation: ratio(6, 10),
        flares: false,
        color: [235, 240, 255],
    },
    StarInfo {
        kind: StarType::BlueGiant,
        name: "Blue giant",
        description: "Enormous, blinding and short-lived. Planets must orbit far away, and harsh radiation bathes them.",
        mass: Fx::from_int(10),
        min_mass: ratio(25, 10),
        max_mass: Fx::from_int(30),
        luminosity: Fx::from_int(3000),
        main_sequence: true,
        light_quality: ratio(9, 10),
        radiation: Fx::from_int(2),
        flares: false,
        color: [170, 195, 255],
    },
    StarInfo {
        kind: StarType::RedGiant,
        name: "Red giant",
        description: "A dying star swollen to huge size: very bright, but with red light.",
        mass: ratio(12, 10),
        min_mass: ratio(8, 10),
        max_mass: Fx::from_int(3),
        luminosity: Fx::from_int(300),
        main_sequence: false,
        light_quality: ratio(6, 10),
        radiation: ratio(3, 10),
        flares: false,
        color: [255, 140, 90],
    },
    StarInfo {
        kind: StarType::WhiteDwarf,
        name: "White dwarf",
        description: "The hot, faint core left after a star dies. Only very close planets stay warm.",
        mass: ratio(6, 10),
        min_mass: ratio(5, 10),
        max_mass: ratio(13, 10),
        luminosity: ratio(2, 1000),
        main_sequence: false,
        light_quality: ratio(7, 10),
        radiation: ratio(5, 10),
        flares: false,
        color: [220, 230, 255],
    },
    StarInfo {
        kind: StarType::NeutronStar,
        name: "Neutron star",
        description: "A collapsed stellar core barely bigger than a city. Almost no visible light, but a deadly beam of radiation. Its extreme physics strains reality.",
        mass: ratio(14, 10),
        min_mass: ratio(14, 10),
        max_mass: ratio(21, 10),
        luminosity: ratio(1, 10000),
        main_sequence: false,
        light_quality: ratio(1, 10),
        radiation: Fx::from_int(8),
        flares: false,
        color: [200, 210, 255],
    },
];

impl StarType {
    pub fn from_index(i: u8) -> StarType {
        STARS.get(i as usize).map_or(StarType::YellowDwarf, |s| s.kind)
    }

    pub fn info(self) -> &'static StarInfo {
        &STARS[self as usize]
    }

    /// Luminosity a star of this type and `mass` has naturally.
    pub fn natural_luminosity(self, mass: Fx) -> Fx {
        let info = self.info();
        let m = (mass / info.mass).clamp(Fx::ratio(1, 100), Fx::from_int(100));
        if info.main_sequence {
            // L ∝ M^3.5 = M³ · √M.
            info.luminosity * m * m * m * m.sqrt()
        } else {
            info.luminosity * m
        }
    }

    /// Mass (within this type's range) whose natural luminosity is closest
    /// to `luminosity`.
    pub fn mass_for_luminosity(self, luminosity: Fx) -> Fx {
        let info = self.info();
        // Bisection: natural luminosity rises with mass for every type.
        let (mut lo, mut hi) = (info.min_mass, info.max_mass);
        for _ in 0..40 {
            let mid = (lo + hi) * Fx::HALF;
            if self.natural_luminosity(mid) < luminosity {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        (lo + hi) * Fx::HALF
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sun_like_star_is_one_sun() {
        assert_eq!(StarType::YellowDwarf.natural_luminosity(Fx::ONE), Fx::ONE);
    }

    #[test]
    fn main_sequence_brightens_steeply_with_mass() {
        let l = StarType::YellowDwarf.natural_luminosity(Fx::ratio(12, 10));
        assert!(l > Fx::ratio(18, 10) && l < Fx::ratio(20, 10), "{l:?}");
    }

    #[test]
    fn mass_for_luminosity_inverts_within_range() {
        let m = StarType::YellowDwarf.mass_for_luminosity(Fx::ratio(15, 10));
        let l = StarType::YellowDwarf.natural_luminosity(m);
        assert!((l - Fx::ratio(15, 10)).abs() < Fx::ratio(2, 100));
        // Out of range clamps to the type's limits.
        let m = StarType::YellowDwarf.mass_for_luminosity(Fx::from_int(100));
        assert!(m <= StarType::YellowDwarf.info().max_mass);
    }
}
