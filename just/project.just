# DNF just — consumer bootstrap, imported by a consumer project Justfile:
#
#   import? 'dnf/just/project.just'
#
# Install, configure, deploy and operate the fleet declared in `etc/config.yaml`.

import 'common.just'
import 'project/_hosts.just'
import 'project/_secrets.just'
import 'project/apply.just'
import 'project/configure.just'
import 'project/dev.just'
import 'project/fix.just'
import 'project/identities.just'
import 'project/install.just'
import 'project/luks.just'
import 'project/manage.just'
import 'project/roaming.just'
import 'project/secrets.just'

# Project-specific param: the repo-side gitignore path for secrets.
secretsGitIgnore := secretsDir + '/.gitignore'
sopsAdminKeyDir := home_directory() + '/.config/sops/age'
sopsAdminKeyFile := sopsAdminKeyDir + '/keys.txt'
sopsYamlFile := secretsDir + '/.sops.yaml'
dnfInstallDir := '/mnt/dnf-install'

# Deploy build location. Empty (default): build each node closure on the host
# running just, then push it — a derivation compiles once and the deployer's
# harmonia re-serves it to the whole fleet. Non-empty: build on each target
# (use for an arch the deployer cannot build natively, e.g. aarch64 rpi hosts).
buildOnTarget := ''
