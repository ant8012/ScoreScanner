# ScoreScanner

Read `ONBOARDING.md` before changing anything. It explains the pipeline, the build, how to run scans and how to
release to Aria. `README.md` covers using the package.

Rules that always apply:

- **Private Cloud Compute only.** Never use the on-device Apple model, even as a fallback. Keep
  `allowOnDeviceFallback` false.
- **Test only with the designated test scores** (on Jack's iPhone in ScoreScanner's `Documents/TestScores/`, plus
  the local `--scan-sample`). Never scan or commit sheet music found elsewhere on his Mac.
- **Look at the images** (crops and detections drawn over the page) before diagnosing a vision bug.
- Build the app through the shell, **arm64 only**. Run **one scan at a time**. Use the phone when Private Cloud
  Compute throttles the simulator; ask Jack to unlock it if `devicectl` says it's locked.
- Changes reach Aria only through a pushed version tag. Don't change `ScoreReader`, `ScoreReadOptions` or
  `ScoreReading` without saying so: Aria uses them.
- Commit or push only when Jack asks.
