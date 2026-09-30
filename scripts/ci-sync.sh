#!/bin/bash
# Bring the checked-out branch up to date, without building anything:
#   1. merge the fork's upstream (MADEIRA_UPSTREAM, default branch) into HEAD;
#   2. move each submodule pin to the tip of the branch .gitmodules names.
# Run from a full-history checkout. It leaves any changes as commits on HEAD and
# does not push. With $GITHUB_OUTPUT set it writes `sha` (the resulting commit)
# and `changed` (whether that differs from where it started).
#
#   MADEIRA_UPSTREAM               repository to merge (default willfaust/Madeira)
#   MADEIRA_SYNC_UPSTREAM          1 (default) or 0
#   MADEIRA_UPDATE_SUBMODULES      1 (default) or 0
#   MADEIRA_ALLOW_WORKFLOW_CHANGES 1 when the push credential may change files under
#                                  .github/workflows (the default GITHUB_TOKEN may not)
set -euo pipefail
cd "$(dirname "$0")/.."

MADEIRA_UPSTREAM="${MADEIRA_UPSTREAM:-https://github.com/willfaust/Madeira.git}"
start="$(git rev-parse HEAD)"

git config user.name >/dev/null || git config user.name 'github-actions[bot]'
git config user.email >/dev/null || git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

summary() {
  echo "$*"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$*" >> "$GITHUB_STEP_SUMMARY"
}
warn() {
  echo "::warning::$*"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- Warning: $*" >> "$GITHUB_STEP_SUMMARY"
}

sync_upstream() {
  local branch up before
  branch="$(git ls-remote --symref "$MADEIRA_UPSTREAM" HEAD | awk '/^ref:/ && !seen { sub("refs/heads/", "", $2); print $2; seen = 1 }')"
  branch="${branch:-main}"
  git fetch --quiet --no-tags "$MADEIRA_UPSTREAM" "$branch"
  up="$(git rev-parse FETCH_HEAD)"
  if git merge-base --is-ancestor "$up" HEAD; then
    summary "- Upstream \`$branch\` (${up:0:7}) is already merged."
    return
  fi
  before="$(git rev-parse HEAD)"
  if ! git merge --no-edit -m "Merge upstream $branch (${up:0:7})" "$up" >/dev/null; then
    git merge --abort
    warn "Merging upstream $branch (${up:0:7}) conflicts with this branch; building without it. Merge it by hand."
    return
  fi
  # The default token cannot push a change to a workflow file (GitHub refuses it), so
  # keep the fork's own workflows and leave that merge to a person.
  if [ "${MADEIRA_ALLOW_WORKFLOW_CHANGES:-0}" != 1 ] \
      && ! git diff --quiet "$before" HEAD -- .github/workflows; then
    git reset --quiet --hard "$before"
    warn "Upstream $branch (${up:0:7}) changes .github/workflows, which this token cannot push; not merged. Use Sync fork on GitHub, or set the AUTO_SYNC_TOKEN secret."
    return
  fi
  summary "- Merged upstream \`$branch\` (${up:0:7}): $(git rev-list --count "$before..$up") commit(s)."
}

update_submodules() {
  local key name path url branch ref tip pin
  local -a moved=()
  while read -r key path; do
    name="${key#submodule.}"
    name="${name%.path}"
    url="$(git config -f .gitmodules "submodule.$name.url")"
    branch="$(git config -f .gitmodules "submodule.$name.branch" || true)"
    ref=HEAD
    [ -z "$branch" ] || ref="refs/heads/$branch"
    tip="$(git ls-remote "$url" "$ref" | awk 'NR == 1 { print $1 }')"
    if [ -z "$tip" ]; then
      warn "Could not read $ref of $url; keeping the pin of $path."
      continue
    fi
    pin="$(git rev-parse "HEAD:$path")"
    [ "$pin" != "$tip" ] || continue
    git update-index --add --cacheinfo "160000,$tip,$path"
    moved+=("$path ${pin:0:7} -> ${tip:0:7}")
  done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
  if [ "${#moved[@]}" -eq 0 ]; then
    summary '- Every submodule already points at its branch tip.'
    return
  fi
  git commit --quiet -m 'Update submodules to their newest branch tips' \
    -m "$(printf '%s\n' "${moved[@]}")"
  summary "- Updated submodule pins: $(printf '`%s`; ' "${moved[@]}")"
}

[ "${MADEIRA_SYNC_UPSTREAM:-1}" = 0 ] || sync_upstream
[ "${MADEIRA_UPDATE_SUBMODULES:-1}" = 0 ] || update_submodules

sha="$(git rev-parse HEAD)"
changed=false
[ "$sha" = "$start" ] || changed=true
summary "- Source commit: \`${sha:0:7}\` ($([ "$changed" = true ] && echo "new, was ${start:0:7}" || echo unchanged))."
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "sha=$sha" >> "$GITHUB_OUTPUT"
  echo "changed=$changed" >> "$GITHUB_OUTPUT"
fi
