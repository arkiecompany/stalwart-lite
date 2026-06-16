# stalwart

Fork of [stalwartlabs/stalwart](https://github.com/stalwartlabs/stalwart): same mail server, **bundled webadmin disabled** (no download, no update route, no static asset serving from the webadmin bundle).

- Default branch: `main` (upstream `main` plus small lite-only commits on top; see `git log`)
- Rebase onto upstream periodically and resolve conflicts as needed.
- GitHub releases and crates.io are both publishing paths. See [PUBLISHING.md](./PUBLISHING.md).

See commit history on `main` for the exact diff.

A minimal public library API is exposed in `crates/main/src/lib.rs` (`start_server()`).
