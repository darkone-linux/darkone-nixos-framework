# DNF main Justfile.
# TODO: optional import (import?) local over global (in nix store)
# TODO: filter only usefull actions here.

import 'assets/default.just'
import 'assets/testing.just'

_default:
	@just --list
