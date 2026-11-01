Hardware verification (2026-11-01): Holyiot dongle on a Raspberry Pi 3 with otbr-agent built from OpenThread cb18e0f.
Secured two-way traffic with a Thread router on the mesh works (ping 12-16 ms, no MAC security errors, CoAP data arrives,
no otbr-agent restarts). Verified over a few hours only; no long soak yet. Only the dongle is built for this release;
the UART boards (Ebyte E73, Ezurio nRF54L15) have not been tried with upstream OpenThread.
