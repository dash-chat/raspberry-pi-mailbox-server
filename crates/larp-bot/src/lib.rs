//! LARP character bot: a headless Dash Chat node that plays one of the
//! earthquake-scenario characters (see docs/larp-design.md).
//!
//! Identity is not generated on the device: it comes from a flashable
//! *identity bundle* (`larp-identity.toml`) so that re-flashing an SD card or
//! wiping the data dir never invalidates the printed QR posters.

pub mod bot;
pub mod cast;
pub mod config;
pub mod identity;
pub mod qr;
pub mod scenario;
