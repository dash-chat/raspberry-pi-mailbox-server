use anyhow::{Context, Result};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use dashchat_node::QrCode;

/// Encode a contact QR string exactly as the app does.
///
/// The app's `encodeContactCode` (packages/stores/src/contacts/contact-code.ts)
/// runs `base64( cbor([device_pubkey, agent_id, inbox_topic, share_intent]) )`
/// over the values as they crossed the tauri IPC boundary — i.e. their serde
/// JSON representations. Reproduced here by serializing the `QrCode` to
/// `serde_json::Value` and CBOR-encoding the same 4-element array.
pub fn encode_contact_code(qr: &QrCode) -> Result<String> {
    let v = serde_json::to_value(qr).context("serializing QrCode")?;
    let field = |name: &str| -> Result<serde_json::Value> {
        v.get(name)
            .cloned()
            .with_context(|| format!("QrCode serde repr is missing `{name}`"))
    };
    let arr = serde_json::Value::Array(vec![
        field("device_pubkey")?,
        field("agent_id")?,
        field("inbox_topic")?,
        field("share_intent")?,
    ]);
    let mut buf = Vec::new();
    ciborium::ser::into_writer(&arr, &mut buf).context("CBOR-encoding contact code")?;
    Ok(BASE64.encode(&buf))
}

/// Decode a contact QR string (the inverse of [`encode_contact_code`]);
/// used by tests and by `larp-bot qr --check`.
pub fn decode_contact_code(code: &str) -> Result<QrCode> {
    let bytes = BASE64.decode(code).context("base64-decoding contact code")?;
    let arr: serde_json::Value =
        ciborium::de::from_reader(bytes.as_slice()).context("CBOR-decoding contact code")?;
    let items = arr
        .as_array()
        .filter(|a| a.len() == 4)
        .context("contact code is not a 4-element array")?;
    serde_json::from_value(serde_json::json!({
        "device_pubkey": items[0],
        "agent_id": items[1],
        "inbox_topic": items[2],
        "share_intent": items[3],
    }))
    .context("deserializing QrCode")
}

/// Render the QR string to a PNG (for the printed wall posters).
pub fn render_png(code: &str, path: &std::path::Path, module_px: u32) -> Result<()> {
    let qr = qrcode::QrCode::new(code.as_bytes()).context("building QR code")?;
    let image = qr
        .render::<image::Luma<u8>>()
        .min_dimensions(qr.width() as u32 * module_px, qr.width() as u32 * module_px)
        .build();
    image
        .save(path)
        .with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::IdentityBundle;

    #[test]
    fn contact_code_roundtrip() {
        let bundle = IdentityBundle::generate("journalist");
        let qr = bundle.qr_code().unwrap();
        let code = encode_contact_code(&qr).unwrap();
        let back = decode_contact_code(&code).unwrap();
        assert_eq!(back, qr);
    }
}
