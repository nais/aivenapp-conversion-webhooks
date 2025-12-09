use std::{env, net::SocketAddr, time::Duration};

use anyhow::{Context, Result};
use axum::{routing::{get, post}, Router};
use axum_otel_metrics::HttpMetricsLayerBuilder;
use axum_server::tls_rustls::RustlsConfig;
use axum_server::Handle;
use tokio::signal;
use tracing::{error, info};

mod conversion;
mod observability;

#[tokio::main]
async fn main() -> Result<()> {
    observability::init_tracing_subscriber()?;
    observability::init_metrics();
    info!("starting app");
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|e| anyhow::anyhow!("Failed to install rustls crypto provider: {e:?}"))?;

    info!("finding certs");

    let cert_path = env::var("TLS_CERT_FILE").unwrap_or_else(|_| "/app/tls.crt".to_string());
    let key_path = env::var("TLS_KEY_FILE").unwrap_or_else(|_| "/app/tls.key".to_string());
    info!(cert_path = %cert_path, key_path = %key_path, "using TLS certs");
    let config = RustlsConfig::from_pem_file(cert_path, key_path)
        .await
        .context("failed to load TLS certificates")?;

    let metrics_layer = HttpMetricsLayerBuilder::new().build();

    let app = Router::new()
        .route("/convert", post(conversion::convert))
        .route("/health", get(health))
        .route("/ready", get(ready))
        .layer(metrics_layer);

    let handle = Handle::new();

    info!("starting webserver");
    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    let server = axum_server::bind_rustls(addr, config)
        .handle(handle.clone())
        .serve(app.into_make_service());

    let shutdown_handle = handle.clone();
    tokio::spawn(async move {
        let mut sigterm =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(sig) => Some(sig),
                Err(err) => {
                    error!("failed to listen for SIGTERM: {err}");
                    None
                }
            };

        tokio::select! {
            res = signal::ctrl_c() => {
                match res {
                    Ok(()) => info!("SIGINT"),
                    Err(err) => error!("failed to listen for shutdown signal: {err}"),
                }
            }
            () = async {
                if let Some(ref mut sigterm) = sigterm {
                    sigterm.recv().await;
                }
            }, if sigterm.is_some() => {
                info!("SIGTERM");
            }
        }

        shutdown_handle.graceful_shutdown(Some(Duration::from_secs(30)));
    });

    server.await?;

    Ok(())
}

async fn health() -> &'static str {
    "ok"
}
/// These is not real, it should really be unhealthy if the certs are expired
/// However stakater reloads the app and that's what we grind here rather than health/ready
async fn ready() -> &'static str {
    "ok"
}
