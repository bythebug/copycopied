#!/bin/zsh
# Builds and mounts a disk image that looks like a camera card (or an empty destination drive).
#   scripts/make-fake-card.sh sony|canon|gopro|drive "<Volume Name>" [clips=148] [kb-per-clip=256]
# Images go in ./fake-cards/ (git-ignored). Eject with: hdiutil detach "/Volumes/<Volume Name>"
# Media is random bytes; real metadata comes in Phase 4/6 via a mocked metadata provider.
# TODO(verify): folder layouts below are from common knowledge, not checked against real cards.
set -euo pipefail

kind=${1:?kind: sony|canon|gopro|drive}
name=${2:?volume name}
clips=${3:-148}
kb=${4:-256}
dir="$(cd "$(dirname "$0")/.." && pwd)/fake-cards"
mkdir -p "$dir"
img="$dir/${name// /_}.dmg"

[[ -e "/Volumes/$name" ]] && { echo "/Volumes/$name is already mounted" >&2; exit 1; }
rm -f "$img"
size_mb=$(( clips * kb * 3 / 1024 + 64 ))
fs=ExFAT layout=MBRSPUD
if [[ $kind == drive ]]; then fs=APFS layout=GPTSPUD size_mb=$(( size_mb > 512 ? size_mb : 512 )); fi
hdiutil create -quiet -size ${size_mb}m -fs $fs -volname "$name" -layout $layout "$img"
hdiutil attach -quiet "$img"
v="/Volumes/$name"

rnd() { head -c $(( kb * 1024 )) /dev/urandom > "$1"; }

case $kind in
  sony)
    mkdir -p "$v/PRIVATE/M4ROOT/CLIP" "$v/PRIVATE/M4ROOT/SUB"
    echo '<MediaProfile/>' > "$v/PRIVATE/M4ROOT/MEDIAPRO.XML"
    for i in $(seq 1 $clips); do
      n=$(printf C%04d $i)
      rnd "$v/PRIVATE/M4ROOT/CLIP/$n.MP4"
      echo "<NonRealTimeMeta clip=\"$n\"/>" > "$v/PRIVATE/M4ROOT/CLIP/${n}M01.XML"
    done ;;
  canon)
    mkdir -p "$v/DCIM/100CANON"
    for i in $(seq 1 $clips); do rnd "$v/DCIM/100CANON/$(printf MVI_%04d $i).MP4"; done ;;
  gopro)
    mkdir -p "$v/DCIM/100GOPRO"
    for i in $(seq 1 $clips); do
      n=$(printf GX01%04d $i)
      rnd "$v/DCIM/100GOPRO/$n.MP4"
      head -c 8192 /dev/urandom > "$v/DCIM/100GOPRO/$n.THM"
    done ;;
  drive) ;;
  *) echo "unknown kind: $kind" >&2; exit 1 ;;
esac
echo "$v"
