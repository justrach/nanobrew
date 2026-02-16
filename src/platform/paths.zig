// nanobrew — Centralized path constants
//
// All path constants for the nanobrew directory tree.
// Same values on both macOS and Linux.

pub const ROOT = "/opt/nanobrew";
pub const PREFIX = ROOT ++ "/prefix";
pub const CELLAR_DIR = PREFIX ++ "/Cellar";
pub const BIN_DIR = PREFIX ++ "/bin";
pub const OPT_DIR = PREFIX ++ "/opt";
pub const STORE_DIR = ROOT ++ "/store";
pub const CACHE_DIR = ROOT ++ "/cache";
pub const BLOBS_DIR = CACHE_DIR ++ "/blobs";
pub const TMP_DIR = CACHE_DIR ++ "/tmp";
pub const API_CACHE_DIR = CACHE_DIR ++ "/api";
pub const TOKEN_CACHE_DIR = CACHE_DIR ++ "/tokens";
pub const DB_PATH = ROOT ++ "/db/state.json";
pub const CASKROOM_DIR = PREFIX ++ "/Caskroom";

pub const PLACEHOLDER_PREFIX = "@@HOMEBREW_PREFIX@@";
pub const PLACEHOLDER_CELLAR = "@@HOMEBREW_CELLAR@@";
pub const REAL_PREFIX = PREFIX;
pub const REAL_CELLAR = PREFIX ++ "/Cellar";
