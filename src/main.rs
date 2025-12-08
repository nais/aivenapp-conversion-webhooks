use std::{env, io::IsTerminal, net::SocketAddr, time::Duration};

use anyhow::{Context, Result, bail};
use axum::{
    Json, Router,
    routing::{get, post},
};
use axum_otel_metrics::HttpMetricsLayerBuilder;
use axum_server::Handle;
use axum_server::tls_rustls::RustlsConfig;
use kube::core::Status as KubeStatus;
use kube::core::conversion::{ConversionRequest, ConversionResponse, ConversionReview};
use opentelemetry::global;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::metrics::{PeriodicReader, SdkMeterProvider, Temporality};
use serde_json::{Map, Value};
use tokio::signal;
use tracing::{debug, error, info, metadata::LevelFilter, warn};
use tracing_subscriber::{
    EnvFilter, Registry, filter, prelude::__tracing_subscriber_SubscriberExt,
    util::SubscriberInitExt,
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

fn init_metrics() {
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

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing_subscriber()?;
    init_metrics();
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
        .route("/convert", post(convert))
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

/// this is only for v1-v2 for aivenapps
async fn convert(Json(review): Json<ConversionReview>) -> Json<ConversionReview> {
    info!("received ConversionReview");
    debug!("{review:?}");
    let request = match ConversionRequest::from_review(review) {
        Ok(r) => r,
        Err(e) => {
            error!("{e:?}");
            let status =
                KubeStatus::failure("request missing in ConversionReview", "InvalidRequest");
            return Json(ConversionResponse::invalid(status).into_review());
        }
    };

    // only supports converting TO v2
    let desired = request.desired_api_version.clone();
    let response = match desired.as_str() {
        "aiven.nais.io/v1" => to_v1(request.clone()),
        "aiven.nais.io/v2" => to_v2(request.clone()),
        _ => {
            let status = KubeStatus::failure(
                &format!("unsupported conversion target: {desired}"),
                "UnsupportedTarget",
            );
            return Json(
                ConversionResponse::for_request(request)
                    .failure(status)
                    .into_review(),
            );
        }
    };

    match response {
        Ok(result) => Json(result),
        Err(error) => Json(
            ConversionResponse::for_request(request)
                .failure(KubeStatus::failure(
                    "Failed conversion",
                    error.to_string().as_str(),
                ))
                .into_review(),
        ),
    }
}

fn to_v1(req: ConversionRequest) -> Result<ConversionReview> {
    let converted_objects = req
        .objects
        .clone()
        .into_iter()
        .map(|mut object| {
            let Some(obj) = object.as_object_mut() else {
                bail!("Object is not a JSON object");
            };

            let Some(old_api_version) = obj
                .get("apiVersion")
                .and_then(|version_obj| version_obj.as_str())
            else {
                bail!("apiVersion string not json parsable");
            };

            let converted_obj = match old_api_version {
                "aiven.nais.io/v1" | "aiven.nais.io/v2" => obj, // v2->v1 is backwards compatible
                _ => bail!("Unhandled `apiVersion`: {old_api_version}"),
            };

            let mut converted_obj = converted_obj.clone();
            converted_obj.insert(
                "apiVersion".to_string(),
                Value::String(req.desired_api_version.clone()),
            );

            Ok(Value::Object(converted_obj))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(ConversionResponse::for_request(req)
        .success(converted_objects)
        .into_review())
}

fn to_v2(req: ConversionRequest) -> Result<ConversionReview> {
    let converted_objects = req
        .objects
        .clone()
        .into_iter()
        .map(|mut object| {
            let Some(obj) = object.as_object_mut() else {
                bail!("Object is not a JSON object");
            };

            let Some(old_api_version) = obj
                .get("apiVersion")
                .and_then(|version_obj| version_obj.as_str())
            else {
                bail!("apiVersion string not json parsable");
            };

            let converted_obj = match old_api_version {
                "aiven.nais.io/v1" => drop_spec_secret(obj)?,
                "aiven.nais.io/v2" => obj.clone(),
                _ => bail!("Unhandled `apiVersion`: {old_api_version}"),
            };

            let mut converted_obj = converted_obj;
            converted_obj.insert(
                "apiVersion".to_string(),
                Value::String(req.desired_api_version.clone()),
            );

            Ok(converted_obj.into())
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(ConversionResponse::for_request(req)
        .success(converted_objects)
        .into_review())
}

fn drop_spec_secret(object: &mut Map<String, Value>) -> Result<Map<String, Value>> {
    let Some(spec) = object
        .get_mut("spec")
        .and_then(|spec_obj| spec_obj.as_object_mut())
    else {
        bail!("spec is not present in object");
    };

    let Some(secret_name) = spec.remove("secretName") else {
        // No common secret name to care about
        return Ok(object.clone());
    };

    for sub_struct_name in ["openSearch", "kafka"] {
        let Some(sub_struct) = spec
            .get_mut(sub_struct_name)
            .and_then(|ss| ss.as_object_mut())
        else {
            // this object does not contain the struct `spec.<sub_struct_name>`
            continue;
        };

        // only set `secretName` inside the `spec.<sub_struct_name>` if it's missing
        sub_struct
            .entry("secretName".to_owned())
            .or_insert(secret_name.clone());
    }
    Ok(object.clone())
}

#[cfg(test)]
mod conversion {
    use super::*;
    use anyhow::Result;
    use serde_json::json;
    #[test]
    fn removes_secret_name_and_moves_to_kafka() -> Result<()> {
        let mut json_value = json!({
            "apiVersion": "v1",
            "spec": {
                "secretName": "supersecret",
                "kafka": {}
            }
        });
        let value = json_value.as_object_mut().unwrap();

        let result = drop_spec_secret(value)?;
        assert!(result["spec"].get("secretName").is_none());
        assert_eq!(result["spec"]["kafka"]["secretName"], "supersecret");
        Ok(())
    }

    #[test]
    fn drops_secret_when_kafka_missing() -> Result<()> {
        let mut json_value = json!({
            "apiVersion": "v1",
            "spec": {
                "secretName": "supersecret",
            }
        });
        let value = json_value.as_object_mut().unwrap();

        let result = drop_spec_secret(value)?;
        assert!(result["spec"].get("secretName").is_none());
        // should NOT create kafka when it wasn't present
        assert!(result["spec"].get("kafka").is_none());
        Ok(())
    }

    #[test]
    fn leaves_kafka_unchanged_if_secret_name_missing() -> Result<()> {
        let mut json_value = json!({
            "apiVersion": "v1",
            "spec": {
                "kafka": {
                    // V this is a low fidelity repr of the kafka bits.
                    "heresafield": true
                }
            }
        });
        let value = json_value.as_object_mut().unwrap();

        let result = drop_spec_secret(value)?;
        assert!(result["spec"].get("secretName").is_none());
        assert_eq!(result["spec"]["kafka"]["heresafield"], true);
        Ok(())
    }

    #[test]
    fn v1_to_v2() -> Result<()> {
        let data = include_str!("../golden/conversionreview.json");
        let review: ConversionReview = serde_json::from_str(data)?;
        let req = ConversionRequest::from_review(review).expect("valid ConversionReview");

        let converted_review = to_v2(req)?;
        let response = converted_review
            .response
            .expect("conversion response must be present");
        assert_eq!(response.converted_objects.len(), 1);
        let converted = &response.converted_objects[0];
        assert!(converted["spec"].get("secretName").is_none());
        assert_eq!(converted["spec"]["kafka"]["secretName"], "fooobar");
        Ok(())
    }
}
