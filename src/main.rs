use anyhow::{Result, bail};
use axum::{Json, Router, routing::post};
use k8s_openapi::api::networking::v1::IngressLoadBalancerStatus;
use kube::core::conversion::{ConversionRequest, ConversionResponse, ConversionReview};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{Error, ErrorKind};
use tracing::{error, info};

#[tokio::main]
async fn main() {
    info!("Good morning, Nais!");

    let app = Router::new().route("/convert", post(convert));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

/// convert is only for aivenapplications.aiven.nais.io/v1 to v2
async fn convert(Json(payload): Json<ConversionRequest>) -> anyhow::Result<ConversionResponse> {
    info!("Time to check the log");

    let desired_version = &payload.desired_api_version;

    if desired_version != "aivenapplications.aiven.nais.io/v2" {
        bail!("migration target")
    }

    let request_uid = &payload.uid;
    let mut p = payload.clone();
    let obj = p
        .objects
        .iter_mut()
        .map(|x| drop_spec_secret(x))
        .collect::<Vec<_>>();
    let converted_objs = match desired_version.as_str() {
        "v2" => p
            .objects
            .iter_mut()
            .map(|x| drop_spec_secret(x))
            .collect::<Vec<_>>(),
        _ => bail!("migration target"),
    };
    let response = todo!();
    todo!()
}

fn conversion_response(list: Vec<serde_json::Value>, uid: &str) -> ConversionResponse {
    ConversionResponse {
        types: None,
        uid: uid.to_owned(),
        result: kube::client::Status {
            status: None,
            code: 0,
            message: todo!(),
            reason: todo!(),
            details: todo!(),
        },
        converted_objects: list,
    }
}

fn drop_spec_secret(mut value: &Value) -> Result<Value> {
    let mut v = value.clone();

    if let Some(api_version) = v.get_mut("apiVersion") {
        if api_version != "v1" {
            bail!("not a v1");
        }
    }

    if let Some(spec) = v.get_mut("spec") {
        let Some(spec_obj) = spec.as_object_mut() else {
            bail!("spec is not an object");
        };

        if let Some(secret_val) = spec_obj.remove("secretName") {
            match spec_obj.get_mut("kafka") {
                None => {
                    let mut kafka_obj = serde_json::Map::new();
                    kafka_obj.insert("secretName".to_owned(), secret_val);
                    spec_obj.insert("kafka".to_owned(), Value::Object(kafka_obj));
                }
                Some(kafka) => {
                    let Some(kafka_obj) = kafka.as_object_mut() else {
                        bail!("spec.kafka is not an object");
                    };
                    kafka_obj.insert("secretName".to_owned(), secret_val);
                }
            }
        }
    }
    Ok(v.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result;
    use serde_json::json;
    #[test]
    fn test_removes_secretName_and_moves_to_kafka() -> Result<()> {
        let value = json!({
            "apiVersion": "v1",
            "spec": {
                "secretName": "supersecret",
                "kafka": {}
            }
        });

        let result = drop_spec_secret(&value)?;
        assert!(result["spec"].get("secretName").is_none());
        assert_eq!(result["spec"]["kafka"]["secretName"], "supersecret");
        Ok(())
    }

    #[test]
    fn test_creates_kafka_if_missing() -> Result<()> {
        let value = json!({
            "apiVersion": "v1",
            "spec": {
                "secretName": "topsecret"
            }
        });

        let result = drop_spec_secret(&value)?;
        assert!(result["spec"].get("secretName").is_none());
        assert_eq!(result["spec"]["kafka"]["secretName"], "topsecret");
        Ok(())
    }

    #[test]
    fn test_leaves_kafka_unchanged_if_secretName_missing() -> Result<()> {
        let value = json!({
            "apiVersion": "v1",
            "spec": {
                "kafka": {
                    "exists": true
                }
            }
        });

        let result = drop_spec_secret(&value)?;
        assert!(result["spec"].get("secretName").is_none());
        assert_eq!(result["spec"]["kafka"]["exists"], true);
        Ok(())
    }

    #[test]
    fn test_fails_if_spec_is_not_object() {
        let value = json!({
            "apiVersion": "v1",
            "spec": "should_be_an_object"
        });
        let result = drop_spec_secret(&value);
        assert!(result.is_err());
    }

    #[test]
    fn test_fails_if_kafka_is_not_object() {
        let value = json!({
            "apiVersion": "v1",
            "spec": {
                "secretName": "s",
                "kafka": "bad"
            }
        });
        let result = drop_spec_secret(&value);
        assert!(result.is_err());
    }

    #[test]
    fn test_fails_on_wrong_api_version() {
        let value = json!({
            "apiVersion": "v2",
            "spec": {
                "secretName": "test"
            }
        });
        let result = drop_spec_secret(&value);
        assert!(result.is_err());
    }

    #[test]
    fn test_handles_no_spec_gracefully() -> Result<()> {
        let value = json!({
            "apiVersion": "v1",
        });

        let result = drop_spec_secret(&value)?;
        assert!(result.get("spec").is_none());
        Ok(())
    }
}
