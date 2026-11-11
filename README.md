# factorio-ha

Live Factorio server state in Home Assistant: a Factorio mod, a small relay
next to the server, and a Home Assistant integration.

```
Factorio mod ──UDP──▶ relay ──MQTT──▶ Home Assistant
```

Status: proof of concept. Protocol: [docs/protocol.md](docs/protocol.md).

| Part | Path |
|---|---|
| Factorio mod (`factorio-ha`, Factorio 2.1) | `mod/factorio-ha/` |
| Relay (Python, Docker) | `relay/` |
| Home Assistant integration (`factorio`) | `custom_components/factorio/` |
