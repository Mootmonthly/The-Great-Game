//! Terrain for the region visit (display only, never part of the
//! simulation). A square of land around a region, shaped by its simulated
//! elevation and its four neighbours': the land tilts towards lower
//! neighbours (where the sea gathers), ridged mountains rise where the
//! region and its neighbours stand high, hills roll in between, coasts are
//! warped into bays and headlands, and rivers run from the heights down to
//! the sea. Deterministic for a given region and seed.

pub struct Terrain {
    /// Heights in metres on a (grid + 1)² lattice covering
    /// [-extent, extent]², row-major by z then x.
    pub heights: Vec<f32>,
    pub sea_level: f32,
    /// Each river as points (x, z, water surface height, width).
    pub rivers: Vec<Vec<[f32; 4]>>,
}

fn hash(ix: i32, iz: i32, seed: u32) -> u32 {
    let mut h = (ix as u32).wrapping_mul(0x8da6_b343) ^ (iz as u32).wrapping_mul(0xd816_3841) ^ seed.wrapping_mul(0xcb1a_b31f);
    h ^= h >> 13;
    h = h.wrapping_mul(0x5bd1_e995);
    h ^ (h >> 15)
}

/// Gradient noise in about [-1, 1].
fn perlin(x: f32, z: f32, seed: u32) -> f32 {
    let (x0, z0) = (x.floor(), z.floor());
    let (fx, fz) = (x - x0, z - z0);
    let (ix, iz) = (x0 as i32, z0 as i32);
    let grad = |gx: i32, gz: i32, dx: f32, dz: f32| {
        let a = (hash(gx, gz, seed) & 0xffff) as f32 / 65536.0 * std::f32::consts::TAU;
        a.cos() * dx + a.sin() * dz
    };
    let fade = |t: f32| t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    let (u, v) = (fade(fx), fade(fz));
    let n00 = grad(ix, iz, fx, fz);
    let n10 = grad(ix + 1, iz, fx - 1.0, fz);
    let n01 = grad(ix, iz + 1, fx, fz - 1.0);
    let n11 = grad(ix + 1, iz + 1, fx - 1.0, fz - 1.0);
    let a = n00 + (n10 - n00) * u;
    let b = n01 + (n11 - n01) * u;
    (a + (b - a) * v) * 1.414
}

fn fbm(x: f32, z: f32, seed: u32, octaves: u32) -> f32 {
    let (mut sum, mut amp, mut f, mut norm) = (0.0, 1.0, 1.0, 0.0);
    for o in 0..octaves {
        sum += perlin(x * f, z * f, seed.wrapping_add(o * 7919)) * amp;
        norm += amp;
        amp *= 0.5;
        f *= 2.03;
    }
    sum / norm
}

/// Ridged noise in [0, 1]: sharp crests where the noise crosses zero, each
/// octave weighted by the last so ridges carry finer ridges.
fn ridged(x: f32, z: f32, seed: u32, octaves: u32) -> f32 {
    let (mut sum, mut amp, mut f, mut weight, mut norm) = (0.0, 1.0, 1.0, 1.0, 0.0);
    for o in 0..octaves {
        let n = 1.0 - perlin(x * f, z * f, seed.wrapping_add(o * 104_729)).abs();
        let n = n * n * weight;
        weight = (n * 1.6).clamp(0.0, 1.0);
        sum += n * amp;
        norm += amp;
        amp *= 0.5;
        f *= 2.1;
    }
    sum / norm
}

