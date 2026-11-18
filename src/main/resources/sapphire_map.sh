#!/usr/bin/env bash
# =============================================================================
#  sapphire_map.sh - Map asynchronous event call chains in a Java codebase and
#  produce ONE self-contained, interactive HTML page (the "Bible").
#
#  Needs only: bash, find, awk  (Linux, macOS, WSL, Git Bash on Windows).
#
#  Usage:
#     ./sapphire_map.sh /path/to/repo                    -> ./sapphire-map.html
#     ./sapphire_map.sh /path/to/repo out.html           -> out.html
#     ./sapphire_map.sh /path/to/repo out.html graph.json  (+ raw graph data)
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
#
#  It is a heuristic (tokenizer + brace matching), not a compiler.
# =============================================================================

# ============================== CONFIG =======================================
# Edit these lists to match Sapphire's API. Space-separated names.

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

# Annotations whose first string is a URL path (class-level = prefix).
PATH_ANNOTATIONS="RequestMapping Path"

# When a listener is registered as an object (subscribe("x", new Foo()) or
# subscribe("x", this)), methods with these names are taken as the callback.
CALLBACK_METHODS="handle onEvent on accept apply call run execute process notify"

# Folder names skipped anywhere in the tree.
EXCLUDE_DIRS="test tests build target out generated .git node_modules"

# How file:line links open. Placeholders: {abs_path} {rel_path} {line}
#   VS Code : vscode://file/{abs_path}:{line}
#   IntelliJ: idea://open?file={abs_path}&line={line}
#   GitLab  : https://gitlab.example.com/group/repo/-/blob/main/{rel_path}#L{line}
LINK_TEMPLATE="vscode://file/{abs_path}:{line}"

# 1 = follow plain method calls so chains connect; 0 = events only.
FOLLOW_CALLS=1
# ============================ END CONFIG =====================================

set -eu

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

ROOT="${1:-}"
OUT="${2:-sapphire-map.html}"
JSON_OUT="${3:-}"
if [ -z "$ROOT" ] || [ "$ROOT" = "-h" ] || [ "$ROOT" = "--help" ]; then usage; exit 0; fi
if [ ! -d "$ROOT" ]; then echo "Not a directory: $ROOT" >&2; exit 1; fi

AWK_BIN="${AWK:-}"
if [ -z "$AWK_BIN" ]; then
  for a in gawk mawk nawk awk; do
    if command -v "$a" >/dev/null 2>&1; then AWK_BIN="$a"; break; fi
  done
fi
if [ -z "$AWK_BIN" ]; then echo "No awk found." >&2; exit 1; fi

ROOT_ABS="$(cd "$ROOT" && pwd -P)"
ROOT_LINK="$ROOT_ABS"
if command -v cygpath >/dev/null 2>&1; then ROOT_LINK="$(cygpath -m "$ROOT_ABS")"; fi

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t sapmap)"
trap 'rm -rf "$TMP"' EXIT

