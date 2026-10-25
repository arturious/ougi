<p align="center"><img src="extension/assets/icon.png" width="128" alt="Ougi icon"></p>

# Ougi

Every temperature sensor and fan in your Mac, with manual fan control and overheat protection — as a
[Raycast](https://raycast.com) extension and a small command-line tool.

- Reads all SMC temperature sensors (CPU cores, GPU, SoC, memory, SSD, battery, power, ambient…) and groups them.
- Shows fan speed, mode and range for each fan.
- Sets all fans to Auto, Max, a percentage or an exact RPM.
- **Overheat protection:** if fans are below max under manual control and any CPU/GPU sensor reaches 95 °C,
  the daemon hands the fans back to macOS.
- Apple Silicon (tested on M4 Pro, macOS 27) and Intel Macs. Macs without fans show temperatures only.

## Setup

1. Install the command-line tool (it is built from this repository's source):

   ```sh
   brew install arturious/tap/ougi
   ```

   Temperatures and fan speeds now work, without any special permissions.

2. To control the fans, install the root daemon once:

   ```sh
   sudo ougi daemon install
   ```

3. Install the **Ougi** extension from the Raycast Store.

After `brew upgrade ougi`, run `sudo ougi daemon install` again — the extension tells you when the daemon is
out of date.

## Command line

```
ougi read                                  temperatures, fans and daemon state as JSON
ougi fan <id|all> <auto|max|rpm|percent%>  set fan speed (needs the daemon)
sudo ougi daemon install                   install the root daemon that enables fan control
sudo ougi daemon uninstall                 remove it and return fans to system control
ougi daemon status                         show whether the daemon is running
ougi dump                                  print every SMC key (debugging)
```

## How it works

Reading SMC keys needs no privileges, but writing them requires root. `sudo ougi daemon install` copies the
binary to `/Library/PrivilegedHelperTools/ougi` (root-owned — Homebrew's prefix is user-writable, so the
daemon never runs from there) and registers `/Library/LaunchDaemons/dev.ougi.daemon.plist` with launchd.

The daemon listens on `/var/run/ougi.sock` and accepts exactly three requests: read sensors, read status, and
set fan speed (validated and clamped to the fan's hardware range). It never runs arbitrary commands. Every two
seconds it checks the overheat guard. When it stops — `daemon uninstall`, shutdown, or a crash restart — it
returns all fans to automatic control.

On Apple Silicon, fan mode keys are locked by `thermalmonitord` until the SMC's fan test mode (`Ftst`) is
enabled; taking over takes about five seconds. Ougi clears `Ftst` as soon as no fan is under manual control,
so macOS manages the fans exactly as before.

Logs: `/var/log/ougi.log`.

## Uninstall

```sh
sudo ougi daemon uninstall
brew uninstall ougi
```

## Building from source

```sh
cd cli && swift build -c release      # .build/release/ougi
cd extension && npm install && npm run dev
```

The icon is drawn by `tools/icon.swift`: `swiftc -o /tmp/icon tools/icon.swift && /tmp/icon extension/assets/icon.png`.

## License

MIT
