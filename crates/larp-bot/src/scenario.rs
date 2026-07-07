use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

/// One mission template: prose fired by the owning character, addressed (in
/// the prose itself) to `to`, whose bot replies with `success` when the
/// message reaches its station. There is no machine-readable metadata in the
/// message text — recognition works by (signed author, exact text) lookup
/// against these packs, which every bot loads in full.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Mission {
    /// Character key of the intended recipient.
    pub to: String,
    /// The mission prose, sent verbatim.
    pub text: String,
    /// The recipient's in-character success reply, sent verbatim.
    pub success: String,
}

/// One character's scenario pack (`scenarios/<character>.toml`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Pack {
    /// Display name for the character's chat profile (e.g. "Bombers").
    pub name: String,
    /// Sent once per group when the bot joins it.
    pub greeting: String,
    #[serde(default)]
    pub missions: Vec<Mission>,
}

/// All packs, keyed by character. Every bot loads all of them: recognizing a
/// mission addressed to me requires knowing the *other* characters' texts.
#[derive(Clone, Debug, Default)]
pub struct Scenarios {
    pub packs: BTreeMap<String, Pack>,
}

impl Scenarios {
    /// Load every `*.toml` in the directory; the file stem is the character key.
    pub fn load_dir(dir: impl AsRef<Path>) -> Result<Self> {
        let dir = dir.as_ref();
        let mut packs = BTreeMap::new();
        for entry in std::fs::read_dir(dir)
            .with_context(|| format!("reading scenarios dir {}", dir.display()))?
        {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("toml") {
                continue;
            }
            let character = path
                .file_stem()
                .and_then(|s| s.to_str())
                .context("scenario file has a non-utf8 name")?
                .to_string();
            let raw = std::fs::read_to_string(&path)?;
            let pack: Pack = toml::from_str(&raw)
                .with_context(|| format!("parsing scenario pack {}", path.display()))?;
            packs.insert(character, pack);
        }
        let scenarios = Self { packs };
        scenarios.lint()?;
        Ok(scenarios)
    }

    /// The pack invariants recognition depends on:
    /// - every `to` names a known character (and not the pack's own),
    /// - mission texts are unique across ALL packs (a text identifies exactly
    ///   one mission),
    /// - success lines are unique across ALL packs and never collide with a
    ///   mission text.
    pub fn lint(&self) -> Result<()> {
        let mut texts: BTreeSet<&str> = BTreeSet::new();
        let mut successes: BTreeSet<&str> = BTreeSet::new();
        for (character, pack) in &self.packs {
            if pack.greeting.trim().is_empty() {
                bail!("pack {character}: empty greeting");
            }
            for (i, mission) in pack.missions.iter().enumerate() {
                if mission.to == *character {
                    bail!("pack {character} mission {i}: addressed to itself");
                }
                if !self.packs.contains_key(&mission.to) {
                    bail!(
                        "pack {character} mission {i}: unknown recipient {:?}",
                        mission.to
                    );
                }
                if mission.text.trim().is_empty() || mission.success.trim().is_empty() {
                    bail!("pack {character} mission {i}: empty text or success");
                }
                if !texts.insert(&mission.text) {
                    bail!("pack {character} mission {i}: duplicate mission text");
                }
                if !successes.insert(&mission.success) {
                    bail!("pack {character} mission {i}: duplicate success line");
                }
            }
        }
        if let Some(overlap) = texts.intersection(&successes).next() {
            bail!("a success line equals a mission text: {overlap:?}");
        }
        Ok(())
    }

    /// Find the mission with this exact text, authored by this character.
    pub fn mission_by_text(&self, author: &str, text: &str) -> Option<&Mission> {
        self.packs
            .get(author)?
            .missions
            .iter()
            .find(|m| m.text == text)
    }

    pub fn pack(&self, character: &str) -> Option<&Pack> {
        self.packs.get(character)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scenarios(packs: &[(&str, Pack)]) -> Scenarios {
        Scenarios {
            packs: packs
                .iter()
                .map(|(k, v)| (k.to_string(), v.clone()))
                .collect(),
        }
    }

    fn pack(missions: Vec<Mission>) -> Pack {
        Pack {
            name: "Test".into(),
            greeting: "hello".into(),
            missions,
        }
    }

    fn mission(to: &str, text: &str, success: &str) -> Mission {
        Mission {
            to: to.into(),
            text: text.into(),
            success: success.into(),
        }
    }

    #[test]
    fn lint_accepts_valid_packs() {
        let s = scenarios(&[
            ("a", pack(vec![mission("b", "t1", "s1")])),
            ("b", pack(vec![mission("a", "t2", "s2")])),
        ]);
        s.lint().unwrap();
    }

    #[test]
    fn lint_rejects_unknown_recipient() {
        let s = scenarios(&[("a", pack(vec![mission("nobody", "t", "s")]))]);
        assert!(s.lint().is_err());
    }

    #[test]
    fn lint_rejects_self_addressed() {
        let s = scenarios(&[("a", pack(vec![mission("a", "t", "s")]))]);
        assert!(s.lint().is_err());
    }

    #[test]
    fn shipped_packs_lint() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../scenarios");
        let s = Scenarios::load_dir(dir).unwrap();
        for character in ["firefighters", "hospital", "journalist", "relative"] {
            assert!(s.pack(character).is_some(), "missing pack {character}");
        }
    }

    #[test]
    fn lint_rejects_duplicate_texts_across_packs() {
        let s = scenarios(&[
            ("a", pack(vec![mission("b", "same", "s1")])),
            ("b", pack(vec![mission("a", "same", "s2")])),
        ]);
        assert!(s.lint().is_err());
    }
}
