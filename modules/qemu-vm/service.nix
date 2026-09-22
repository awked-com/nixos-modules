{ lib, pkgs, ... }:

let
  qemuArch = pkgs.stdenv.hostPlatform.qemuArch;
  loadKvm = pkgs.writeShellScript "load-qemu-kvm" ''
    set -eu

    ${pkgs.kmod}/bin/modprobe kvm 2>/dev/null || true

    ${lib.optionalString (qemuArch == "x86_64") ''
      if ${pkgs.gnugrep}/bin/grep -qw vmx /proc/cpuinfo; then
        ${pkgs.kmod}/bin/modprobe kvm-intel
      elif ${pkgs.gnugrep}/bin/grep -qw svm /proc/cpuinfo; then
        ${pkgs.kmod}/bin/modprobe kvm-amd
      else
        echo "CPU does not expose Intel VMX or AMD SVM" >&2
        exit 1
      fi
    ''}

    if [ ! -c /dev/kvm ]; then
      echo "KVM did not provide /dev/kvm" >&2
      exit 1
    fi
  '';
  requireKvm = pkgs.writeShellScript "require-qemu-kvm" ''
    set -eu

    if [ ! -c /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
      echo "QEMU requires accessible KVM kernel acceleration (/dev/kvm)" >&2
      exit 1
    fi
  '';
in
{
  hardware.ksm.enable = lib.mkDefault true;

  systemd.services.qemu-kvm-modules = {
    description = "Load hardware-specific KVM modules for QEMU";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = loadKvm;
    };
  };

  systemd.services."qemu-vm-tap@" = {
    description = "Set up TAP interfaces for QEMU VM '%i'";
    partOf = [ "qemu-vm@%i.service" ];
    before = [ "qemu-vm@%i.service" ];
    after = [ "systemd-networkd.service" ];
    unitConfig.ConditionPathExists = "/etc/qemu-vm/%i/tap-up";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/etc/qemu-vm/%i/tap-up";
      ExecStop = "/etc/qemu-vm/%i/tap-down";
    };
  };

  systemd.services."qemu-vm@" = {
    description = "QEMU virtual machine '%i'";
    requires = [
      "qemu-kvm-modules.service"
      "qemu-vm-tap@%i.service"
    ];
    after = [
      "qemu-kvm-modules.service"
      "network.target"
      "systemd-networkd.service"
      "qemu-vm-tap@%i.service"
    ];
    wants = [ "network.target" ];
    unitConfig.ConditionPathExists = "/etc/qemu-vm/%i/run";
    serviceConfig = {
      ExecStart = "/etc/qemu-vm/%i/run";
      ExecStartPre = [
        requireKvm
        "${pkgs.coreutils}/bin/ln --symbolic --force /etc/qemu-vm/%i/console /run/qemu-vm/%i/console"
      ];
      ExecStop = "/etc/qemu-vm/%i/shutdown";
      Restart = "always";
      RestartSec = 5;
      User = "vm-%i";
      Group = "kvm";
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 1048576;
      RuntimeDirectory = "qemu-vm/%i";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      DevicePolicy = "closed";
      DeviceAllow = [ "/dev/kvm rw" ];
    };
  };
}
