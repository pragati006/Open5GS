FROM ubuntu:22.04

# sip-tester provides `sipp`. The rest are for connectivity checks / routing
# inside a UE network namespace and for capturing the SIP flow.
RUN apt-get update && apt-get install -y --no-install-recommends \
        sip-tester \
        iproute2 \
        iputils-ping \
        tcpdump \
        netcat-openbsd \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY run-server.sh run-client.sh /opt/sip/
RUN chmod +x /opt/sip/run-server.sh /opt/sip/run-client.sh

WORKDIR /opt/sip
