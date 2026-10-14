//! Map overlays as RGBA pixels, one pixel per region.
//!
//! Rendering is display-only and never feeds back into the simulation, so it
//! may use floating point.

use crate::fixed::Fx;
use crate::substance::Phase;
use crate::world::{World, HEIGHT, REGION_COUNT, WIDTH};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Overlay {
    /// Terrain, liquids, ice, and a tint of the dominant species.
    Surface,
    Temperature,
    /// Dominant species colour, brightness by biomass.
    Life,
    /// How suitable each region is for any kind of life.
    Viability,
    /// Veil strength: dark where sealed, glowing violet where thin, with
    /// beings from beyond marked in their colour.
    Veil,
    /// Ambient mana (arcane law): dark to bright cyan-blue.
    Mana,
    /// Ambient qi (cultivation law): dark to jade green.
    Qi,
    /// Amount of one substance (surface plus atmosphere column).
    Substance(usize),
}

impl Overlay {
    /// Mode numbers used by the Godot viewer: 0..6, then 7 + substance index.
    pub fn from_mode(mode: i64) -> Overlay {
        match mode {
            0 => Overlay::Surface,
            1 => Overlay::Temperature,
            2 => Overlay::Life,
            3 => Overlay::Viability,
            4 => Overlay::Veil,
            5 => Overlay::Mana,
            6 => Overlay::Qi,
            m => Overlay::Substance((m - 7).max(0) as usize),
        }
    }
}

fn mix(a: [f64; 3], b: [f64; 3], t: f64) -> [f64; 3] {
    let t = t.clamp(0.0, 1.0);
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    ]
}

fn rgb(c: [u8; 3]) -> [f64; 3] {
    [c[0] as f64, c[1] as f64, c[2] as f64]
}

fn temperature_color(k: f64) -> [f64; 3] {
    const STOPS: [(f64, [f64; 3]); 8] = [
        (0.0, [20.0, 0.0, 40.0]),
        (100.0, [60.0, 30.0, 160.0]),
        (200.0, [40.0, 120.0, 230.0]),
        (273.0, [200.0, 240.0, 255.0]),
        (300.0, [90.0, 200.0, 90.0]),
        (400.0, [240.0, 200.0, 40.0]),
        (1000.0, [220.0, 50.0, 20.0]),
        (2000.0, [255.0, 250.0, 210.0]),
    ];
    for w in STOPS.windows(2) {
        let (k0, c0) = w[0];
        let (k1, c1) = w[1];
        if k <= k1 {
            return mix(c0, c1, (k - k0) / (k1 - k0));
        }
    }
    STOPS[STOPS.len() - 1].1
}

impl World {
    /// Dominant species in a region and the region's total biomass.
    pub fn dominant_species(&self, i: usize) -> Option<(u32, Fx)> {
        let pops = &self.regions[i].populations;
        let top = pops
            .iter()
            .max_by_key(|p| (p.biomass, std::cmp::Reverse(p.species)))?;
        let total = pops.iter().fold(Fx::ZERO, |a, p| a + p.biomass);
        Some((top.species, total))
    }

    pub fn overlay_rgba(&self, overlay: Overlay) -> Vec<u8> {
        let mut out = Vec::with_capacity(REGION_COUNT * 4);
        for i in 0..REGION_COUNT {
            let c = self.region_color(i, overlay);
            out.extend_from_slice(&[
                c[0].round() as u8,
                c[1].round() as u8,
                c[2].round() as u8,
                255,
            ]);
        }
        out
    }

