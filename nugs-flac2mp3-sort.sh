#!/usr/bin/env zsh
set -euo pipefail

# =========================
# CONFIG (edit if needed)
# =========================
# Where Nugs-Downloader saves files (mounted NAS on your Mac):
SRC="/Volumes/data/downloads/music/nugs"
# Final MP3 library root (mounted NAS on your Mac):
DEST_BASE="/Volumes/data/media/music/nuggs"
# Set to 1 to simulate (no file changes)
DRY_RUN=0

# Hardcode eye-d3 path (change if your install lives elsewhere)
EYE_D3="/opt/homebrew/Cellar/eye-d3/0.9.8/bin/eyeD3"

# =========================
# DEP CHECKS
# =========================
# Choose GNU sed if present, else BSD sed
SED="${SED:-$(command -v gsed || command -v sed || true)}"
if [[ -z "${SED:-}" ]]; then
  echo "Error: neither gsed nor sed found. Try: brew install gnu-sed"; exit 1
fi

need() {
  # Accept either a command name or a full path
  if [[ "$1" == /* ]]; then
    [[ -x "$1" ]] || { echo "Missing dependency (not executable): $1"; exit 1; }
  else
    command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
  fi
}

need ffmpeg
need mp3gain
need "$EYE_D3"

[[ -d "$SRC" ]] || { echo "Source not found: $SRC"; exit 1; }
mkdir -p "$DEST_BASE"

# =========================
# HELPERS
# =========================
normalize_delims() { "$SED" 's/ – / - /g; s/ — / - /g'; }

# Convert YYYY-MM-DD -> 08-02-2025 (zero-padded); if parse fails, echo as-is
fmt_date() { date -jf "%Y-%m-%d" "$1" "+%m-%d-%Y" 2>/dev/null || printf "%s" "$1"; }

# Clean folder components: replace slashes with ", ", strip weird chars, tidy spaces
clean_component() {
  print -r -- "$1" | "$SED" '
    s~/~, ~g;
    s/[[:cntrl:]]//g;
    s/[*?<>|"]//g;
    s/[[:space:]]\{1,\}$//;  s/^[[:space:]]\{1,\}//;
    s/[[:space:]]\{2,\}/ /g;
  '
}

pick_cover() {
  local dir="$1"
  for c in cover.jpg Cover.jpg COVER.jpg folder.jpg Folder.jpg FOLDER.jpg cover.png Cover.png; do
    [[ -f "$dir/$c" ]] && { print -r -- "$dir/$c"; return; }
  done
}

# =========================
# MAIN
# =========================
echo "Scanning: $SRC"
# Expect folders like: "YYYY-MM-DD - Artist - Venue, City, ST"
find "$SRC" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r showdir; do
  showbase="${showdir:t}"

  # Split into date / artist / venue (supports en/em dash or hyphen)
  IFS=$'\n' parts=($(print -r -- "$showbase" | normalize_delims | awk -F' - ' '{print $1"\n"$2"\n"$3}'))
  raw_date="${parts[1]:-}"
  artist="${parts[2]:-Unknown Artist}"
  venue="${parts[3]:-Unknown Venue}"

  dest_date="$(fmt_date "$raw_date")"           # e.g., 08-02-2025
  artist_clean="$(clean_component "$artist")"
  venue_clean="$(clean_component "$venue")"

  album_dir="${venue_clean} - ${dest_date}"
  dest_dir="${DEST_BASE}/${artist_clean}/${album_dir}"
  [[ $DRY_RUN -eq 1 ]] || mkdir -p "$dest_dir"

  echo "▶︎ Processing: $artist_clean — $album_dir"

  shopt -s nullglob
  flacs=("$showdir"/*.flac)
  mp3s_in_src=("$showdir"/*.mp3)

  # ---- 1) Convert FLAC -> MP3 320 (preserve tags) ----
  for f in "${flacs[@]}"; do
    base="${f:t}"
    mp3="${dest_dir}/${base%.flac}.mp3"
    echo "   • Converting: ${base} → ${mp3:t}"
    if [[ $DRY_RUN -eq 0 ]]; then
      ffmpeg -loglevel error -y \
        -i "$f" -vn -c:a libmp3lame -b:a 320k -map_metadata 0 "$mp3"
    fi
  done

  # Move any pre-existing MP3s in the source into the dest
  for m in "${mp3s_in_src[@]}"; do
    echo "   • Moving MP3: ${m:t}"
    [[ $DRY_RUN -eq 1 ]] || mv -n "$m" "$dest_dir/"
  done

  # ---- 2) Tag/rename MP3s in destination ----
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

    # Tidy title spacing
    title="$(print -r -- "$title" | "$SED" 's/^[[:space:]-]*//; s/[[:space:]]+$//' )"

    args=(--artist "$artist_clean" --album "$album_dir" --album-artist "$artist_clean" --genre "Live")
    [[ -n "$year" ]]  && args+=(--recording-date "$year" --release-year "$year")
    [[ -n "$track" ]] && args+=(--track "$track")
    [[ -n "$title" ]] && args+=(--title "$title")

    if [[ $DRY_RUN -eq 0 ]]; then
      if [[ -n "$cover" ]]; then
        "$EYE_D3" --quiet --add-image "$cover:FRONT_COVER" "${args[@]}" "$f" >/dev/null || true
      else
        "$EYE_D3" --quiet "${args[@]}" "$f" >/dev/null || true
      fi
    fi
  done

  # ---- 3) Album gain with mp3gain (lossless frame gain + APEv2 tags) ----
  if compgen -G "$dest_dir/*.mp3" > /dev/null; then
    echo "   • mp3gain (album mode)"
    [[ $DRY_RUN -eq 1 ]] || (mp3gain -a -k -q "$dest_dir"/*.mp3 >/dev/null 2>&1 || true)
  fi

  # ---- 4) Bring over artwork/notes ----
  for ext in jpg JPG png PNG txt TXT; do
    for a in "$showdir"/*.$ext; do
      [[ -e "$a" ]] || continue
      echo "   • Moving extra: ${a:t}"
      [[ $DRY_RUN -eq 1 ]] || mv -n "$a" "$dest_dir/"
    done
  done

  # ---- 5) Cleanup source: remove FLACs and delete empty show folder ----
  for f in "${flacs[@]}"; do
    echo "   • Deleting FLAC: ${f:t}"
    [[ $DRY_RUN -eq 1 ]] || rm -f "$f"
  done
  if [[ $DRY_RUN -eq 0 ]]; then
    rmdir "$showdir" 2>/dev/null || true
  fi

  echo "✅  ${artist_clean}/${album_dir}"
done