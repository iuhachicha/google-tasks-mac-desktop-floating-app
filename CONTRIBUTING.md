# Contributing

Keep changes focused on a compact, native task manager.

1. Build with `./build.sh` and run `./tests/run.sh`.
2. For UI changes, check the 240-point layout, keyboard dismissal, light/dark appearance, and empty/offline states.
3. Explain the user-visible change and the checks performed in your pull request. Add focused regression coverage for behavior changes.

Use synthetic data. Never include OAuth client JSON, tokens, authorization URLs containing codes, private task snapshots, account details, or screenshots of real lists in commits, issues, or pull requests. Check the staged diff before submitting; ignore rules are not a substitute for review.

Keep task writes behind the granted editing permission and visible-list checks. Changes to permissions, network endpoints, token storage, callback handling, or data collection need explicit documentation and careful review.

Contributions are provided under the repository’s [MIT license](LICENSE).
