Hardware verification (2026-11-01):
- Holyiot dongle: tested on a Raspberry Pi 3 with otbr-agent built from OpenThread cb18e0f. Secured two-way traffic with a Thread
  router on the mesh works (ping 12-16 ms, no MAC security errors, CoAP data arrives, no otbr-agent restarts). Verified over a few
  hours only; no long soak yet.
- Ebyte E73 and Ezurio nRF54L15 (all UART variants): built with the same patch and configuration, NOT yet tested on hardware.
  Treat them as untested until this note says otherwise.
