# Fan Control

Menubar app, CLI, HTTP API, and MCP server for Apple Silicon Macs (M1–M5). **Auto** (macOS default) or **Max** (hardware-reported maximum). There is no low/custom RPM path.

## Safety

- Writes require root (`fand` LaunchDaemon). Reads do not.
- Max only — cannot pin fans below the firmware floor.
- TTL dead-man switch (default 15 min, max 2 h) returns to Auto.
- Failsafe: live SoC/package sensors (`TC*` / `Tp*`) at 102 °C → Auto. `Tf*` trip-point keys are ignored.
- API listens on `127.0.0.1:8765` only.
- Process exit / SIGTERM / SIGINT → Auto.

This uses undocumented SMC keys. Firmware thermal protection still applies. Use at your own risk.

## Install

```bash
# Menubar app
./scripts/install-app.sh

# Root daemon at boot (password once)
./scripts/install.sh
```

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