fn smoothstep(a: f32, b: f32, x: f32) -> f32 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// `elev` holds the region's elevation and its west, east, north and south
/// neighbours' (0..1, as the simulation keeps them); `wet_share` is how much
/// of the land the sea should cover.
pub fn generate(seed: u32, elev: [f32; 5], wet_share: f32, grid: usize, extent: f32) -> Terrain {
    let n = grid + 1;
    let step = 2.0 * extent / grid as f32;
    let [e0, ew, ee, en, es] = elev;
    let (gx, gz) = ((ee - ew) * 0.5, (es - en) * 0.5);
    let high = e0.max(ew.max(ee).max(en.max(es)) * 0.85);
    let mut heights = vec![0.0f32; n * n];
    for iz in 0..n {
        let z = iz as f32 * step - extent;
        for ix in 0..n {
            let x = ix as f32 * step - extent;
            // Warp the land so coasts and ranges wander.
            let wx = x + 320.0 * fbm(x / 1500.0, z / 1500.0, seed ^ 0x51, 3);
            let wz = z + 320.0 * fbm(x / 1500.0 + 9.1, z / 1500.0 - 3.7, seed ^ 0x93, 3);
            // The land tilts towards lower neighbours.
            let base = e0 + gx * (x / extent) + gz * (z / extent);
            let broad = fbm(wx / 2600.0, wz / 2600.0, seed ^ 0x17, 3);
            // Mountains where the land stands high.
            let m = smoothstep(0.32, 0.7, base * 0.7 + high * 0.3 + broad * 0.12);
            let range = ridged(wx / 1700.0, wz / 1700.0, seed ^ 0x2b, 5);
            let hills = fbm(wx / 700.0, wz / 700.0, seed ^ 0x3c, 4);
            let detail = fbm(x / 70.0, z / 70.0, seed ^ 0x4d, 2);
            heights[iz * n + ix] = (base - 0.3) * 180.0 + broad * 45.0 + hills * (14.0 + 30.0 * (1.0 - m)) + range * range * (40.0 + 620.0 * m) + detail * 1.4;
        }
    }
    // The sea covers the lowest `wet_share` of the inner land.
    let mut sample: Vec<f32> = (0..n * n)
        .step_by(7)
        .filter(|&i| {
            let (x, z) = ((i % n) as f32 * step - extent, (i / n) as f32 * step - extent);
            x.abs() < extent * 0.82 && z.abs() < extent * 0.82
        })
        .map(|i| heights[i])
        .collect();
    sample.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let sea_level = if wet_share > 0.02 {
        sample[((wet_share.min(0.9)) * (sample.len() - 1) as f32) as usize]
    } else {
        -1.0e4
    };
    let rivers = if sea_level > -1.0e3 { carve_rivers(&mut heights, n, step, extent, sea_level, seed) } else { Vec::new() };
    Terrain { heights, sea_level, rivers }
}

