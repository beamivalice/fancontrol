# Fan Control

Menubar app, CLI, HTTP API, and MCP server for Apple Silicon Macs (M1–M5). **Auto** (macOS default) or **Max** (hardware-reported maximum). There is no low/custom RPM path.

## Safety

- Writes require root (`fand` LaunchDaemon). Reads do not.
- Max only — cannot pin fans below the firmware floor.
- TTL dead-man switch (default 15 min, max 2 h) returns to Auto.
- Failsafe: live SoC/package sensors (`TC*` / `Tp*`) at 102 °C → Auto. `Tf*` trip-point keys are ignored.
- API listens on `127.0.0.1:8765` only.
- Process exit / SIGTERM / SIGINT → Auto.
- One writer queue owns every SMC write; reads use a second SMC view, so a busy write can never delay a failsafe check.

## States

The menubar shows what the sensors report: **OFF** (nothing spinning), **MAX**, **23%** (auto), **—** (no data). OFF is display-only — no user, agent or endpoint can command it. `GET /status` returns the same value as `state`, and `fanctl status` prints it.

This uses undocumented SMC keys. Firmware thermal protection still applies. Use at your own risk.

## Install

```bash
./scripts/install-app.sh
```

Open **Fan Control**. If `fand` is not running it asks for your password **once** and installs a LaunchDaemon. After that the helper starts at boot and is already up when the app opens.

Or install the daemon yourself: `./scripts/install.sh`.

In the menu: **Open at Login**. Then **Max** / **Auto**.

```bash
fanctl status
fanctl max --ttl 900
fanctl auto
curl -s http://127.0.0.1:8765/status
```

MCP: `npx tsx mcp/src/index.ts` or `npm --prefix mcp install && npm --prefix mcp run build`. Tools: `get_thermal_status`, `max_fans`, `set_fan_auto`.

Uninstall: `./scripts/uninstall.sh`.

## License

MIT. See [LICENSE](LICENSE).
