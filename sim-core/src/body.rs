//! Bodies: a genome of body parts, unlocked by evolutionary milestones
//! (docs/GAME_DESIGN.md §4.4).
//!
//! A species' traits (armour, speed, intelligence, offence) are derived from
//! its parts, never set directly. Later phases derive the character sheet and
//! arena abilities from the same parts: wings give a fly speed, a gland's
//! substance decides its breath weapon.

use crate::fixed::Fx;
use crate::hash::StateHasher;
use crate::rng::Rng;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum PartKind {
    Segment,
    Shell,
    Fin,
    Leaf,
    Eye,
    Jaw,
    Brain,
    Tentacle,
    Limb,
    Claw,
    Wing,
    Gland,
    // Parts of beings from beyond the Veil (§4.4a). Never evolved.
    Tendril,
    PhaseMembrane,
    Void,
}

impl PartKind {
    pub const ALL: [PartKind; 15] = [
        PartKind::Segment,
        PartKind::Shell,
        PartKind::Fin,
        PartKind::Leaf,
        PartKind::Eye,
        PartKind::Jaw,
        PartKind::Brain,
        PartKind::Tentacle,
        PartKind::Limb,
        PartKind::Claw,
        PartKind::Wing,
        PartKind::Gland,
        PartKind::Tendril,
        PartKind::PhaseMembrane,
        PartKind::Void,
    ];

    pub fn name(self) -> &'static str {
        match self {
            PartKind::Segment => "body segment",
            PartKind::Shell => "shell",
            PartKind::Fin => "fin",
            PartKind::Leaf => "light-catching frond",
            PartKind::Eye => "eye",
            PartKind::Jaw => "jaw",
            PartKind::Brain => "brain",
            PartKind::Tentacle => "tentacle",
            PartKind::Limb => "limb",
            PartKind::Claw => "claw",
            PartKind::Wing => "wing",
            PartKind::Gland => "gland",
            PartKind::Tendril => "tendril",
            PartKind::PhaseMembrane => "phase membrane",
            PartKind::Void => "void",
        }
    }

    /// Milestones a lineage needs before it can grow this part.
    pub fn requires(self) -> u16 {
        match self {
            PartKind::Segment | PartKind::Shell | PartKind::Fin | PartKind::Leaf => MULTICELLULAR,
            PartKind::Eye | PartKind::Jaw | PartKind::Brain | PartKind::Tentacle => NERVOUS,
            PartKind::Limb | PartKind::Claw => LIMBS,
            PartKind::Wing => FLIGHT,
            PartKind::Gland => GLANDS,
            PartKind::Tendril | PartKind::PhaseMembrane | PartKind::Void => OTHERWORLDLY,
        }
    }

    fn max_count(self) -> u8 {
        match self {
            PartKind::Segment => 12,
            PartKind::Limb | PartKind::Tentacle | PartKind::Tendril => 10,
            PartKind::Eye => 8,
            PartKind::Wing | PartKind::Fin | PartKind::Claw => 6,
            PartKind::Leaf => 8,
            _ => 3,
        }
    }
}

// Evolutionary milestones, as bit flags.
pub const MULTICELLULAR: u16 = 1 << 0;
pub const NERVOUS: u16 = 1 << 1;
pub const SKELETON: u16 = 1 << 2;
pub const LIMBS: u16 = 1 << 3;
pub const FLIGHT: u16 = 1 << 4;
pub const GLANDS: u16 = 1 << 5;
pub const SAPIENCE: u16 = 1 << 6;
/// Came through the Veil (§4.4a). Not an evolutionary milestone: no native
/// lineage can reach it.
pub const OTHERWORLDLY: u16 = 1 << 7;

pub struct Milestone {
    pub flag: u16,
    pub name: &'static str,
    pub requires: u16,
}

pub const MILESTONES: [Milestone; 7] = [
    Milestone {
        flag: MULTICELLULAR,
        name: "Multicellularity",
        requires: 0,
    },
    Milestone {
        flag: NERVOUS,
        name: "Nervous system",
        requires: MULTICELLULAR,
    },
    Milestone {
        flag: SKELETON,
        name: "Skeleton",
        requires: MULTICELLULAR,
    },
    Milestone {
        flag: GLANDS,
        name: "Chemical glands",
        requires: MULTICELLULAR,
    },
    Milestone {
        flag: LIMBS,
        name: "Limbs",
        requires: SKELETON | NERVOUS,
    },
    Milestone {
        flag: FLIGHT,
        name: "Flight",
        requires: LIMBS,
    },
    Milestone {
        flag: SAPIENCE,
        name: "Sapience",
        requires: NERVOUS,
    },
];

