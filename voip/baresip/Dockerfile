FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# baresip + modules needed for headless SIP UAC/UAS:
#   libre, librem  – base libraries
#   baresip        – core
#   baresip-x11    – NOT needed; skip
# Modules used: aufile (play/record), netroam, ctrl_tcp, account, rtp
RUN apt-get update && apt-get install -y --no-install-recommends \
        baresip \
        libasound2-plugins \
        alsa-utils \
        pulseaudio-utils \
        iproute2 \
        iputils-ping \
        tcpdump \
        sox \
        netcat-openbsd \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Route ALSA -> PulseAudio (for mic/speaker via WSLg)
COPY asound.conf /etc/asound.conf

# Create a test audio file (8kHz mono 16-bit PCM, 60 seconds, 440 Hz tone).
# Long enough that the call stays up for the full demo hold time.
RUN sox -n -r 8000 -c 1 -b 16 /opt/test.wav synth 60 sine 440

COPY config /etc/baresip/config
COPY run-baresip.sh /run-baresip.sh
COPY baresip-ctrl.py /baresip-ctrl.py
RUN chmod +x /run-baresip.sh /baresip-ctrl.py

ENTRYPOINT ["/run-baresip.sh"]
