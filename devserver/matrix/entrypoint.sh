#!/bin/sh
# First start: generate a config for server_name "localhost", append dev.yaml,
# then register the test accounts once Synapse answers.
set -e
if [ ! -f /data/homeserver.yaml ]; then
  SYNAPSE_SERVER_NAME=localhost SYNAPSE_REPORT_STATS=no /start.py generate
  cat /dev.yaml >> /data/homeserver.yaml
fi
/start.py &
synapse=$!
if [ ! -f /data/.seeded ]; then
  until python -c "import urllib.request; urllib.request.urlopen('http://localhost:8008/health')" 2>/dev/null; do sleep 1; done
  for user in alice bob carol; do
    register_new_matrix_user -c /data/homeserver.yaml -u "$user" -p 123456 --no-admin http://localhost:8008 || true
  done
  touch /data/.seeded
fi
wait "$synapse"
