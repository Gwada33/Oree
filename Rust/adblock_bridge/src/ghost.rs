//! Storage for hibernated-tab "ghosts": compressed (zstd) page snapshots kept as opaque files on disk.
//!
//! The bridge only compresses and stores bytes. Encrypting them (phase 6) happens in Swift between
//! `ghost_compress` and `GhostStore::put`, so nothing here has to change for it.

use crate::BridgeError;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

/// Largest payload `ghost_decompress` will produce. Protects against a corrupted or hostile file that
/// claims to expand to gigabytes.
const MAX_DECOMPRESSED: usize = 32 * 1024 * 1024;

fn ghost_err(error: impl std::fmt::Display) -> BridgeError {
    BridgeError::Ghost(error.to_string())
}

/// Compresses `bytes` with zstd (`level` is clamped to 1...19; ~3 is a good speed/size balance for HTML).
#[uniffi::export]
pub fn ghost_compress(bytes: Vec<u8>, level: i32) -> Result<Vec<u8>, BridgeError> {
    zstd::bulk::compress(&bytes, level.clamp(1, 19)).map_err(ghost_err)
}

/// Decompresses a zstd payload, refusing anything that expands beyond 32 MiB.
#[uniffi::export]
pub fn ghost_decompress(bytes: Vec<u8>) -> Result<Vec<u8>, BridgeError> {
    zstd::bulk::decompress(&bytes, MAX_DECOMPRESSED).map_err(ghost_err)
}

/// A directory of opaque blobs addressed by key (a tab id). Writes are atomic (temp file + rename).
#[derive(uniffi::Object)]
pub struct GhostStore {
    dir: PathBuf,
}

/// Keys become file names: letters, digits, `-` and `_` only, so no key can point outside the directory.
fn valid_key(key: &str) -> bool {
    !key.is_empty() && key.len() <= 128 && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

impl GhostStore {
    fn path(&self, key: &str) -> Result<PathBuf, BridgeError> {
        if valid_key(key) { Ok(self.dir.join(format!("{key}.ghost"))) } else { Err(BridgeError::InvalidGhostKey) }
    }
}

#[uniffi::export]
impl GhostStore {
    #[uniffi::constructor]
    pub fn new(dir: String) -> Result<Arc<Self>, BridgeError> {
        let dir = PathBuf::from(dir);
        fs::create_dir_all(&dir).map_err(ghost_err)?;
        Ok(Arc::new(Self { dir }))
    }

    pub fn put(&self, key: String, bytes: Vec<u8>) -> Result<(), BridgeError> {
        let path = self.path(&key)?;
        let temp = self.dir.join(format!("{key}.tmp"));
        fs::write(&temp, bytes).map_err(ghost_err)?;
        fs::rename(&temp, &path).map_err(ghost_err)
    }

    /// `None` when there is no ghost for this key.
    pub fn get(&self, key: String) -> Result<Option<Vec<u8>>, BridgeError> {
        match fs::read(self.path(&key)?) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(ghost_err(error)),
        }
    }

    pub fn remove(&self, key: String) -> Result<(), BridgeError> {
        match fs::remove_file(self.path(&key)?) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(ghost_err(error)),
        }
    }

    /// Deletes every ghost (app start and quit).
    pub fn purge(&self) -> Result<(), BridgeError> {
        fs::remove_dir_all(&self.dir).map_err(ghost_err)?;
        fs::create_dir_all(&self.dir).map_err(ghost_err)
    }

    /// Total size of the stored ghosts, in bytes.
    pub fn total_bytes(&self) -> u64 {
        fs::read_dir(&self.dir)
            .map(|entries| entries.filter_map(|e| e.ok()?.metadata().ok()).map(|m| m.len()).sum())
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!("oree-ghost-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir.to_string_lossy().into_owned()
    }

    #[test]
    fn compression_round_trips_and_shrinks_html() {
        let html = "<div class=\"row\"><span>Hello</span></div>".repeat(2000).into_bytes();
        let packed = ghost_compress(html.clone(), 3).unwrap();
        assert!(packed.len() * 10 < html.len(), "repetitive HTML should shrink a lot");
        assert_eq!(ghost_decompress(packed).unwrap(), html);
    }

    #[test]
    fn decompression_refuses_oversized_and_corrupt_input() {
        let big = vec![0u8; MAX_DECOMPRESSED + 1];
        let packed = ghost_compress(big, 1).unwrap();
        assert!(ghost_decompress(packed).is_err(), "a payload above the cap must be refused");
        assert!(ghost_decompress(b"not zstd".to_vec()).is_err());
    }

    #[test]
    fn store_puts_gets_removes_and_purges() {
        let store = GhostStore::new(temp_dir("store")).unwrap();
        assert_eq!(store.get("tab-1".into()).unwrap(), None);
        store.put("tab-1".into(), b"abc".to_vec()).unwrap();
        assert_eq!(store.get("tab-1".into()).unwrap(), Some(b"abc".to_vec()));
        assert_eq!(store.total_bytes(), 3);
        store.put("tab-1".into(), b"abcd".to_vec()).unwrap();      // overwrite
        assert_eq!(store.get("tab-1".into()).unwrap(), Some(b"abcd".to_vec()));
        store.remove("tab-1".into()).unwrap();
        store.remove("tab-1".into()).unwrap();                      // removing twice is fine
        assert_eq!(store.get("tab-1".into()).unwrap(), None);
        store.put("a".into(), vec![1]).unwrap();
        store.put("b".into(), vec![2]).unwrap();
        store.purge().unwrap();
        assert_eq!(store.total_bytes(), 0);
    }

    #[test]
    fn keys_cannot_escape_the_directory() {
        let store = GhostStore::new(temp_dir("keys")).unwrap();
        for bad in ["", "../x", "a/b", "a.b", "x\0y", &"k".repeat(129)] {
            assert!(matches!(store.put(bad.into(), vec![1]), Err(BridgeError::InvalidGhostKey)), "{bad:?}");
        }
    }
}
