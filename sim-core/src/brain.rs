//! Brains: tiny neural networks carried in every genome.
//!
//! Each brain is a fixed-size network (8 inputs, 6 hidden neurons, 4 outputs)
//! evaluated with fixed-point maths, so it is as deterministic as the rest of
//! the simulation and server replay still matches exactly.
//!
//! Brains are used at two levels (docs/GAME_DESIGN.md §4.8):
//! - **Species instincts:** a species' brain is tested in a few standard
//!   situations once, when the species appears. The answers become its
//!   temperament, which drives the population simulation.
//! - **Named individuals:** each carries a personal variant of its species'
//!   brain and runs it every season to decide what to do.

use crate::fixed::Fx;
use crate::hash::StateHasher;
use crate::rng::Rng;

pub const INPUTS: usize = 8;
pub const HIDDEN: usize = 6;
pub const OUTPUTS: usize = 4;
pub const WEIGHTS: usize = INPUTS * HIDDEN + HIDDEN + HIDDEN * OUTPUTS + OUTPUTS;

/// Sensor order.
pub mod input {
    pub const FOOD: usize = 0;
    pub const THREAT: usize = 1;
    pub const PREY: usize = 2;
    pub const STRANGER: usize = 3;
    pub const KIN: usize = 4;
    pub const HUNGER: usize = 5;
    pub const INJURY: usize = 6;
    pub const BIAS: usize = 7;
}

/// Action order.
pub mod output {
    pub const APPROACH: usize = 0;
    pub const FLEE: usize = 1;
    pub const ATTACK: usize = 2;
    pub const SOCIALIZE: usize = 3;
    pub const NAMES: [&str; 4] = ["approach", "flee", "attack", "socialize"];
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Brain {
    pub weights: [Fx; WEIGHTS],
}

impl Brain {
    /// Small random weights: a new lineage starts with weak, noisy instincts.
    pub fn random(rng: &mut Rng) -> Brain {
        let mut weights = [Fx::ZERO; WEIGHTS];
        for w in &mut weights {
            *w = rng.spread() * Fx::ratio(8, 10);
        }
        Brain { weights }
    }

    /// Copies the brain with mutations: each weight has a `rate` chance of
    /// shifting by up to ±`amount`.
    pub fn mutated(&self, rng: &mut Rng, rate: Fx, amount: Fx) -> Brain {
        let mut weights = self.weights;
        let limit = Fx::from_int(4);
        for w in &mut weights {
            if rng.chance(rate) {
                *w = (*w + rng.spread() * amount).clamp(-limit, limit);
            }
        }
        Brain { weights }
    }

    /// Runs the network. Activations use a hard tanh (clamp to -1..1), which
    /// needs no floating point.
    pub fn think(&self, inputs: &[Fx; INPUTS]) -> [Fx; OUTPUTS] {
        let w = &self.weights;
        let mut hidden = [Fx::ZERO; HIDDEN];
        let mut k = 0;
        for h in &mut hidden {
            let mut sum = Fx::ZERO;
            for x in inputs {
                sum += *x * w[k];
                k += 1;
            }
            sum += w[k];
            k += 1;
            *h = sum.clamp(-Fx::ONE, Fx::ONE);
        }
        let mut out = [Fx::ZERO; OUTPUTS];
        for o in &mut out {
            let mut sum = Fx::ZERO;
            for h in &hidden {
                sum += *h * w[k];
                k += 1;
            }
            sum += w[k];
            k += 1;
            *o = sum.clamp(-Fx::ONE, Fx::ONE);
        }
        out
    }

    /// Index of the strongest output, ties going to the lowest index.
    pub fn decide(&self, inputs: &[Fx; INPUTS]) -> usize {
        let out = self.think(inputs);
        let mut best = 0;
        for i in 1..OUTPUTS {
            if out[i] > out[best] {
                best = i;
            }
        }
        best
    }

