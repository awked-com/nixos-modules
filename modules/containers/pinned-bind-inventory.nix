{ lib, ... }:
{
  options.services.pinned-bind-sources.inventory = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    internal = true;
    description = "Original host paths behind pinned container bind mounts for storage auditing";
  };
}
