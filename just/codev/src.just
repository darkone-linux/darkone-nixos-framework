# DNF just — sub-projects: Rust generator.

# Build the Rust generator
[group('src')]
gen-build:
	just --justfile src/generator/Justfile build

# Run Rust generator unit tests
[group('src')]
gen-test:
	just --justfile src/generator/Justfile test

# Regenerate dnf/config/config.schema.json from the local generator; the
# release train rewrites it from the pinned one
[group('src')]
gen-schema:
	cargo run -q --manifest-path src/generator/Cargo.toml -- schema > dnf/config/config.schema.json
