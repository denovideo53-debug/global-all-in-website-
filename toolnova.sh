#!/usr/bin/env bash
# toolnova.sh - ToolNova repository automation, validation and maintenance script
# Usage: ./toolnova.sh <command>
# Commands: validate, check, stats, search, categories, list, doctor, help

set -euo pipefail
IFS=$'\n\t'

PROG_NAME="toolnova.sh"
TOOLS_JSON="tools.json"

print_help() {
  cat <<'EOF'
ToolNova CLI

Usage:
  ./toolnova.sh <command> [args]

Commands:
  validate    Validate tools registry (tools.json)
  check       Check repository health
  stats       Show platform statistics
  search      Search tools: ./toolnova.sh search <keyword>
  categories  List categories with counts
  list        List registered tools (optional: ./toolnova.sh list <limit>)
  doctor      Run diagnostics (checks dependencies/environments)
  help        Show this help

Examples:
  ./toolnova.sh validate
  ./toolnova.sh search pdf
  ./toolnova.sh list 50

EOF
}

# Utilities for JSON parsing: prefer jq, fallback to python3
_have_jq() { command -v jq >/dev/null 2>&1; }
_have_python() { command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; }

# Safely read tools.json and ensure it parses to an array of objects
_read_tools_raw() {
  if [ ! -f "$TOOLS_JSON" ]; then
    echo "ERROR: $TOOLS_JSON was not found." >&2
    return 2
  fi

  if _have_jq; then
    if ! jq empty "$TOOLS_JSON" >/dev/null 2>&1; then
      echo "ERROR: Invalid JSON in $TOOLS_JSON" >&2
      return 3
    fi
    # Prefer top-level .tools array if present, else assume root array
    if jq -e '.tools | arrays' "$TOOLS_JSON" >/dev/null 2>&1; then
      jq -c '.tools[]' "$TOOLS_JSON"
    else
      if jq -e 'arrays' "$TOOLS_JSON" >/dev/null 2>&1; then
        jq -c '.[]' "$TOOLS_JSON"
      else
        # Maybe root is object with numeric keys or single tool
        jq -c 'if type=="object" and has("id") then . as $single | [$single][] else empty end' "$TOOLS_JSON"
      fi
    fi
    return 0
  fi

  # Fallback to python for parsing (less strict output)
  if _have_python; then
    python3 - <<PY
import sys, json
p='''$TOOLS_JSON'''
try:
    j=json.load(open(p))
except Exception as e:
    sys.stderr.write('ERROR: Invalid JSON in %s: %s\n' % (p, e))
    sys.exit(3)
arr=None
if isinstance(j, dict) and 'tools' in j and isinstance(j['tools'], list):
    arr=j['tools']
elif isinstance(j, list):
    arr=j
elif isinstance(j, dict) and 'id' in j:
    arr=[j]
else:
    sys.stderr.write('ERROR: Unexpected JSON structure in %s\n' % p)
    sys.exit(4)
for item in arr:
    print(json.dumps(item, ensure_ascii=False))
PY
    return $?
  fi

  echo "ERROR: Neither 'jq' nor 'python3' is available to parse JSON. Please install one of them." >&2
  return 4
}

# Normalize a string for simple checks
_trim() { echo "$1" | sed -e 's/^\s\+//' -e 's/\s\+$//'; }

