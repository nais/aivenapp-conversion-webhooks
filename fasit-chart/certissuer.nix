{
  lib,
  release,
  extraConfig,
}:
lib.recursiveUpdate {
  apiVersion = "cert-manager.io/v1";
  kind = "Issuer";
  metadata = {
    name = "${release.name}-selfsigned-issuer";
    labels.app = release.name;
  };
  spec.selfSigned = { };
} extraConfig
