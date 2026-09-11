# setup-hawser

Install a pinned [Hawser](https://github.com/hawserhq/hawser) — the upstream
open source Docker Engine on Windows via WSL2 — on a Windows runner, verified
against the release's `SHA256SUMS`, and wait for the engine to answer. One line
replaces Docker Desktop on the runner: no per-runner license, no auto-updates
you did not schedule, and the same pinned engine your developers run.

```yaml
- uses: hawserhq/setup-hawser@v1
  with:
    version: 0.3.0            # or omit: "latest"
- run: docker run --rm hello-world
```

After the step, `docker` targets the engine (the `hawser` docker context is
exported as `DOCKER_CONTEXT`), so compose, Testcontainers, Dev Containers and
anything else that follows docker follow it too.

## Laptop == runner: the lockfile

Commit a `hawser.lock` (`hawser lock` writes one) and the action installs
**exactly that engine** — dockerd, containerd, runc, BuildKit to the commit —
while `hawser install --locked hawser.lock` does the same on a laptop. "Works
locally, fails in CI" from engine drift stops being a category. The lock is
auto-detected in the working directory, or pointed at with `lockfile:`.

## The one thing to know: WSL2

Installing the engine needs WSL2. **GitHub-hosted `windows-latest` runners have
it** — this repo's own CI installs the engine and runs `docker run hello-world`
on one — and so does any self-hosted Windows runner with WSL2 enabled. On a
machine without WSL2 the action fails with a clear "WSL2 is not available"
message; use `install: false` there to stage `hawser.exe` on PATH only (useful
for `hawser bundle`, `hawser lock`, packaging steps).

Self-hosted runners also need a logged-on session for WSL2 — see
[auto-logon-runner.md](https://github.com/hawserhq/hawser/blob/main/docs/auto-logon-runner.md);
`hawser runner check` verifies that setup.

## Inputs

| Input | Default | What it does |
| --- | --- | --- |
| `version` | `latest` | Hawser release to install, e.g. `0.3.0` |
| `lockfile` | `` | Path to a `hawser.lock` (auto-detects `./hawser.lock`) |
| `install` | `true` | Install and start the engine; `false` stages `hawser.exe` only |
| `install-args` | `` | Extra `hawser install` arguments |
| `wait` | `3m` | How long to wait for the engine to answer |
| `token` | `${{ github.token }}` | For the release API when resolving `latest` |

## Outputs

| Output | Meaning |
| --- | --- |
| `version` | Installed Hawser version |
| `home` | Directory holding `hawser.exe` (on PATH; also `HAWSER_HOME`) |
| `docker-context` | `hawser` — the docker context targeting the engine |

## GitLab and other CI

The action is a thin wrapper around one PowerShell script, so every CI system
runs the same logic. In `.gitlab-ci.yml` on a Windows runner:

```yaml
before_script:
  - Invoke-WebRequest https://raw.githubusercontent.com/hawserhq/setup-hawser/v1/scripts/install-hawser.ps1 -OutFile install-hawser.ps1
  - pwsh -File install-hawser.ps1 -Version 0.3.0
  - $env:DOCKER_CONTEXT = 'hawser'
```

Pin the script by tag, exactly as you would pin the action. The script has the
same parameters as the inputs above (`-Version`, `-Lockfile`, `-Install`,
`-InstallArgs`, `-Wait`).

## What the action does, precisely

1. Resolves the release (or uses the pinned version).
2. Downloads `hawser_<version>_windows_<arch>.zip` and `SHA256SUMS` from the
   GitHub release and **refuses on any checksum mismatch**.
3. Extracts, puts `hawser.exe` on `PATH`, exports `HAWSER_HOME`.
4. With `install: true`: checks WSL2 is available, runs
   `hawser install --headless --no-autostart` (plus `--locked` when a lock is
   present and the release supports it), `hawser start`, then waits with
   `hawser healthcheck --wait` (or by polling `status --json` on releases that
   predate `healthcheck`), and exports `DOCKER_CONTEXT=hawser`.

Nothing is fetched as "latest" inside Hawser itself: the release pins its engine
rootfs by SHA-256, and the lockfile pins it to the commit.

## Runners without a docker CLI

`hawser cli install` installs the upstream docker CLI + compose + buildx on the
runner (checksum-pinned), if the runner image has none:

```yaml
- uses: hawserhq/setup-hawser@v1
- run: hawser cli install --no-path
```

## License

[Apache-2.0](LICENSE). Hawser is not affiliated with or endorsed by Docker, Inc.;
Docker is a trademark of Docker, Inc.
