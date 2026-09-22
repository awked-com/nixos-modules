{
  name,
  description,
  uid,
  qemuArgs ? [ ],
  vcpu ? 1,
  memory ? 512,
  volumes ? [ ],
  interfaces ? [ ],
  timeoutStopSec ? 45,
}:

{
  lib,
  pkgs,
  utils,
  ...
}:

let
  inherit (import ../networking/validation.nix) allUnique normalizeMac validMacAddress;
  qemuArch = pkgs.stdenv.hostPlatform.qemuArch;
  validVcpu = builtins.isInt vcpu && vcpu > 0;
  effectiveVcpu = if validVcpu then vcpu else 1;
  validMemory = builtins.isInt memory && memory > 0;
  effectiveMemory = if validMemory then memory else 1;
  safeIdentifier =
    value: builtins.isString value && builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" value != null;
  machineConfig =
    {
      x86_64 = "q35,accel=kvm,acpi=on,mem-merge=on";
      aarch64 = "virt,accel=kvm,gic-version=max";
    }
    .${qemuArch} or (throw "vm-qemu: unsupported QEMU architecture ${qemuArch}");
  runtimePath = "/run/qemu-vm/${name}";
  qmpSocket = "${runtimePath}/qmp.sock";
  serialSocket = "${runtimePath}/console.sock";
  serviceUser = "vm-${name}";
  serviceUid = uid;
  serviceGroup = "kvm";
  qemuPackage = pkgs.qemu_kvm.override {
    nixosTestRunner = true;
  };
  canSandbox = builtins.elem "--enable-seccomp" (qemuPackage.configureFlags or [ ]);
  volumePaths = map (volume: volume.image) volumes;
  interfaceNames = map (interface: interface.ifname) interfaces;
  interfaceMacAddresses = map (interface: interface.mac) interfaces;
  multiQueue = effectiveVcpu > 1;
  volumeArgs = lib.concatLists (
    lib.imap0 (
      index: volume:
      let
        driveId = "vd${toString index}";
      in
      [
        "-drive"
        "id=${driveId},format=raw,file=${volume.image},if=none,aio=io_uring,discard=unmap,read-only=off"
        "-device"
        "virtio-blk-pci,drive=${driveId}"
      ]
    ) volumes
  );
  interfaceArgs = lib.concatMap (interface: [
    "-netdev"
    "tap,id=${interface.ifname},ifname=${interface.ifname},script=no,downscript=no,vhost=on${lib.optionalString multiQueue ",queues=${toString effectiveVcpu}"}"
    "-device"
    "virtio-net-pci,netdev=${interface.ifname},mac=${interface.mac},romfile=${lib.optionalString multiQueue ",mq=on,vectors=${toString (2 * effectiveVcpu + 2)}"}"
  ]) interfaces;
  tapUp = pkgs.writeShellScript "qemu-vm-${name}-tap-up" (
    ''
      set -euo pipefail
    ''
    + lib.concatMapStrings (interface: ''
      if [ -e /sys/class/net/${interface.ifname} ]; then
        ${pkgs.iproute2}/bin/ip link delete ${lib.escapeShellArg interface.ifname}
      fi
      ${pkgs.iproute2}/bin/ip tuntap add name ${lib.escapeShellArg interface.ifname} \
        mode tap user ${lib.escapeShellArg serviceUser} vnet_hdr${lib.optionalString multiQueue " multi_queue"}
      ${pkgs.iproute2}/bin/ip link set ${lib.escapeShellArg interface.ifname} up
    '') interfaces
  );
  tapDown = pkgs.writeShellScript "qemu-vm-${name}-tap-down" (
    ''
      set -uo pipefail
    ''
    + lib.concatMapStrings (interface: ''
      ${pkgs.iproute2}/bin/ip link delete ${lib.escapeShellArg interface.ifname} 2>/dev/null || true
    '') interfaces
  );
  qemuCommand = lib.escapeShellArgs (
    [
      "${qemuPackage}/bin/qemu-system-${qemuArch}"
      "-name"
      name
      "-machine"
      machineConfig
      "-smp"
      (toString effectiveVcpu)
      "-m"
      "${toString effectiveMemory}M"
      "-cpu"
      "host"
      "-nodefaults"
      "-no-user-config"
      "-no-reboot"
      "-nographic"
      "-qmp"
      "unix:${qmpSocket},server=on,wait=off"
      "-monitor"
      "none"
      "-chardev"
      "socket,id=serial,path=${serialSocket},server=on,wait=off"
      "-serial"
      "chardev:serial"
      "-device"
      "virtio-rng-pci"
    ]
    ++ lib.optionals (qemuArch == "x86_64") [
      "-device"
      "i8042"
    ]
    ++ lib.optionals canSandbox [
      "-sandbox"
      "on"
    ]
    ++ interfaceArgs
    ++ volumeArgs
    ++ qemuArgs
  );
  runVm = pkgs.writeShellScript "qemu-vm-${name}-run" ''
    exec ${qemuCommand}
  '';
  shutdownVm = pkgs.writeShellScript "shutdown-${name}" ''
    set -euo pipefail

    if [[ -S ${lib.escapeShellArg qmpSocket} ]]; then
      printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"system_powerdown"}' |
        ${pkgs.socat}/bin/socat STDIO ${lib.escapeShellArg "UNIX:${qmpSocket},shut-none"} || true
    fi

    # Returning kills QEMU; wait for TimeoutStopSec even after QMP failure.
    while [[ -n "''${MAINPID:-}" ]] && kill -0 "$MAINPID" 2>/dev/null; do
      ${pkgs.coreutils}/bin/sleep 0.1
    done
  '';
  console = pkgs.writeShellApplication {
    name = "console-${name}";
    runtimeInputs = [ pkgs.socat ];
    text = ''
      if [[ ! -S ${lib.escapeShellArg serialSocket} ]]; then
        echo "Serial console is unavailable: ${serialSocket}" >&2
        exit 1
      fi

      echo "Connecting to ${name}; press Ctrl-] to disconnect." >&2
      exec socat \
        "STDIO,raw,echo=0,escape=0x1d" \
      ${lib.escapeShellArg "UNIX-CONNECT:${serialSocket}"}
    '';
  };
