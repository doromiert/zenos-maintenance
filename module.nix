{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.zenos.maintenance;

  # Directory to store the timestamp
  stateDir = "/var/lib/zenos";
  timestampFile = "${stateDir}/last_maintenance";

  # The Maintenance Script (Root)
  maintenanceScript = pkgs.writeShellScript "zenos-maintenance-task" ''
    set -e

    echo "Starting ZenOS Maintenance..."

    # 1. Update the System
    # Logic: If a flake path is configured, use it. Otherwise fall back to legacy channels.
    if [ -n "${cfg.flakePath}" ] && [ -f "${cfg.flakePath}/flake.nix" ]; then
      echo "Flake detected at ${cfg.flakePath}. Updating inputs..."
      ${pkgs.nix}/bin/nix flake update --flake "${cfg.flakePath}"
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake "${cfg.flakePath}"
    else
      echo "No specific flake found or configured. Attempting legacy channel update..."
      ${pkgs.nix}/bin/nix-channel --update
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --upgrade
    fi

    # 2. Garbage Collection
    echo "Cleaning old generations..."
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 7d

    # 3. Optimize Store
    echo "Optimizing store..."
    ${pkgs.nix}/bin/nix-store --optimise

    # 4. Update Timestamp
    mkdir -p ${stateDir}
    touch ${timestampFile}
    chmod 644 ${timestampFile}

    echo "ZenOS Maintenance Complete."
  '';

  # The Watchdog Script (User)
  nagScript = pkgs.writeShellScript "zenos-maintenance-check" ''
    if [ ! -f "${timestampFile}" ]; then
      LAST_RUN=0
    else
      LAST_RUN=$(stat -c %Y "${timestampFile}")
    fi

    NOW=$(date +%s)
    DIFF=$((NOW - LAST_RUN))
    SEVEN_DAYS=$((7 * 24 * 60 * 60))

    if [ $DIFF -gt $SEVEN_DAYS ]; then
      ${pkgs.libnotify}/bin/notify-send \
        "ZenOS cleanup" \
        "Maintenance overdue (>7 days). Please leave the device ON and PLUGGED IN tonight to allow automatic updates and optimization." \
        -i zenos-symbolic \
        -u critical \
        --expire-time=0 \
        -a "ZenOS System"
    fi
  '';

in
{
  options.zenos.maintenance = {
    enable = lib.mkEnableOption "ZenOS Automatic Maintenance & Cleanup";

    dates = lib.mkOption {
      type = lib.types.str;
      default = "03:00";
      description = "Systemd calendar expression for when maintenance should run.";
    };

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Path to the directory containing the system flake.nix.";
    };
  };

  config = lib.mkIf cfg.enable {

    # --- System Service (The Worker) ---
    systemd.services.zenos-maintenance = {
      description = "ZenOS System Update & Cleanup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = maintenanceScript;
        CPUSchedulingPolicy = "idle";
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.zenos-maintenance = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        Persistent = false;
        Unit = "zenos-maintenance.service";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
    ];

    # --- User Service (The Watchdog) ---
    systemd.user.services.zenos-maintenance-nag = {
      description = "Check ZenOS Maintenance Status";
      script = "${nagScript}";
      serviceConfig = {
        Type = "oneshot";
        PassEnvironment = "DISPLAY DBUS_SESSION_BUS_ADDRESS";
      };
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
    };

    systemd.user.timers.zenos-maintenance-nag = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnStartupSec = "15min";
        OnUnitActiveSec = "1d";
      };
    };

    environment.systemPackages = [ pkgs.libnotify ];
  };
}
