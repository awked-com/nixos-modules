{
  config,
  lib,
  pkgs,
}:

let
  cfg = config.services.cast;
  runtimeDirectory = "/run/user/${toString config.users.users.${cfg.user}.uid}";
  gstreamerPluginPath = lib.makeSearchPath "lib/gstreamer-1.0" (
    [
      (lib.getLib pkgs.gst_all_1.gstreamer)
      pkgs.gst_all_1.gst-plugins-base
      pkgs.gst_all_1.gst-plugins-good
      pkgs.gst_all_1.gst-plugins-bad
      pkgs.gst_all_1.gst-libav
    ]
    ++ lib.optional cfg.audio.enable pkgs.pipewire
  );
in
{
  videoSink = lib.concatStringsSep " " (
    [ "kmssink" ]
    ++ lib.optional (cfg.display.driver != null) "driver-name=${cfg.display.driver}"
    ++ lib.optional (cfg.display.connectorId != null) "connector-id=${toString cfg.display.connectorId}"
    ++ lib.optional (cfg.display.planeId != null) "plane-id=${toString cfg.display.planeId}"
  );
  environment = {
    DBUS_SESSION_BUS_ADDRESS = "unix:path=${runtimeDirectory}/bus";
    GST_PLUGIN_SYSTEM_PATH_1_0 = gstreamerPluginPath;
    XDG_RUNTIME_DIR = runtimeDirectory;
  }
  // lib.optionalAttrs cfg.audio.enable {
    PIPEWIRE_RUNTIME_DIR = runtimeDirectory;
  }
  // lib.optionalAttrs (cfg.graphics.vaapiDriver != null) {
    LIBVA_DRIVER_NAME = cfg.graphics.vaapiDriver;
  };
  userService = "user@${toString config.users.users.${cfg.user}.uid}.service";
  waitForPipeWire = pkgs.writeShellApplication {
    name = "wait-for-pipewire";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.pipewire
    ];
    text = ''
      export XDG_RUNTIME_DIR=${lib.escapeShellArg runtimeDirectory}
      export PIPEWIRE_RUNTIME_DIR="$XDG_RUNTIME_DIR"
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
      deadline=$((SECONDS + 30))

      until timeout 1s pw-cli info 0 >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
          echo "PipeWire did not become ready within 30 seconds" >&2
          exit 1
        fi
        sleep 0.1
      done
    '';
  };
  displayPower = import ./display/display-power.nix {
    inherit lib pkgs;
    connectorName = cfg.display.connectorName;
    framebuffer = cfg.display.framebuffer;
  };
}
