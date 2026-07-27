## 1. Reproducible 5G SA lab — Open5GS core + OAI RAN + SIP over the data plane

A single `docker compose up -d` brings up a full 5G Standalone network:

- **Open5GS** 5G core (NRF, AMF, AUSF, UDM, UDR, PCF, BSF, NSSF, SMF, UPF + MongoDB)
- **OAI** RAN: one monolithic **gNB** and **two nr-UEs** over the RF simulator (no radio HW)
- A **SIP UAS/UAC** pair (sipp) that drives SIP signalling **through the 5G user plane**


The **SIP server lives only on the data net**; the UEs are **not** attached to it,
so the only path from a UE to the SIP server is through the UPF. Each SIP client
runs in its UE's network namespace and pins a route to `10.100.0.0/24` via
`oaitun_ue1`. 
Proof: the UAS sees every request sourced from `10.100.0.2` (the UPF N6 address after NAT), never
from a UE's `10.45.0.x`.


# Prerequisites (host, one-time per boot)

Needs the SCTP kernel module (N2/NGAP) and a running Docker daemon:

```bash
sudo modprobe sctp
sudo service docker start          # or: sudo systemctl start docker
```

`/dev/net/tun` must exist (WSL2/most Linux). Docker Compose v2+, ~6 GB RAM free.

---

# Bring-up (one command)

```bash
cd /home/pragati/linux_workspace/Open5GS
docker compose build sip-server            # builds the local sipp image
docker compose up -d                       # brings up the entire stack
```

Startup ordering is handled automatically:

- `dbctl` provisions the two subscribers as soon as Mongo is healthy, and the gNB
  waits for `dbctl` to complete (`service_completed_successfully`).
- The SIP clients poll for `oaitun_ue1`, install the data-plane route, then ping.

Give it ~2–3 minutes for the UEs to complete RACH + registration + PDU session and
for the SIP clients to run. Then verify.

Staged bring-up (useful for debugging) is also fine:

```bash
docker compose up -d mongo nrf amf ausf udm udr pcf bsf nssf smf upf
docker compose up dbctl                     # runs to completion
docker compose up -d oai-gnb
docker compose up -d oai-nr-ue-1 oai-nr-ue-2
docker compose up -d sip-server sip-client-1 sip-client-2
```

---

# Verify

```bash
./scripts/verify.sh          # automated: registration, IP, SIP  -> 9/9 PASS

```

Manual spot-checks:

```bash
docker compose logs amf | grep -Ei "Registration complete|imsi-00101"
docker exec oai-nr-ue-1 ip addr show oaitun_ue1        # 10.45.0.x
docker exec oai-nr-ue-1 ping -c3 -I oaitun_ue1 10.45.0.1     # UPF gw, through the core
docker compose logs sip-client-1 | grep -E "ping OK|SUCCESS: SIP"
docker compose logs sip-server   | tail
```

---

# Files

```
docker-compose.yaml          whole stack (17 services)
.env                         image tags + PLMN/DNN/UE identities
open5gs/*.yaml               per-NF Open5GS v2.7 configs (direct NF<->NRF)
oai/gnb.conf                 OAI gNB (band 78, 106 PRB, RFsim) — OAI reference-based
oai/nr-ue.conf               OAI UE base config (uicc0; IMSI overridden per UE via CLI)
dbctl/add-subscribers.sh     subscriber provisioning (open5gs-dbctl)
sip/                         sipp image (Dockerfile) + UAS/UAC run scripts
scripts/verify.sh            automated requirement checks

```

#Teardown

```bash
docker compose down -v
```

---


## 2. Live microphone call over 5G (real full-duplex voice)

A genuine **live voice call**: you speak into the laptop mic and hear yourself
back through the 5G data plane. Overlay `docker-compose.ott.yaml` runs
**two linphonec softphones** (native mediastreamer PulseAudio), one in each UE
netns:

```
you speak -> phone-ue2 (mic) --5G(UPF/N3-N6)--> RTPengine --> phone-ue1 (auto-answer)
                                                                     |
      laptop speaker  <----------- plays received audio -------------+
```

linphonec is used (not baresip) because baresip's `alsa`/`portaudio` **capture**
opens the device but pushes zero frames in this container (0 RTP), whereas
mediastreamer's native pulse path works. The callee auto-answers via a log-watcher writing `answer` to the ctrl FIFO.

#Run

```bash
DC="docker compose -f docker-compose.yaml -f docker-compose.ott.yaml"
$DC up -d                                             # both register (~30s)
bash scripts/live-call.sh 18                          # SPEAK for 18s; hear yourself; prints proof
```

# Live-call files

```
docker-compose.ott.yaml            overlay: two linphonec phones (mic caller + auto-answer callee)
scripts/live-call.sh               place the call, capture mic + speaker + RTP proof
```

---
## 3. OTT VoIP service (Kamailio + RTPengine + baresip) for ML

An **over-the-top SIP voice service** layered on the 5G data plane, in the compose
overlay `docker-compose.sip.yaml` (so it adds onto the running 5G stack):

- **Kamailio** — SIP registrar + proxy (`10.100.0.10`), with `rtpengine` media steering + `nathelper`
- **RTPengine** — RTP media relay (`10.100.0.11`, userspace mode, ports 30000–31000)
- **baresip** ×2 — softphones, one inside each UE's netns (`ue1` = auto-answer callee, `ue2` = caller)

# Bring up / verify

```bash
DC="docker compose -f docker-compose.yaml -f docker-compose.sip.yaml"
$DC build kamailio baresip-ue1
$DC up -d kamailio rtpengine
$DC up -d baresip-ue1 baresip-ue2        # caller auto-dials after ~30s
bash scripts/live-call.sh                # -> place a live call
```

Control a softphone directly (netstring JSON over baresip `ctrl_tcp`):

```bash
docker exec baresip-ue2 python3 /baresip-ctrl.py dial sip:ue1@10.100.0.10
docker exec baresip-ue2 python3 /baresip-ctrl.py listcalls
docker exec baresip-ue2 python3 /baresip-ctrl.py hangup
```

# VoIP files

```
docker-compose.sip.yaml      overlay: kamailio + rtpengine + 2 baresip
voip/kamailio/               Dockerfile + kamailio.cfg (registrar/NAT/rtpengine)
voip/rtpengine/              (rtpengine runs via compose entrypoint, userspace mode)
voip/baresip/                Dockerfile + config + run-baresip.sh + baresip-ctrl.py
```

----

## 4. ML: RTP loss-cause / QoS classifier (`ml/`)

An AI component that classifies the _cause_ of media degradation from **RTP
statistics**, so the correct mitigation can be chosen — because the two failure
modes need opposite fixes:

The discriminator is **timing**: congestion makes one-way delay + jitter climb
before packets drop; radio loss drops without delay growth and is bursty. The lab is
ideal for this because you can _manufacture labels_ with `tc`:

```bash
bash scripts/rtp-dataset.sh   # drive baresip calls under tc netem (radio) / tbf (congestion); capture at callee
bash scripts/rtp-train.sh     # extract per-second RTP features + train + evaluate (host python3, numpy-only)
cd ml && python3 predict.py data/congestion.pcap   # -> verdict + recommended mitigation
```

Dependency-light (stdlib pcap parsing + a numpy softmax model; no scikit-learn/Docker).
