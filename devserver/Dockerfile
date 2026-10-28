# Local Escargot-compatible MSN server for testing the macOS port.
# Source: https://gitlab.com/escargot-chat/server (CC BY-NC 4.0), pinned to the
# last public master commit. Dependencies are pinned to early-2021 releases
# because the code predates SQLAlchemy 1.4 / aiohttp 3.8 / Jinja2 3.
FROM python:3.8-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends git build-essential libxml2-dev libxslt1-dev \
 && rm -rf /var/lib/apt/lists/*

ARG ESCARGOT_COMMIT=9cddb9cfad3e9b09b483527798d7ac37533422a3
RUN git clone https://gitlab.com/escargot-chat/server.git /srv/escargot \
 && cd /srv/escargot && git checkout ${ESCARGOT_COMMIT}

WORKDIR /srv/escargot
RUN pip install --no-cache-dir \
      'aiohttp==3.7.4.post0' 'SQLAlchemy==1.3.23' 'Jinja2==2.11.3' 'MarkupSafe==1.1.1' \
      'lxml==4.6.3' 'Pillow==8.1.2' 'cryptography==3.4.7' 'pytz==2021.1' \
      'python-dateutil==2.8.1' 'funcli==0.7.0' 'HLL==1.3.1' \
      'git+https://gitlab.com/valtron/sqlaltery.git@v0.1.0'

# Non-dev mode serves plain HTTP on 127.0.0.1:8081 (nginx terminates TLS in
# production). Bind all interfaces so the host can reach it through Docker.
RUN sed -i "s/http_host = '127.0.0.1'/http_host = '0.0.0.0'/" core/http.py

COPY settings_local.py /srv/escargot/settings_local.py
COPY entrypoint.sh /entrypoint.sh
COPY seed_users.py /srv/escargot/script/seed_users.py
RUN chmod +x /entrypoint.sh

EXPOSE 1863 1864 8081
ENTRYPOINT ["/entrypoint.sh"]
