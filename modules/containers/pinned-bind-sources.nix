{ name, sources }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  runtimeDirectory = "container-bind-${name}";
  runtimePath = "/run/${runtimeDirectory}";
  bindings = lib.imap0 (
    index: mountPoint:
    let
      source = sources.${mountPoint};
    in
    {
      inherit mountPoint;
      inherit (source) path;
      target = toString index;
      create = source.create or false;
      uid = if source ? user then config.users.users.${source.user}.uid else null;
      gid = if source ? group then config.users.groups.${source.group}.gid else null;
      mode = source.mode or null;
      isReadOnly = source.isReadOnly or false;
    }
  ) (lib.attrNames sources);
  manifest = pkgs.writeText "${name}-bind-sources.json" (builtins.toJSON bindings);
  helper = "${pkgs.pinned-bind-sources}/bin/pinned-bind-sources";
in
{
  imports = [ ./pinned-bind-inventory.nix ];
  services.pinned-bind-sources.inventory = builtins.listToAttrs (
    map (binding: {
      name = "${runtimePath}/${binding.target}";
      value = binding.path;
    }) bindings
  );

  # Re-resolving writable ancestors after validation would race path replacement.
  containers.${name}.bindMounts = lib.listToAttrs (
    map (binding: {
      name = binding.mountPoint;
      value = {
        hostPath = "${runtimePath}/${binding.target}";
        mountPoint = "${binding.mountPoint}:idmap";
        inherit (binding) isReadOnly;
      };
    }) bindings
  );

  systemd.services."container@${name}" = {
    unitConfig.RequiresMountsFor = map (binding: binding.path) bindings;
    preStart = lib.mkAfter ''
      install -d -m 0700 -o root -g root ${runtimePath}
      ${helper} pin ${manifest} ${runtimePath}
    '';
    postStop = ''
      ${helper} unpin ${manifest} ${runtimePath}
    '';
  };
}
