//! Seeded pseudo-random number generator (SplitMix64).
//!
//! Small, fast, and fully specified, so the same seed gives the same sequence
//! on every platform and every Rust version.

use crate::fixed::Fx;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Rng {
    state: u64,
}

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng { state: seed }
    }

    pub fn state(&self) -> u64 {
        self.state
    }

    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform integer in `0..n`. `n` must be non-zero.
    pub fn below(&mut self, n: u64) -> u64 {
        self.next_u64() % n
    }

    /// Uniform value in `[0, 1)`.
    pub fn unit(&mut self) -> Fx {
        Fx((self.next_u64() >> 48) as i64)
    }

    /// Uniform value in `[lo, hi)`.
    pub fn range(&mut self, lo: Fx, hi: Fx) -> Fx {
        lo + (hi - lo) * self.unit()
    }

    /// Roughly bell-shaped value in `[-1, 1)`, mean 0.
    pub fn spread(&mut self) -> Fx {
        let s = self.unit() + self.unit() + self.unit();
        (s - Fx::ratio(3, 2)) * Fx::ratio(2, 3)
    }

    /// True with probability `p`.
    pub fn chance(&mut self, p: Fx) -> bool {
        self.unit() < p
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_seed_same_sequence() {
        let mut a = Rng::new(42);
        let mut b = Rng::new(42);
        for _ in 0..100 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn known_first_value() {
        // Locks the algorithm: changing it would silently break old saves.
        assert_eq!(Rng::new(0).next_u64(), 0xE220_A839_7B1D_CDAF);
    }
}
