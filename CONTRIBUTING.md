# Contributing

A change here runs in the next release of every repository that calls these workflows.
Work on a branch and open a pull request against `main`.

## Before you merge

1. **CI is green**: shellcheck, actionlint and `tests/wp-plugin.sh`.
2. **A real repository ran the branch.** Point one plugin repository's callers at the
   branch - both the ref after `@` and `tools-ref` - and let its PR checks run. For a
   change to the deploy, run its `wordpress-svn-release.yml` by **Run workflow** with the
   version that is already released: deploying an unchanged version commits nothing to
   SVN, so it exercises the whole chain without publishing anything new.
   `wp-emoji-guard` is the usual pilot: no build step, no composer, and its SVN still has
   the symlinks that broke a release elsewhere.
3. **A new test for a new failure.** Every case in `tests/wp-plugin.sh` is something that
   went wrong in a real release; a fix for a new one comes with its test.

Run the checks locally:

```sh
bash tests/wp-plugin.sh                                    # needs rsync, zip, python3, svn
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:stable -x wp-plugin/bin/*.sh tests/*.sh
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest
```

## Commit messages

Releases are cut by release-please from [Conventional Commits](https://www.conventionalcommits.org/).
The users of this repository are the calling repositories, so a change to how a workflow
behaves for them is a `fix:` or `feat:` even when no plugin user would notice it.

| Type | Release | When |
|---|---|---|
| `fix:` | 1.0.0 → 1.0.1 | a workflow or script did the wrong thing |
| `feat:` | 1.0.0 → 1.1.0 | a new workflow, a new optional input |
| `feat!:` / `BREAKING CHANGE:` | 1.0.0 → 2.0.0 | the callers have to change |
| `docs:`, `test:`, `ci:`, `chore:`, `refactor:` | none | everything else |

## Adding a family

Workflows go into `.github/workflows/` with a prefix for the family (`npm-…`,
`node-…`) - GitHub does not find reusable workflows in subdirectories. Scripts go into a
directory named like the prefix, the documentation into `docs/<family>.md`.
