set shell := ["bash", "-euo", "pipefail", "-c"]

# Default -> just --list
_default:
    @just --list

# Build the generator (release)
build:
    cargo build --release

# Run unit tests
test:
    cargo test --quiet

# Run unit tests with output
test-verbose:
    cargo test -- --nocapture

# Build + test
check: build test

# Run the generator (usage: just run <command> [debug])
run command debug='':
    cargo run -- {{command}} {{debug}}
