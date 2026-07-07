use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

/// `larp-bot run` configuration (`config.toml`). The character itself comes
/// from the identity bundle — this file only wires up paths and timing.
#[derive(Clone, Debug, Deserialize)]
pub struct BotConfig {
    /// The mailbox this bot syncs through: `http://127.0.0.1:<port>` on the
    /// Pis, the cloud mailbox URL on the journalist droplet.
    pub mailbox_url: String,
    /// The flashed identity bundle (survives wipes; see identity.rs).
    pub identity: PathBuf,
    /// The public cast file (all characters' agent/device ids).
    pub cast: PathBuf,
    /// Directory of scenario packs (`<character>.toml`, all characters).
    pub scenarios_dir: PathBuf,
    /// Node data dir. A cache: safe to wipe, identity comes from the bundle.
    pub data_dir: PathBuf,
    #[serde(default)]
    pub timing: Timing,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct Timing {
    /// Mission firing interval bounds, per group (uniform random draw).
    pub min_interval_secs: u64,
    pub max_interval_secs: u64,
    /// Max missions per group awaiting a success reply before the bot
    /// pauses its timer for that group.
    pub max_outstanding: usize,
    /// How often the bot polls its groups for new messages.
    pub poll_interval_secs: u64,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            min_interval_secs: 180,
            max_interval_secs: 480,
            max_outstanding: 3,
            poll_interval_secs: 3,
        }
    }
}

impl BotConfig {
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let raw = std::fs::read_to_string(path.as_ref())
            .with_context(|| format!("reading config {}", path.as_ref().display()))?;
        let config: Self = toml::from_str(&raw).context("parsing config")?;
        anyhow::ensure!(
            config.timing.min_interval_secs <= config.timing.max_interval_secs,
            "timing: min_interval_secs > max_interval_secs"
        );
        anyhow::ensure!(config.timing.max_outstanding > 0, "timing: max_outstanding is 0");
        Ok(config)
    }
}
