{ release, values }:

let
  renderedAnnotations = values.annotations or {};
  renderedLabels = values.labels or {};
  mkAnnotations = attrs: if attrs != {} then { annotations = attrs; } else {};
in {
  issuer = {
    apiVersion = "cert-manager.io/v1";
    kind = "Issuer";
    metadata = (mkAnnotations renderedAnnotations) // {
      name = "${release.Name}-selfsigned-issuer";
      labels = { app = release.Name; } // renderedLabels;
    };
    spec = { selfSigned = {}; };
  };

  cert = {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    metadata = (mkAnnotations renderedAnnotations) // {
      name = "${release.Name}-serving-cert";
      labels = { app = release.Name; } // renderedLabels;
    };
    spec = {
      dnsNames = [
        "${release.Name}-webhook.${release.Namespace}.svc"
        "${release.Name}-webhook.${release.Namespace}.svc.cluster.local"
      ];
      issuerRef = {
        kind = "Issuer";
        name = "${release.Name}-selfsigned-issuer";
      };
      secretName = "${release.Name}-webhook";
    };
  };
}
