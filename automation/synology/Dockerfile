FROM python:3.14-slim-bookworm

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        git \
        wget \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install --yes --no-install-recommends gh \
    && gh auth login --help | grep -q -- --insecure-storage \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pr-issue-worker
COPY automation/synology/pyproject.toml ./
COPY automation/synology/src ./src
COPY automation/synology/scripts/setup-github-labels.sh /usr/local/bin/setup-github-labels
RUN python -m pip install --no-cache-dir .

RUN useradd --create-home --uid 1000 --shell /usr/sbin/nologin worker \
    && mkdir -p /data/workspaces \
    && chown -R worker:worker /data

ENV HOME=/home/worker \
    DATA_PATH=/data \
    STATE_PATH=/data/state.sqlite3 \
    WORKSPACE_PATH=/data/workspaces \
    PYTHONUNBUFFERED=1

USER worker
ENTRYPOINT ["pr-issue-worker"]
CMD ["serve"]