pub fn milestone_names(flags: u16) -> Vec<&'static str> {
    MILESTONES
        .iter()
        .filter(|m| flags & m.flag != 0)
        .map(|m| m.name)
        .collect()
}

/// Largest body size a lineage can reach with its milestones.
pub fn size_cap(flags: u16) -> Fx {
    if flags & OTHERWORLDLY != 0 {
        // Not bound by the square-cube law.
        Fx::from_int(1000)
    } else if flags & MULTICELLULAR == 0 {
        Fx::ratio(5, 100)
    } else if flags & SKELETON == 0 {
        Fx::from_int(3)
    } else {
        Fx::from_int(500)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Part {
    pub kind: PartKind,
    pub count: u8,
    /// Relative size of each copy, 0.2..3.
    pub size: Fx,
    /// For glands: index of the substance the gland makes or channels.
    pub substance: Option<u16>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Body {
    /// At most one entry per part kind, kept sorted by kind.
    pub parts: Vec<Part>,
}

/// Values derived from a body, each 0..1 unless stated.
#[derive(Clone, Copy, Debug, Default)]
pub struct BodyTraits {
    pub armor: Fx,
    pub speed: Fx,
    pub intelligence: Fx,
    /// Ability to catch and kill prey.
    pub offense: Fx,
    /// Extra energy from light-catching fronds (multiplier bonus, 0..1).
    pub photosynthesis: Fx,
    pub perception: Fx,
    /// Total part mass; complex bodies breed more slowly.
    pub complexity: Fx,
}

fn sat(x: Fx, half: Fx) -> Fx {
    if x <= Fx::ZERO {
        Fx::ZERO
    } else {
        x / (x + half)
    }
}

impl Body {
    pub fn part(&self, kind: PartKind) -> Option<&Part> {
        self.parts.iter().find(|p| p.kind == kind)
    }

    fn mass(&self, kind: PartKind) -> Fx {
        self.part(kind)
            .map_or(Fx::ZERO, |p| Fx::from_int(p.count as i64) * p.size)
    }

    pub fn count(&self, kind: PartKind) -> u8 {
        self.part(kind).map_or(0, |p| p.count)
    }

    /// Adds `count` copies of a part, or more copies of an existing one.
    pub fn grow(&mut self, kind: PartKind, count: u8, size: Fx, substance: Option<u16>) {
        match self.parts.iter_mut().find(|p| p.kind == kind) {
            Some(p) => p.count = (p.count + count).min(kind.max_count()),
            None => {
                self.parts.push(Part {
                    kind,
                    count: count.min(kind.max_count()),
                    size,
                    substance,
                });
                self.parts.sort_by_key(|p| p.kind);
            }
        }
    }

    /// Makes an existing part bigger (up to the size limit).
    pub fn enlarge(&mut self, kind: PartKind, factor: Fx) {
        if let Some(p) = self.parts.iter_mut().find(|p| p.kind == kind) {
            p.size = (p.size * factor).min(Fx::from_int(3));
        }
    }

    pub fn traits(&self, body_size: Fx) -> BodyTraits {
        let shell = self.mass(PartKind::Shell) + self.mass(PartKind::PhaseMembrane);
        let locomotion = self.mass(PartKind::Fin) * Fx::ratio(3, 10)
            + self.mass(PartKind::Limb) * Fx::ratio(4, 10)
            + self.mass(PartKind::Wing) * Fx::ratio(6, 10)
            + self.mass(PartKind::Tentacle) * Fx::ratio(1, 10)
            + self.mass(PartKind::Tendril) * Fx::ratio(1, 10)
            + self.mass(PartKind::PhaseMembrane) * Fx::ratio(3, 10);
        let brain =
            self.mass(PartKind::Brain) * (Fx::ONE + self.mass(PartKind::Eye) * Fx::ratio(1, 10));
        let weapons = self.mass(PartKind::Jaw)
            + self.mass(PartKind::Claw) * Fx::ratio(8, 10)
            + self.mass(PartKind::Gland) * Fx::ratio(6, 10)
            + self.mass(PartKind::Tentacle) * Fx::ratio(3, 10)
            + self.mass(PartKind::Tendril) * Fx::ratio(3, 10)
            + self.mass(PartKind::Void) * Fx::ratio(8, 10);
        let complexity = self
            .parts
            .iter()
            .fold(Fx::ZERO, |a, p| a + Fx::from_int(p.count as i64) * p.size);
        let speed = sat(locomotion + Fx::ratio(5, 100), Fx::ONE)
            / (Fx::ONE + body_size * Fx::ratio(2, 100));
        BodyTraits {
            armor: sat(shell * Fx::HALF, Fx::ONE),
            speed,
            intelligence: sat(brain, Fx::from_int(2)),
            offense: sat(weapons, Fx::ratio(15, 10)),
            photosynthesis: sat(self.mass(PartKind::Leaf), Fx::from_int(2)),
            perception: sat(self.mass(PartKind::Eye), Fx::from_int(2)),
            complexity,
        }
    }

    /// Random change to the body: copy, lose, resize, or add a part the
    /// lineage's milestones allow.
    pub fn mutate(&mut self, rng: &mut Rng, milestones: u16, gland_substance: Option<u16>) {
        let allowed: Vec<PartKind> = PartKind::ALL
            .iter()
            .copied()
            .filter(|k| milestones & k.requires() == k.requires())
            .collect();
        if allowed.is_empty() {
            return;
        }
        match rng.below(4) {
            0 if !self.parts.is_empty() => {
                let i = rng.below(self.parts.len() as u64) as usize;
                let p = &mut self.parts[i];
                p.count = (p.count + 1).min(p.kind.max_count());
            }
            1 if !self.parts.is_empty() => {
                let i = rng.below(self.parts.len() as u64) as usize;
                if self.parts[i].count > 1 {
                    self.parts[i].count -= 1;
                } else {
                    self.parts.remove(i);
                }
            }
            2 if !self.parts.is_empty() => {
                let i = rng.below(self.parts.len() as u64) as usize;
                let p = &mut self.parts[i];
                p.size = (p.size * rng.range(Fx::ratio(7, 10), Fx::ratio(14, 10)))
                    .clamp(Fx::ratio(2, 10), Fx::from_int(3));
            }
            _ => {
                let kind = allowed[rng.below(allowed.len() as u64) as usize];
                let substance = if kind == PartKind::Gland {
                    gland_substance
                } else {
                    None
                };
                if kind != PartKind::Gland || substance.is_some() {
                    let count = if matches!(
                        kind,
                        PartKind::Limb | PartKind::Wing | PartKind::Eye | PartKind::Fin
                    ) {
                        2
                    } else {
                        1
                    };
                    self.grow(kind, count, Fx::ONE, substance);
                }
            }
        }
    }

    /// Short summary, e.g. "4 limbs, 2 eyes, jaw, 2 wings".
    pub fn describe(&self, substance_names: &[String]) -> String {
        if self.parts.is_empty() {
            return "single cell".into();
        }
        self.parts
            .iter()
            .map(|p| {
                let mut name = p.kind.name().to_string();
                if let (PartKind::Gland, Some(s)) = (p.kind, p.substance) {
                    if let Some(n) = substance_names.get(s as usize) {
                        name = format!("{} gland", n.to_lowercase());
                    }
                }
                if p.count > 1 {
                    format!("{} {}s", p.count, name)
                } else {
                    name
                }
            })
            .collect::<Vec<_>>()
            .join(", ")
    }

    pub(crate) fn hash_into(&self, h: &mut StateHasher) {
        h.u64(self.parts.len() as u64);
        for p in &self.parts {
            h.u64(p.kind as u64);
            h.u64(p.count as u64);
            h.i64(p.size.0);
            h.u64(p.substance.map_or(u64::MAX, |s| s as u64));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parts_respect_milestones() {
        let mut rng = Rng::new(4);
        let mut body = Body::default();
        for _ in 0..500 {
            body.mutate(&mut rng, MULTICELLULAR, None);
        }
        for p in &body.parts {
            assert_eq!(
                p.kind.requires() & !MULTICELLULAR,
                0,
                "{:?} needs more milestones",
                p.kind
            );
        }
    }

    #[test]
    fn wings_make_bodies_faster() {
        let mut walker = Body::default();
        walker.grow(PartKind::Limb, 4, Fx::ONE, None);
        let mut flyer = walker.clone();
        flyer.grow(PartKind::Wing, 2, Fx::ONE, None);
        assert!(flyer.traits(Fx::ONE).speed > walker.traits(Fx::ONE).speed);
    }
}
