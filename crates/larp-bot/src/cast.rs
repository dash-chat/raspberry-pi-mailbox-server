use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result};
use dashchat_node::{AgentId, DeviceId};
use serde::{Deserialize, Serialize};

/// One character's public identity, as stored in `cast.toml`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CastEntry {
    /// Hex 32-byte agent id.
    pub agent_id: String,
    /// Hex 32-byte device public key (the bot has exactly one device).
    pub device_id: String,
}

/// The public cast file baked into every station: maps character key →
/// public identity. This is what lets any bot recognize which character
/// authored a message (signed by that character's device key).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Cast {
    pub characters: BTreeMap<String, CastEntry>,
}

impl Cast {
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let raw = std::fs::read_to_string(path.as_ref())
            .with_context(|| format!("reading cast file {}", path.as_ref().display()))?;
        let cast: Self = toml::from_str(&raw).context("parsing cast file")?;
        cast.resolve()?; // fail fast on malformed entries
        Ok(cast)
    }

    pub fn save(&self, path: impl AsRef<Path>) -> Result<()> {
        std::fs::write(path.as_ref(), toml::to_string_pretty(self)?)
            .with_context(|| format!("writing cast file {}", path.as_ref().display()))?;
        Ok(())
    }

    /// Parse every entry into real key types, keyed by character.
    pub fn resolve(&self) -> Result<ResolvedCast> {
        let mut by_device = BTreeMap::new();
        let mut agents = BTreeMap::new();
        for (character, entry) in &self.characters {
            let device_bytes: [u8; 32] = hex::decode(&entry.device_id)
                .with_context(|| format!("cast[{character}].device_id is not hex"))?
                .try_into()
                .map_err(|_| anyhow::anyhow!("cast[{character}].device_id is not 32 bytes"))?;
            let agent_bytes: [u8; 32] = hex::decode(&entry.agent_id)
                .with_context(|| format!("cast[{character}].agent_id is not hex"))?
                .try_into()
                .map_err(|_| anyhow::anyhow!("cast[{character}].agent_id is not 32 bytes"))?;
            let agent = AgentId::from_bytes(&agent_bytes)?;
            by_device.insert(device_bytes, character.clone());
            agents.insert(character.clone(), agent);
        }
        Ok(ResolvedCast { by_device, agents })
    }
}

/// Cast with parsed keys, for hot-path lookups.
#[derive(Clone, Debug)]
pub struct ResolvedCast {
    /// device public key bytes → character key
    by_device: BTreeMap<[u8; 32], String>,
    agents: BTreeMap<String, AgentId>,
}

impl ResolvedCast {
    /// Which character (if any) signed with this device key?
    pub fn character_of_device(&self, device: &DeviceId) -> Option<&str> {
        self.by_device.get(device.as_bytes()).map(|s| s.as_str())
    }

    pub fn agent_of(&self, character: &str) -> Option<AgentId> {
        self.agents.get(character).copied()
    }

    pub fn characters(&self) -> impl Iterator<Item = &str> {
        self.agents.keys().map(|s| s.as_str())
    }
}
