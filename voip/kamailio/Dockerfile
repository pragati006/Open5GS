FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        kamailio \
        kamailio-extra-modules \
        kamailio-utils-modules \
        kamailio-json-modules \
        iproute2 \
        iputils-ping \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

COPY kamailio.cfg /etc/kamailio/kamailio.cfg

# Run in foreground, send logs to stderr
CMD ["kamailio", "-f", "/etc/kamailio/kamailio.cfg", "-DD", "-E"]
