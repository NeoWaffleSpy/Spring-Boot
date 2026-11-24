#!/bin/bash
# Regenerates core's page template from src/main/resources/Event_mapper.sh, the single source of
# truth for the page. Run it after changing the page in the script, then rebuild core.
#   {{TITLE}} = the page title, {{DATA}} = the graph JSON (plus the IDE's own settings)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../src/main/resources/Event_mapper.sh"
out="$here/src/main/resources/com/eventmapper/core/page/event-map.html"
mkdir -p "$(dirname "$out")"

awk '
  doc != "" { if ($0 == doc) doc = ""; else print; next }
  /^html_(head|tail)\(\) \{$/ { fn = $1; next }
  fn == "" { next }
  /^\}$/ { if (fn == "html_head()") print "{{DATA}}"; fn = ""; next }
  /^cat <<.EOF_HTML_[A-Z]+.$/ { doc = $2; gsub(/[<'\'']/, "", doc); next }
  /^printf / {
    s = $0
    sub(/^printf '\''/, "", s); sub(/'\'' "\$TITLE_HTML"$/, "", s)
    gsub(/%s/, "{{TITLE}}", s); sub(/\\n$/, "", s)
    print s; next
  }
  { print "extract-page.sh: unexpected line in " fn ": " $0 > "/dev/stderr"; bad = 1 }
  END { exit bad }
' "$src" > "$out"

grep -q '{{DATA}}' "$out" && grep -q '{{TITLE}}' "$out"
echo "Wrote $out ($(wc -l < "$out") lines)"
