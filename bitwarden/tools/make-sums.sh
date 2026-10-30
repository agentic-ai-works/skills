#!/usr/bin/env bash
# Regenerate SHA256SUMS for the files that run (scripts/, install/, LICENSE).
# Run this before every release, then publish the printed fingerprint next to the download
# (listing page, release notes). install.sh checks the files against SHA256SUMS, and with
# --expect FINGERPRINT also checks that SHA256SUMS itself is the one you published.
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
find scripts install LICENSE -type f ! -name "*.cmd" | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
echo "SHA256SUMS written ($(wc -l < SHA256SUMS) files)."
echo "Publish this fingerprint: $(sha256sum SHA256SUMS | cut -d' ' -f1)"
