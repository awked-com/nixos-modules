{
  lib,
  pkgs,
  connectorName ? null,
  framebuffer ? "/sys/class/graphics/fb0/blank",
}:

let
  dpmsGlob =
    if connectorName == null then
      "/sys/class/drm/card*-*/dpms"
    else
      "/sys/class/drm/card*-${lib.escapeShellArg connectorName}/dpms";
in

pkgs.writeShellApplication {
  name = "display-power";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.util-linux
  ];
  text =
    lib.replaceStrings [ "@framebuffer@" "@dpmsGlob@" ] [ (lib.escapeShellArg framebuffer) dpmsGlob ]
      (builtins.readFile ./display-power.sh);
}
