## What and why

<!-- What changes, and what problem it solves. Link an issue if there is one. -->

## Shipping checklist

Publishing is **tag-driven** — merging to `main` releases nothing. A user-visible
change needs all four of these together, or `release.yml` fails the tag:

- [ ] `version:` bumped in `claude-terminal/config.yaml` (`<upstream base>-wdn.<n>`)
- [ ] matching `## <version>` section added to `claude-terminal/CHANGELOG.md`
- [ ] docs updated — `claude-terminal/DOCS.md` is what Home Assistant renders
- [ ] `translations/en.yaml` updated if any option was added or renamed
      (unmatched keys are silently ignored and reappear as raw names in the UI)

## If this touches the boot path

`run.sh` runs before `exec ttyd`, so anything slow or blocking there delays or
breaks the terminal:

- [ ] no network calls and nothing blocking added to the boot path
- [ ] intentional non-zero returns are captured (`set -e` is active)
- [ ] new scripts added to the executable list in `build-test.yml`
- [ ] new binaries added to the runnability list in `build-test.yml`

## Verification

<!-- How you know it works. Local podman run per DEVELOPMENT.md, CI output,
     or the specific check you looked at. "CI is green" is only sufficient if
     the new code path is actually exercised by a check. -->
