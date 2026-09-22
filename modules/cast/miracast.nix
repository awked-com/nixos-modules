{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cast;
  p2pInterface = cfg.wirelessInterface;
  media = import ./media.nix { inherit config lib pkgs; };
  hardening = import ./hardening.nix;
  miracleCastDbusPolicy = pkgs.writeTextDir "share/dbus-1/system.d/org.freedesktop.miracle.cast-user.conf" ''
    <?xml version="1.0"?> <!--*-nxml-*-->
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
            "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">

    <busconfig>
            <policy user="${cfg.user}">
                    <allow send_destination="org.freedesktop.miracle"/>
                    <allow send_destination="org.freedesktop.miracle.wifi"/>
                    <allow receive_sender="org.freedesktop.miracle"/>
                    <allow receive_sender="org.freedesktop.miracle.wifi"/>
            </policy>
    </busconfig>
  '';
  waitForMiraclecast = pkgs.writeShellApplication {
    name = "wait-for-miraclecast";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      service=org.freedesktop.miracle.wifi
      interface=org.freedesktop.miracle.wifi.Link
      miracle_interface=${lib.escapeShellArg p2pInterface}
      expected_interface='s "${p2pInterface}"'
      deadline=$((SECONDS + 30))

      while true; do
        link=

        while IFS= read -r candidate; do
          case "$candidate" in
            /org/freedesktop/miracle/wifi/link/*)
              property="$(
                busctl --timeout=1s get-property \
                  "$service" "$candidate" "$interface" InterfaceName \
                  2>/dev/null || true
              )"

              if test "$property" = "$expected_interface"; then
                link="$candidate"
                break
              fi
              ;;
          esac
        done < <(busctl --timeout=1s --list tree "$service" 2>/dev/null || true)

        if test -n "$link" && busctl --timeout=1s set-property \
          "$service" "$link" "$interface" P2PScanning b true \
          >/dev/null 2>&1
        then
          break
        fi

        if (( SECONDS >= deadline )); then
          echo "MiracleCast did not publish $miracle_interface within 30 seconds" >&2
          exit 1
        fi

        sleep 0.1
      done

      busctl --timeout=1s set-property \
        "$service" "$link" "$interface" P2PScanning b false
    '';
  };
in
lib.mkIf cfg.enable {
  services.dbus.packages = [
    pkgs.miraclecast
    miracleCastDbusPolicy
  ];

  systemd.services.miracle-sink = rec {
    description = "MiracleCast display sink";
    bindsTo = [ "miracle-wifid.service" ];
    partOf = [ "miracle-wifid.service" ];
    requires = [
      "display-power.service"
      media.userService
    ];
    after = bindsTo ++ requires;
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = [ "!/run/display/active-uxplay" ];
      StartLimitIntervalSec = 0;
    };
    path = [ pkgs.miraclecast ];
    environment = media.environment // {
      GST_DEBUG_NO_COLOR = "1";
      HOME = "/run/miracle-sink";
      XDG_CACHE_HOME = "/run/miracle-sink/cache";
    };
    serviceConfig = hardening.mediaClient // {
      User = cfg.user;
      Group = cfg.group;
      Slice = "miraclecast.slice";
      MemoryMax = "1G";
      MemorySwapMax = 0;
      CapabilityBoundingSet = "";
      DevicePolicy = "closed";
      DeviceAllow = [ "char-drm rw" ];
      ExecStartPre = [
        "${waitForMiraclecast}/bin/wait-for-miraclecast"
      ]
      ++ lib.optional cfg.audio.enable "${media.waitForPipeWire}/bin/wait-for-pipewire";
      ExecStart =
        "${pkgs.coreutils}/bin/stdbuf -oL "
        + lib.escapeShellArgs (
          [
            "${pkgs.miraclecast}/bin/miracle-sinkctl"
            "--res"
            cfg.miraclecast.supportedResolutions
            "--video-decoder"
            cfg.graphics.videoDecoder
          ]
          ++ lib.optionals (cfg.graphics.videoCaps != null) [
            "--video-caps"
            cfg.graphics.videoCaps
          ]
          ++ (
            if cfg.audio.enable then
              [
                "--audio-sink"
                "pipewiresink"
              ]
            else
              [ "--no-audio" ]
          )
          ++ [
            "--video-sink"
            media.videoSink
            "--display-power-cmd"
            "${media.displayPower}/bin/display-power"
            "bind"
            p2pInterface
          ]
        );
      ExecStopPost = "${media.displayPower}/bin/display-power release miracle";
      ReadWritePaths = [
        "/run/display"
        "/run/miracle-sink"
        cfg.display.framebuffer
      ];
      Restart = "always";
      RestartSec = "2s";
      RuntimeDirectory = "miracle-sink";
      RuntimeDirectoryMode = "0770";
      TimeoutStopSec = "10s";
    };
  };

}
