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
    dnsnames = [
      "${release.name}-webhook.${release.namespace}.svc"
      "${release.name}-webhook.${release.namespace}.svc.cluster.local"
    ];
    issuerRef = {
      kind = "Issuer";
      name = "${release.name}-selfsigned-issuer";
    };
    secretname = "${release.name}-webhook";
  };
} extraConfig