    fn region_color(&self, i: usize, overlay: Overlay) -> [f64; 3] {
        let r = &self.regions[i];
        let elev = r.elevation.to_f64();
        let ground = mix([70.0, 55.0, 45.0], [170.0, 160.0, 150.0], elev);
        match overlay {
            Overlay::Surface => {
                let mut c = ground;
                let (mut liquid, mut liquid_color, mut ice) = (0.0, [0.0; 3], 0.0);
                for (s, sub) in self.substances.iter().enumerate() {
                    let a = r.amounts[s].to_f64();
                    if a <= 0.0 {
                        continue;
                    }
                    match sub.phase(r.temperature, self.pressure) {
                        Phase::Liquid => {
                            let col = rgb(sub.color);
                            liquid_color = mix(liquid_color, col, a / (liquid + a));
                            liquid += a;
                        }
                        Phase::Solid if sub.melt_k < Fx::from_int(400) => ice += a,
                        _ => {}
                    }
                }
                if ice > 0.1 {
                    c = mix(c, [235.0, 240.0, 250.0], (ice / 2.0).min(0.85));
                }
                if liquid > 0.05 {
                    let deep = mix(liquid_color, [0.0, 0.0, 0.0], (liquid / 12.0).min(0.6));
                    c = mix(c, deep, 0.35 + (liquid / 2.0).min(0.6));
                }
                if let Some((id, total)) = self.dominant_species(i) {
                    if let Some(s) = self.species_by_id(id) {
                        c = mix(c, rgb(s.color), (total.to_f64() / 80.0).min(0.3));
                    }
                }
                c
            }
            Overlay::Temperature => temperature_color(r.temperature.to_f64()),
            Overlay::Life => match self.dominant_species(i) {
                Some((id, total)) => {
                    let col = self.species_by_id(id).map_or([255.0; 3], |s| rgb(s.color));
                    mix(
                        [15.0, 15.0, 20.0],
                        col,
                        0.25 + (total.to_f64() / 40.0).min(0.75),
                    )
                }
                None => mix([15.0, 15.0, 20.0], ground, 0.25),
            },
            Overlay::Viability => {
                let v = self.life[i].viability().to_f64();
                if v <= 0.0 {
                    mix([25.0, 10.0, 10.0], ground, 0.2)
                } else {
                    mix([20.0, 40.0, 20.0], [120.0, 255.0, 120.0], v * 1.5)
                }
            }
            Overlay::Veil => {
                let open = 1.0 - self.veil(i).to_f64();
                let mut c = mix(mix([12.0, 12.0, 18.0], ground, 0.15), [190.0, 80.0, 255.0], open * 1.2);
                if open * 1.2 > 1.0 {
                    c = mix(c, [255.0, 230.0, 255.0], open * 1.2 - 1.0);
                }
                let horror = self
                    .regions[i]
                    .populations
                    .iter()
                    .filter(|p| self.is_otherworldly(p.species))
                    .max_by_key(|p| (p.biomass, std::cmp::Reverse(p.species)));
                if let Some(p) = horror {
                    if let Some(s) = self.species_by_id(p.species) {
                        c = mix(c, rgb(s.color), 0.4 + (p.biomass.to_f64() / 20.0).min(0.5));
                    }
                }
                c
            }
            Overlay::Mana => mix(
                mix([12.0, 12.0, 18.0], ground, 0.15),
                [60.0, 190.0, 255.0],
                self.mana(i).to_f64() * 1.2,
            ),
            Overlay::Qi => mix(
                mix([12.0, 12.0, 18.0], ground, 0.15),
                [60.0, 220.0, 150.0],
                self.qi(i).to_f64() * 1.2,
            ),
            Overlay::Substance(s) => {
                let Some(sub) = self.substances.get(s) else {
                    return ground;
                };
                let a = r.amounts[s].to_f64() + self.atmosphere[s].to_f64();
                mix([15.0, 15.0, 20.0], rgb(sub.color), a / (a + 1.0))
            }
        }
    }

    /// Plain-text map for terminals: one character per region.
    pub fn ascii_map(&self) -> String {
        let mut s = String::with_capacity((WIDTH + 1) * HEIGHT);
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                let i = y * WIDTH + x;
                let ch = match self.dominant_species(i) {
                    Some((id, _)) => (b'a' + (id % 26) as u8) as char,
                    None if self.life[i].viability() > Fx::ZERO => '.',
                    None => ' ',
                };
                s.push(ch);
            }
            s.push('\n');
        }
        s
    }
}
