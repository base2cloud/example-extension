# Pinned by digest, not tag. A tag is mutable: python:3.12-slim can be
# repointed at a different image, which would silently change what runs with
# access to CWS credentials. Refresh with:
#   docker buildx imagetools inspect python:3.12-slim
FROM python:3.12-slim@sha256:09f7da3bc104798d0afb40bc08d23ab2da20a76130cec1f2ef170848f5d85217

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Drop privileges. Nothing here needs root, and the container holds a
# credential capable of reading the Chrome Web Store listing.
RUN groupadd --gid 10001 poller \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin poller \
    && chown -R poller:poller /app
USER 10001:10001

# Cloud Run Jobs run the container to completion; no EXPOSE or long-running CMD needed.
CMD ["python", "main.py"]
