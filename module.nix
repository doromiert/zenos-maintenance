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

  # --- 1. The Core Logic (Does the work, checks frequency) ---
  maintenanceCore = pkgs.writeShellScript "zenos-maintenance-core" ''
    set -e

    # 1. Frequency Check (Daily Limit)
    # If maintenance was performed < 24 hours ago, skip it.
    if [ -f "${timestampFile}" ]; then
      LAST_RUN=$(stat -c %Y "${timestampFile}")
      NOW=$(date +%s)
      AGE=$((NOW - LAST_RUN))
      ONE_DAY=86400
      
      if [ "$AGE" -lt "$ONE_DAY" ]; then
        echo "Maintenance already performed within the last 24h. Skipping."
        exit 0
      fi
    fi

    echo "Starting ZenOS Maintenance (Daily Run)..."

    # 2. Update the System
    if [ -n "${cfg.flakePath}" ] && [ -f "${cfg.flakePath}/flake.nix" ]; then
      echo "Flake detected at ${cfg.flakePath}. Updating inputs..."
      ${pkgs.nix}/bin/nix flake update --flake "${cfg.flakePath}"
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake "${cfg.flakePath}"
    else
      echo "No specific flake found or configured. Attempting legacy channel update..."
      ${pkgs.nix}/bin/nix-channel --update
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --upgrade
    fi

    # 3. Garbage Collection
    echo "Cleaning old generations..."
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 7d

    # 4. Optimize Store
    echo "Optimizing store..."
    ${pkgs.nix}/bin/nix-store --optimise

    # 5. Update Timestamp
    mkdir -p ${stateDir}
    touch ${timestampFile}
    chmod 644 ${timestampFile}

    echo "ZenOS Maintenance Complete."
  '';

  # --- 2. The Maintenance Service Script (Wrapper) ---
  # Only used for Manual/Idle starts. Wraps core in an inhibitor to KEEP system awake.
  maintenanceWrapper = pkgs.writeShellScript "zenos-maintenance-wrapper" ''
    ${pkgs.systemd}/bin/systemd-inhibit \
      --what="sleep:shutdown:idle" \
      --who="ZenOS Maintenance" \
      --why="Performing daily system updates" \
      --mode="block" \
      ${maintenanceCore}
  '';

  # --- 3. The Idle Checker Script ---
  # Triggers if: Maintenance Due (>24h) AND User Idle (>1h)
  idleCheckScript = pkgs.writeShellScript "zenos-idle-check" ''
    # Check if due (reuse logic, simple check)
    if [ -f "${timestampFile}" ]; then
      LAST_RUN=$(stat -c %Y "${timestampFile}")
      NOW=$(date +%s)
      if [ $((NOW - LAST_RUN)) -lt 86400 ]; then
        exit 0 # Done today, don't care if idle.
      fi
    fi

    # Check Idle State
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
      echo "User idle > 1h and maintenance due. Starting..."
      ${pkgs.systemd}/bin/systemctl start zenos-maintenance.service
    fi
  '';

  # --- 4. The Watchdog Script (Weekly Nag) ---
  # Alerts only if maintenance is severely overdue (>7 days)
  nagScript = pkgs.writeShellScript "zenos-maintenance-nag" ''
    mkdir -p ${stateDir}
    if [ ! -f "${timestampFile}" ]; then LAST_RUN=0; else LAST_RUN=$(stat -c %Y "${timestampFile}"); fi

    NOW=$(date +%s)
    # Check if 7 days overdue (Not 1 day - we don't nag for daily misses, only weekly failures)
    if [ $((NOW - LAST_RUN)) -le 604800 ]; then exit 0; fi

    # Check Nag Frequency (Max once per week)
    if [ -f "${nagTimestampFile}" ]; then
      LAST_NAG=$(stat -c %Y "${nagTimestampFile}")
      if [ $((NOW - LAST_NAG)) -lt 604800 ]; then exit 0; fi
    fi

    ${pkgs.libnotify}/bin/notify-send \
      "ZenOS Maintenance Required" \
      "Maintenance is overdue (>7 days). Your device will attempt to update automatically next time it sleeps or is idle for 1 hour." \
      -i zenos-symbolic \
      -u critical \
      --expire-time=0 \
      -a "ZenOS System"
      
    touch "${nagTimestampFile}"
  '';

in
{
  options.zenos.maintenance = {
    enable = lib.mkEnableOption "ZenOS Automatic Maintenance & Cleanup";
    dates = lib.mkOption {
      type = lib.types.str;
      default = "03:00";
      description = "Systemd calendar expression for scheduled maintenance.";
    };
    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Path to the directory containing the system flake.nix.";
    };
  };

  config = lib.mkIf cfg.enable {

    # --- A. Standard Service (Manual / Timer / Idle) ---
    systemd.services.zenos-maintenance = {
      description = "ZenOS System Update (Standard)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = maintenanceWrapper;
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

    # --- B. Sleep Hook Service (The "Trap") ---
    # Captures the sleep event. If maintenance is due, runs it BEFORE sleep completes.
    systemd.services.zenos-maintenance-on-sleep = {
      description = "ZenOS System Update (Sleep Hook)";
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
        # We run core directly (no inhibitor wrapper) because we are already in the sleep transaction.
        # This service effectively delays sleep until it exits.
        ExecStart = maintenanceCore;
        TimeoutSec = "900"; # Allow 15 mins for update before forcing sleep
      };
    };

    # --- C. Idle Detector ---
    systemd.services.zenos-maintenance-idle-check = {
      description = "Check for User Idle to Trigger Maintenance";
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

    # --- D. Filesystem Setup ---
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0775 root users -"
      "f ${timestampFile} 0644 root root -"
      "f ${nagTimestampFile} 0664 root users -"
    ];

    # --- E. User Nag Service ---
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
        OnStartupSec = "5min";
        OnUnitActiveSec = "6h";
      };
    };

    environment.systemPackages = [
      pkgs.libnotify
      pkgs.bc
    ];
  };
}
