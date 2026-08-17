#!/bin/bash
# bashauma: winner popup
#
# Renders a short 🎉/🎊 confetti animation. Exits (closing the popup) on any
# keypress, or automatically after a few seconds.
set -euo pipefail

MESSAGES=(
    "Board cleared!"
    "Nice work!"
    "Everyone's got a task!"
    "You did it!"
    "Round complete!"
)
MESSAGE="${MESSAGES[$RANDOM % ${#MESSAGES[@]}]}"

CONFETTI=("🎉" "🎊" "✨" "🎈")
COLS=$(tput cols 2>/dev/null || echo 40)
ROWS=$(tput lines 2>/dev/null || echo 10)

# Confetti emoji render two terminal cells wide, so a row holds half as many
# of them as there are columns. Build rows in 2-cell slots (emoji, or two
# spaces) to keep frames from overflowing and wrapping on narrow popups.
SLOTS=$((COLS / 2))
((SLOTS < 1)) && SLOTS=1

cleanup() {
    tput cnorm 2>/dev/null || true
    clear
}
trap cleanup EXIT

tput civis 2>/dev/null || true
clear

FRAMES=40
FRAME_DELAY=0.1
for ((frame = 0; frame < FRAMES; frame++)); do
    clear
    for ((row = 0; row < ROWS - 2; row++)); do
        line=""
        for ((slot = 0; slot < SLOTS; slot++)); do
            if (((row * 7 + slot * 3 + frame) % 11 == 0)); then
                line+="${CONFETTI[$((RANDOM % ${#CONFETTI[@]}))]}"
            else
                line+="  "
            fi
        done
        printf '%s\n' "$line"
    done
    mid_row=$((ROWS / 2))
    pad=$(((COLS - ${#MESSAGE} - 6) / 2))
    ((pad < 0)) && pad=0
    tput cup "$mid_row" "$pad" 2>/dev/null || true
    printf '🎉 %s 🎉' "$MESSAGE"

    # Sleep out the frame delay, but bail out immediately on any keypress
    # (non-blocking poll first, so a closed/non-tty stdin never blocks or
    # skips the delay).
    if read -r -s -n 1 -t 0 _key 2>/dev/null; then
        break
    fi
    sleep "$FRAME_DELAY"
done
