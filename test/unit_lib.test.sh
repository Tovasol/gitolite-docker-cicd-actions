#!/usr/bin/env bash
# Tier-1 unit tests for lib.sh pure functions — the glob/branch/path matching, slugify,
# and clamp logic, with adversarial inputs (regex-metachar injection, traversal, shell
# metachars, empty/huge). lib.sh is side-effect-free on source.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
# shellcheck source=/dev/null
. "$HERE/../bin/lib.sh"

suite glob_match
assert_ok   "** matches nested"        glob_match "site/scaffold/src/App.tsx" "site/scaffold/**"
assert_ok   "** matches direct child"  glob_match "site/scaffold/index.html"  "site/scaffold/**"
assert_ok   "* matches one segment"    glob_match "site/x"   "site/*"
assert_fail "* does NOT cross slash"   glob_match "site/a/b" "site/*"
assert_ok   "? matches one char"       glob_match "main"     "ma?n"
assert_fail "? does NOT cross slash"   glob_match "a/b"      "a?b"
assert_ok   "literal dot is escaped"   glob_match "a.b"      "a.b"
assert_fail "dot not treated as regex" glob_match "axb"      "a.b"
assert_fail "regex metachars literal"  glob_match "xxxx"     "a.*"
assert_ok   "leading **/ optional"     glob_match "App.tsx"  "**/App.tsx"
assert_ok   "leading **/ with prefix"  glob_match "a/b/App.tsx" "**/App.tsx"

suite branch_matches
assert_ok   "empty include = all"      branch_matches "anything" "" ""
assert_ok   "exact include"            branch_matches "main" "main" ""
assert_ok   "glob include one-seg"     branch_matches "feature/x" "feature/*" ""
assert_fail "not in include"           branch_matches "release" "main" ""
assert_fail "ignore wins over include" branch_matches "main" "" "main"
assert_fail "ignore wins (explicit)"   branch_matches "main" "main" "main"

suite paths_match
nl=$'\n'
assert_ok   "any changed hits include" paths_match "site/a${nl}README.md" "site/**" ""
assert_fail "none hit include"         paths_match "README.md${nl}docs/x" "site/**" ""
assert_fail "all paths ignored"        paths_match "docs/a${nl}docs/b" "" "docs/**"
assert_ok   "empty filters = match"    paths_match "anything" "" ""

suite slugify
assert_match "lowercases + dashes"   "$(slugify 'feature/Foo Bar')" '^feature-foo-bar-[0-9a-f]{6}$'
assert_no_match "no slash leaks"     "$(slugify 'a/b/c')"           '/'
assert_no_match "no traversal dots"  "$(slugify '../../etc')"       '\.\.'
assert_match "slug starts alnum (no leading dash)" "$(slugify '../../etc')" '^[a-z0-9]'
assert_no_match "shell metachars gone" "$(slugify '$(rm -rf /)')"   '[$()]'
assert_match "empty -> safe base"    "$(slugify '')"                '^x-[0-9a-f]{6}$'
assert_ne    "distinct inputs differ" "$(slugify 'a')" "$(slugify 'b')"
# the appended sha1 — not the base — must be the discriminator: two inputs that base-slugify to
# the SAME stem (foo-bar) must still differ, which can ONLY come from the hash suffix.
assert_ne    "hash disambiguates same-base inputs" "$(slugify 'foo/bar')" "$(slugify 'foo!bar')"

suite clamp_int
assert_eq "in range"        "$(clamp_int 5 1 10)"   5
assert_eq "below -> lo"     "$(clamp_int 0 1 10)"   1
assert_eq "above -> hi"     "$(clamp_int 99 1 10)"  10
assert_eq "non-numeric->lo" "$(clamp_int abc 1 10)" 1
assert_eq "empty -> lo"     "$(clamp_int '' 1 10)"  1
assert_eq "injection -> lo" "$(clamp_int '5;rm -rf /' 1 10)" 1

summary
