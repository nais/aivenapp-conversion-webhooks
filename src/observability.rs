use std::{env, io::IsTerminal, time::Duration};

use anyhow::Result;
use opentelemetry::global;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::metrics::{PeriodicReader, SdkMeterProvider, Temporality};
use tracing::{info, metadata::LevelFilter, warn};
use tracing_subscriber::{
    filter, prelude::__tracing_subscriber_SubscriberExt, util::SubscriberInitExt, EnvFilter,
    Registry,
};

/// Initialize the tracing subscriber used by this binary.
///
/// # Errors
///
/// Returns an error if installing the tracing subscriber fails.
pub fn init_tracing_subscriber() -> Result<()> {
    use tracing_subscriber::fmt as layer_fmt;

    let (we_shall_not_json, we_shall_json) = if std::io::stdout().is_terminal() {
        (Some(layer_fmt::layer().compact()), None)
    } else {
        (None, Some(layer_fmt::layer().json().flatten_event(true)))
    };

    let env_filter = EnvFilter::builder()
        .with_default_directive(LevelFilter::INFO.into())
        .from_env();
    let (we_got_valid_log_env, we_got_no_valid_log_env) = env_filter.map_or_else(
        |_| {
            (
                None,
                Some(filter::Targets::new().with_default(LevelFilter::INFO)),
            )
        },
        |log_level| (Some(log_level), None),
    );
    Registry::default()
        .with(we_shall_not_json)
        .with(we_shall_json)
        .with(we_got_valid_log_env)
        .with(we_got_no_valid_log_env)
        .try_init()?;

    // This check is down here because log framework gets set/configured first in previous statement
    if let Ok(log_value) = env::var("RUST_LOG") {
        let rust_log_set_to_invalid_syntax = EnvFilter::try_from_default_env().is_err();
        if rust_log_set_to_invalid_syntax {
            warn!("Invalid syntax in found env var `RUST_LOG`: {}", log_value);
        }
    }

    Ok(())
}

pub fn init_metrics() {
    // Only configure OTLP metrics if an endpoint is provided.
    let endpoint = match env::var("OTEL_EXPORTER_OTLP_ENDPOINT") {
        Ok(v) if !v.is_empty() => v,
        _ => {
            info!(
                "OTEL_EXPORTER_OTLP_ENDPOINT not set; HTTP metrics will be recorded but not exported"
            );
            return;
        }
    };

    info!(%endpoint, "initializing OTLP metrics exporter");

    let exporter = match opentelemetry_otlp::MetricExporter::builder()
        .with_http()
        .with_endpoint(endpoint)
        .with_temporality(Temporality::default())
        .build()
    {
        Ok(exp) => exp,
        Err(err) => {
            warn!(%err, "failed to build OTLP metrics exporter; metrics will not be exported");
            return;
        }
    };

    let reader = PeriodicReader::builder(exporter)
        .with_interval(Duration::from_secs(30))
        .build();

    let provider = SdkMeterProvider::builder().with_reader(reader).build();
    global::set_meter_provider(provider);
}

