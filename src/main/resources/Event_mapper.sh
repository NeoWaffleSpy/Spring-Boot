#!/usr/bin/env bash
# =============================================================================
#  Event_mapper.sh - Map asynchronous event call chains in a Java codebase and
#  produce ONE self-contained, interactive HTML page (the "Bible").
#
#  Needs only: bash, find, awk  (Linux, macOS, WSL, Git Bash on Windows).
#
#  Usage:
#     ./Event_mapper.sh /path/to/repo                    -> ./repo.html (folder name)
#     ./Event_mapper.sh /path/to/repo out.html           -> out.html
#     ./Event_mapper.sh /path/to/repo out.html graph.json  (+ raw graph data)
#     ./Event_mapper.sh --logs /path/to/logs /path/to/repo  (+ *.log files, searched
#                      recursively; the folder can be anywhere; repeat --logs for more)
#
#  It finds:
#    * Endpoints       methods carrying an ENDPOINT_ANNOTATIONS annotation
#    * Emissions       EMIT_METHODS calls:  bus.emit("evt") / emit(Events.X)
#                      / fire(new SomeEvent(..))                  -> "emits"
#    * Listeners       @LISTEN_ANNOTATIONS("evt") on a method, or
#                      LISTEN_METHODS calls: subscribe("evt", handler) where
#                      handler = this::m | Foo::m | lambda | new X(){..} | obj
#                                                                 -> "handled by"
#    * Method calls    same class, fields / injected params, interface ->
#                      implementations, so endpoint -> service -> emit chains
#                      connect                                    -> "calls"
#    * Blind spots     emit(variable) and handlers it couldn't resolve
#    * Flows           every entry point (endpoints, events fired from outside,
#                      code nothing in the scan calls) with all it triggers
#    * Logs (--logs)   hops on the event bus per address (calls, replies, times,
#                      errors), joined to the map: events seen ×N / never seen;
#                      error and warning patterns; LOG_RULES counts; observed
#                      lifecycles (hops chained by timing, checked against the code)
#
#  Deferred calls count as calls: future.onSuccess(this::handle), compose(Foo::m),
#  onComplete(new Done()), consumer(addr, this) -> the handle()/accept()... run.
#
#  It is a heuristic (tokenizer + brace matching), not a compiler.
# =============================================================================

# ============================== CONFIG =======================================
# Edit these lists to match the event API of the codebase you scan. Space-separated names.

# Method names that FIRE an event:   bus.emit("x"), fire(new XEvent())...
EMIT_METHODS="emit publish fire dispatch trigger raise"

# Method names that REGISTER a listener: bus.subscribe("x", this::onX)...
LISTEN_METHODS="on subscribe hook listen addListener addHandler register registerListener registerHandler"

# Annotations that mark a method as a listener: @OnEvent("x"), @Hook(Events.X),
# @Subscribe(XEvent.class), or @Subscribe void on(XEvent e) (parameter type).
LISTEN_ANNOTATIONS="OnEvent Hook Subscribe EventHandler EventListener Listen Listener"

# Annotation keys that hold the event name, e.g. @OnEvent(event = "x")
EVENT_ANNOTATION_KEYS="value event events topic topics name"

# Annotations that mark an endpoint, as Name=VERB (ANY = no fixed verb).
ENDPOINT_ANNOTATIONS="GetMapping=GET PostMapping=POST PutMapping=PUT DeleteMapping=DELETE PatchMapping=PATCH RequestMapping=ANY GET=GET POST=POST PUT=PUT DELETE=DELETE PATCH=PATCH"

# Method names that register an endpoint at run time, called as
#   router.addRoute(HttpMethod.POST, endpointName, (o, event) -> { ... })
# (verb, name, handler: a lambda, this::m / Foo::m, or anything else -> unresolved).
# Each call becomes an endpoint named "Lambda <method that registers it>".
ROUTE_METHODS="addRoute"

# Method names of HTTP clients. A call whose arguments hold a URL (string
# literals and String constants, "+ variable" parts act as wildcards) is matched
# to the endpoint with that path, e.g. restTemplate.postForObject("/orders", ..)
# or webClient.get().uri("/orders/" + id). The verb comes from an HttpMethod.X
# argument, the method name (getFor.., postFor..) or webClient.get()/post()...
CLIENT_METHODS="getForObject getForEntity postForObject postForEntity postForLocation put delete patchForObject exchange uri"

# Annotations whose first string is a URL path (class-level = prefix).
PATH_ANNOTATIONS="RequestMapping Path"

# When a listener is registered as an object (subscribe("x", new Foo()) or
# subscribe("x", this)), methods with these names are taken as the callback.
CALLBACK_METHODS="handle onEvent on accept apply call run execute process notify"

# Folder names skipped anywhere in the tree.
EXCLUDE_DIRS="test tests build target out generated .git node_modules"

# Folder names whose content is still scanned but flagged in the page with a
# tint and a small folder tag, as name=colour. A folder listed here is scanned
# even if EXCLUDE_DIRS names it. Colours: orange green blue purple red yellow
# teal pink grey, or a hex value like #c0392b.
SPECIAL_DIRS="target=orange test=green"

# 1 = follow plain method calls so chains connect; 0 = events only.
FOLLOW_CALLS=1

# Folders searched recursively for *.log files, space-separated (no spaces inside
# a path here; use --logs for those). They can be outside the scanned folder.
# --logs DIR on the command line adds to this list.
LOG_DIRS=""

# How log lines are read. Rules marked "one per line" take as many lines as needed: add a
# line for a new tag or pattern, nothing else to change. Regexes are POSIX extended (awk).
#
# A line that starts a record; other lines continue the record above (stack traces...).
LOG_START='^[0-9][0-9]/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]'
# Separator between the fields of a record, and the field names in order (the last one takes
# the rest of the line). "time", "level" and "message" are used; other names are skipped.
LOG_SEP=' - '
LOG_FIELDS="time category level message"
# Correlation tags at the start of the message, as kind=regex (one per line).
LOG_IDS='
action=^\[action-[A-Za-z0-9]+\]
event=^\[event-[A-Za-z0-9]+\]
internal-call=^\[internal-call-[A-Za-z0-9]+\]
'
# After a tag, a hop on the event bus: its request ">> @address Sender->Receiver payload"
# and its reply "<< status payload". Messages starting with a LOG_SKIP prefix (|-separated)
# are ignored.
LOG_REQUEST='>> @'
LOG_REPLY='<< '
LOG_SKIP='>> headers:|<< headers:'
# Levels whose messages are grouped into patterns (numbers, ids and quoted text replaced by
# placeholders, so similar messages count together).
LOG_PATTERN_LEVELS="ERROR WARN"
# Hops linked into lifecycles: a hop sent by X while a hop received by X is still waiting
# for its reply is taken as its child (the latest such hop, at most LOG_LINK_WINDOW ms old).
LOG_LINK_WINDOW=30000
# Named rules counted on every record, as name=regex (one per line).
LOG_RULES='
connection-refused=Connection refused
timeout=[Tt]ime[d]? ?out
'
# ============================ END CONFIG =====================================

set -eu

usage() { sed -n '2,/^# =* CONFIG/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

POS=()
LOG_LIST=()
for d in $LOG_DIRS; do LOG_LIST+=("$d"); done
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -l|--logs)
      if [ $# -lt 2 ]; then echo "$1 needs a folder" >&2; exit 1; fi
      LOG_LIST+=("$2"); shift 2 ;;
    --logs=*) LOG_LIST+=("${1#--logs=}"); shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
ROOT="${POS[0]:-}"
OUT="${POS[1]:-}"
JSON_OUT="${POS[2]:-}"
if [ -z "$ROOT" ]; then usage; exit 0; fi
if [ ! -d "$ROOT" ]; then echo "Not a directory: $ROOT" >&2; exit 1; fi
if [ ${#LOG_LIST[@]} -gt 0 ]; then
  for d in "${LOG_LIST[@]}"; do
    if [ ! -d "$d" ]; then echo "Not a log folder: $d" >&2; exit 1; fi
  done
fi

AWK_BIN="${AWK:-}"
if [ -z "$AWK_BIN" ]; then
  for a in gawk mawk nawk awk; do
    if command -v "$a" >/dev/null 2>&1; then AWK_BIN="$a"; break; fi
  done
fi
if [ -z "$AWK_BIN" ]; then echo "No awk found." >&2; exit 1; fi

ROOT_ABS="$(cd "$ROOT" && pwd -P)"
# the scanned folder's name: default output file name and page title
NAME="$(basename "$ROOT_ABS")"
case "$NAME" in ""|/|.) NAME="event-map" ;; esac
if [ -z "$OUT" ]; then OUT="$NAME.html"; fi
TITLE_HTML="$(printf '%s' "$NAME" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')"
ROOT_LINK="$ROOT_ABS"
if command -v cygpath >/dev/null 2>&1; then ROOT_LINK="$(cygpath -m "$ROOT_ABS")"; fi

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t evmap)"
trap 'rm -rf "$TMP"' EXIT

