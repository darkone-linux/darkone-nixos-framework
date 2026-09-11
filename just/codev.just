# DNF just — co-development bootstrap: a consumer project holding `dnf/`,
# `doc/` and `src/*` checkouts (the framework maintainer workspace):
#
#   import 'dnf/just/codev.just'
#
# Adds multi-repo git helpers, the Rust generator, the ecosystem release train
# and the framework test recipes, all runnable from the workspace root.

import 'project.just'
import 'codev/dev.just'
import 'codev/git.just'
import 'codev/release.just'
import 'codev/src.just'
import 'dnf/dev.just'
import 'dnf/test.just'

# Repos to iterate in git commands: dnf, doc, all src/* dirs, then .
repos := `for d in src/*/; do [ -d "$d/.git" ] && echo "${d%/}"; done; printf '%s\n' dnf doc .`
