import os

DB = 'sqlite:////data/escargot.sqlite'
STATS_DB = 'sqlite:////data/stats.sqlite'

# Host advertised to clients in XFR/RNG switchboard redirects. The macOS client
# connects to this name, so it must resolve from the host (not the container).
TARGET_HOST = os.environ.get('TARGET_HOST', '127.0.0.1')
LOGIN_HOST = TARGET_HOST
STORAGE_HOST = TARGET_HOST

DEBUG = True
DEBUG_MSNP = True
DEBUG_HTTP_REQUEST = True
DEBUG_HTTP_REQUEST_FULL = os.environ.get('DEBUG_HTTP_REQUEST_FULL') == '1'