# ---- list Java files ---------------------------------------------------------
PRUNE=()
for d in $EXCLUDE_DIRS; do
  case " $SPECIAL_DIRS " in *" $d="*) continue ;; esac   # special folders are scanned
  if [ ${#PRUNE[@]} -eq 0 ]; then PRUNE=(-name "$d"); else PRUNE+=(-o -name "$d"); fi
done
if [ ${#PRUNE[@]} -gt 0 ]; then
  (cd "$ROOT_ABS" && find . -type d \( "${PRUNE[@]}" \) -prune -o -type f -name '*.java' -print) > "$TMP/files.txt"
else
  (cd "$ROOT_ABS" && find . -type f -name '*.java' -print) > "$TMP/files.txt"
fi
echo "Scanning $(wc -l < "$TMP/files.txt" | tr -d ' ') Java files with $AWK_BIN ..." >&2

# ---- components: every folder holding a pom.xml ---------------------------------
if [ ${#PRUNE[@]} -gt 0 ]; then
  COMPONENTS="$(cd "$ROOT_ABS" && find . -type d \( "${PRUNE[@]}" \) -prune -o -type f -name pom.xml -print)"
else
  COMPONENTS="$(cd "$ROOT_ABS" && find . -type f -name pom.xml -print)"
fi
[ -n "$COMPONENTS" ] && COMPONENTS="$(printf '%s\n' "$COMPONENTS" | sed -e 's|^\./||' -e 's|/*pom\.xml$||' -e 's|^$|.|' | sort -u | tr '\n' '|')"

# ---- log files: *.log under each log folder, as "bytes<TAB>path<TAB>path shown" ---
: > "$TMP/logs.txt"
if [ ${#LOG_LIST[@]} -gt 0 ]; then
  for d in "${LOG_LIST[@]}"; do
    dabs="$(cd "$d" && pwd -P)"
    find "$dabs" -type f -name '*.log' -print | sort | while IFS= read -r f; do
      b="$(wc -c < "$f" | tr -d ' ')"
      shown="$f"
      if command -v cygpath >/dev/null 2>&1; then shown="$(cygpath -m "$f")"; fi
      printf '%s\t%s\t%s\n' "$b" "$f" "$shown"
    done >> "$TMP/logs.txt"
  done
  echo "Found $(wc -l < "$TMP/logs.txt" | tr -d ' ') log files in ${#LOG_LIST[@]} folder(s)." >&2
fi

# ---- the analyser (awk) ------------------------------------------------------
read -r -d '' AWK_PROG <<'EOF_AWK' || true
# Event_mapper analyser - portable POSIX awk (gawk, mawk, BSD/macOS awk, busybox)
# Input : -v listfile=<file with one path per line> and config variables.
# Output: graph JSON in -v outfile.

BEGIN {
  LS = "\035"
  nw = split("if for while switch catch synchronized return new else try do throw super this assert case finally instanceof yield default class interface enum record", w, " ")
  for (i = 1; i <= nw; i++) CTRL[w[i]] = 1
  nw = split("return else case throw yield do assert", w, " ")
  for (i = 1; i <= nw; i++) STMT[w[i]] = 1
  nw = split(emit_methods, w, " ");   for (i = 1; i <= nw; i++) EMIT[w[i]] = 1
  nw = split(listen_methods, w, " "); for (i = 1; i <= nw; i++) LISTEN[w[i]] = 1
  nw = split(listen_ann, w, " ");     for (i = 1; i <= nw; i++) LANN[w[i]] = 1
  nw = split(ev_keys, w, " ");        for (i = 1; i <= nw; i++) EVKEY[w[i]] = 1
  nw = split(path_ann, w, " ");       for (i = 1; i <= nw; i++) PATHANN[w[i]] = 1
  nCB = split(callback_methods, CBL, " ")
  nw = split(route_methods, w, " ");  for (i = 1; i <= nw; i++) ROUTE[w[i]] = 1
  nw = split(client_methods, w, " "); for (i = 1; i <= nw; i++) CLIENT[w[i]] = 1
  nw = split(endpoint_ann, w, " ")
  for (i = 1; i <= nw; i++) { p = index(w[i], "="); if (p) EPANN[substr(w[i], 1, p - 1)] = substr(w[i], p + 1); else EPANN[w[i]] = "ANY" }
  FOLLOW = (follow_calls + 0 != 0)

  nFiles = 0
  while ((getline path < listfile) > 0) {
    if (path == "") continue
    rel = path; sub(/^\.\//, "", rel)
    readFile(path)
    matchBrackets()
    walkFile(rel)
    nFiles++
  }
  close(listfile)
  resolveAndWrite()
  exit
}

# ------------------------------------------------------------------ lexer ---
function readFile(p,   line, n) {
  split("", T); split("", K); split("", L); split("", PM); split("", LN)
  nt = 0; n = 0; inBC = 0; inTB = 0; tbuf = ""
  while ((getline line < p) > 0) {
    n++; sub(/\r$/, "", line); LN[n] = line
    tokLine(line, n)
  }
  close(p)
}

function addTok(t, k, ln) { nt++; T[nt] = t; K[nt] = k; L[nt] = ln }

function tokLine(s, ln,   pos, len, c, c2, j, rest, q) {
  len = length(s); pos = 1
  while (pos <= len) {
    if (inBC) {
      j = index(substr(s, pos), "*/")
      if (j == 0) return
      pos += j + 1; inBC = 0; continue
    }
    if (inTB) {
      j = index(substr(s, pos), "\"\"\"")
      if (j == 0) { tbuf = tbuf substr(s, pos) " "; return }
      tbuf = tbuf substr(s, pos, j - 1); addTok(tbuf, "s", tbLine)
      inTB = 0; pos += j + 2; continue
    }
    c = substr(s, pos, 1)
    if (c == " " || c == "\t" || c == "\f") { pos++; continue }
    c2 = substr(s, pos, 2)
    if (c2 == "//") return
    if (c2 == "/*") { inBC = 1; pos += 2; continue }
    if (substr(s, pos, 3) == "\"\"\"") { inTB = 1; tbuf = ""; tbLine = ln; pos += 3; continue }
    if (c == "\"" || c == "\047") {
      j = pos + 1
      while (j <= len) {
        q = substr(s, j, 1)
        if (q == "\\") { j += 2; continue }
        if (q == c) break
        j++
      }
      addTok(substr(s, pos + 1, j - pos - 1), (c == "\"") ? "s" : "c", ln)
      pos = j + 1; continue
    }
    if (c ~ /[A-Za-z_$]/) {
      rest = substr(s, pos); match(rest, /^[A-Za-z0-9_$]+/)
      addTok(substr(rest, 1, RLENGTH), "i", ln); pos += RLENGTH; continue
    }
    if (c ~ /[0-9]/) {
      rest = substr(s, pos); match(rest, /^[0-9][0-9A-Za-z_.]*/)
      addTok(substr(rest, 1, RLENGTH), "n", ln); pos += RLENGTH; continue
    }
    if (c2 == "::" || c2 == "->") { addTok(c2, "p", ln); pos += 2; continue }
    addTok(c, "p", ln); pos++
  }
}

function matchBrackets(   i, sp, sb, t) {
  sp = 0; sb = 0
  for (i = 1; i <= nt; i++) {
    if (K[i] != "p") continue
    t = T[i]
    if (t == "(") PS[++sp] = i
    else if (t == ")") { if (sp > 0) { PM[PS[sp]] = i; PM[i] = PS[sp]; sp-- } }
    else if (t == "{") BS[++sb] = i
    else if (t == "}") { if (sb > 0) { PM[BS[sb]] = i; PM[i] = BS[sb]; sb-- } }
  }
}

# ---------------------------------------------------------- structure walk ---
function walkFile(rel,   i, j, t, k, a, imp, k2) {
  pkg = ""
  for (i = 1; i <= nt; i++) {
    if (T[i] == "package" && K[i] == "i") { j = i + 1; while (j <= nt && T[j] != ";") { pkg = pkg T[j]; j++ }; break }
    if (T[i] == "class" || T[i] == "interface" || T[i] == "enum") break
  }
  for (i = 1; i <= nt; i++) {
    if (T[i] == "class" || T[i] == "interface" || T[i] == "enum" || T[i] == "@") break
    if (T[i] == "import" && K[i] == "i") {
      j = i + 1; if (T[j] == "static") j++
      imp = ""; while (j <= nt && T[j] != ";") { imp = imp T[j]; j++ }
      if (imp ~ /\.\*$/) addList(WILD, rel, substr(imp, 1, length(imp) - 2), "W")
      else { k2 = imp; sub(/^.*\./, "", k2); IMP[rel SUBSEP k2] = imp }
      i = j
    }
  }
  depth = 0; ctxKind[0] = "FILE"; ctxParen[0] = 0; ctxFq[0] = ""; ctxQual[0] = ""; ctxId[0] = ""; ctxClose[0] = nt + 1
  pd = 0; nAnn = 0; nTA = 0; pendType = ""
  split("", pendLam); split("", exprEnd); split("", exprId); split("", anonL); split("", anonC); split("", USEDREF)
  for (i = 1; i <= nt; i++) {
    while (depth > 0 && ctxKind[depth] == "EXPR" && i >= ctxClose[depth]) depth--
    if (i in exprId) {
      depth++; ctxKind[depth] = "EXPR"; ctxId[depth] = exprId[i]; ctxClose[depth] = exprEnd[i]
      ctxParen[depth] = pd; ctxFq[depth] = ctxFq[depth - 1]; ctxQual[depth] = ctxQual[depth - 1]
    }
    t = T[i]; k = K[i]
    if (k == "p") {
      if (t == "(") pd++
      else if (t == ")") pd--
      else if (t == "{") openBrace(i, rel)
      else if (t == "::") refCall(i, rel)
      else if (t == "}") {
        if (depth > 0) { if (ctxKind[depth] == "TYPE" || ctxKind[depth] == "METHOD") nAnn = 0; depth-- }
      }
      else if (typeLevel()) {
        if (t == "@" && K[i + 1] == "i" && T[i + 1] != "interface") collectAnn(i)
        else if (t == "=" || t == ";" || t == ",") { fieldCheck(i); if (t == ";") nAnn = 0 }
      }
      continue
    }
    if (k != "i") continue
    if ((t == "class" || t == "interface" || t == "enum" || t == "record") && T[i - 1] != "." && K[i + 1] == "i" && pendType == "") {
      pendType = T[i + 1]; pendKind = t; pendIdx = i; pendPd = pd; pendLine = L[i + 1]
      nTA = nAnn
      for (a = 1; a <= nAnn; a++) { taName[a] = annName[a]; taS[a] = annS[a]; taE[a] = annE[a] }
      nAnn = 0
      continue
    }
    if (T[i + 1] == "(") callLike(i, rel)
  }
}

function typeLevel() { return ((ctxKind[depth] == "TYPE" || ctxKind[depth] == "FILE") && pd == ctxParen[depth]) }

function curScope(   d) {
  for (d = depth; d >= 1; d--) {
    if (ctxKind[d] == "METHOD" || ctxKind[d] == "LAMBDA" || ctxKind[d] == "EXPR") return ctxId[d]
    if (ctxKind[d] == "TYPE") return "class:" ctxFq[d]
  }
  return ""
}

function pushCtx(kind, id) {
  depth++; ctxKind[depth] = kind; ctxId[depth] = id; ctxParen[depth] = pd
  ctxFq[depth] = ctxFq[depth - 1]; ctxQual[depth] = ctxQual[depth - 1]
}

function openBrace(i, rel,   prevT, p, j, nm, cl) {
  prevT = T[i - 1]
  if (pendType != "" && pd == pendPd) { newType(i, rel, 0); return }
  if (prevT == ")" && ((i - 1) in PM)) { p = PM[i - 1]; if (isAnonAt(p)) { newType(i, rel, p); return } }
  if (ctxKind[depth] == "TYPE" && pd == ctxParen[depth]) {
    cl = i - 1
    if (K[cl] == "i") {
      j = cl
      while (j > 0 && (K[j] == "i" || T[j] == "," || T[j] == ".") && T[j] != "throws") j--
      if (T[j] == "throws") cl = j - 1
    }
    if (T[cl] == ")" && (cl in PM)) {
      p = PM[cl]; nm = T[p - 1]
      if (K[p - 1] == "i" && !(nm in CTRL) && nm !~ /^[A-Z0-9_]+$/ && T[p - 2] != "new") { newMethod(i, rel, p, cl, nm); return }
    }
  }
  if (prevT == "->" && (i in pendLam)) { pushCtx("LAMBDA", pendLam[i]); return }
  pushCtx("BLOCK", "")
}

function isAnonAt(p,   j, ad) {
  j = p - 1
  if (T[j] == ">") {
    ad = 0
    while (j > 0) { if (T[j] == ">") ad++; else if (T[j] == "<") { ad--; if (ad == 0) break }; j-- }
    j--
  }
  if (K[j] != "i") return 0
  anonSimple = T[j]
  while (T[j - 1] == "." && K[j - 2] == "i") j -= 2
  return (T[j - 1] == "new")
}

function addList(arr, key, val, tag) {
  if ((tag SUBSEP key SUBSEP val) in SEEN) return
  SEEN[tag SUBSEP key SUBSEP val] = 1
  if (key in arr) arr[key] = arr[key] LS val; else arr[key] = val
}

function firstStr(s, e,   j) {
  if (!s) return ""
  for (j = s + 1; j < e; j++) if (K[j] == "s") return T[j]
  return ""
}

function newType(i, rel, anonP,   par, d, qual, fq, simple, j, ad, mode, a, pre, s, sup) {
  par = 0
  for (d = depth; d >= 1; d--) if (ctxKind[d] == "TYPE") { par = d; break }
  if (anonP) {
    simple = anonSimple
    qual = (par ? ctxQual[par] : "?") "$new " simple "@L" L[anonP]
  } else {
    simple = pendType
    qual = (par ? ctxQual[par] "." : "") simple
  }
  fq = (pkg != "" ? pkg "." : "") qual
  if (!(fq in tFile)) {
    tPkg[fq] = pkg; tFile[fq] = rel; tLine[fq] = anonP ? L[anonP] : pendLine; tQual[fq] = qual; tSimple[fq] = simple
    tAnon[fq] = anonP ? 1 : 0; tKind[fq] = anonP ? "anon" : pendKind; tOuter[fq] = par ? ctxFq[par] : ""; tPrefix[fq] = ""
    if (anonP) { tSup[fq] = simple; addList(IMPL, simple, fq, "I") }
    else {
      addList(BYS, simple, fq, "B")
      ad = 0; mode = 0; sup = ""
      for (j = pendIdx + 2; j < i; j++) {
        if (T[j] == "<") ad++
        else if (T[j] == ">") ad--
        else if (ad == 0 && (T[j] == "extends" || T[j] == "implements")) mode = 1
        else if (ad == 0 && T[j] == "permits") mode = 0
        else if (mode && ad == 0 && K[j] == "i" && T[j + 1] != ".") { sup = sup LS T[j]; addList(IMPL, T[j], fq, "I") }
      }
      tSup[fq] = substr(sup, 2)
      pre = ""
      for (a = 1; a <= nTA; a++) if (taName[a] in PATHANN) { s = firstStr(taS[a], taE[a]); if (s != "") { pre = s; break } }
      tPrefix[fq] = pre
    }
  }
  if (anonP && (i in anonL)) { Lkind[anonL[i]] = "anon"; Ltarget[anonL[i]] = fq }
  if (anonP && (i in anonC)) ObAnon[anonC[i]] = fq
  if (!anonP) { pendType = ""; nTA = 0 }
  depth++; ctxKind[depth] = "TYPE"; ctxId[depth] = ""; ctxParen[depth] = pd; ctxFq[depth] = fq; ctxQual[depth] = qual
  nAnn = 0
}

function collectAnn(i,   j, name) {
  j = i + 1; name = T[j]
  while (T[j + 1] == "." && K[j + 2] == "i") { j += 2; name = T[j] }
  nAnn++; annName[nAnn] = name
  if (T[j + 1] == "(" && ((j + 1) in PM)) { annS[nAnn] = j + 1; annE[nAnn] = PM[j + 1] }
  else { annS[nAnn] = 0; annE[nAnn] = 0 }
}

function addRole(mid, r) { if (index(" " mRoles[mid] " ", " " r " ") == 0) mRoles[mid] = mRoles[mid] " " r }

function newMethod(i, rel, p, cl, nm,   fq, mid, a, j, verb, path, pre, n, firstPT, ln) {
  fq = ctxFq[depth]; mid = fq "#" nm; ln = L[p - 1]
  if (!(mid in mFile)) { mFile[mid] = rel; mLine[mid] = ln; mFq[mid] = fq; mName[mid] = nm; mRoles[mid] = "" }
  if (!((fq SUBSEP nm) in TM)) { TM[fq SUBSEP nm] = mid; TMC[fq]++; if (!(fq in TMfirst)) TMfirst[fq] = mid }
  firstPT = parseParams(p, cl, fq)
  for (a = 1; a <= nAnn; a++) {
    if (annName[a] in EPANN) {
      verb = EPANN[annName[a]]; if (verb == "ANY") verb = ""
      path = firstStr(annS[a], annE[a])
      if (path == "") for (j = 1; j <= nAnn; j++) if (annName[j] in PATHANN) { path = firstStr(annS[j], annE[j]); if (path != "") break }
      addRole(mid, "endpoint")
      if (verb != "" || !(mid in mVerb)) mVerb[mid] = verb
      pre = tPrefix[fq]
      if (path != "" || pre != "") {
        path = pre "/" path; gsub(/\/\/+/, "/", path); sub(/\/$/, "", path)
        if (path == "") path = "/"
        mPath[mid] = path
      }
    }
    if (annName[a] in LANN) {
      n = annEvents(annS[a], annE[a])
      if (n == 0 && firstPT ~ /^[A-Z]/) addListener("C:" firstPT, "method", mid, rel, ln, fq, mid)
      for (j = 1; j <= n; j++) addListener(AEV[j], "method", mid, rel, ln, fq, mid)
    }
  }
  nAnn = 0
  depth++; ctxKind[depth] = "METHOD"; ctxId[depth] = mid; ctxParen[depth] = pd
  ctxFq[depth] = fq; ctxQual[depth] = ctxQual[depth - 1]
}

function parseParams(p, cl, fq,   j, pdp, ad, first, typ, name, res) {
  res = ""; first = 1; typ = ""; name = ""; pdp = 0; ad = 0
  for (j = p + 1; j <= cl; j++) {
    if (j == cl || (T[j] == "," && pdp == 0 && ad == 0)) {
      if (typ != "" && name != "" && !((fq SUBSEP name) in TF)) TF[fq SUBSEP name] = typ
      if (first) { res = typ; first = 0 }
      typ = ""; name = ""; continue
    }
    if (T[j] == "@" && K[j + 1] == "i") {
      j++; while (T[j + 1] == "." && K[j + 2] == "i") j += 2
      if (T[j + 1] == "(" && ((j + 1) in PM)) j = PM[j + 1]
      continue
    }
    if (T[j] == "(") pdp++
    else if (T[j] == ")") pdp--
    else if (T[j] == "<") ad++
    else if (T[j] == ">") ad--
    else if (K[j] == "i" && ad == 0 && pdp == 0 && T[j] != "final") {
      if (typ == "") { typ = T[j]; while (T[j + 1] == "." && K[j + 2] == "i") { j += 2; typ = T[j] } }
      else name = T[j]
    }
  }
  return res
}

function annEvents(s, e,   j, n, ch, key, pdep) {
  n = 0; key = ""; pdep = 0
  if (!s) return 0
  for (j = s + 1; j < e; j++) {
    if (T[j] == "(" || T[j] == "{") pdep++
    else if (T[j] == ")" || T[j] == "}") pdep--
    else if (T[j] == "," && pdep == 0) key = ""
    else if (K[j] == "i" && T[j + 1] == "=") { key = T[j]; j++ }
    else if (key == "" || (key in EVKEY)) {
      if (K[j] == "s") AEV[++n] = "S:" T[j]
      else if (K[j] == "i") {
        ch = T[j]; while (T[j + 1] == "." && K[j + 2] == "i") { j += 2; ch = ch "." T[j] }
        if (ch ~ /^[A-Z]/ || ch ~ /\.[A-Z]/) AEV[++n] = "C:" ch
      }
    }
  }
  return n
}

function fieldCheck(i,   fq, nm, j, ad, s, hasS, hasF, q, tgt) {
  fq = ctxFq[depth]; if (fq == "") return
  nm = T[i - 1]; if (K[i - 1] != "i" || (nm in CTRL)) return
  j = i - 2
  if (T[i] == "=" && T[j] == "String" && (K[i + 1] == "s" || K[i + 1] == "i")) {
    hasS = 0; hasF = 0
    for (s = j - 1; s > 0 && T[s] != ";" && T[s] != "{" && T[s] != "}"; s--) { if (T[s] == "static") hasS = 1; if (T[s] == "final") hasF = 1 }
    if ((hasS && hasF) || tKind[fq] == "interface") {
      if (K[i + 1] == "s" && T[i + 2] == ";") {
        if (!(nm in CONST) && !(nm in ALIAS)) CONST[nm] = T[i + 1]
        CONST[tSimple[fq] "." nm] = T[i + 1]
        nDef++; Dname[nDef] = tSimple[fq] "." nm; Dto[nDef] = ""; Dfile[nDef] = rel; Dline[nDef] = L[i]
      }
      else if (K[i + 1] == "i") {
        # alias of another constant: String A = Other.B;  (or = B; inside the same class)
        q = i + 1; tgt = T[q]
        while (T[q + 1] == "." && K[q + 2] == "i") { q += 2; tgt = tgt "." T[q] }
        if (T[q + 1] == ";") {
          if (index(tgt, ".") == 0) tgt = tSimple[fq] "." tgt
          if (!(nm in CONST) && !(nm in ALIAS)) ALIAS[nm] = tgt
          ALIAS[tSimple[fq] "." nm] = tgt
          nDef++; Dname[nDef] = tSimple[fq] "." nm; Dto[nDef] = tgt; Dfile[nDef] = rel; Dline[nDef] = L[i]
        }
      }
    }
  }
  # Handler<String> h = new DoneHandler(): the concrete class says more than the declared type
  if (T[i] == "=" && T[i + 1] == "new" && K[i + 2] == "i") {
    q = i + 2; while (T[q + 1] == "." && K[q + 2] == "i") q += 2
    if (T[q + 1] == "(" || T[q + 1] == "<") { TF[fq SUBSEP nm] = T[q]; return }
  }
  while (T[j] == "]" && T[j - 1] == "[") j -= 2
  if (T[j] == ">") {
    ad = 0
    while (j > 0) { if (T[j] == ">") ad++; else if (T[j] == "<") { ad--; if (ad == 0) break }; j-- }
    j--
  }
  if (K[j] == "i" && T[j] ~ /^[A-Z]/ && !((fq SUBSEP nm) in TF)) TF[fq SUBSEP nm] = T[j]
}

# --------------------------------------------------- calls / events / hooks ---
function parseEv(j, needComma,   ch, q) {
  if (K[j] == "s") { q = j; ch = "S:" T[j] }
  else if (T[j] == "new" && K[j + 1] == "i") {
    q = j + 1; ch = T[q]
    while (T[q + 1] == "." && K[q + 2] == "i") { q += 2; ch = T[q] }
    if (T[q + 1] != "(" && T[q + 1] != "<") return ""
    evEnd = q; return "C:" ch
  }
  else if (K[j] == "i") {
    q = j; ch = T[j]
    while (T[q + 1] == "." && K[q + 2] == "i") { q += 2; ch = ch "." T[q] }
    if (ch !~ /^[A-Z]/ && ch !~ /\.[A-Z]/) return ""
    ch = "C:" ch
  }
  else return ""
  if (needComma) { if (T[q + 1] != ",") return "" }
  else if (T[q + 1] != "," && T[q + 1] != ")") return ""
  evEnd = q
  return ch
}

function addListener(ev, kind, target, rel, ln, ctxT, ctxS) {
  nLs++; Lev[nLs] = ev; Lkind[nLs] = kind; Ltarget[nLs] = target
  Lfile[nLs] = rel; Lline[nLs] = ln; Lctx[nLs] = ctxT; Lscope[nLs] = ctxS
  return nLs
}

function addUnres(rel, ln, sc, text) {
  gsub(/\t/, " ", text); sub(/^ +/, "", text); sub(/ +$/, "", text)
  if (length(text) > 200) text = substr(text, 1, 200)
  nU++; Ufile[nU] = rel; Uline[nU] = ln; Uscope[nU] = sc; Utext[nU] = text
}

# source text of tokens a..b-1, spaced only between words (for unresolved node labels)
function tokText(a, b,   out, x) {
  out = ""
  for (x = a; x < b; x++) out = out ((x > a && K[x] == "i" && K[x - 1] == "i") ? " " : "") (K[x] == "s" ? "\"" T[x] "\"" : T[x])
  if (length(out) > 60) out = substr(out, 1, 57) "..."
  return out
}

# end of the argument starting at token a (first comma outside brackets), at most b
function argEnd(a, b,   x, d) {
  d = 0
  for (x = a; x < b; x++) { if (T[x] == "(" || T[x] == "[" || T[x] == "{") d++; else if (T[x] == ")" || T[x] == "]" || T[x] == "}") d--; else if (T[x] == "," && d == 0) return x }
  return b
}

# HTTP client call: remember its verb and, per argument, the pieces a URL could be made of
# (S:literal, C:Constant, ? = anything else); they are resolved once every constant is known
function clientCall(i, rel, sc, ce,   a, e, x, k, pc, ch, verb, t) {
  t = T[i]; verb = ""
  for (x = i + 2; x < ce; x++) if (T[x] == "." && T[x + 1] ~ /^(GET|POST|PUT|DELETE|PATCH)$/) { verb = T[x + 1]; break }
  if (verb == "" && t == "uri" && T[i - 1] == "." && T[i - 2] == ")" && T[i - 3] == "(" && T[i - 4] ~ /^(get|post|put|delete|patch)$/) verb = toupper(T[i - 4])
  if (verb == "" && match(t, /^(get|post|put|delete|patch)/)) verb = toupper(substr(t, 1, RLENGTH))
  nHC++; HCsc[nHC] = sc; HCf[nHC] = rel; HCl[nHC] = L[i]; HCverb[nHC] = verb; HCn[nHC] = 0
  a = i + 2
  for (k = 1; k <= 6 && a < ce; k++) {
    e = argEnd(a, ce); pc = ""
    for (x = a; x < e; x++) {
      if (K[x] == "s") pc = pc LS "S:" T[x]
      else if (T[x] == "+") continue
      else if (K[x] == "i") {
        ch = T[x]; while (T[x + 1] == "." && K[x + 2] == "i") { x += 2; ch = ch "." T[x] }
        if (T[x + 1] == "(") { pc = pc LS "?"; if ((x + 1) in PM) x = PM[x + 1] }
        else if (ch ~ /^[A-Z]/ || ch ~ /\.[A-Z]/) pc = pc LS "C:" ch
        else pc = pc LS "?"
      }
      else { pc = pc LS "?"; if (T[x] == "(" && (x in PM)) x = PM[x] }
    }
    HCn[nHC] = k; HCarg[nHC, k] = substr(pc, 2)
    a = e + 1
  }
}
# URL of a client call: the first argument whose pieces give a string holding a "/"
function clientUrl(n,   k, np, pp, x, out, v) {
  for (k = 1; k <= HCn[n]; k++) {
    np = split(HCarg[n, k], pp, LS); out = ""
    for (x = 1; x <= np; x++) {
      if (substr(pp[x], 1, 2) == "S:") out = out substr(pp[x], 3)
      else if (substr(pp[x], 1, 2) == "C:") { v = normEv(pp[x]); out = out (evFound ? v : "{}") }
      else out = out "{}"
    }
    if (index(out, "/")) return out
  }
  return ""
}
# endpoints whose path ends the URL (segment by segment; {..} on either side is a wildcard,
# at least one literal segment must match); only the best-scoring ones are kept
function matchUrl(url, verb,   cs, nc, m, es, ne, j, c1, e1, lit, ok, best, out, sc, x) {
  sub(/^[a-zA-Z]+:\/\/[^\/]*/, "", url); sub(/[?#].*/, "", url)
  nc = split(url, cs, "/"); j = 0
  for (m = 1; m <= nc; m++) if (cs[m] != "") cs[++j] = cs[m]
  nc = j; best = 0; out = ""
  for (m in mPath) {
    if (substr(mPath[m], 1, 1) == "{") continue
    if (verb != "" && mVerb[m] != "" && mVerb[m] != verb) continue
    ne = split(mPath[m], es, "/"); j = 0
    for (x = 1; x <= ne; x++) if (es[x] != "") es[++j] = es[x]
    ne = j; if (ne == 0 || ne > nc) continue
    lit = 0; ok = 1
    for (j = 1; j <= ne; j++) {
      c1 = cs[nc - ne + j]; e1 = es[j]
      if (index(c1, "{") || index(e1, "{")) continue
      if (c1 != e1) { ok = 0; break }
      lit++
    }
    if (!ok || lit == 0) continue
    sc = lit * 10 - (nc - ne)
    if (sc > best) { best = sc; out = m } else if (sc == best) out = out LS m
  }
  return out
}

# router.addRoute(VERB, name, handler): an endpoint "Lambda <registering method>" that calls
# the handler (a lambda node, a method reference, or an unresolved handler)
function routeCall(i, rel, sc, fq, ce,   a1, e1, a2, e2, a3, a, rid, own, verb, path, lid, q) {
  a1 = i + 2; e1 = argEnd(a1, ce); if (e1 >= ce) return
  a2 = e1 + 1; e2 = argEnd(a2, ce); if (e2 >= ce) return
  a3 = e2 + 1
  verb = T[e1 - 1]; if (verb !~ /^[A-Z]+$/) verb = "ANY"
  path = (e2 == a2 + 1 && K[a2] == "s") ? T[a2] : "{" tokText(a2, e2) "}"
  own = (sc in mName) ? mName[sc] : sc; sub(/^class:/, "", own); sub(/.*\./, "", own)
  rid = "route:" rel ":" L[i] ":" i
  nRt++; Rid[nRt] = rid; Rlabel[nRt] = "Lambda " own; Rfq[nRt] = fq; Rfile[nRt] = rel; Rline[nRt] = L[i]
  Rverb[nRt] = verb; Rpath[nRt] = path; Rkind[nRt] = "unres"; Rtxt[nRt] = tokText(a3, ce)
  for (a = a3; a < ce; a++) if (T[a] == "->") break
  if (a < ce) {
    lid = sc; sub(/^class:/, "", lid); lid = lid "$\316\273L" L[a]
    lamFile[lid] = rel; lamLine[lid] = L[a]; lamFq[lid] = fq; lamParent[lid] = sc; lamOrd[++nLam] = lid
    if (T[a + 1] == "{") pendLam[a + 1] = lid
    else { exprId[a] = lid; exprEnd[a] = ce }
    Rkind[nRt] = "lambda"; Rtarget[nRt] = lid
    return
  }
  q = a3; while (q < ce && (K[q] == "i" || T[q] == ".")) q++
  if (T[q] == "::" && K[q + 1] == "i" && q > a3 && q + 2 == ce) { Rkind[nRt] = "ref"; Rtarget[nRt] = T[q - 1] LS T[q + 1]; USEDREF[q] = 1 }
}

# A method reference used as a value: future.onSuccess(this::handle), compose(Foo::handle),
# map(mapper::convert). The method runs later, called by whatever receives it, so it counts as a
# call from where the reference is written. (References a listener or a route registers are
# handled there.)
function refCall(i, rel,   sc, recv) {
  if (!FOLLOW || (i in USEDREF) || K[i + 1] != "i" || T[i + 1] == "new") return
  sc = curScope(); if (sc == "" || substr(sc, 1, 6) == "class:") return
  if (T[i - 1] == "this" || T[i - 1] == "super") recv = ""
  else if (K[i - 1] == "i" && T[i - 2] != ".") recv = T[i - 1]
  else return
  nCalls++; Cscope[nCalls] = sc; Cfq[nCalls] = ctxFq[depth]; Crecv[nCalls] = recv; Cname[nCalls] = T[i + 1]; Cfile[nCalls] = rel; Cline[nCalls] = L[i]
}

# An object handed to a call: future.onComplete(new Done()), consumer(addr, this), then(handler),
# with a field or parameter as handler. Its CALLBACK_METHODS (handle, accept, run...) run later,
# called by whatever receives the object. Resolved at the end, when every class is known.
function callbackArgs(o, ce, sc, rel,   a, s, pdp) {
  s = o + 1; pdp = 0
  for (a = o + 1; a <= ce; a++) {
    if (a < ce && (T[a] == "(" || T[a] == "{" || T[a] == "[")) pdp++
    else if (a < ce && (T[a] == ")" || T[a] == "}" || T[a] == "]")) pdp--
    else if (a == ce || (T[a] == "," && pdp == 0)) { if (a > s) callbackArg(s, a, sc, rel); s = a + 1 }
  }
}
function callbackArg(s, e, sc, rel,   q, r, nm) {
  if (e == s + 1 && T[s] == "this") { nOb++; ObK[nOb] = "this"; ObN[nOb] = "" }
  else if (e == s + 1 && K[s] == "i" && T[s] ~ /^[a-z_]/) { nOb++; ObK[nOb] = "var"; ObN[nOb] = T[s] }
  else if (T[s] == "new" && K[s + 1] == "i") {
    q = s + 1; while (T[q + 1] == "." && K[q + 2] == "i") q += 2
    nm = T[q]
    while (q < e && T[q] != "(") q++
    if (T[q] != "(" || !(q in PM)) return
    # the whole argument must be the object: new X(..) or new X(..) { .. }
    r = PM[q] + 1; if (T[r] == "{" && (r in PM)) { anonAt = r; r = PM[r] + 1 } else anonAt = 0
    if (r != e) return
    nOb++; ObK[nOb] = "new"; ObN[nOb] = nm
    if (anonAt) anonC[anonAt] = nOb
  }
  else return
  ObSc[nOb] = sc; ObFq[nOb] = ctxFq[depth]; ObFile[nOb] = rel; ObLine[nOb] = L[s]
}

function callLike(i, rel,   t, prev, sc, fq, inBody, ce, r, j, q, a, lid, n, b, recv, pi, ad) {
  t = T[i]; pi = i - 1
  if (T[pi] == ">") {   # explicit type arguments: recv.<List<Object>>name(...)
    j = pi; ad = 0
    while (j > 0) { if (T[j] == ">") ad++; else if (T[j] == "<") { ad--; if (ad == 0) break }; j-- }
    if (j > 1 && T[j] == "<" && T[j - 1] == ".") pi = j - 1
  }
  prev = T[pi]
  if (prev == "new" || prev == "@") return
  if ((K[i - 1] == "i" && !(prev in STMT)) || prev == ">" || prev == "]") return   # declaration
  sc = curScope(); fq = ctxFq[depth]
  inBody = (sc != "" && substr(sc, 1, 6) != "class:")
  ce = ((i + 1) in PM) ? PM[i + 1] : nt
  if (t in EMIT) {
    r = parseEv(i + 2, 0)
    if (r != "") { if (sc != "") { nEm++; Eev[nEm] = r; Escope[nEm] = sc; Efile[nEm] = rel; Eline[nEm] = L[i] } }
    else if (inBody) {
      addUnres(rel, L[i], sc, LN[L[i]])
      nUE++; UEsc[nUE] = sc; UEf[nUE] = rel; UEl[nUE] = L[i]; UEt[nUE] = tokText(i + 2, argEnd(i + 2, ce))
    }
  }
  else if ((t in ROUTE) && sc != "") routeCall(i, rel, sc, fq, ce)
  else if ((t in LISTEN) && sc != "") {
    r = parseEv(i + 2, 1)
    if (r != "") {
      j = evEnd + 2
      n = addListener(r, "site", sc, rel, L[i], fq, sc)
      Lhx[n] = tokText(j, ce)
      q = j
      while (q < ce && (K[q] == "i" || T[q] == ".")) q++
      if (T[q] == "::" && K[q + 1] == "i" && q > j) { Lkind[n] = "ref"; Ltarget[n] = T[q - 1] LS T[q + 1]; USEDREF[q] = 1 }
      else {
        for (a = j; a < ce; a++) if (T[a] == "->") break
        if (a < ce) {
          lid = sc; sub(/^class:/, "", lid); lid = lid "$\316\273L" L[i]
          lamFile[lid] = rel; lamLine[lid] = L[i]; lamFq[lid] = fq; lamParent[lid] = sc; lamOrd[++nLam] = lid
          if (T[a + 1] == "{") pendLam[a + 1] = lid
          else { exprId[a] = lid; exprEnd[a] = ce }
          Lkind[n] = "lambda"; Ltarget[n] = lid
        }
        else if (T[j] == "new" && K[j + 1] == "i") {
          q = j + 1; while (T[q + 1] == "." && K[q + 2] == "i") q += 2
          Lkind[n] = "class"; Ltarget[n] = T[q]
          while (q < ce && T[q] != "(") q++
          if (T[q] == "(" && (q in PM)) { b = PM[q] + 1; if (T[b] == "{") anonL[b] = n }
        }
        else if (j == ce - 1 && (T[j] == "this" || (K[j] == "i" && T[j] ~ /^[a-z_]/))) { Lkind[n] = "obj"; Ltarget[n] = T[j] }
      }
      if (Lkind[n] == "site") addUnres(rel, L[i], sc, "handler not resolved, shown at registration site: " LN[L[i]])
    }
  }
  if ((t in CLIENT) && inBody && !(t in EMIT) && !(t in LISTEN)) clientCall(i, rel, sc, ce)
  if (FOLLOW && inBody && !(t in EMIT) && !(t in LISTEN) && !(t in ROUTE) && ((i + 1) in PM)) callbackArgs(i + 1, ce, sc, rel)
  if (FOLLOW && inBody && t ~ /^[a-z_]/ && !(t in CTRL) && !(t in EMIT) && !(t in LISTEN)) {
    recv = ""
    if (prev == ".") { if (K[pi - 1] == "i" && T[pi - 2] != ".") recv = T[pi - 1]; else return }
    nCalls++; Cscope[nCalls] = sc; Cfq[nCalls] = fq; Crecv[nCalls] = recv; Cname[nCalls] = t; Cfile[nCalls] = rel; Cline[nCalls] = L[i]
  }
}

# ------------------------------------------------------------- resolution ---
# Event name for a raw reference. A constant gives its string value; a constant that is an
# alias of another one (String A = Other.B;) is followed to the end of the chain.
# Sets evAs to the name written in the code when an alias was followed, and evFound to 1
# when a string value was reached.
# evRaw keeps the reference itself when no string value was found (unknown constant, event class).
function normEv(r) { evAs = ""; evFound = 0; evRaw = ""; return evName(r, 0) }
function evName(r, dep,   ch, n, parts, k, key, m) {
  if (substr(r, 1, 2) == "S:") { evFound = 1; return substr(r, 3) }
  ch = substr(r, 3); sub(/\.class$/, "", ch)
  n = split(ch, parts, ".")
  for (k = 1; k <= n; k++) {
    key = parts[k]; for (m = k + 1; m <= n; m++) key = key "." parts[m]
    if (key in CONST) { evFound = 1; return CONST[key] }
    if ((key in ALIAS) && dep < 10) { if (dep == 0) evAs = ch; return evName("C:" ALIAS[key], dep + 1) }
  }
  evRaw = ch
  return parts[n]
}

# Resolve a simple type name as seen from class ctx: nested/outer types,
# explicit import, same package, wildcard imports, else every match.
function resolveType(s, ctx,   key, n, arr, i, out, f, c, g, wn, wa, w) {
  if (s == "") return ""
  key = s SUBSEP ctx
  if (key in RTCACHE) return RTCACHE[key]
  out = ""
  c = ctx; g = 0
  while (c != "" && g++ < 10) { if ((c "." s) in tFile) { out = c "." s; break }; c = (c in tOuter) ? tOuter[c] : "" }
  if (out == "" && (s in BYS)) {
    f = (ctx in tFile) ? tFile[ctx] : ""
    if ((f SUBSEP s) in IMP && (IMP[f SUBSEP s] in tFile)) out = IMP[f SUBSEP s]
    else {
      n = split(BYS[s], arr, LS)
      for (i = 1; i <= n; i++) if ((ctx in tPkg) && tPkg[arr[i]] == tPkg[ctx]) out = out LS arr[i]
      if (out == "" && (f in WILD)) {
        wn = split(WILD[f], wa, LS)
        for (i = 1; i <= n; i++) for (w = 1; w <= wn; w++) if (tPkg[arr[i]] == wa[w]) out = out LS arr[i]
      }
      if (out == "") out = BYS[s]; else out = substr(out, 2)
    }
  }
  RTCACHE[key] = out
  return out
}
function inList(list, x) { return index(LS list LS, LS x LS) > 0 }

# A type name -> concrete classes: the type(s) plus their implementors/subclasses.
function classesFor(s, ctx,   out, seen, fr, nfr, a2, lvl, i, j, n, arr, f, nx, sn) {
  out = ""; split("", seen)
  if (s == "") return ""
  fr = resolveType(s, ctx)
  n = split(fr, arr, LS); for (i = 1; i <= n; i++) if (!(arr[i] in seen)) { seen[arr[i]] = 1; out = out LS arr[i] }
  for (lvl = 0; lvl < 4 && fr != ""; lvl++) {
    nx = ""; nfr = split(fr, a2, LS)
    for (j = 1; j <= nfr; j++) {
      sn = tSimple[a2[j]]
      if (!(sn in IMPL)) continue
      n = split(IMPL[sn], arr, LS)
      for (i = 1; i <= n; i++) {
        f = arr[i]
        if ((f in seen) || !inList(resolveType(sn, f), a2[j])) continue
        seen[f] = 1; out = out LS f; nx = nx LS f
      }
    }
    fr = substr(nx, 2)
  }
  return substr(out, 2)
}

function lookupMethod(fq, name, dep,   n, arr, i, n2, arr2, j, r) {
  if (fq == "" || dep > 6) return ""
  if ((fq SUBSEP name) in TM) return TM[fq SUBSEP name]
  if ((fq in tSup) && tSup[fq] != "") {
    n = split(tSup[fq], arr, LS)
    for (i = 1; i <= n; i++) {
      n2 = split(resolveType(arr[i], (tAnon[fq] ? tOuter[fq] : fq)), arr2, LS)
      for (j = 1; j <= n2; j++) { r = lookupMethod(arr2[j], name, dep + 1); if (r != "") return r }
    }
  }
  if ((fq in tOuter) && tOuter[fq] != "") return lookupMethod(tOuter[fq], name, dep + 1)
  return ""
}

function lookupField(fq, name,   g) {
  g = 0
  while (fq != "" && g++ < 10) {
    if ((fq SUBSEP name) in TF) return TF[fq SUBSEP name]
    fq = (fq in tOuter) ? tOuter[fq] : ""
  }
  return ""
}

function methodsIn(list, name,   n, arr, i, out) {
  out = ""; n = split(list, arr, LS)
  for (i = 1; i <= n; i++) if ((arr[i] SUBSEP name) in TM) out = out LS TM[arr[i] SUBSEP name]
  return substr(out, 2)
}

function addNode(id, kind, label, cls, file, line) {
  if (id in NK) return
  NK[id] = kind; NL[id] = label; NC[id] = cls; NFL[id] = file; NLn[id] = line; NO[++nNodes] = id
}
function addMethodNode(mid) {
  if ((mid in NK) || !(mid in mFile)) return
  addNode(mid, "method", tQual[mFq[mid]] "." mName[mid] "()", mFq[mid], mFile[mid], mLine[mid])
}
function addClassNode(fq,   id) {
  id = "class:" fq
  if (!(id in NK)) {
    if (fq in tFile) addNode(id, "class", tQual[fq], fq, tFile[fq], tLine[fq])
    else addNode(id, "class", fq, fq, "", "")
  }
  return id
}
function addEvent(nm,   id) {
  id = "event:" nm; addNode(id, "event", nm, "", "", "")
  if (!evFound && evRaw != "" && !(id in EVRAW)) EVRAW[id] = evRaw   # call right after normEv()
  return id
}
function unresHandler(n, txt,   id) {
  id = "unres:h:" Lfile[n] ":" Lline[n] ":" n
  addNode(id, "handler", (txt == "" ? "unknown handler" : txt), Lctx[n], Lfile[n], Lline[n]); UNR[id] = 1
  return id
}
function nodeForScope(sid) {
  if (substr(sid, 1, 6) == "class:") return addClassNode(substr(sid, 7))
  if (sid in mFile) addMethodNode(sid)
  return sid
}
function classCallbacks(fq,   out, i, m) {
  if (!(fq in tFile)) return addClassNode(fq)
  out = ""
  for (i = 1; i <= nCB; i++) if ((fq SUBSEP CBL[i]) in TM) { m = TM[fq SUBSEP CBL[i]]; addMethodNode(m); out = out LS m }
  if (out == "" && tAnon[fq] && TMC[fq] == 1) { m = TMfirst[fq]; addMethodNode(m); out = LS m }
  if (out == "") return addClassNode(fq)
  return substr(out, 2)
}
function addEdge(s, d, k, f, l, as) { E[s SUBSEP d SUBSEP k SUBSEP f SUBSEP l SUBSEP as] = 1 }
function scopeLabel(sid) {
  if (sid in mFile) return tQual[mFq[sid]] "." mName[sid] "()"
  if (substr(sid, 1, 6) == "class:") return (substr(sid, 7) in tQual) ? tQual[substr(sid, 7)] : substr(sid, 7)
  return sid
}

function resolveAndWrite(   m, n, x, nn, arr, eid, kind, tg, targets, pr, left, right, ft, list, t2, c, recv, nm, cls,
                            key, ep, s, d, qh, qt, cur, id, first, roles, rr, nr, i, lid, kk, evUsed, v, aid, rid) {
  # lambdas
  for (i = 1; i <= nLam; i++) {
    lid = lamOrd[i]
    addNode(lid, "lambda", "\316\273 in " scopeLabel(lamParent[lid]) " (L" lamLine[lid] ")", lamFq[lid], lamFile[lid], lamLine[lid])
  }
  # endpoints
  for (m in mFile) if (index(mRoles[m], "endpoint")) addMethodNode(m)
  # listeners
  for (n = 1; n <= nLs; n++) {
    eid = addEvent(normEv(Lev[n])); evUsed = evAs; kind = Lkind[n]; tg = Ltarget[n]; targets = ""
    if (kind == "method") { addMethodNode(tg); targets = tg }
    else if (kind == "lambda") targets = tg
    else if (kind == "ref") {
      split(tg, pr, LS); left = pr[1]; right = pr[2]
      if (right == "new") {
        list = resolveType(left, Lctx[n])
        nn = split(list, arr, LS); for (x = 1; x <= nn; x++) targets = targets LS addClassNode(arr[x])
        targets = substr(targets, 2)
      }
      else if (left == "this" || left == "super") targets = lookupMethod(Lctx[n], right, 0)
      else {
        ft = lookupField(Lctx[n], left)
        targets = methodsIn(classesFor(ft != "" ? ft : left, Lctx[n]), right)
      }
      if (targets == "") { addUnres(Lfile[n], Lline[n], Lscope[n], "listener handler not found: " left "::" right); targets = unresHandler(n, left "::" right) }
    }
    else if (kind == "anon") targets = classCallbacks(tg)
    else if (kind == "class") {
      list = classesFor(tg, Lctx[n]); nn = split(list, arr, LS)
      for (x = 1; x <= nn; x++) targets = targets LS classCallbacks(arr[x])
      targets = substr(targets, 2)
      if (targets == "") targets = addClassNode(tg)
    }
    else if (kind == "obj") {
      if (tg == "this") targets = classCallbacks(Lctx[n])
      else {
        ft = lookupField(Lctx[n], tg)
        if (ft != "") { list = classesFor(ft, Lctx[n]); nn = split(list, arr, LS); for (x = 1; x <= nn; x++) targets = targets LS classCallbacks(arr[x]); targets = substr(targets, 2) }
      }
      if (targets == "") targets = unresHandler(n, tg)
    }
    else targets = unresHandler(n, Lhx[n])
    nn = split(targets, arr, LS)
    for (x = 1; x <= nn; x++) {
      t2 = arr[x]; if (t2 == "") continue
      if (t2 in mFile) { addRole(t2, "handler"); addMethodNode(t2) }
      addEdge(eid, t2, "handled_by", Lfile[n], Lline[n], evUsed)
    }
  }
  # emissions
  for (n = 1; n <= nEm; n++) {
    eid = addEvent(normEv(Eev[n]))
    addEdge(nodeForScope(Escope[n]), eid, "emits", Efile[n], Eline[n], evAs)
  }
  for (n = 1; n <= nRt; n++) {
    rid = Rid[n]
    addNode(rid, "endpoint", Rlabel[n], Rfq[n], Rfile[n], Rline[n]); mVerb[rid] = Rverb[n]; mPath[rid] = Rpath[n]; ROUTEN[rid] = 1
    targets = ""
    if (Rkind[n] == "lambda") targets = Rtarget[n]
    else if (Rkind[n] == "ref") {
      split(Rtarget[n], pr, LS); left = pr[1]; right = pr[2]
      if (left == "this" || left == "super") targets = lookupMethod(Rfq[n], right, 0)
      else { ft = lookupField(Rfq[n], left); targets = methodsIn(classesFor(ft != "" ? ft : left, Rfq[n]), right) }
    }
    if (targets == "") {
      addUnres(Rfile[n], Rline[n], "", "route handler not found: " Rtxt[n])
      targets = "unres:h:" Rfile[n] ":" Rline[n] ":r" n
      addNode(targets, "handler", (Rtxt[n] == "" ? "unknown handler" : Rtxt[n]), Rfq[n], Rfile[n], Rline[n]); UNR[targets] = 1
    }
    nn = split(targets, arr, LS)
    for (x = 1; x <= nn; x++) { if (arr[x] in mFile) addMethodNode(arr[x]); addEdge(rid, arr[x], "calls", Rfile[n], Rline[n]) }
  }
  for (n = 1; n <= nHC; n++) {
    v = clientUrl(n); if (v == "") continue
    targets = matchUrl(v, HCverb[n]); if (targets == "") continue
    nn = split(targets, arr, LS); s = nodeForScope(HCsc[n])
    for (x = 1; x <= nn; x++) { if (arr[x] in mFile) addMethodNode(arr[x]); addEdge(s, arr[x], "http", HCf[n], HCl[n]); HTTPT[arr[x]] = 1 }
  }
  for (n = 1; n <= nUE; n++) {
    eid = "unres:e:" UEf[n] ":" UEl[n] ":" n
    addNode(eid, "event", (UEt[n] == "" ? "unknown event" : UEt[n]), "", UEf[n], UEl[n]); UNR[eid] = 1
    addEdge(nodeForScope(UEsc[n]), eid, "emits", UEf[n], UEl[n], "")
  }
  # calls
  for (c = 1; c <= nCalls; c++) {
    recv = Crecv[c]; nm = Cname[c]; cls = Cfq[c]; targets = ""
    if (recv == "" || recv == "this") targets = lookupMethod(cls, nm, 0)
    else {
      ft = lookupField(cls, recv)
      if (ft != "") targets = methodsIn(classesFor(ft, cls), nm)
      else if (recv ~ /^[A-Z]/ && (recv in BYS)) targets = methodsIn(resolveType(recv, cls), nm)
    }
    nn = split(targets, arr, LS)
    for (x = 1; x <= nn; x++) if (arr[x] != Cscope[c]) addEdge(Cscope[c], arr[x], "calls", Cfile[c], Cline[c])
  }
  # objects handed to calls -> their callback methods. A named class must implement or extend
  # something (Handler, Runnable...), so plain data objects passed around are left out.
  for (ob = 1; ob <= nOb; ob++) {
    obCls = ObFq[ob]
    if (ObK[ob] == "this") obList = obCls
    else if (ObK[ob] == "new") obList = (ob in ObAnon) ? ObAnon[ob] : resolveType(ObN[ob], obCls)
    else { ft = lookupField(obCls, ObN[ob]); if (ft == "") continue; obList = classesFor(ft, obCls) }
    nn = split(obList, arr, LS)
    for (x = 1; x <= nn; x++) {
      obC = arr[x]
      if (!(obC in tFile) || (!tAnon[obC] && tSup[obC] == "")) continue
      obFound = 0
      for (obY = 1; obY <= nCB; obY++) {
        obM = lookupMethod(obC, CBL[obY], 0)
        if (obM != "" && obM != ObSc[ob]) { addEdge(ObSc[ob], obM, "calls", ObFile[ob], ObLine[ob]); obFound = 1 }
      }
      if (!obFound && tAnon[obC] && TMC[obC] == 1 && TMfirst[obC] != ObSc[ob]) addEdge(ObSc[ob], TMfirst[obC], "calls", ObFile[ob], ObLine[ob])
    }
  }

  # prune: keep events, endpoints, handlers, lambdas, and anything leading to an event
  for (key in E) {
    split(key, ep, SUBSEP); s = ep[1]; d = ep[2]
    if (d in REV) REV[d] = REV[d] LS s; else REV[d] = s
    if (ep[3] == "handled_by") KEEP[d] = 1
  }
  for (id in NK) if (NK[id] == "event" || NK[id] == "lambda" || (id in ROUTEN) || (id in UNR) || ((id in mFile) && mRoles[id] != "")) KEEP[id] = 1
  qh = 1; qt = 0
  for (id in NK) if (NK[id] == "event" || (id in HTTPT)) { Q[++qt] = id; REACH[id] = 1 }
  while (qh <= qt) {
    cur = Q[qh++]
    if (cur in REV) {
      nn = split(REV[cur], arr, LS)
      for (x = 1; x <= nn; x++) if (!(arr[x] in REACH)) { REACH[arr[x]] = 1; Q[++qt] = arr[x] }
    }
  }
  for (id in REACH) KEEP[id] = 1
  for (id in KEEP) if (!(id in NK)) nodeForScope(id)

  # constants that name each event, aliases included
  for (i = 1; i <= nDef; i++) {
    v = normEv("C:" Dname[i]); aid = "event:" v
    if (!(aid in NK)) continue
    AKA[aid] = AKA[aid] (AKA[aid] == "" ? "" : ",") "{\"name\":\"" jesc(Dname[i]) "\",\"to\":" (Dto[i] == "" ? "null" : "\"" jesc(Dto[i]) "\"") \
      ",\"file\":\"" jesc(Dfile[i]) "\",\"line\":" Dline[i] ",\"missing\":" ((Dto[i] != "" && !evFound) ? "true" : "false") "}"
    if (Dto[i] != "" && !evFound) { addUnres(Dfile[i], Dline[i], "", "alias target not found: " Dname[i] " = " Dto[i]); UNR[aid] = 1 }
    if (Dto[i] == "" && !(aid in EVLABEL)) { EVLABEL[aid] = Dname[i]; NFL[aid] = Dfile[i]; NLn[aid] = Dline[i] }
  }
  # events are named after the constant that holds their value (easier to find in an IDE than
  # the string); without one, after the reference used in the code, else the quoted string
  for (id in NK) if (NK[id] == "event" && substr(id, 1, 6) != "unres:") {
    if (id in EVLABEL) NL[id] = EVLABEL[id]
    else if (id in EVRAW) NL[id] = EVRAW[id]
    else NL[id] = "\"" substr(id, 7) "\""
  }

  # ---- write JSON ----
  printf "{\"meta\":{\"root\":\"%s\",\"generated\":\"%s\",\"files\":%d,\"special\":\"%s\",\"components\":[", jesc(root), jesc(generated), nFiles, jesc(special_dirs) > outfile
  nn = split(components, arr, "|"); first = 1
  for (x = 1; x <= nn; x++) {
    if (arr[x] == "") continue
    v = arr[x]; sub(/.*\//, "", v); if (arr[x] == ".") v = root_name
    printf "%s{\"dir\":\"%s\",\"name\":\"%s\"}", (first ? "" : ","), jesc(arr[x] == "." ? "" : arr[x]), jesc(v) > outfile; first = 0
  }
  printf "]}," > outfile
  printf "\"edges\":[" > outfile
  first = 1; nEdges = 0
  for (key in E) {
    split(key, ep, SUBSEP)
    if (!((ep[1] in KEEP) && (ep[2] in KEEP) && (ep[1] in NK) && (ep[2] in NK))) continue
    USED[ep[1]] = 1; USED[ep[2]] = 1
    printf "%s[\"%s\",\"%s\",\"%s\",\"%s\",%d,\"%s\"]", (first ? "" : ","), jesc(ep[1]), jesc(ep[2]), ep[3], jesc(ep[4]), ep[5], jesc(ep[6]) > outfile
    first = 0; nEdges++
  }
  printf "],\"nodes\":[" > outfile
  first = 1
  for (i = 1; i <= nNodes; i++) {
    id = NO[i]
    if (!(id in KEEP)) continue
    kind = NK[id]; roles = ""
    if (id in mFile) {
      nr = split(mRoles[id], rr, " ")
      for (x = 1; x <= nr; x++) roles = roles (roles == "" ? "" : ",") "\"" rr[x] "\""
      if (index(mRoles[id], "endpoint")) kind = "endpoint"
      else if (index(mRoles[id], "handler")) kind = "handler"
    }
    if (id in ROUTEN) roles = "\"lambda\""
    if (!((id in USED) || kind == "event" || kind == "endpoint")) continue
    CNT[kind]++
    printf "%s{\"id\":\"%s\",\"kind\":\"%s\",\"label\":\"%s\",\"cls\":\"%s\",\"file\":%s,\"abs\":%s,\"line\":%s,\"roles\":[%s],\"path\":%s,\"verb\":%s,\"aka\":[%s],\"value\":%s,\"unres\":%s}", \
      (first ? "" : ","), jesc(id), kind, jesc(NL[id]), jesc(NC[id]), \
      (NFL[id] == "" ? "null" : "\"" jesc(NFL[id]) "\""), \
      (NFL[id] == "" ? "null" : "\"" jesc(root "/" NFL[id]) "\""), \
      (NLn[id] == "" ? "null" : NLn[id]), roles, \
      ((id in mPath) ? "\"" jesc(mPath[id]) "\"" : "null"), \
      (((id in mVerb) && mVerb[id] != "") ? "\"" mVerb[id] "\"" : "null"), AKA[id], ((kind == "event" && substr(id, 1, 6) != "unres:") ? "\"" jesc(substr(id, 7)) "\"" : "null"), ((id in UNR) ? "true" : "false") > outfile
    first = 0
  }
  printf "],\"unresolved\":[" > outfile
  for (i = 1; i <= nU; i++)
    printf "%s{\"file\":\"%s\",\"line\":%d,\"scope\":\"%s\",\"text\":\"%s\"}", (i == 1 ? "" : ","), jesc(Ufile[i]), Uline[i], jesc(Uscope[i]), jesc(Utext[i]) > outfile
  printf "]}" > outfile
  close(outfile)

  printf "Scanned %d files -> %d endpoints, %d events, %d handlers, %d lambdas, %d methods, %d classes, %d links, %d unresolved\n", \
    nFiles, CNT["endpoint"], CNT["event"], CNT["handler"], CNT["lambda"], CNT["method"], CNT["class"], nEdges, nU > "/dev/stderr"
}

function jesc(s,   out, i, c, n) {
  if (s !~ /[\\"\t<]/) return s
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\t") out = out " "
    else if (c == "<" && substr(s, i + 1, 1) == "/") out = out "<\\"
    else out = out c
  }
  return out
}
EOF_AWK

(cd "$ROOT_ABS" && LC_ALL=C "$AWK_BIN" \
  -v listfile="$TMP/files.txt" -v outfile="$TMP/graph.json" -v root="$ROOT_LINK" \
  -v generated="$(date '+%Y-%m-%dT%H:%M:%S')" -v special_dirs="$SPECIAL_DIRS" \
  -v emit_methods="$EMIT_METHODS" -v listen_methods="$LISTEN_METHODS" \
  -v listen_ann="$LISTEN_ANNOTATIONS" -v ev_keys="$EVENT_ANNOTATION_KEYS" \
  -v endpoint_ann="$ENDPOINT_ANNOTATIONS" -v path_ann="$PATH_ANNOTATIONS" \
  -v callback_methods="$CALLBACK_METHODS" -v route_methods="$ROUTE_METHODS" \
  -v client_methods="$CLIENT_METHODS" -v components="$COMPONENTS" -v root_name="$NAME" -v follow_calls="$FOLLOW_CALLS" \
  "$AWK_PROG")

# ---- the log reader (awk) -------------------------------------------------------
# Streams every log file once and keeps only aggregates, so the page stays small whatever the
# size of the logs: hops per address, message patterns, rule and level counts.
read -r -d '' AWK_LOGS <<'EOF_AWK_LOGS' || true
# Input : -v loglist=<file of "bytes<TAB>path<TAB>shown path">, rules in ENVIRON (no escape
#         processing, so regexes keep their backslashes).
# Output: JSON in -v outfile.
BEGIN {
  CTL = "[\001-\037]"
  nF = split(ENVIRON["LOG_FIELDS"], FN, " "); SEP = ENVIRON["LOG_SEP"]; SEPL = length(SEP)
  START = ENVIRON["LOG_START"]; REQ = ENVIRON["LOG_REQUEST"]; REP = ENVIRON["LOG_REPLY"]
  nSkip = split(ENVIRON["LOG_SKIP"], SKIP, "|")
  nId = rules(ENVIRON["LOG_IDS"], IDK, IDR)
  nRu = rules(ENVIRON["LOG_RULES"], RUK, RUR)
  n = split(ENVIRON["LOG_PATTERN_LEVELS"], w, " "); for (i = 1; i <= n; i++) PATLV[w[i]] = 1
  nFiles = 0; nPat = 0; MAXPAT = 3000; minT = ""; maxT = ""
  WINDOW = ENVIRON["LOG_LINK_WINDOW"] + 0; if (WINDOW <= 0) WINDOW = 30000
  while ((getline v < loglist) > 0) {
    p = index(v, "\t"); q = index(substr(v, p + 1), "\t")
    if (!p || !q) continue
    nFiles++; Fb[nFiles] = substr(v, 1, p - 1); real = substr(v, p + 1, q - 1); Fs[nFiles] = substr(v, p + q + 1)
    readFile(real, nFiles)
  }
  close(loglist)
  for (k in PH) { HU[Hk[PH[k]]]++ }
  writeJson()
  printf "Read %d log lines (%d records) -> %d hops on %d routes, %d replies without request\n", nLines, nRec, nHop, nKeys, orphan > "/dev/stderr"
}

# "name=regex" lines -> arrays; blank lines and lines without "=" are skipped
function rules(s, K, R,   n, a, i, l, p, c) {
  n = split(s, a, "\n"); c = 0
  for (i = 1; i <= n; i++) {
    l = a[i]; sub(/\r$/, "", l); sub(/^[ \t]+/, "", l)
    p = index(l, "="); if (p < 2) continue
    c++; K[c] = substr(l, 1, p - 1); R[c] = substr(l, p + 1)
  }
  return c
}

function readFile(path, f,   line, ln) {
  ln = 0; lastPat = ""
  while ((getline line < path) > 0) {
    ln++; nLines++
    sub(/\r$/, "", line)
    if (line ~ START) record(line, f, ln)
    else {
      nCont++
      # first line under an ERROR/WARN record: usually the exception, kept with its pattern
      if (lastPat != "" && !(lastPat in PEX) && line ~ /[A-Za-z]/) { t = line; sub(/^[ \t]+/, "", t); PEX[lastPat] = substr(t, 1, 200) }
    }
  }
  close(path)
  Fl[f] = ln
}

function record(line, f, ln,   rest, i, p, val, time, level, msg, kind, tag, id, ms, k, r, s, j, pat, pk) {
  nRec++; rest = line; time = ""; level = ""; msg = ""; lastPat = ""
  for (i = 1; i <= nF; i++) {
    if (i < nF) { p = index(rest, SEP); if (!p) { val = rest; rest = "" } else { val = substr(rest, 1, p - 1); rest = substr(rest, p + SEPL) } }
    else val = rest
    if (FN[i] == "time") time = val
    else if (FN[i] == "level") { level = val; gsub(/[ \t]+/, "", level) }
    else if (FN[i] == "message") msg = val
  }
  if (level != "") LV[level]++
  ms = toMs(time)
  if (ms != "") { if (minT == "" || ms < minMs) { minMs = ms; minT = time }; if (maxT == "" || ms > maxMs) { maxMs = ms; maxT = time } }
  for (r = 1; r <= nRu; r++) if (msg ~ RUR[r]) { RC[r]++; if (!(r in RF)) { RF[r] = f; RL[r] = ln; RX[r] = substr(msg, 1, 300) } }
  # correlation tag -> hop request / reply
  kind = ""
  for (i = 1; i <= nId; i++) if (match(msg, IDR[i])) { kind = IDK[i]; tag = substr(msg, RSTART, RLENGTH); s = substr(msg, RSTART + RLENGTH); break }
  if (kind != "") {
    TG[kind]++
    id = kind SUBSEP tag
    sub(/^[ \t]+/, "", s)
    for (j = 1; j <= nSkip; j++) if (SKIP[j] != "" && substr(s, 1, length(SKIP[j])) == SKIP[j]) { s = ""; break }
    if (s != "" && substr(s, 1, length(REQ)) == REQ) hopRequest(id, substr(s, length(REQ) + 1), ms, time, f, ln)
    else if (s != "" && substr(s, 1, length(REP)) == REP) hopReply(id, substr(s, length(REP) + 1), ms, f, ln)
  }
  if (level in PATLV) {
    pat = msg
    if (kind != "") pat = s
    gsub(/"[^"]*"/, "\"…\"", pat); gsub(/'[^']*'/, "'…'", pat)
    gsub(/[0-9A-Za-z_.:\/-]*[0-9][0-9A-Za-z_.:\/-]*/, "#", pat)
    gsub(/[ \t]+/, " ", pat); pat = substr(pat, 1, 160)
    pk = level SUBSEP pat
    if (!(pk in PC) && nPat >= MAXPAT) { patOver++; return }
    if (!(pk in PC)) { nPat++; PO[nPat] = pk; PF[pk] = f; PL[pk] = ln; PX[pk] = substr(msg, 1, 300) }
    PC[pk]++; lastPat = pk
  }
}

# address, Sender->Receiver, payload
function hopRequest(id, s, ms, time, f, ln,   p, addr, who, from, to, key, n, a, j, h, par, amb, keep) {
  p = index(s, " "); addr = p ? substr(s, 1, p - 1) : s; s = p ? substr(s, p + 1) : ""
  sub(/^[ \t]+/, "", s); p = index(s, " "); who = p ? substr(s, 1, p - 1) : s
  p = index(who, "->"); if (p) { from = substr(who, 1, p - 1); to = substr(who, p + 2) } else { from = ""; to = who }
  key = addr SUBSEP from SUBSEP to
  if (!(key in HC)) { nKeys++; HO[nKeys] = key; KI[key] = nKeys; HF[key] = f; HL[key] = ln; HT1[key] = time }
  HC[key]++; HT2[key] = time; nHop++
  # parent: the latest hop received by this hop's sender and still waiting for its reply
  par = 0; amb = 0
  if (from != "" && (from in OPENBY) && OPENBY[from] != "") {
    n = split(OPENBY[from], a, " "); keep = ""
    for (j = 1; j <= n; j++) {
      h = a[j]
      if (ms != "" && Hs[h] != "" && ms - Hs[h] > WINDOW) continue   # too old: its reply was lost
      keep = keep " " h
      if (par) amb = 1
      par = h
    }
    OPENBY[from] = keep
  }
  if (par) { PAIR[Hk[par] SUBSEP key]++; HP[key]++; if (amb) HA[key]++ }
  nH++; Hk[nH] = key; Hs[nH] = ms; Hto[nH] = to
  OPENBY[to] = OPENBY[to] " " nH
  PH[id] = nH
}
# takes handle h out of the hops open at receiver "to"
function unopen(to, h,   s, i) {
  s = OPENBY[to] " "; i = index(s, " " h " ")
  if (i) { s = substr(s, 1, i - 1) substr(s, i + length(h) + 1) }
  sub(/ $/, "", s); OPENBY[to] = s
}
function hopReply(id, s, ms, f, ln,   p, st, key, d, h) {
  p = index(s, " "); st = p ? substr(s, 1, p - 1) : s
  if (!(id in PH)) { orphan++; return }
  h = PH[id]; key = Hk[h]; delete PH[id]
  unopen(Hto[h], h); PT[id] = Hs[h]
  HR[key]++; HS[key SUBSEP st]++; if (!((key, "|") in HSL) || index(HSL[key, "|"], "," st ",") == 0) HSL[key, "|"] = HSL[key, "|"] "," st ","
  if (PT[id] != "" && ms != "") { d = ms - PT[id]; if (d >= 0) { HD[key] += d; HDN[key]++; if (d > HM[key]) HM[key] = d } }
  delete PT[id]
  if (st !~ /^2/) { HE[key]++; if (!(key in HEF)) { HEF[key] = f; HEL[key] = ln } }
  delete Hk[h]; delete Hs[h]; delete Hto[h]   # closed: it can no longer be a parent
}

# "MM/DD HH:MM:SS.mmm" or "YYYY-MM-DD HH:MM:SS,mmm" -> milliseconds (only differences matter)
function toMs(t,   d, hms, a, n, y, mo, dy, frac) {
  if (!match(t, /[0-9][0-9]?:[0-9][0-9]:[0-9][0-9]([.,][0-9]+)?/)) return ""
  hms = substr(t, RSTART, RLENGTH)
  y = 0; mo = 0; dy = 0
  if (match(t, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) { d = substr(t, RSTART, RLENGTH); y = substr(d, 1, 4) + 0; mo = substr(d, 6, 2) + 0; dy = substr(d, 9, 2) + 0 }
  else if (match(t, /[0-9][0-9]?\/[0-9][0-9]?/)) { d = substr(t, RSTART, RLENGTH); n = split(d, a, "/"); mo = a[1] + 0; dy = a[2] + 0 }
  frac = 0
  if (match(hms, /[.,][0-9]+$/)) { frac = substr(hms, RSTART + 1, 3); while (length(frac) < 3) frac = frac "0"; frac += 0; hms = substr(hms, 1, RSTART - 1) }
  n = split(hms, a, ":")
  return ((((y * 12 + mo) * 31 + dy) * 24 + a[1]) * 60 + a[2]) * 60000 + a[3] * 1000 + frac
}

function writeJson(   i, k, a, n, x, st, sl, first) {
  printf "{\"files\":[" > outfile
  for (i = 1; i <= nFiles; i++) printf "%s{\"file\":\"%s\",\"bytes\":%s,\"lines\":%d}", (i > 1 ? "," : ""), jesc(Fs[i]), (Fb[i] ~ /^[0-9]+$/ ? Fb[i] : 0), Fl[i] > outfile
  printf "],\"lines\":%d,\"records\":%d,\"cont\":%d,\"first\":\"%s\",\"last\":\"%s\",\"orphans\":%d,\"patOver\":%d,\"levels\":{", nLines, nRec, nCont, jesc(minT), jesc(maxT), orphan, patOver > outfile
  first = 1; for (k in LV) { printf "%s\"%s\":%d", (first ? "" : ","), jesc(k), LV[k] > outfile; first = 0 }
  printf "},\"tags\":{" > outfile
  first = 1; for (k in TG) { printf "%s\"%s\":%d", (first ? "" : ","), jesc(k), TG[k] > outfile; first = 0 }
  printf "},\"hops\":[" > outfile
  for (i = 1; i <= nKeys; i++) {
    k = HO[i]; split(k, a, SUBSEP)
    st = ""; n = split(HSL[k, "|"], sl, ",")
    for (x = 1; x <= n; x++) if (sl[x] != "") st = st (st == "" ? "" : ",") "\"" jesc(sl[x]) "\":" HS[k SUBSEP sl[x]]
    printf "%s{\"a\":\"%s\",\"from\":\"%s\",\"to\":\"%s\",\"n\":%d,\"replied\":%d,\"noReply\":%d,\"err\":%d,\"ms\":%.0f,\"msN\":%d,\"max\":%.0f,\"file\":%d,\"line\":%d,\"t1\":\"%s\",\"t2\":\"%s\",\"st\":{%s},\"errFile\":%d,\"errLine\":%d,\"par\":%d,\"amb\":%d}", \
      (i > 1 ? "," : ""), jesc(a[1]), jesc(a[2]), jesc(a[3]), HC[k], HR[k], HU[k], HE[k], HD[k], HDN[k], HM[k], HF[k], HL[k], jesc(HT1[k]), jesc(HT2[k]), st, HEF[k], HEL[k], HP[k], HA[k] > outfile
  }
  # parent hop -> child hop, with how many times (indexes into hops, from 1)
  printf "],\"links\":[" > outfile
  first = 1
  for (k in PAIR) {
    split(k, a, SUBSEP)
    printf "%s{\"p\":%d,\"c\":%d,\"n\":%d}", (first ? "" : ","), KI[a[1] SUBSEP a[2] SUBSEP a[3]], KI[a[4] SUBSEP a[5] SUBSEP a[6]], PAIR[k] > outfile
    first = 0
  }
  printf "],\"patterns\":[" > outfile
  for (i = 1; i <= nPat; i++) {
    k = PO[i]; split(k, a, SUBSEP)
    printf "%s{\"level\":\"%s\",\"text\":\"%s\",\"n\":%d,\"file\":%d,\"line\":%d,\"ex\":\"%s\",\"exc\":\"%s\"}", (i > 1 ? "," : ""), jesc(a[1]), jesc(a[2]), PC[k], PF[k], PL[k], jesc(PX[k]), jesc(PEX[k]) > outfile
  }
  printf "],\"rules\":[" > outfile
  for (i = 1; i <= nRu; i++) printf "%s{\"name\":\"%s\",\"re\":\"%s\",\"n\":%d,\"file\":%d,\"line\":%d,\"ex\":\"%s\"}", (i > 1 ? "," : ""), jesc(RUK[i]), jesc(RUR[i]), RC[i], RF[i], RL[i], jesc(RX[i]) > outfile
  printf "]}" > outfile
  close(outfile)
}

function jesc(s,   out, i, c, n) {
  gsub(CTL, " ", s)
  if (s !~ /[\\"<]/) return s
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "<" && substr(s, i + 1, 1) == "/") out = out "<\\"
    else out = out c
  }
  return out
}
EOF_AWK_LOGS

if [ -s "$TMP/logs.txt" ]; then
  # mawk reads big logs about 5 times faster than gawk: use it unless AWK says otherwise
  LOG_AWK="$AWK_BIN"
  if [ -z "${AWK:-}" ] && command -v mawk >/dev/null 2>&1; then LOG_AWK=mawk; fi
  echo "Reading the logs with $LOG_AWK ..." >&2
  LC_ALL=C LOG_FIELDS="$LOG_FIELDS" LOG_SEP="$LOG_SEP" LOG_START="$LOG_START" LOG_IDS="$LOG_IDS" \
    LOG_REQUEST="$LOG_REQUEST" LOG_REPLY="$LOG_REPLY" LOG_SKIP="$LOG_SKIP" \
    LOG_PATTERN_LEVELS="$LOG_PATTERN_LEVELS" LOG_RULES="$LOG_RULES" LOG_LINK_WINDOW="$LOG_LINK_WINDOW" \
    "$LOG_AWK" -v loglist="$TMP/logs.txt" -v outfile="$TMP/logs.json" "$AWK_LOGS" < /dev/null
else
  printf 'null' > "$TMP/logs.json"
fi

# ---- assemble the HTML ---------------------------------------------------------
html_head() {
cat <<'EOF_HTML_HEAD'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
EOF_HTML_HEAD
printf '<title>%s</title>\n' "$TITLE_HTML"
cat <<'EOF_HTML_HEAD'
<style>
:root{--bg:#f7f7f5;--panel:#fff;--ink:#1d1d1f;--mute:#6b6b70;--line:#e3e3e0;--hi:#eef3ff;--acc:#2f5bd3;
--ep:#0f7b5f;--ev:#b4570b;--hd:#7a3ed1;--me:#4a5568;--la:#8a6d00;--cl:#64748b;--warn:#b42318}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--panel:#1c1c1f;--ink:#ececee;--mute:#9a9aa2;--line:#2c2c31;
--hi:#22283a;--acc:#7ea2ff;--ep:#3ccf9f;--ev:#f2a65a;--hd:#b79cff;--me:#a0aec0;--la:#e0c14c;--cl:#94a3b8;--warn:#ff7a6e}}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--ink)}
header{display:flex;align-items:baseline;gap:12px;padding:10px 16px;border-bottom:1px solid var(--line);background:var(--panel)}
header h1{font-size:16px;margin:0}header .meta{color:var(--mute);font-size:12px}
main{display:grid;grid-template-columns:360px 1fr;height:calc(100vh - 45px)}
aside{border-right:1px solid var(--line);display:flex;flex-direction:column;min-height:0;background:var(--panel)}
#q{margin:10px;padding:9px 11px;border:1px solid var(--line);border-radius:8px;font:inherit;background:var(--bg);color:var(--ink)}
#chips{display:flex;flex-wrap:wrap;gap:6px;padding:0 10px 8px}
.chip{border:1px solid var(--line);border-radius:999px;padding:2px 9px;font-size:12px;cursor:pointer;user-select:none;background:var(--bg)}
.chip.off{opacity:.4;text-decoration:line-through}
.navtabs{display:flex;flex-wrap:wrap;gap:4px;padding:0 10px 8px}
.navtabs button,.btn{font:inherit;font-size:12px;border:1px solid var(--line);background:var(--bg);color:var(--ink);border-radius:6px;padding:4px 10px;cursor:pointer}
.navtabs button.on,.btn.on{background:var(--acc);color:#fff;border-color:var(--acc)}
#count{color:var(--mute);font-size:12px;padding:0 12px 6px}
#results{list-style:none;margin:0;padding:0 6px 10px;overflow:auto;flex:1}
#results li>div{min-width:0;overflow-wrap:anywhere}#results li{padding:6px 8px;border-radius:6px;cursor:pointer;display:flex;gap:8px;align-items:flex-start}
#results li:hover{background:var(--hi)}#results li.sel{background:var(--hi);outline:1px solid var(--acc)}
.ic{width:20px;flex:none;text-align:center;font-weight:700}
.k-endpoint{color:var(--ep)}.k-event{color:var(--ev)}.k-handler{color:var(--hd)}.k-method{color:var(--me)}.k-lambda{color:var(--la)}.k-class{color:var(--cl)}
.sub{color:var(--mute);font-size:12px;word-break:break-all}
#detail{overflow:auto;padding:18px 24px}
.empty{color:var(--mute);margin-top:40px;text-align:center}
.title{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.title h2{margin:0;font-size:19px;word-break:break-all}
.badge{font-size:11px;border-radius:4px;padding:1px 7px;border:1px solid currentColor}
.lnk{color:var(--mute);font-size:12px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.toolbar{display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin:16px 0 10px}
.toolbar select{font:inherit;font-size:12px;padding:3px;border-radius:6px;border:1px solid var(--line);background:var(--bg);color:var(--ink)}
.tree,.tree ul{list-style:none;margin:0;padding-left:18px}.tree{padding-left:0}
.tree li{margin:2px 0}.tree summary{cursor:pointer;list-style:none}.tree summary::-webkit-details-marker{display:none}
.tree summary:before{content:'▸';display:inline-block;width:14px;color:var(--mute)}.tree details[open]>summary:before{content:'▾'}
.leaf{padding-left:14px}
.row{display:inline-flex;gap:6px;align-items:center;max-width:100%}.row>*{min-width:0}.row>.ic,.row>.elabel,.row>.alias{flex:none}
code.nm2{display:inline-block;vertical-align:middle}code.nm2 .own{font-size:10.5px}
.elabel{font-size:11px;color:var(--mute);min-width:70px}
.nm{cursor:pointer;font-weight:500;display:inline-block;max-width:100%}.nm:hover{text-decoration:underline}
.cyc{color:var(--warn);font-size:12px}
.section h3{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--mute);margin:20px 0 6px}
table{border-collapse:collapse;width:100%;font-size:13px}td,th{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line);vertical-align:top}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--bg);padding:1px 4px;border-radius:4px;word-break:break-all}
.help{color:var(--mute);font-size:12px;margin-top:4px}
.alias{font-size:11px;color:var(--ev);border:1px dashed var(--ev);border-radius:4px;padding:0 5px;white-space:nowrap}
.gal{fill:var(--ev);font-size:10.5px;font-style:italic;text-anchor:middle;paint-order:stroke;stroke:var(--bg);stroke-width:4px;stroke-linejoin:round}#gvp.dim .gal{opacity:.15}
#detail.gview{display:flex;flex-direction:column}
#gwrap{position:relative;border:1px solid var(--line);border-radius:10px;background:var(--bg);flex:1 1 0;min-height:300px;overflow:hidden;margin-top:8px}
#gsvg{width:100%;height:100%;display:block;cursor:grab;user-select:none;touch-action:none}#gsvg.pan{cursor:grabbing}
.gn{cursor:pointer}.gn .box{fill:var(--panel);stroke-width:1.6}.gn .box2{fill:none;stroke-width:1;opacity:.6}.gn:hover .box{fill:var(--hi)}
.gn.ctr .box{stroke-width:3.2;fill:var(--hi)}.gn.foc .box{fill:var(--hi);filter:drop-shadow(0 0 5px var(--acc))}
.gn text{fill:var(--ink);font-size:12px}.gn text.gp{fill:var(--mute);font-size:10px}.gn text.gm{font-weight:600;font-size:12.5px}.gn text.gs{fill:var(--mute);font-size:10.5px}.gn text.ki{font-size:14px;font-weight:700}.gn text.gal2{fill:var(--ev);font-size:10px;font-style:italic}
.s-endpoint{stroke:var(--ep)}.s-event{stroke:var(--ev)}.s-handler{stroke:var(--hd)}.s-method{stroke:var(--me)}.s-lambda{stroke:var(--la)}.s-class{stroke:var(--cl)}
.gn text.f-endpoint{fill:var(--ep)}.gn text.f-event{fill:var(--ev)}.gn text.f-handler{fill:var(--hd)}.gn text.f-method{fill:var(--me)}.gn text.f-lambda{fill:var(--la)}.gn text.f-class{fill:var(--cl)}
.gb{cursor:pointer}.gb rect{fill:var(--bg);stroke:var(--mute)}.gn .gb text{font-size:10.5px;font-weight:700;text-anchor:middle}.gb:hover rect{stroke:var(--acc);fill:var(--hi)}
.gb.on rect{fill:var(--acc);stroke:var(--acc)}.gn .gb.on text{fill:#fff}
.ge{fill:none;stroke-width:1.5;opacity:.8;transition:opacity .15s}.ge:hover{stroke-width:3}.ge.emits{stroke:var(--ev)}.ge.handled_by{stroke:var(--hd)}.ge.calls{stroke:var(--me);stroke-dasharray:5 3}.ge.http{stroke:var(--ep);stroke-dasharray:9 3 2 3}.ge.via{stroke-dasharray:1.5 3}.ge.more{stroke:var(--line);stroke-dasharray:3 3}
.gn,.gmore{transition:opacity .15s}#gvp.dim .gn:not(.hl),#gvp.dim .gmore{opacity:.28}#gvp.dim .ge:not(.hl){opacity:.08}#gvp.dim .ge.hl{stroke-width:2.6;opacity:1}
.gmore{cursor:pointer}.gmore rect{fill:var(--panel);stroke:var(--mute);stroke-dasharray:3 3}.gmore text{fill:var(--mute);font-size:12px;text-anchor:middle}.gmore:hover rect{stroke:var(--acc)}
#ghead .title .gsel{color:var(--acc)}#ghead .loc{min-height:18px}
.own{display:block;font-size:11px;font-weight:400;color:var(--mute);word-break:break-all;line-height:1.3}h2 .own{font-size:12px}
.glegend{display:flex;gap:6px 24px;flex-wrap:wrap;justify-content:space-between;font-size:12px;color:var(--mute);margin-top:6px;align-items:center}.glegend>div{display:flex;gap:8px 10px;flex-wrap:wrap;align-items:center}.glegend span{white-space:nowrap}.glegend i{display:inline-block;width:16px;border-top:2px solid;vertical-align:middle;margin-right:4px}.glegend svg{vertical-align:middle;margin-right:4px}
@media (max-width:800px){main{grid-template-columns:1fr;height:auto}aside{max-height:45vh}#detail.gview{display:block}#gwrap{height:65vh}}
.h1sub{font-weight:400;color:var(--mute)}
.badge.cmpb{color:var(--mute)}
#csvg{width:100%;height:100%;display:block;cursor:grab;user-select:none;touch-action:none}#csvg.pan{cursor:grabbing}
.cbx{cursor:move}#csvg.moving,#csvg.moving *,#gsvg.moving,#gsvg.moving *{cursor:grabbing!important}.gn.drag .box{filter:drop-shadow(0 3px 6px rgba(0,0,0,.35))}
.cbx rect{fill:color-mix(in srgb,var(--ink) 3%,var(--panel));stroke:var(--line);stroke-width:1.5}.cbt{fill:var(--ink);font-weight:700;font-size:13px}
.cn{cursor:pointer}.cn .box{fill:var(--panel);stroke-width:1.5}.cn:hover .box{fill:var(--hi)}.cn text{fill:var(--ink);font-size:12px}.cn text.gm{font-weight:600;font-size:12.5px}.cn text.gp{fill:var(--mute);font-size:10px}.cn text.ki{font-size:14px;font-weight:700}
.cn text.f-endpoint{fill:var(--ep)}.cn text.f-event{fill:var(--ev)}.cn text.f-handler{fill:var(--hd)}.cn text.f-method{fill:var(--me)}.cn text.f-lambda{fill:var(--la)}.cn text.f-class{fill:var(--cl)}
.cn.unr .box{stroke:var(--warn);stroke-dasharray:6 3}.cn.unr text{fill:var(--warn)}
.ce{fill:none;stroke-width:1.6;opacity:.85;transition:opacity .15s}.ce:hover{stroke-width:3}.ce.event{stroke:var(--hd)}.ce.http{stroke:var(--ep);stroke-dasharray:9 3 2 3}
#cvp.dim .cn:not(.hl){opacity:.3}#cvp.dim .ce:not(.hl){opacity:.08}#cvp.dim .ce.hl{stroke-width:2.6;opacity:1}
.cbox{font-weight:700;margin-right:-6px}
.badge.unrb{color:var(--warn)}#results li.unr>div>div:first-child,.nm.unr{color:var(--warn)}
.gn.unr .box{stroke:var(--warn);stroke-dasharray:6 3;fill:color-mix(in srgb,var(--warn) 9%,var(--panel))}.gn.unr:hover .box,.gn.unr.ctr .box,.gn.unr.foc .box{fill:color-mix(in srgb,var(--warn) 14%,var(--hi))}
.gn.unr text,.gn.unr text.ki{fill:var(--warn)}.gn.unr text.gp,.gn.unr text.gs{fill:color-mix(in srgb,var(--warn) 70%,var(--mute))}
.unrl rect{fill:color-mix(in srgb,var(--warn) 9%,var(--panel));stroke:var(--warn);stroke-dasharray:4 2;stroke-width:1.4}.unrl svg{vertical-align:middle;margin-right:4px}
.sptag{display:inline-block;flex:none;align-self:center;font-size:10.5px;font-weight:600;line-height:1.5;padding:0 7px;border-radius:9px;color:var(--sp);background:color-mix(in srgb,var(--sp) 14%,transparent);white-space:nowrap;vertical-align:middle;font-family:system-ui,sans-serif}
#results li.sp{background:color-mix(in srgb,var(--sp) 8%,transparent);box-shadow:inset 3px 0 0 color-mix(in srgb,var(--sp) 70%,transparent)}
#results li.sp:hover,#results li.sp.sel{background:color-mix(in srgb,var(--sp) 8%,var(--hi))}#results li .sptag{margin-left:auto}
.gn.sp .box{fill:color-mix(in srgb,var(--sp) 10%,var(--panel))}.gn.sp:hover .box,.gn.sp.ctr .box,.gn.sp.foc .box{fill:color-mix(in srgb,var(--sp) 12%,var(--hi))}
.ftab tr[data-flow]{cursor:pointer}.ftab tr[data-flow]:hover td{background:var(--hi)}.ftab .fnm{font-weight:500}td.num,th.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
.fin{font:inherit;font-size:12px;padding:4px 8px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--ink);min-width:220px}
.fnames{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:6px 0 8px}.chip.on{background:var(--acc);color:#fff;border-color:var(--acc)}
.fstats{display:flex;flex-wrap:wrap;gap:6px 18px;margin:12px 0 0;color:var(--mute);font-size:13px}.fstats b{color:var(--ink)}
.freach{display:flex;flex-wrap:wrap;gap:6px 16px}
.seen,.nseen{display:inline-block;flex:none;font-size:10.5px;font-weight:600;line-height:1.5;padding:0 6px;border-radius:9px;white-space:nowrap;vertical-align:middle;font-family:system-ui,sans-serif}
.seen{color:var(--ep);background:color-mix(in srgb,var(--ep) 13%,transparent)}.seen.serr{color:var(--warn);background:color-mix(in srgb,var(--warn) 12%,transparent)}
.nseen{color:var(--mute);border:1px dashed var(--line)}
.badge.nmap{color:var(--mute);border-style:dashed}.ltab td.bad,.st.bad{color:var(--warn);font-weight:600}
.st{font:11.5px ui-monospace,SFMono-Regular,Menlo,monospace;padding:0 4px;border-radius:4px;background:var(--bg);white-space:nowrap}
.lvl{white-space:nowrap}.lvl.lv-ERROR,.lvl.lv-ERROR b{color:var(--warn)}.lvl.lv-WARN,.lvl.lv-WARN b{color:var(--ev)}
.lfiles{margin:10px 0 0}.lfiles summary{cursor:pointer}
.ltab,.ftab{display:block;overflow-x:auto}.ltab>tbody,.ftab>tbody{display:table;width:100%}
.row.lrow{display:inline-flex;flex-wrap:wrap;gap:2px 8px}
.lpct{font-size:11px;font-weight:700;color:var(--acc)}.cin{font-size:11px;color:var(--ep)}.cout{font-size:11px;color:var(--warn)}
.gsp rect{fill:color-mix(in srgb,var(--sp) 22%,var(--panel));stroke:color-mix(in srgb,var(--sp) 55%,transparent);stroke-width:1}.gn .gsp text{fill:var(--sp);font-size:9.5px;font-weight:600;text-anchor:middle}
</style></head><body>
EOF_HTML_HEAD
printf '<header><h1>%s <span class="h1sub">event map</span></h1><span class="meta" id="meta"></span></header>\n' "$TITLE_HTML"
cat <<'EOF_HTML_HEAD'
<main>
<aside>
  <input id="q" placeholder="Search endpoint, event, class, method…   ( / )" autocomplete="off">
  <div id="chips"></div>
  <div class="navtabs"><button id="tBrowse" class="on">Browse</button><button id="tGraph">Graph</button><button id="tFlows" title="Entry points and everything each one triggers">Flows</button><button id="tLogs" hidden title="What the log files show: hops on the event bus, errors, rules">Logs</button><button id="tConn" hidden title="Links between components (pom.xml folders)">Connectivity</button><button id="tIssues">Issues</button></div>
  <div id="count"></div>
  <ul id="results"></ul>
</aside>
<section id="detail"><div class="empty">Search on the left, then pick an item to trace its chain.<br><br>
<b>Trace forward</b> = what it triggers · <b>Trace back</b> = what leads to it<br>
<b>Graph</b> = the item and its links as a diagram you can expand</div></section>
</main>
<script>const DATA=
EOF_HTML_HEAD
}
html_tail() {
cat <<'EOF_HTML_TAIL'
;</script>
<script>
const $=s=>document.querySelector(s);
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const N=new Map(DATA.nodes.map(n=>[n.id,n])),OUT=new Map(),IN=new Map();
for(const [s,d,k,f,l,a] of DATA.edges){(OUT.get(s)||OUT.set(s,[]).get(s)).push({id:d,k,f,l,a});(IN.get(d)||IN.set(d,[]).get(d)).push({id:s,k,f,l,a});}
// constant names of an event; "to" is set when the constant is an alias of another constant
const akaOf=n=>n.aka||[],aliasesOf=n=>akaOf(n).filter(a=>a.to);
const short=s=>String(s).split('.').pop();
// the alias written in the code when an emit / listener used one
const asTag=e=>e.a?` <span class="alias" title="Written in the code as the alias ${esc(e.a)}">as ${esc(e.a)}</span>`:'';
function akaHtml(n){const list=akaOf(n);if(!list.length)return'';
 return `<div class="section"><h3>Names in code (${list.length})</h3><table>${list.map(a=>`<tr><td><code class="nm2">${nameStr(a.name)}</code></td><td>${a.to
  ?`<span class="alias">alias of</span> <code class="nm2">${nameStr(a.to)}</code>${a.missing?' <span class="cyc">target not found</span>':''}`
  :`= <code>"${esc(n.value)}"</code>`}</td><td>${link(a.file,absOf(a.file),a.line)}</td></tr>`).join('')}</table>
  ${aliasesOf(n).length?'<div class="help">Emits and listeners using any of these names are merged into this event.</div>':''}</div>`;}
const KIND={endpoint:['🌐','Endpoint'],event:['⚡','Event'],handler:['🎧','Handler'],method:['ƒ','Method'],lambda:['λ','Lambda'],class:['◆','Class']};
const ORDER=['endpoint','event','handler','lambda','method','class'];
const FWD={emits:'emits',handled_by:'handled by',calls:'calls',http:'calls over HTTP'},BWD={emits:'emitted by',handled_by:'triggered by',calls:'called by',http:'called over HTTP by'};
const enabled=new Set(ORDER);let selected=null,view='browse';
$('#meta').textContent=`${DATA.meta.files} files · ${DATA.nodes.length} nodes · ${DATA.edges.length} links · generated ${DATA.meta.generated}`;
{const L=(typeof LOGS!=='undefined'&&LOGS&&LOGS.files)||[];if(L.length){const s=document.createElement('span');const mb=L.reduce((a,l)=>a+l.bytes,0)/1048576;
 s.textContent=` · ${L.length} log file${L.length>1?'s':''} (${mb<10?mb.toFixed(1):Math.round(mb)} MB)`;s.title=L.map(l=>l.file).join('\n');$('#meta').appendChild(s);}}
// source location as plain text (file:line), easy to copy into the IDE
function link(file,abs,line,text){if(!file)return'';
 return `<span class="lnk" title="${esc(file)}:${line}">${wb(text||(file.split('/').pop()+':'+line))}</span>`;}
function ic(n){const k=KIND[n.kind]||['?',''];return `<span class="ic k-${n.kind}" title="${k[1]}">${k[0]}</span>`;}
// SPECIAL_DIRS: name=colour (graph: tag on the bottom edge, the top corners hold the badges). Each gets --spN (tuned per theme); a node belongs to the first
// listed folder found in its file path.
const SPC={orange:['#c8762a','#e0a066'],green:['#4a9a5a','#7fc08c'],blue:['#4a78c0','#8aaee0'],purple:['#8060c0','#b49ae0'],
 red:['#c05050','#e08e8e'],yellow:['#b08a1a','#d8bc5c'],teal:['#3a948e','#76c2bc'],pink:['#c05090','#e08ebc'],grey:['#808088','#a8a8b0']};
const SP=new Map();String(DATA.meta.special||'').split(/\s+/).filter(Boolean).forEach(t=>{const i=t.indexOf('=');
 const name=i<0?t:t.slice(0,i),c=i<0?'grey':t.slice(i+1).toLowerCase();if(name&&!SP.has(name))SP.set(name,{i:SP.size,c:SPC[c]||[c,c]});});
{const st=document.createElement('style');const v=k=>[...SP.values()].map(o=>`--sp${o.i}:${o.c[k]};`).join('');
 st.textContent=`:root{${v(0)}}@media (prefers-color-scheme:dark){:root{${v(1)}}}`;document.head.appendChild(st);}
const SPN=new Map();
function spOf(n){if(!n||!n.file||!SP.size)return null;if(SPN.has(n.id))return SPN.get(n.id);
 const parts=n.file.split('/').slice(0,-1);let r=null;for(const d of parts)if(SP.has(d)){r={name:d,i:SP.get(d).i};break;}
 SPN.set(n.id,r);return r;}
function unrTag(n){return n.unres?'<span class="badge unrb" title="Not resolved by the scan: check by hand">unresolved</span>':'';}
function spTag(n){const sp=spOf(n);return sp?`<span class="sptag" style="--sp:var(--sp${sp.i})" title="From the ${esc(sp.name)}/ folder">${esc(sp.name)}</span>`:'';}
// components: folders holding a pom.xml; a node belongs to the deepest one above its file.
// Events are left out (their constants often live in a shared module).
const COMPS=(DATA.meta.components||[]).slice().sort((a,b)=>b.dir.length-a.dir.length),CMP=new Map();
function compOf(n){if(!n||!n.file||n.kind==='event'||!COMPS.length)return null;if(CMP.has(n.id))return CMP.get(n.id);
 const c=COMPS.find(c=>c.dir===''||n.file===c.dir||n.file.startsWith(c.dir+'/'));const r=c?c.name:null;CMP.set(n.id,r);return r;}
const USED_COMPS=new Set(DATA.nodes.map(compOf).filter(Boolean)),MULTI=USED_COMPS.size>1;
const HAS_HTTP=DATA.edges.some(e=>e[2]==='http');
// logs: hops on the event bus found in the log files, joined to the map. An event is matched by
// its value (the hop's address), a handler by its class name (the hop's receiver).
const HASLOGS=typeof LOGS!=='undefined'&&!!LOGS,HOPS=HASLOGS?LOGS.hops:[];
const HOPA=new Map(),HOPAT=new Map();
for(const h of HOPS){const a=HOPA.get(h.a)||{n:0,err:0,noReply:0};a.n+=h.n;a.err+=h.err;a.noReply+=h.noReply;HOPA.set(h.a,a);
 const k=h.a+'\u0001'+h.to;HOPAT.set(k,(HOPAT.get(k)||0)+h.n);}
const simpleCls=c=>String(c||'').split('.').pop().split('$')[0];
const fmtN=n=>Number(n).toLocaleString('en-US');
// "×N" when the logs show it, "never seen" for an event whose address is not in them
function seenTag(n,parent){if(!HOPS.length||!n)return'';
 if(n.kind==='event'&&n.value!=null&&!n.unres){const a=HOPA.get(n.value);
  return a?`<span class="seen${a.err||a.noReply?' serr':''}" title="Seen ${fmtN(a.n)} times in the logs${a.err?' · '+fmtN(a.err)+' error replies':''}${a.noReply?' · '+fmtN(a.noReply)+' without reply':''}">×${fmtN(a.n)}</span>`
   :'<span class="nseen" title="Its address never appears in the logs">never seen</span>';}
 if(parent&&parent.kind==='event'&&parent.value!=null&&n.cls){const c=HOPAT.get(parent.value+'\u0001'+simpleCls(n.cls));
  return c?`<span class="seen" title="${esc(simpleCls(n.cls))} received it ${fmtN(c)} times in the logs">×${fmtN(c)}</span>`:'';}
 return'';}
function cmpTag(n){const c=MULTI&&compOf(n);return c?`<span class="badge cmpb" title="Component (folder with a pom.xml)">▣ ${esc(c)}</span>`:'';}
function sub(n){if(n.unres&&n.id.startsWith('unres:'))return (n.kind==='event'?'event name not known statically':'handler not found')+(n.file?' · '+n.file.split('/').pop()+':'+n.line:'');
 if(n.kind==='endpoint'&&n.path)return `${n.verb||''} ${n.path}`;
 if(n.kind==='event'){const e=(IN.get(n.id)||[]).filter(x=>x.k==='emits').length,h=(OUT.get(n.id)||[]).length;
  return `${n.value!=null&&!(n.label||'').startsWith('"')?'"'+n.value+'" · ':''}${e} emitter(s) · ${h} listener(s)`;}
 // the class is left out when the name already starts with it (Listeners.mail() / demo.Listeners)
 const c=n.cls||'';return c&&!(n.label||'').startsWith(c.split('.').pop()+'.')?c:'';}
// chips
for(const k of ORDER){const c=document.createElement('span');c.className='chip k-'+k;c.textContent=KIND[k][0]+' '+KIND[k][1]+' ('+DATA.nodes.filter(n=>n.kind===k).length+')';
 c.onclick=()=>{enabled.has(k)?enabled.delete(k):enabled.add(k);c.classList.toggle('off');renderList();};$('#chips').appendChild(c);}
const hay=new Map(DATA.nodes.map(n=>[n.id,[n.label,n.id,n.value,n.path,n.verb,n.file,n.cls,...akaOf(n).map(a=>a.name)].join(' ').toLowerCase()]));
function renderList(){const toks=$('#q').value.toLowerCase().split(/\s+/).filter(Boolean);
 let r=DATA.nodes.filter(n=>enabled.has(n.kind)&&toks.every(t=>hay.get(n.id).includes(t)));
 r.sort((a,b)=>ORDER.indexOf(a.kind)-ORDER.indexOf(b.kind)||a.label.localeCompare(b.label));
 $('#count').textContent=r.length+' result(s)'+(r.length>400?' – showing 400':'');
 $('#results').innerHTML=r.slice(0,400).map(n=>{const sp=spOf(n);return `<li data-id="${esc(n.id)}" class="${n.id===selected?'sel':''}${sp?' sp':''}${n.unres?' unr':''}"${sp?` style="--sp:var(--sp${sp.i})"`:''}>${ic(n)}<div><div>${nameHtml(n)}</div><div class="sub">${esc(sub(n))} ${seenTag(n)}</div></div>${spTag(n)}</li>`;}).join('');}
$('#results').onclick=e=>{const li=e.target.closest('li');if(li)go(li.dataset.id);};
$('#q').oninput=renderList;
document.addEventListener('keydown',e=>{if(e.key==='/'&&document.activeElement!==$('#q')){e.preventDefault();$('#q').focus();$('#q').select();}});
function go(id){location.hash=encodeURIComponent(id);}
window.addEventListener('hashchange',fromHash);
function fromHash(){const id=decodeURIComponent(location.hash.slice(1));if(id&&N.has(id)){if(view==='issues'||view==='conn'||view==='flows'||view==='logs')setView('browse');select(id);}}
// detail
let dir='fwd',maxDepth=8;
function select(id){selected=id;const n=N.get(id);renderList();
 if(view==='graph'){drawGraph(null,true);return;}
 const roles=(n.roles||[]).filter(r=>r!==n.kind).map(r=>`<span class="badge k-${r}">${r}</span>`).join(' ');
 $('#detail').innerHTML=`<div class="title">${ic(n)}<h2>${nameHtml(n)}</h2><span class="badge k-${n.kind}">${KIND[n.kind][1]}</span>${unrTag(n)}${spTag(n)}${cmpTag(n)}${roles}${seenTag(n)}</div>
 <div class="loc">${n.kind==='endpoint'&&n.path?`<code>${esc((n.verb||'')+' '+n.path)}</code> · `:''}${n.kind==='event'&&n.value!=null&&!n.label.startsWith('"')?`<code>"${esc(n.value)}"</code> · `:''}${n.file?link(n.file,n.abs,n.line,n.file+':'+n.line):''}${n.cls?` <span class="sub">· ${esc(n.cls)}</span>`:''}</div>
 <div class="toolbar"><button class="btn" data-d="fwd">Trace forward ▶</button><button class="btn" data-d="bwd">◀ Trace back</button>
 <span class="sub">depth</span><select id="depth">${[2,3,4,6,8,12,20].map(d=>`<option ${d===maxDepth?'selected':''}>${d}</option>`).join('')}</select>
 <button class="btn" id="expand">Expand all</button><button class="btn" id="collapse">Collapse</button><button class="btn" id="copy">Copy as text</button>
 <label class="sub"><input type="checkbox" id="hideCalls"> events only</label></div>
 <div class="help" id="help"></div><ul class="tree" id="tree"></ul>
 ${akaHtml(n)}<div class="section" id="direct"></div>`;
 document.querySelectorAll('[data-d]').forEach(b=>b.onclick=()=>{dir=b.dataset.d;drawTree();});
 $('#depth').onchange=e=>{maxDepth=+e.target.value;drawTree();};
 $('#expand').onclick=()=>expandAll($('#tree'),0);$('#collapse').onclick=drawTree;
 $('#copy').onclick=()=>{navigator.clipboard.writeText(asText(selected));$('#copy').textContent='Copied ✓';setTimeout(()=>$('#copy').textContent='Copy as text',1200);};
 $('#hideCalls').onchange=drawTree;drawTree();drawDirect(n);}
function hideCalls(){return $('#hideCalls')&&$('#hideCalls').checked;}
// "events only": collapse chains of calls so you see endpoint/handler -> event -> handler
function nextOf(id,d){const raw=(d==='fwd'?OUT:IN).get(id)||[];if(!hideCalls())return raw;
 const out=[],seen=new Set([id]),q=[...raw];
 while(q.length){const e=q.shift();if(seen.has(e.id))continue;seen.add(e.id);
  if(d==='bwd'){
   // going back, stop at the nearest trigger (handler, endpoint, lambda, event, class); a plain
   // method is replaced by its callers, keeping the first link's kind (e.g. "emitted by")
   const n=N.get(e.id);if(!n||n.kind!=='method'){out.push(e);continue;}
   const up=(IN.get(e.id)||[]).filter(m=>m.k==='calls');
   if(up.length)q.push(...up.map(m=>({...m,k:e.k,via:true,a:e.a||m.a})));
   else out.push(e);   // nobody calls it: it is where the chain starts
   continue;}
  if(e.k==='calls'){const more=OUT.get(e.id)||[];q.push(...more.map(m=>({...m,via:true})));}
  else out.push(e);}
 return out;}
function drawTree(){document.querySelectorAll('[data-d]').forEach(b=>b.classList.toggle('on',b.dataset.d===dir));
 $('#help').textContent=dir==='fwd'?'Everything this item triggers, step by step.':'Every path that leads to this item.';
 const t=$('#tree');t.innerHTML='';fill(t,selected,0,new Set([selected]));if(!t.children.length)t.innerHTML='<li class="sub">Nothing found in this direction.</li>';}
function fill(ul,id,depth,path){for(const e of nextOf(id,dir)){const n=N.get(e.id);if(!n)continue;const li=document.createElement('li');
 const lab=(dir==='fwd'?FWD:BWD)[e.k]+(e.via?' (via calls)':'');
 const row=`<span class="row"><span class="elabel">${esc(lab)}</span>${ic(n)}<span class="nm${n.unres?' unr':''}" data-id="${esc(n.id)}">${nameHtml(n)}</span>${spTag(n)}${seenTag(n,dir==='fwd'?N.get(id):null)}${n.kind==='endpoint'&&n.path?`<code>${esc((n.verb||'')+' '+n.path)}</code>`:''}${asTag(e)}${link(e.f,absOf(e.f),e.l)}</span>`;
 const kids=nextOf(e.id,dir);
 if(path.has(e.id)){li.className='leaf';li.innerHTML=row+' <span class="cyc">↻ cycle</span>';}
 else if(!kids.length){li.className='leaf';li.innerHTML=row;}
 else if(depth+1>=maxDepth){li.className='leaf';li.innerHTML=row+' <span class="sub">… (max depth)</span>';}
 else{const det=document.createElement('details');det.innerHTML=`<summary>${row} <span class="sub">(${kids.length})</span></summary>`;
  const sub=document.createElement('ul');det.appendChild(sub);
  det.addEventListener('toggle',()=>{if(det.open&&!sub.dataset.done){sub.dataset.done=1;fill(sub,e.id,depth+1,new Set([...path,e.id]));}});li.appendChild(det);}
 ul.appendChild(li);}}
const ABS=new Map(DATA.nodes.filter(n=>n.file).map(n=>[n.file,n.abs]));function absOf(f){return ABS.get(f)||(DATA.meta.root+'/'+f);}
function expandAll(root,budget){let opened=0;const step=()=>{const closed=[...root.querySelectorAll('details:not([open])')];if(!closed.length||opened>1500)return;
 closed.forEach(d=>{d.open=true;opened++;});setTimeout(step,0);};step();}
$('#detail').addEventListener('click',e=>{const x=e.target.closest('.nm');if(x){e.preventDefault();go(x.dataset.id);}});
function drawDirect(n){const rows=(list,lbl)=>list.map(e=>{const m=N.get(e.id);return m?`<tr><td>${esc(lbl[e.k])}${asTag(e)}</td><td><span class="row">${ic(m)}<span class="nm${m.unres?' unr':''}" data-id="${esc(m.id)}">${nameHtml(m)}</span>${spTag(m)}</span></td><td>${link(e.f,absOf(e.f),e.l)}</td></tr>`:''}).join('');
 const o=OUT.get(n.id)||[],i=IN.get(n.id)||[];
 $('#direct').innerHTML=`<h3>Direct links</h3><table><tr><th>Relation</th><th>Item</th><th>Where</th></tr>${rows(i,BWD)}${rows(o,FWD)||''}${!o.length&&!i.length?'<tr><td colspan=3 class="sub">none</td></tr>':''}</table>`;}
function asText(id){const lines=[];const n=N.get(id);lines.push(`${KIND[n.kind][1]}: ${n.label}${n.path?' ['+(n.verb||'')+' '+n.path+']':''}  (${n.file||''}:${n.line||''})`);
 const walk=(cur,depth,path)=>{if(depth>=maxDepth)return;for(const e of nextOf(cur,dir)){const m=N.get(e.id);if(!m)continue;
  lines.push(`${'  '.repeat(depth+1)}${(dir==='fwd'?FWD:BWD)[e.k]} -> ${KIND[m.kind][1]}: ${m.label}${e.a?'  [as '+e.a+']':''}  (${e.f}:${e.l})${path.has(e.id)?'  [cycle]':''}`);
  if(!path.has(e.id))walk(e.id,depth+1,new Set([...path,e.id]));}};
 walk(id,0,new Set([id]));return lines.join('\n');}
// issues
function setView(v){view=v;$('#detail').classList.toggle('gview',v==='graph'||v==='conn');['Browse','Graph','Flows','Logs','Conn','Issues'].forEach(x=>$('#t'+x).classList.toggle('on',v===x.toLowerCase()));}
$('#tBrowse').onclick=()=>{setView('browse');selected?select(selected):null;};
$('#tGraph').onclick=()=>{setView('graph');if(selected)drawGraph(null,true);
 else $('#detail').innerHTML='<div class="empty">Pick an item on the left to center the graph on it.</div>';};
// graph: centered on the selected item, incoming links on the left, outgoing on the right.
// Each node has two badges: ◂ (top left) opens its incoming links, ▸ (top right) its outgoing ones.
const G={center:null,open:new Set(),lim:new Map(),pos:new Map(),t:{x:0,y:0,k:1},hide:false,auto:true,focus:null,dragged:false,moved:new Map()};
// Node sizes follow their text: each column is as wide as its longest name (GMIN..GMAX), names
// still too long wrap at dots / camelCase humps, and node height follows the number of lines.
const GMIN=190,GMAX=400,GHMIN=46,LH=14,GAP=96,VGAP=20,GLIM=25;
const isOpen=(id,d)=>G.open.has(id+'|'+d);
const keyId=k=>k.slice(0,k.lastIndexOf('|'));
function uniqNext(id,d){const seen=new Map(),r=[];
 for(const e of nextOf(id,d)){if(e.id===id||!N.has(e.id))continue;const o=seen.get(e.id);
  if(o){if(e.a&&!o.a)o.a=e.a;continue;}const c={...e};seen.set(e.id,c);r.push(c);}return r;}
// one outline per kind: endpoint = hexagon, event = parallelogram, handler = pill,
// lambda = cut corners, method = square corners, class = rounded with a double border
function shapeD(kind,w,h){const r=Math.min(h/2,23),s=Math.round(Math.min(h,50)*.25),c=Math.round(Math.min(h,50)*.2),q=Math.round(Math.min(h,50)*.14);switch(kind){
 case 'endpoint':return `M${s},0H${w-s}L${w},${h/2}L${w-s},${h}H${s}L0,${h/2}Z`;
 case 'event':return `M${s},0H${w}L${w-s},${h}H0Z`;
 case 'handler':return `M${r},0H${w-r}A${r},${r} 0 0 1 ${w},${r}V${h-r}A${r},${r} 0 0 1 ${w-r},${h}H${r}A${r},${r} 0 0 1 0,${h-r}V${r}A${r},${r} 0 0 1 ${r},0Z`;
 case 'lambda':return `M${c},0H${w-c}L${w},${c}V${h-c}L${w-c},${h}H${c}L0,${h-c}V${c}Z`;
 case 'class':return `M0,${q}Q0,0 ${q},0H${w-q}Q${w},0 ${w},${q}V${h-q}Q${w},${h} ${w-q},${h}H${q}Q0,${h} 0,${h-q}Z`;
 default:return `M0,0H${w}V${h}H0Z`;}}
const PAD={endpoint:15,event:15,handler:17,lambda:12,method:10,class:11};
// text measuring, with the page font
const MC=document.createElement('canvas').getContext('2d');let FAM=null;
const FSZ={gsp:'600 9.5px',gp:'10px',gm:'600 12.5px',gs:'10.5px',gal2:'italic 10px',gal:'italic 10.5px'};
function tw(s,c){FAM=FAM||getComputedStyle(document.body).fontFamily;MC.font=FSZ[c]+' '+FAM;return MC.measureText(s).width;}
// break points: after . _ , ( / : # - and at camelCase humps (fooBar, HTTPServer)
function segs(s){const out=[];let cur='';for(let i=0;i<s.length;i++){const a=s[i-1],b=s[i],c=s[i+1];
 if(cur&&(/[._,(/:#\-]/.test(a)||(/[a-z0-9]/.test(a)&&/[A-Z]/.test(b))||(/[A-Z]/.test(a)&&/[A-Z]/.test(b)&&c&&/[a-z]/.test(c)))){out.push(cur);cur='';}cur+=b;}
 if(cur)out.push(cur);return out;}
function ell(s,c,w){if(tw(s,c)<=w)return s;while(s.length>1&&tw(s+'…',c)>w)s=s.slice(0,-1);return s+'…';}
function lell(s,c,w){if(tw(s,c)<=w)return s;while(s.length>1&&tw('…'+s,c)>w)s=s.slice(1);return '…'+s;}
function wrap(s,c,w,max){if(tw(s,c)<=w)return [s];const out=[];let cur='';
 for(const g of segs(s)){if(cur&&tw(cur+g,c)>w){out.push(cur);cur=g;}else cur+=g;}if(cur)out.push(cur);
 if(out.length>max){const rest=out.slice(max-1).join('');out.length=max-1;out.push(rest);}
 return out.map(l=>ell(l,c,w));}
// "Owner.member(...)" -> ["Owner", "member(...)"]; a quoted event value stays whole
function splitName(n){const L=n.label||'';if(L.startsWith('"')||n.kind==='lambda'||(n.unres&&n.id.startsWith('unres:')))return [null,L];
 const p=L.indexOf('('),head=p<0?L:L.slice(0,p),cut=Math.max(head.lastIndexOf('.'),head.lastIndexOf('#'),head.lastIndexOf('::'));
 if(cut<=0)return [null,L];const sep=head.startsWith('::',cut)?2:1;return [L.slice(0,cut),L.slice(cut+sep)];}
function gSpec(n){const [own,mem]=splitName(n),al=aliasesOf(n),L=[];
 if(own)L.push({c:'gp',t:own,m:'left'});
 L.push({c:'gm',t:mem,m:'wrap'});
 const extra=n.kind==='endpoint'&&n.path?(n.verb||'')+' '+n.path
  :n.kind==='event'?(n.value!=null&&!(n.label||'').startsWith('"')?'"'+n.value+'"':'')
  :(own?'':n.cls||'');
 if(extra)L.push({c:'gs',t:extra,m:'cut'});
 if(al.length)L.push({c:'gal2',t:'≡ '+al.map(a=>short(a.name)).join(', '),m:'cut'});
 return L;}
const inner=(kind,w)=>w-(PAD[kind]||10)*2-24;   // room for text inside a node of width w
// Breadth-first from the center through the opened directions. Each node keeps the column where it
// was first reached (outgoing = +1, incoming = -1) and its discovery order sets its row.
function gLayout(){const c=G.center,col=new Map([[c,0]]),seq=new Map([[c,0]]),q=[c],more=[];let n=1;
 while(q.length){const id=q.shift();
  for(const [d,s] of [['bwd',-1],['fwd',1]]){if(!isOpen(id,d))continue;const list=uniqNext(id,d),key=id+'|'+d,lim=G.lim.get(key)||GLIM;
   for(const e of list.slice(0,lim))if(!col.has(e.id)){col.set(e.id,col.get(id)+s);seq.set(e.id,n++);q.push(e.id);}
   if(list.length>lim)more.push({key,owner:id,d,n:list.length-lim,col:col.get(id)+s,seq:n++});}}
 const cols=new Map(),add=o=>(cols.get(o.col)||cols.set(o.col,[]).get(o.col)).push(o);
 for(const [id,cl] of col)add({id,col:cl,seq:seq.get(id)});more.forEach(add);
 // widths: each column fits its widest node
 const cw=new Map();
 for(const [cl,arr] of cols){let w=GMIN;
  for(const o of arr){if(o.key)continue;const nd=N.get(o.id);o.spec=gSpec(nd);
   const need=Math.max(...o.spec.map(l=>tw(l.t,l.c)))+(PAD[nd.kind]||10)*2+24;w=Math.max(w,need);}
  cw.set(cl,Math.min(GMAX,Math.ceil(w)));}
 // gaps: wide enough for the "as ALIAS" labels drawn between two columns
 const gap=new Map();
 for(const [id,cl] of col)for(const e of uniqNext(id,'fwd')){if(!e.a||!col.has(e.id))continue;const c2=col.get(e.id);
  if(Math.abs(c2-cl)!==1)continue;const g=Math.min(cl,c2),need=tw('as '+short(e.a),'gal')+44;gap.set(g,Math.max(gap.get(g)||GAP,need));}
 const xs=new Map([[0,0]]),keys=[...cols.keys()];
 for(let cl=1;cl<=Math.max(0,...keys);cl++)xs.set(cl,xs.get(cl-1)+cw.get(cl-1)/2+(gap.get(cl-1)||GAP)+cw.get(cl)/2);
 for(let cl=-1;cl>=Math.min(0,...keys);cl--)xs.set(cl,xs.get(cl+1)-cw.get(cl+1)/2-(gap.get(cl)||GAP)-cw.get(cl)/2);
 const pos=new Map();
 for(const [cl,arr] of cols){arr.sort((a,b)=>a.seq-b.seq);const w=cw.get(cl);
  const items=arr.map(o=>{if(o.key)return {o,h:GHMIN,lines:null};const nd=N.get(o.id),room=inner(nd.kind,w),lines=[];
   for(const l of o.spec){if(l.m==='wrap')wrap(l.t,l.c,room,3).forEach(t=>lines.push([l.c,t]));
    else lines.push([l.c,l.m==='left'?lell(l.t,l.c,room):ell(l.t,l.c,room)]);}
   return {o,h:Math.max(GHMIN,lines.length*LH+18),lines};});
  let y=-(items.reduce((s,it)=>s+it.h,0)+VGAP*(items.length-1))/2;
  for(const it of items){pos.set(it.o.key||it.o.id,{x:xs.get(cl),y:y+it.h/2,w,h:it.h,lines:it.lines,more:it.o.key?it.o:null});y+=it.h+VGAP;}}
 return pos;}
function edgePath(a,b){const ax=a.x+a.w/2,bx=b.x-b.w/2;
 if(bx>ax+10){const m=(ax+bx)/2;return `M${ax},${a.y}C${m},${a.y} ${m},${b.y} ${bx},${b.y}`;}
 const ax2=a.x-a.w/2,bx2=b.x+b.w/2;
 if(ax2>bx2+10){const m=(ax2+bx2)/2;return `M${ax2},${a.y}C${m},${a.y} ${m},${b.y} ${bx2},${b.y}`;}
 const y=Math.max(a.y+a.h/2,b.y+b.h/2)+28;return `M${a.x},${a.y+a.h/2}C${a.x},${y} ${b.x},${y} ${b.x},${b.y+b.h/2}`;}
function gShell(){const n=N.get(G.center);
 const shapes=ORDER.map(k=>`<span><svg width="20" height="13"><path class="s-${k}" d="${shapeD(k,20,13)}" style="fill:var(--panel);stroke-width:1.4"/>${k==='class'?`<path class="s-class" transform="translate(2,2)" d="${shapeD(k,16,9)}" style="fill:none;stroke-width:1"/>`:''}</svg>${KIND[k][1]}</span>`).join('');
 $('#detail').innerHTML=`<div id="ghead"></div>
 <div class="toolbar"><button class="btn" id="gExpB" title="Open the incoming links of every node shown">◀ Expand all</button><button class="btn" id="gExpF" title="Open the outgoing links of every node shown">Expand all ▶</button>
 <button class="btn" id="gCollapse">Collapse all</button><button class="btn" id="gFit" title="Fit (F)">Fit</button>
 <label class="sub"><input type="checkbox" id="hideCalls" ${G.hide?'checked':''}> events only</label></div>
 <div class="help"><b>◂ / ▸</b> badges show or hide incoming / outgoing links · click a node to show it above (Esc or the background to go back) · drag a node to move it (Collapse all resets) · drag the background to pan, scroll to zoom · <b>F</b> fit · <b>Esc</b> clear</div>
 <div id="gwrap"><svg id="gsvg" data-c="${esc(G.center)}"><defs>${['emits','handled_by','calls','http'].map(k=>
  `<marker id="ar-${k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0L10,5L0,10z" style="fill:var(${k==='emits'?'--ev':k==='handled_by'?'--hd':k==='http'?'--ep':'--me'})"/></marker>`).join('')}</defs><g id="gvp"></g></svg></div>
 <div class="glegend"><div>${shapes}${DATA.nodes.some(n=>n.unres)?'<span class="unrl"><svg width="20" height="13"><rect x="1" y="1" width="18" height="11" rx="3"/></svg>unresolved</span>':''}${[...SP].filter(([d])=>DATA.nodes.some(n=>spOf(n)?.name===d)).map(([d,o])=>`<span class="sptag" style="--sp:var(--sp${o.i})">${esc(d)}</span>`).join('')}</div><div><span><i style="border-color:var(--ev)"></i>emits</span><span><i style="border-color:var(--hd)"></i>handled by</span>
 <span><i style="border-color:var(--me);border-top-style:dashed"></i>calls</span>${HAS_HTTP?'<span><i style="border-color:var(--ep);border-top-style:dashed"></i>HTTP</span>':''}<span><i style="border-color:var(--mute);border-top-style:dotted"></i>via calls (events only)</span></div></div>`;
 const expandAll=d=>{for(const id of G.pos.keys())if(N.has(id)&&uniqNext(id,d).length)G.open.add(id+'|'+d);drawGraph(null,true);};
 $('#gExpB').onclick=()=>expandAll('bwd');$('#gExpF').onclick=()=>expandAll('fwd');
 $('#gCollapse').onclick=()=>{G.open=new Set([G.center+'|bwd',G.center+'|fwd']);G.lim=new Map();G.moved=new Map();drawGraph(null,true);};
 $('#gFit').onclick=()=>{gFit();gApply();};
 $('#hideCalls').onchange=e=>{G.hide=e.target.checked;drawGraph(null,true);};
 const svg=$('#gsvg');let drag=null;
 svg.addEventListener('wheel',e=>{e.preventDefault();const r=svg.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top;
  const k=Math.min(3,Math.max(0.12,G.t.k*Math.exp(-e.deltaY*0.0015)));
  G.t.x=mx-(mx-G.t.x)*k/G.t.k;G.t.y=my-(my-G.t.y)*k/G.t.k;G.t.k=k;G.auto=false;gApply();},{passive:false});
 // refit when the panel gets its final size, until the user pans or zooms
 new ResizeObserver(()=>{if(G.auto&&$('#gsvg')===svg){gFit();gApply();}}).observe(svg);
 // drag the background to pan, drag a node to move it (its links follow; a short press is a click)
 svg.addEventListener('pointerdown',e=>{if(e.button)return;if(e.target.closest('.gb,.gmore'))return;const g=e.target.closest('.gn');
  if(g){const p=G.pos.get(g.dataset.id);drag={node:g.dataset.id,g,x:e.clientX,y:e.clientY,px:p.x,py:p.y,moved:false};return;}
  drag={x:e.clientX,y:e.clientY,tx:G.t.x,ty:G.t.y,moved:false};svg.classList.add('pan');svg.setPointerCapture(e.pointerId);});
 svg.addEventListener('pointermove',e=>{if(!drag)return;const dx=e.clientX-drag.x,dy=e.clientY-drag.y;
  if(!drag.moved&&Math.abs(dx)+Math.abs(dy)<=4)return;
  if(!drag.moved){drag.moved=true;G.auto=false;if(drag.node){svg.classList.add('moving');drag.g.classList.add('drag');svg.setPointerCapture(e.pointerId);}}
  if(drag.node){const p=G.pos.get(drag.node);p.x=drag.px+dx/G.t.k;p.y=drag.py+dy/G.t.k;gMoveNode(drag.node,drag.g);return;}
  G.t.x=drag.tx+dx;G.t.y=drag.ty+dy;gApply();});
 const endDrag=()=>{if(drag&&drag.moved){G.dragged=true;setTimeout(()=>G.dragged=false);
   if(drag.node){const p=G.pos.get(drag.node),m=G.moved.get(drag.node)||{dx:0,dy:0};
    G.moved.set(drag.node,{dx:m.dx+p.x-drag.px,dy:m.dy+p.y-drag.py});svg.classList.remove('moving');drawGraph(null);}}
  drag=null;svg.classList.remove('pan');};
 svg.addEventListener('pointerup',endDrag);svg.addEventListener('pointercancel',endDrag);
 svg.addEventListener('click',e=>{if(G.dragged)return;
  const b=e.target.closest('.gb');if(b){gToggle(b.closest('.gn').dataset.id,b.dataset.d);return;}
  const m=e.target.closest('.gmore');
  if(m){const p=G.pos.get(m.dataset.key).more;G.lim.set(p.key,(G.lim.get(p.key)||GLIM)+GLIM);drawGraph(p.owner);return;}
  const g=e.target.closest('.gn');if(!g){gFocus(null);return;}const id=g.dataset.id;
  gFocus(G.focus===id?null:id);});}
function gToggle(id,d){const key=id+'|'+d;
 if(G.open.has(key)){G.open.delete(key);
  // forget opened directions that are no longer reachable from the center
  const vis=gLayout();for(const k of [...G.open])if(!vis.has(keyId(k)))G.open.delete(k);}
 else if(uniqNext(id,d).length)G.open.add(key);else return;
 drawGraph(id);}
function gBadge(id,d,pos,w){const all=uniqNext(id,d);if(!all.length)return'';
 const on=isOpen(id,d),hidden=all.filter(e=>!pos.has(e.id)).length;if(!on&&!hidden)return'';
 const t=on?(d==='bwd'?'◂ −':'− ▸'):(d==='bwd'?'◂ '+hidden:hidden+' ▸'),bw=Math.max(28,12+t.length*6.5);
 return `<g class="gb${on?' on':''}" data-d="${d}" transform="translate(${d==='bwd'?0:w},0)"><title>${on?'Hide':'Show'} ${d==='bwd'?'incoming':'outgoing'} links (${all.length}${hidden?', '+hidden+' not shown':''})</title><rect x="${-bw/2}" y="-9" width="${bw}" height="18" rx="9"/><text y="4">${t}</text></g>`;}
function drawGraph(anchor,fit){
 if(G.center!==selected){G.center=selected;G.open=new Set([selected+'|bwd',selected+'|fwd']);G.lim=new Map();G.pos=new Map();G.focus=null;G.moved=new Map();fit=true;}
 if(!$('#gsvg')||$('#gsvg').dataset.c!==G.center){gShell();fit=true;}
 const old=anchor&&G.pos.get(anchor),pos=gLayout();G.pos=pos;
 for(const [id,m] of G.moved){const p=pos.get(id);if(p){p.x+=m.dx;p.y+=m.dy;}}if(G.focus&&!pos.has(G.focus))G.focus=null;
 const edges=[],labels=[],seen=new Set();
 for(const [id,p] of pos){if(p.more){const o=pos.get(p.more.owner);edges.push(`<path class="ge more" data-o="${esc(p.more.owner)}" data-m="${esc(id)}" d="${p.more.d==='fwd'?edgePath(o,p):edgePath(p,o)}"/>`);continue;}
  for(const e of uniqNext(id,'fwd')){if(!pos.has(e.id)||seen.has(id+'>'+e.id))continue;seen.add(id+'>'+e.id);
   const a=N.get(id),b=N.get(e.id),k=FWD[e.k]?e.k:'calls',q=pos.get(e.id);
   edges.push(`<path class="ge ${k}${e.via?' via':''}" data-s="${esc(id)}" data-d="${esc(e.id)}" d="${edgePath(p,q)}" marker-end="url(#ar-${k})"><title>${esc(a.label+' '+(FWD[e.k]||e.k)+' '+b.label+(e.a?' (written as the alias '+e.a+')':'')+(e.f?' — '+e.f+':'+e.l:''))}</title></path>`);
   // an emit or listener that names the event through an alias gets an "as ALIAS" label at the
   // emitter / handler end (several can meet at the event); the column gap is sized to fit it,
   // and labels are drawn above the nodes
   if(e.a){const ltr=(q.x-q.w/2)-(p.x+p.w/2)>10,atEv=a.kind==='event';
    // just under the line, clear of the corner badges
    const [x,y,an]=!ltr?[(p.x+q.x)/2,(p.y+q.y)/2-6,'middle']:atEv?[q.x-q.w/2-8,q.y+15,'end']:[p.x+p.w/2+8,p.y+15,'start'];
    labels.push(`<text class="gal" x="${x}" y="${y}" style="text-anchor:${an}"><title>${esc('Written in the code as '+e.a)}</title>as ${esc(short(e.a))}</text>`);}}}
 const nodes=[];
 for(const [id,p] of pos){const {w,h}=p;
  if(p.more){nodes.push(`<g class="gmore" data-key="${esc(id)}" transform="translate(${p.x-w/2},${p.y-h/2})"><title>Show ${Math.min(GLIM,p.more.n)} more</title><rect width="${w}" height="${h}" rx="8"/><text x="${w/2}" y="${h/2+4}">+${p.more.n} more…</text></g>`);continue;}
  const n=N.get(id),pad=PAD[n.kind]||10,tx=pad+20,y0=h/2-(p.lines.length-1)*LH/2+4;
  const txt=p.lines.map(([c,s],i)=>`<text class="${c}" x="${tx}" y="${y0+i*LH}">${esc(s)}</text>`).join('');
  const nin=uniqNext(id,'bwd').length,nout=uniqNext(id,'fwd').length;
  const tip=`${KIND[n.kind][1]}: ${n.label}${n.value!=null?'\n"'+n.value+'"':''}${n.path?'\n'+(n.verb||'')+' '+n.path:''}${n.cls?'\n'+n.cls:''}${n.file?'\n'+n.file+':'+n.line:''}\n${nin} incoming · ${nout} outgoing`;
  const sp=spOf(n),tw2=sp?Math.ceil(tw(sp.name,'gsp'))+12:0;
  const spg=sp?`<g class="gsp" transform="translate(${w-tw2-pad-6},${h-7})"><rect width="${tw2}" height="14" rx="7"/><text x="${tw2/2}" y="10">${esc(sp.name)}</text></g>`:'';
  nodes.push(`<g class="gn${id===G.center?' ctr':''}${sp?' sp':''}${n.unres?' unr':''}"${sp?` style="--sp:var(--sp${sp.i})"`:''} data-id="${esc(id)}" transform="translate(${p.x-w/2},${p.y-h/2})"><title>${esc((n.unres?'UNRESOLVED: '+(n.kind==='event'?'event name not known statically':n.kind==='handler'?'handler not found':'')+'\n':'')+tip+(sp?'\nFrom the '+sp.name+'/ folder':''))}</title>
   <path class="box s-${n.kind}" d="${shapeD(n.kind,w,h)}"/>${n.kind==='class'?`<path class="box2 s-class" transform="translate(3,3)" d="${shapeD('class',w-6,h-6)}"/>`:''}
   <text class="ki f-${n.kind}" x="${pad}" y="${h/2+5}">${KIND[n.kind][0]}</text>${txt}${spg}${gBadge(id,'bwd',pos,w)}${gBadge(id,'fwd',pos,w)}</g>`);}
 $('#gvp').innerHTML=edges.join('')+nodes.join('')+labels.join('');
 if(fit)gFit();
 else if(old&&pos.get(anchor)){G.auto=false;const p=pos.get(anchor);G.t.x-=(p.x-old.x)*G.t.k;G.t.y-=(p.y-old.y)*G.t.k;}
 gApply();gHighlight();gInfo();}
// while a node is dragged: move it and redraw only the links touching it ("as ALIAS" labels are
// hidden until the drop, when the whole graph is redrawn with the new position)
function gMoveNode(id,g){const p=G.pos.get(id),vp=$('#gvp');g.setAttribute('transform',`translate(${p.x-p.w/2},${p.y-p.h/2})`);
 vp.querySelectorAll('.gal').forEach(t=>t.style.display='none');
 vp.querySelectorAll('.ge[data-s]').forEach(e=>{if(e.dataset.s===id||e.dataset.d===id){const a=G.pos.get(e.dataset.s),b=G.pos.get(e.dataset.d);if(a&&b)e.setAttribute('d',edgePath(a,b));}});
 vp.querySelectorAll('.ge.more').forEach(e=>{if(e.dataset.o===id){const m=G.pos.get(e.dataset.m),o=p;e.setAttribute('d',m.more.d==='fwd'?edgePath(o,m):edgePath(m,o));}});}
// focus: a clicked node lights up with its direct links, and a details card opens
function gFocus(id){G.focus=id;gHighlight();gInfo();}
function gHighlight(){const vp=$('#gvp');if(!vp)return;vp.querySelectorAll('.hl,.foc').forEach(e=>e.classList.remove('hl','foc'));
 vp.classList.toggle('dim',!!G.focus);if(!G.focus)return;const f=G.focus,mark=id=>{const g=vp.querySelector(`.gn[data-id="${CSS.escape(id)}"]`);if(g)g.classList.add('hl');return g;};
 vp.querySelectorAll('.ge[data-s]').forEach(e=>{if(e.dataset.s===f||e.dataset.d===f){e.classList.add('hl');mark(e.dataset.s===f?e.dataset.d:e.dataset.s);}});
 const g=mark(f);if(g)g.classList.add('foc');}
// the top of the graph view describes the selected node, or the center when nothing is selected
function gInfo(){const box=$('#ghead');if(!box)return;const n=N.get(G.focus||G.center),sel=!!G.focus&&G.focus!==G.center;
 const al=aliasesOf(n);
 box.innerHTML=`<div class="title">${ic(n)}<h2>${nameHtml(n)}</h2><span class="badge k-${n.kind}">${KIND[n.kind][1]}</span>${unrTag(n)}${spTag(n)}${cmpTag(n)}${sel?'<span class="badge gsel">selected</span>':'<span class="badge gsel">center</span>'}</div>
 <div class="loc">${n.kind==='endpoint'&&n.path?`<code>${esc((n.verb||'')+' '+n.path)}</code> · `:''}${n.kind==='event'&&n.value!=null&&!n.label.startsWith('"')?`<code>"${esc(n.value)}"</code> · `:''}${n.file?link(n.file,n.abs,n.line,n.file+':'+n.line):''}${n.cls?` <span class="sub">· ${esc(n.cls)}</span>`:''}${al.length?` · <span class="alias" title="${esc(al.map(a=>a.name+' = '+a.to+(a.missing?' (target not found)':'')).join(' · '))}">≡ ${esc(al.map(a=>short(a.name)).join(', '))}</span>`:''}</div>`;}
// "ClassName.member" on two lines: the owner small and grey above, the member below
function nameHtml(n){const [own,mem]=splitName(n);return twoLines(own,mem);}
// <wbr> at dots and camelCase humps lets long names wrap cleanly
const wb=s=>segs(String(s)).map(esc).join('<wbr>');
function twoLines(own,mem){return (own?`<span class="own">${wb(own)}</span>`:'')+wb(mem);}
// same rule for a plain "Class.NAME" string (constant names)
function nameStr(t){const s=String(t??'');if(s.startsWith('"'))return esc(s);const c=s.lastIndexOf('.');return c>0?twoLines(s.slice(0,c),s.slice(c+1)):esc(s);}
document.addEventListener('keydown',e=>{if(view!=='graph'||!$('#gsvg')||/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName))return;
 if(e.key==='Escape')gFocus(null);else if(e.key==='f'||e.key==='F'){gFit();gApply();}});
function gFit(){const svg=$('#gsvg'),W=svg.clientWidth||800,H=svg.clientHeight||500;let x0=1e9,x1=-1e9,y0=1e9,y1=-1e9;
 for(const p of G.pos.values()){x0=Math.min(x0,p.x-p.w/2-16);x1=Math.max(x1,p.x+p.w/2+16);y0=Math.min(y0,p.y-p.h/2-12);y1=Math.max(y1,p.y+p.h/2+30);}
 const k=Math.min(1.1,W/(x1-x0+60),H/(y1-y0+60));G.auto=true;G.t={k,x:W/2-(x0+x1)/2*k,y:H/2-(y0+y1)/2*k};}
function gApply(){$('#gvp').setAttribute('transform',`translate(${G.t.x},${G.t.y}) scale(${G.t.k})`);}
$('#tIssues').onclick=()=>{setView('issues');drawIssues();};
// ---------------------------------------------------------------- connectivity
// Starting from every endpoint, follow the links (plain calls are walked through, even into a
// shared module) and stop at the first item of ANOTHER component reached by an event (handled by)
// or an HTTP call. Each item reached that way is followed in turn, so chains go on A -> B -> C.
if(MULTI)$('#tConn').hidden=false;
$('#tConn').onclick=()=>{setView('conn');drawConn();};
let CONN=null;
function connLinks(){if(CONN)return CONN;const links=new Map(),orig=[],seenO=new Set();
 const addO=id=>{if(!seenO.has(id)){seenO.add(id);orig.push(id);}};
 for(const n of DATA.nodes)if(n.kind==='endpoint'&&compOf(n))addO(n.id);
 for(let i=0;i<orig.length;i++){const o=orig[i],oc=compOf(N.get(o)),seen=new Set([o]),q=[[o,null,null]];
  while(q.length){const [cur,ev,first]=q.shift();
   for(const e of OUT.get(cur)||[]){const m=N.get(e.id);if(!m||seen.has(e.id))continue;seen.add(e.id);const mc=compOf(m);
    const via=e.k==='emits'?e.id:ev,hop=first||{f:e.f,l:e.l};
    if((e.k==='http'||e.k==='handled_by')&&mc&&mc!==oc){const k=e.k==='http'?'http':'event',key=o+'>'+e.id+'>'+k;
     const L=links.get(key)||links.set(key,{from:o,to:e.id,k,via:new Set(),at:{f:e.f,l:e.l}}).get(key);
     if(k==='event'&&via)L.via.add(via);addO(e.id);continue;}
    q.push([e.id,via,hop]);}}}
 return CONN=[...links.values()];}
const C={t:{x:0,y:0,k:1},auto:true,dragged:false,hl:null};
function drawConn(){const links=connLinks();
 const items=new Map();for(const l of links){for(const id of [l.from,l.to]){const c=compOf(N.get(id));(items.get(c)||items.set(c,new Set()).get(c)).add(id);}}
 const comps=[...items.keys()].sort((a,b)=>a.localeCompare(b));
 $('#detail').innerHTML=`<div class="title"><h2>Connectivity</h2><span class="sub">${comps.length} components · ${links.length} links</span></div>
 <div class="help">Endpoints, and what they reach in other components: an event handled there, or an HTTP call matched to its endpoint (plain calls into shared modules are followed, not shown). Hover an item to see its links · click it to open it in the graph · drag a component to move it · drag the background to pan, scroll to zoom · <b>F</b> fit</div>
 <div id="gwrap"><svg id="csvg"><defs>${['event','http'].map(k=>`<marker id="ca-${k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0L10,5L0,10z" style="fill:var(${k==='http'?'--ep':'--hd'})"/></marker>`).join('')}</defs><g id="cvp"></g></svg></div>
 <div class="glegend"><div><span class="cbox">▣</span>component<span><svg width="20" height="13"><path class="s-endpoint" d="${shapeD('endpoint',20,13)}" style="fill:var(--panel);stroke-width:1.4"/></svg>endpoint</span></div>
 <div><span><i style="border-color:var(--hd)"></i>event handled in another component</span><span><i style="border-color:var(--ep);border-top-style:dashed"></i>HTTP call</span></div></div>`;
 if(!links.length){$('#gwrap').innerHTML='<div class="empty">No link between components found.</div>';return;}
 // layout: components flow left to right. Each component gets a column from the links between
 // components (callers before the components they reach; cycles broken), boxes in a column and
 // items in a box are then ordered by the height of what they link to (a few barycenter passes),
 // so most links run left to right without crossing.
 const IW=n=>Math.max(tw(splitName(n)[1]||n.label,'gm'),tw(connSub(n),'gp'))+54;
 const box=new Map(),cOut=new Map(),cIn=new Map(),nb=new Map();
 for(const c of comps){const ids=[...items.get(c)].sort((a,b)=>{const x=N.get(a),y=N.get(b);return (x.kind==='endpoint'?0:1)-(y.kind==='endpoint'?0:1)||x.label.localeCompare(y.label);});
  const w=Math.min(380,Math.max(220,tw(c,'gm')+60,...ids.map(id=>IW(N.get(id))+24)));box.set(c,{c,ids,w,h:40+ids.length*46});cOut.set(c,new Map());cIn.set(c,new Map());}
 const bump=(m,k)=>m.set(k,(m.get(k)||0)+1);
 for(const l of links){const a=compOf(N.get(l.from)),z=compOf(N.get(l.to));if(a===z)continue;bump(cOut.get(a),z);bump(cIn.get(z),a);
  (nb.get(l.from)||nb.set(l.from,[]).get(l.from)).push(l.to);(nb.get(l.to)||nb.set(l.to,[]).get(l.to)).push(l.from);}
 // drop back edges (depth-first, sources first), then rank = longest path from a source
 const st=new Map(),fwd=new Map(comps.map(c=>[c,[]]));
 const order=[...comps].sort((a,b)=>(cIn.get(a).size-cOut.get(a).size)-(cIn.get(b).size-cOut.get(b).size)||a.localeCompare(b));
 const dfs=c=>{st.set(c,1);for(const z of [...cOut.get(c).keys()].sort()){if(st.get(z)===1)continue;fwd.get(c).push(z);if(!st.has(z))dfs(z);}st.set(c,2);};
 for(const c of order)if(!st.has(c))dfs(c);
 const rank=new Map(comps.map(c=>[c,0]));
 for(let it=0;it<comps.length;it++)for(const c of comps)for(const z of fwd.get(c))if(rank.get(z)<rank.get(c)+1)rank.set(z,rank.get(c)+1);
 const cols=[];for(const c of order){const r=rank.get(c);(cols[r]||(cols[r]=[])).push(box.get(c));}
 for(let i=0;i<cols.length;i++)if(!cols[i])cols[i]=[];
 const CG=170,BG=46,colX=[];let x=0;
 for(const col of cols){const w=Math.max(220,...col.map(b=>b.w));colX.push(x);col.forEach(b=>b.cw=w);x+=w+CG;}
 const place=()=>{const hs=cols.map(col=>col.reduce((s,b)=>s+b.h,0)+BG*Math.max(0,col.length-1)),H=Math.max(...hs);
  cols.forEach((col,i)=>{let y=(H-hs[i])/2;for(const b of col){b.col=i;b.x=colX[i]+(b.cw-b.w)/2;b.y=y;y+=b.h+BG;b.ids.forEach((id,k)=>pos.set(id,{x:b.x+12,y:b.y+36+k*46,w:b.w-24,h:38,b}));}});};
 const pos=new Map();place();
 const mean=ids=>{let s=0,n=0;for(const id of ids)for(const o of nb.get(id)||[]){const q=pos.get(o);if(q){s+=q.y;n++;}}return n?s/n:null;};
 for(let pass=0;pass<6;pass++){
  for(const col of cols){
   for(const b of col){const ky=new Map(b.ids.map((id,k)=>[id,mean([id])??(b.y+36+k*46)]));b.ids.sort((p,q)=>ky.get(p)-ky.get(q));}
   const ky=new Map(col.map(b=>[b,mean(b.ids)??b.y]));col.sort((p,q)=>ky.get(p)-ky.get(q));place();}}
 CL={links,cols,colX,boxes:cols.flat()};connRender();
 C.auto=true;connFit();connWire();}
let CL=null;
// links leave from the side facing the target and enter on the side facing the source. Between the
// two boxes, a link crosses each layout column through a free gap (between or around the boxes now
// standing in it, a few px apart per link) instead of over them. Boxes overlapping horizontally:
// both ends on the right, bulging out. Routing uses the current positions, so it follows drags.
function connRender(){const {links,cols,colX,boxes}=CL,pos=new Map();
 for(const b of boxes)b.ids.forEach((id,k)=>pos.set(id,{x:b.x+12,y:b.y+36+k*46,w:b.w-24,h:38,b}));
 const out=boxes.map(b=>`<g class="cbx" data-c="${esc(b.c)}"><title>Drag to move the component</title><rect x="${b.x}" y="${b.y}" width="${b.w}" height="${b.h}" rx="12"/><text class="cbt" x="${b.x+14}" y="${b.y+22}">▣ ${esc(b.c)}</text></g>`);
 const used=new Map(),colSpan=ci=>[colX[ci],colX[ci]+cols[ci][0].cw];
 const gapY=(ci,t)=>{const [c0,c1]=colSpan(ci),inCol=boxes.filter(b=>b.x<c1&&b.x+b.w>c0).sort((p,q)=>p.y-q.y),iv=[];let top=-1e9;
  for(const b of inCol){iv.push([top,b.y-12]);top=Math.max(top,b.y+b.h+12);}iv.push([top,1e9]);
  let best=null;for(const [lo,hi] of iv){if(hi-lo<8)continue;const y=Math.min(hi,Math.max(lo,t)),d=Math.abs(y-t);if(!best||d<best.d)best={y,d,lo,hi};}
  if(!best)return t;
  const u=used.get(ci)||used.set(ci,[]).get(ci);let y=best.y,k=0;
  while(u.some(v=>Math.abs(v-y)<7)&&k<40){k++;const s=Math.ceil(k/2)*7*(k%2?1:-1),c=best.y+s;if(c>=best.lo&&c<=best.hi)y=c;}
  u.push(y);return y;};
 const seg=(px,py,qx,qy)=>{const m=(qx-px)/2;return `C${px+m},${py} ${qx-m},${qy} ${qx},${qy}`;};
 const edges=[];
 for(const l of links){const a=pos.get(l.from),z=pos.get(l.to);if(!a||!z)continue;const ay=a.y+a.h/2,zy=z.y+z.h/2;let d;
  const A0=a.b.x,A1=a.b.x+a.b.w,Z0=z.b.x,Z1=z.b.x+z.b.w,dir=Z0>A1+20?1:Z1<A0-20?-1:0;
  if(dir){const x1=dir>0?A1:A0,x2=dir>0?Z0:Z1;
   d=`M${dir>0?a.x+a.w:a.x},${ay}L${x1},${ay}`;let px=x1,py=ay;
   const mid=[];for(let ci=0;ci<cols.length;ci++){const [c0,c1]=colSpan(ci);if(dir>0?(c0>=x1&&c1<=x2):(c0>=x2&&c1<=x1))mid.push(ci);}
   if(dir<0)mid.reverse();
   for(const ci of mid){const [c0,c1]=colSpan(ci),cx=(c0+c1)/2,t=ay+(zy-ay)*(cx-x1)/(x2-x1),wy=gapY(ci,t);
    const ex=dir>0?c0:c1,lx=dir>0?c1:c0;d+=seg(px,py,ex,wy)+`L${lx},${wy}`;px=lx;py=wy;}
   d+=seg(px,py,x2,zy)+`L${dir>0?z.x:z.x+z.w},${zy}`;}
  else{const x=Math.max(A1,Z1),o=50+Math.abs(zy-ay)*0.2;d=`M${a.x+a.w},${ay}L${x},${ay}C${x+o},${ay} ${x+o},${zy} ${x},${zy}L${z.x+z.w},${zy}`;}
  const A=N.get(l.from),Z=N.get(l.to),via=[...l.via].map(v=>N.get(v)?.label).filter(Boolean);
  const tip=`${compOf(A)}: ${A.label}\n${l.k==='http'?'calls over HTTP':'→ event '+via.join(', ')+' → handled by'}\n${compOf(Z)}: ${Z.label}${l.at.f?'\n'+l.at.f+':'+l.at.l:''}`;
  edges.push(`<path class="ce ${l.k}" data-s="${esc(l.from)}" data-d="${esc(l.to)}" d="${d}" marker-end="url(#ca-${l.k})"><title>${esc(tip)}</title></path>`);}
 const nodes=[];
 for(const [id,p] of pos){const n=N.get(id),[own,mem]=splitName(n),room=p.w-50;
  nodes.push(`<g class="cn${n.unres?' unr':''}" data-id="${esc(id)}" data-c="${esc(p.b.c)}" transform="translate(${p.x},${p.y})"><title>${esc(KIND[n.kind][1]+': '+n.label+(n.file?'\n'+n.file+':'+n.line:''))}</title>
   <path class="box s-${n.kind}" d="${shapeD(n.kind,p.w,p.h)}"/><text class="ki f-${n.kind}" x="${n.kind==='endpoint'?13:11}" y="${p.h/2+5}">${KIND[n.kind][0]}</text>
   <text class="gm" x="37" y="16">${esc(ell(mem||n.label,'gm',room))}</text><text class="gp" x="37" y="30">${esc(ell(connSub(n),'gp',room))}</text></g>`);}
 $('#cvp').innerHTML=out.join('')+edges.join('')+nodes.join('');}
function connSub(n){return n.kind==='endpoint'&&n.path?`${n.verb||'ANY'} ${n.path}`:(KIND[n.kind][1]+(splitName(n)[0]?' · '+splitName(n)[0]:''));}
function connFit(){const svg=$('#csvg'),vp=$('#cvp');if(!svg||!vp)return;const b=vp.getBBox(),W=svg.clientWidth||800,H=svg.clientHeight||500;
 const k=Math.min(1.1,W/(b.width+60),H/(b.height+60));C.t={k,x:W/2-(b.x+b.width/2)*k,y:H/2-(b.y+b.height/2)*k};connApply();}
function connApply(){const vp=$('#cvp');if(vp)vp.setAttribute('transform',`translate(${C.t.x},${C.t.y}) scale(${C.t.k})`);}
function connWire(){const svg=$('#csvg');let drag=null;
 new ResizeObserver(()=>{if(C.auto&&$('#csvg')===svg)connFit();}).observe(svg);
 svg.addEventListener('wheel',e=>{e.preventDefault();const r=svg.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top;
  const k=Math.min(3,Math.max(0.12,C.t.k*Math.exp(-e.deltaY*0.0015)));C.t.x=mx-(mx-C.t.x)*k/C.t.k;C.t.y=my-(my-C.t.y)*k/C.t.k;C.t.k=k;C.auto=false;connApply();},{passive:false});
 // drag a component (its box or any item in it) to move it, the background to pan
 svg.addEventListener('pointerdown',e=>{if(e.button)return;const g=e.target.closest('.cbx,.cn');
  if(g){const b=CL.boxes.find(b=>b.c===g.dataset.c);drag={box:b,x:e.clientX,y:e.clientY,bx:b.x,by:b.y,moved:false};return;}
  drag={x:e.clientX,y:e.clientY,tx:C.t.x,ty:C.t.y,moved:false};svg.classList.add('pan');svg.setPointerCapture(e.pointerId);});
 svg.addEventListener('pointermove',e=>{if(!drag)return;const dx=e.clientX-drag.x,dy=e.clientY-drag.y;
  if(!drag.moved&&Math.abs(dx)+Math.abs(dy)<=4)return;if(!drag.moved){drag.moved=true;C.auto=false;if(drag.box){svg.classList.add('moving');svg.setPointerCapture(e.pointerId);}}
  if(drag.box){drag.box.x=drag.bx+dx/C.t.k;drag.box.y=drag.by+dy/C.t.k;C.hl=null;$('#cvp').classList.remove('dim');connRender();return;}
  C.t.x=drag.tx+dx;C.t.y=drag.ty+dy;connApply();});
 const end=()=>{if(drag&&drag.moved){C.dragged=true;setTimeout(()=>C.dragged=false);}drag=null;svg.classList.remove('pan','moving');};
 svg.addEventListener('pointerup',end);svg.addEventListener('pointercancel',end);
 const vp=$('#cvp');
 svg.addEventListener('mouseover',e=>{if(svg.classList.contains('moving'))return;const g=e.target.closest('.cn');const id=g?g.dataset.id:null;if(id===C.hl)return;C.hl=id;
  vp.classList.toggle('dim',!!id);vp.querySelectorAll('.hl').forEach(x=>x.classList.remove('hl'));if(!id)return;g.classList.add('hl');
  vp.querySelectorAll('.ce').forEach(p=>{if(p.dataset.s===id||p.dataset.d===id){p.classList.add('hl');const o=p.dataset.s===id?p.dataset.d:p.dataset.s;vp.querySelector(`.cn[data-id="${CSS.escape(o)}"]`)?.classList.add('hl');}});});
 svg.addEventListener('click',e=>{if(C.dragged)return;const g=e.target.closest('.cn');if(!g)return;setView('graph');go(g.dataset.id);if(selected===g.dataset.id)select(selected);});}
document.addEventListener('keydown',e=>{if(view==='conn'&&$('#csvg')&&(e.key==='f'||e.key==='F')&&!/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName)){C.auto=true;connFit();}});
function drawIssues(){const ev=DATA.nodes.filter(n=>n.kind==='event');
 const noL=ev.filter(n=>!(OUT.get(n.id)||[]).length),noE=ev.filter(n=>!(IN.get(n.id)||[]).some(e=>e.k==='emits'));
 const deadEp=DATA.nodes.filter(n=>n.kind==='endpoint'&&!(OUT.get(n.id)||[]).length);
 const lst=a=>a.length?`<table>${a.map(n=>`<tr><td><span class="row">${ic(n)}<span class="nm${n.unres?' unr':''}" data-id="${esc(n.id)}">${nameHtml(n)}</span>${spTag(n)}</span></td><td>${n.file?link(n.file,n.abs,n.line):''}</td></tr>`).join('')}</table>`:'<div class="sub">none 🎉</div>';
 $('#detail').innerHTML=`<div class="title"><h2>Issues & blind spots</h2></div>
 <div class="section"><h3>Events emitted but never listened to (${noL.length})</h3>${lst(noL)}</div>
 <div class="section"><h3>Events listened to but never emitted (${noE.length})</h3><div class="help">Often emitted with a dynamic name — check "unresolved" below.</div>${lst(noE)}</div>
 <div class="section"><h3>Unresolved emissions / handlers (${DATA.unresolved.length})</h3><div class="help">Event name not statically known (variable) or handler not found. Add a pattern to the config, or check by hand.</div>
 ${DATA.unresolved.length?`<table>${DATA.unresolved.map(u=>`<tr><td>${link(u.file,absOf(u.file),u.line,u.file+':'+u.line)}</td><td><code>${esc(u.text)}</code></td></tr>`).join('')}</table>`:'<div class="sub">none 🎉</div>'}</div>
 <div class="section"><h3>Endpoints with no detected chain (${deadEp.length})</h3>${lst(deadEp)}</div>`;}
// ---------------------------------------------------------------- flows
// A flow is everything an entry point triggers. Entry points: endpoints (HTTP and addRoute), events
// listened to but never emitted in the scanned code (they come from outside), and every other item
// nothing in the scan leads to (methods a framework calls: consumers, timers, start()...).
$('#tFlows').onclick=()=>{setView('flows');flowSel&&N.has(flowSel)?drawFlow(flowSel):drawFlows();};
let FLOWS=null,flowSel=null,flowQ='',flowSort='steps',flowName='';
// what an item triggers: steps reached, longest chain, events, handlers, HTTP calls
function reachOf(id){const seen=new Set([id]),q=[[id,0]];const r={steps:0,depth:0,event:0,handler:0,http:0,cyc:false};
 for(let i=0;i<q.length;i++){const [c,d]=q[i];if(d>r.depth)r.depth=d;
  for(const e of OUT.get(c)||[]){if(!N.has(e.id))continue;if(e.k==='http')r.http++;if(e.id===id)r.cyc=true;
   if(seen.has(e.id))continue;seen.add(e.id);r.steps++;const k=N.get(e.id).kind;if(k==='event')r.event++;else if(k==='handler')r.handler++;q.push([e.id,d+1]);}}
 return r;}
const memberOf=n=>String(n.label||'').replace(/\(\)$/,'').split('.').pop();
function flows(){if(FLOWS)return FLOWS;const list=[];
 for(const n of DATA.nodes){const ins=IN.get(n.id)||[],outs=OUT.get(n.id)||[];let group=null;
  if(n.kind==='endpoint')group='endpoint';
  else if(n.kind==='event'){if(outs.length&&!ins.some(e=>e.k==='emits'))group='external';}
  else if(!ins.length&&outs.length)group='root';
  if(group)list.push({id:n.id,group,...reachOf(n.id)});}
 return FLOWS=list;}
const FGROUPS=[['endpoint','Endpoints','HTTP endpoints and routes registered with addRoute.'],
 ['external','Events from outside','Listened to, but nothing in the scanned code emits them: another service, a framework or a dynamic name (see Issues) fires them.'],
 ['root','Other starting points','Nothing in the scanned code calls these. Real entry points are among them (event bus consumers, timers, start(), framework callbacks), with dead code and calls the scan could not resolve.']];
function flowRow(f){const n=N.get(f.id);return `<tr data-flow="${esc(f.id)}"><td><span class="row">${ic(n)}<span class="fnm${n.unres?' unr':''}">${nameHtml(n)}</span>${spTag(n)}${cmpTag(n)}</span>${n.kind==='endpoint'&&n.path?`<div><code>${esc((n.verb||'')+' '+n.path)}</code></div>`:''}</td>
 <td class="num">${f.steps}</td><td class="num">${f.event}</td><td class="num">${f.handler}</td><td class="num">${f.http||''}</td><td class="num">${f.depth}${f.cyc?' <span class="cyc" title="Leads back to itself">↻</span>':''}</td><td>${n.file?link(n.file,n.abs,n.line):''}</td></tr>`;}
function drawFlows(){flowSel=null;const all=flows(),toks=flowQ.toLowerCase().split(/\s+/).filter(Boolean);
 const keep=f=>toks.every(t=>hay.get(f.id).includes(t))&&(!flowName||f.group!=='root'||memberOf(N.get(f.id))===flowName);
 const cmp=flowSort==='name'?(a,b)=>N.get(a.id).label.localeCompare(N.get(b.id).label):(a,b)=>b[flowSort]-a[flowSort]||N.get(a.id).label.localeCompare(N.get(b.id).label);
 // names shared by several starting points hint at a framework entry point (start, handle...)
 const names=new Map();for(const f of all)if(f.group==='root'){const m=memberOf(N.get(f.id));names.set(m,(names.get(m)||0)+1);}
 const common=[...names].filter(x=>x[1]>1).sort((a,b)=>b[1]-a[1]||a[0].localeCompare(b[0])).slice(0,30);
 const head='<tr><th>Entry point</th><th class="num" title="Items reached">Steps</th><th class="num">Events</th><th class="num">Handlers</th><th class="num" title="HTTP calls">HTTP</th><th class="num" title="Longest chain">Depth</th><th>Where</th></tr>';
 $('#detail').innerHTML=`<div class="title"><h2>Flows</h2><span class="sub">${all.length} entry points</span></div>
 <div class="help">A flow is everything an entry point triggers, followed through calls, events and HTTP. Pick one to see its whole lifecycle.</div>
 <div class="toolbar"><input id="fq" class="fin" placeholder="Filter entry points…" value="${esc(flowQ)}" autocomplete="off">
 <span class="sub">sort by</span><select id="fsort">${[['steps','steps'],['depth','depth'],['event','events'],['http','HTTP calls'],['name','name']].map(([v,t])=>`<option value="${v}" ${v===flowSort?'selected':''}>${t}</option>`).join('')}</select></div>
 ${FGROUPS.map(([g,title,help])=>{const rows=all.filter(f=>f.group===g&&keep(f)).sort(cmp),tot=all.filter(f=>f.group===g).length;
  const chips=g==='root'&&common.length?`<div class="fnames"><span class="sub">Common names:</span> ${common.map(([m,c])=>`<span class="chip${m===flowName?' on':''}" data-fname="${esc(m)}">${esc(m)} ×${c}</span>`).join('')}</div>`:'';
  return `<div class="section"><h3>${title} (${rows.length===tot?tot:rows.length+' of '+tot})</h3><div class="help">${help}</div>${chips}
  ${rows.length?`<table class="ftab">${head}${rows.slice(0,500).map(flowRow).join('')}</table>${rows.length>500?`<div class="sub">showing 500 of ${rows.length}: filter to narrow</div>`:''}`:'<div class="sub">none</div>'}</div>`;}).join('')}`;
 const fq=$('#fq');fq.oninput=()=>{flowQ=fq.value;const p=fq.selectionStart;drawFlows();const f2=$('#fq');f2.focus();f2.setSelectionRange(p,p);};
 $('#fsort').onchange=e=>{flowSort=e.target.value;drawFlows();};
 $('#detail').querySelectorAll('[data-fname]').forEach(c=>c.onclick=()=>{flowName=flowName===c.dataset.fname?'':c.dataset.fname;drawFlows();});
 $('#detail').querySelectorAll('tr[data-flow]').forEach(tr=>tr.onclick=e=>{if(!e.target.closest('.lnk'))drawFlow(tr.dataset.flow);});}
function drawFlow(id){flowSel=id;dir='fwd';const n=N.get(id),f=flows().find(x=>x.id===id)||{id,...reachOf(id)};
 // what the flow reaches, by kind
 const seen=new Set([id]),q=[id],got={};
 for(let i=0;i<q.length;i++)for(const e of OUT.get(q[i])||[]){if(seen.has(e.id)||!N.has(e.id))continue;seen.add(e.id);q.push(e.id);const m=N.get(e.id);(got[m.kind]||(got[m.kind]=[])).push(m);}
 const reached=['event','endpoint','handler','lambda'].filter(k=>got[k]).map(k=>`<div class="section"><h3>${KIND[k][1]}s reached (${got[k].length})</h3><div class="freach">${got[k].sort((a,b)=>a.label.localeCompare(b.label)).map(m=>`<span class="row">${ic(m)}<span class="nm${m.unres?' unr':''}" data-id="${esc(m.id)}">${nameHtml(m)}</span>${seenTag(m)}</span>`).join('')}</div></div>`).join('');
 $('#detail').innerHTML=`<div class="toolbar" style="margin-top:0"><button class="btn" id="fback">◀ All entry points</button></div>
 <div class="title">${ic(n)}<h2>${nameHtml(n)}</h2><span class="badge k-${n.kind}">${KIND[n.kind][1]}</span>${unrTag(n)}${spTag(n)}${cmpTag(n)}</div>
 <div class="loc">${n.kind==='endpoint'&&n.path?`<code>${esc((n.verb||'')+' '+n.path)}</code> · `:''}${n.file?link(n.file,n.abs,n.line,n.file+':'+n.line):''}${n.cls?` <span class="sub">· ${esc(n.cls)}</span>`:''}</div>
 <div class="fstats"><span><b>${f.steps}</b> steps</span><span><b>${f.event}</b> events</span><span><b>${f.handler}</b> handlers</span><span><b>${f.http}</b> HTTP calls</span><span>longest chain <b>${f.depth}</b></span>${f.cyc?'<span class="cyc">↻ leads back to itself</span>':''}</div>
 <div class="toolbar"><span class="sub">depth</span><select id="depth">${[2,3,4,6,8,12,20].map(d=>`<option ${d===maxDepth?'selected':''}>${d}</option>`).join('')}</select>
 <button class="btn" id="expand">Expand all</button><button class="btn" id="collapse">Collapse</button><button class="btn" id="copy">Copy as text</button>
 <button class="btn" id="fgraph">Show in graph</button><label class="sub"><input type="checkbox" id="hideCalls"> events only</label></div>
 <div class="help">The lifecycle, step by step: every path the code allows (all branches, every implementation of an interface).</div>
 <ul class="tree" id="tree"></ul>${reached}`;
 $('#fback').onclick=drawFlows;
 const tree=()=>{const t=$('#tree');t.innerHTML='';fill(t,id,0,new Set([id]));if(!t.children.length)t.innerHTML='<li class="sub">It triggers nothing the scan could follow.</li>';
  // open the first levels so the lifecycle reads at a glance (a level's children are built when it opens)
  const openLv=(ul,lv)=>{if(!ul||!lv)return;const ds=[...ul.querySelectorAll(':scope>li>details')];ds.forEach(d=>d.open=true);
   setTimeout(()=>ds.forEach(d=>openLv(d.querySelector(':scope>ul'),lv-1)),0);};
  openLv(t,3);};
 $('#depth').onchange=e=>{maxDepth=+e.target.value;tree();};
 $('#expand').onclick=()=>expandAll($('#tree'),0);$('#collapse').onclick=tree;$('#hideCalls').onchange=tree;
 $('#copy').onclick=()=>{navigator.clipboard.writeText(asText(id));$('#copy').textContent='Copied ✓';setTimeout(()=>$('#copy').textContent='Copy as text',1200);};
 $('#fgraph').onclick=()=>{setView('graph');go(id);if(selected===id)select(id);};
 tree();$('#detail').scrollTop=0;}
// ---------------------------------------------------------------- logs
// What the log files show, reduced by the script to counts: hops on the event bus (request ">>"
// and reply "<<" under one tag), message patterns of the levels in LOG_PATTERN_LEVELS, LOG_RULES.
if(HASLOGS)$('#tLogs').hidden=false;
$('#tLogs').onclick=()=>{setView('logs');drawLogs();};
let logQ='',logSort='n';
const EVBYVAL=new Map();for(const n of DATA.nodes)if(n.kind==='event'&&n.value!=null&&!n.unres&&!EVBYVAL.has(n.value))EVBYVAL.set(n.value,n);
// the event of a hop (by address) and its handler in the receiver class, if the map has them
function hopMap(h){const ev=EVBYVAL.get(h.a);if(!ev)return{ev:null,hd:null};
 const hd=(OUT.get(ev.id)||[]).map(e=>N.get(e.id)).find(m=>m&&simpleCls(m.cls)===h.to)||null;return{ev,hd};}
function logLoc(i,l){const f=HASLOGS&&LOGS.files[i-1];return f?`<span class="lnk" title="${esc(f.file)}:${l}">${wb(f.file.split('/').pop()+':'+l)}</span>`:'';}
const fmtMs=v=>v<1000?Math.round(v)+' ms':(v/1000).toFixed(v<10000?2:1)+' s';
function drawLogs(){const L=LOGS,mb=L.files.reduce((a,f)=>a+f.bytes,0)/1048576;
 const toks=logQ.toLowerCase().split(/\s+/).filter(Boolean);
 const hops=L.hops.filter(h=>toks.every(t=>(h.a+' '+h.from+' '+h.to).toLowerCase().includes(t)));
 const key={n:h=>h.n,err:h=>h.err+h.noReply,avg:h=>h.msN?h.ms/h.msN:0,max:h=>h.max}[logSort];
 hops.sort(key?(a,b)=>key(b)-key(a)||a.a.localeCompare(b.a):(a,b)=>a.a.localeCompare(b.a)||a.to.localeCompare(b.to));
 const never=[...EVBYVAL.values()].filter(n=>!HOPA.has(n.value)).sort((a,b)=>a.label.localeCompare(b.label));
 const outside=new Set(L.hops.filter(h=>!EVBYVAL.has(h.a)).map(h=>h.a));
 const hopRow=h=>{const {ev,hd}=hopMap(h),st=Object.entries(h.st).map(([s,c])=>`<span class="st${/^2/.test(s)?'':' bad'}" title="${fmtN(c)} replies with status ${esc(s)}">${esc(s)}${Object.keys(h.st).length>1?' ×'+fmtN(c):''}</span>`).join(' ');
  return `<tr><td>${ev?`<span class="row">${ic(ev)}<span class="nm" data-id="${esc(ev.id)}"><code>${esc(h.a)}</code></span></span>${ev.label!=='"'+h.a+'"'?`<div class="sub">${esc(ev.label)}</div>`:''}`
   :`<code>${esc(h.a)}</code> <span class="badge nmap" title="No event in the scanned code has this value">not in map</span>`}</td>
  <td><span class="sub">${esc(h.from||'?')} →</span> ${hd?`<span class="nm" data-id="${esc(hd.id)}">${esc(h.to)}</span>`:esc(h.to)}${ev&&!hd?' <span class="badge nmap" title="The map has no handler of this event in that class">no handler in map</span>':''}</td>
  <td class="num">${fmtN(h.n)}</td><td>${st}</td><td class="num">${h.msN?fmtMs(h.ms/h.msN):''}</td><td class="num">${h.msN?fmtMs(h.max):''}</td>
  <td class="num${h.err?' bad':''}">${h.err?`<span title="First at ${esc(h.errFile?L.files[h.errFile-1].file+':'+h.errLine:'')}">${fmtN(h.err)}</span>`:''}</td><td class="num${h.noReply?' bad':''}">${h.noReply?fmtN(h.noReply):''}</td>
  <td>${logLoc(h.file,h.line)}<div class="sub">${esc(h.t1)}${h.t2!==h.t1?' → '+esc(h.t2):''}</div></td></tr>`;};
 const pats=L.patterns.slice().sort((a,b)=>b.n-a.n);
 const lvls=Object.entries(L.levels).sort((a,b)=>b[1]-a[1]);
 $('#detail').innerHTML=`<div class="title"><h2>Logs</h2><span class="sub">${L.files.length} file${L.files.length>1?'s':''} · ${mb<10?mb.toFixed(1):Math.round(mb)} MB · ${fmtN(L.lines)} lines · ${fmtN(L.records)} records${L.first?` · ${esc(L.first)} → ${esc(L.last)}`:''}</span></div>
 <div class="fstats">${lvls.map(([l,c])=>`<span class="lvl lv-${esc(l)}"><b>${fmtN(c)}</b> ${esc(l)}</span>`).join('')}${Object.entries(L.tags).map(([t,c])=>`<span title="Lines with a [${esc(t)}-…] tag"><b>${fmtN(c)}</b> [${esc(t)}]</span>`).join('')}</div>
 <details class="lfiles"><summary class="sub">Files read</summary><table>${L.files.map(f=>`<tr><td><code>${esc(f.file)}</code></td><td class="num">${fmtN(f.lines)} lines</td><td class="num">${(f.bytes/1048576).toFixed(1)} MB</td></tr>`).join('')}</table></details>
 <div class="section"><h3>Hops on the event bus (${hops.length===L.hops.length?fmtN(L.hops.length):fmtN(hops.length)+' of '+fmtN(L.hops.length)})</h3>
 <div class="help">One row per address and sender → receiver: how many requests, their replies, how long they took. Addresses are joined to the map's events by value, receivers to handler classes.</div>
 ${L.hops.length?`<div class="toolbar"><input id="lq" class="fin" placeholder="Filter address, sender, receiver…" value="${esc(logQ)}" autocomplete="off">
 <span class="sub">sort by</span><select id="lsort">${[['n','calls'],['err','errors'],['avg','average time'],['max','max time'],['a','address']].map(([v,t])=>`<option value="${v}" ${v===logSort?'selected':''}>${t}</option>`).join('')}</select></div>
 <table class="ltab"><tr><th>Address</th><th>Sender → receiver</th><th class="num">Calls</th><th>Replies</th><th class="num">Avg</th><th class="num">Max</th><th class="num">Errors</th><th class="num" title="Requests with no reply in the logs">No reply</th><th>First seen</th></tr>
 ${hops.slice(0,500).map(hopRow).join('')}</table>${hops.length>500?`<div class="sub">showing 500 of ${fmtN(hops.length)}: filter to narrow</div>`:''}
 ${L.orphans?`<div class="help">${fmtN(L.orphans)} replies had no request in the logs read (it was in an older file).</div>`:''}`
 :'<div class="sub">No hop found. If the logs have some, check LOG_IDS, LOG_REQUEST and LOG_REPLY in the CONFIG of the script.</div>'}</div>
 ${L.hops.length?lifeHtml(L):''}
 ${L.hops.length?`<div class="section"><h3>Events never seen in the logs (${never.length})</h3><div class="help">No hop in the logs read has their value as address. Unused, or not used during the period the logs cover.</div>
 ${never.length?`<table>${never.map(n=>`<tr><td><span class="row">${ic(n)}<span class="nm" data-id="${esc(n.id)}">${nameHtml(n)}</span></span></td><td><code>${esc(n.value)}</code></td><td>${n.file?link(n.file,n.abs,n.line):''}</td></tr>`).join('')}</table>`:'<div class="sub">none</div>'}</div>
 <div class="section"><h3>Addresses not in the map (${outside.size})</h3><div class="help">Seen in the logs, but no event in the scanned code has this value: built at run time, from another service, or missed by the scan.</div>
 ${outside.size?`<div class="freach">${[...outside].sort().map(a=>`<code>${esc(a)}</code>`).join('')}</div>`:'<div class="sub">none</div>'}</div>`:''}
 <div class="section"><h3>Messages (${fmtN(pats.length)} patterns)</h3><div class="help">Messages of the levels in LOG_PATTERN_LEVELS, grouped: numbers, ids and quoted text become placeholders.</div>
 ${pats.length?`<table class="ltab"><tr><th>Level</th><th>Message</th><th class="num">Count</th><th>First seen</th></tr>${pats.slice(0,300).map(p=>`<tr><td><span class="lvl lv-${esc(p.level)}">${esc(p.level)}</span></td><td><code title="${esc(p.ex)}">${esc(p.text)}</code>${p.exc?`<div class="sub">${esc(p.exc)}</div>`:''}</td><td class="num">${fmtN(p.n)}</td><td>${logLoc(p.file,p.line)}</td></tr>`).join('')}</table>
 ${pats.length>300?`<div class="sub">showing the 300 most frequent</div>`:''}${L.patOver?`<div class="sub">${fmtN(L.patOver)} more records had too many different messages to keep</div>`:''}`:'<div class="sub">none</div>'}</div>
 <div class="section"><h3>Rules (${L.rules.length})</h3><div class="help">LOG_RULES in the CONFIG of the script.</div>
 ${L.rules.length?`<table class="ltab"><tr><th>Rule</th><th class="num">Count</th><th>Example</th></tr>${L.rules.map(r=>`<tr><td><b>${esc(r.name)}</b><div class="sub"><code>${esc(r.re)}</code></div></td><td class="num">${fmtN(r.n)}</td><td>${r.n?`<code>${esc(r.ex)}</code><div>${logLoc(r.file,r.line)}</div>`:''}</td></tr>`).join('')}</table>`:'<div class="sub">none</div>'}</div>`;
 const lq=$('#lq');if(lq){lq.oninput=()=>{logQ=lq.value;const p=lq.selectionStart;drawLogs();const l2=$('#lq');l2.focus();l2.setSelectionRange(p,p);};
  $('#lsort').onchange=e=>{logSort=e.target.value;drawLogs();};}
 const lt=$('#lthr');if(lt)lt.onchange=e=>{lifeThr=+e.target.value;const y=$('#detail').scrollTop;drawLogs();$('#detail').scrollTop=y;};}
// ---- observed lifecycles: hops linked by timing (see LOG_LINK_WINDOW). A link A -> B means "B was
// sent by A's receiver while A waited for its reply"; its strength is the share of A's runs that
// had it. Only links at least as strong as the threshold are drawn.
let lifeThr=0.5;
const CODEP=new Map();
// does the code lead from the handler of hop p to the event of hop c?  true / false / null (unknown)
function inCode(p,c){const k=p.a+'\u0001'+p.to+'\u0001'+c.a;if(CODEP.has(k))return CODEP.get(k);
 const ev=EVBYVAL.get(p.a),target=EVBYVAL.get(c.a);let r=null;
 if(ev&&target){const start=(OUT.get(ev.id)||[]).map(e=>e.id).filter(id=>{const m=N.get(id);return m&&simpleCls(m.cls)===p.to;});
  if(start.length){r=false;const seen=new Set(start),q=[...start];
   for(let i=0;i<q.length&&i<5000&&!r;i++)for(const e of OUT.get(q[i])||[]){if(e.id===target.id){r=true;break;}
    if(!seen.has(e.id)&&N.get(e.id)?.kind!=='event'){seen.add(e.id);q.push(e.id);}}}}
 CODEP.set(k,r);return r;}
function lifeHtml(L){const H=L.hops,kids=new Map(),strong=new Set();
 for(const l of L.links){const p=H[l.p-1],c=H[l.c-1];if(!p||!c)continue;const r=l.n/p.n;
  if(r>=lifeThr){(kids.get(l.p)||kids.set(l.p,[]).get(l.p)).push({i:l.c,n:l.n,r});strong.add(l.c);}}
 for(const v of kids.values())v.sort((a,b)=>b.n-a.n);
 // starts: hops with strong children that are rarely children themselves
 const roots=[...kids.keys()].filter(i=>{const h=H[i-1];return h.par/h.n<0.5||!strong.has(i);}).sort((a,b)=>H[b-1].n-H[a-1].n);
 const hopLine=(h,extra)=>{const {ev}=hopMap(h);return `<span class="row lrow">${ev?`${ic(ev)}<span class="nm" data-id="${esc(ev.id)}"><code>${esc(h.a)}</code></span>`:`<code>${esc(h.a)}</code>`}
  <span class="sub">${esc(h.from||'?')} → ${esc(h.to)}</span><span class="seen${h.err||h.noReply?' serr':''}" title="${fmtN(h.n)} calls${h.err?' · '+fmtN(h.err)+' errors':''}">×${fmtN(h.n)}</span>${h.msN?`<span class="sub">${fmtMs(h.ms/h.msN)}</span>`:''}${extra||''}</span>`;};
 const codeTag=(p,c)=>{const x=inCode(p,c);return x===true?'<span class="cin" title="The code leads from this handler to that event">in code ✓</span>'
  :x===false?'<span class="cout" title="No path in the scanned code from the receiver\'s handler to that event: a call the scan misses, or a coincidence in timing">not in code</span>':'';};
 let budget=1500;
 const node=(i,path)=>{const ch=kids.get(i)||[];let out='';
  for(const k of ch){if(budget--<=0)break;const p=H[i-1],c=H[k.i-1];
   const extra=` <span class="lpct" title="${fmtN(k.n)} of the ${fmtN(p.n)} runs of the parent">${Math.round(k.r*100)}%</span>${codeTag(p,c)}${c.amb?` <span class="sub" title="${fmtN(c.amb)} times another hop of the same receiver was waiting too">· ${fmtN(c.amb)} unsure</span>`:''}`;
   if(path.has(k.i)){out+=`<li class="leaf">${hopLine(c,extra)} <span class="cyc">↻ cycle</span></li>`;continue;}
   const sub=kids.has(k.i)?node(k.i,new Set([...path,k.i])):'';
   out+=sub?`<li><details open><summary>${hopLine(c,extra)}</summary><ul>${sub}</ul></details></li>`:`<li class="leaf">${hopLine(c,extra)}</li>`;}
  return out;};
 const body=roots.length?`<ul class="tree">${roots.slice(0,100).map(i=>`<li><details${roots.length<=10?' open':''}><summary>${hopLine(H[i-1])}</summary><ul>${node(i,new Set([i]))}</ul></details></li>`).join('')}</ul>${roots.length>100?`<div class="sub">showing the 100 busiest of ${roots.length}</div>`:''}`
  :`<div class="sub">${L.links.length?'No link this strong: lower the threshold.':'No hop was sent while another one was waiting for its reply.'}</div>`;
 return `<div class="section"><h3>Observed lifecycles</h3>
 <div class="help">Hops chained by timing: a hop is the child of the latest hop its sender received and has not replied to yet. The % is how often the parent was followed by it; <b>in code ✓</b> / <b>not in code</b> compares with the map.</div>
 <div class="toolbar"><span class="sub">links followed in at least</span><select id="lthr">${[[0.9,'90%'],[0.5,'50%'],[0.2,'20%'],[0.05,'5%'],[0,'any']].map(([v,t])=>`<option value="${v}" ${v===lifeThr?'selected':''}>${t}</option>`).join('')}</select><span class="sub">of the parent's runs · ${fmtN(L.links.length)} links in all</span></div>${body}</div>`;}
renderList();fromHash();
</script></body></html>
EOF_HTML_TAIL
}
{ html_head; cat "$TMP/graph.json"; printf ';\nconst LOGS='; cat "$TMP/logs.json"; html_tail; } > "$OUT"
if [ -n "$JSON_OUT" ]; then cp "$TMP/graph.json" "$JSON_OUT"; fi
echo "Done. Open $OUT in a browser." >&2
