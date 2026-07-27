# Reproducible 5G SA lab — Open5GS core + OAI RAN + SIP over the data plane

A single `docker compose up -d` brings up a full 5G Standalone network:

- **Open5GS** 5G core (NRF, AMF, AUSF, UDM, UDR, PCF, BSF, NSSF, SMF, UPF + MongoDB)
- **OAI** RAN: one monolithic **gNB** and **two nr-UEs** over the RF simulator (no radio HW)
- A **SIP UAS/UAC** pair (sipp) that drives SIP signalling **through the 5G user plane**

Verified result (`scripts/verify.sh`): **9/9 checks pass.**

| Requirement                              | How it is met                                                          | Evidence                                                      |
| ---------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------- |
| ≥ 2 UEs attach                           | `oai-nr-ue-1` + `oai-nr-ue-2` register on the AMF (IMSI …0001 / …0002) | AMF "Registration complete" ×2                                |
| Working IP connectivity through the core | Each UE gets `oaitun_ue1` from `10.45.0.0/16`; ping traverses the UPF  | UE1=10.45.0.2, UE2=10.45.0.3, ping 0% loss                    |
| SIP through the 5G data plane (no VoLTE) | sipp UAC (in each UE's netns) → UPF (N3/GTP-U → N6/NAT) → sipp UAS     | 10 successful calls/UE; server sees SIP from UPF `10.100.0.2` |

---

## 1. Topology

```
                         core net 192.168.70.0/24
  mongo(.10) nrf(.11) amf(.13) ausf(.14) udm(.15) udr(.16)
  pcf(.17) bsf(.18) nssf(.19) smf(.20) upf(.21) gnb(.30)
      |                  |  N2/SBI          |  N3 (GTP-U 2152)
      |            oai-nr-ue-1(.31)  oai-nr-ue-2(.32)  --RFsim TCP 4043--> gnb
      |                                     |
   (subscriber DB)                     UPF ogstun (10.45.0.1/16, UE pool)
                                            |  N6 / MASQUERADE
                                    data net 10.100.0.0/24
                                    upf(.2)      sip-server(.5)  <-- sipp UAS
```

The **SIP server lives only on the data net**; the UEs are **not** attached to it,
so the only path from a UE to the SIP server is through the UPF. Each SIP client
runs in its UE's network namespace and pins a route to `10.100.0.0/24` via
`oaitun_ue1`, guaranteeing the SIP 5-tuple rides the 5G data plane. Proof: the UAS
sees every request sourced from `10.100.0.2` (the UPF N6 address after NAT), never
from a UE's `10.45.0.x`.

Key parameters (`.env`): **PLMN 001/01**, **TAC 1**, **SST 1**, **DNN `internet`**,
band 78 / 106 PRB / SCS 30 kHz, SSB @ 3319.68 MHz, UE key/OPc = OAI test defaults.

---

## 2. Prerequisites (host, one-time per boot)

Needs the SCTP kernel module (N2/NGAP) and a running Docker daemon:

```bash
sudo modprobe sctp
sudo service docker start          # or: sudo systemctl start docker
```

`/dev/net/tun` must exist (WSL2/most Linux). Docker Compose v2+, ~6 GB RAM free.

---

## 3. Bring-up (one command)

```bash
cd /home/pragati/linux_workspace/5g
docker compose build sip-server            # builds the local sipp image
docker compose up -d                       # brings up the entire stack
```

Startup ordering is handled automatically:

- `dbctl` provisions the two subscribers as soon as Mongo is healthy, and the gNB
  waits for `dbctl` to complete (`service_completed_successfully`).
- The SIP clients poll for `oaitun_ue1`, install the data-plane route, ping, then
  run sipp.

Give it ~2–3 minutes for the UEs to complete RACH + registration + PDU session and
for the SIP clients to run. Then verify (step 4).

Staged bring-up (useful for debugging) is also fine:

```bash
docker compose up -d mongo nrf amf ausf udm udr pcf bsf nssf smf upf
docker compose up dbctl                     # runs to completion
docker compose up -d oai-gnb
docker compose up -d oai-nr-ue-1 oai-nr-ue-2
docker compose up -d sip-server sip-client-1 sip-client-2
```

---

## 4. Verify

```bash
./scripts/verify.sh          # automated: registration, IP, SIP  -> 9/9 PASS
./scripts/prove-dataplane.sh # captures SIP at the UAS proving UPF (N6) traversal
./scripts/ue-status.sh       # per-UE RRC/NAS state + tunnel IP
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

## 5. Files

```
docker-compose.yaml          whole stack (17 services)
.env                         image tags + PLMN/DNN/UE identities
open5gs/*.yaml               per-NF Open5GS v2.7 configs (direct NF<->NRF)
oai/gnb.conf                 OAI gNB (band 78, 106 PRB, RFsim) — OAI reference-based
oai/nr-ue.conf               OAI UE base config (uicc0; IMSI overridden per UE via CLI)
dbctl/add-subscribers.sh     subscriber provisioning (open5gs-dbctl)
sip/                         sipp image (Dockerfile) + UAS/UAC run scripts
scripts/verify.sh            automated requirement checks
scripts/prove-dataplane.sh   packet-level proof SIP crosses the UPF
scripts/ue-status.sh         UE attach diagnostics
scripts/{pull-all,check-tags}.sh  image helpers
```

## 6. Teardown

```bash
docker compose down -v
```

## 7. Notes / gotchas (discovered while building this)

- **OAI image tag matters.** `oai-gnb:2026.w20` **segfaults** in rfsim _server_
  mode (`rfsimulator_readconfig`). This lab pins **`OAI_TAG=2025.w40`** (`.env`),
  which is verified working. If you change it, re-test the gNB in isolation.
- **UPF runs as root.** `gradiant/open5gs` runs as user `open5gs`; creating the
  `ogstun` TUN device needs root, so the `upf` service sets `user: "0"` +
  `cap_add: NET_ADMIN` + `/dev/net/tun`.
- **RT scheduling.** OAI threads use SCHED_FIFO; the gNB/UE services set
  `ulimits: {rtprio: 99, memlock: -1}` or you get `pthread_create errno 11`.
- **No `--sa` flag.** Recent OAI removed it (SA is the default); passing it aborts.
- **gNB↔UE frequency must match.** The gNB prints the exact UE args on boot
  (`Command line parameters for OAI UE: -C 3319680000 -r 106 --numerology 1 --ssb 516`);
  the UE services use those.
- **UEs not attaching / gNB abort on `prach_id`**: PRACH config must be consistent
  with the TDD pattern; this uses OAI's tested `band78.106prb.rfsim` values incl.
  `prach_dtx_threshold = 200` (too low → false PRACH detection on rfsim noise).
- **SCTP** module must be loaded on the host (see prerequisites).

---

## 8. OTT VoIP service (Kamailio + RTPengine + baresip)

An **over-the-top SIP voice service** layered on the 5G data plane, in the compose
overlay `docker-compose.sip.yaml` (so it adds onto the running 5G stack):

- **Kamailio** — SIP registrar + proxy (`10.100.0.10`), with `rtpengine` media steering + `nathelper`
- **RTPengine** — RTP media relay (`10.100.0.11`, userspace mode, ports 30000–31000)
- **baresip** ×2 — softphones, one inside each UE's netns (`ue1` = auto-answer callee, `ue2` = caller)

Verified result (`scripts/voip-verify.sh`): **3/3 checks pass.**

| Requirement                            | How it is met                                                  | Evidence                                                                                                      |
| -------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Two SIP clients register via Kamailio  | baresip in each UE netns REGISTERs to Kamailio over the tunnel | `kamcmd ul.dump` lists ue1 + ue2, `Received: 10.100.0.2` (UPF NAT)                                            |
| A successful audio call is established | ue2 dials ue1, callee auto-answers                             | `CALL_ESTABLISHED` + `CALL_RTPESTAB (audio)`; both legs `Active calls (1)`                                    |
| RTPengine relays media                 | Kamailio `rtpengine_manage()` rewrites SDP to the relay        | rtpengine logs `10.100.0.11:3xxxx <> 10.100.0.2:yyyy … 251 p` per leg; 2915 RTP pkts captured on `oaitun_ue1` |

Because the UEs reach `10.100.0.10/.11` only via the UPF, all SIP signalling **and**
RTP media ride the 5G data plane. Every packet shows source `10.100.0.2` (the UPF
N6 NAT address) at the servers, and the on-tunnel capture shows the UE's own
`10.45.0.x` talking to the RTPengine relay.

### Bring up / verify

```bash
DC="docker compose -f docker-compose.yaml -f docker-compose.sip.yaml"
$DC build kamailio baresip-ue1
$DC up -d kamailio rtpengine
$DC up -d baresip-ue1 baresip-ue2        # caller auto-dials after ~30s
bash scripts/voip-verify.sh              # -> 3 passed, 0 failed
bash scripts/voip-call-capture.sh        # -> captures/voip-rtp.pcap (RTP via RTPengine)
```

Control a softphone directly (netstring JSON over baresip `ctrl_tcp`):

```bash
docker exec baresip-ue2 python3 /baresip-ctrl.py dial sip:ue1@10.100.0.10
docker exec baresip-ue2 python3 /baresip-ctrl.py listcalls
docker exec baresip-ue2 python3 /baresip-ctrl.py hangup
```

### VoIP files

```
docker-compose.sip.yaml      overlay: kamailio + rtpengine + 2 baresip
voip/kamailio/               Dockerfile + kamailio.cfg (registrar/NAT/rtpengine)
voip/rtpengine/              (rtpengine runs via compose entrypoint, userspace mode)
voip/baresip/                Dockerfile + config + run-baresip.sh + baresip-ctrl.py
scripts/voip-verify.sh       automated 3-check verification
scripts/voip-call-capture.sh place a call + capture RTP proof to captures/
```

### VoIP gotchas (discovered while building)

- **baresip 1.0.0 needs `module_path`** (`/usr/lib/baresip/modules`) or it can't load `.so` modules.
- **Auto-answer** is a per-account flag (`;answermode=auto`), not the `auto_answer` config option.
- **baresip control** is `ctrl_tcp` using **netstring-framed JSON** — `echo | nc` won't work; use `baresip-ctrl.py`.
- **Kamailio**: `fix_nated_register()` requires a `received_avp` shared with the registrar module; the rtpengine module `t_precheck_trans` needs `tmx.so` (not `libTMX.so`).
- **RTPengine** runs in userspace with `--table=-1` (no kernel module — needed in WSL); its image entrypoint sed-edits a config file, so we bypass it and pass flags directly.
- **NAT**: both UEs share the UPF's single data-net IP (`10.100.0.2`); Kamailio's `fix_nated_*` + RTPengine's source-learning handle the double-NAT.

```

---

## 9. Real (audible) audio call over 5G

Section 8 establishes a call whose media is a synthetic tone. This layer carries
**real speech** end-to-end and makes it **audible on the laptop speaker** via WSLg
PulseAudio — overlay `docker-compose.audio-call.yaml` (adds onto §8).

Direction of the demo:

```

baresip-ue2 (caller) --sends audio/speech.wav--> UPF (N3/N6) --> RTPengine
|
laptop speaker <--alsa/PulseAudio (WSLg)-- baresip-ue1 (callee) <----+

````

The caller transmits a live audio stream ; the
callee plays the **received** stream out the laptop speaker. So you hear, on your
speaker, the audio that actually crossed the 5G user plane.

### Bring up / run

```bash
DC="docker compose -f docker-compose.yaml -f docker-compose.sip.yaml -f docker-compose.audio-call.yaml"
bash scripts/make-speech.sh                 # (first time) generate audio/speech.wav via espeak-ng
$DC up -d baresip-ue1 baresip-ue2           # callee plays received audio to the speaker
bash scripts/audio-call.sh 20               # dial, hold 20s (you HEAR the speech), print proof
bash scripts/play-received.sh               # replay the exact audio that crossed 5G
````

Verified result of `scripts/audio-call.sh`:

| Proof                                              | Evidence                                                                           |
| -------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Media rides the 5G data plane via RTPengine        | ~1700 RTP pkts, UE `10.45.0.x` ↔ relay `10.100.0.11:3xxxx`, bidirectional          |
| Real audio came out of the call (not silence/tone) | speaker-monitor recording ≈ 22.9 s, peak 0.95 / RMS 0.085 (source speech RMS 0.10) |

`captures/received-over-5g.wav` is the recording of what played on the speaker.

### Live microphone (environment-gated)

WSLg exposes both a speaker sink (`RDPSink`) and a mic source (`RDPSource`).
**Speaker-out works; mic-in returns digital silence** in this WSLg setup
(`RDPSource` RMS ≈ 0.0001 — see `scripts/audio-probe.sh`). That is a Windows/WSLg
mic-passthrough/permission limitation, not a lab bug, so the demo uses a recorded
speech file as the source. To try a **live mic** once Windows mic access is
enabled (Settings → Privacy → Microphone) and the mic is unmuted: set the caller's
`AUDIO_SOURCE: "alsa,default"` + `EXTRA_MODULES: "alsa.so"` (as in the parked
`docker-compose.sip.mic.yaml`) and re-dial; verify with `scripts/audio-probe.sh`
that `RDPSource` shows non-trivial RMS first.

### Audio-call files

```
docker-compose.audio-call.yaml  overlay: callee plays received RTP to laptop speaker
audio/speech.wav                recorded sentence used as the caller's audio source
scripts/make-speech.sh          (re)generate audio/speech.wav (espeak-ng, 8 kHz mono)
scripts/audio-call.sh           dial + capture RTP proof + record speaker output
scripts/play-received.sh        replay captures/received-over-5g.wav to the speaker
scripts/audio-probe.sh          probe WSLg PulseAudio sinks/sources (speaker/mic health)
```

---

## 10. Live microphone call over 5G (real full-duplex voice)

A genuine **live voice call**: you speak into the laptop mic and hear yourself
back through the 5G data plane. Overlay `docker-compose.live-linphone.yaml` runs
**two linphonec softphones** (native mediastreamer PulseAudio), one in each UE
netns:

```
you speak -> phone-ue2 (mic) --5G(UPF/N3-N6)--> RTPengine --> phone-ue1 (auto-answer)
                                                                     |
      laptop speaker  <----------- plays received audio -------------+
```

linphonec is used (not baresip) because baresip's `alsa`/`portaudio` **capture**
opens the device but pushes zero frames in this container (0 RTP), whereas
mediastreamer's native pulse path works. Two non-obvious fixes were required:
liblinphone rejects incoming calls with **503 "core global state is not on"**
unless its data dir exists (`run-linphone2.sh` creates `~/.local/share/linphone`),
and the callee auto-answers via a log-watcher writing `answer` to the ctrl FIFO.

### Run

```bash
DC="docker compose -f docker-compose.yaml -f docker-compose.sip.yaml -f docker-compose.live-linphone.yaml"
docker rm -f baresip-ue1 baresip-ue2 phone-ue2        # free the UE-netns SIP ports
$DC up -d phone-ue1 phone-ue2                          # both register (~30s)
bash scripts/live-linphone-updown.sh                  # silent check: expect ~800 RTP pkts/9s
bash scripts/live-call-final.sh 18                    # SPEAK for 18s; hear yourself; prints proof
```

Verified result of `scripts/live-call-final.sh`:

| Proof                                 | Evidence                                                                          |
| ------------------------------------- | --------------------------------------------------------------------------------- |
| Live mic captured                     | mic recording RMS ≈ 0.05 while speaking                                           |
| Media crosses 5G via RTPengine        | ~2000 RTP pkts, UE `10.45.0.x:7078` ↔ relay `10.100.0.11:3xxxx`, bidirectional    |
| Your voice comes back out the speaker | speaker-monitor recording RMS ≈ 0.07 (saved to `captures/live-voice-over-5g.wav`) |

Revert to the automated baresip softphones (§8) when done:

```bash
docker rm -f phone-ue1 phone-ue2
docker compose -f docker-compose.yaml -f docker-compose.sip.yaml up -d baresip-ue1 baresip-ue2
```

### Live-call files

```
docker-compose.live-linphone.yaml  overlay: two linphonec phones (mic caller + auto-answer callee)
voip/linphone/run-linphone2.sh     linphonec runner: auto-answer, device select, DB-dir fix
scripts/live-linphone-updown.sh    bring up both phones + silent connect/RTP check
scripts/live-call-final.sh         place the call, capture mic + speaker + RTP proof
```

---

## 11. ML: RTP loss-cause / QoS classifier (`ml/`)

An AI component that classifies the _cause_ of media degradation from **RTP
statistics**, so the correct mitigation can be chosen — because the two failure
modes need opposite fixes:

| Class        | User-plane cause                                     | Correct mitigation                            |
| ------------ | ---------------------------------------------------- | --------------------------------------------- |
| `clean`      | healthy link                                         | none                                          |
| `radio`      | random/bursty loss (radio BLER), **no** queue growth | add FEC / redundancy + PLC — _not_ rate cut   |
| `congestion` | queue builds → delay/jitter rise, then loss          | reduce bitrate / lower-rate codec — _not_ FEC |

The discriminator is **timing**: congestion makes one-way delay + jitter climb
before packets drop; radio loss drops without delay growth and is bursty. The lab is
ideal for this because you can _manufacture labels_ with `tc`:

```bash
bash scripts/rtp-dataset.sh   # drive baresip calls under tc netem (radio) / tbf (congestion); capture at callee
bash scripts/rtp-train.sh     # extract per-second RTP features + train + evaluate (host python3, numpy-only)
cd ml && python3 predict.py data/congestion.pcap   # -> verdict + recommended mitigation
```

Result (72 windows, 24/class): held-out accuracy ≈ 0.76, with **congestion vs radio
cleanly separated** (the decision that matters) — congestion 23/24, radio 20/24, no
congestion↔radio confusion. Dependency-light (stdlib pcap parsing + a numpy softmax
model; no scikit-learn/Docker). Full details and design rationale in `ml/README.md`.
