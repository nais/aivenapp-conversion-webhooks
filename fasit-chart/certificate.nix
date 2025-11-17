{
  lib,
  release,
  extraConfig,
}:
lib.recursiveUpdate {
  apiVersion = "cert-manager.io/v1";
  kind = "Certificate";
  metadata = {
    name = "${release.name}-serving-cert";
    labels.app = release.name;
  };
  spec = {
    dnsNames = [
      "${release.name}-webhook.${release.namespace}.svc"
      "${release.name}-webhook.${release.namespace}.svc.cluster.local"
    ];
    issuerRef = {
      kind = "Issuer";
      name = "${release.name}-selfsigned-issuer";
    };
    secretName = "${release.name}-webhook";
  };
} extraConfig
