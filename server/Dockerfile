FROM python:3.12-slim

# rsync makes the nightly backup snapshots.
RUN apt-get update && apt-get install -y --no-install-recommends rsync \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Run as the same user ID as the server's normal account so uploaded files
# are owned by you, not root. Override with PUID/PGID build args if needed.
ARG PUID=1000
ARG PGID=1000
RUN groupadd -o -g ${PGID} homedrive && useradd -o -u ${PUID} -g ${PGID} -M homedrive
USER homedrive

ENV HOMEDRIVE_FILES=/files HOMEDRIVE_DATA=/data
EXPOSE 8000
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
