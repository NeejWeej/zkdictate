#!/bin/bash
cd "$(dirname "$0")" || exit 1
status=0
/bin/bash ./install.sh "$@" || status=$?
if [[ "$status" -eq 0 ]]; then
  echo "ZK Dictate is installed. You can close this window."
else
  echo "Installation stopped. Follow the instructions above, then run this installer again."
fi
read -r -p "Press Return to finish." _ || true
exit "$status"
