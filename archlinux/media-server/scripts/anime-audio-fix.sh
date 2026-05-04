#!/bin/bash

# Only run for anime
if [[ "$sonarr_series_tags" != *"anime"* ]]; then
    exit 0
fi

MEDIA_PATH="$sonarr_episodefile_path"
[[ "$MEDIA_PATH" != *.mkv ]] && exit 0

# Find first Japanese audio track
JP_AUDIO_TRACK=$(ffprobe -v error \
  -select_streams a \
  -show_entries stream=index:stream_tags=language \
  -of default=noprint_wrappers=1:nokey=1 "$MEDIA_PATH" | \
  paste - - | awk '$2 ~ /^jpn$/ {print $1; exit}')

# Find first English subtitle track
EN_SUB_TRACK=$(ffprobe -v error \
  -select_streams s \
  -show_entries stream=index:stream_tags=language \
  -of default=noprint_wrappers=1:nokey=1 "$MEDIA_PATH" | \
  paste - - | awk '$2 ~ /^eng$/ {print $1; exit}')

# Clear all audio/subtitle default flags
CMD=(mkvpropedit "$MEDIA_PATH")
for i in {1..5}; do
    CMD+=(--edit track:a$i --set flag-default=0)
    CMD+=(--edit track:s$i --set flag-default=0 --set flag-forced=0)
done

# Set Japanese audio default (if found)
if [[ -n "$JP_AUDIO_TRACK" ]]; then
    CMD+=(--edit track:a$((JP_AUDIO_TRACK + 1)) --set flag-default=1)
fi

# Set English subs default (if found)
if [[ -n "$EN_SUB_TRACK" ]]; then
    CMD+=(--edit track:s$((EN_SUB_TRACK + 1)) --set flag-default=1 --set flag-forced=0)
fi

"${CMD[@]}"

