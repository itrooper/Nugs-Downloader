#!/usr/bin/env zsh
set -euo pipefail

# Make sure ffmpeg is installed
command -v ffmpeg >/dev/null 2>&1 || { echo "Error: ffmpeg not found. Install via 'brew install ffmpeg'"; exit 1; }

# Find all .flac files
find . -type f -iname "*.flac" | while IFS= read -r flacfile; do
    # Get parent directory of the flac file
    parent_dir="$(dirname "$flacfile")"
    # Make 'converted' subfolder inside the same directory
    dest_dir="${parent_dir}/converted"
    mkdir -p "$dest_dir"

    # Output file name with .mp3 extension
    mp3file="${dest_dir}/$(basename "${flacfile%.*}.mp3")"

    echo "Converting: $flacfile -> $mp3file"
    ffmpeg -loglevel error -y -i "$flacfile" -vn -c:a libmp3lame -b:a 320k "$mp3file"
done

echo "✅ All FLAC files converted to MP3 320 in 'converted' subfolders."