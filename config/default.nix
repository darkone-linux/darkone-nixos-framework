# Global DNF configuraiton

{
  alerts = import ./alerts.nix;
  modules = import ./modules.nix;
  network = import ./network.nix;
}
