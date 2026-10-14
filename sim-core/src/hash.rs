//! Stable state hashing (FNV-1a, 64-bit).
//!
//! `std`'s default hasher is not guaranteed to stay the same between Rust
//! releases, so the simulation uses its own. Two worlds with equal hashes are
//! treated as identical by replay verification.

pub struct StateHasher(u64);

impl StateHasher {
    pub fn new() -> StateHasher {
        StateHasher(0xcbf2_9ce4_8422_2325)
    }

    pub fn bytes(&mut self, data: &[u8]) {
        for b in data {
            self.0 ^= *b as u64;
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }

    pub fn u64(&mut self, v: u64) {
        self.bytes(&v.to_le_bytes());
    }

    pub fn i64(&mut self, v: i64) {
        self.bytes(&v.to_le_bytes());
    }

    pub fn finish(&self) -> u64 {
        self.0
    }
}

impl Default for StateHasher {
    fn default() -> Self {
        Self::new()
    }
}
