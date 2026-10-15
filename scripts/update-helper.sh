#!/bin/sh
# Invoked only by the installed application after confirmation and validation.
set -eu
update_pid="$1"
update_stage="$2"
update_target="$3"
update_dir="$4"
update_result="$5"
case "$update_pid" in ''|*[!0-9]*) exit 1 ;; esac
update_attempt=0
while kill -0 "$update_pid" 2>/dev/null; do
  update_attempt=$((update_attempt + 1))
  if [ "$update_attempt" -gt 150 ]; then printf '%s\n' 'Previous process did not exit; original application retained.' > "$update_result"; exit 1; fi
  sleep 0.2
done
update_backup="$update_dir/Rollback.noindex/Previous.app"
# Preserve recovery without leaving another launchable app in Spotlight.
if ! /usr/bin/ditto -c -k --keepParent "$update_target" "$update_dir/Previous.zip"; then
  printf '%s\n' 'Cannot archive current application; original retained.' > "$update_result"
  exit 1
fi
/bin/mkdir -p "$update_dir/Rollback.noindex"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$update_target" >/dev/null 2>&1 || true
if ! /bin/mv "$update_target" "$update_backup"; then printf '%s\n' 'Cannot move current application; original retained.' > "$update_result"; exit 1; fi
if ! /bin/mv "$update_stage" "$update_target"; then
  /bin/mv "$update_backup" "$update_target"
  printf '%s\n' 'Replacement failed; previous application restored.' > "$update_result"
  /usr/bin/open "$update_target"
  exit 1
fi
if /usr/bin/open "$update_target"; then
  /bin/rm -rf "$update_dir/Rollback.noindex"
  printf '%s\n' 'Installed and relaunched; previous application archived as Previous.zip.' > "$update_result"
else
  /bin/mv "$update_target" "$update_dir/Rollback.noindex/Failed.app"
  /bin/mv "$update_backup" "$update_target"
  printf '%s\n' 'Relaunch failed; previous application restored.' > "$update_result"
  /usr/bin/open "$update_target"
  exit 1
fi
