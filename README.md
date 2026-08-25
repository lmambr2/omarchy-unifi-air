# UniFi Air for Omarchy

Live UniFi Protect **UP-AirQuality** readings on the Omarchy bar: AQI and CO₂
at a glance, with temperature, humidity, PM, VOC and vape in the panel.

It talks to Protect on your UniFi OS console over the LAN (or a VPN). AQI and
CO₂ currently come from Protect's private bootstrap — the documented
Integration API can see the sensor exists but omits those fields on Protect
7.2. A local UniFi OS user with Protect view access is the supported login.
Cloud-only UI.com accounts will not work.

Temperature defaults to Fahrenheit.

## Install

```bash
omarchy plugin add https://github.com/lmambr2/omarchy-unifi-air.git --enable
omarchy restart shell
```

If the widget is enabled but not visible, place it explicitly:

```bash
omarchy plugin enable lane.unifi-air --section right
omarchy restart shell
```

Update or remove:

```bash
omarchy plugin update lane.unifi-air --yes
omarchy plugin remove lane.unifi-air
```

Requires `curl`, `jq` and `secret-tool` (package `libsecret`), all present on a
stock Omarchy system.

## Setup

1. In UniFi OS create a **local** user with Protect view access
   (**Settings → Admins & Users**). A dedicated viewer is enough; do not use
   your owner account.
2. Click the widget and press **Set up**, or run
   `~/.config/omarchy/plugins/lane.unifi-air/unifi-air-login` in a terminal.
3. Enter the console address (your default gateway is offered), choose
   whether to accept its self-signed certificate (the default is to allow it
   on a private LAN address, and to verify TLS otherwise), and sign in with
   the local username and password.

HTTP without TLS is refused unless you confirm it. The Network Integration
API key is offered as option 2 for completeness; on current Protect it will
not show AQI or CO₂.

The address is kept in `~/.local/state/omarchy/unifi-air/config`; the password
or key goes into the keyring under the plugin id and is never written
anywhere else or passed on a command line. `unifi-air-login --status` shows
what is configured, `unifi-air-login --forget` removes it all.

A leftover Network API key stored by `hegjon.unifi` is tried as a fallback
for the Integration API only.

## Settings

Under the widget's settings in the bar:

- Show CO₂ next to AQI on the bar
- Temperature in Fahrenheit (default on)
- Compact bar label (numbers only)
- Refresh interval
- Sensor name (blank = first UP-AirQuality)

Middle-click the icon, or press **R** in the panel, to refresh. Press **S**
to run setup. IPC: `omarchy-shell lane.unifi-air open|close|toggle|refresh`.

## Development

`test/test-manifest`, `test/test-url`, `test/test-extract`, `test/test-fetch`
(stub controller, no real credentials) and `test/lint` (qmllint; needs an
Omarchy machine).

```bash
~/.config/omarchy/plugins/lane.unifi-air/test/run
omarchy plugin validate ~/.config/omarchy/plugins/lane.unifi-air
```

## License

MIT. Not affiliated with, endorsed by, or supported by Ubiquiti Inc.; UniFi
and Protect are their trade marks.
