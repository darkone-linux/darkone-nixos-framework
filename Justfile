# DNF framework Justfile — framework-only recipes (tests, fixtures, release).
#
# Consumer projects import `dnf/just/project.just` instead; the co-development
# workspace imports `dnf/just/codev.just`.

import 'just/dnf.just'

_default:
	@just --list
