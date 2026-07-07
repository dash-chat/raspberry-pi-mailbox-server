//! Milestone-1 end-to-end test (docs/larp-design.md §8):
//! two player nodes + two character bots share one in-memory mailbox.
//!
//! Phase 1: pair contact, poster-QR onboarding, group creation, greetings.
//! Phase 2: a mission fires, the recipient bot acks, the origin marks it
//!          delivered.
//! Phase 3: wipe the firefighters bot's data dir, restart it from the same
//!          identity bundle, and prove the *same printed QR string* still
//!          onboards a new player into a new group.

use std::collections::BTreeMap;
use std::time::Duration;

use dashchat_node::testing::{TestMailbox, TestNode};
use dashchat_node::{NodeConfig, ShareIntent};
use p2panda_auth::Access;

use larp_bot::bot::{Bot, BotState, build_node};
use larp_bot::cast::Cast;
use larp_bot::config::Timing;
use larp_bot::identity::IdentityBundle;
use larp_bot::qr;
use larp_bot::scenario::{Mission, Pack, Scenarios};

const FF_MISSION: &str = "FF-MISSION-1: smoke on Main Street, carry this to the hospital!";
const FF_SUCCESS: &str = "HOSP-ACK-1: received, ambulances rolling.";
const HOSP_MISSION: &str = "HOSP-MISSION-1: trapped person reported, carry this to the firefighters!";
const HOSP_SUCCESS: &str = "FF-ACK-1: rescue crew dispatched.";

fn test_scenarios() -> Scenarios {
    let mut packs = BTreeMap::new();
    packs.insert(
        "firefighters".to_string(),
        Pack {
            name: "Firefighters".into(),
            greeting: "FF-GREETING: fire station online.".into(),
            missions: vec![Mission {
                to: "hospital".into(),
                text: FF_MISSION.into(),
                success: FF_SUCCESS.into(),
            }],
        },
    );
    packs.insert(
        "hospital".to_string(),
        Pack {
            name: "Hospital".into(),
            greeting: "HOSP-GREETING: hospital online.".into(),
            missions: vec![Mission {
                to: "firefighters".into(),
                text: HOSP_MISSION.into(),
                success: HOSP_SUCCESS.into(),
            }],
        },
    );
    let scenarios = Scenarios { packs };
    scenarios.lint().unwrap();
    scenarios
}

/// Hermetic node config: no p2p, no mDNS, no relay, no blobs. Everything
/// flows through the shared in-memory mailbox — deterministic, and keeps the
/// test off the real internet relay.
fn test_node_config() -> NodeConfig {
    NodeConfig::testing().no_p2p().no_blob_sync()
}

fn fast_timing() -> Timing {
    Timing {
        min_interval_secs: 1,
        max_interval_secs: 2,
        max_outstanding: 3,
        poll_interval_secs: 1,
    }
}

