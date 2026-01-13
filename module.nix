{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.zenos.maintenance;

  # Directory paths
  stateDir = "/System/ZenOS/Maintenance";
  timestampFile = "${stateDir}/last_maintenance";
  nagTimestampFile = "${stateDir}/last_nag";
  firstRunFile = "${stateDir}/first_run_seen";

  # --- Helper: Send Notification from Root to Active User ---
  notifyScript = pkgs.writeShellScript "zenos-notify-helper" ''
    SUMMARY=$1
    BODY=$2

    # Tools
    LOGINCTL="${pkgs.systemd}/bin/loginctl"
    GREP="${pkgs.gnugrep}/bin/grep"
    AWK="${pkgs.gawk}/bin/awk"
    HEAD="${pkgs.coreutils}/bin/head"
    ID="${pkgs.coreutils}/bin/id"
    SUDO="${pkgs.sudo}/bin/sudo"
    NOTIFY="${pkgs.libnotify}/bin/notify-send"

    # 1. Find the primary user session on seat0
    SESSION_ID=$($LOGINCTL list-sessions | $GREP seat0 | $AWK '{print $1}' | $HEAD -n1)

    if [ -n "$SESSION_ID" ]; then
      USER_ID=$($LOGINCTL show-session -p User --value "$SESSION_ID")
      USER_NAME=$($ID -un "$USER_ID")
      
      # 2. Critical Environment Variables
      USER_DBUS="/run/user/$USER_ID/bus"
      USER_RUNTIME="/run/user/$USER_ID"
      
      if [ -S "$USER_DBUS" ]; then
        # 3. Execute notify-send as the user
        $SUDO -u "$USER_NAME" \
          DISPLAY=:0 \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_DBUS" \
          XDG_RUNTIME_DIR="$USER_RUNTIME" \
          $NOTIFY "$SUMMARY" "$BODY" \
          -i zenos-symbolic \
          -u critical \
          -a "ZenOS Maintenance"
        exit $?
      fi
    fi
    exit 1
  '';

  # --- 1. The Core Logic (Daily Run - Deep Clean) ---
  maintenanceCore = pkgs.writeShellScript "zenos-maintenance-core" ''
    set -e

    # -- Frequency Check (Once every 24h) --
    if [ -f "${timestampFile}" ]; then
      LAST_RUN=$(stat -c %Y "${timestampFile}")
      NOW=$(date +%s)
      AGE=$((NOW - LAST_RUN))
      if [ "$AGE" -lt 86400 ]; then
        echo "Skipping: Maintenance already performed today."
        exit 0
      fi
    fi

    ${notifyScript} "System Maintenance" "Starting optimization & cleanup..."
    echo "Starting ZenOS Maintenance..."

    # -- 1. Update System --
    if [ -n "${cfg.flakePath}" ] && [ -f "${cfg.flakePath}/flake.nix" ]; then
      echo "Updating Flake inputs..."
      ${pkgs.nix}/bin/nix flake update --flake "${cfg.flakePath}"
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake "${cfg.flakePath}"
    else
      ${pkgs.nix}/bin/nix-channel --update
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --upgrade
    fi

    # -- 2. Nix Garbage Collection --
    echo "Collecting Garbage..."
    # Clean system profile
    ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system --delete-generations 7d
    # Clean boot entries explicitly (prevents full /boot)
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 7d

    # -- 3. Store Deduplication --
    echo "Optimising Nix Store (Hardlinking)..."
    ${pkgs.nix}/bin/nix-store --optimise

    # -- 4. Log Vacuuming (New) --
    echo "Vacuuming Journals..."
    # Keep only 2 weeks of logs to save space
    ${pkgs.systemd}/bin/journalctl --vacuum-time=14d
    # Remove archived journals if they exceed 500M total
    ${pkgs.systemd}/bin/journalctl --vacuum-size=500M

    # -- 5. SSD TRIM (New - Critical for Performance) --
    echo "Trimming SSD blocks..."
    ${pkgs.util-linux}/bin/fstrim -av

    # -- 6. Timestamp & Finish --
    mkdir -p ${stateDir}
    touch ${timestampFile}
    chmod 644 ${timestampFile}

    # Write barrier to ensure logs/timestamps hit the disk
    ${pkgs.coreutils}/bin/sync

    ${notifyScript} "System Maintenance" "System optimized. Storage reclaimed."
    echo "ZenOS Maintenance Complete."
  '';

  # --- 2. Shutdown Cleanup Script (Safe) ---
  shutdownCleanupScript = pkgs.writeShellScript "zenos-shutdown-cleanup" ''
    echo "Running safe shutdown cleanup..."

    # Quick GC only
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d

    # Flush file system buffers to disk before power cut
    ${pkgs.coreutils}/bin/sync
  '';

  # --- 3. Wrappers & Checkers ---
  maintenanceWrapper = pkgs.writeShellScript "zenos-maintenance-wrapper" ''
    ${pkgs.systemd}/bin/systemd-inhibit \
      --what="sleep:shutdown:idle" \
      --who="ZenOS Maintenance" \
      --why="Performing daily system updates" \
      --mode="block" \
      ${maintenanceCore}
  '';

  idleCheckScript = pkgs.writeShellScript "zenos-idle-check" ''
    # Check if run recently first (Cheap check)
    if [ -f "${timestampFile}" ]; then
      LAST_RUN=$(stat -c %Y "${timestampFile}")
      NOW=$(date +%s)
      if [ $((NOW - LAST_RUN)) -lt 86400 ]; then exit 0; fi
    fi

    # Check Session
    SESSION=$(${pkgs.systemd}/bin/loginctl list-sessions --no-legend | grep seat0 | awk '{print $1}' | head -n1)
    if [ -z "$SESSION" ]; then exit 0; fi

    # Check Idle State
    IS_IDLE=$(${pkgs.systemd}/bin/loginctl show-session -p IdleHint --value "$SESSION")
    if [ "$IS_IDLE" != "yes" ]; then exit 0; fi

    # Check Idle Duration (>1 hour)
    IDLE_SINCE=$(${pkgs.systemd}/bin/loginctl show-session -p IdleSinceHintMonotonic --value "$SESSION")
    UPTIME_SEC=$(cat /proc/uptime | awk '{print $1}')
    NOW_MONO=$(echo "$UPTIME_SEC * 1000000" | ${pkgs.bc}/bin/bc | cut -d. -f1)

    if [ $((NOW_MONO - IDLE_SINCE)) -gt $((3600 * 1000000)) ]; then
      ${pkgs.systemd}/bin/systemctl start zenos-maintenance.service
    fi
  '';

  # --- 4. The Watchdog (Nag) ---
  nagScript = pkgs.writeShellScript "zenos-maintenance-nag" ''
    mkdir -p ${stateDir}

    # -- A. Fresh Install / Intro Check --
    if [ ! -f "${timestampFile}" ]; then
      if [ ! -f "${firstRunFile}" ]; then
        ${pkgs.libnotify}/bin/notify-send \
          "ZenOS Maintenance" \
          "Automatic maintenance is active. It will run daily when the device is idle." \
          -i zenos-symbolic -u critical -a "ZenOS System"
        touch "${firstRunFile}"
        touch "${nagTimestampFile}"
        exit 0
      fi
      LAST_RUN=0
    else
      LAST_RUN=$(stat -c %Y "${timestampFile}")
    fi

    # -- B. Regular Overdue Check --
    NOW=$(date +%s)
    # Check if 7 days overdue
    if [ $((NOW - LAST_RUN)) -le 604800 ]; then exit 0; fi

    # Check Nag Frequency (Weekly Limit)
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
      };
    };
    dates = lib.mkOption {
      type = lib.types.str;
      default = "03:00";
    };
    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
    };
  };

  config = lib.mkIf cfg.enable {

    # --- Feature: Activation Check ---
    system.activationScripts.zenosFirstRunCheck = ''
      if [ ! -f "${firstRunFile}" ] && [ "${toString cfg.nag.enable}" = "1" ]; then
        if ${notifyScript} "ZenOS Maintenance" "Automatic maintenance is active. It will run daily when the device is idle."; then
            mkdir -p ${stateDir}
            touch "${firstRunFile}"
            touch "${nagTimestampFile}"
        else
            echo "ZenOS Maintenance: Notification failed. Will retry on next login."
        fi
      fi
    '';

    # --- Services ---
    systemd.services.zenos-maintenance = {
      description = "ZenOS System Update";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = maintenanceWrapper;
        CPUSchedulingPolicy = "idle";
        IOSchedulingClass = "idle"; # Low IO priority
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
        TimeoutSec = "1200"; # Increased timeout for TRIM operations
      };
    };

    systemd.services.zenos-shutdown-cleanup = {
      description = "ZenOS Shutdown Garbage Collection";
      wantedBy = [
        "poweroff.target"
        "reboot.target"
        "halt.target"
      ];
      before = [
        "poweroff.target"
        "reboot.target"
        "halt.target"
        "shutdown.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = shutdownCleanupScript;
        TimeoutSec = "120";
      };
    };

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
    ];

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
        OnStartupSec = "10s";
        OnUnitActiveSec = "6h";
      };
    };

    environment.systemPackages = [
      pkgs.libnotify
      pkgs.bc
      pkgs.sudo
      pkgs.util-linux # Required for fstrim
    ];
  };
}
