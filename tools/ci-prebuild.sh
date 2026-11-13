#!/usr/bin/env bash
# SCRIPT: ci-prebuild.sh
# DESCRIPTION: Prepare CI helper executables and generate man page before packaging jobs.
# USAGE: ./tools/ci-prebuild.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./tools/ci-prebuild.sh
set -euo pipefail

if [[ -d ./vendor/script-helpers/scripts ]]; then
  chmod +x ./vendor/script-helpers/scripts/*.sh || true
fi

# The vendored script-helpers tests are not part of the package, and their
# fixtures trip the publication check that gates rpm and brew. CI checkouts
# only: locally this would dirty the submodule.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  rm -rf ./scripts/script-helpers/tests
fi

chmod +x ./tools/gen-man.sh || true

./tools/gen-man.sh
