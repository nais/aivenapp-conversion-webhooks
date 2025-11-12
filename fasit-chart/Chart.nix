{
  version ? "invalid",
  ...
}:
{
  inherit version;
  apiVersion = "v2";
  name = "aiven-conversion-webhooks";
  description = "Install conversion webhooks for aivenapp versions";
  sources = [
    "https://github.com/nais/aiven-conversion-webhooks/tree/main/fasit-chart"
  ];
  type = "application";
}
