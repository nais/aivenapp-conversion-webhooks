{
  version ? "invalid",
  ...
}:
{
  inherit version;
  apiVersion = "v2";
  name = "aivenapp-conversion-webhooks-chart";
  description = "Install conversion webhooks for aivenapp versions";
  sources = [
    "https://github.com/nais/aivenapp-conversion-webhooks/tree/main/fasit-chart"
  ];
  type = "application";
}
