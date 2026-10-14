//! Textures for the stylised 3D globe.
//!
//! Turns the coarse region grid into smooth, high-resolution maps: colour,
//! height, ice, glow and atmosphere settings. Display only: this never feeds
//! back into the simulation, so it may use floating point.

use crate::substance::Phase;
use crate::world::{World, HEIGHT, REGION_COUNT, WIDTH};

/// Per-pixel maps for the globe shader, all RGBA8, equirectangular.
pub struct GlobeMaps {
    pub width: usize,
    pub height: usize,
    /// RGB: surface colour. A: liquid mask (for shiny seas).
    pub albedo: Vec<u8>,
    /// R: surface height. G: ice. B: glow (lava). A: liquid depth.
    pub data: Vec<u8>,
}

/// Look of the atmosphere and clouds.
#[derive(Clone, Copy, Debug)]
pub struct AtmosphereLook {
    pub color: [f32; 3],
    /// 0 (none) .. 1 (very thick).
    pub thickness: f32,
    /// 0 (clear) .. 1 (overcast).
    pub clouds: f32,
    pub cloud_color: [f32; 3],
    /// Starlight strength relative to Earth, for the sun lamp.
    pub sunlight: f32,
}

/// Per-region values, sampled smoothly between region centres.
#[derive(Clone, Copy, Default)]
struct Cell {
    elevation: f64,
    surface: f64,
    ice: f64,
    temperature: f64,
    life: f64,
    life_color: [f64; 3],
    liquid_color: [f64; 3],
    glow: f64,
}

fn hash(x: i64, y: i64, seed: u64) -> f64 {
    let mut h = (x as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ (y as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F)
        ^ seed.wrapping_mul(0x1656_67B1_9E37_79F9);
    h ^= h >> 33;
    h = h.wrapping_mul(0xFF51_AFD7_ED55_8CCD);
    h ^= h >> 33;
    (h >> 11) as f64 / (1u64 << 53) as f64
}

/// Smooth value noise in 0..1, wrapping horizontally every `period` cells.
fn value_noise(x: f64, y: f64, period: i64, seed: u64) -> f64 {
    let (x0, y0) = (x.floor(), y.floor());
    let (tx, ty) = (x - x0, y - y0);
    let s = |t: f64| t * t * (3.0 - 2.0 * t);
    let at = |ix: i64, iy: i64| hash(ix.rem_euclid(period), iy, seed);
    let (ix, iy) = (x0 as i64, y0 as i64);
    let top = at(ix, iy) + (at(ix + 1, iy) - at(ix, iy)) * s(tx);
    let bottom = at(ix, iy + 1) + (at(ix + 1, iy + 1) - at(ix, iy + 1)) * s(tx);
    top + (bottom - top) * s(ty)
}

/// Fractal noise in roughly -0.5..0.5, seamless east-west.
fn fbm(u: f64, v: f64, seed: u64) -> f64 {
    let mut sum = 0.0;
    let mut amp = 0.5;
    let mut freq = 8.0;
    for o in 0..5 {
        sum += amp * (value_noise(u * freq, v * freq * 0.5, freq as i64, seed + o) - 0.5);
        amp *= 0.5;
        freq *= 2.0;
    }
    sum
}

fn mix3(a: [f64; 3], b: [f64; 3], t: f64) -> [f64; 3] {
    let t = t.clamp(0.0, 1.0);
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    ]
}

fn rgb(c: [u8; 3]) -> [f64; 3] {
    [
        c[0] as f64 / 255.0,
        c[1] as f64 / 255.0,
        c[2] as f64 / 255.0,
    ]
}

