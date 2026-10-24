#!/bin/sh
# Xcode Cloud runs this right after cloning. Sheafs.xcodeproj and Config/Signing.xcconfig are
# git-ignored (XcodeGen generates the project from project.yml), so make both here.
# CI_TEAM_ID and CI_PRIMARY_REPOSITORY_PATH are set by Xcode Cloud.
set -eu
cd "${CI_PRIMARY_REPOSITORY_PATH:?not running in Xcode Cloud}"
: "${CI_TEAM_ID:?Xcode Cloud did not set CI_TEAM_ID}"
printf '// Written by ci_scripts/ci_post_clone.sh\nDEVELOPMENT_TEAM = %s\n' "$CI_TEAM_ID" > Config/Signing.xcconfig
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
test -f Sheafs.xcodeproj/xcshareddata/xcschemes/Sheafs.xcscheme || { echo "no shared Sheafs scheme" >&2; exit 1; }
echo "ci_post_clone: Sheafs.xcodeproj generated, team $CI_TEAM_ID"