# ---- list Java files ---------------------------------------------------------
PRUNE=()
for d in $EXCLUDE_DIRS; do
  if [ ${#PRUNE[@]} -eq 0 ]; then PRUNE=(-name "$d"); else PRUNE+=(-o -name "$d"); fi
done
if [ ${#PRUNE[@]} -gt 0 ]; then
  (cd "$ROOT_ABS" && find . -type d \( "${PRUNE[@]}" \) -prune -o -type f -name '*.java' -print) > "$TMP/files.txt"
else
  (cd "$ROOT_ABS" && find . -type f -name '*.java' -print) > "$TMP/files.txt"
fi
echo "Scanning $(wc -l < "$TMP/files.txt" | tr -d ' ') Java files with $AWK_BIN ..." >&2

# ---- the analyser (awk) ------------------------------------------------------
read -r -d '' AWK_PROG <<'EOF_AWK' || true
# sapphire_map analyser - portable POSIX awk (gawk, mawk, BSD/macOS awk, busybox)
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
  split("", pendLam); split("", exprEnd); split("", exprId); split("", anonL)
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

function fieldCheck(i,   fq, nm, j, ad, s, hasS, hasF) {
  fq = ctxFq[depth]; if (fq == "") return
  nm = T[i - 1]; if (K[i - 1] != "i" || (nm in CTRL)) return
  j = i - 2
  if (T[i] == "=" && T[j] == "String" && K[i + 1] == "s" && T[i + 2] == ";") {
    hasS = 0; hasF = 0
    for (s = j - 1; s > 0 && T[s] != ";" && T[s] != "{" && T[s] != "}"; s--) { if (T[s] == "static") hasS = 1; if (T[s] == "final") hasF = 1 }
    if ((hasS && hasF) || tKind[fq] == "interface") { if (!(nm in CONST)) CONST[nm] = T[i + 1]; CONST[tSimple[fq] "." nm] = T[i + 1] }
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
    else if (inBody) addUnres(rel, L[i], sc, LN[L[i]])
  }
  else if ((t in LISTEN) && sc != "") {
    r = parseEv(i + 2, 1)
    if (r != "") {
      j = evEnd + 2
      n = addListener(r, "site", sc, rel, L[i], fq, sc)
      q = j
      while (q < ce && (K[q] == "i" || T[q] == ".")) q++
      if (T[q] == "::" && K[q + 1] == "i" && q > j) { Lkind[n] = "ref"; Ltarget[n] = T[q - 1] LS T[q + 1] }
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
  if (FOLLOW && inBody && t ~ /^[a-z_]/ && !(t in CTRL) && !(t in EMIT) && !(t in LISTEN)) {
    recv = ""
    if (prev == ".") { if (K[pi - 1] == "i" && T[pi - 2] != ".") recv = T[pi - 1]; else return }
    nCalls++; Cscope[nCalls] = sc; Cfq[nCalls] = fq; Crecv[nCalls] = recv; Cname[nCalls] = t; Cfile[nCalls] = rel; Cline[nCalls] = L[i]
  }
}

# ------------------------------------------------------------- resolution ---
function normEv(r,   ch, n, parts, k, key, m) {
  if (substr(r, 1, 2) == "S:") return substr(r, 3)
  ch = substr(r, 3); sub(/\.class$/, "", ch)
  n = split(ch, parts, ".")
  for (k = 1; k <= n; k++) {
    key = parts[k]; for (m = k + 1; m <= n; m++) key = key "." parts[m]
    if (key in CONST) return CONST[key]
  }
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
function addEvent(nm,   id) { id = "event:" nm; addNode(id, "event", nm, "", "", ""); return id }
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
function addEdge(s, d, k, f, l) { E[s SUBSEP d SUBSEP k SUBSEP f SUBSEP l] = 1 }
function scopeLabel(sid) {
  if (sid in mFile) return tQual[mFq[sid]] "." mName[sid] "()"
  if (substr(sid, 1, 6) == "class:") return (substr(sid, 7) in tQual) ? tQual[substr(sid, 7)] : substr(sid, 7)
  return sid
}

function resolveAndWrite(   m, n, x, nn, arr, eid, kind, tg, targets, pr, left, right, ft, list, t2, c, recv, nm, cls,
                            key, ep, s, d, qh, qt, cur, id, first, roles, rr, nr, i, lid, kk) {
  # lambdas
  for (i = 1; i <= nLam; i++) {
    lid = lamOrd[i]
    addNode(lid, "lambda", "\316\273 in " scopeLabel(lamParent[lid]) " (L" lamLine[lid] ")", lamFq[lid], lamFile[lid], lamLine[lid])
  }
  # endpoints
  for (m in mFile) if (index(mRoles[m], "endpoint")) addMethodNode(m)
  # listeners
  for (n = 1; n <= nLs; n++) {
    eid = addEvent(normEv(Lev[n])); kind = Lkind[n]; tg = Ltarget[n]; targets = ""
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
      if (targets == "") addUnres(Lfile[n], Lline[n], Lscope[n], "listener handler not found: " left "::" right)
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
      if (targets == "") targets = nodeForScope(Lscope[n])
    }
    else targets = nodeForScope(Lscope[n])
    nn = split(targets, arr, LS)
    for (x = 1; x <= nn; x++) {
      t2 = arr[x]; if (t2 == "") continue
      if (t2 in mFile) { addRole(t2, "handler"); addMethodNode(t2) }
      addEdge(eid, t2, "handled_by", Lfile[n], Lline[n])
    }
  }
  # emissions
  for (n = 1; n <= nEm; n++) {
    eid = addEvent(normEv(Eev[n]))
    addEdge(nodeForScope(Escope[n]), eid, "emits", Efile[n], Eline[n])
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

  # prune: keep events, endpoints, handlers, lambdas, and anything leading to an event
  for (key in E) {
    split(key, ep, SUBSEP); s = ep[1]; d = ep[2]
    if (d in REV) REV[d] = REV[d] LS s; else REV[d] = s
    if (ep[3] == "handled_by") KEEP[d] = 1
  }
  for (id in NK) if (NK[id] == "event" || NK[id] == "lambda" || ((id in mFile) && mRoles[id] != "")) KEEP[id] = 1
  qh = 1; qt = 0
  for (id in NK) if (NK[id] == "event") { Q[++qt] = id; REACH[id] = 1 }
  while (qh <= qt) {
    cur = Q[qh++]
    if (cur in REV) {
      nn = split(REV[cur], arr, LS)
      for (x = 1; x <= nn; x++) if (!(arr[x] in REACH)) { REACH[arr[x]] = 1; Q[++qt] = arr[x] }
    }
  }
  for (id in REACH) KEEP[id] = 1
  for (id in KEEP) if (!(id in NK)) nodeForScope(id)

  # ---- write JSON ----
  printf "{\"meta\":{\"root\":\"%s\",\"generated\":\"%s\",\"files\":%d,\"link_template\":\"%s\"},", jesc(root), jesc(generated), nFiles, jesc(link_template) > outfile
  printf "\"edges\":[" > outfile
  first = 1; nEdges = 0
  for (key in E) {
    split(key, ep, SUBSEP)
    if (!((ep[1] in KEEP) && (ep[2] in KEEP) && (ep[1] in NK) && (ep[2] in NK))) continue
    USED[ep[1]] = 1; USED[ep[2]] = 1
    printf "%s[\"%s\",\"%s\",\"%s\",\"%s\",%d]", (first ? "" : ","), jesc(ep[1]), jesc(ep[2]), ep[3], jesc(ep[4]), ep[5] > outfile
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
    if (!((id in USED) || kind == "event" || kind == "endpoint")) continue
    CNT[kind]++
    printf "%s{\"id\":\"%s\",\"kind\":\"%s\",\"label\":\"%s\",\"cls\":\"%s\",\"file\":%s,\"abs\":%s,\"line\":%s,\"roles\":[%s],\"path\":%s,\"verb\":%s}", \
      (first ? "" : ","), jesc(id), kind, jesc(NL[id]), jesc(NC[id]), \
      (NFL[id] == "" ? "null" : "\"" jesc(NFL[id]) "\""), \
      (NFL[id] == "" ? "null" : "\"" jesc(root "/" NFL[id]) "\""), \
      (NLn[id] == "" ? "null" : NLn[id]), roles, \
      ((id in mPath) ? "\"" jesc(mPath[id]) "\"" : "null"), \
      (((id in mVerb) && mVerb[id] != "") ? "\"" mVerb[id] "\"" : "null") > outfile
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
  -v generated="$(date '+%Y-%m-%dT%H:%M:%S')" -v link_template="$LINK_TEMPLATE" \
  -v emit_methods="$EMIT_METHODS" -v listen_methods="$LISTEN_METHODS" \
  -v listen_ann="$LISTEN_ANNOTATIONS" -v ev_keys="$EVENT_ANNOTATION_KEYS" \
  -v endpoint_ann="$ENDPOINT_ANNOTATIONS" -v path_ann="$PATH_ANNOTATIONS" \
  -v callback_methods="$CALLBACK_METHODS" -v follow_calls="$FOLLOW_CALLS" \
  "$AWK_PROG")

# ---- assemble the HTML ---------------------------------------------------------
html_head() {
cat <<'EOF_HTML_HEAD'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sapphire event map</title>
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
.navtabs{display:flex;gap:4px;padding:0 10px 8px}
.navtabs button,.btn{font:inherit;font-size:12px;border:1px solid var(--line);background:var(--bg);color:var(--ink);border-radius:6px;padding:4px 10px;cursor:pointer}
.navtabs button.on,.btn.on{background:var(--acc);color:#fff;border-color:var(--acc)}
#count{color:var(--mute);font-size:12px;padding:0 12px 6px}
#results{list-style:none;margin:0;padding:0 6px 10px;overflow:auto;flex:1}
#results li{padding:6px 8px;border-radius:6px;cursor:pointer;display:flex;gap:8px;align-items:flex-start}
#results li:hover{background:var(--hi)}#results li.sel{background:var(--hi);outline:1px solid var(--acc)}
.ic{width:20px;flex:none;text-align:center;font-weight:700}
.k-endpoint{color:var(--ep)}.k-event{color:var(--ev)}.k-handler{color:var(--hd)}.k-method{color:var(--me)}.k-lambda{color:var(--la)}.k-class{color:var(--cl)}
.sub{color:var(--mute);font-size:12px;word-break:break-all}
#detail{overflow:auto;padding:18px 24px}
.empty{color:var(--mute);margin-top:40px;text-align:center}
.title{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.title h2{margin:0;font-size:19px;word-break:break-all}
.badge{font-size:11px;border-radius:4px;padding:1px 7px;border:1px solid currentColor}
.loc a,.lnk{color:var(--acc);text-decoration:none;font-size:12px}.loc a:hover,.lnk:hover{text-decoration:underline}
.toolbar{display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin:16px 0 10px}
.toolbar select{font:inherit;font-size:12px;padding:3px;border-radius:6px;border:1px solid var(--line);background:var(--bg);color:var(--ink)}
.tree,.tree ul{list-style:none;margin:0;padding-left:18px}.tree{padding-left:0}
.tree li{margin:2px 0}.tree summary{cursor:pointer;list-style:none}.tree summary::-webkit-details-marker{display:none}
.tree summary:before{content:'▸';display:inline-block;width:14px;color:var(--mute)}.tree details[open]>summary:before{content:'▾'}
.leaf{padding-left:14px}
.row{display:inline-flex;gap:6px;align-items:baseline;flex-wrap:wrap}
.elabel{font-size:11px;color:var(--mute);min-width:70px}
.nm{cursor:pointer;font-weight:500}.nm:hover{text-decoration:underline}
.cyc{color:var(--warn);font-size:12px}
.section h3{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--mute);margin:20px 0 6px}
table{border-collapse:collapse;width:100%;font-size:13px}td,th{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line);vertical-align:top}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--bg);padding:1px 4px;border-radius:4px;word-break:break-all}
.help{color:var(--mute);font-size:12px;margin-top:4px}
#gwrap{position:relative;border:1px solid var(--line);border-radius:10px;background:var(--bg);height:calc(100vh - 230px);min-height:420px;overflow:hidden;margin-top:8px}
#gsvg{width:100%;height:100%;display:block;cursor:grab;user-select:none;touch-action:none}#gsvg.pan{cursor:grabbing}
.gn{cursor:pointer}.gn .box{fill:var(--panel);stroke-width:1.5}.gn:hover .box{fill:var(--hi)}.gn.ctr .box{stroke-width:3;fill:var(--hi)}
.gn text{fill:var(--ink);font-size:12px}.gn text.gs{fill:var(--mute);font-size:10.5px}.gn text.ki{font-size:14px;font-weight:700}
.s-endpoint{stroke:var(--ep)}.s-event{stroke:var(--ev)}.s-handler{stroke:var(--hd)}.s-method{stroke:var(--me)}.s-lambda{stroke:var(--la)}.s-class{stroke:var(--cl)}
.gn text.f-endpoint{fill:var(--ep)}.gn text.f-event{fill:var(--ev)}.gn text.f-handler{fill:var(--hd)}.gn text.f-method{fill:var(--me)}.gn text.f-lambda{fill:var(--la)}.gn text.f-class{fill:var(--cl)}
.gb rect{fill:var(--bg);stroke:var(--mute)}.gn .gb text{font-size:11px;font-weight:700;text-anchor:middle}.gn:hover .gb rect{stroke:var(--acc)}
.ge{fill:none;stroke-width:1.5;opacity:.8}.ge.emits{stroke:var(--ev)}.ge.handled_by{stroke:var(--hd)}.ge.calls{stroke:var(--me);stroke-dasharray:5 3}.ge.via{stroke-dasharray:1.5 3}.ge.more{stroke:var(--line);stroke-dasharray:3 3}
.gmore{cursor:pointer}.gmore rect{fill:var(--panel);stroke:var(--mute);stroke-dasharray:3 3}.gmore text{fill:var(--mute);font-size:12px;text-anchor:middle}.gmore:hover rect{stroke:var(--acc)}
.glegend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--mute);margin-top:6px}.glegend i{display:inline-block;width:22px;border-top:2px solid;vertical-align:middle;margin-right:4px}
@media (max-width:800px){main{grid-template-columns:1fr;height:auto}aside{max-height:45vh}}
</style></head><body>
<header><h1>💎 Sapphire event map</h1><span class="meta" id="meta"></span></header>
<main>
<aside>
  <input id="q" placeholder="Search endpoint, event, class, method…   ( / )" autocomplete="off">
  <div id="chips"></div>
  <div class="navtabs"><button id="tBrowse" class="on">Browse</button><button id="tGraph">Graph</button><button id="tIssues">Issues</button></div>
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
for(const [s,d,k,f,l] of DATA.edges){(OUT.get(s)||OUT.set(s,[]).get(s)).push({id:d,k,f,l});(IN.get(d)||IN.set(d,[]).get(d)).push({id:s,k,f,l});}
const KIND={endpoint:['🌐','Endpoint'],event:['⚡','Event'],handler:['🎧','Handler'],method:['ƒ','Method'],lambda:['λ','Lambda'],class:['◆','Class']};
const ORDER=['endpoint','event','handler','lambda','method','class'];
const FWD={emits:'emits',handled_by:'handled by',calls:'calls'},BWD={emits:'emitted by',handled_by:'triggered by',calls:'called by'};
const enabled=new Set(ORDER);let selected=null,view='browse';
$('#meta').textContent=`${DATA.meta.files} files · ${DATA.nodes.length} nodes · ${DATA.edges.length} links · generated ${DATA.meta.generated}`;
function hrefOf(file,abs,line){const t=DATA.meta.link_template||'';
 return t.replace('{abs_path}',encodeURI(abs||'')).replace('{rel_path}',encodeURI(file)).replace('{line}',line||1);}
function link(file,abs,line,text){if(!file)return'';const href=hrefOf(file,abs,line);
 return `<a class="lnk" href="${esc(href)}" title="${esc(file)}:${line}">${esc(text||(file.split('/').pop()+':'+line))}</a>`;}
function ic(n){const k=KIND[n.kind]||['?',''];return `<span class="ic k-${n.kind}" title="${k[1]}">${k[0]}</span>`;}
function sub(n){if(n.kind==='endpoint'&&n.path)return `${n.verb||''} ${n.path}`;if(n.kind==='event'){const e=(IN.get(n.id)||[]).filter(x=>x.k==='emits').length,h=(OUT.get(n.id)||[]).length;return `${e} emitter(s) · ${h} listener(s)`;}return n.cls||'';}
// chips
for(const k of ORDER){const c=document.createElement('span');c.className='chip k-'+k;c.textContent=KIND[k][0]+' '+KIND[k][1]+' ('+DATA.nodes.filter(n=>n.kind===k).length+')';
 c.onclick=()=>{enabled.has(k)?enabled.delete(k):enabled.add(k);c.classList.toggle('off');renderList();};$('#chips').appendChild(c);}
const hay=new Map(DATA.nodes.map(n=>[n.id,[n.label,n.id,n.path,n.verb,n.file,n.cls].join(' ').toLowerCase()]));
function renderList(){const toks=$('#q').value.toLowerCase().split(/\s+/).filter(Boolean);
 let r=DATA.nodes.filter(n=>enabled.has(n.kind)&&toks.every(t=>hay.get(n.id).includes(t)));
 r.sort((a,b)=>ORDER.indexOf(a.kind)-ORDER.indexOf(b.kind)||a.label.localeCompare(b.label));
 $('#count').textContent=r.length+' result(s)'+(r.length>400?' – showing 400':'');
 $('#results').innerHTML=r.slice(0,400).map(n=>`<li data-id="${esc(n.id)}" class="${n.id===selected?'sel':''}">${ic(n)}<div><div>${esc(n.label)}</div><div class="sub">${esc(sub(n))}</div></div></li>`).join('');}
$('#results').onclick=e=>{const li=e.target.closest('li');if(li)go(li.dataset.id);};
$('#q').oninput=renderList;
document.addEventListener('keydown',e=>{if(e.key==='/'&&document.activeElement!==$('#q')){e.preventDefault();$('#q').focus();$('#q').select();}});
function go(id){location.hash=encodeURIComponent(id);}
window.addEventListener('hashchange',fromHash);
function fromHash(){const id=decodeURIComponent(location.hash.slice(1));if(id&&N.has(id)){if(view==='issues')setView('browse');select(id);}}
// detail
let dir='fwd',maxDepth=8;
function select(id){selected=id;const n=N.get(id);renderList();
 if(view==='graph'){drawGraph(null,true);return;}
 const roles=(n.roles||[]).filter(r=>r!==n.kind).map(r=>`<span class="badge k-${r}">${r}</span>`).join(' ');
 $('#detail').innerHTML=`<div class="title">${ic(n)}<h2>${esc(n.label)}</h2><span class="badge k-${n.kind}">${KIND[n.kind][1]}</span>${roles}</div>
 <div class="loc">${n.kind==='endpoint'&&n.path?`<code>${esc((n.verb||'')+' '+n.path)}</code> · `:''}${n.file?link(n.file,n.abs,n.line,n.file+':'+n.line):''}${n.cls?` <span class="sub">· ${esc(n.cls)}</span>`:''}</div>
 <div class="toolbar"><button class="btn" data-d="fwd">Trace forward ▶</button><button class="btn" data-d="bwd">◀ Trace back</button>
 <span class="sub">depth</span><select id="depth">${[2,3,4,6,8,12,20].map(d=>`<option ${d===maxDepth?'selected':''}>${d}</option>`).join('')}</select>
 <button class="btn" id="expand">Expand all</button><button class="btn" id="collapse">Collapse</button><button class="btn" id="copy">Copy as text</button>
 <label class="sub"><input type="checkbox" id="hideCalls"> events only</label></div>
 <div class="help" id="help"></div><ul class="tree" id="tree"></ul>
 <div class="section" id="direct"></div>`;
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
  if(e.k==='calls'){const more=(d==='fwd'?OUT:IN).get(e.id)||[];q.push(...more.map(m=>({...m,via:true})));}
  else out.push(e);}
 return out;}
function drawTree(){document.querySelectorAll('[data-d]').forEach(b=>b.classList.toggle('on',b.dataset.d===dir));
 $('#help').textContent=dir==='fwd'?'Everything this item triggers, step by step.':'Every path that leads to this item.';
 const t=$('#tree');t.innerHTML='';fill(t,selected,0,new Set([selected]));if(!t.children.length)t.innerHTML='<li class="sub">Nothing found in this direction.</li>';}
function fill(ul,id,depth,path){for(const e of nextOf(id,dir)){const n=N.get(e.id);if(!n)continue;const li=document.createElement('li');
 const lab=(dir==='fwd'?FWD:BWD)[e.k]+(e.via?' (via calls)':'');
 const row=`<span class="row"><span class="elabel">${esc(lab)}</span>${ic(n)}<span class="nm" data-id="${esc(n.id)}">${esc(n.label)}</span>${n.kind==='endpoint'&&n.path?`<code>${esc((n.verb||'')+' '+n.path)}</code>`:''}${link(e.f,absOf(e.f),e.l)}</span>`;
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
function drawDirect(n){const rows=(list,lbl)=>list.map(e=>{const m=N.get(e.id);return m?`<tr><td>${esc(lbl[e.k])}</td><td>${ic(m)} <span class="nm" data-id="${esc(m.id)}">${esc(m.label)}</span></td><td>${link(e.f,absOf(e.f),e.l)}</td></tr>`:''}).join('');
 const o=OUT.get(n.id)||[],i=IN.get(n.id)||[];
 $('#direct').innerHTML=`<h3>Direct links</h3><table><tr><th>Relation</th><th>Item</th><th>Where</th></tr>${rows(i,BWD)}${rows(o,FWD)||''}${!o.length&&!i.length?'<tr><td colspan=3 class="sub">none</td></tr>':''}</table>`;}
function asText(id){const lines=[];const n=N.get(id);lines.push(`${KIND[n.kind][1]}: ${n.label}${n.path?' ['+(n.verb||'')+' '+n.path+']':''}  (${n.file||''}:${n.line||''})`);
 const walk=(cur,depth,path)=>{if(depth>=maxDepth)return;for(const e of nextOf(cur,dir)){const m=N.get(e.id);if(!m)continue;
  lines.push(`${'  '.repeat(depth+1)}${(dir==='fwd'?FWD:BWD)[e.k]} -> ${KIND[m.kind][1]}: ${m.label}  (${e.f}:${e.l})${path.has(e.id)?'  [cycle]':''}`);
  if(!path.has(e.id))walk(e.id,depth+1,new Set([...path,e.id]));}};
 walk(id,0,new Set([id]));return lines.join('\n');}
// issues
function setView(v){view=v;['Browse','Graph','Issues'].forEach(x=>$('#t'+x).classList.toggle('on',v===x.toLowerCase()));}
$('#tBrowse').onclick=()=>{setView('browse');selected?select(selected):null;};
$('#tGraph').onclick=()=>{setView('graph');if(selected)drawGraph(null,true);
 else $('#detail').innerHTML='<div class="empty">Pick an item on the left to center the graph on it.</div>';};
// graph: centered on the selected item, incoming links on the left, outgoing on the right
const G={center:null,open:new Set(),lim:new Map(),pos:new Map(),t:{x:0,y:0,k:1},hide:false,auto:true};
const GW=210,GH=42,GX=290,GY=58,GLIM=25;
const trunc=(s,n)=>{s=String(s??'');return s.length>n?s.slice(0,n-1)+'…':s;};
function uniqNext(id,d){const seen=new Set(),r=[];
 for(const e of nextOf(id,d)){if(e.id===id||seen.has(e.id)||!N.has(e.id))continue;seen.add(e.id);r.push(e);}return r;}
function neighbours(id){const s=new Set();for(const d of ['fwd','bwd'])for(const e of uniqNext(id,d))s.add(e.id);return s;}
// Breadth-first from the center through expanded nodes. Each node keeps the column where it was
// first reached (outgoing = +1, incoming = -1) and its discovery order sets its row.
function gLayout(){const c=G.center,col=new Map([[c,0]]),seq=new Map([[c,0]]),q=[c],more=[];let n=1;
 while(q.length){const id=q.shift();if(!G.open.has(id))continue;
  for(const [d,s] of [['bwd',-1],['fwd',1]]){const list=uniqNext(id,d),key=id+'|'+d,lim=G.lim.get(key)||GLIM;
   for(const e of list.slice(0,lim))if(!col.has(e.id)){col.set(e.id,col.get(id)+s);seq.set(e.id,n++);q.push(e.id);}
   if(list.length>lim)more.push({key,owner:id,d,n:list.length-lim,col:col.get(id)+s,seq:n++});}}
 const cols=new Map(),add=o=>(cols.get(o.col)||cols.set(o.col,[]).get(o.col)).push(o);
 for(const [id,cl] of col)add({id,col:cl,seq:seq.get(id)});more.forEach(add);
 const pos=new Map();
 for(const [cl,arr] of cols){arr.sort((a,b)=>a.seq-b.seq);const h=(arr.length-1)*GY;
  arr.forEach((o,i)=>pos.set(o.key||o.id,{x:cl*GX,y:i*GY-h/2,more:o.key?o:null}));}
 return pos;}
function edgePath(a,b){const ax=a.x+GW/2,bx=b.x-GW/2;
 if(bx>ax+10){const m=(ax+bx)/2;return `M${ax},${a.y}C${m},${a.y} ${m},${b.y} ${bx},${b.y}`;}
 if(ax>bx+GW+10){const ax2=a.x-GW/2,bx2=b.x+GW/2,m=(ax2+bx2)/2;return `M${ax2},${a.y}C${m},${a.y} ${m},${b.y} ${bx2},${b.y}`;}
 const y=Math.max(a.y,b.y)+GH/2+28;return `M${a.x},${a.y+GH/2}C${a.x},${y} ${b.x},${y} ${b.x},${b.y+GH/2}`;}
function gSub(n){return n.kind==='endpoint'&&n.path?(n.verb||'')+' '+n.path:(n.cls||KIND[n.kind][1]);}
function gShell(){const n=N.get(G.center),hasLinks=!!DATA.meta.link_template;
 $('#detail').innerHTML=`<div class="title">${ic(n)}<h2>${esc(n.label)}</h2><span class="badge k-${n.kind}">${KIND[n.kind][1]}</span></div>
 <div class="loc">${n.kind==='endpoint'&&n.path?`<code>${esc((n.verb||'')+' '+n.path)}</code> · `:''}${n.file?link(n.file,n.abs,n.line,n.file+':'+n.line):''}</div>
 <div class="toolbar"><button class="btn" id="gExpand">Expand one level</button><button class="btn" id="gCollapse">Collapse all</button>
 <button class="btn" id="gFit">Fit</button><button class="btn" id="gTree">Open as tree</button>
 <label class="sub"><input type="checkbox" id="hideCalls" ${G.hide?'checked':''}> events only</label></div>
 <div class="help">Click a node to expand or collapse its links · double-click to center on it${hasLinks?' · Ctrl+click to open its source':''} · drag to pan, scroll to zoom</div>
 <div id="gwrap"><svg id="gsvg" data-c="${esc(G.center)}"><defs>${['emits','handled_by','calls'].map(k=>
  `<marker id="ar-${k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0L10,5L0,10z" style="fill:var(${k==='emits'?'--ev':k==='handled_by'?'--hd':'--me'})"/></marker>`).join('')}</defs><g id="gvp"></g></svg></div>
 <div class="glegend"><span><i style="border-color:var(--ev)"></i>emits</span><span><i style="border-color:var(--hd)"></i>handled by</span>
 <span><i style="border-color:var(--me);border-top-style:dashed"></i>calls</span><span><i style="border-color:var(--mute);border-top-style:dotted"></i>via calls (events only)</span></div>`;
 $('#gExpand').onclick=()=>{for(const id of G.pos.keys())if(N.has(id)&&neighbours(id).size)G.open.add(id);drawGraph(null,true);};
 $('#gCollapse').onclick=()=>{G.open=new Set([G.center]);G.lim=new Map();drawGraph(null,true);};
 $('#gFit').onclick=()=>{gFit();gApply();};
 $('#gTree').onclick=()=>{setView('browse');select(G.center);};
 $('#hideCalls').onchange=e=>{G.hide=e.target.checked;drawGraph(null,true);};
 const svg=$('#gsvg');let drag=null,clickT=null;
 svg.addEventListener('wheel',e=>{e.preventDefault();const r=svg.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top;
  const k=Math.min(3,Math.max(0.12,G.t.k*Math.exp(-e.deltaY*0.0015)));
  G.t.x=mx-(mx-G.t.x)*k/G.t.k;G.t.y=my-(my-G.t.y)*k/G.t.k;G.t.k=k;G.auto=false;gApply();},{passive:false});
 // refit when the panel gets its final size, until the user pans or zooms
 new ResizeObserver(()=>{if(G.auto&&$('#gsvg')===svg){gFit();gApply();}}).observe(svg);
 svg.addEventListener('pointerdown',e=>{if(e.target.closest('.gn,.gmore'))return;
  drag={x:e.clientX,y:e.clientY,tx:G.t.x,ty:G.t.y};G.auto=false;svg.classList.add('pan');svg.setPointerCapture(e.pointerId);});
 svg.addEventListener('pointermove',e=>{if(!drag)return;G.t.x=drag.tx+e.clientX-drag.x;G.t.y=drag.ty+e.clientY-drag.y;gApply();});
 const endDrag=()=>{drag=null;svg.classList.remove('pan');};svg.addEventListener('pointerup',endDrag);svg.addEventListener('pointercancel',endDrag);
 svg.addEventListener('click',e=>{const m=e.target.closest('.gmore');
  if(m){const p=G.pos.get(m.dataset.key).more;G.lim.set(p.key,(G.lim.get(p.key)||GLIM)+GLIM);drawGraph(p.owner);return;}
  const g=e.target.closest('.gn');if(!g)return;const id=g.dataset.id;
  if(e.ctrlKey||e.metaKey){const n=N.get(id);if(n.file&&DATA.meta.link_template)window.open(hrefOf(n.file,n.abs,n.line));return;}
  clearTimeout(clickT);
  if(e.detail>1){if(id!==G.center)go(id);return;}
  clickT=setTimeout(()=>gToggle(id),230);});}
function gToggle(id){
 if(G.open.has(id)){G.open.delete(id);
  // forget expansions that are no longer reachable from the center
  const vis=gLayout();for(const o of [...G.open])if(!vis.has(o))G.open.delete(o);}
 else if(neighbours(id).size)G.open.add(id);else return;
 drawGraph(id);}
function drawGraph(anchor,fit){
 if(G.center!==selected){G.center=selected;G.open=new Set([selected]);G.lim=new Map();G.pos=new Map();fit=true;}
 if(!$('#gsvg')||$('#gsvg').dataset.c!==G.center){gShell();fit=true;}
 const old=anchor&&G.pos.get(anchor),pos=gLayout();G.pos=pos;
 const edges=[],seen=new Set();
 for(const [id,p] of pos){if(p.more){edges.push(`<path class="ge more" d="${edgePath(p.more.d==='fwd'?pos.get(p.more.owner):p,p.more.d==='fwd'?p:pos.get(p.more.owner))}"/>`);continue;}
  for(const e of uniqNext(id,'fwd')){if(!pos.has(e.id)||seen.has(id+'>'+e.id))continue;seen.add(id+'>'+e.id);
   const a=N.get(id),b=N.get(e.id),k=FWD[e.k]?e.k:'calls';
   edges.push(`<path class="ge ${k}${e.via?' via':''}" d="${edgePath(p,pos.get(e.id))}" marker-end="url(#ar-${k})"><title>${esc(a.label+' '+(FWD[e.k]||e.k)+' '+b.label+(e.f?' — '+e.f+':'+e.l:''))}</title></path>`);}}
 const nodes=[];
 for(const [id,p] of pos){
  if(p.more){nodes.push(`<g class="gmore" data-key="${esc(id)}" transform="translate(${p.x-GW/2},${p.y-GH/2})"><rect width="${GW}" height="${GH}" rx="8"/><text x="${GW/2}" y="${GH/2+4}">+${p.more.n} more…</text></g>`);continue;}
  const n=N.get(id),nb=neighbours(id),hidden=[...nb].filter(x=>!pos.has(x)).length,open=G.open.has(id);
  let badge='';if(nb.size){const t=open&&!hidden?'−':'+'+(hidden||''),bw=Math.max(20,8+t.length*7);
   badge=`<g class="gb" transform="translate(${GW},${GH/2})"><rect x="${-bw/2}" y="-9" width="${bw}" height="18" rx="9"/><text y="4">${t}</text></g>`;}
  const tip=`${KIND[n.kind][1]}: ${n.label}${n.path?'\n'+(n.verb||'')+' '+n.path:''}${n.cls?'\n'+n.cls:''}${n.file?'\n'+n.file+':'+n.line:''}\n${nb.size} link(s)${hidden?', '+hidden+' hidden':''}`;
  nodes.push(`<g class="gn${id===G.center?' ctr':''}" data-id="${esc(id)}" transform="translate(${p.x-GW/2},${p.y-GH/2})"><title>${esc(tip)}</title>
   <rect class="box s-${n.kind}" width="${GW}" height="${GH}" rx="8"/><text class="ki f-${n.kind}" x="9" y="27">${KIND[n.kind][0]}</text>
   <text x="31" y="18">${esc(trunc(n.label,26))}</text><text class="gs" x="31" y="33">${esc(trunc(gSub(n),31))}</text>${badge}</g>`);}
 $('#gvp').innerHTML=edges.join('')+nodes.join('');
 if(fit)gFit();
 else if(old&&pos.get(anchor)){G.auto=false;const p=pos.get(anchor);G.t.x-=(p.x-old.x)*G.t.k;G.t.y-=(p.y-old.y)*G.t.k;}
 gApply();}
function gFit(){const svg=$('#gsvg'),W=svg.clientWidth||800,H=svg.clientHeight||500;let x0=1e9,x1=-1e9,y0=1e9,y1=-1e9;
 for(const p of G.pos.values()){x0=Math.min(x0,p.x-GW/2);x1=Math.max(x1,p.x+GW/2+14);y0=Math.min(y0,p.y-GH/2);y1=Math.max(y1,p.y+GH/2+30);}
 const k=Math.min(1.1,W/(x1-x0+60),H/(y1-y0+60));G.auto=true;G.t={k,x:W/2-(x0+x1)/2*k,y:H/2-(y0+y1)/2*k};}
function gApply(){$('#gvp').setAttribute('transform',`translate(${G.t.x},${G.t.y}) scale(${G.t.k})`);}
$('#tIssues').onclick=()=>{setView('issues');drawIssues();};
function drawIssues(){const ev=DATA.nodes.filter(n=>n.kind==='event');
 const noL=ev.filter(n=>!(OUT.get(n.id)||[]).length),noE=ev.filter(n=>!(IN.get(n.id)||[]).some(e=>e.k==='emits'));
 const deadEp=DATA.nodes.filter(n=>n.kind==='endpoint'&&!(OUT.get(n.id)||[]).length);
 const lst=a=>a.length?`<table>${a.map(n=>`<tr><td>${ic(n)} <span class="nm" data-id="${esc(n.id)}">${esc(n.label)}</span></td><td>${n.file?link(n.file,n.abs,n.line):''}</td></tr>`).join('')}</table>`:'<div class="sub">none 🎉</div>';
 $('#detail').innerHTML=`<div class="title"><h2>Issues & blind spots</h2></div>
 <div class="section"><h3>Events emitted but never listened to (${noL.length})</h3>${lst(noL)}</div>
 <div class="section"><h3>Events listened to but never emitted (${noE.length})</h3><div class="help">Often emitted with a dynamic name — check "unresolved" below.</div>${lst(noE)}</div>
 <div class="section"><h3>Unresolved emissions / handlers (${DATA.unresolved.length})</h3><div class="help">Event name not statically known (variable) or handler not found. Add a pattern to the config, or check by hand.</div>
 ${DATA.unresolved.length?`<table>${DATA.unresolved.map(u=>`<tr><td>${link(u.file,absOf(u.file),u.line,u.file+':'+u.line)}</td><td><code>${esc(u.text)}</code></td></tr>`).join('')}</table>`:'<div class="sub">none 🎉</div>'}</div>
 <div class="section"><h3>Endpoints with no detected chain (${deadEp.length})</h3>${lst(deadEp)}</div>`;}
renderList();fromHash();
</script></body></html>
EOF_HTML_TAIL
}
{ html_head; cat "$TMP/graph.json"; html_tail; } > "$OUT"
if [ -n "$JSON_OUT" ]; then cp "$TMP/graph.json" "$JSON_OUT"; fi
echo "Done. Open $OUT in a browser." >&2
