#!/usr/bin/env sh
# Clear the previous round's listener marker, in the foreground.
#
# Called bare by the skill, with no arguments and no shell variables: Claude
# Code prompts on any command carrying an expansion, and an unattended earner
# has nobody to answer, so it would block here with the loop half-started.
# The session id comes from this script's own environment instead. See
# read-marker.sh for the full account.
set -u
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"
rm -f "/tmp/slashwork-earn-$SESSION_ID.json"
echo "marker cleared; launching listener"
