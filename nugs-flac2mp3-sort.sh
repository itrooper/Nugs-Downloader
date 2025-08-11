#!/usr/bin/env zsh
set -euo pipefail

# ========= CONFIG =========
# Where Nugs-Downloader saves shows (on your Mac, NAS mounted at /Volumes/data):
SRC="/Volumes/data/downloads/music/nugs"
# Final MP3 library (your main library, separate under nugs/):
DEST_BASE="/Volumes/data/media/music/nugs"
# Dry run (1 = no file changes)
DRY_RUN=0

# Explicit eyeD3 path (from your Homebrew Cellar)
EYE_D3="/opt/homebrew/Cellar/eye-d3/0.9.8/bin/eyeD3"

# ========= DEPS =========
SED="${SED:-$(command -v gsed || command -v sed || true)}"
[[ -n "${SED:-}" ]] || { echo "Need sed/gsed (brew install gnu-sed)"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need ffmpeg
need mp3gain
[[ -x "$EYE_D3" ]] || { echo "Missing eye-d3 at $EYE_D3"; exit 1; }
[[ -d "$SRC" ]] || { echo "Source not found: $SRC"; exit 1; }
mkdir -p "$DEST_BASE"

# zsh nullglob (bash shopt equivalent)
setopt NULL_GLOB

# ========= HELPERS =========
trim(){ print -r -- "$1" | "$SED" 's/^[[:space:]]\+//; s/[[:space:]]\+$//'; }
clean_component(){
  print -r -- "$1" | "$SED" '
    s~/~, ~g; s/[[:cntrl:]]//g; s/[*?<>|"]//g;
    s/[[:space:]]\{1,\}$//; s/^[[:space:]]\{1,\}//; s/[[:space:]]\{2,\}/ /g;'
}
mmddyyyy(){ local iso="${1:0:10}"; date -jf "%Y-%m-%d" "$iso" "+%m-%d-%Y" 2>/dev/null || printf "%s" "$iso"; }
pick_cover(){ local d="$1"; for c in cover.jpg Cover.jpg COVER.jpg folder.jpg Folder.jpg FOLDER.jpg cover.png Cover.png; do
  [[ -f "$d/$c" ]] && { print -r -- "$d/$c"; return; }; done }

# Extract tags from a file (returns: ARTIST \n ALBUM \n DATE)
probe_tags(){
  local f="$1"
  ffprobe -v error -select_streams a:0 \
    -show_entries format_tags=artist,album,date \
    -of default=nw=1:nk=1 "$f" 2>/dev/null || true
}

# Parse album like "YYYY-MM-DD Venue, City, ST" → iso_date + venue
parse_album_date_venue(){
  local album="$1"
  if [[ "$album" =~ ^([0-9]{4})[-_/]([0-9]{2})[-_/]([0-9]{2})[[:space:]]+(.+)$ ]]; then
    print -r -- "${match[1]}-${match[2]}-${match[3]}" "${match[4]}"
  else
    print -r -- "" "$album"
  fi
}

echo "Scanning: $SRC"
for showdir in "$SRC"/*(/); do
  # choose a probe file: prefer FLAC, else MP3
  probe=""
  for f in "$showdir"/*.flac "$showdir"/*.mp3; do probe="$f"; break; done
  [[ -n "$probe" ]] || { echo "Skip (no media): ${showdir:t}"; continue; }

  # Read tags
  vals=($(probe_tags "$probe"))
  artist_raw="${vals[1]:-Unknown Artist}"
  album_raw="${vals[2]:-}"
  date_tag="${vals[3]:-}"   # may be empty or "2025-08-02..."

  # Peel date & venue from album when possible
  pair=($(parse_album_date_venue "$album_raw"))
  iso_from_album="${pair[1]:-}"
  venue_raw="${pair[2]:-Unknown Venue}"

  iso_date="${iso_from_album:-${date_tag:0:10}}"
  [[ -z "$iso_date" ]] && iso_date="1900-01-01"

  # Final strings
  artist_clean="$(clean_component "$(trim "$artist_raw")")"
  venue_clean="$(clean_component "$(trim "$venue_raw")")"
  date_out="$(mmddyyyy "$iso_date")"
  year="${iso_date:0:4}"

  dest_dir="${DEST_BASE}/${artist_clean}/${venue_clean} - ${date_out}"
  [[ $DRY_RUN -eq 1 ]] || mkdir -p "$dest_dir"
  echo "▶︎ ${artist_clean} — ${venue_clean} - ${date_out}"

  # 1) Convert FLAC → MP3 320 into dest (keep base names)
  for fl in "$showdir"/*.flac; do
    mp3="${dest_dir}/${fl:t:r}.mp3"
    echo "   • Converting: ${fl:t} → ${mp3:t}"
    [[ $DRY_RUN -eq 1 ]] || ffmpeg -loglevel error -y -i "$fl" -vn \
      -c:a libmp3lame -b:a 320k -map_metadata 0 "$mp3"
  done

  # 2) Move any MP3s that already exist in source
  for m in "$showdir"/*.mp3; do
    echo "   • Moving MP3: ${m:t}"
    [[ $DRY_RUN -eq 1 ]] || mv -n "$m" "$dest_dir/"
  done

  # 3) Tag/rename MP3s in dest
  cover="$(pick_cover "$showdir")"; [[ -z "$cover" ]] && cover="$(pick_cover "$dest_dir")"
  track_re='^([0-9]{1,2})[[:space:]]*[-_.][[:space:]]*(.*)\.mp3$'
  i=1
  for f in "$dest_dir"/*.mp3(N); do
    base="${f:t}"; title="${base%.*}"; track=""
    if [[ "$base" =~ $track_re ]]; then
      track="${match[1]}"; title="${match[2]}"
    else
      track=$(printf "%02d" $i); i=$((i+1))
      new="${f:h}/${track} - ${title}.mp3"
      echo "   • Renaming: ${base} → ${new:t}"
      [[ $DRY_RUN -eq 1 ]] || mv -n "$f" "$new"
      f="$new"
    fi
    title="$(trim "$title")"
    args=(--artist "$artist_clean" --album "${venue_clean} - ${date_out}" --album-artist "$artist_clean" --genre "Live"
          --recording-date "$year" --release-year "$year" --track "$track" --title "$title")
    if [[ $DRY_RUN -eq 0 ]]; then
      if [[ -n "$cover" ]]; then
        "$EYE_D3" --quiet --add-image "$cover:FRONT_COVER" "${args[@]}" "$f" >/dev/null || true
      else
        "$EYE_D3" --quiet "${args[@]}" "$f" >/dev/null || true
      fi
    fi
  done

  # 4) Album gain (lossless frame gain + APEv2 tags)
  if ls "$dest_dir"/*.mp3 >/dev/null 2>&1; then
    echo "   • mp3gain (album mode)"
    [[ $DRY_RUN -eq 1 ]] || (mp3gain -a -k -q "$dest_dir"/*.mp3 >/dev/null 2>&1 || true)
  fi

  # 5) Extras + cleanup
  for ext in jpg JPG png PNG txt TXT; do
    for a in "$showdir"/*.$ext; do
      [[ -e "$a" ]] || continue
      echo "   • Moving extra: ${a:t}"
      [[ $DRY_RUN -eq 1 ]] || mv -n "$a" "$dest_dir/"
    done
  done
  for fl in "$showdir"/*.flac; do
    echo "   • Deleting FLAC: ${fl:t}"
    [[ $DRY_RUN -eq 1 ]] || rm -f "$fl"
  done
  [[ $DRY_RUN -eq 1 ]] || rmdir "$showdir" 2>/dev/null || true

  echo "✅  ${artist_clean}/${venue_clean} - ${date_out}"
done