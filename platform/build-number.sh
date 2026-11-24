#!/usr/bin/env sh
# The build number App Store Connect tells uploads apart by, printed: the time of the build in UTC, the day and
# the hour and minute as one number, 20261124.825 is 24 November 2026 at 8:25. It only goes up, two builds of
# the same commit too, no upload is refused as one it has seen. No leading zeros, App Store Connect reads
# integers. The build scripts write it into the bundle's copy of the Info.plist, the repo's stays as it is.

set -eu

date -u '+%Y%m%d %H %M' | awk '{ print $1 "." $2 * 100 + $3 }'
