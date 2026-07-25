# Automatic deployment of mac CI runners

Scripts to image a mac (Intel or Apple Silicon) into a Julia CI runner:
erase, install a known macOS, create the `julia` user, enable SSH, and install
Xcode/Homebrew/juliaup — with one image build up front and near-zero per-machine
interaction (Intel) or one short Setup Assistant click-through (Apple Silicon).

Everything is plain `bash` around Apple's own `startosinstall`. An earlier
version of this process used MDS (Mac Deploy Stick); see "History" at the
bottom for why that was dropped.

## How it works

`build-image.sh` produces `juliaci.dmg` containing a full macOS installer app,
`firstboot.pkg`, and two launch scripts (`run` for Intel, `run-as` for Apple
Silicon). On the target the disk is erased and macOS installed; on the first
boot of the new system the package suppresses Setup Assistant, and a
LaunchDaemon (`firstboot/setup.sh`) configures the machine to match what the
old MDS workflow + the PR #57 follow-up notes established: `julia` user
(uid 601, zsh, admin) with auto-login (/etc/kcpassword), computer name
`<prefix>-<serial>` (default prefix `honeycrisp`, see `--name-prefix`), SSH +
Screen Sharing on, Wi-Fi off, all sleep/hibernation off, restart-on-power-
failure on; it then fetches Xcode from your HTTP server and runs the
`scripts/` in order (Xcode select/license, repo clone, Homebrew, juliaup
release+lts, tailscale, buildbot authorized_keys), and finishes by sweeping
`chown -R julia /Users/julia`.

## Building the image (once per macOS/Xcode combination)

Needs a mac with ~40 GB free. All steps in this directory.

1. Pick a macOS version (coordinate with @staticfloat / whatever the existing
   queue runs). Note: 2018 Intel minis top out at Sequoia (15); macOS 26
   dropped Intel minis.
