{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.zenos.maintenance;

  # Directory to store the timestamps
  stateDir = "/System/ZenOS/Maintenance";
  timestampFile = "${stateDir}/last_maintenance";
  nagTimestampFile = "${stateDir}/last_nag";

  # --- Helper: Send Notification from Root ---
  # Tries to find the active user on seat0 and send a notification
  notifyScript = pkgs.writeShellScript "zenos-notify-helper" ''
    SUMMARY=$1
    BODY=$2

    # Find primary session on seat0
    SESSION=$(loginctl list-sessions | grep seat0 | awk '{print $1}' | head -n1)
    if [ -n "$SESSION" ]; then
      USER_ID=$(loginctl show-session -p User --value "$SESSION")
      USER_NAME=$(id -un "$USER_ID")
      USER_DBUS="/run/user/$USER_ID/bus"
      
      if [ -S "$USER_DBUS" ]; then
        # Switch to user and send notification
        ${pkgs.sudo}/bin/sudo -u "$USER_NAME" \
          DISPLAY=:0 \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_DBUS" \
          ${pkgs.libnotify}/bin/notify-send "$SUMMARY" "$BODY" \
          -i zenos-symbolic \
          -a "ZenOS Maintenance"
      fi
    fi
  '';

  # --- 1. The Core Logic (Daily Run) ---
  maintenanceCore = pkgs.writeShellScript "zenos-maintenance-core" ''
    set -e

    # 1. Frequency Check
    if [ -f "${timestampFile}" ]; then
      LAST_RUN=$(stat -c %Y "${timestampFile}")
      NOW=$(date +%s)
      AGE=$((NOW - LAST_RUN))
      if [ "$AGE" -lt 86400 ]; then
        echo "Skipping: Maintenance already performed today."
        exit 0
      fi
    fi

    # Notify User: Starting
    ${notifyScript} "System Maintenance" "Starting daily update & cleanup..."

    echo "Starting ZenOS Maintenance..."

    # 2. Update System
    if [ -n "${cfg.flakePath}" ] && [ -f "${cfg.flakePath}/flake.nix" ]; then
      ${pkgs.nix}/bin/nix flake update --flake "${cfg.flakePath}"
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake "${cfg.flakePath}"
    else
      ${pkgs.nix}/bin/nix-channel --update
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --upgrade
    fi

    # 3. Cleanup
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 7d
    ${pkgs.nix}/bin/nix-store --optimise

    # 4. Timestamp
    mkdir -p ${stateDir}
    touch ${timestampFile}
    chmod 644 ${timestampFile}

    # Notify User: Done
    ${notifyScript} "System Maintenance" "Daily maintenance complete."
    echo "ZenOS Maintenance Complete."
  '';

  # --- 2. Shutdown Cleanup Script (Safe Mode) ---
  # NO updates, NO network reliance. Just disk cleanup.
  shutdownCleanupScript = pkgs.writeShellScript "zenos-shutdown-cleanup" ''
    echo "Running safe shutdown cleanup..."
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 7d
    ${pkgs.nix}/bin/nix-store --optimise
  '';

  # --- 3. Wrapper & Idle Checker (Same as before) ---
  maintenanceWrapper = pkgs.writeShellScript "zenos-maintenance-wrapper" ''
    ${pkgs.systemd}/bin/systemd-inhibit \
      --what="sleep:shutdown:idle" \
      --who="ZenOS Maintenance" \
      --why="Performing daily system updates" \
      --mode="block" \
      ${maintenanceCore}
  '';

  idleCheckScript = pkgs.writeShellScript "zenos-idle-check" ''
    if [ -f "${timestampFile}" ]; then
      LAST_RUN=$(stat -c %Y "${timestampFile}")
      NOW=$(date +%s)
      if [ $((NOW - LAST_RUN)) -lt 86400 ]; then exit 0; fi
    fi

    SESSION=$(${pkgs.systemd}/bin/loginctl list-sessions --no-legend | grep seat0 | awk '{print $1}' | head -n1)
    if [ -z "$SESSION" ]; then exit 0; fi

    IS_IDLE=$(${pkgs.systemd}/bin/loginctl show-session -p IdleHint --value "$SESSION")
    if [ "$IS_IDLE" != "yes" ]; then exit 0; fi

    IDLE_SINCE=$(${pkgs.systemd}/bin/loginctl show-session -p IdleSinceHintMonotonic --value "$SESSION")
    UPTIME_SEC=$(cat /proc/uptime | awk '{print $1}')
    NOW_MONO=$(echo "$UPTIME_SEC * 1000000" | ${pkgs.bc}/bin/bc | cut -d. -f1)

    IDLE_DURATION=$((NOW_MONO - IDLE_SINCE))
    ONE_HOUR=$((3600 * 1000000))

    if [ "$IDLE_DURATION" -gt "$ONE_HOUR" ]; then
      ${pkgs.systemd}/bin/systemctl start zenos-maintenance.service
    fi
  '';

  # --- 4. The Watchdog (Nag) ---
  nagScript = pkgs.writeShellScript "zenos-maintenance-nag" ''
    mkdir -p ${stateDir}

    # -- A. Fresh Install Check --
    if [ ! -f "${timestampFile}" ]; then
      # Never run before! Notify immediately.
      ${pkgs.libnotify}/bin/notify-send \
        "ZenOS Setup" \
        "First-time setup: Please leave your device idle/plugged in for ~1 hour tonight to allows initial updates." \
        -i zenos-symbolic -u critical -a "ZenOS System"
      exit 0
    fi

    # -- B. Regular Overdue Check --
    LAST_RUN=$(stat -c %Y "${timestampFile}")
    NOW=$(date +%s)

    # 7 Days grace period
    if [ $((NOW - LAST_RUN)) -le 604800 ]; then exit 0; fi

    # Check Nag Frequency (Weekly)
    if [ -f "${nagTimestampFile}" ]; then
      LAST_NAG=$(stat -c %Y "${nagTimestampFile}")
      if [ $((NOW - LAST_NAG)) -lt 604800 ]; then exit 0; fi
    fi

    ${pkgs.libnotify}/bin/notify-send \
      "Maintenance Overdue" \
      "System hasn't updated in >7 days. Please leave device idle for 1 hour." \
      -i zenos-symbolic -u critical -a "ZenOS System"
      
    touch "${nagTimestampFile}"
  '';

in
{
  options.zenos.maintenance = {
    enable = lib.mkEnableOption "ZenOS Automatic Maintenance";

    nag = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable desktop notifications for overdue maintenance.";
      };
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "03:00";
      description = "Systemd calendar expression for scheduled maintenance.";
    };

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Path to the system flake.nix.";
    };
  };

  config = lib.mkIf cfg.enable {

    # --- Service A: Main Update Worker ---
    systemd.services.zenos-maintenance = {
      description = "ZenOS System Update";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = maintenanceWrapper;
        CPUSchedulingPolicy = "idle";
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

    # --- Service B: Sleep Trap ---
    systemd.services.zenos-maintenance-on-sleep = {
      description = "ZenOS Update (Sleep Hook)";
      before = [
        "sleep.target"
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
      ];
      wantedBy = [
        "sleep.target"
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = maintenanceCore;
        TimeoutSec = "900";
      };
    };

    # --- Service C: Shutdown Cleanup (Safe) ---
    systemd.services.zenos-shutdown-cleanup = {
      description = "ZenOS Shutdown Garbage Collection";
      # Run on PowerOff, Reboot, or Halt
      wantedBy = [
        "poweroff.target"
        "reboot.target"
        "halt.target"
      ];
      # Must run before the actual shutdown logic
      before = [
        "poweroff.target"
        "reboot.target"
        "halt.target"
        "shutdown.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = shutdownCleanupScript;
        TimeoutSec = "120"; # Give it 2 mins max
      };
    };

    # --- Service D: Idle Check ---
    systemd.services.zenos-maintenance-idle-check = {
      description = "Idle Check Trigger";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = idleCheckScript;
      };
      path = [
        pkgs.gawk
        pkgs.bc
        pkgs.systemd
      ];
    };

    systemd.timers.zenos-maintenance-idle-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "15min";
        Unit = "zenos-maintenance-idle-check.service";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0775 root users -"
      "f ${timestampFile} 0644 root root -"
      "f ${nagTimestampFile} 0664 root users -"
    ];

    # --- Service E: User Nag ---
    systemd.user.services.zenos-maintenance-nag = lib.mkIf cfg.nag.enable {
      description = "Check ZenOS Maintenance Status";
      script = "${nagScript}";
      serviceConfig = {
        Type = "oneshot";
        PassEnvironment = "DISPLAY DBUS_SESSION_BUS_ADDRESS";
      };
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
    };

    systemd.user.timers.zenos-maintenance-nag = lib.mkIf cfg.nag.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Run 10 seconds after login to catch fresh installs immediately
        OnStartupSec = "10s";
        OnUnitActiveSec = "6h";
      };
    };

    environment.systemPackages = [
      pkgs.libnotify
      pkgs.bc
      pkgs.sudo
    ];
  };
}
