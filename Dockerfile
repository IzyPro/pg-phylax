# Dockerfile
# Mirrors eeshugerman/postgres-backup-s3 base approach
# Uses go-cron for reliable scheduling (same as eeshugerman)
# Alpine 3.21 for small image size and security

ARG ALPINE_VERSION=3.21
ARG PG_VERSION=17

FROM alpine:${ALPINE_VERSION}

ARG PG_VERSION

# Install system dependencies
RUN apk add --no-cache \
    # PostgreSQL client matching PG_VERSION
    postgresql${PG_VERSION}-client \
    # AWS CLI for S3/R2 upload (same as eeshugerman)
    aws-cli \
    # curl for Telegram API calls
    curl \
    # bash for scripts
    bash \
    # ca-certificates for HTTPS
    ca-certificates \
    # tzdata for timezone support
    tzdata\
    # coreutils for GNU date (required for retention math)
    coreutils


# Create non-root user for security
# Do not run as root - principle of least privilege
RUN addgroup -S pgphylax && adduser -S -G pgphylax pgphylax

# Create working directories
RUN mkdir -p /backups /var/log/pgphylax && \
    chown -R pgphylax:pgphylax /backups /var/log/pgphylax

# Copy scripts
COPY src/env.sh     /usr/local/bin/env.sh
COPY src/notify.sh  /usr/local/bin/notify.sh
COPY src/backup.sh  /usr/local/bin/backup.sh
COPY src/run.sh     /usr/local/bin/run.sh

# Set correct permissions - readable and executable, not writable
RUN chmod 0555 \
    /usr/local/bin/env.sh \
    /usr/local/bin/notify.sh \
    /usr/local/bin/backup.sh \
    /usr/local/bin/run.sh

# Switch to non-root user
USER root

# No ports exposed - this is a batch job, not a server
# No VOLUME declared - managed by docker-compose

CMD ["/bin/sh", "/usr/local/bin/run.sh"]
