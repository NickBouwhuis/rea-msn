#!/bin/sh
set -e
cd /srv/escargot
export PYTHONPATH=/srv/escargot
mkdir -p /data
if [ ! -f /data/escargot.sqlite ]; then
  # script/dbcreate.py also records fake sqlaltery migrations, which fails with
  # the published sqlaltery; a fresh database only needs the tables.
  python -c "
from core import db, stats
from core.conn import Conn
import settings
db.Base.metadata.create_all(Conn(settings.DB).engine)
stats.Base.metadata.create_all(Conn(settings.STATS_DB).engine)
"
  python script/seed_users.py
fi
exec python -u run_all.py
