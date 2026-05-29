# DNF main Justfile.
# TODO: optional import (import?) local over global (in nix store)
# TODO: filter only usefull actions here.

import 'assets/just/common.just'
import 'assets/just/testing.just'

_default:
	@just --list
