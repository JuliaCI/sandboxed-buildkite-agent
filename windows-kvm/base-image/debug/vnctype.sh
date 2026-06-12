#!/bin/bash
# Type over VNC in one vncdo invocation. qemu's VNC drops the implicit shift
# for punctuation/digit keysyms, so force it with explicit keydown/keyup shift
# around the base key.
S="$1"; STR="$2"; TRAILING="${3:-}"
A=()
shifted() { A+=(keydown shift pause 0.03 key "$1" pause 0.03 keyup shift pause 0.05); }
plain()   { A+=(key "$1" pause 0.05); }
for ((i=0; i<${#STR}; i++)); do
  c="${STR:$i:1}"
  case "$c" in
    [a-z0-9]) plain "$c" ;;
    [A-Z]) shifted "$(echo "$c" | tr A-Z a-z)" ;;
    " ") plain space ;;  "-") plain minus ;;  ".") plain period ;;
    "/") plain slash ;;  ";") plain semicolon ;;  "\\") plain backslash ;;
    ",") plain comma ;;  "'") plain apostrophe ;;  "=") plain equal ;;
    ":") shifted semicolon ;;  '"') shifted apostrophe ;;  "_") shifted minus ;;
    "$") shifted 4 ;;  "(") shifted 9 ;;  ")") shifted 0 ;;  "|") shifted backslash ;;
    "%") shifted 5 ;;  "~") shifted grave ;;  "@") shifted 2 ;;  "+") shifted equal ;;
    "*") shifted 8 ;;  "&") shifted 7 ;;  "{") shifted bracketleft ;;  "}") shifted bracketright ;;
    *) echo "unmapped: $c" >&2 ;;
  esac
done
[[ -n "$TRAILING" ]] && A+=(key "$TRAILING")
~/.local/bin/vncdo -s "$S" "${A[@]}"
