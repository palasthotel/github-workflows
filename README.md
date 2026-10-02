# github-workflows

Reusable GitHub Actions workflows for Palasthotel repositories.

The release workflows used to live as copies in every repository, and the copies drifted:
fifteen WordPress plugins had fifteen different deploy workflows, and fixes such as the one
for symlinks in SVN had reached only some of them. They live here once now, and the
repositories call them.

| Family | Workflows | Documentation |
|---|---|---|
| WordPress plugins | `wp-plugin-pr.yml`, `wp-plugin-release-please.yml`, `wp-plugin-sync-version.yml`, `wp-plugin-svn-deploy.yml` | [docs/wp-plugin.md](docs/wp-plugin.md) |

## Using a workflow

```yaml
jobs:
  checks:
    uses: palasthotel/github-workflows/.github/workflows/wp-plugin-pr.yml@v1
    with:
      slug: my-plugin
```

`@v1` follows the latest 1.x release. Every release is also tagged exactly (`v1.2.0`), and
those tags are immutable.

## Versioning

- `fix:` and `feat:` release a new 1.x version and move `v1` to it - every repository on
  `@v1` gets the change with its next run.
- A change that needs the callers to change - a renamed or new required input, a removed
  workflow - is a breaking change (`feat!:`) and becomes `v2`. Repositories move to `@v2`
  when they are adjusted; `v1` stays where it is.

Public repositories can only call reusable workflows from public repositories, and the
plugins are public - which is why this one is, too. Nothing in it is secret: the
credentials stay in the calling repositories and are passed with `secrets: inherit`.

## Repository layout

| Path | |
|---|---|
| `.github/workflows/wp-plugin-*.yml` | the reusable workflows - GitHub requires them directly in `.github/workflows/`, hence the prefix per family |
| `.github/workflows/ci.yml`, `release-please.yml` | this repository's own checks and releases |
| `wp-plugin/bin/` | the scripts the WordPress workflows run |
| `tests/` | tests for the scripts, run by CI |
| `docs/` | one page per family |

See [CONTRIBUTING.md](CONTRIBUTING.md) before changing anything here.

## License

MIT, see [LICENSE](LICENSE).