impl World {
    fn globe_cells(&self) -> Vec<Cell> {
        (0..REGION_COUNT)
            .map(|i| {
                let r = &self.regions[i];
                let mut liquid = 0.0;
                let mut liquid_color = [0.15, 0.35, 0.75];
                let mut ice = 0.0;
                let mut glow = 0.0;
                for (s, sub) in self.substances.iter().enumerate() {
                    let a = r.amounts[s].to_f64();
                    if a <= 0.0 {
                        continue;
                    }
                    match sub.phase(r.temperature, self.pressure) {
                        Phase::Liquid => {
                            liquid_color = mix3(liquid_color, rgb(sub.color), a / (liquid + a));
                            liquid += a;
                            // Molten rock and sulfur glow.
                            if r.temperature.to_f64() > 650.0 {
                                glow += a;
                            }
                        }
                        Phase::Solid if sub.melt_k.to_f64() < 400.0 => ice += a,
                        _ => {}
                    }
                }
                let (life, life_color) = match self.dominant_species(i) {
                    Some((id, total)) => (
                        total.to_f64(),
                        self.species_by_id(id)
                            .map_or([0.3, 0.6, 0.3], |s| rgb(s.color)),
                    ),
                    None => (0.0, [0.0; 3]),
                };
                Cell {
                    elevation: r.elevation.to_f64(),
                    surface: self.surface_level(i).to_f64(),
                    ice,
                    temperature: r.temperature.to_f64(),
                    life,
                    life_color,
                    liquid_color,
                    glow: (glow / 2.0).min(1.0),
                }
            })
            .collect()
    }

    /// Builds the globe maps at `w` × `h` pixels.
    pub fn globe_maps(&self, w: usize, h: usize) -> GlobeMaps {
        let cells = self.globe_cells();
        let mut albedo = Vec::with_capacity(w * h * 4);
        let mut data = Vec::with_capacity(w * h * 4);
        let seed = self.seed;
        for py in 0..h {
            for px in 0..w {
                let u = (px as f64 + 0.5) / w as f64;
                let v = (py as f64 + 0.5) / h as f64;
                // Bilinear sample between region centres.
                let gx = u * WIDTH as f64 - 0.5;
                let gy = (v * HEIGHT as f64 - 0.5).clamp(0.0, (HEIGHT - 1) as f64);
                let (x0, y0) = (gx.floor() as i64, gy.floor() as usize);
                let (tx, ty) = (gx - gx.floor(), gy - gy.floor());
                let y1 = (y0 + 1).min(HEIGHT - 1);
                let idx = |x: i64, y: usize| y * WIDTH + x.rem_euclid(WIDTH as i64) as usize;
                let c00 = cells[idx(x0, y0)];
                let c10 = cells[idx(x0 + 1, y0)];
                let c01 = cells[idx(x0, y1)];
                let c11 = cells[idx(x0 + 1, y1)];
                let lerp = |f: &dyn Fn(&Cell) -> f64| {
                    let top = f(&c00) + (f(&c10) - f(&c00)) * tx;
                    let bottom = f(&c01) + (f(&c11) - f(&c01)) * tx;
                    top + (bottom - top) * ty
                };
                let lerp3 = |f: &dyn Fn(&Cell) -> [f64; 3]| {
                    let top = mix3(f(&c00), f(&c10), tx);
                    let bottom = mix3(f(&c01), f(&c11), tx);
                    mix3(top, bottom, ty)
                };

                // Detail noise roughens coastlines and mountains.
                let detail = fbm(u, v, seed);
                let elevation = lerp(&|c| c.elevation) + detail * 0.18;
                let surface = lerp(&|c| c.surface);
                let depth = surface - elevation;
                let is_liquid = depth > 0.004;
                let temperature = lerp(&|c| c.temperature);
                let ice = (lerp(&|c| c.ice) + detail * 0.6).max(0.0);
                let life = lerp(&|c| c.life);
                let glow = lerp(&|c| c.glow);

                let mut color;
                let mut lava = 0.0;
                if is_liquid {
                    let base = lerp3(&|c| c.liquid_color);
                    let shallow = mix3(base, [0.3, 0.78, 0.85], 0.35);
                    let deep = mix3(base, [0.02, 0.06, 0.25], 0.6);
                    color = mix3(shallow, deep, (depth * 4.0).min(1.0));
                    if glow > 0.05 {
                        // Dark crust broken by bright cracks.
                        let cracks = 1.0 - (fbm(u * 3.0, v * 3.0, seed + 99) * 2.0).abs() * 4.0;
                        lava = (cracks.clamp(0.0, 1.0) * glow.min(1.0)).powf(1.5);
                        color = mix3([0.16, 0.07, 0.05], [1.0, 0.5, 0.1], lava);
                    }
                } else {
                    // Stylised land palette by height.
                    let e = elevation.clamp(0.0, 1.2);
                    color = if e < 0.35 {
                        mix3([0.86, 0.76, 0.5], [0.66, 0.52, 0.32], e / 0.35)
                    } else if e < 0.7 {
                        mix3([0.66, 0.52, 0.32], [0.52, 0.44, 0.4], (e - 0.35) / 0.35)
                    } else {
                        mix3([0.52, 0.44, 0.4], [0.8, 0.78, 0.8], (e - 0.7) / 0.5)
                    };
                    if temperature > 700.0 {
                        color = mix3(color, [0.18, 0.1, 0.08], 0.75);
                    }
                    if life > 0.5 {
                        let tint = mix3(lerp3(&|c| c.life_color), [0.3, 0.62, 0.25], 0.5);
                        color = mix3(color, tint, (life / 25.0).min(0.75));
                    }
                }
                let ice_amount = if ice > 0.25 {
                    ((ice - 0.25) * 2.0).min(1.0)
                } else {
                    0.0
                };
                color = mix3(color, [0.92, 0.96, 1.0], ice_amount * 0.9);

                albedo.extend_from_slice(&[
                    (color[0] * 255.0) as u8,
                    (color[1] * 255.0) as u8,
                    (color[2] * 255.0) as u8,
                    if is_liquid && ice_amount < 0.5 {
                        255
                    } else {
                        0
                    },
                ]);
                let height = if is_liquid { surface } else { elevation };
                data.extend_from_slice(&[
                    (height.clamp(0.0, 1.0) * 255.0) as u8,
                    (ice_amount * 255.0) as u8,
                    (lava.clamp(0.0, 1.0) * 255.0) as u8,
                    (depth.clamp(0.0, 1.0) * 255.0) as u8,
                ]);
            }
        }
        GlobeMaps {
            width: w,
            height: h,
            albedo,
            data,
        }
    }

