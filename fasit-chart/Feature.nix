_: {
  dependencies = [
    {
      allOf = [
        "nais-crds"
        "aivenator"
      ];
    }
  ];

  environmentKinds = [
    "tenant"
    "onprem"
    "legacy"
  ];

  values = { };
}
