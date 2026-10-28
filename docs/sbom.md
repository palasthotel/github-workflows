# SBOMs and Dependency-Track

Every release gets CycloneDX SBOMs of what it ships. They are attached to the GitHub
release and sent to Dependency-Track, which reports the known vulnerabilities of every
released version.

```
v* tag ──▶ wp-plugin-sbom.yml            build → pack → sbom.sh → GitHub release + artifact "sbom"
               │
               └──▶ dependency-track-upload.yml   OIDC token → session → one project per SBOM
```

## What is in an SBOM - and what is not

Only what runs on a site that installs the release:

| SBOM | Source | Contains |
|---|---|---|
| `sbom-npm.cdx.json` | the `cyclonedx/bom.json` that [`@cyclonedx/webpack-plugin`](https://github.com/CycloneDX/cyclonedx-webpack-plugin) writes next to the bundles of every webpack build | the npm packages webpack bundled |
| `sbom-composer.cdx.json` | the `composer.lock` that `pack.sh` installed in the payload | the composer packages without `require-dev` |

Not in them:

- **`package-lock.json`**. Every npm package of a plugin is a devDependency, so it would
  list either nothing or the whole toolchain - webpack, babel, eslint.
- **`@wordpress/*` and React**. wp-scripts leaves them out of the bundle as externals;
  WordPress ships them.
- **css-loader**. wp-scripts extracts the CSS into `.css` files, so its runtime modules
  only run during the build, though the webpack plugin counts them as bundled.
- **Code copied into the repository by hand** - a library in `public/js/`, say. No tool
  sees it; move it to npm or composer.

An SBOM without components is not written: a plugin that bundles nothing has nothing to
report, and Dependency-Track gets no empty project.

## A plugin repository

### The webpack plugin

Only for a plugin with a JS build. Add `@cyclonedx/webpack-plugin` to `devDependencies`,
pinned, and to the production config. Without a `webpack.config.js`, wrap the one of
wp-scripts - it picks up a root `webpack.config.js` by itself, and entries and
`--output-path` on the command line still apply:

```js
const defaultConfig = require( '@wordpress/scripts/config/webpack.config' );
const { CycloneDxWebpackPlugin } = require( '@cyclonedx/webpack-plugin' );

/**
 * Production builds also write a CycloneDX SBOM of what webpack bundled
 * (cyclonedx/bom.json next to the bundles). The release workflows of
 * palasthotel/github-workflows send it to Dependency-Track and keep it out of the
 * payload.
 */
function withSbom( config ) {
	if ( config.mode !== 'production' ) {
		return config;
	}
	return {
		...config,
		plugins: [
			...config.plugins,
			new CycloneDxWebpackPlugin( {
				specVersion: '1.6',
				outputLocation: './cyclonedx',
				includeWellknown: false,
				reproducibleResults: true,
			} ),
		],
	};
}

module.exports = Array.isArray( defaultConfig )
	? defaultConfig.map( withSbom )
	: withSbom( defaultConfig );
```

`cyclonedx/` lies in the build output, which is ignored by git. `pack.sh` leaves every
`cyclonedx/` directory out of the payload, and the PR checks fail if one gets in anyway.

### The caller

`.github/workflows/sbom.yml` - `slug`, `build-command`, `exclude` and the other inputs
as in `wordpress-svn-release.yml`, `tag-prefix` included (and the `tags:` pattern to
match):

```yaml
name: SBOM

on:
  push:
    tags:
      - "v*"
  # The SBOM of a version released before this workflow existed - see
  # https://github.com/palasthotel/github-workflows/blob/main/docs/sbom.md
  workflow_dispatch:
    inputs:
      version:
        description: "Released version, without the leading v (e.g. 1.0.1)"
        required: true
        type: string

permissions:
  contents: read

jobs:
  sbom:
    uses: palasthotel/github-workflows/.github/workflows/wp-plugin-sbom.yml@v1
    permissions:
      contents: write
    with:
      slug: my-plugin
      version: ${{ github.event.inputs.version }}

  dependency-track:
    needs: sbom
    if: needs.sbom.outputs.sboms != ''
    uses: palasthotel/github-workflows/.github/workflows/dependency-track-upload.yml@v1
    permissions:
      contents: read
      id-token: write
    with:
      version: ${{ needs.sbom.outputs.version }}
```

`contents: write` attaches the SBOMs to the release, `id-token: write` lets the upload
job ask GitHub for its OIDC token.

**Run workflow** with a released version builds the tag of that version, so it gives a
version released before this workflow its SBOM. A tag from before the webpack plugin was
added gets a composer SBOM only.

### Inputs of wp-plugin-sbom.yml

`slug`, `version`, `root`, `plugin-dir`, `main-file`, `build-command`, `exclude`,
`node-version`, `php-version`, `tag-prefix` and `tools-ref` as in [the deploy](wp-plugin.md#inputs),
and:

| Input | Default | Meaning |
|---|---|---|
| `composer-include-dev` | `false` | keep `require-dev` in the composer SBOM, read from the plugin's own `composer.lock` - for a plugin that ships a dev dependency in another form, like firebase-notifications, which ships the Firebase SDK prefixed by Strauss |
| `attach-to-release` | `true` | attach the SBOMs to the GitHub release |
| `cyclonedx-composer-version` | `6.2.0` | of `cyclonedx/cyclonedx-php-composer` |

Outputs: `sboms` (e.g. `composer npm`, empty when nothing ships) and `version`.

## Dependency-Track

`dependency-track-upload.yml` sends each SBOM to its own project,
`<owner>/<repository> (npm)` and `(composer)` - the names the GitLab component
`palasthotel/devops/ci-components/sbom` uses for the projects there. The version is the
released one, marked as the latest. A new version is created under the parent of the
latest one: move the first version of a project under a parent such as "WordPress
plugins" once, and the following ones land there too.

Every new version is tagged `library`: the policies of Dependency-Track are assigned by
tag, and what we publish as open source is a library to the sites that install it - its
findings are judged differently from those of a site we run. `project-tags` takes another
comma-separated list. Dependency-Track only applies tags when the upload creates the
version, so a version that existed before keeps the tags it has; tag those by hand.

The job authenticates with workload identity federation: GitHub's OIDC token of the job,
with the audience `https://api.hausmeister.palasthotel.de`, is exchanged for a session of
the service account `ci-github` via the workload identity provider `github-actions`. No
secret is stored anywhere.

The instance, the provider and the service account are fixed in the workflow, and the
project name is always the calling repository: a caller that could set the URL could
send its token elsewhere and replay it, one that could set the project could overwrite
another project's SBOM. The binding trusts the token because this workflow sent it.

### The binding in Dependency-Track

The service account needs `BOM_UPLOAD`, `PROJECT_CREATION_UPLOAD` and
`VIEW_PORTFOLIO` - the last one only for the lookup of the latest version, but it reads
the whole portfolio, the customer projects included. So the binding lets in nothing but
this workflow, from releases and the default branch:

| | |
|---|---|
| Subject | `repo:palasthotel@4201000/*` - the immutable subject with the organisation's ID, so a deleted repository can't be recreated under its name and inherit its access |
| Condition | `(claims.job_workflow_ref.startsWith("palasthotel/github-workflows/.github/workflows/dependency-track-upload.yml@") \|\| claims.job_workflow_ref.startsWith("palasthotel@4201000/github-workflows@1401352495/.github/workflows/dependency-track-upload.yml@")) && (claims.ref == "refs/heads/main" \|\| claims.ref.startsWith("refs/tags/v") \|\| claims.ref.startsWith("refs/tags/plugin-v"))` - `job_workflow_ref` in both forms GitHub may send it, the tags with both prefixes in use |

A repository that still sends the old subject (`repo:palasthotel/<name>`) has to switch
to the immutable one before its upload works (REST API
`repos/<owner>/<repo>/actions/oidc/customization/sub`, `use_immutable_subject`).

When Dependency-Track refuses the token, the job log shows its claims - `sub`, `ref`,
`job_workflow_ref` and the like, never the token itself - next to the binding.
