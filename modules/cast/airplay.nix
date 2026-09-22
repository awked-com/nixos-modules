{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cast;
  media = import ./media.nix { inherit config lib pkgs; };
  hardening = import ./hardening.nix;
  portRange = {
    from = cfg.airplay.port;
    to = cfg.airplay.port + 2;
  };
in
lib.mkIf cfg.enable {
  services.avahi = {
    enable = true;
    openFirewall = false;
    allowInterfaces = cfg.airplay.interfaces;
    publish = {
      enable = true;
      userServices = true;
    };
  };

  networking.firewall.interfaces = lib.genAttrs cfg.airplay.interfaces (_: {
    allowedUDPPorts = [ 5353 ];
    allowedTCPPortRanges = [ portRange ];
    allowedUDPPortRanges = [ portRange ];
  });

  systemd.services.uxplay = rec {
    description = "UxPlay AirPlay screen mirroring receiver";
    requires = [
      "avahi-daemon.service"
      "display-power.service"
      media.userService
    ];
    after = requires;
    partOf = [ "avahi-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = [ "!/run/display/active-miracle" ];
      StartLimitIntervalSec = 0;
    };
    environment = media.environment // {
      UXPLAY_DISPLAY_COMMAND = "${media.displayPower}/bin/display-power";
      XDG_CACHE_HOME = "/run/uxplay/cache";
    };
    serviceConfig = hardening.mediaClient // {
      User = cfg.user;
      Group = cfg.group;
      MemoryHigh = "768M";
      MemoryMax = "1G";
      MemorySwapMax = 0;
      CapabilityBoundingSet = [ ];
      DeviceAllow = [ "char-drm rw" ];
      DevicePolicy = "closed";
      PrivateIPC = true;
      KeyringMode = "private";
      PrivateMounts = true;
      ProtectProc = "invisible";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_UNIX"
      ];
      SystemCallFilter = hardening.daemon.SystemCallFilter;
      ExecStartPre = lib.optional cfg.audio.enable "${media.waitForPipeWire}/bin/wait-for-pipewire";
      ExecStopPost = "${media.displayPower}/bin/display-power release uxplay";
      ReadWritePaths = [
        "/run/display"
        cfg.display.framebuffer
      ];
      ExecStart = lib.escapeShellArgs (
        [
          "${pkgs.coreutils}/bin/stdbuf"
          "-oL"
          "${pkgs.uxplay}/bin/uxplay"
          "-p"
          (toString cfg.airplay.port)
          "-n"
          cfg.friendlyName
          "-nh"
          "-h265"
          "-s"
          cfg.airplay.mode
          "-fps"
          (toString cfg.airplay.framerate)
          "-nofreeze"
          "-vd"
          cfg.graphics.videoDecoder
          "-taper"
        ]
        ++ lib.optionals (cfg.graphics.videoCaps != null) [
          "-vc"
          cfg.graphics.videoCaps
        ]
        ++ [
          "-srgb"
          "no"
          "-fs"
          "-vs"
          media.videoSink
          "-as"
          (if cfg.audio.enable then "pipewiresink" else "0")
        ]
      );
      Restart = "always";
      RestartSec = "2s";
      RuntimeDirectory = "uxplay";
      RuntimeDirectoryMode = "0700";
    };
  };
}
