# Dependabot

Every repository gets the same `.github/dependabot.yml`, generated from one template by
[`dependabot/bin/generate.sh`](../dependabot/bin/generate.sh). Dependabot can't extend
a shared config, so each repository carries the whole file - generated, so they don't
drift apart.

```sh
bash ../github-workflows/dependabot/bin/generate.sh        # in the repository
```

The PR checks of [wp-plugin-pr.yml](wp-plugin.md) warn when the file differs from what
the template gives for the repository. A warning, not a failure: when the template
changes, the plugins would otherwise fail their next pull request until each is
regenerated.

## What the template does

The patch policy of our Renovate preset (`palasthotel/devops/renovatebot`), as far as
Dependabot can follow it:

| | |
|---|---|
| Schedule | weekly, Monday 07:00 Europe/Berlin |
| Cooldown | a release is proposed 7 days after it came out - except our own packages (`@palasthotel/*`, `palasthotel/*`) |
| Security updates | right away. Dependabot applies no cooldown to them, so the 2 days of the Renovate preset can't be set here |
| Commits | `deps(deps-dev): …` - not a type release-please releases on |
| Assignee | `JanaME`, or `ASSIGNEE=…` when generating |

One entry per ecosystem the repository has, each with groups, so that a week brings one
to three pull requests instead of one per package - and merging one doesn't put the
others in conflict, because no two of them touch the same lock file:

| Ecosystem | Found in | Groups |
|---|---|---|
| npm | every directory with a `package-lock.json` | `wordpress`: `@wordpress/*` and `@types/wordpress__*`, major versions included - they are released together and depend on each other. `npm`: everything else, minor and patch. `npm-security`: the security updates. A major version outside `@wordpress` comes alone, to be built and looked at alone. |
| composer | every directory with a `composer.json` that requires a package - one that only sets up the autoloader has nothing to update | `composer`: minor and patch. `composer-security`. |
| github-actions | always, with `directory: "/"` | `github-actions`: all of them. `/.github/` would be taken for a composite action, and the workflows would never be checked. |

`node_modules/`, `vendor/` and `build/` are skipped.

## Changing the template

Change `generate.sh`, add a case to `tests/dependabot.sh`, release, and regenerate the
repositories. Dependabot reads a changed file with its next check, closes the pull
requests the new groups replace and opens the grouped ones.
