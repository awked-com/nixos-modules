{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cast;
  framebufferDevice = lib.last (lib.splitString "/" (lib.dirOf cfg.display.framebuffer));
  inherit (import ../media.nix { inherit config lib pkgs; }) displayPower;
  displayArbiter = pkgs.writeShellApplication {
    name = "display-arbiter";
    runtimeInputs = [
      pkgs.systemd
      pkgs.util-linux
    ];
    text = lib.replaceStrings [ "@displayPower@" ] [ "${displayPower}/bin/display-power" ] (
      builtins.readFile ./display-arbiter.sh
    );
  };
in
lib.mkIf cfg.enable {
  boot.kernelParams = [ "fbcon=nodefer" ];

  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="graphics", KERNEL=="${framebufferDevice}", \
      RUN+="${pkgs.coreutils}/bin/chgrp ${cfg.group} /sys/class/graphics/%k/blank", \
      RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/graphics/%k/blank"
  '';

  systemd.services.display-arbiter = {
    description = "Display ownership arbiter";
    wantedBy = [ "multi-user.target" ];
    requires = [ "display-power.service" ];
    after = [ "display-power.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${displayArbiter}/bin/display-arbiter";
    };
  };

  systemd.paths.display-arbiter = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/run/display";
      Unit = "display-arbiter.service";
    };
  };

  systemd.timers.display-arbiter = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
      Unit = "display-arbiter.service";
    };
  };

  systemd.services.display-power = {
    description = "Initialize direct-KMS display power";
    wantedBy = [ "multi-user.target" ];
    after = [
      "plymouth-quit-wait.service"
      "plymouth-quit.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = cfg.user;
      Group = cfg.group;
      RuntimeDirectory = "display";
      RuntimeDirectoryMode = "0770";
      RuntimeDirectoryPreserve = true;
      ExecStartPre = "+${pkgs.kbd}/bin/chvt 63";
      ExecStart = "${displayPower}/bin/display-power reconcile";
    };
  };
}
