# WordPress plugins: release and deploy to WordPress.org

Four reusable workflows take a Palasthotel WordPress plugin from a conventional commit
to a release on wordpress.org:

```
Push to main
    │
    ├──▶ wp-plugin-release-please.yml   opens / updates the release PR (version file + CHANGELOG.md)
    │
    │    release PR opened / updated
    ├──▶ wp-plugin-sync-version.yml     writes the version into the plugin header and readme.txt
    │
    │    any PR to main
    └──▶ wp-plugin-pr.yml               php -l, pack + payload assertions, version carriers agree

Merge the release PR  →  release-please tags vX.Y.Z and creates the GitHub release
    │
    └── v* tag ──▶ wp-plugin-svn-deploy.yml   version check → build → pack → zip to the release
                                             → trunk + tags/X.Y.Z in the wordpress.org SVN
```

The scripts behind them are in [`wp-plugin/bin/`](../wp-plugin/bin) and are tested by
[`tests/wp-plugin.sh`](../tests/wp-plugin.sh) on every change to this repository.

## What a plugin repository needs

```
.github/workflows/pr.yml                    ┐
.github/workflows/release-please.yml        │ the four callers below
.github/workflows/update-plugin-version.yml │
.github/workflows/wordpress-svn-release.yml ┘
release-please-config.json
.release-please-manifest.json
package.json or version.txt                  the version release-please maintains
CHANGELOG.md
public/                                      what ships to wordpress.org
```

`bin/pack.sh`, `bin/update-plugin-version.sh` and `bin/version-checker.sh` are no longer
needed in the plugin repository.

`package.json` stays even when it lists no dependencies: with `"release-type": "node"`
release-please bumps the version there, and the scripts read it. Removing it once cut
wp-process-log 1.4.0 with 1.3.4 in every version carrier. With `version.txt` use
`"release-type": "simple"` instead.

### Repository configuration

Usually set once for the organization:

| Kind | Name | Used by |
|---|---|---|
| Variable | `RELEASE_BOT_APP_ID` | release PR, version sync |
| Secret | `RELEASE_BOT_PRIVATE_KEY` | release PR, version sync |
| Secret | `SVN_USERNAME` | deploy - a wordpress.org account with commit rights, usually `palasthotel` |
| Secret | `SVN_PASSWORD` | deploy |

There is no `SVN_REPO_URL` any more: the SVN URL is `https://plugins.svn.wordpress.org/<slug>/`.

## The callers

