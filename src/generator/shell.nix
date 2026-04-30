{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  buildInputs = with pkgs; [
    rustc
    cargo
    cargo-audit
    rustfmt
    clippy
    rust-analyzer
    pkg-config
    gcc
  ];

  shellHook = ''
    alias build="cargo build --release"
    alias test="cargo test"
  '';

  RUST_BACKTRACE = 1;
}
