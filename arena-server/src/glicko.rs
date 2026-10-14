//! Glicko-2 ratings (Glickman, "Example of the Glicko-2 system"). Each match
//! is treated as its own rating period.
//!
//! Ratings are server-side bookkeeping, not simulation, so floating point is
//! fine here.

use serde::{Deserialize, Serialize};

const SCALE: f64 = 173.7178;
/// System constant: how much volatility may change per period.
const TAU: f64 = 0.5;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rating {
    pub rating: f64,
    pub deviation: f64,
    pub volatility: f64,
}

impl Default for Rating {
    fn default() -> Rating {
        Rating {
            rating: 1500.0,
            deviation: 350.0,
            volatility: 0.06,
        }
    }
}

fn g(phi: f64) -> f64 {
    1.0 / (1.0 + 3.0 * phi * phi / (std::f64::consts::PI * std::f64::consts::PI)).sqrt()
}

impl Rating {
    /// New rating after one game against `opponent`; `score` is 1 for a
    /// win, 0.5 for a draw, 0 for a loss.
    pub fn update(self, opponent: Rating, score: f64) -> Rating {
        let mu = (self.rating - 1500.0) / SCALE;
        let phi = self.deviation / SCALE;
        let mu_j = (opponent.rating - 1500.0) / SCALE;
        let phi_j = opponent.deviation / SCALE;
        let g_j = g(phi_j);
        let e = 1.0 / (1.0 + (-g_j * (mu - mu_j)).exp());
        let v = 1.0 / (g_j * g_j * e * (1.0 - e));
        let delta = v * g_j * (score - e);

        // New volatility by the Illinois algorithm.
        let a = (self.volatility * self.volatility).ln();
        let f = |x: f64| {
            let ex = x.exp();
            let d = phi * phi + v + ex;
            ex * (delta * delta - phi * phi - v - ex) / (2.0 * d * d) - (x - a) / (TAU * TAU)
        };
        let mut lo = a;
        let mut hi = if delta * delta > phi * phi + v {
            (delta * delta - phi * phi - v).ln()
        } else {
            let mut k = 1.0;
            while f(a - k * TAU) < 0.0 {
                k += 1.0;
            }
            a - k * TAU
        };
        let (mut f_lo, mut f_hi) = (f(lo), f(hi));
        for _ in 0..100 {
            if (hi - lo).abs() <= 1e-6 {
                break;
            }
            let c = lo + (lo - hi) * f_lo / (f_hi - f_lo);
            let f_c = f(c);
            if f_c * f_hi <= 0.0 {
                lo = hi;
                f_lo = f_hi;
            } else {
                f_lo /= 2.0;
            }
            hi = c;
            f_hi = f_c;
        }
        let sigma = (lo / 2.0).exp();

        let phi_star = (phi * phi + sigma * sigma).sqrt();
        let phi_new = 1.0 / (1.0 / (phi_star * phi_star) + 1.0 / v).sqrt();
        let mu_new = mu + phi_new * phi_new * g_j * (score - e);
        Rating {
            rating: 1500.0 + SCALE * mu_new,
            deviation: (SCALE * phi_new).min(350.0),
            volatility: sigma,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn winner_gains_and_loser_drops() {
        let a = Rating::default();
        let b = Rating::default();
        let a2 = a.update(b, 1.0);
        let b2 = b.update(a, 0.0);
        assert!(a2.rating > 1500.0 && b2.rating < 1500.0);
        assert!((a2.rating - 1500.0 - (1500.0 - b2.rating)).abs() < 1e-6);
        assert!(a2.deviation < 350.0);
    }

    #[test]
    fn glickman_example() {
        // Player 1500/200 beats a 1400/30 player: rating rises modestly.
        let p = Rating {
            rating: 1500.0,
            deviation: 200.0,
            volatility: 0.06,
        };
        let o = Rating {
            rating: 1400.0,
            deviation: 30.0,
            volatility: 0.06,
        };
        let r = p.update(o, 1.0);
        assert!(r.rating > 1550.0 && r.rating < 1580.0, "{r:?}");
        assert!(r.deviation < 200.0);
    }
}
