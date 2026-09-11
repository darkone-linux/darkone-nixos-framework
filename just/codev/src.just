# DNF just — sub-projects: Rust generator.

# Build the Rust generator
[group('src')]
gen-build:
	just --justfile src/generator/Justfile build

# Run Rust generator unit tests
[group('src')]
gen-test:
	just --justfile src/generator/Justfile test
