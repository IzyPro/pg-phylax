ARG ALPINE_VERSION
ARG PG_VERSION

FROM alpine:${ALPINE_VERSION}

ARG SUPERCRONIC_VERSION
ARG SUPERCRONIC_SHA1SUM
ARG SUPERCRONIC_ARCH

# Install system dependencies
RUN apk add --no-cache \
    postgresql${PG_VERSION}-client \
    aws-cli \
    curl \
    bash \
    ca-certificates \
    tzdata

# Install supercronic using build args
RUN curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/${SUPERCRONIC_ARCH}" \
    -o /usr/local/bin/supercronic && \
    echo "${SUPERCRONIC_SHA1SUM}  /usr/local/bin/supercronic" | sha1sum -c - && \
    chmod +x /usr/local/bin/supercronic

# Create non-root user for security
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
USER pgphylax

CMD ["/bin/sh", "/usr/local/bin/run.sh"]