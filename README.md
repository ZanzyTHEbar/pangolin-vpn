# Pangolin Podman client

Run the Pangolin client for any linux machine with the upstream image `ghcr.io/zanzythebar/pangolin-client-container:latest` using a rootful Podman Quadlet system service.

- `./login.sh`: run the interactive `login-plain` flow with rootless Podman, then sync the resulting auth/device state into the rootful volumes.
- `./run.sh`: run the actual VPN client as a rootful systemd-managed Quadlet service.

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

    This copies the Quadlet files into `/etc/containers/systemd/`, installs the DNS helper at `/usr/local/bin/pangolin-client-dns`, copies `.env` into `/etc/pangolin-client/pangolin-client.env`, reloads the system manager, enables the generated service for boot, and starts or restarts `pangolin-client.service`.

    The repo remains the source of truth. Rerun `./run.sh` after changing `.env` or the Quadlet files.

    While the service is up, the DNS helper configures `systemd-resolved` on the `pangolin` interface to use Pangolin DNS and route the domains from `PANGOLIN_ROUTE_DOMAINS` there. When the service stops, that DNS state is reverted.

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
sudo podman ps --filter name=pangolin-client
sudo podman volume inspect pangolin-client-config pangolin-client-etc
```

## Files

- `.env`: machine-specific runtime settings used as the local source of truth.
- `login.sh`: rootless login helper that syncs the resulting auth/device state into the rootful service volumes.
- `run.sh`: installs the rootful Quadlet artifacts and starts the system service.
- `pangolin-dns.sh`: applies and reverts host `systemd-resolved` settings for Pangolin only while the service is up.
- `quadlet/`: rootful Podman Quadlet definitions that get copied into `/etc/containers/systemd/`.

## Notes

- Keep `.env` to simple `KEY=VALUE` lines only.
- Run `./login.sh` as your normal user, not with `sudo`.
- `./login.sh` keeps a rootless copy of the Pangolin auth/device state so it can sync that state into the rootful service volumes.
- `PANGOLIN_ROUTE_DOMAINS` controls which suffixes the host sends to Pangolin DNS while the service is up. Set it as a comma-separated list like `home.arpa,internal.example` if needed.
- `./run.sh` installs a service env file at `/etc/pangolin-client/pangolin-client.env` for the rootful system service.
- `./run.sh` installs `/usr/local/bin/pangolin-client-dns` and wires it to `ExecStartPost` / `ExecStopPost` so Pangolin DNS only exists while the service is actually running.
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
