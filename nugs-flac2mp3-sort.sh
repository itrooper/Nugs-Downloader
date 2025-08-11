#!/usr/bin/env zsh
set -euo pipefail

# ===== CONFIG =====
SRC="/Volumes/data/downloads/music/nugs"
DEST_BASE="/Volumes/data/media/music/nuggs"
DRY_RUN=0
EYE_D3="/opt/homebrew/Cellar/eye-d3/0.9.8/bin/eyeD3"   # change if needed

# ===== deps =====
SED="${SED:-$(command -v gsed || command -v sed || true)}"
[[ -n "${SED:-}" ]] || { echo "Need sed/gsed"; exit 1; }
need() { if [[ "$1" == /* ]]; then [[ -x "$1" ]] || { echo "Missing: $1"; exit 1; }; else command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; fi }
need ffmpeg
need mp3gain
need "$EYE_D3"
[[ -d "$SRC" ]] || { echo "Source not found: $SRC"; exit 1; }
mkdir -p "$DEST_BASE"

# zsh nullglob (bash shopt equivalent)
setopt NULL_GLOB

# ===== helpers =====
normalize_delims() { "$SED" 's/ – / - /g; s/ — / - /g'; }
fmt_date_iso_to_mmddyyyy() { date -jf "%Y-%m-%d" "$1" "+%m-%d-%Y" 2>/dev/null || printf "%s" "$1"; }
clean_component() {
  print -r -- "$1" | "$SED" '
    s~/~, ~g; s/[[:cntrl:]]//g; s/[*?<>|"]//g;
    s/[[:space:]]\{1,\}$//; s/^[[:space:]]\{1,\}//; s/[[:space:]]\{2,\}/ /g;'
}
pick_cover() { local d="$1"; for c in cover.jpg Cover.jpg COVER.jpg folder.jpg Folder.jpg FOLDER.jpg cover.png Cover.png; do [[ -f "$d/$c" ]] && { print -r -- "$d/$c"; return; }; done }

# Extract tags from first media file if folder parsing is ambiguous
probe_tags() {
  local f="$1"
  local v; v=($(ffprobe -v error -select_streams a:0 -show_entries format_tags=artist,album,date \
               -of default=nw=1:nk=1 "$f" 2>/dev/null || true))
  # ffprobe prints each value on its own line in order artist/album/date
  print -r -- "${v[1]:-}" "${v[2]:-}" "${v[3]:-}"
}

# Robust folder parser
parse_showdir() {
  local base="$1"
  local norm="$(print -r -- "$base" | normalize_delims)"
  local -a toks; IFS=$'\n' toks=($(print -r -- "$norm" | awk -F' - ' '{for(i=1;i<=NF;i++)print $i}'))
  local raw_date="" artist="" venue=""
  for t in "${toks[@]}"; do
    if [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then raw_date="$t"; continue; fi
    if [[ "$t" =~ ^[0-9]{2}[_-][0-9]{2}[_-]([0-9]{2}|[0-9]{4})$ ]]; then
      # convert 08_02_25 → 2025-08-02 best effort
      local m="${t:0:2}"; local d="${t:3:2}"; local y="${t:6}"
      [[ ${#y} -eq 2 ]] && y="20$y"
      raw_date="$y-$m-$d"
      continue
    fi
  done
  # Guess the rest: take the longest alpha token as venue, another as artist
  local -a rest; for t in "${toks[@]}"; do [[ "$t" != "$raw_date" && -n "$t" ]] && rest+=("$t"); done
  if (( ${#rest[@]} >= 2 )); then
    # prefer token with comma as venue
    for t in "${rest[@]}"; do [[ "$t" == *","* ]] && venue="$t"; done
    [[ -z "$venue" ]] && venue="${rest[-1]}"
    for t in "${rest[@]}"; do [[ "$t" != "$venue" ]] && { artist="$t"; break; }; done
  elif (( ${#rest[@]} == 1 )); then
    artist="${rest[1]}"; venue="Unknown Venue"
  fi
  print -r -- "$raw_date" "$artist" "$venue"
}

echo "Scanning: $SRC"
for showdir in "$SRC"/*(/); do
  showbase="${showdir:t}"
  # Try folder parse
  parts=($(parse_showdir "$showbase"))
  raw_date="${parts[1]:-}"
  artist="${parts[2]:-}"
  venue="${parts[3]:-}"

  # If date/artist/venue look weak, probe first media file
  test_file=""
  for f in "$showdir"/*.flac "$showdir"/*.mp3; do test_file="$f"; break; done
  if [[ -n "$test_file" ]]; then
    tags=($(probe_tags "$test_file"))
    [[ -z "$artist" && -n "${tags[1]:-}" ]] && artist="${tags[1]}"
    # album often like "YYYY-MM-DD Venue, City, ST" → peel date & venue
    if [[ -z "$venue" && -n "${tags[2]:-}" ]]; then
      alb="${tags[2]}"
      # try to split album into date + venue
      if [[ "$alb" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+(.+)$ ]]; then
        [[ -z "$raw_date" ]] && raw_date="${match[1]}"
        venue="${match[2]}"
      else
        venue="$alb"
      fi
    fi
    [[ -z "$raw_date" && -n "${tags[3]:-}" ]] && raw_date="${tags[3]}"
  fi

  # Defaults if still missing
  [[ -z "$artist" ]] && artist="Unknown Artist"
  [[ -z "$venue"  ]] && venue="Unknown Venue"

  dest_date="$(fmt_date_iso_to_mmddyyyy "$raw_date")"
  artist_clean="$(clean_component "$artist")"
  venue_clean="$(clean_component "$venue")"
  album_dir="${venue_clean} - ${dest_date}"
  dest_dir="${DEST_BASE}/${artist_clean}/${album_dir}"
  [[ $DRY_RUN -eq 1 ]] || mkdir -p "$dest_dir"

  echo "▶︎ Processing: $artist_clean — $album_dir"

  # Convert FLAC -> MP3 (keep base names)
  for f in "$showdir"/*.flac; do
    mp3="${dest_dir}/${f:t:r}.mp3"
    echo "   • Converting: ${f:t} → ${mp3:t}"
    [[ $DRY_RUN -eq 1 ]] || ffmpeg -loglevel error -y -i "$f" -vn -c:a libmp3lame -b:a 320k -map_metadata 0 "$mp3"
  done

  # Move any existing MP3s in source into dest
  for m in "$showdir"/*.mp3; do
    echo "   • Moving MP3: ${m:t}"
    [[ $DRY_RUN -eq 1 ]] || mv -n "$m" "$dest_dir/"
  done

  # Tag/rename
  cover="$(pick_cover "$showdir")"; [[ -z "$cover" ]] && cover="$(pick_cover "$dest_dir")"
  year="${raw_date:0:4}"
  track_re='^([0-9]{1,2})[[:space:]]*[-_.][[:space:]]*(.*)\.mp3$'
  i=1
  for f in "$dest_dir"/*.mp3; do
    base="${f:t}"
    title="${base%.*}"
    track=""
    if [[ "$base" =~ $track_re ]]; then
      track="${match[1]}"; title="${match[2]}"
    else
      track=$(printf "%02d" $i); i=$((i+1))
      new="${f:h}/${track} - ${title}.mp3"
      echo "   • Renaming: ${base} → ${new:t}"
      [[ $DRY_RUN -eq 1 ]] || mv -n "$f" "$new"
      f="$new"
    fi
    title="$(print -r -- "$title" | "$SED" 's/^[[:space:]-]*//; s/[[:space:]]+$//')"
    args=(--artist "$artist_clean" --album "$album_dir" --album-artist "$artist_clean" --genre "Live")
    [[ -n "$year" ]]  && args+=(--recording-date "$year" --release-year "$year")
    [[ -n "$track" ]] && args+=(--track "$track")
    [[ -n "$title" ]] && args+=(--title "$title")
    if [[ $DRY_RUN -eq 0 ]]; then
      if [[ -n "$cover" ]]; then "$EYE_D3" --quiet --add-image "$cover:FRONT_COVER" "${args[@]}" "$f" >/dev/null || true
      else "$EYE_D3" --quiet "${args[@]}" "$f" >/dev/null || true; fi
    fi
  done

  # Album gain
  if ls "$dest_dir"/*.mp3 >/dev/null 2>&1; then
    echo "   • mp3gain (album mode)"
    [[ $DRY_RUN -eq 1 ]] || (mp3gain -a -k -q "$dest_dir"/*.mp3 >/dev/null 2>&1 || true)
  fi

  # Extras + cleanup
  for ext in jpg JPG png PNG txt TXT; do for a in "$showdir"/*.$ext; do [[ -e "$a" ]] && { echo "   • Moving extra: ${a:t}"; [[ $DRY_RUN -eq 1 ]] || mv -n "$a" "$dest_dir/"; }; done; done
  for f in "$showdir"/*.flac; do echo "   • Deleting FLAC: ${f:t}"; [[ $DRY_RUN -eq 1 ]] || rm -f "$f"; done
  [[ $DRY_RUN -eq 1 ]] || rmdir "$showdir" 2>/dev/null || true

  echo "✅  ${artist_clean}/${album_dir}"
done