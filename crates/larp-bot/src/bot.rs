use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use dashchat_node::{
    ChatPayload, InboxPayload, Node, NodeConfig, Payload, Profile, stores::LocalStore,
};
use rand::Rng as _;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::cast::ResolvedCast;
use crate::config::{BotConfig, Timing};
use crate::identity::IdentityBundle;
use crate::scenario::Scenarios;

/// Persistent bot state (`state.json` in the data dir). A cache like the rest
/// of the data dir: wiping it loses greeted/acked bookkeeping but never the
/// identity (which lives in the flashed bundle).
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct BotState {
    /// Groups already greeted (hex chat ids).
    pub greeted: std::collections::BTreeSet<String>,
    /// Contact requests already accepted (hex agent ids).
    pub accepted_contacts: std::collections::BTreeSet<String>,
    /// Mission ops I already success-replied to (hex op hashes).
    pub acked: std::collections::BTreeSet<String>,
    /// Success-line ops I already counted as deliveries (hex op hashes).
    pub delivered_ops: std::collections::BTreeSet<String>,
    /// Missions I fired, per group (hex chat id → list).
    pub fired: BTreeMap<String, Vec<FiredMission>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FiredMission {
    pub to: String,
    pub text: String,
    pub success: String,
    pub delivered: bool,
}

impl BotState {
    pub fn load(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(raw) => serde_json::from_str(&raw).unwrap_or_else(|err| {
                warn!(?err, "state.json unreadable, starting fresh");
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    fn outstanding(&self, group: &str) -> usize {
        self.fired
            .get(group)
            .map(|v| v.iter().filter(|m| !m.delivered).count())
            .unwrap_or(0)
    }
}

/// Overwrite the freshly-migrated local store's identity with the flashed
/// bundle, and register the bundle's inbox topic as active. Idempotent; runs
/// before the Node ever reads its keys. `Node::init`'s startup path then
/// re-subscribes the inbox topic from the store, so no private API is needed.
pub async fn seed_identity(data_dir: &Path, bundle: &IdentityBundle) -> Result<()> {
    std::fs::create_dir_all(data_dir)
        .with_context(|| format!("creating data dir {}", data_dir.display()))?;
    // Same filename Node::new derives via its (private) Filesystem type.
    let store_path = data_dir.join("localdata.db");

    // Run the store's own migrations (also mints a throwaway identity on
    // first boot, which the UPDATE below replaces).
    let store = LocalStore::new(&store_path).await?;
    store.close().await;

    let opts = sqlx::sqlite::SqliteConnectOptions::new()
        .filename(&store_path)
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(opts)
        .await
        .context("opening local store for identity seeding")?;

    let seed = hex::decode(&bundle.device_private_key)?;
    sqlx::query("UPDATE identity SET value = ? WHERE key = 'private_key'")
        .bind(seed)
        .execute(&pool)
        .await?;
    sqlx::query("UPDATE identity SET value = ? WHERE key = 'agent_id'")
        .bind(bundle.agent_id_bytes()?.to_vec())
        .execute(&pool)
        .await?;
    // Schema: active_inboxes(topic_id BLOB PK, expires_at_nanos INTEGER).
    let nanos = bundle
        .inbox_expires_at
        .timestamp_nanos_opt()
        .unwrap_or(i64::MAX);
    sqlx::query("INSERT OR REPLACE INTO active_inboxes (topic_id, expires_at_nanos) VALUES (?, ?)")
        .bind(bundle.inbox_topic_bytes()?.to_vec())
        .bind(nanos)
        .execute(&pool)
        .await?;
    pool.close().await;

    // Sanity: the store must now report the flashed identity.
    let store = LocalStore::new(&store_path).await?;
    let keys = store.node_keys().await?;
    let ok = keys.private_key.as_bytes() == bundle.signing_key()?.as_bytes()
        && keys.agent_id == bundle.agent_id()?;
    store.close().await;
    anyhow::ensure!(ok, "identity seeding failed: store keys don't match the bundle");
    Ok(())
}

/// Seed the identity and start the node. The caller picks the `NodeConfig`
/// (production: [`bot_node_config`]; tests: `NodeConfig::testing()`-based)
/// and registers a mailbox afterwards.
pub async fn build_node(
    data_dir: &Path,
    bundle: &IdentityBundle,
    config: NodeConfig,
) -> Result<(Node, mpsc::Receiver<dashchat_node::Notification>)> {
    seed_identity(data_dir, bundle).await?;
    let (notification_tx, notification_rx) = mpsc::channel(1024);
    let node = Node::new(
        data_dir.to_path_buf(),
        config,
        Some(notification_tx),
        None,
    )
    .await?;
    Ok((node, notification_rx))
}

/// Node config for a bot: fully offline-capable — no relay, no mDNS, no p2p,
/// no blob sync. Everything flows through the one configured mailbox.
pub fn bot_node_config() -> NodeConfig {
    let mut config = NodeConfig::default().no_p2p().no_blob_sync();
    // Runtime QR minting isn't used (the QR comes from the bundle), but keep
    // any incidental inbox registration far-lived anyway.
    config.contact_code_expiry = chrono::Duration::days(365 * 5);
    config
}

/// Register the configured mailbox on the node, retrying until it's up
/// (the mailbox on the same Pi may come up after us).
async fn register_mailbox(node: &Node, url: &str) {
    loop {
        match dashchat_node::mailbox::fetch_mailbox_health(url).await {
            Ok(health) => {
                if !node.mailboxes.is_tracked(&health.mailbox_id).await {
                    let client = mailbox_client::toy::ToyMailboxClient::new(
                        health.mailbox_id,
                        url.to_string(),
                        node.endpoint_id(),
                        node.unfetched_blob_tracker(),
                    );
                    node.mailboxes.register(client).await;
                }
                info!(%url, "mailbox registered");
                return;
            }
            Err(err) => {
                warn!(%url, ?err, "mailbox not reachable yet, retrying in 5s");
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    }
}

pub struct Bot {
    node: Node,
    bundle: IdentityBundle,
    cast: ResolvedCast,
    scenarios: Scenarios,
    timing: Timing,
    state: BotState,
    state_path: PathBuf,
    /// Per-group next mission fire time (in-memory; reseeded on restart).
    next_fire: BTreeMap<String, Instant>,
}

/// Run the bot daemon: seed identity, start the node, register the mailbox,
/// then loop forever (notification handling + group polling + scheduling).
pub async fn run(config: BotConfig) -> Result<()> {
    let bundle = IdentityBundle::load(&config.identity)?;
    let cast = crate::cast::Cast::load(&config.cast)?.resolve()?;
    let scenarios = Scenarios::load_dir(&config.scenarios_dir)?;

    let (node, notification_rx) =
        build_node(&config.data_dir, &bundle, bot_node_config()).await?;
    info!(
        character = %bundle.character,
        device_id = %hex::encode(bundle.device_id()?.as_bytes()),
        "node up"
    );

    register_mailbox(&node, &config.mailbox_url).await;

    let state_path = config.data_dir.join("state.json");
    Bot::new(node, bundle, cast, scenarios, config.timing, state_path)?
        .run_loop(notification_rx)
        .await
}

impl Bot {
    pub fn new(
        node: Node,
        bundle: IdentityBundle,
        cast: ResolvedCast,
        scenarios: Scenarios,
        timing: Timing,
        state_path: PathBuf,
    ) -> Result<Self> {
        anyhow::ensure!(
            scenarios.pack(&bundle.character).is_some(),
            "no scenario pack for character {:?}",
            bundle.character
        );
        Ok(Self {
            node,
            bundle,
            cast,
            scenarios,
            timing,
            state: BotState::load(&state_path),
            state_path,
            next_fire: BTreeMap::new(),
        })
    }

    /// Announce the character's profile once. Must happen before accepting
    /// contacts: `add_contact`'s reply requires a profile.
    async fn ensure_profile(&self) -> Result<()> {
        if self.node.my_profile().await?.is_none() {
            let name = self
                .scenarios
                .pack(&self.bundle.character)
                .expect("checked in new()")
                .name
                .clone();
            self.node
                .set_profile(Profile {
                    name,
                    surname: None,
                    avatar: None,
                    about: None,
                })
                .await?;
        }
        Ok(())
    }

    pub async fn run_loop(mut self, mut notifications: mpsc::Receiver<dashchat_node::Notification>) -> Result<()> {
        self.ensure_profile().await?;
        let poll = Duration::from_secs(self.timing.poll_interval_secs.max(1));
        let mut tick = tokio::time::interval(poll);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                maybe = notifications.recv() => {
                    match maybe {
                        Some(notification) => {
                            if let Err(err) = self.handle_notification(notification).await {
                                warn!(?err, "notification handling failed");
                            }
                        }
                        None => anyhow::bail!("node notification channel closed"),
                    }
                }
                _ = tick.tick() => {
                    if let Err(err) = self.tick().await {
                        warn!(?err, "tick failed");
                    }
                }
            }
        }
    }

    /// Auto-accept incoming contact requests (the acceptance half of the
    /// QR-poster onboarding flow).
    async fn handle_notification(&mut self, n: dashchat_node::Notification) -> Result<()> {
        let Some(Payload::Inbox(InboxPayload::ContactRequest { code, profile })) = n.payload
        else {
            return Ok(());
        };
        let requester = hex::encode(code.agent_id.as_bytes());
        if code.agent_id == self.bundle.agent_id()?
            || self.state.accepted_contacts.contains(&requester)
        {
            return Ok(());
        }
        info!(name = %profile.name, "accepting contact request");
        self.node.add_contact(code).await.map_err(|e| anyhow::anyhow!("{e:?}"))?;
        self.state.accepted_contacts.insert(requester);
        self.state.save(&self.state_path)?;
        Ok(())
    }

    async fn tick(&mut self) -> Result<()> {
        let groups = self.node.get_groups().await?;
        for group in groups {
            let key = group.to_string();

            // Greet groups we just joined (join itself is automatic).
            if !self.state.greeted.contains(&key) {
                let greeting = self
                    .scenarios
                    .pack(&self.bundle.character)
                    .expect("checked at startup")
                    .greeting
                    .clone();
                info!(group = %key, "greeting new group");
                self.node.send_message(group, greeting, None).await?;
                self.state.greeted.insert(key.clone());
                self.state.save(&self.state_path)?;
                // Schedule the group's first mission.
                self.next_fire.insert(key.clone(), self.draw_next_fire());
            }

            self.process_group_messages(group, &key).await?;
            self.maybe_fire_mission(group, &key).await?;
        }
        Ok(())
    }

    /// Scan the group's messages, reacting to (a) missions addressed to this
    /// character and (b) success replies for missions this character fired.
    /// Recognition is (signed author device, exact template text); dedup is
    /// by operation hash, so re-scans and restarts are harmless.
    async fn process_group_messages(
        &mut self,
        group: dashchat_node::ChatId,
        key: &str,
    ) -> Result<()> {
        let my_device = self.bundle.device_id()?;
        let authors = self.node.op_store.get_authors(group.into()).await?;
        let ops = self
            .node
            .op_store
            .get_interleaved_logs(group.into(), authors.into_iter().collect())
            .await?;

        let mut dirty = false;
        let mut replies: Vec<String> = Vec::new();
        for (header, payload) in ops {
            let Some(Payload::Chat(ChatPayload::Message(content))) = payload else {
                continue;
            };
            let author = dashchat_node::DeviceId::from(header.verifying_key);
            if author == my_device {
                continue;
            }
            let Some(author_character) = self.cast.character_of_device(&author) else {
                continue; // a player, not a cast bot
            };
            let author_character = author_character.to_string();
            let op_hash = hex::encode(header.hash().as_bytes());
            let text = content.message().to_string();

            // (a) A mission addressed to me → success-reply exactly once.
            if let Some(mission) = self.scenarios.mission_by_text(&author_character, &text) {
                if mission.to == self.bundle.character && !self.state.acked.contains(&op_hash) {
                    info!(from = %author_character, "mission received, acking");
                    replies.push(mission.success.clone());
                    self.state.acked.insert(op_hash.clone());
                    dirty = true;
                }
                continue;
            }

            // (b) A success reply from the recipient of one of my missions.
            if !self.state.delivered_ops.contains(&op_hash) {
                if let Some(fired) = self.state.fired.get_mut(key) {
                    if let Some(mission) = fired
                        .iter_mut()
                        .find(|m| !m.delivered && m.to == author_character && m.success == text)
                    {
                        info!(to = %author_character, "mission delivered");
                        mission.delivered = true;
                        self.state.delivered_ops.insert(op_hash.clone());
                        dirty = true;
                    }
                }
            }
        }
        for reply in replies {
            self.node.send_message(group, reply, None).await?;
        }
        if dirty {
            self.state.save(&self.state_path)?;
        }
        Ok(())
    }

    async fn maybe_fire_mission(
        &mut self,
        group: dashchat_node::ChatId,
        key: &str,
    ) -> Result<()> {
        let due = self
            .next_fire
            .entry(key.to_string())
            .or_insert_with(|| {
                // Restart: don't fire instantly, draw a fresh interval.
                Instant::now() + rand_interval(&self.timing)
            });
        if Instant::now() < *due {
            return Ok(());
        }
        if self.state.outstanding(key) >= self.timing.max_outstanding {
            // Paused: check again next tick without redrawing the interval.
            return Ok(());
        }
        let Some(mission) = self.pick_mission(key) else {
            return Ok(());
        };
        info!(to = %mission.to, group = %key, "firing mission");
        self.node
            .send_message(group, mission.text.clone(), None)
            .await?;
        self.state.fired.entry(key.to_string()).or_default().push(FiredMission {
            to: mission.to,
            text: mission.text,
            success: mission.success,
            delivered: false,
        });
        self.state.save(&self.state_path)?;
        let next = self.draw_next_fire();
        self.next_fire.insert(key.to_string(), next);
        Ok(())
    }

    /// Prefer templates never fired in this group; once exhausted, allow
    /// re-firing delivered ones (never ones still outstanding — their success
    /// lines must stay unambiguous).
    fn pick_mission(&self, group: &str) -> Option<crate::scenario::Mission> {
        let pack = self.scenarios.pack(&self.bundle.character)?;
        let fired = self.state.fired.get(group);
        let fired_texts: Vec<&str> = fired
            .map(|v| v.iter().map(|m| m.text.as_str()).collect())
            .unwrap_or_default();
        let outstanding_texts: Vec<&str> = fired
            .map(|v| {
                v.iter()
                    .filter(|m| !m.delivered)
                    .map(|m| m.text.as_str())
                    .collect()
            })
            .unwrap_or_default();

        let unused: Vec<&crate::scenario::Mission> = pack
            .missions
            .iter()
            .filter(|m| !fired_texts.contains(&m.text.as_str()))
            .collect();
        let candidates = if unused.is_empty() {
            pack.missions
                .iter()
                .filter(|m| !outstanding_texts.contains(&m.text.as_str()))
                .collect::<Vec<_>>()
        } else {
            unused
        };
        if candidates.is_empty() {
            return None;
        }
        let idx = rand::thread_rng().gen_range(0..candidates.len());
        Some(candidates[idx].clone())
    }

    fn draw_next_fire(&self) -> Instant {
        Instant::now() + rand_interval(&self.timing)
    }
}

fn rand_interval(timing: &Timing) -> Duration {
    let secs =
        rand::thread_rng().gen_range(timing.min_interval_secs..=timing.max_interval_secs.max(timing.min_interval_secs));
    Duration::from_secs(secs)
}
