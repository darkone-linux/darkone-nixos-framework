# DNF just — co-development shortcuts.

# Two fleet evaluations, one after the other: `WORKERS` (default 2) and
# `WORKER_MEM` (MiB) bound each. `hosts`: comma-separated, all when empty.
# `base`: framework revision the `dnf/` working tree is compared with.
#
# Prove a framework refactor neutral: host derivations before and after
[group('dev')]
drv-diff hosts='' base='HEAD':
	@cd {{workDir}} && bash {{scriptsDir}}/drv-diff.sh "{{hosts}}" "{{base}}"

# Clean + amend (both repos) + apply-local (or on host) + Test
[group('dev')]
cat host='':
	#!/usr/bin/env bash
	set -euo pipefail
	just clean
	just amend
	if [ "{{host}}" == "" ] ;then
		just apply-local test
	else
		just apply-verbose "{{host}}"
	fi
