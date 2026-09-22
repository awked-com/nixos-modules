{ config, lib, ... }:

let
  credentialSources =
    service:
    lib.concatMap (
      credential:
      let
        source = builtins.match "[^:]+:(/.*)" credential;
      in
      lib.optional (source != null) (builtins.head source)
    ) (lib.toList (service.serviceConfig.LoadCredential or [ ]));
  serviceCredentials = lib.mapAttrs (_: credentialSources) (
    lib.filterAttrs (_: service: service.enable) config.systemd.services
  );
  consumers =
    path:
    lib.mapAttrsToList (name: _: "${name}.service") (
      lib.filterAttrs (_: sources: builtins.elem path sources) serviceCredentials
    );
  restartConsumers = { config, ... }: {
    # LoadCredential snapshots change only on restart.
    config.restartUnits = lib.mkDefault (consumers config.path);
  };
in
{
  options.sops = {
    secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule restartConsumers);
    };
    templates = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule restartConsumers);
    };
  };
}