in
{
  imports = [ ./service.nix ];

  assertions = [
    {
      assertion = builtins.isInt uid && uid > 0;
      message = "vm-qemu ${name}: uid must be an explicit positive integer";
    }
    {
      assertion = validVcpu;
      message = "vm-qemu ${name}: vcpu must be a positive integer";
    }
    {
      assertion = validMemory;
      message = "vm-qemu ${name}: memory must be a positive integer number of MiB";
    }
    {
      assertion =
        builtins.all (ifname: safeIdentifier ifname && builtins.stringLength ifname <= 15) interfaceNames
        && allUnique interfaceNames;
      message = "vm-qemu ${name}: TAP interface names must be safe, unique, and at most 15 characters";
    }
    {
      assertion =
        builtins.all validMacAddress interfaceMacAddresses
        && allUnique (map normalizeMac interfaceMacAddresses);
      message = "vm-qemu ${name}: interface MAC addresses must be valid and unique";
    }
  ];

  boot.kernelModules = lib.optionals (interfaces != [ ]) [
    "tap"
    "vhost_net"
  ];
  environment.etc = {
    "qemu-vm/${name}/run".source = runVm;
    "qemu-vm/${name}/shutdown".source = shutdownVm;
    "qemu-vm/${name}/console".source = lib.getExe console;
  }
  // lib.optionalAttrs (interfaces != [ ]) {
    "qemu-vm/${name}/tap-up".source = tapUp;
    "qemu-vm/${name}/tap-down".source = tapDown;
  };

  systemd.services."qemu-vm@${name}" = {
    inherit description;
    overrideStrategy = "asDropin";
    wantedBy = [ "multi-user.target" ];
    unitConfig = lib.optionalAttrs (volumePaths != [ ]) {
      ConditionPathExists = volumePaths;
      RequiresMountsFor = volumePaths;
    };
    restartTriggers = [ runVm ] ++ lib.optionals (interfaces != [ ]) [ tapUp ];
    serviceConfig = {
      TimeoutStopSec = timeoutStopSec;
      ReadWritePaths = volumePaths;
      DeviceAllow = lib.optionals (interfaces != [ ]) [
        "/dev/net/tun rw"
        "/dev/vhost-net rw"
      ];
      ExecStartPre = lib.concatMap (path: [
        "+${pkgs.coreutils}/bin/chown ${serviceUser}:${serviceGroup} ${utils.escapeSystemdExecArg path}"
        "+${pkgs.coreutils}/bin/chmod 0600 ${utils.escapeSystemdExecArg path}"
      ]) volumePaths;
    };
  };

  users.users.${serviceUser} = {
    isSystemUser = true;
    group = serviceGroup;
    uid = serviceUid;
  };
}
