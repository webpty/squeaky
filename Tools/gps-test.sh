#!/bin/zsh
# Stage 2 test. Copies every photo in a folder to a second folder, writes one
# known location into the copies with the bundled ExifTool, and checks each
# copy. The source folder is only read, never written.
#
#   Tools/gps-test.sh <samples folder> <output folder>
set -e
cd "$(dirname "$0")/.."
root=$PWD

src=${1:A}
out=${2:A}
[[ -d "$src" ]] || { echo "No folder $src"; exit 2; }
[[ "$src" != "$out" ]] || { echo "Output must differ from the samples folder"; exit 2; }
mkdir -p "$out"

# Ushuaia harbour, the cruise pier.
lat=54.8090; latref=S
lon=68.2970; lonref=W
alt=3

et=(/usr/bin/perl "$root/Vendor/ExifTool/exiftool")
mkdir -p build
swiftc -O Tools/imagecheck.swift -o build/imagecheck 2>/dev/null
check=$root/build/imagecheck

# Everything except the GPS block, the file system's own entries and offsets
# that move when the metadata grows.
compare=(-a -G1 -s -n --GPS:all --System:all --ExifTool:all --File:FileSize)
ignore='(Offset|Start|Length|ByteCount|MediaDataSize|Size) *:|^\[Composite\] *(GPS|ImageSize)'

for f in "$src"/*(.N); do
  name=${f:t}
  case ${name:e:l} in
    cr3|hif|heif|heic|jpg|jpeg) ;;
    *) continue ;;
  esac
  copy="$out/$name"
  [[ -e "$copy" ]] && { echo "$name: already in the output folder, skipped"; continue; }

  model=$("${et[@]}" -s3 -Model "$f")
  had=$("${et[@]}" -s3 -n -GPSLatitude "$f")
  taken=$("${et[@]}" -s3 -DateTimeOriginal "$f")
  zone=$("${et[@]}" -s3 -OffsetTimeOriginal "$f")

  # GPS time is UTC: the capture time less its zone. No zone recorded: the
  # camera clock is taken as UTC for this test only.
  if [[ -n "$zone" ]]; then
    utc=$(date -j -u -f "%Y:%m:%d %H:%M:%S %z" "$taken ${zone/:/}" "+%Y:%m:%d %H:%M:%S")
  else
    utc=$taken
  fi

  cp -p "$f" "$copy"
  "${et[@]}" "${compare[@]}" "$copy" | grep -Ev "$ignore" > "$out/.before-$name.txt"

  # Clear any old location first, so no old GPS detail is left mixed with the
  # new one. Every tag names the EXIF GPS block: left to choose, ExifTool also
  # writes XMP into a CR3, without the S and W, which reads as north and east.
  # Then the file's own dates are copied back from the original.
  "${et[@]}" -q -P -overwrite_original \
    -GPS:all= -XMP-exif:GPS\*= \
    -GPS:GPSVersionID=2.3.0.0 \
    -GPS:GPSLatitude=$lat -GPS:GPSLatitudeRef=$latref \
    -GPS:GPSLongitude=$lon -GPS:GPSLongitudeRef=$lonref \
    -GPS:GPSAltitude=$alt -GPS:GPSAltitudeRef=0 \
    -GPS:GPSDateStamp="${utc[1,10]}" -GPS:GPSTimeStamp="${utc[12,19]}" \
    -GPS:GPSMapDatum=WGS-84 \
    "$copy"
  "${et[@]}" -q -P -overwrite_original -tagsFromFile "$f" -FileCreateDate -FileModifyDate "$copy"

  "${et[@]}" "${compare[@]}" "$copy" | grep -Ev "$ignore" > "$out/.after-$name.txt"
  changed=$(diff "$out/.before-$name.txt" "$out/.after-$name.txt" | grep -c '^[<>]' || true)
  if [[ "$changed" == 0 ]]; then
    rm "$out/.before-$name.txt" "$out/.after-$name.txt"
  fi

  hash=(-s3 -api ImageHashType=SHA256 -ImageDataHash)
  picture_same=$([[ $("${et[@]}" "${hash[@]}" "$f") == $("${et[@]}" "${hash[@]}" "$copy") ]] && echo yes || echo no)
  xmp=$("${et[@]}" -s3 -a -XMP-exif:GPSLatitude "$copy")
  warnings=$("${et[@]}" -s3 -validate -warning "$copy" | tr '\n' ' ')
  created_same=$([[ $(stat -f %B "$f") == $(stat -f %B "$copy") ]] && echo yes || echo no)
  modified_same=$([[ $(stat -f %m "$f") == $(stat -f %m "$copy") ]] && echo yes || echo no)
  written=$("${et[@]}" -s3 -c '%.6f' -GPSLatitude -GPSLongitude -GPSAltitude -GPSDateStamp -GPSTimeStamp "$copy" | tr '\n' ' ')
  system=$("$check" "$copy" || true)

  print -r -- "$name | $model | had location: $([[ -n "$had" ]] && echo yes || echo no) | zone: ${zone:-none}"
  print -r -- "  written: $written"
  print -r -- "  system reads: $system"
  print -r -- "  picture untouched: $picture_same | other details changed: $changed | second location left: ${xmp:-none}"
  print -r -- "  created date kept: $created_same | modified date kept: $modified_same"
  print -r -- "  validate: ${warnings:-ok}"
done
