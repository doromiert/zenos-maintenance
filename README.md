# ZenOS Maintenance Module

A NixOS module designed for [ZenOS] systems to automate updates, garbage collection, and store optimization during idle hours. It includes a user-nagging protocol if maintenance is missed for more than 7 days.

## Features

1.  **Automatic Updates:** Runs `nix flake update` and `nixos-rebuild switch` at 03:00 (default).
2.  **Cleanup:** Runs `nix-collect-garbage --delete-older-than 7d`.
3.  **Optimization:** Runs `nix-store --optimise`.
4.  **Watchdog:** If the system is powered off during the maintenance window for 7 consecutive days, a persistent (critical) notification will appear on the desktop asking the user to leave the device on.

## Usage

### 1. Add to Inputs

In your system `flake.nix`:

```nix
inputs = {
  nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  # Add ZenOS Maintenance
  zenos-maintenance.url = "github:doromiert/zenos-maintenance";
  # or path: zenos-maintenance.url = "path:/local/path/to/repo";
};
```

### 2. Import Module

In your `flake.nix` outputs:

```nix
outputs = { self, nixpkgs, zenos-maintenance, ... }: {
  nixosConfigurations.myMachine = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ./configuration.nix

      # Import the module
      zenos-maintenance.nixosModules.default
    ];
  };
};
```

### 3. Configure

In your `configuration.nix`:

```nix
{ config, pkgs, ... }: {
  zenos.maintenance = {
    enable = true;
    dates = "03:00";          # Optional: Default is 3 AM
    flakePath = "/etc/nixos"; # Optional: Default is /etc/nixos
  };
}
```
