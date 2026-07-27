#!/usr/bin/env bash
# Final LIVE call over 5G (linphonec<->linphonec):
#   you speak -> phone-ue2 mic -> 5G/UPF -> RTPengine -> phone-ue1 -> laptop speaker.
# Proof: RTP through the relay + a recording of your voice coming out the speaker.

set -u

#cd /home/pragati/linux_workspace/5g
#mkdir -p captures

WIN="${1:-18}"

# -------------------------------------------------------------------
# Clean previous logs
# -------------------------------------------------------------------
rm -f captures/kamailio.log
rm -f captures/rtpengine.log
rm -f captures/live-voice-over-5g.wav
rm -f captures/mic.raw
rm -f captures/spk.raw

# -------------------------------------------------------------------
# Stop previous calls
# -------------------------------------------------------------------
docker exec phone-ue2 sh -c "echo terminate > /tmp/lin.in" 2>/dev/null || true
docker exec phone-ue1 sh -c "echo terminate > /tmp/lin.in" 2>/dev/null || true
sleep 2

# -------------------------------------------------------------------
# Start Kamailio and RTPengine log capture
# -------------------------------------------------------------------
docker logs -f kamailio > logs/kamailio.log 2>&1 &
KAM_LOG_PID=$!

docker logs -f rtpengine > logs/rtpengine.log 2>&1 &
RTP_LOG_PID=$!

# -------------------------------------------------------------------
# RTP capture on UE2
# -------------------------------------------------------------------
docker exec -d phone-ue2 sh -c \
"rm -f /tmp/rtp.pcap;
 timeout $((WIN+6)) tcpdump -ni oaitun_ue1 \
 -w /tmp/rtp.pcap 'udp and host 10.100.0.11' \
 >/dev/null 2>&1"

# -------------------------------------------------------------------
# Audio capture
# -------------------------------------------------------------------
docker run -d --rm --name audcap \
  -v /mnt/wslg:/mnt/wslg \
  -v /home/pragati/linux_workspace/5g/captures:/c \
  -e PULSE_SERVER=unix:/mnt/wslg/PulseServer \
  --entrypoint bash \
  baresip-ott:local \
  -c "
parec --device=RDPSink.monitor --format=s16le --rate=8000 --channels=1 /c/spk.raw &
parec --device=RDPSource --format=s16le --rate=8000 --channels=1 /c/mic.raw &
sleep $((WIN+4))
kill %1 %2 2>/dev/null
" >/dev/null 2>&1

sleep 1

# -------------------------------------------------------------------
# Place call
# -------------------------------------------------------------------
docker exec phone-ue2 sh -c "echo 'call sip:ue1@10.100.0.10' > /tmp/lin.in"

sleep 4

echo "############################################################"
echo "#   SPEAK INTO YOUR LAPTOP MIC NOW -- ${WIN} seconds"
echo "#   (you should hear your own voice from the speaker)"
echo "############################################################"

sleep "${WIN}"

docker exec phone-ue2 sh -c "echo terminate > /tmp/lin.in" 2>/dev/null || true
sleep 3

# -------------------------------------------------------------------
# Stop log capture
# -------------------------------------------------------------------
kill $KAM_LOG_PID 2>/dev/null
kill $RTP_LOG_PID 2>/dev/null

wait $KAM_LOG_PID 2>/dev/null || true
wait $RTP_LOG_PID 2>/dev/null || true

# -------------------------------------------------------------------
# Results
# -------------------------------------------------------------------
echo
echo "================= RESULT ================="

echo "--- MIC captured (your voice into the phone) ---"
docker run --rm \
  -v /home/pragati/linux_workspace/5g/captures:/c \
  --entrypoint sox \
  baresip-ott:local \
  -t raw -r 8000 -e signed -b 16 -c 1 \
  /c/mic.raw -n stat 2>&1 \
  | grep -iE "Length|Maximum amplitude|RMS.*ampl"

echo
echo "--- SPEAKER output (after crossing 5G) ---"
docker run --rm \
  -v /home/pragati/linux_workspace/5g/captures:/c \
  --entrypoint sox \
  baresip-ott:local \
  -t raw -r 8000 -e signed -b 16 -c 1 \
  /c/spk.raw -n stat 2>&1 \
  | grep -iE "Length|Maximum amplitude|RMS.*ampl"

echo
echo "--- RTP through RTPengine on the 5G data plane ---"

pk=$(docker exec phone-ue2 tcpdump -nr /tmp/rtp.pcap 2>/dev/null | wc -l)

echo "Packets: ${pk}"

docker exec phone-ue2 tcpdump -nr /tmp/rtp.pcap 2>/dev/null \
| awk '{print $3,$4,$5}' \
| sort | uniq -c | sort -rn | head -3 \
| sed 's/^/    /'

# -------------------------------------------------------------------
# Save WAV recording
# -------------------------------------------------------------------
docker run --rm \
  -v /home/pragati/linux_workspace/5g/captures:/c \
  --entrypoint sox \
  baresip-ott:local \
  -t raw -r 8000 -e signed -b 16 -c 1 \
  /c/spk.raw \
  /c/live-voice-over-5g.wav 2>/dev/null

echo
echo "Artifacts saved:"
echo "  logs/kamailio.log"
echo "  logs/rtpengine.log"

docker cp phone-ue2:/tmp/rtp.pcap captures/rtp.pcap >/dev/null 2>&1 || true
echo "  captures/rtp.pcap"

echo "=========================================="
echo "RMS > ~0.01 on SPEAKER = your live voice really crossed the 5G network."