//! Fixed-point arithmetic.
//!
//! The simulation never touches floating point. Floats can round differently
//! across CPUs, compilers and optimisation levels, which would break replay
//! verification (see docs/GAME_DESIGN.md §6.2). `Fx` stores a number as a
//! 64-bit integer with 16 fractional bits, so every operation is exact integer
//! maths and gives identical results on every platform.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::ops::{Add, AddAssign, Div, Mul, Neg, Sub, SubAssign};

const FRAC_BITS: u32 = 16;
const ONE_RAW: i64 = 1 << FRAC_BITS;

#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Fx(pub i64);

impl Fx {
    pub const ZERO: Fx = Fx(0);
    pub const ONE: Fx = Fx(ONE_RAW);
    pub const HALF: Fx = Fx(ONE_RAW / 2);
    pub const MAX: Fx = Fx(i64::MAX);

    pub const fn from_int(v: i64) -> Fx {
        Fx(v << FRAC_BITS)
    }

    /// `num / den` as a fixed-point value.
    pub const fn ratio(num: i64, den: i64) -> Fx {
        Fx(((num as i128) << FRAC_BITS).wrapping_div(den as i128) as i64)
    }

    /// Converts an input value from the UI. Only for the edge of the
    /// simulation: the result is logged as raw bits, so replays never repeat
    /// the conversion.
    pub fn from_f64(v: f64) -> Fx {
        Fx((v * ONE_RAW as f64).round() as i64)
    }

    /// For display only. Never feed the result back into the simulation.
    pub fn to_f64(self) -> f64 {
        self.0 as f64 / ONE_RAW as f64
    }

    pub fn to_int(self) -> i64 {
        self.0 >> FRAC_BITS
    }

    pub fn abs(self) -> Fx {
        Fx(self.0.saturating_abs())
    }

    pub fn min(self, o: Fx) -> Fx {
        if self < o {
            self
        } else {
            o
        }
    }

    pub fn max(self, o: Fx) -> Fx {
        if self > o {
            self
        } else {
            o
        }
    }

    pub fn clamp(self, lo: Fx, hi: Fx) -> Fx {
        self.max(lo).min(hi)
    }

    pub fn sqrt(self) -> Fx {
        if self.0 <= 0 {
            return Fx::ZERO;
        }
        Fx(isqrt((self.0 as u128) << FRAC_BITS) as i64)
    }

    /// Base-2 logarithm, piecewise linear between powers of two (error
    /// below 0.09). Exact integer maths. Non-positive input gives a large
    /// negative value.
    pub fn log2(self) -> Fx {
        if self.0 <= 0 {
            return Fx::from_int(-64);
        }
        let bits = 63 - self.0.leading_zeros() as i64; // position of top bit
        let whole = bits - FRAC_BITS as i64;
        let base = 1i64 << bits;
        let frac = Fx::ratio(self.0 - base, base);
        Fx::from_int(whole) + frac
    }

    /// 2 to the power `self`, piecewise linear between integers (error below
    /// 6%). Exact integer maths.
    pub fn exp2(self) -> Fx {
        let whole = self.0 >> FRAC_BITS;
        let frac = Fx(self.0 & (ONE_RAW - 1));
        let mantissa = Fx::ONE + frac;
        if whole >= 0 {
            Fx(mantissa
                .0
                .checked_shl(whole.min(46) as u32)
                .unwrap_or(i64::MAX))
        } else {
            Fx(mantissa.0 >> (-whole).min(63))
        }
    }

    /// Rounds to the nearest integer.
    pub fn round(self) -> i64 {
        (self.0 + ONE_RAW / 2) >> FRAC_BITS
    }

    pub fn square(self) -> Fx {
        self * self
    }
}

fn isqrt(n: u128) -> u128 {
    if n < 2 {
        return n;
    }
    let mut x = 1u128 << ((128 - n.leading_zeros()).div_ceil(2));
    loop {
        let y = (x + n / x) >> 1;
        if y >= x {
            return x;
        }
        x = y;
    }
}

fn saturate(v: i128) -> i64 {
    v.clamp(i64::MIN as i128, i64::MAX as i128) as i64
}

impl Add for Fx {
    type Output = Fx;
    fn add(self, o: Fx) -> Fx {
        Fx(self.0.saturating_add(o.0))
    }
}

impl Sub for Fx {
    type Output = Fx;
    fn sub(self, o: Fx) -> Fx {
        Fx(self.0.saturating_sub(o.0))
    }
}

impl Mul for Fx {
    type Output = Fx;
    fn mul(self, o: Fx) -> Fx {
        Fx(saturate((self.0 as i128 * o.0 as i128) >> FRAC_BITS))
    }
}

impl Div for Fx {
    type Output = Fx;
    fn div(self, o: Fx) -> Fx {
        if o.0 == 0 {
            return if self.0 >= 0 { Fx::MAX } else { Fx(i64::MIN) };
        }
        Fx(saturate(((self.0 as i128) << FRAC_BITS) / o.0 as i128))
    }
}

impl Neg for Fx {
    type Output = Fx;
    fn neg(self) -> Fx {
        Fx(self.0.saturating_neg())
    }
}

impl AddAssign for Fx {
    fn add_assign(&mut self, o: Fx) {
        *self = *self + o;
    }
}

impl SubAssign for Fx {
    fn sub_assign(&mut self, o: Fx) {
        *self = *self - o;
    }
}

impl fmt::Debug for Fx {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:.4}", self.to_f64())
    }
}

impl fmt::Display for Fx {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:.2}", self.to_f64())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arithmetic() {
        let a = Fx::from_int(3);
        let b = Fx::ratio(1, 2);
        assert_eq!(a * b, Fx::ratio(3, 2));
        assert_eq!(a / b, Fx::from_int(6));
        assert_eq!(a + b - b, a);
        assert_eq!(Fx::from_int(9).sqrt(), Fx::from_int(3));
        assert_eq!(Fx::from_int(2).sqrt().0, 92681); // floor(sqrt(2) * 65536)
    }

    #[test]
    fn log_and_exp() {
        assert_eq!(Fx::from_int(8).log2(), Fx::from_int(3));
        assert_eq!(Fx::ratio(1, 4).log2(), Fx::from_int(-2));
        assert_eq!(Fx::from_int(3).exp2(), Fx::from_int(8));
        assert_eq!(Fx::from_int(-1).exp2(), Fx::HALF);
        assert_eq!(Fx::ratio(5, 2).round(), 3);
    }

    #[test]
    fn division_by_zero_saturates() {
        assert_eq!(Fx::ONE / Fx::ZERO, Fx::MAX);
    }
}
