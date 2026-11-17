# Fibre Monitor

iPhone app for **Huawei OptiXstar HG8145X6** fibre routers (ONTs) across firmware variants (including HG8145X6-10 / `COMMON` and `GNMTNNCE`). It logs in to the router's web interface on the local network and provides:

- **Multi-router profiles:** save multiple routers (each with Keychain credentials, detected model and config mode, and per-router device nicknames), pick on launch when 2+ profiles exist, or switch live from Dashboard / Settings
- **Dashboard:** live download/upload speed with a 60-second sparkline, optical Rx power range bar (`Good` / `Weak` / `Bad` / `Too strong`) and PON state, WAN connection details (PPPoE/IPoE, CGNAT flag, uptime, gateway, DNS), conditional ONT uptime / Tx laser power / CPU & memory load when reported by the firmware, and confirmed router restart
- **Clients:** searchable online/offline device list with Wi-Fi band or LAN port badges, live per-device traffic rates (when non-zero), DHCP vendor & lease details, **Rename on Router** (`UserDevAlias`), local iPhone-only nicknames, and offline device removal
- **Wi-Fi:** 2.4 GHz / 5 GHz radio switches (with connected-radio & last-radio safeguards), on-demand QR join code generation and passphrase reveal/copy (never saved on disk), and WPA2-PSK SSID & password editing (other security modes direct to the router's web page) with typed SSID confirmation
- **Tools & LAN:** built-in router Ping / Traceroute diagnostics, LAN / DHCP pool & secondary subnet inspection, and explicit session logout

Native SwiftUI, iOS 16+, with system Liquid Glass on iOS 26+.

## Layout

```text
FibreMonitor/Models      Data models, error types, router profiles
FibreMonitor/Services    HuaweiOntClient, HuaweiJs, OntTransport, SettingsStore (Keychain)
FibreMonitor/ViewModels  MonitorViewModel (polling, NWPathMonitor, actions, haptics)
FibreMonitor/Views       4-tab Liquid Glass UI (Dashboard, Clients, Wi-Fi, Settings)
FibreMonitorTests        Parser, session, multi-router, WlanBasic, and Phase 4 write unit tests
tools/gen_icon.py        Regenerates the app icon
```
