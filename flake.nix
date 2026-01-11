{
  description = "ZenOS Maintenance & Cleanup Module";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    {
      # Export the module so it can be imported by other flakes
      nixosModules.default = import ./module.nix;

      # Optional: Export the module as 'zenos-maintenance' specifically
      nixosModules.zenos-maintenance = import ./module.nix;

      # specific formatter for 'nix fmt'
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;
    };
}
