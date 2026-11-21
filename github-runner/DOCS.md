# GitHub Actions Runner

Runs one self-hosted GitHub Actions runner for one **private** repository on
this Home Assistant host. Jobs run one at a time at low CPU and IO priority.

## Security: read this first

Jobs drive the **host's** Docker daemon, so the add-on needs protection mode
off, and **any workflow this runner executes is root on the host**. Register
it only to a private repository whose every pusher you trust. On a public
repository, a pull request from a fork would run here.

## Setup

1. Install the add-on and turn **Protection mode** off on its Info tab.
2. Create a registration token (valid for one hour):
   `gh api -X POST repos/OWNER/REPO/actions/runners/registration-token -q .token`
3. Set `repository`, `registration_token`, and optionally `runner_name` and
   `labels`, then start the add-on. The log shows `Listening for Jobs` when the
   runner is online.
4. In the workflow, use `runs-on: [self-hosted, <label>]`.

The token is used once. The registration is kept in `/data/runner`. To move
the runner to another repository, uninstall and reinstall the add-on.

## How it behaves

- **One job at a time.** One runner instance never takes two jobs.
- **Low priority.** The runner runs under `nice -n 10` and `ionice -c 3`.
  Containers that jobs start on the host get `--cpu-shares 256` and
  `--memory 2g` from a `docker` wrapper, because they do not inherit the
  runner's priority.
- **Cleanup before and after every job.** The `job-started.sh` and
  `job-completed.sh` hooks kill leftover processes and remove leftover job
  containers. The runner only runs hook scripts whose name ends in `.sh`.
- **Workspace paths.** A step such as `docker run -v "$(pwd)":/work` is
  resolved by the host's daemon. The wrapper rewrites `/data/...` to the
  host's path for `/data`, so workspace mounts work as on a hosted runner.
- **Self-update.** The runner updates itself inside `/data/runner`, so GitHub
  never rejects it as outdated.
- **Heartbeat.** While the runner is listening, the add-on publishes
  `sensor.github_runner_heartbeat` (a timestamp) to Home Assistant every 5
  minutes. Alert when it is older than about 15 minutes; an alert built on a
  missing entity also covers a Home Assistant restart.

## Options

| Option | Purpose |
| --- | --- |
| `repository` | Full URL of the private repository. |
| `registration_token` | First start only; see Setup. |
| `runner_name` | Name in the repository's runner list. |
| `labels` | Comma-separated labels for `runs-on`. |
