#!/bin/bash

# Exit if tagged
if [[ -n "$sonarr_series_tags" ]]; then
    exit 0
fi

MEDIA_PATH="$sonarr_episodefile_path"

# Only process .mkv files
[[ "$MEDIA_PATH" != *.mkv ]] && exit 0

# Get the track indices of English audio tracks
ENGLISH_AUDIO_TRACK=$(ffprobe -v error \
  -select_streams a \
  -show_entries stream=index:stream_tags=language \
  -of default=noprint_wrappers=1:nokey=1 "$MEDIA_PATH" | \
  paste - - | awk '$2 ~ /^eng$/ {print $1; exit}')

# Exit if no English audio found
if [[ -z "$ENGLISH_AUDIO_TRACK" ]]; then
    echo "No English audio track found in: $MEDIA_PATH"
    exit 0
fi

# Clear default flags for all audio and subtitle tracks
mkvpropedit "$MEDIA_PATH" \
  --edit track:a1 --set flag-default=0 \
  --edit track:a2 --set flag-default=0 \
  --edit track:a3 --set flag-default=0 \
  --edit track:s1 --set flag-default=0 \
  --edit track:s2 --set flag-default=0

# Set the detected English audio track as default
mkvpropedit "$MEDIA_PATH" \
  --edit track:a$((ENGLISH_AUDIO_TRACK + 1)) --set flag-default=1

