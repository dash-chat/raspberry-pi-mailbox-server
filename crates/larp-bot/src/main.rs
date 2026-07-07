use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

use larp_bot::{cast, config::BotConfig, identity::IdentityBundle, qr};

#[derive(Parser)]
#[command(name = "larp-bot", about = "Dash Chat character bot for the earthquake LARP")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Generate a character's flashable identity bundle (run offline, once).
    Keygen {
        /// Character key, e.g. "firefighters".
        #[arg(long)]
        character: String,
        /// Where to write the bundle (default: ./larp-identity.toml).
        #[arg(long, default_value = "larp-identity.toml")]
        out: PathBuf,
    },
    /// Render a character's contact QR (for the wall posters) from its bundle.
    Qr {
        #[arg(long)]
        identity: PathBuf,
        /// Output PNG path (default: ./qr.png).
        #[arg(long, default_value = "qr.png")]
        out: PathBuf,
        /// Pixels per QR module.
        #[arg(long, default_value_t = 16)]
        module_px: u32,
        /// Also print the raw QR string (and verify it round-trips).
        #[arg(long)]
        print_string: bool,
    },
    /// Assemble the public cast.toml from one or more identity bundles.
    Cast {
        /// Identity bundle paths, one per character.
        #[arg(long, required = true, num_args = 1..)]
        identity: Vec<PathBuf>,
        #[arg(long, default_value = "cast.toml")]
        out: PathBuf,
    },
    /// Run the bot daemon.
    Run {
        #[arg(long, default_value = "/etc/larp-bot/config.toml")]
        config: PathBuf,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    match Cli::parse().command {
        Command::Keygen { character, out } => {
            anyhow::ensure!(!out.exists(), "{} already exists — refusing to overwrite an identity", out.display());
            let bundle = IdentityBundle::generate(&character);
            bundle.save(&out)?;
            println!("wrote {}", out.display());
            println!("\n# cast.toml entry (public — safe to commit):");
            let entry = bundle.cast_entry()?;
            println!("[characters.{character}]");
            print!("{}", toml::to_string_pretty(&entry)?);
        }
        Command::Qr { identity, out, module_px, print_string } => {
            let bundle = IdentityBundle::load(&identity)?;
            let code = qr::encode_contact_code(&bundle.qr_code()?)?;
            // Always verify the string round-trips before it lands on paper.
            let decoded = qr::decode_contact_code(&code).context("QR round-trip check failed")?;
            anyhow::ensure!(decoded == bundle.qr_code()?, "QR round-trip mismatch");
            qr::render_png(&code, &out, module_px)?;
            println!("wrote {} ({})", out.display(), bundle.character);
            if print_string {
                println!("{code}");
            }
        }
        Command::Cast { identity, out } => {
            let mut cast = cast::Cast::default();
            for path in identity {
                let bundle = IdentityBundle::load(&path)?;
                let entry = bundle.cast_entry()?;
                if cast.characters.insert(bundle.character.clone(), entry).is_some() {
                    anyhow::bail!("duplicate character {:?}", bundle.character);
                }
            }
            cast.save(&out)?;
            println!("wrote {} ({} characters)", out.display(), cast.characters.len());
        }
        Command::Run { config } => {
            let config = BotConfig::load(&config)?;
            larp_bot::bot::run(config).await?;
        }
    }
    Ok(())
}
