#!/bin/bash
# verify.sh <results-dir> -- reproduce the JDK offline and compare with expected/<major>.
set -euo pipefail
source "$(dirname "$0")/common.sh"
results=${1:?usage: verify.sh <results-dir>}

"$ROOT/run.sh" "$results"
diff "$ROOT/expected/$JDK_MAJOR/hashes.txt" "$results/hashes-${ONE_VENDOR:-tem}.txt"
(cd "$results" && sha256sum -c "$ROOT/expected/$JDK_MAJOR/deb.sha256")
echo "REPRODUCED: $(wc -l < "$results/hashes-${ONE_VENDOR:-tem}.txt") files and the .deb match expected/$JDK_MAJOR"