Replace `my-plugin` with the wordpress.org slug. Everything else has a default that fits
the usual layout; see [Inputs](#inputs) for the rest.

`.github/workflows/pr.yml`

```yaml
name: PR

on:
  pull_request:
    branches:
      - main

permissions:
  contents: read

jobs:
  checks:
    uses: palasthotel/github-workflows/.github/workflows/wp-plugin-pr.yml@v1
    with:
      slug: my-plugin
      dev-plugin-name: My Plugin - DEV
```

`.github/workflows/release-please.yml`

```yaml
name: Release Please

on:
  push:
    branches:
      - main

permissions:
  contents: read

jobs:
  release-please:
    uses: palasthotel/github-workflows/.github/workflows/wp-plugin-release-please.yml@v1
    with:
      app-id: ${{ vars.RELEASE_BOT_APP_ID }}
    secrets: inherit
```

`.github/workflows/update-plugin-version.yml`

```yaml
name: Update plugin version

on:
  pull_request:
    types: [opened, synchronize]
    branches:
      - main

permissions:
  contents: read

jobs:
  sync-version:
    uses: palasthotel/github-workflows/.github/workflows/wp-plugin-sync-version.yml@v1
    with:
      app-id: ${{ vars.RELEASE_BOT_APP_ID }}
    secrets: inherit
```

`.github/workflows/wordpress-svn-release.yml`

```yaml
name: Build and release to WordPress.org

on:
  push:
    tags:
      - "v*"
  # Re-run a failed deploy from a branch that has the fix - see below
  workflow_dispatch:
    inputs:
      version:
        description: "Version to deploy, without the leading v (e.g. 1.0.1)"
        required: true
        type: string

permissions:
  contents: write

jobs:
  deploy:
    uses: palasthotel/github-workflows/.github/workflows/wp-plugin-svn-deploy.yml@v1
    with:
      slug: my-plugin
      version: ${{ github.event.inputs.version }}
    secrets: inherit
```

## Inputs

All workflows take the path inputs; they default to the usual layout and are detected
where they are left empty.

| Input | Default | Meaning |
|---|---|---|
| `slug` | - | the wordpress.org slug: SVN URL, `build/<slug>/` and `<slug>.zip` (pr, deploy) |
| `root` | `.` | the plugin project inside the repository - e.g. `wp-plugin` in a monorepo |
| `plugin-dir` | `public` | what ships, relative to `root` |
| `main-file` | detected | the file in `plugin-dir` with `Plugin Name:`; set it when there is more than one |
| `version-file` | detected | `version.txt` if it exists, else `package.json` |
| `build-command` | none | runs in `root` before packing, e.g. `npm ci && npm run build` (pr, deploy) |
| `exclude` | none | newline-separated rsync patterns kept out of the payload (pr, deploy) |
| `required-files` | none | newline-separated paths that must be in the payload - list what `wp_enqueue_script` loads, so a renamed build output fails the PR instead of 404ing in wp-admin (pr) |
| `dev-plugin-name` | none | the development wrapper's `Plugin Name`, which must never ship (pr) |
| `php-versions` | `["7.4", "8.2", "8.3", "8.4"]` | `php -l` matrix, starting with the plugin's `Requires PHP` (pr) |
| `node-version` | `24.x` | for the build command |
| `php-version` | `8.1` | for composer, used when the payload has a `composer.json` |
| `app-id` | - | `${{ vars.RELEASE_BOT_APP_ID }}` (release-please, sync) |
| `tools-ref` | `v1` | the ref of this repository whose scripts run - keep it equal to the ref after `@` |

The payload check always requires the main file, the readme and `LICENSE`, and rejects
symlinks, `.github`, `bin`, `node_modules`, `package.json`, `package-lock.json`,
`composer.json`, `composer.lock`, `CONTRIBUTING.md` and `CHANGELOG.md`.

## Packing locally

The repositories sit next to each other, so the script runs from a checkout of this one:

```sh
SLUG=my-plugin bash ../github-workflows/wp-plugin/bin/pack.sh
```

Run the build step first if the plugin has one. The result is `build/my-plugin/` and
`my-plugin.zip`, the same payload the deploy publishes.

## How the deploy works, and why

- **`rsync -rL`, never `cp -r`.** GNU `cp` keeps symlinks while descending and BSD `cp`
  resolves them, so a macOS rehearsal passes while the Ubuntu runner fails.
  wordpress.org discards symlinks when it builds the download; `-L` turns them into files.
- **`svn propdel svn:special`.** A file that was a symlink in SVN keeps the property, and
  committing a regular file in its place fails with `E145001 ... has unexpectedly changed
  kind`.
- **Synced from `build/<slug>/`, not from the sources,** so the release zip and the SVN
  trunk are identical and the payload is the cleaned one.
- **`assets/` is mirrored only when the repository has it.** It holds the plugin page's
  banner, icon and screenshots next to `trunk/` in SVN and never ships with the download.
  Mirroring an absent directory with `--delete` would empty the plugin page's media.
- **composer** runs only when the payload has a `composer.json`: `install --no-dev`, an
  optimized autoloader, then `composer.json` and `composer.lock` are dropped.

## When a deploy fails

Do not re-push the tag. A tag event runs the caller workflow **as it was at that tag**,
and a tag ruleset usually refuses to move a tag (`GH013`). Fix the cause on a branch, then
use **Run workflow** on the plugin's `wordpress-svn-release.yml` from that branch and give
it the version to deploy. `check-version.sh` stops the run before anything is published
if the branch's version carriers disagree with that version.

A fix in this repository reaches the next run of every plugin as soon as `v1` has moved.
