FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# linphonec (console client) + mediastreamer pulse/alsa plugins for real audio
RUN apt-get update && apt-get install -y --no-install-recommends \
        linphone-cli \
        pulseaudio-utils \
        alsa-utils \
        iproute2 \
        iputils-ping \
        tcpdump \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

COPY run-linphone.sh /run-linphone.sh
RUN chmod +x /run-linphone.sh
ENTRYPOINT ["/run-linphone.sh"]
