# Yubikey module in a VM: pam_u2f wired as a password alternative, central
# mapping distributed, tooling shipped. The LUKS side (initrd, sops secrets,
# enroll unit on the disko host `server1`) is covered by the L1 `eval-all`
# tier: a plain VM has no LUKS header to enroll.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-yubikey";
  workspace = ../../workspaces/node/configs/yubikey;
  host = "node1";

  testScript = ''
    node1.wait_for_unit("multi-user.target")

    # pam_u2f is stacked (sufficient) on the interactive services.
    node1.succeed("grep -q 'pam_u2f.so' /etc/pam.d/sudo")
    node1.succeed("grep -q 'pam_u2f.so' /etc/pam.d/login")

    # Central mapping built from the registry, restricted to the host users:
    # one line for darkone (both keys), nothing else.
    node1.succeed("grep -q '^darkone:FAKEKEYHANDLEBACKUP' /etc/u2f_mappings")
    node1.succeed("test $(wc -l < /etc/u2f_mappings) -eq 1")

    # Enrollment & diagnostic tooling.
    node1.succeed("command -v ykman pamu2fcfg fido2-token")
  '';
}
