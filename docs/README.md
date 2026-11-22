# Documentation

This index separates task-oriented tutorials from implementation references and operational runbooks. Historical reviews and research are preserved in [archive](archive/README.md); they may describe earlier states and are not current instructions.

## Tutorials

- Import an AUR or reviewed local PKGBUILD, validate it, and inspect its declaration. [Add and inspect a package](tutorials/add-package.md)
- Use the fzf menu to manage packages and builds. [Package management interface](tutorials/package-management.md)

## Reference

- [Per-package `update.toml`](reference/update-toml.md): every track, strategy, field, default, validator rule, and updater effect.
- [Package manager CLI](reference/manage-cli.md): `manage.sh add` / `packages` commands and all options.
- [Build strategies](reference/build-strategy.md)
- [Dependency management](reference/dependency-management.md): nvchecker, dependency inputs, and rebuild triggers.
- [ABI rebuild policy](reference/abi-rebuild-policy.md)
- [pkgrel policy](reference/pkgrel-policy.md)
- [CI quality gates](reference/ci-quality-gates.md)
- [FFmpeg feature matrix](reference/ffmpeg-feature-matrix.md)
- [Performance profile](reference/performance-profile.md)

## Operations

- [Build platform](operations/build-platform.md)
- [Build pipeline](operations/build-pipeline.md)
- [Troubleshooting](operations/troubleshooting.md)

## Archive

- [Archived material index](archive/README.md)
