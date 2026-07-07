use std::path::Path;

use anyhow::{Context, Result, ensure};
use chrono::{DateTime, Utc};
use dashchat_node::{AgentId, DeviceId, QrCode, SigningKey};
use serde::{Deserialize, Serialize};

/// The flashable identity bundle (`larp-identity.toml`): everything that must
/// survive a data-dir wipe or image re-flash so the printed QR posters stay
/// valid. Generated offline by `larp-bot keygen`, read from the FAT boot
/// partition by `larp-bot run`.
///
/// All three key fields are required — none is derivable from the others:
/// the agent id is minted from a throwaway key, and the inbox topic is what
/// the printed QR routes contact requests to (requests for unregistered inbox
/// topics are silently dropped).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct IdentityBundle {
    /// Character key, e.g. "firefighters". Selects the scenario pack.
    pub character: String,
    /// Hex ed25519 signing-key seed (the device key).
    pub device_private_key: String,
    /// Hex 32-byte agent id.
    pub agent_id: String,
    /// Hex 32-byte inbox topic id.
    pub inbox_topic: String,
    /// Expiry baked into the QR. Posters are printed: keep it years out.
    pub inbox_expires_at: DateTime<Utc>,
}

impl IdentityBundle {
    pub fn generate(character: &str) -> Self {
        let device_key = SigningKey::generate();
        // Upstream mints the agent id from a throwaway key's public half
        // (stores/local_store.rs); mirror that.
        let agent_id = AgentId::from(dashchat_node::ActorId::from(
            SigningKey::generate().verifying_key(),
        ));
        // Inbox topics are plain random 32 bytes (Topic::inbox()).
        let inbox: [u8; 32] = rand::random();
        Self {
            character: character.to_string(),
            device_private_key: hex::encode(device_key.as_bytes()),
            agent_id: hex::encode(agent_id.as_bytes()),
            inbox_topic: hex::encode(inbox),
            inbox_expires_at: Utc::now() + chrono::Duration::days(365 * 5),
        }
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let raw = std::fs::read_to_string(path.as_ref())
            .with_context(|| format!("reading identity bundle {}", path.as_ref().display()))?;
        let bundle: Self = toml::from_str(&raw).context("parsing identity bundle")?;
        bundle.validate()?;
        Ok(bundle)
    }

    pub fn save(&self, path: impl AsRef<Path>) -> Result<()> {
        self.validate()?;
        std::fs::write(path.as_ref(), toml::to_string_pretty(self)?)
            .with_context(|| format!("writing identity bundle {}", path.as_ref().display()))?;
        Ok(())
    }

    pub fn validate(&self) -> Result<()> {
        self.signing_key()?;
        self.agent_id()?;
        self.inbox_topic_bytes()?;
        ensure!(!self.character.is_empty(), "character must not be empty");
        Ok(())
    }

    pub fn signing_key(&self) -> Result<SigningKey> {
        let bytes: [u8; 32] = hex::decode(&self.device_private_key)
            .context("device_private_key is not hex")?
            .try_into()
            .map_err(|_| anyhow::anyhow!("device_private_key is not 32 bytes"))?;
        Ok(SigningKey::from_bytes(&bytes))
    }

    pub fn device_id(&self) -> Result<DeviceId> {
        Ok(DeviceId::from(self.signing_key()?.verifying_key()))
    }

    pub fn agent_id(&self) -> Result<AgentId> {
        let bytes: [u8; 32] = hex::decode(&self.agent_id)
            .context("agent_id is not hex")?
            .try_into()
            .map_err(|_| anyhow::anyhow!("agent_id is not 32 bytes"))?;
        AgentId::from_bytes(&bytes)
    }

    pub fn agent_id_bytes(&self) -> Result<[u8; 32]> {
        Ok(*self.agent_id()?.as_bytes())
    }

    pub fn inbox_topic_bytes(&self) -> Result<[u8; 32]> {
        hex::decode(&self.inbox_topic)
            .context("inbox_topic is not hex")?
            .try_into()
            .map_err(|_| anyhow::anyhow!("inbox_topic is not 32 bytes"))
    }

    /// The contact QR for this identity, exactly as the node would mint it.
    ///
    /// `InboxTopic` isn't exported by dashchat-node, so the value is built
    /// through its serde representation (topics serialize as hex strings) —
    /// covered by a round-trip test below.
    pub fn qr_code(&self) -> Result<QrCode> {
        let value = serde_json::json!({
            "device_pubkey": serde_json::to_value(self.device_id()?)?,
            "agent_id": serde_json::to_value(self.agent_id()?)?,
            "inbox_topic": {
                "expires_at": serde_json::to_value(self.inbox_expires_at)?,
                "topic": self.inbox_topic,
            },
            "share_intent": "AddContact",
        });
        serde_json::from_value(value).context("assembling QrCode from identity bundle")
    }

    /// The public half, as a `cast.toml` entry.
    pub fn cast_entry(&self) -> Result<crate::cast::CastEntry> {
        Ok(crate::cast::CastEntry {
            agent_id: self.agent_id.clone(),
            device_id: hex::encode(self.device_id()?.as_bytes()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dashchat_node::ShareIntent;

    #[test]
    fn qr_code_roundtrips_through_serde() {
        let bundle = IdentityBundle::generate("firefighters");
        let qr = bundle.qr_code().unwrap();
        assert_eq!(qr.device_pubkey, bundle.device_id().unwrap());
        assert_eq!(qr.agent_id, bundle.agent_id().unwrap());
        assert_eq!(qr.share_intent, ShareIntent::AddContact);
        let inbox = qr.inbox_topic.as_ref().expect("inbox topic present");
        // Serde re-serialization must preserve the exact topic hex.
        let v = serde_json::to_value(inbox).unwrap();
        assert_eq!(v["topic"], serde_json::json!(bundle.inbox_topic));
    }

    #[test]
    fn bundle_toml_roundtrip() {
        let bundle = IdentityBundle::generate("hospital");
        let toml_str = toml::to_string_pretty(&bundle).unwrap();
        let back: IdentityBundle = toml::from_str(&toml_str).unwrap();
        assert_eq!(back.device_private_key, bundle.device_private_key);
        assert_eq!(back.agent_id, bundle.agent_id);
        assert_eq!(back.inbox_topic, bundle.inbox_topic);
    }
}
