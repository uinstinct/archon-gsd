#!/usr/bin/env bash
# add-to-archon.sh — drop the archon-gsd Engine files into an existing Archon
# checkout, in one command. Resolves issue #8.
#
# One-liner (run from your Archon checkout root — the dir holding Archon's
# docker-compose.yml):
#
#   curl -fsSL https://raw.githubusercontent.com/uinstinct/archon-gsd/main/scripts/add-to-archon.sh | bash
#
# Or target a checkout elsewhere:
#
#   curl -fsSL https://raw.githubusercontent.com/uinstinct/archon-gsd/main/scripts/add-to-archon.sh | bash -s -- /path/to/archon
#
# What it copies (see README, "Add to an existing Archon setup"):
#   docker-compose.override.yml       (merge slot)
#   docker/Dockerfile.user        -> Dockerfile.user            (merge slot)
#   docker/install-gsd-runtime.sh -> install-gsd-runtime.sh
#   docker/gsd-seed-entrypoint.sh -> gsd-seed-entrypoint.sh
#   docker/log-tail.ts            -> log-tail.ts
#
# Conflict policy:
#   * The two files Archon also treats as user extension slots —
#     docker-compose.override.yml and Dockerfile.user — are NEVER clobbered.
#     If yours already exists and differs from the incoming version, the
#     incoming content is appended below a clearly marked banner so you can
#     merge it by hand. Re-running won't append twice.
#   * The three GSD-owned helper files are written straight in. If one already
#     exists and differs, the old copy is saved as <name>.bak first.
set -euo pipefail

RAW_BASE="${ARCHON_GSD_RAW:-https://raw.githubusercontent.com/uinstinct/archon-gsd/main}"
DEST="${1:-$PWD}"

# Marker that fingerprints a pending, un-merged archon-gsd block. Used both to
# write the banner and to detect (and skip) a prior append on re-run.
MERGE_BEGIN="# >>> archon-gsd: incoming content — NOT auto-merged (merge me, then delete to the end marker) >>>"
MERGE_END="# <<< archon-gsd: end >>>"

# Source path in the repo == path under RAW_BASE == basename written at DEST.
# "merge" files get the no-clobber banner treatment; "copy" files overwrite
# (with a .bak of any differing prior copy).
FILES=(
  "docker-compose.override.yml|merge"
  "docker/Dockerfile.user|merge"
  "docker/install-gsd-runtime.sh|copy"
  "docker/gsd-seed-entrypoint.sh|copy"
  "docker/log-tail.ts|copy"
)

FRESH=()      # written for the first time
UPDATED=()    # overwrote an identical-or-stale copy file (with .bak)
SKIPPED=()    # already current, nothing to do
NEEDS_MERGE=() # banner appended; user must merge by hand

die() { echo "error: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required but not found on PATH"

[ -d "$DEST" ] || die "destination '$DEST' is not a directory"
if [ ! -f "$DEST/docker-compose.yml" ]; then
  echo "warning: '$DEST/docker-compose.yml' not found — this should be your" >&2
  echo "         Archon checkout root. Pass the right path as the first arg, e.g." >&2
  echo "         curl -fsSL .../add-to-archon.sh | bash -s -- /path/to/archon" >&2
  echo "" >&2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # fetch <src-rel-path> <out-file>
  curl -fsSL "$RAW_BASE/$1" -o "$2" \
    || die "download failed: $RAW_BASE/$1"
}

for entry in "${FILES[@]}"; do
  src="${entry%%|*}"
  mode="${entry##*|}"
  name="$(basename "$src")"
  target="$DEST/$name"
  incoming="$TMP/$name"

  fetch "$src" "$incoming"

  if [ ! -e "$target" ]; then
    cp "$incoming" "$target"
    FRESH+=("$name")
    continue
  fi

  if cmp -s "$incoming" "$target"; then
    SKIPPED+=("$name")
    continue
  fi

  case "$mode" in
    merge)
      if grep -qF "$MERGE_BEGIN" "$target"; then
        # A prior run already appended a block awaiting merge — don't stack another.
        NEEDS_MERGE+=("$name (block already appended on an earlier run — still un-merged)")
        continue
      fi
      {
        printf '\n'
        printf '# ============================================================================\n'
        printf '%s\n' "$MERGE_BEGIN"
        printf '# This file already existed and differs from archon-gsd'\''s version, so the\n'
        printf '# incoming content was appended below instead of overwriting yours. Merge it\n'
        printf '# into the configuration above, then delete everything from the banner down\n'
        printf '# to the "%s" line.\n' "$MERGE_END"
        printf '# Source: %s/%s\n' "$RAW_BASE" "$src"
        printf '# ============================================================================\n'
        cat "$incoming"
        printf '%s\n' "$MERGE_END"
      } >>"$target"
      NEEDS_MERGE+=("$name")
      ;;
    copy)
      cp "$target" "$target.bak"
      cp "$incoming" "$target"
      UPDATED+=("$name (previous copy saved as $name.bak)")
      ;;
    *)
      die "internal: unknown mode '$mode' for $src"
  esac
done

# Keep the shell helpers executable.
for sh in install-gsd-runtime.sh gsd-seed-entrypoint.sh; do
  [ -f "$DEST/$sh" ] && chmod +x "$DEST/$sh"
done

print_list() { # print_list <heading> <array-name>
  local heading="$1"; shift
  [ "$#" -gt 0 ] || return 0
  echo "$heading"
  local item
  for item in "$@"; do echo "  - $item"; done
  echo ""
}

echo ""
echo "archon-gsd files applied to: $DEST"
echo ""
print_list "Written fresh:"            "${FRESH[@]+"${FRESH[@]}"}"
print_list "Updated (backup kept):"    "${UPDATED[@]+"${UPDATED[@]}"}"
print_list "Already current, skipped:" "${SKIPPED[@]+"${SKIPPED[@]}"}"
print_list "NEEDS MANUAL MERGE:"       "${NEEDS_MERGE[@]+"${NEEDS_MERGE[@]}"}"

if [ "${#NEEDS_MERGE[@]}" -gt 0 ]; then
  echo "Action required: the files above already existed. Open each one, fold the"
  echo "appended archon-gsd block into your own config, and delete the banner +"
  echo "block. The marked block starts at:"
  echo "  $MERGE_BEGIN"
  echo ""
fi

echo "Next, build the Engine into Archon's image (run from $DEST):"
echo "  docker compose -f docker-compose.yml build   # base 'archon' image first"
echo "  docker compose up -d --build                 # builds the GSD extension, runs the stack"
echo ""
echo "Then place the workflow and prepare each target repo — see README steps 2 and 3:"
echo "  https://github.com/uinstinct/archon-gsd#add-to-an-existing-archon-setup"
echo ""
echo "Notes:"
echo "  - An existing docker-compose.override.yml or Dockerfile.user is never"
echo "    overwritten — when one differs, the incoming content is appended under a"
echo "    merge banner for you to fold in by hand."
echo "  - Re-running this script is safe. Target a checkout elsewhere with:"
echo "      curl -fsSL $RAW_BASE/scripts/add-to-archon.sh | bash -s -- /path/to/archon"