/// Rivers from springs high in the hills, each following the steepest way
/// down (cutting through small hollows) to the sea, cut into the land
/// with a bed that only ever falls.
fn carve_rivers(h: &mut [f32], n: usize, step: f32, extent: f32, sea: f32, seed: u32) -> Vec<Vec<[f32; 4]>> {
    let mut springs: Vec<(usize, usize)> = Vec::new();
    let mut k = 0u32;
    while springs.len() < 6 && k < 4000 {
        k += 1;
        let r = hash(k as i32, 77, seed);
        let ix = (r % (n as u32 - 40)) as usize + 20;
        let iz = ((r >> 12) % (n as u32 - 40)) as usize + 20;
        let y = h[iz * n + ix];
        if y < sea + 45.0 || y > sea + 700.0 {
            continue;
        }
        if springs.iter().any(|&(sx, sz)| (sx as i32 - ix as i32).pow(2) + (sz as i32 - iz as i32).pow(2) < (n as i32 / 6).pow(2)) {
            continue;
        }
        springs.push((ix, iz));
    }
    let mut rivers = Vec::new();
    let mut wet = vec![false; n * n];
    for (sx, sz) in springs {
        let (mut x, mut z) = (sx, sz);
        let mut path: Vec<(usize, usize)> = vec![(x, z)];
        // Never step on a cell twice: at a hollow, climb out through the
        // lowest way not yet taken (the carving later cuts a gorge there).
        let mut seen: std::collections::HashSet<usize> = std::collections::HashSet::new();
        seen.insert(z * n + x);
        for _ in 0..(n * 2) {
            let mut best = (f32::MAX, x, z);
            for dz in -1i32..=1 {
                for dx in -1i32..=1 {
                    if dx == 0 && dz == 0 {
                        continue;
                    }
                    let (nx, nz) = (x as i32 + dx, z as i32 + dz);
                    if nx < 1 || nz < 1 || nx >= n as i32 - 1 || nz >= n as i32 - 1 {
                        continue;
                    }
                    let i = nz as usize * n + nx as usize;
                    if seen.contains(&i) {
                        continue;
                    }
                    // Momentum: keep the way it was flowing on flat ground.
                    let (px, pz) = if path.len() > 1 { path[path.len() - 2] } else { (x, z) };
                    let keep = (x as i32 - px as i32) * dx + (z as i32 - pz as i32) * dz;
                    let y = h[i] + if dx != 0 && dz != 0 { 0.2 } else { 0.0 } - keep as f32 * 0.4;
                    if y < best.0 {
                        best = (y, nx as usize, nz as usize);
                    }
                }
            }
            if best.0 == f32::MAX {
                break;
            }
            x = best.1;
            z = best.2;
            path.push((x, z));
            let i = z * n + x;
            seen.insert(i);
            if h[i] < sea + 0.3 || x <= 1 || z <= 1 || x >= n - 2 || z >= n - 2 {
                break;
            }
            if wet[i] {
                break; // Joins a river already carved.
            }
        }
        if path.len() < 30 {
            continue;
        }
        // Smooth the course, then carve a bed that only falls.
        let pts: Vec<(f32, f32)> = (0..path.len())
            .map(|i| {
                let lo = i.saturating_sub(3);
                let hi = (i + 4).min(path.len());
                let c = (hi - lo) as f32;
                let (sx, sz) = path[lo..hi].iter().fold((0.0, 0.0), |a, p| (a.0 + p.0 as f32, a.1 + p.1 as f32));
                (sx / c, sz / c)
            })
            .collect();
        let total = pts.len() as f32;
        let mut bed = f32::MAX;
        let mut out = Vec::new();
        for (i, &(px, pz)) in pts.iter().enumerate() {
            let t = i as f32 / total;
            let width = 5.0 + 22.0 * t;
            let depth = 1.5 + 3.5 * t;
            let ground = h[(pz.round() as usize) * n + px.round() as usize];
            bed = bed.min(ground - depth).max(sea - 3.0);
            let reach = (width * 1.8 / step).ceil() as i32 + 1;
            for dz in -reach..=reach {
                for dx in -reach..=reach {
                    let (cx, cz) = (px.round() as i32 + dx, pz.round() as i32 + dz);
                    if cx < 0 || cz < 0 || cx >= n as i32 || cz >= n as i32 {
                        continue;
                    }
                    let d = (((cx as f32 - px) * step).powi(2) + ((cz as f32 - pz) * step).powi(2)).sqrt();
                    let half = width * 0.5;
                    let target = if d < half { bed } else { bed + ((d - half) / (width * 1.3)).powi(2) * (depth + 6.0) };
                    let j = cz as usize * n + cx as usize;
                    if target < h[j] {
                        h[j] = target;
                    }
                    if d < half {
                        wet[j] = true;
                    }
                }
            }
            if i % 3 == 0 || i + 1 == pts.len() {
                out.push([px * step - extent, pz * step - extent, (bed + depth * 0.75).max(sea + 0.05), width]);
            }
        }
        rivers.push(out);
    }
    rivers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terrain_is_deterministic_and_has_a_sea_and_rivers() {
        let a = generate(7, [0.55, 0.4, 0.7, 0.5, 0.6], 0.3, 128, 3000.0);
        let b = generate(7, [0.55, 0.4, 0.7, 0.5, 0.6], 0.3, 128, 3000.0);
        assert_eq!(a.heights, b.heights);
        assert!(a.sea_level > -1000.0);
        let wet = a.heights.iter().filter(|&&y| y < a.sea_level).count() as f32 / a.heights.len() as f32;
        assert!(wet > 0.1 && wet < 0.6, "about the asked share is under water: {wet}");
        let top = a.heights.iter().cloned().fold(f32::MIN, f32::max);
        assert!(top - a.sea_level > 150.0, "high land has mountains: {}", top - a.sea_level);
    }
}
