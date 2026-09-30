#!/bin/bash
# Publish the built IPA as a GitHub Release. Run from a full-history checkout of the
# commit that was built, with the Madeira-iPhone artifact downloaded under $DIST.
#
#   GH_TOKEN         token allowed to write releases
#   SHA              the commit the IPA was built from
#   DIST             directory holding the downloaded artifact (default dist)
#   MADEIRA_DRAFT    1 publishes a draft nobody else can see (default 0)
#   MADEIRA_KEEP     keep this many automatic releases, delete older ones (0 = keep all)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GH_TOKEN:?}" "${SHA:?}"
DIST="${DIST:-dist}"
repo="${GITHUB_REPOSITORY:?}"
sha7="${SHA:0:7}"
tag="build-$(date -u +%Y%m%d)-$sha7"
tag_re='^build-[0-9]{8}-[0-9a-f]{7}$'

ipa="$(find "$DIST" -name Madeira-unsigned.ipa -type f | head -n 1)"
[ -n "$ipa" ] || { echo "No Madeira-unsigned.ipa under $DIST" >&2; exit 1; }
artifact_dir="$(dirname "$ipa")"

# The artifact must be the build of the commit being released, and intact.
built_from="$(cat "$artifact_dir/source-commit.txt")"
if [ "$built_from" != "$SHA" ]; then
  echo "The IPA was built from $built_from, not $SHA" >&2
  exit 1
fi
want="$(awk 'NR == 1 { print $1 }' "$artifact_dir/SHA256SUMS")"
have="$(sha256sum "$ipa" | awk '{ print $1 }')"
[ "$want" = "$have" ] || { echo "IPA checksum mismatch: $have, expected $want" >&2; exit 1; }
unzip -tq "$ipa" >/dev/null

# The newest earlier automatic release, to list what changed since.
prev_tag="$(gh release list --repo "$repo" --limit 100 --json tagName,isDraft,createdAt \
  --jq "[.[] | select(.isDraft | not) | select(.tagName | test(\"$tag_re\")) | select(.tagName != \"$tag\")]
        | sort_by(.createdAt) | reverse | .[0].tagName // empty")"
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
{
  echo "Unsigned Madeira iPhone build (Debug configuration) of commit [\`$sha7\`](https://github.com/$repo/commit/$SHA)."
  echo
  echo "Sign it with your own Apple ID in a sideloading tool before installing; JIT is enabled"
  echo "through StikDebug. It contains what compiles, not a statement of game compatibility."
  echo "SHA-256: \`$have\`"
  echo
  echo '### Sources'
  git submodule status | sed -E 's/^[-+ ]?([0-9a-f]{7})[0-9a-f]* ([^ ]+).*/- `\2` `\1`/'
  if [ -n "$prev_tag" ] && git rev-parse -q --verify "$prev_tag^{commit}" >/dev/null; then
    echo
    echo "### Changes since \`$prev_tag\`"
    git log --no-merges --pretty='- %h %s' "$prev_tag..$SHA" | head -n 40
    git diff --raw "$prev_tag" "$SHA" \
      | awk '$1 == ":160000" && $2 == "160000" { print "- `" $6 "` " substr($3, 1, 7) " -> " substr($4, 1, 7) }'
  fi
} > "$notes"

assets=("$ipa" "$artifact_dir/SHA256SUMS" "$artifact_dir/submodule-commits.txt" \
        "$artifact_dir/BUILD-NOTES.txt" "$artifact_dir/Madeira.entitlements")
title="Madeira build $(date -u +%Y-%m-%d) ($sha7)"

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  # A forced rebuild of the same commit on the same day replaces its assets.
  gh release upload "$tag" "${assets[@]}" --repo "$repo" --clobber
  gh release edit "$tag" --repo "$repo" --title "$title" --notes-file "$notes"
else
  flags=(--latest)
  [ "${MADEIRA_DRAFT:-0}" != 1 ] || flags=(--draft)
  gh release create "$tag" "${assets[@]}" --repo "$repo" --target "$SHA" \
    --title "$title" --notes-file "$notes" "${flags[@]}"
fi
echo "Release $tag: https://github.com/$repo/releases/tag/$tag"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "Release: [$tag](https://github.com/$repo/releases/tag/$tag)" >> "$GITHUB_STEP_SUMMARY"

# Old automatic releases are dropped so the repository does not fill with 140 MB
# files. Only tags this script makes are considered.
keep="${MADEIRA_KEEP:-0}"
if [ "$keep" -gt 0 ]; then
  gh release list --repo "$repo" --limit 200 --json tagName,isDraft,createdAt \
    --jq "[.[] | select(.isDraft | not) | select(.tagName | test(\"$tag_re\"))]
          | sort_by(.createdAt) | reverse | .[$keep:] | .[].tagName" \
    | while read -r old; do
        echo "Deleting old release $old"
        gh release delete "$old" --repo "$repo" --cleanup-tag --yes
      done
fi