    pub(crate) fn hash_into(&self, h: &mut StateHasher) {
        for w in &self.weights {
            h.i64(w.0);
        }
    }
}

/// Behavioural tendencies measured from a brain, each 0..1.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Temperament {
    pub aggression: Fx,
    pub fear: Fx,
    pub curiosity: Fx,
    pub sociability: Fx,
}

impl Temperament {
    /// Short description, e.g. "fierce, social".
    pub fn describe(&self) -> String {
        let hi = Fx::ratio(65, 100);
        let lo = Fx::ratio(35, 100);
        let mut words = Vec::new();
        if self.aggression > hi {
            words.push("fierce");
        } else if self.aggression < lo {
            words.push("gentle");
        }
        if self.fear > hi {
            words.push("skittish");
        } else if self.fear < lo {
            words.push("bold");
        }
        if self.curiosity > hi {
            words.push("curious");
        }
        if self.sociability > hi {
            words.push("social");
        } else if self.sociability < lo {
            words.push("solitary");
        }
        if words.is_empty() {
            "even-tempered".into()
        } else {
            words.join(", ")
        }
    }
}

fn scenario(values: &[(usize, Fx)]) -> [Fx; INPUTS] {
    let mut x = [Fx::ZERO; INPUTS];
    x[input::BIAS] = Fx::ONE;
    for &(i, v) in values {
        x[i] = v;
    }
    x
}

fn unit(v: Fx) -> Fx {
    (v + Fx::ONE) * Fx::HALF
}

/// Tests a brain in standard situations and turns its answers into a
/// temperament.
pub fn temperament(brain: &Brain) -> Temperament {
    use input::*;
    use output::*;
    let hungry_with_prey = brain.think(&scenario(&[
        (PREY, Fx::ONE),
        (HUNGER, Fx::ONE),
        (FOOD, Fx::ratio(2, 10)),
    ]));
    let threatened = brain.think(&scenario(&[(THREAT, Fx::ONE), (HUNGER, Fx::ratio(3, 10))]));
    let calm = brain.think(&scenario(&[(HUNGER, Fx::ratio(3, 10))]));
    let with_kin = brain.think(&scenario(&[
        (KIN, Fx::ONE),
        (FOOD, Fx::HALF),
        (HUNGER, Fx::ratio(2, 10)),
    ]));
    let with_stranger = brain.think(&scenario(&[
        (STRANGER, Fx::ONE),
        (FOOD, Fx::ratio(3, 10)),
        (HUNGER, Fx::ratio(3, 10)),
    ]));
    Temperament {
        aggression: unit((hungry_with_prey[ATTACK] + with_stranger[ATTACK]) * Fx::HALF),
        fear: unit(threatened[FLEE]),
        curiosity: unit(calm[APPROACH]),
        sociability: unit((with_kin[SOCIALIZE] + with_stranger[SOCIALIZE]) * Fx::HALF),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn temperament_is_in_range_and_deterministic() {
        let mut rng = Rng::new(9);
        for _ in 0..50 {
            let b = Brain::random(&mut rng);
            let t = temperament(&b);
            for v in [t.aggression, t.fear, t.curiosity, t.sociability] {
                assert!(v >= Fx::ZERO && v <= Fx::ONE);
            }
            assert_eq!(t, temperament(&b.clone()));
        }
    }

    #[test]
    fn hand_wired_brain_behaves_as_wired() {
        // Hidden neuron 0 copies the THREAT input; output FLEE reads it.
        let mut b = Brain {
            weights: [Fx::ZERO; WEIGHTS],
        };
        b.weights[input::THREAT] = Fx::ONE;
        let flee_from_h0 = INPUTS * HIDDEN + HIDDEN + output::FLEE * (HIDDEN + 1);
        b.weights[flee_from_h0] = Fx::ONE;
        let t = temperament(&b);
        assert_eq!(t.fear, Fx::ONE);
        assert_eq!(t.aggression, Fx::HALF);
    }
}
