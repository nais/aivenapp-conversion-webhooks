use std::{env, io::IsTerminal, net::SocketAddr};

use anyhow::{Result, bail};
use axum::{
    Json, Router,
    routing::{get, post},
};
use axum_server::tls_rustls::RustlsConfig;
use kube::core::Status as KubeStatus;
use kube::core::conversion::{ConversionRequest, ConversionResponse, ConversionReview};
use serde_json::Value;
use tracing::{debug, error, info, metadata::LevelFilter, warn};
use tracing_subscriber::{
    EnvFilter, Registry, filter, prelude::__tracing_subscriber_SubscriberExt,
    util::SubscriberInitExt,
};

/* Todos

[x] Use tls certs from cert manager
[x] have a tls cert integration test
[x] nix docker -> Ci
[x] fasit feature
metrics
traces
signal handling -> graceful shutudown

 */

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

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing_subscriber()?;
    info!("starting app");
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install rustls crypto provider");

    info!("finding certs");

    let cert_path = env::var("TLS_CERT_FILE").unwrap_or_else(|_| "/app/tls.crt".to_string());
    let key_path = env::var("TLS_KEY_FILE").unwrap_or_else(|_| "/app/tls.key".to_string());
    info!(cert_path = %cert_path, key_path = %key_path, "using TLS certs");
    let config = RustlsConfig::from_pem_file(cert_path, key_path)
        .await
        .expect("certs");

    let app = Router::new()
        .route("/convert", post(convert))
        .route("/health", get(health))
        .route("/ready", get(ready));

    info!("starting webserver");
    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    axum_server::bind_rustls(addr, config)
        .serve(app.into_make_service())
        .await?;

    Ok(())
}

async fn health() -> &'static str {
    "ok"
}

async fn ready() -> &'static str {
    "ok"
}

/// this is only for v1-v2 for aivenapps
async fn convert(Json(review): Json<ConversionReview>) -> Json<ConversionReview> {
    info!("received ConversionReview");
    debug!("{review:?}");
    let request = match ConversionRequest::from_review(review.clone()) {
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
        "aiven.nais.io/v1" => to_v1(request),
        "aiven.nais.io/v2" => to_v2(request),
        _ => {
            let status = KubeStatus::failure(
                &format!("unsupported conversion target: {desired}"),
                "UnsupportedTarget",
            );
            let response = ConversionResponse::for_request(request)
                .failure(status)
                .into_review();
            return Json(response);
        }
    };

    return axum::Json(response.expect("`ConversionResponse` should always be json parsable"));
}

fn to_v1(req: ConversionRequest) -> Result<ConversionReview> {
    let mut req = req.clone();
    let objects = std::mem::take(&mut req.objects);
    let converted = objects
        .into_iter()
        .map(|mut v| {
            if let Some(obj) = v.as_object_mut() {
                obj.insert(
                    "apiVersion".to_string(),
                    Value::String(req.desired_api_version.clone()),
                );
                Ok(v)
            } else {
                bail!("object is not a JSON object");
            }
        })
        .collect::<anyhow::Result<Vec<_>>>();

    match converted {
        Ok(list) => Ok(ConversionResponse::for_request(req)
            .success(list)
            .into_review()),
        Err(e) => {
            error!("{e:?}");
            let status =
                KubeStatus::failure(&format!("conversion failed: {e}"), "ConversionFailed");

            Ok(ConversionResponse::for_request(req)
                .failure(status)
                .into_review())
        }
    }
}

fn to_v2(req: ConversionRequest) -> Result<ConversionReview> {
    let mut req = req.clone();

    /* NB!! this is cool actually, this lets us get the objects and we replace the old objects with an empty vec and now suddenly we dont have to worry about partial ownershit           */
    let objects = std::mem::take(&mut req.objects);
    let converted = objects
        .into_iter()
        .map(|v| {
            let mut v = drop_spec_secret(v)?;
            if let Some(obj) = v.as_object_mut() {
                obj.insert(
                    "apiVersion".to_string(),
                    Value::String(req.desired_api_version.clone()),
                );
                Ok(v)
            } else {
                bail!("object is not a JSON object");
            }
        })
        .collect::<anyhow::Result<Vec<_>>>();

    match converted {
        Ok(list) => Ok(ConversionResponse::for_request(req)
            .success(list)
            .into_review()),
        Err(e) => {
            error!("{e:?}");
            let status =
                KubeStatus::failure(&format!("conversion failed: {e}"), "ConversionFailed");

            Ok(ConversionResponse::for_request(req)
                .failure(status)
                .into_review())
        }
    }
}

fn drop_spec_secret(mut v: Value) -> Result<Value> {
    if let Some(spec) = v.get_mut("spec") {
        let Some(spec_obj) = spec.as_object_mut() else {
            bail!("spec is not an object");
        };

        if let Some(secret_val) = spec_obj.remove("secretName") {
            // At time of writing only v1's left w/spec.secretName are those that should move `secretName` under spec.kafka
            if let Some(kafka) = spec_obj.get_mut("kafka") {
                let Some(kafka_obj) = kafka.as_object_mut() else {
                    bail!("spec.kafka is not an object");
                };
                // only set secretName inside kafka if it's missing
                kafka_obj
                    .entry("secretName".to_owned())
                    .or_insert(secret_val);
            }
        }
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result;
    use serde_json::json;
    #[test]
    fn test_removes_secret_name_and_moves_to_kafka() -> Result<()> {
        let value = json!({
            "apiVersion": "v1",
            "spec": {
                "secretName": "supersecret",
                "kafka": {}
            }
        });

        let result = drop_spec_secret(value)?;
        assert!(result["spec"].get("secretName").is_none());
        assert_eq!(result["spec"]["kafka"]["secretName"], "supersecret");
        Ok(())
    }

    #[test]
    fn test_drops_secret_when_kafka_missing() -> Result<()> {
        let value = json!({
            "apiVersion": "v1",
            "spec": {
                "secretName": "topsecret"
            }
        });

        let result = drop_spec_secret(value)?;
        assert!(result["spec"].get("secretName").is_none());
        // should NOT create kafka when it wasn't present
        assert!(result["spec"].get("kafka").is_none());
        Ok(())
    }

    #[test]
    fn test_leaves_kafka_unchanged_if_secret_name_missing() -> Result<()> {
        let value = json!({
            "apiVersion": "v1",
            "spec": {
                "kafka": {
                    // V this is a low fidelity repr of the kafka bits.
                    "heresafield": true
                }
            }
        });

        let result = drop_spec_secret(value)?;
        assert!(result["spec"].get("secretName").is_none());
        assert_eq!(result["spec"]["kafka"]["heresafield"], true);
        Ok(())
    }

    #[test]
    fn test_fails_on_wrong_api_version() {
        let value = json!({
            "apiVersion": "v2",
            "spec": {
                "secretName": "test"
            }
        });
        let result = drop_spec_secret(value);
        assert!(result.is_err());
    }

    #[test]
    fn test_conversion() -> Result<()> {
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
