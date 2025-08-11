#!/usr/bin/env zsh
set -euo pipefail

# Where the downloader drops shows (mounted NAS on your Mac):
SRC="/Volumes/data/downloads/music/nugs"
# Final library location (mounted NAS on your Mac):
DEST_BASE="/Volumes/data/media/music/nuggs"

# ---- helpers ----
normalize_delims() { gsed 's/ – / - /g; s/ — / - /g'; }

# Convert YYYY-MM-DD -> 08-02-2025 (zero-padded)
fmt_date() {
  local iso="$1"
  date -jf "%Y-%m-%d" "$iso" "+%m-%d-%Y" 2>/dev/null || echo "$iso"
}

# Clean folder components: replace slashes with ", ", strip weird chars
clean_component() {
  print -r -- "$1" | gsed '
    s~/~, ~g;                 # slashes -> ", "
    s/[[:cntrl:]]//g;         # remove control chars
    s/[*?<>|"]//g;            # strip Win-problem chars
    s/[[:space:]]\{1,\}$//;   # trim end
    s/^[[:space:]]\{1,\}//;   # trim start
    s/[[:space:]]\{2,\}/ /g;  # collapse spaces
  '
}

pick_cover() {
  local dir="$1"
  for c in cover.jpg Cover.jpg COVER.jpg folder.jpg Folder.jpg FOLDER.jpg cover.png Cover.png; do
    [[ -f "$dir/$c" ]] && { print -r -- "$dir/$c"; return; }
  done
}

[[ -d "$SRC" ]] || { echo "Source not found: $SRC"; exit 1; }
mkdir -p "$DEST_BASE"

# Expect show folders like:
#   "2025-08-02 - Johnny Blue Skies - Golden Gate Park, San Francisco, CA"
find "$SRC" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r showdir; do
  showbase="${showdir:t}"
  IFS=$'\n' parts=($(print -r -- "$showbase" | normalize_delims | awk -F' - ' '{print $1"\n"$2"\n"$3}'))
  raw_date="${parts[1]:-}"                    # 2025-08-02
  artist="${parts[2]:-Unknown Artist}"        # Johnny Blue Skies
  venue="${parts[3]:-Unknown Venue}"          # Golden Gate Park, San Francisco, CA

  # Build destination
  dest_date="$(fmt_date "$raw_date")"         # 08-02-2025
  artist_clean="$(clean_component "$artist")"
  venue_clean="$(clean_component "$venue")"
  album_dir="${venue_clean} - ${dest_date}"
  dest_dir="${DEST_BASE}/${artist_clean}/${album_dir}"
  mkdir -p "$dest_dir"

  echo "▶︎ Processing: $artist_clean — $album_dir"

  # Move MP3s + artwork/notes
  shopt -s nullglob
  for f in "$showdir"/*.mp3; do mv -n "$f" "$dest_dir/"; done
  for ext in jpg JPG png PNG txt TXT; do
    for a in "$showdir"/*.$ext; do [[ -e "$a" ]] && mv -n "$a" "$dest_dir/"; done
  done

  # Tagging
  cover="$(pick_cover "$dest_dir")"
  year="${raw_date:0:4}"
  track_re='^([0-9]{1,2})[[:space:]]*[-_.][[:space:]]*(.*)\.mp3$'
  i=1
  for f in "$dest_dir"/*.mp3(N); do
    base="${f:t}"
    title="${base%.*}"
    track=""
    if [[ "$base" =~ $track_re ]]; then
      track="${match[1]}"
      title="${match[2]}"
    else
      track=$(printf "%02d" $i); i=$((i+1))
      title="${title}"
      mv -n "$f" "${f:h}/${track} - ${title}.mp3"
      f="${f:h}/${track} - ${title}.mp3"
    fi

    title="$(print -r -- "$title" | gsed 's/^[[:space:]-]*//; s/[[:space:]]+$//')"

    args=(--artist "$artist_clean" --album "$album_dir" --album-artist "$artist_clean" --genre "Live")
    [[ -n "$year" ]]  && args+=(--recording-date "$year" --release-year "$year")
    [[ -n "$track" ]] && args+=(--track "$track")
    [[ -n "$title" ]] && args+=(--title "$title")

    if [[ -n "$cover" ]]; then
      eyeD3 --quiet --add-image "$cover:FRONT_COVER" "${args[@]}" "$f" >/dev/null || true
    else
      eyeD3 --quiet "${args[@]}" "$f" >/dev/null || true
    fi
  done

  # Album gain with mp3gain (lossless frame gain + APEv2 tags)
  (mp3gain -a -k -q "$dest_dir"/*.mp3 >/dev/null 2>&1 || true)

  echo "✅  ${artist_clean}/${album_dir}"
done