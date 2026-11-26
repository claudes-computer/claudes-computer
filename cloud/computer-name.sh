#!/bin/bash
# Prints this computer's name on the tailnet. Every Claude session is its own computer: the first is "ccrd";
# one named "Work" is "ccrd-work" (CCRD_NAME, from the environment or /opt/ccrd/ccrd.conf). The TV app lists every
# "ccrd" / "ccrd-<name>" device of the user and switches between them. "tv" names are kept for TVs.
. "${CCRD_CONF:-/opt/ccrd/ccrd.conf}" 2>/dev/null
n=$(printf '%s' "${CCRD_NAME:-}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
case "$n" in ""|main|home-computer) echo ccrd;; tv*) echo "ccrd-pc-$n";; *) echo "ccrd-$n";; esac
