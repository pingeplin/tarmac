# Contributing to Tarmac

Thanks for your interest in contributing! This document explains how to get
your changes accepted and, importantly, the terms under which contributions are
made.

## License and contribution terms

Tarmac is licensed under the [Apache License 2.0](LICENSE). By submitting a
contribution (a pull request, patch, or any code/documentation), you agree that
your contribution is licensed under the same Apache 2.0 terms, as described in
Section 5 of the license.

### Developer Certificate of Origin (DCO)

To keep the project's provenance clean and to preserve the maintainer's ability
to relicense or offer the software under commercial terms in the future, every
commit must be signed off under the [Developer Certificate of Origin](https://developercertificate.org/)
(reproduced below). Signing off certifies that you wrote the change or otherwise
have the right to submit it under the project's license.

Add a sign-off line to each commit message:

```
Signed-off-by: Your Name <your.email@example.com>
```

The easiest way is to let git add it automatically:

```sh
git commit -s -m "your message"
```

The name and email must match your real identity (matching your git
`user.name` and `user.email`).

<details>
<summary>Developer Certificate of Origin 1.1 (full text)</summary>

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

</details>

## Development setup

Build the project with:

```sh
make
```

Please make sure `make` succeeds before opening a pull request. Note that the
editor/IDE may show stale SourceKit diagnostics — `make` is the source of truth.

## Submitting changes

1. Fork the repository and create a topic branch from `main`.
2. Make your change, keeping it focused and matching the surrounding code style.
3. Ensure the build passes (`make`) and add tests where the architecture allows
   (pure logic lives in `core/` and is unit-tested there).
4. Commit with a clear message and a DCO sign-off (`git commit -s`).
5. Open a pull request describing the change and the motivation.

## Questions

If you're unsure whether a change fits the project's direction, open an issue to
discuss it before investing significant effort. Thanks for contributing!
