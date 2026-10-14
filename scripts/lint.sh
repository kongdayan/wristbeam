#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
task_developer="$(/usr/bin/xcode-select -p)"
if [[ "$task_developer" == /Library/Developer/CommandLineTools && -d "$task_developer/usr/lib/sourcekitdInProc.framework" ]]; then
  export XCODE_DEFAULT_TOOLCHAIN_OVERRIDE="$task_developer"
fi
actionlint -color
shellcheck scripts/update-helper.sh
for task_script in scripts/*.sh; do zsh -n "$task_script"; done
swiftlint lint --strict --quiet
