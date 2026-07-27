#!/usr/bin/env bash
# Fail when config.yaml options drift out of sync with what users actually see.
#
# translations/en.yaml is silently forgiving: an unmatched key is ignored and
# the raw option name reappears in the Home Assistant UI, so a rename degrades
# the interface with no error anywhere.
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0

schema=$(ruby -ryaml -e 'puts YAML.load_file("claude-terminal/config.yaml")["schema"].keys' 2>/dev/null \
  || python3 -c 'import yaml,sys;print("\n".join(yaml.safe_load(open("claude-terminal/config.yaml"))["schema"]))')

for k in $schema; do
  grep -q "^  ${k}:" claude-terminal/translations/en.yaml \
    || { echo "FAIL: option '$k' has no label in translations/en.yaml"; rc=1; }
  grep -q "\`${k}\`" claude-terminal/DOCS.md \
    || { echo "FAIL: option '$k' is undocumented in DOCS.md"; rc=1; }
done

# and the reverse: a translation for an option that no longer exists
tr_keys=$(awk '/^configuration:/{f=1;next} /^[a-z]/{f=0} f && /^  [a-z_]+:/{gsub(/[ :]/,"");print}' \
  claude-terminal/translations/en.yaml)
for k in $tr_keys; do
  echo "$schema" | grep -qx "$k" || { echo "FAIL: translations/en.yaml labels '$k', which is not in the schema"; rc=1; }
done

# config.yaml value-type checks. A wrong TYPE here is not a lint nit: the
# Supervisor skips a config it cannot parse and the add-on silently never
# appears in the store, with the reason only in the Supervisor log.
apparmor=$(ruby -ryaml -e 'v=YAML.load_file("claude-terminal/config.yaml")["apparmor"]; print v.inspect' 2>/dev/null)
case "$apparmor" in
  true|false|nil) ;;
  *) echo "FAIL: config.yaml apparmor must be a boolean, got ${apparmor} (the Supervisor validates vol.Boolean; a profile name fails the whole file)"; rc=1 ;;
esac

# the custom profile is installed under the add-on slug, so the profile
# declared in apparmor.txt has to match it
if [ -f claude-terminal/apparmor.txt ]; then
  slug=$(ruby -ryaml -e 'print YAML.load_file("claude-terminal/config.yaml")["slug"]' 2>/dev/null)
  grep -q "profile ${slug}" claude-terminal/apparmor.txt \
    || { echo "FAIL: apparmor.txt does not declare 'profile ${slug}'"; rc=1; }
fi

[ "$rc" -eq 0 ] && echo "DOCS DRIFT: clean ($(echo "$schema" | wc -w | tr -d ' ') options)" || echo "DOCS DRIFT: failures above"
exit $rc