# Validate tools.json deeply
cmd_validate() {
  echo "ToolNova Validation"
  echo "-------------------"

  local errors=()
  local warnings=()

  if [ ! -f "$TOOLS_JSON" ]; then
    echo "ERROR: $TOOLS_JSON was not found."
    echo "Please create or restore the tools registry."
    return 2
  fi

  # Check JSON syntax and produce raw items
  local raw
  if ! raw=$(_read_tools_raw 2>&1); then
    echo "$raw" >&2
    return 3
  fi

  # Track uniqueness
  declare -A ids
  declare -A slugs
  declare -A names
  declare -A categories_count
  local total=0

  # Collect list of ids for reference checks
  local id_list=()
  while IFS= read -r line; do
    total=$((total+1))
    id=$(echo "$line" | ( _have_jq && jq -r '.id // empty' || python3 -c "import sys, json; print((json.loads(sys.stdin.read())).get('id',''))") )
    if [ -n "$id" ]; then id_list+=("$id"); fi
  done <<<"$raw"

  # Re-iterate for full validation (avoid storing huge arrays; use streaming)
  local idx=0
  while IFS= read -r item; do
    idx=$((idx+1))
    # Extract fields using jq if present, fallback to python
    if _have_jq; then
      id=$(echo "$item" | jq -r '.id // empty')
      slug=$(echo "$item" | jq -r '.slug // empty')
      name=$(echo "$item" | jq -r '.name // .title // empty')
      desc=$(echo "$item" | jq -r '.description // empty')
      category=$(echo "$item" | jq -r '.category // empty')
      keywords=$(echo "$item" | jq -r '.keywords // [] | join("||")')
      related=$(echo "$item" | jq -r '.related // [] | join("||")')
      status=$(echo "$item" | jq -r '.status // empty')
    else
      # python extraction
      read -r id slug name desc category keywords related status <<PY
$(python3 - <<PY2
import sys,json
obj=json.loads('''$item''')
print(obj.get('id',''))
print(obj.get('slug',''))
print(obj.get('name', obj.get('title','')))
print(obj.get('description',''))
print(obj.get('category',''))
print('||'.join(obj.get('keywords',[])))
print('||'.join(map(str,obj.get('related',[]))))
print(obj.get('status',''))
PY2
)
PY
    fi

    # Basic checks
    if [ -z "$id" ]; then
      errors+=("missing id for tool at index $idx")
    else
      if [[ ${ids[$id]+_} ]]; then
        errors+=("duplicate id: $id (index $idx)")
      else
        ids[$id]=1
      fi
    fi

    if [ -z "$slug" ]; then
      errors+=("missing slug for tool ${id:-index_$idx}")
    else
      if [[ ${slugs[$slug]+_} ]]; then
        errors+=("duplicate slug: $slug (index $idx)")
      else
        slugs[$slug]=1
      fi
      # slug format check: only lowercase letters, numbers, hyphen, underscore
      if ! [[ "$slug" =~ ^[a-z0-9-_]+$ ]]; then
        warnings+=("slug contains unusual characters: $slug (index $idx)")
      fi
    fi

    if [ -z "$name" ]; then
      errors+=("missing name/title for tool ${id:-index_$idx}")
    else
      if [[ ${names[$name]+_} ]]; then
        warnings+=("duplicate name: $name (index $idx)")
      else
        names[$name]=1
      fi
    fi

    if [ -z "$desc" ]; then
      warnings+=("missing description for ${id:-index_$idx}")
    fi

    if [ -z "$category" ]; then
      warnings+=("missing category for ${id:-index_$idx}")
    else
      # simple category char checks
      if [[ "$category" =~ [^[:print:]] ]]; then
        errors+=("category contains non-printable chars for ${id:-index_$idx}")
      fi
      categories_count["$category"]=$((categories_count["$category"]+1))
    fi

    # Keywords checks
    if [ -n "$keywords" ]; then
      IFS='||' read -r -a kwarr <<<"$keywords"
      declare -A seenkw
      for k in "${kwarr[@]}"; do
        ktrim=$(echo "$k" | sed -e 's/^\s\+//' -e 's/\s\+$//')
        if [ -z "$ktrim" ]; then
          warnings+=("empty keyword for ${id:-index_$idx}")
        else
          if [[ ${seenkw[$ktrim]+_} ]]; then
            warnings+=("duplicate keyword '$ktrim' in tool ${id:-index_$idx}")
          fi
          seenkw[$ktrim]=1
        fi
      done
    fi

    # Related references must exist in id_list
    if [ -n "$related" ]; then
      IFS='||' read -r -a rarr <<<"$related"
      for r in "${rarr[@]}"; do
        if [ -n "$r" ]; then
          found=0
          for idv in "${id_list[@]}"; do
            if [ "$idv" = "$r" ]; then found=1; break; fi
          done
          if [ $found -ne 1 ]; then
            warnings+=("related reference '$r' for tool ${id:-index_$idx} does not match any tool id")
          fi
        fi
      done
    fi

  done <<<"$raw"

  # Print summary
  printf "Total tools: %d\n" $total
  echo
  if [ ${#errors[@]} -ne 0 ]; then
    echo "Errors:";
    for e in "${errors[@]}"; do echo " - $e"; done
  fi
  if [ ${#warnings[@]} -ne 0 ]; then
    echo "Warnings:";
    for w in "${warnings[@]}"; do echo " - $w"; done
  fi

  if [ ${#errors[@]} -ne 0 ]; then
    echo
    echo "Result: FAIL"
    return 10
  fi

  echo
  echo "Result: PASS"
  return 0
}

# Repository health check
cmd_check() {
  echo "ToolNova Repository Check"
  echo "--------------------------"
  local rc=0

  # Validate tools.json
  if ! ./toolnova.sh validate >/dev/null 2>&1; then
    echo "[ERR] tools.json validation failed"
    rc=1
  else
    echo "[OK] tools.json validation passed"
  fi

  # Check presence of key files (non-fatal)
  for f in .github/workflows .github ISSUE_TEMPLATE README.md; do
    if [ -e "$f" ]; then
      echo "[OK] $f exists"
    else
      echo "[WARN] $f is missing"
    fi
  done

  # package manager detection
  if [ -f package.json ]; then
    echo "[INFO] package.json found"
    if [ -f pnpm-lock.yaml ]; then echo "[INFO] pnpm lockfile detected"; fi
    if [ -f yarn.lock ]; then echo "[INFO] yarn.lock detected"; fi
    if [ -f package-lock.json ]; then echo "[INFO] package-lock.json detected"; fi
  else
    echo "[INFO] package.json not present"
  fi

  # Check expected directories for a typical frontend repo (non-critical)
  for d in src public content; do
    if [ -d "$d" ]; then
      echo "[OK] directory: $d"
    else
      echo "[WARN] directory not found: $d"
    fi
  done

  return $rc
}

# Stats
cmd_stats() {
  if [ ! -f "$TOOLS_JSON" ]; then
    echo "ERROR: $TOOLS_JSON not found."
    return 2
  fi

  if _have_jq; then
    total=$(jq '.tools? // (if type=="array" then .|length else 0 end) + (if (.tools?|type)=="array" then 0 else 0 end) ' "$TOOLS_JSON" 2>/dev/null || jq 'if type=="array" then length else ( .tools|length ) end' "$TOOLS_JSON" ) || true
    # safer approach: get actual count
    total=$(jq -r 'if .tools then (.tools|length) elif type=="array" then (.|length) else 0 end' "$TOOLS_JSON")

    categories=$(jq -r '[ ( .tools? // . )[]? | .category // "(uncategorized)" ] | unique | length' "$TOOLS_JSON")
    echo "ToolNova Statistics"
    echo "-------------------"
    echo "Total Tools: $total"
    echo "Categories: $categories"
    echo
    echo "Tools per category:"
    jq -r '[( .tools? // . )[]? | .category // "(uncategorized)"] | group_by(.) | map({category:.[0], count:length}) | .[] | "- \(.category): \(.count)"' "$TOOLS_JSON"

    echo
    # featured/popular/new detection (best-effort)
    echo "Featured tools:"
    jq -r '[( .tools? // . )[]? | select(.featured==true) | .name // .title // .id ] | .[]? // "(none)"' "$TOOLS_JSON" | sed '/^$/d' | sed -n '1,20p' || true

    echo "\nPopular tools:"
    jq -r '[( .tools? // . )[]? | select(.popular==true) | .name // .title // .id ] | .[]? // "(none)"' "$TOOLS_JSON" | sed '/^$/d' | sed -n '1,20p' || true

    echo "\nTools with missing optional metadata (e.g., no description or no keywords):"
    jq -r '[( .tools? // . )[]? | select((.description // "")=="") | .name // .title // .id ] | .[]? // "(none)"' "$TOOLS_JSON" | sed '/^$/d' | sed -n '1,20p' || true

  else
    # Fallback using python
    python3 - <<PY
import json,sys
p='''$TOOLS_JSON'''
try:
    j=json.load(open(p))
except Exception as e:
    print('ERROR: Invalid JSON:', e)
    sys.exit(3)
arr = j.get('tools') if isinstance(j, dict) and 'tools' in j else (j if isinstance(j, list) else [])
print('ToolNova Statistics')
print('-------------------')
print('Total Tools:', len(arr))
cats={}
for t in arr:
    c=t.get('category','(uncategorized)')
    cats[c]=cats.get(c,0)+1
print('Categories:', len(cats))
print('\nTools per category:')
for k,v in sorted(cats.items(), key=lambda x:-x[1]):
    print('-', k+':', v)
print('\nFeatured tools:')
for t in arr:
    if t.get('featured'):
        print('-', t.get('name') or t.get('title') or t.get('id'))
print('\nPopular tools:')
for t in arr:
    if t.get('popular'):
        print('-', t.get('name') or t.get('title') or t.get('id'))
print('\nTools missing description:')
for t in arr:
    if not t.get('description'):
        print('-', t.get('name') or t.get('title') or t.get('id'))
PY
  fi
}

# Search
cmd_search() {
  local q="${1-}"
  if [ -z "$q" ]; then
    echo "Usage: $PROG_NAME search <keyword>" >&2
    return 2
  fi
  if [ ! -f "$TOOLS_JSON" ]; then
    echo "No tools registry ($TOOLS_JSON) found." >&2
    return 2
  fi
  echo "Search Results for: $q"
  echo
  if _have_jq; then
    # Build jq filter for case-insensitive contains over several fields
    jq -r --argQ "$q" '
      def ci_contains($s;$q): ($s//"" | ascii_downcase) | contains($q|ascii_downcase);
      [ ( .tools? // . )[]? | select(
        ci_contains(.id|tostring;$q) or
        ci_contains(.slug|tostring;$q) or
        ci_contains(.name//.title|tostring;$q) or
        ci_contains(.description|tostring;$q) or
        ci_contains(.category|tostring;$q) or
        (.keywords? // [] | map(tostring) | join(" ") | ascii_downcase | contains($q|ascii_downcase))
      ) | {id: .id, name: (.name//.title), slug: .slug, category: .category} ] | .[] | "- [\(.id // "?")] \(.name // \"(no title)\") (slug: \(.slug // \"?\"), category: \(.category // \"?\"))"' "$TOOLS_JSON" | sed '/^$/d' | sed -n '1,200p' || true
  else
    python3 - <<PY
import json,sys
q='''$q'''.lower()
try:
    j=json.load(open('''$TOOLS_JSON'''))
except Exception as e:
    print('ERROR reading JSON:', e)
    sys.exit(3)
arr = j.get('tools') if isinstance(j, dict) and 'tools' in j else (j if isinstance(j, list) else [])
res=[]
for t in arr:
    s=' '.join([str(t.get(k,'')) for k in ('id','slug','name','title','description','category')]+[' '.join(t.get('keywords',[]))])
    if q in s.lower():
        res.append(t)
for r in res[:200]:
    print('-', r.get('id') or r.get('slug') or '(no-id)', r.get('name') or r.get('title') or '')
if not res:
    print('No tools found.')
PY
  fi
}

# Categories list
cmd_categories() {
  if [ ! -f "$TOOLS_JSON" ]; then
    echo "No tools registry ($TOOLS_JSON) found." >&2
    return 2
  fi
  echo "Available Categories"
  echo "--------------------"
  if _have_jq; then
    jq -r '[( .tools? // . )[]? | .category // "(uncategorized)" ] | group_by(.) | map({category:.[0], count:length}) | sort_by(-.count) | .[] | "- \(.category): \(.count)"' "$TOOLS_JSON"
  else
    python3 - <<PY
import json
j=json.load(open('''$TOOLS_JSON'''))
arr = j.get('tools') if isinstance(j, dict) and 'tools' in j else (j if isinstance(j, list) else [])
cats={}
for t in arr:
    c=t.get('category','(uncategorized)')
    cats[c]=cats.get(c,0)+1
for k,v in sorted(cats.items(), key=lambda x:-x[1]):
    print('-', f"{k}: {v}")
PY
  fi
}

# List tools
cmd_list() {
  if [ ! -f "$TOOLS_JSON" ]; then
    echo "No tools registry ($TOOLS_JSON) found." >&2
    return 2
  fi
  local limit=${1-}
  if _have_jq; then
    if [ -n "$limit" ]; then
      jq -r --argjson L "$limit" '[( .tools? // . )[]? | {id: .id, name: (.name//.title), slug: .slug, category: .category}] | .[:$L] | .[] | "- [\(.id // "?")] \(.name // \"(no title)\") (slug: \(.slug // \"?\"), category: \(.category // \"?\"))"' "$TOOLS_JSON"
    else
      jq -r '[( .tools? // . )[]? | {id: .id, name: (.name//.title), slug: .slug, category: .category}] | .[] | "- [\(.id // "?")] \(.name // \"(no title)\") (slug: \(.slug // \"?\"), category: \(.category // \"?\"))"' "$TOOLS_JSON" | sed -n '1,500p'
    fi
  else
    python3 - <<PY
import json,sys
j=json.load(open('''$TOOLS_JSON'''))
arr = j.get('tools') if isinstance(j, dict) and 'tools' in j else (j if isinstance(j, list) else [])
limit=%s
for i,t in enumerate(arr):
    if limit and i>=limit: break
    print('-', t.get('id') or '(no-id)', t.get('name') or t.get('title') or '', f"(slug: {t.get('slug')}, category: {t.get('category')})")
PY
  fi
}

# Doctor
cmd_doctor() {
  echo "ToolNova Doctor"
  echo "---------------"
  local ok=0 fail=0
  check_bin() { if command -v "$1" >/dev/null 2>&1; then echo "✓ $1"; ok=$((ok+1)); else echo "✗ $1 (missing)"; fail=$((fail+1)); fi }
  check_bin bash
  check_bin jq
  check_bin python3
  check_bin node
  check_bin npm
  check_bin pnpm || true
  check_bin yarn || true

  # Check tools.json
  if [ -f "$TOOLS_JSON" ]; then
    if _read_tools_raw >/dev/null 2>&1; then
      echo "✓ $TOOLS_JSON"
    else
      echo "✗ $TOOLS_JSON (invalid JSON or structure)"
      fail=$((fail+1))
    fi
  else
    echo "✗ $TOOLS_JSON (missing)"
    fail=$((fail+1))
  fi

  # Check script executable
  if [ -x "$0" ]; then
    echo "✓ $PROG_NAME is executable"
  else
    echo "✗ $PROG_NAME is not executable (run: chmod +x $PROG_NAME)"
    fail=$((fail+1))
  fi

  echo
  if [ $fail -eq 0 ]; then
    echo "System Status: READY"
    return 0
  else
    echo "System Status: PROBLEMS DETECTED"
    return 2
  fi
}

# Entrypoint
main() {
  if [ $# -lt 1 ]; then
    print_help
    exit 2
  fi
  cmd="$1"; shift || true
  case "$cmd" in
    validate)
      cmd_validate
      ;;
    check)
      cmd_check
      ;;
    stats)
      cmd_stats
      ;;
    search)
      cmd_search "$@"
      ;;
    categories)
      cmd_categories
      ;;
    list)
      cmd_list "$@"
      ;;
    doctor)
      cmd_doctor
      ;;
    help|-h|--help)
      print_help
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      print_help
      exit 2
      ;;
  esac
}

main "$@"
