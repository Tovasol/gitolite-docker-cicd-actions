#!/usr/bin/env sh
. /cicd/lib.sh
step smoke
echo "CI works: repo=$CI_REPO branch=$CI_BRANCH sha=$CI_SHA"