/// Poll `f` until it returns true or the timeout elapses.
async fn wait_until<F, Fut>(what: &str, timeout: Duration, mut f: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if f().await {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for: {what}"
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

async fn messages_of(node: &TestNode, chat: dashchat_node::ChatId) -> Vec<String> {
    node.get_messages(chat)
        .await
        .map(|msgs| {
            msgs.iter()
                .map(|m| m.content.message().to_string())
                .collect()
        })
        .unwrap_or_default()
}

struct RunningBot {
    node: dashchat_node::Node,
    task: tokio::task::JoinHandle<anyhow::Result<()>>,
}

async fn start_bot(
    data_dir: &std::path::Path,
    bundle: &IdentityBundle,
    cast: &Cast,
    mailbox: &TestMailbox,
) -> RunningBot {
    let (node, rx) = build_node(data_dir, bundle, test_node_config())
        .await
        .expect("bot node builds");
    mailbox.register_on(&node).await;
    let bot = Bot::new(
        node.clone(),
        bundle.clone(),
        cast.resolve().unwrap(),
        test_scenarios(),
        fast_timing(),
        data_dir.join("state.json"),
    )
    .expect("bot constructs");
    let task = tokio::spawn(bot.run_loop(rx));
    RunningBot { node, task }
}

#[tokio::test(flavor = "multi_thread")]
async fn mission_ack_roundtrip_and_wipe_survival() {
    dashchat_node::testing::setup_tracing(&["info"], false);
    let mailbox = TestMailbox::from_env();

    // --- The cast: two characters, generated offline like `larp-bot keygen`.
    let ff_bundle = IdentityBundle::generate("firefighters");
    let hosp_bundle = IdentityBundle::generate("hospital");
    let mut cast = Cast::default();
    cast.characters
        .insert("firefighters".into(), ff_bundle.cast_entry().unwrap());
    cast.characters
        .insert("hospital".into(), hosp_bundle.cast_entry().unwrap());

    // The printed wall posters (QR strings), rendered before any node exists.
    let ff_poster = qr::encode_contact_code(&ff_bundle.qr_code().unwrap()).unwrap();
    let hosp_poster = qr::encode_contact_code(&hosp_bundle.qr_code().unwrap()).unwrap();

    // --- Stations come up.
    let ff_dir = tempfile::tempdir().unwrap();
    let hosp_dir = tempfile::tempdir().unwrap();
    let ff_bot = start_bot(ff_dir.path(), &ff_bundle, &cast, &mailbox).await;
    let _hosp_bot = start_bot(hosp_dir.path(), &hosp_bundle, &cast, &mailbox).await;

    // --- The players arrive and pair up.
    let p1 = TestNode::new(test_node_config(), "p1").await;
    p1.add_mailbox(&mailbox).await;
    let p2 = TestNode::new(test_node_config(), "p2").await;
    p2.add_mailbox(&mailbox).await;
    p1.behavior()
        .initiate_and_establish_contact(&p2, ShareIntent::AddContact)
        .await
        .expect("players establish contact");

    // --- Players scan the wall posters.
    let ff_device = ff_bundle.device_id().unwrap();
    let hosp_device = hosp_bundle.device_id().unwrap();
    p1.add_contact(qr::decode_contact_code(&ff_poster).unwrap())
        .await
        .expect("p1 adds firefighters");
    p1.add_contact(qr::decode_contact_code(&hosp_poster).unwrap())
        .await
        .expect("p1 adds hospital");
    // The bots' capability announcements arriving at p1 proves the contact
    // handshake completed on the bot side.
    p1.behavior()
        .await_first_capabilities(ff_device)
        .await
        .expect("firefighters bot accepted p1");
    p1.behavior()
        .await_first_capabilities(hosp_device)
        .await
        .expect("hospital bot accepted p1");

    // --- p1 creates the group: pair + both characters.
    let mut members: BTreeMap<p2panda::VerifyingKey, Access> = BTreeMap::new();
    members.insert(*p2.device_id(), Access::write());
    members.insert(*ff_device, Access::write());
    members.insert(*hosp_device, Access::write());
    let chat_id = p1.create_group(members).await.expect("group created");

    // --- Phase 1: both bots join and greet.
    wait_until("both bots greet the group", Duration::from_secs(60), || async {
        let texts = messages_of(&p1, chat_id).await;
        texts.iter().any(|t| t.contains("FF-GREETING"))
            && texts.iter().any(|t| t.contains("HOSP-GREETING"))
    })
    .await;

    // --- Phase 2: missions fire and get acked (transport is the shared
    // mailbox; the courier walk is exercised in the field, not here).
    wait_until("mission fired and acked", Duration::from_secs(90), || async {
        let texts = messages_of(&p1, chat_id).await;
        texts.iter().any(|t| t == FF_MISSION) && texts.iter().any(|t| t == FF_SUCCESS)
    })
    .await;

    // The origin bot must have marked the mission delivered in its state file.
    wait_until("origin marks delivered", Duration::from_secs(30), || async {
        let state = BotState::load(&ff_dir.path().join("state.json"));
        state
            .fired
            .get(&chat_id.to_string())
            .map(|missions| missions.iter().any(|m| m.text == FF_MISSION && m.delivered))
            .unwrap_or(false)
    })
    .await;

    // p2 sees the same conversation through the mailbox.
    wait_until("p2 converges", Duration::from_secs(60), || async {
        let texts = messages_of(&p2, chat_id).await;
        texts.iter().any(|t| t == FF_MISSION) && texts.iter().any(|t| t == FF_SUCCESS)
    })
    .await;

    // --- Phase 3: wipe the firefighters station and restart from the bundle.
    ff_bot.task.abort();
    let _ = ff_bot.task.await;
    ff_bot.node.shutdown().await.expect("ff node shuts down");
    std::fs::remove_dir_all(ff_dir.path()).unwrap();
    std::fs::create_dir_all(ff_dir.path()).unwrap();
    let _ff_bot2 = start_bot(ff_dir.path(), &ff_bundle, &cast, &mailbox).await;

    // The SAME printed poster still onboards a brand-new contact...
    p2.add_contact(qr::decode_contact_code(&ff_poster).unwrap())
        .await
        .expect("p2 adds firefighters after the wipe");
    p2.behavior()
        .await_first_capabilities(ff_device)
        .await
        .expect("rebuilt firefighters bot accepted p2");

    // ...and the character keeps working in a fresh group.
    let mut members: BTreeMap<p2panda::VerifyingKey, Access> = BTreeMap::new();
    members.insert(*ff_device, Access::write());
    let chat2 = p2.create_group(members).await.expect("post-wipe group");
    // Generous: the rebuilt bot first re-syncs the entire pre-wipe history
    // (its sync-tracker watermarks were wiped too) before it gets to chat2.
    wait_until("rebuilt bot greets", Duration::from_secs(180), || async {
        let texts = messages_of(&p2, chat2).await;
        texts.iter().any(|t| t.contains("FF-GREETING"))
    })
    .await;
}