    pub fn atmosphere_look(&self) -> AtmosphereLook {
        let mut color = [0.0f64; 3];
        let mut total = 0.0;
        let mut vapor = 0.0;
        let mut haze = 0.0;
        for (s, sub) in self.substances.iter().enumerate() {
            let a = self.atmosphere[s].to_f64();
            if a <= 0.0 {
                continue;
            }
            let tint = match sub.key.as_str() {
                "nitrogen" | "oxygen" => [0.35, 0.6, 1.0],
                "methane" => [0.95, 0.62, 0.3],
                "ammonia" => [0.85, 0.75, 0.55],
                "co2" => [0.95, 0.85, 0.62],
                "sulfur" => [1.0, 0.9, 0.35],
                "hydrogen" => [0.8, 0.85, 1.0],
                "water" => [0.85, 0.92, 1.0],
                _ => rgb(sub.color),
            };
            color = [
                color[0] + tint[0] * a,
                color[1] + tint[1] * a,
                color[2] + tint[2] * a,
            ];
            total += a;
            if matches!(sub.key.as_str(), "water" | "methane" | "ammonia") {
                vapor += a;
            }
            if sub.key == "sulfur" {
                haze += a;
            }
        }
        let color = if total > 0.0 {
            [color[0] / total, color[1] / total, color[2] / total]
        } else {
            [0.0; 3]
        };
        let p = self.pressure.to_f64();
        let has_liquid = self.regions.iter().any(|r| {
            self.substances.iter().enumerate().any(|(s, sub)| {
                r.amounts[s].to_f64() > 0.2
                    && sub.phase(r.temperature, self.pressure) == Phase::Liquid
            })
        });
        let clouds = if has_liquid && p > 0.05 {
            (0.2 + vapor * 4.0 + p * 0.03 + haze * 0.2).min(0.55)
        } else {
            0.0
        };
        let cloud_color = if vapor > 0.0 {
            mix3([1.0, 1.0, 1.0], color, 0.25)
        } else {
            [1.0, 1.0, 1.0]
        };
        AtmosphereLook {
            color: [color[0] as f32, color[1] as f32, color[2] as f32],
            thickness: (p / (p + 1.0)) as f32,
            clouds: clouds as f32,
            cloud_color: [
                cloud_color[0] as f32,
                cloud_color[1] as f32,
                cloud_color[2] as f32,
            ],
            sunlight: self.stellar_flux().to_f64() as f32,
        }
    }
}