2. Get the **full** installer app, either
   `softwareupdate --fetch-full-installer --full-installer-version <ver>`
   (lands in /Applications) or [mist-cli](https://github.com/ninxsoft/mist-cli).
3. Get a matching Xcode from https://developer.apple.com/download/all/?q=xcode
   (cross-reference versions at https://xcodereleases.com). Either keep the
   `.xip`, or expand it to `Xcode.app` (faster per-machine: the image build
   tars the app once instead of every machine running `xip --expand`).
4. Build:
   ```
   JULIA_PASSWORD='<ssh password for the julia user>' ./build-image.sh \
       --installer "/Applications/Install macOS Sequoia.app" \
       --server http://192.168.1.10 \
       --xcode /path/to/Xcode.app \
       --output-dir out
   ```
5. Serve `out/` at the `--server` URL. The server **must support HTTP range
   requests** — `python3 -m http.server` does NOT and `hdiutil` will fail
   against it. Working options: `caddy file-server --root out --listen :8000
   --access-log` (use `--access-log`: watching requests for the dmg/pkg/Xcode
   asset is your deployment progress bar and reveals each machine's IP),
   `npx http-server out -p 80`, or nginx. To see who's connected without
   logs: `lsof -nP -i :8000`. Verify range support (expect `206`):
   ```
   curl -r 0-99 -o /dev/null -s -w '%{http_code}\n' http://192.168.1.10/juliaci.dmg
   ```
   The server is needed during deployment *and* during each machine's first
   boot (that's when Xcode is fetched).

## Deploying a machine

### Intel

1. Boot into Recovery: hold **Cmd-R** (or **Option-Cmd-R** for internet
   recovery — prefer that on machines whose local recovery is much older than
   the macOS you're installing).
2. If on Wi-Fi, join the network from the recovery menu bar.
3. Utilities → Terminal:
   ```
   hdiutil mount http://192.168.1.10/juliaci.dmg
   /Volumes/JULIACI/run
   ```
   (`run -y` skips the confirmation; `run [-y] <volname>` if the target volume
   isn't named "Macintosh HD" — check Disk Utility, and erase the disk as APFS
   "Macintosh HD" first if it's blank or hosed.)
4. Walk away. The machine reboots into the installer (streaming the installer
   over HTTP — Ethernet strongly recommended), then boots to the login window
   and runs first-boot setup. Progress: `tail -f /var/log/juliaci-firstboot.log`
   over SSH once the machine answers.

### Apple Silicon

There is no unattended erase from recovery without MDM — erase+install needs a
volume-owner's credentials, and only Automated Device Enrollment can skip
Setup Assistant on a virgin machine. So one short manual hop:

1. Boot the machine as shipped, click through Setup Assistant minimally:
   skip everything skippable, create a throwaway admin user `setup`.
2. Terminal:
   ```
   hdiutil mount http://192.168.1.10/juliaci.dmg
   sudo /Volumes/JULIACI/run-as
   ```
   It prompts for the `setup` user's credentials, then erases and reinstalls.
3. The machine must stay networked on first boot (Apple activation). After
   that, identical to Intel: julia user, SSH, no Setup Assistant.

If an Apple Silicon machine is in an unknown/locked state, DFU-restore it
first from a host mac with Apple Configurator (`cfgutil restore`), then start
from step 1.

### Finding a machine on the network

No need to hunt for the IP: setup.sh sets the hostname (`<prefix>-<serial>`,
serial is on the bottom label) and enables SSH *early* in first boot, so
`ssh julia@<prefix>-<serial>.local` works minutes after first boot — even
while the console still shows Setup Assistant or the login window. To
discover machines without reading labels: `dns-sd -B _ssh._tcp local.`
Fallback if mDNS is blocked: `arp -a` on the machine serving the image after
the mini fetches Xcode.

### Afterwards (both)

Verify over SSH (`ssh julia@<ip>`): `xcodebuild -version`, `brew --version`,
`juliaup status`, `ls ~/src/sandboxed-buildkite-agent`.

Then enroll the machine into the Julia tailnet (headscale). The image installs
tailscale (`scripts/04-install-tailscale.sh`) but enrollment needs per-machine
credentials, so it's driven from your machine over SSH:

```
./enroll-tailscale.sh <machine-ip>                  # interactive: prints a
                                                    # URL for the headscale admin
TS_AUTHKEY=<key> ./enroll-tailscale.sh <machine-ip> # with a preauth key
```

Either way this runs `tailscale up --login-server https://headscale.julialang.org
--advertise-tags "tag:julialang-ci"` on the machine (the flags the headscale
admin expects). The tailnet hostname defaults to the computer name,
`<prefix>-<serial>`, so no explicit --hostname is needed. The script installs
tailscale first if the machine was imaged before that script existed.

Finally, send the IP (tailnet name) and julia password to @staticfloat to add
the machine to the Buildkite queues. That last step (documented in the
top-level README) amounts to: a `config.toml` from
`platforms/macos-seatbelt/config.toml.example` with the queue's runner
groups, the Buildkite agent token into `agent/secrets/buildkite-agent-token`
(`chmod o-rwx`), then `bin/bk enable && bin/bk start` in
`~julia/src/sandboxed-buildkite-agent` — the token and queue conventions are
the org-admin inputs the deployer can't self-serve.

## Troubleshooting / gotchas (hard-won, please append)

- **`hdiutil mount http://...` fails or hangs**: your HTTP server probably
  doesn't do range requests (see above).
- **Machine sits at the login window and nothing happens**: the firstboot
  LaunchDaemon didn't get loaded on that boot — reboot once; it runs on the
  next boot (it self-removes when done). If still nothing, check
  `/var/log/juliaci-firstboot.log` and `/var/log/install.log`.
- **`startosinstall` in recovery rejects flags or crashes**: the recoveryOS is
  much older than the installer. Reboot with Option-Cmd-R (internet recovery)
  to get the newest recovery environment.
- **`--eraseinstall cannot be used in conjunction with --volume`**: correct —
  in recoveryOS you erase first, then install. `run` does exactly that
  (`diskutil eraseDisk APFS "Macintosh HD" GPT diskN` + `startosinstall
  --volume`); `--eraseinstall` is only valid from a booted OS, which is why
  `run-as` (Apple Silicon path) uses it.
- **Machine boots into Setup Assistant instead of the login window**: the
  firstboot package failed or never ran — `.AppleSetupDone` never got
  touched. Check for `/var/log/juliaci-firstboot.log` (absent → pkg never
  ran) and grep `/var/log/install.log` for `org.julialang.ci.firstboot`.
  Field cases, both fixed in the current scripts: (a) PackageKit said
  `The file "postinstall" doesn't exist` with `NSFilePosixPermissions = 420`
  — script in the pkg but not executable, from a checkout with lost exec
  bits; build-image.sh now forces 755 at build time. (b) The pkg was applied
  only from recovery onto the erased volume — the OS install creates a fresh
  Data volume and discards pre-placed payload, so deliver via
  `--installpackage` (recovery-time `installer` is validation only; both are
  what `run` now does). Rescue without reimaging: click through Setup
  Assistant with a throwaway admin — account name AND full name must not
  contain "julia" in any case (macOS aliases full names to logins, so a
  full name like "Julia" hijacks every julia-targeting command; use
  `setup`/`setup`) — then
  `curl -O http://<server>/firstboot.pkg`,
  `sudo installer -pkg firstboot.pkg -target /`, reboot (setup reboots
  itself again when done), and later `sudo sysadminctl -deleteUser
  <throwaway>` from the julia account.
- **Rolling out a pkg fix without rebuilding the dmg**: build with
  `--pkg-only`, serve `out/firstboot.pkg`, and launch recovery deploys as
  `SERVER=http://<host>:<port> bash run` — `run` then prefers the served pkg
  over the one baked into the dmg.
- **firstboot.pkg via `--installpackage` (Apple Silicon run-as path)**: must
  be a distribution ("product archive") package — `build-image.sh` wraps
  with `productbuild`. If packages mysteriously don't apply there, try
  signing: `PKG_SIGN_ID="Developer ID Installer: ..." ./build-image.sh ...`.
- **Cmd-R doesn't enter recovery on a used T2 machine**: firmware password
  set by the previous owner; you need it (or an Apple Store) to clear it.
- **julia user has no secure token / volume ownership** (script-created
  users don't get one): known; CI doesn't need it. On fully-unattended
  machines nobody holds a token — for OS upgrades, redeploy the image. On
  machines where a human clicked through Setup Assistant (rescues, Apple
  Silicon), the throwaway SA user holds the only token and macOS refuses to
  delete "the last secure token user" — transfer it first, then delete:
  `sysadminctl -secureTokenOn julia -password <julia-pw> -adminUser
  <throwaway> -adminPassword <pw>`, then `sysadminctl -deleteUser
  <throwaway>`. Bonus: that julia is then a volume owner.
- **Xcode license/first-launch prompts on first build**: should be handled by
  `scripts/00-select-xcode.sh` (`-license accept`, `-runFirstLaunch`); re-run
  it if Xcode was installed manually after deployment.
- Historical script bugs fixed in the bash rewrite, kept here so they aren't
  reintroduced: Homebrew shellenv hardcoded the Apple Silicon prefix
  (`/opt/homebrew`) which is wrong on Intel (`/usr/local`);
  `NONINTERACTIVE=1 sudo -i ...` never reached the Homebrew installer because
  `sudo -i` scrubs the environment; `sudo -i -u julia curl ... | sh` ran the
  juliaup installer as root (the pipe's right-hand side is not under sudo);
  the Homebrew installer switches xcode-select to the Command Line Tools it
  installs, undoing 00-select-xcode.sh (02 now switches back); `brew` cannot
  run as root from a LaunchDaemon ("Error: $HOME must be set") so root-side
  scripts must use hardcoded brew-adjacent paths, never `brew --prefix`.

## History

This process originally (PR #57, 2023) used MDS
(https://twocanoes.com/products/mac/mds/) with the workflow file
`setupci.mdsworkflows` kept in this directory. MDS became a paid subscription
(~2024); it can still be built from its open source at
https://bitbucket.org/twocanoes/macdeploystick (needs
`carthage bootstrap --use-xcframeworks --platform macOS` and "Sign to Run
Locally"), but since its Intel value was a GUI around `startosinstall` and its
Apple Silicon flow was no more unattended than the above, it was replaced with
these scripts. At real fleet scale, the sanctioned fully-unattended path is
Apple Business Manager + an MDM with Automated Device Enrollment.
