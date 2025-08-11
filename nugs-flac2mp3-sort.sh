#!/usr/bin/env zsh
set -euo pipefail

# ----- CONFIG -----
SRC="/Volumes/data/downloads/music/nugs"
DEST_BASE="/Volumes/data/media/music/nuggs"
# set to 1 for a dry run (no file changes)
DRY_RUN=0

# ----- HELPERS -----
normalize_delims() { gnu-sed -E 's/ – / - /g; s/ — / - /g'; }
fmt_date() { date -jf "%Y-%m-%d" "$1" "+%m-%d-%Y" 2>/dev/null || printf "%s" "$1"; }
clean_component() {
  print -r -- "$1" | gnu-sed '
    s~/~, ~g;
    s/[[:cntrl:]]//g;
    s/[*?<>|"]//g;
    s/[[:space:]]+$//; s/^[[:space:]]+//; s/[[:space:]]{2,}/ /g;
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
# "YYYY-MM-DD - Artist - Venue, City, ST"
find "$SRC" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r showdir; do
  showbase="${showdir:t}"
  IFS=$'\n' parts=($(print -r -- "$showbase" | normalize_delims | awk -F' - ' '{print $1"\n"$2"\n"$3}'))
  raw_date="${parts[1]:-}"
  artist="${parts[2]:-Unknown Artist}"
  venue="${parts[3]:-Unknown Venue}"

  # Build destination folder pieces
  dest_date="$(fmt_date "$raw_date")"
  artist_clean="$(clean_component "$artist")"
  venue_clean="$(clean_component "$venue")"
  album_dir="${venue_clean} - ${dest_date}"
  dest_dir="${DEST_BASE}/${artist_clean}/${album_dir}"
  [[ $DRY_RUN -eq 1 ]] || mkdir -p "$dest_dir"

  echo "▶︎ Processing: $artist_clean — $album_dir"

  shopt -s nullglob
  flacs=("$showdir"/*.flac)
  mp3s_in_src=("$showdir"/*.mp3)

  # 1) Convert FLAC → MP3 320 (preserve tags); keep filename base
  for f in "${flacs[@]}"; do
    mp3="${dest_dir}/$(basename "${f%.flac}.mp3")"
    echo "   • Converting: ${f:t} → ${mp3:t}"
    if [[ $DRY_RUN -eq 0 ]]; then
      ffmpeg -loglevel error -y \
        -i "$f" -vn -c:a libmp3lame -b:a 320k -map_metadata 0 "$mp3"
    fi
  done

  # If there were already MP3s (e.g., AAC/ALAC -> you converted earlier), move them in
  for m in "${mp3s_in_src[@]}"; do
    echo "   • Moving MP3: ${m:t}"
    [[ $DRY_RUN -eq 1 ]] || mv -n "$m" "$dest_dir/"
  done

  # 2) Tag/rename MP3s in destination
  cover="$(pick_cover "$showdir")"
  [[ -z "$cover" ]] && cover="$(pick_cover "$dest_dir")"
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
      new="${f:h}/${track} - ${title}.mp3"
      echo "   • Renaming: ${base} → ${new:t}"
      [[ $DRY_RUN -eq 1 ]] || mv -n "$f" "$new"
      f="$new"
    fi
    title="$(print -r -- "$title" | gnu-sed 's/^[[:space:]-]*//; s/[[:space:]]+$//' )"

    args=(--artist "$artist_clean" --album "$album_dir" --album-artist "$artist_clean" --genre "Live")
    [[ -n "$year" ]]  && args+=(--recording-date "$year" --release-year "$year")
    [[ -n "$track" ]] && args+=(--track "$track")
    [[ -n "$title" ]] && args+=(--title "$title")

    if [[ $DRY_RUN -eq 0 ]]; then
      if [[ -n "$cover" ]]; then
        eyeD3 --quiet --add-image "$cover:FRONT_COVER" "${args[@]}" "$f" >/dev/null || true
      else
        eyeD3 --quiet "${args[@]}" "$f" >/dev/null || true
      fi
    fi
  done

  # 3) Album gain with mp3gain (lossless frame gain + APEv2 tags)
  if compgen -G "$dest_dir/*.mp3" > /dev/null; then
    echo "   • mp3gain (album mode)"
    [[ $DRY_RUN -eq 1 ]] || (mp3gain -a -k -q "$dest_dir"/*.mp3 >/dev/null 2>&1 || true)
  fi

  # 4) Bring over artwork/notes
  for ext in jpg JPG png PNG txt TXT; do
    for a in "$showdir"/*.$ext; do
      [[ -e "$a" ]] || continue
      echo "   • Moving extra: ${a:t}"
      [[ $DRY_RUN -eq 1 ]] || mv -n "$a" "$dest_dir/"
    done
  done

  # 5) Cleanup source: remove FLACs and delete empty show folder
  for f in "${flacs[@]}"; do
    echo "   • Deleting FLAC: ${f:t}"
    [[ $DRY_RUN -eq 1 ]] || rm -f "$f"
  done
  # if folder empty after cleanup, remove it
  if [[ $DRY_RUN -eq 0 ]]; then
    rmdir "$showdir" 2>/dev/null || true
  fi

  echo "✅  ${artist_clean}/${album_dir}"
done