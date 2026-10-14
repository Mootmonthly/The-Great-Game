//! Server signatures (HMAC-SHA256). Only the server signs and checks them;
//! they let records leave the server and come back untampered.

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use std::path::Path;

pub struct Signer {
    key: Vec<u8>,
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}

/// SHA-256 of `data`, as hex.
pub fn digest(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

impl Signer {
    pub fn new(key: Vec<u8>) -> Signer {
        Signer { key }
    }

    /// A fresh random key.
    pub fn random() -> Signer {
        let mut key = vec![0u8; 32];
        getrandom::getrandom(&mut key).expect("system random source");
        Signer { key }
    }

    /// Loads the key from `path`, creating it on first run.
    pub fn load_or_create(path: &Path) -> std::io::Result<Signer> {
        if let Ok(text) = std::fs::read_to_string(path) {
            if let Some(key) = unhex(text.trim()) {
                return Ok(Signer { key });
            }
        }
        let s = Signer::random();
        std::fs::write(path, hex(&s.key))?;
        Ok(s)
    }

    pub fn sign(&self, data: &[u8]) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.key).expect("any key length");
        mac.update(data);
        hex(&mac.finalize().into_bytes())
    }

    pub fn verify(&self, data: &[u8], signature: &str) -> bool {
        let Some(sig) = unhex(signature) else {
            return false;
        };
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.key).expect("any key length");
        mac.update(data);
        mac.verify_slice(&sig).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signatures_check_out_and_detect_tampering() {
        let s = Signer::random();
        let sig = s.sign(b"champion 7 cost 120");
        assert!(s.verify(b"champion 7 cost 120", &sig));
        assert!(!s.verify(b"champion 7 cost 999", &sig));
        assert!(!Signer::random().verify(b"champion 7 cost 120", &sig));
    }
}
