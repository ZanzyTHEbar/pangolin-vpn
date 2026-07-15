# Pangolin Podman client

Run the Pangolin client for any linux machine with the upstream image [`ghcr.io/zanzythebar/pangolin-client-container:latest`](https://github.com/ZanzyTHEbar/pangolin-client-container) using a rootful Podman Quadlet system service.

- `./login.sh`: run the interactive `login-plain` flow with rootless Podman, then sync the resulting auth/device state into the rootful volumes.
- `./run.sh`: run the actual VPN client as a rootful systemd-managed Quadlet service.
- `pangolin-vpn`: control the installed service explicitly with `on`, `off`, `restart`, and `status`.

Do not delete the `pangolin-client-config` or `pangolin-client-etc` volumes unless you intentionally want to forget your machine and log in again.

Set `PANGOLIN_ENDPOINT` to your Pangolin dashboard URL, for example `https://vpn.example.com`.

## Prerequisites

- Podman
- `sudo`
- `rsync`
- systemd
- `/dev/net/tun`
- `NET_ADMIN` support for Podman

## Design

- Interactive auth: rootless Podman `login-plain`
- Persistent runtime: rootful Podman Quadlet service
- Shared state handoff: `./login.sh` copies the rootless auth/device state into the rootful volumes `pangolin-client-config` and `pangolin-client-etc`
- Browser handling: the host opens your Pangolin device-login page (`$PANGOLIN_ENDPOINT/auth/login/device`); the script filters Pangolin's redundant in-container browser lines from displayed output
- Host DNS integration: `./run.sh` installs a helper that applies `resolvectl` DNS settings only while the rootful Pangolin container is running and the tunnel interface exists, then reverts them when the service stops. Routed domains come from `PANGOLIN_ROUTE_DOMAINS` in `.env` instead of alias discovery.
- Explicit control: `pangolin-vpn` stores manual intent in `/run/pangolin-client-control/enabled` so readiness checks can avoid silently starting the VPN unless you opted in.
- Route readiness: optional helpers can prefer a trusted LAN path for configured private hosts, otherwise restore those host routes through Pangolin and wait for a configured TCP target.

## Quick start

1. Review `.env`

   ```bash
   ${EDITOR:-vi} .env
   ```

   If `.env` is missing, recreate it with `cp .env.example .env`. Set `PANGOLIN_ENDPOINT` to your dashboard URL. Add `PANGOLIN_CLIENT_ID` and `PANGOLIN_CLIENT_SECRET` only if you want credential-based login.

2. Log your machine into Pangolin

   ```bash
   ./login.sh
   ```

    After the login succeeds, the script copies the resulting auth/device state into the rootful named volumes `pangolin-client-config` and `pangolin-client-etc` that the systemd service uses.

    The script opens the generic device login page from the host before Pangolin takes over the terminal:

    - `https://vpn.example.com/auth/login/device`

    Pangolin then prints the one-time code directly in your terminal from the rootless `login-plain` flow. Paste the code into the browser page, approve the device, and wait for the script to sync the resulting state into the rootful service volumes.

    The script already opens the browser page from the host, so it filters Pangolin's redundant in-container browser lines (`Press Enter to open...`, `Failed to open browser automatically`, `Please manually visit...`) from the displayed output.

3. Install and start the system service

   ```bash
   ./run.sh
   ```

    This copies the Quadlet files into `/etc/containers/systemd/`, installs the DNS helper at `/usr/local/bin/pangolin-client-dns`, installs the generic control/readiness helpers, installs `pangolin-vpn-ready.service`, copies `.env` into `/etc/pangolin-client/pangolin-client.env`, reloads the system manager, enables the generated service for boot, and starts or restarts `pangolin-client.service`.

    The repo remains the source of truth. Rerun `./run.sh` after changing `.env` or the Quadlet files.

    While the service is up, the DNS helper configures `systemd-resolved` on the `pangolin` interface to use Pangolin DNS and route the domains from `PANGOLIN_ROUTE_DOMAINS` there. When the service stops, that DNS state is reverted.

4. Control the service explicitly when you need to turn the VPN on or off

   ```bash
   pangolin-vpn status
   sudo pangolin-vpn on
   sudo pangolin-vpn off
   ```

## Control And Readiness

`pangolin-vpn` is the user-facing wrapper installed to `/usr/local/bin/pangolin-vpn`.

```bash
pangolin-vpn status
sudo pangolin-vpn on
sudo pangolin-vpn off
sudo pangolin-vpn restart
```

The wrapper uses these settings:

```env
# Defaults shown.
PANGOLIN_SERVICE=pangolin-client.service
PANGOLIN_CONTROL_DIR=/run/pangolin-client-control
PANGOLIN_CONTROL_MARKER=/run/pangolin-client-control/enabled
PANGOLIN_INTERFACE_NAME=pangolin
PANGOLIN_ROUTE_HELPER=/usr/local/sbin/pangolin-route-helper
```

`pangolin-vpn on` starts the system service, waits for it to become active, creates the manual marker, runs the route helper, and prints status. `pangolin-vpn off` removes the marker, stops the service, runs the route helper, and verifies the service is inactive.

`./run.sh` still starts or restarts `pangolin-client.service` after installation, but it does not create the manual marker. Run `sudo pangolin-vpn on` when you want readiness gates to treat VPN startup as explicitly allowed.

`pangolin-route-helper` is installed to `/usr/local/sbin/pangolin-route-helper`. It is optional and no-ops when `PANGOLIN_MANAGED_HOSTS` is empty. When configured, it prefers trusted LAN routes for private hosts and restores those routes through the Pangolin interface when you are away from that LAN.

```env
PANGOLIN_MANAGED_HOSTS=10.0.0.10,10.0.0.11
PANGOLIN_TRUSTED_LAN_PREFIX=10.0.0.
PANGOLIN_TRUSTED_GATEWAY=10.0.0.1
PANGOLIN_TRUSTED_GATEWAY_MAC=
PANGOLIN_TRUSTED_GATEWAY_PROBE_TIMEOUT=2
PANGOLIN_ROUTE_STATE_DIR=/run/pangolin-route-helper
```

`pangolin-vpn-ready` is installed to `/usr/local/sbin/pangolin-vpn-ready`. Use it from systemd units or scripts that need a private resource before they continue.

```env
PANGOLIN_READY_TARGET_HOST=10.0.0.10
PANGOLIN_READY_TARGET_PORT=2049
PANGOLIN_READY_TIMEOUT=75
```

Readiness succeeds immediately if a trusted LAN path reaches the target. If trusted LAN is absent, readiness requires the manual marker created by `pangolin-vpn on`, starts `pangolin-client.service`, and waits until the target is reachable through the Pangolin interface.

`./run.sh` also installs a generic oneshot unit at `/etc/systemd/system/pangolin-vpn-ready.service`. Other units can depend on it directly, for example with fstab options:

```text
x-systemd.requires=pangolin-vpn-ready.service,x-systemd.after=pangolin-vpn-ready.service
```

Example DragonServer-style configuration:

```env
PANGOLIN_MANAGED_HOSTS="192.168.0.191 192.168.0.218"
PANGOLIN_TRUSTED_LAN_PREFIX=192.168.0.
PANGOLIN_TRUSTED_GATEWAY=192.168.0.1
PANGOLIN_TRUSTED_GATEWAY_MAC=3c:84:6a:fa:07:6a
PANGOLIN_READY_TARGET_HOST=192.168.0.191
PANGOLIN_READY_TARGET_PORT=2049
```

## Test The VPN

After `./run.sh`, use these checks.

1. Confirm the systemd unit is active.

   ```bash
   sudo systemctl status pangolin-client.service
   ```

2. Follow the service logs and watch for successful tunnel startup instead of TUN permission failures.

   ```bash
   sudo journalctl -u pangolin-client.service -f
   ```

3. Confirm the container is running.

   ```bash
   sudo podman ps --filter name=pangolin-client
   ```

4. Inspect the container logs directly.

   ```bash
   sudo podman logs pangolin-client
   ```

5. Check for the Pangolin-created tunnel interface on the host. If you set `PANGOLIN_INTERFACE_NAME`, replace `<iface>` with that value. Otherwise inspect the full link list first.

   ```bash
   ip -brief link
   ip -brief addr show dev <iface>
   ```

6. Verify routing changed after the client came up.

   ```bash
   ip route
   ```

7. Confirm host DNS is using Pangolin while the service is active. If you set `PANGOLIN_INTERFACE_NAME`, replace `pangolin` below with that value.

   ```bash
   resolvectl status pangolin
   getent ahosts <private-host.example.internal>
   getent ahosts <private-nfs.example.internal>
   ```

8. Test a known internal/private destination reachable only through Pangolin. Replace `<private-host-or-alias>` with one of your actual private Pangolin targets. Remember that ICMP does not work with aliases, you must use an FQDN or CIDR. 

   ```bash
   getent ahosts <private-host-or-alias>
   ping -c 3 <private-host>
   curl -I http://<private-host-or-alias>
   ```

## Useful commands

```bash
sudo systemctl status pangolin-client.service
sudo journalctl -u pangolin-client.service -f
sudo systemctl restart pangolin-client.service
sudo systemctl stop pangolin-client.service
pangolin-vpn status
sudo pangolin-vpn on
sudo pangolin-vpn off
sudo podman ps --filter name=pangolin-client
sudo podman volume inspect pangolin-client-config pangolin-client-etc
sudo pangolin-route-helper --status
sudo pangolin-vpn-ready
```

## Files

- `.env`: machine-specific runtime settings used as the local source of truth.
- `login.sh`: rootless login helper that syncs the resulting auth/device state into the rootful service volumes.
- `run.sh`: installs the rootful Quadlet artifacts and starts the system service.
- `pangolin-dns.sh`: applies and reverts host `systemd-resolved` settings for Pangolin only while the service is up.
- `pangolin-vpn`: explicit service on/off/status wrapper.
- `pangolin-route-helper`: optional managed-route reconciler for trusted LAN and Pangolin paths.
- `pangolin-vpn-ready`: optional readiness gate for private resources.
- `systemd/pangolin-vpn-ready.service`: generic systemd readiness unit for mounts or services that need a private target.
- `systemd/`: optional drop-ins installed for the rootful service.
- `quadlet/`: rootful Podman Quadlet definitions that get copied into `/etc/containers/systemd/`.

## Notes

- Keep `.env` to simple `KEY=VALUE` lines only.
- Run `./login.sh` as your normal user, not with `sudo`.
- `./login.sh` keeps a rootless copy of the Pangolin auth/device state so it can sync that state into the rootful service volumes.
- `PANGOLIN_ROUTE_DOMAINS` controls which suffixes the host sends to Pangolin DNS while the service is up. Set it as a comma-separated list like `home.arpa,internal.example` if needed.
- `./run.sh` installs a service env file at `/etc/pangolin-client/pangolin-client.env` for the rootful system service.
- `./run.sh` installs `/usr/local/bin/pangolin-client-dns` and wires it to `ExecStartPost` / `ExecStopPost` so Pangolin DNS only exists while the service is actually running.
- `./run.sh` installs `/usr/local/bin/pangolin-vpn`, `/usr/local/sbin/pangolin-route-helper`, `/usr/local/sbin/pangolin-vpn-ready`, `/etc/systemd/system/pangolin-vpn-ready.service`, and a route-helper drop-in for `pangolin-client.service`.
- `./run.sh` enables `pangolin-client.service` for boot by enabling the Quadlet-generated unit name after the source files are installed and the system manager is reloaded.
- `./run.sh` may stop an old user Pangolin service and remove user Quadlet symlinks from `${XDG_CONFIG_HOME:-~/.config}/containers/systemd/` when those symlinks point back to this repo, but it does not remove old rootless volumes.
- If you still have an old rootless user service from the previous setup, stop and disable it manually before relying on the new system service:

  ```bash
  systemctl --user stop pangolin-client.service
  systemctl --user disable pangolin-client.service
  systemctl --user daemon-reload
  ```

- If you intentionally want to forget your machine completely and force a fresh login on the next run:

  ```bash
  sudo systemctl stop pangolin-client.service
  podman volume rm pangolin-client-config pangolin-client-etc
  sudo podman volume rm pangolin-client-config pangolin-client-etc
  ```
