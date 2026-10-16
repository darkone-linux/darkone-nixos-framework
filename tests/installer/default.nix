# Installer VM tools: `dnf-vm`, the installer test, and `#try`.
#
# - `vm`: QEMU machine booted on the generic ISO (`dnf-vm.sh`);
# - `test`: `darkone new` end to end, scripted and interactive (`run.py`),
#   `just test-installer` and the release CI;
# - `try`: the ISO of this flake in a window, a persistent disk under
#   `~/.local/share/dnf-try` (`nix run .#try`, `--reset` starts over).

{ pkgs, iso }:
let
  vm = pkgs.writeShellApplication {
    name = "dnf-vm";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.qemu
    ];
    runtimeEnv.OVMF_FV = "${pkgs.OVMF.fd}/FV";
    text = builtins.readFile ./dnf-vm.sh;
  };

  python = pkgs.python3.withPackages (p: [ p.pexpect ]);
in
{
  inherit vm;

  test = pkgs.writeShellApplication {
    name = "dnf-installer-test";
    runtimeInputs = [
      vm
      pkgs.age
      pkgs.coreutils
      pkgs.dosfstools
      pkgs.gnutar
      pkgs.mtools
      pkgs.openssh
      pkgs.util-linux
    ];
    text = ''exec ${python}/bin/python3 ${./run.py} "$@"'';
  };

  try = pkgs.writeShellApplication {
    name = "dnf-try";
    runtimeInputs = [
      vm
      pkgs.coreutils
    ];
    text = ''
      state="''${XDG_DATA_HOME:-$HOME/.local/share}/dnf-try"
      if [ "''${1:-}" = "--reset" ]; then
        rm -rf "$state"
      fi
      echo "DNF installer VM, disk in $state (--reset starts over)."
      exec dnf-vm --state "$state" --gui --iso ${iso}/iso/*.iso
    '';
  };
}
