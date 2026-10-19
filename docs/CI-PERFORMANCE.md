# CI performance

Each CI run publishes a **CI timing** job summary and a `ci-timings` JSON/Markdown artifact. It reports initial scheduling/provisioning wait, completed job and step wall times, the slowest steps, and comparison with up to five successful runs of the same workflow/event. It uses the current run attempt, paginates job results and excludes unfinished/skipped durations. Runner and toolchain changes can affect comparisons; a small sample is not a performance guarantee. Parallel job durations are not total user wait time or CPU usage.

Rebuild a report from GitHub metadata without compiling locally:

```sh
python3 scripts/ci-metrics.py report --repo kongdayan/wristbeam --run-id RUN_ID --output /tmp/ci-timings.json
```

The native interface harness separately records compilation and rendering time. `interface-compile-timing.json` and `interface-render-timing.json` accompany ARM interface screenshots. The command wrapper emits a heartbeat every 30 seconds, preserves command failures and records elapsed time, child user/system CPU time and largest-child RSS high-water mark. The memory value is not total process-tree RSS. Run each measurement in its own wrapper process so resource accounting is isolated. Reports do not contain command arguments, credentials, logs or health data.

## Baseline observed on 2026-10-19

| Run | Swift CodeQL compilation/extraction | Query analysis | Swift CodeQL job |
| --- | ---: | ---: | ---: |
| [PR CI 38881952773](https://github.com/kongdayan/wristbeam/actions/runs/38881952773) | 573 s | 163 s | 803 s |
| [main CI 38884689072](https://github.com/kongdayan/wristbeam/actions/runs/38884689072) | 768 s | 161 s | 1,011 s |
| [Full CI 38879864731](https://github.com/kongdayan/wristbeam/actions/runs/38879864731) | 1,138 s | 200 s | 1,429 s |

These historical runs have different commits and hosted machines. They identify a recurring bottleneck, not a controlled speedup comparison. In PR #12's initial completed native jobs, Intel took 463 seconds and ARM took 631 seconds. The 195 XCTest methods themselves took approximately 9 and 7 seconds; the rest includes compiler, rendering, integration and package work. The ARM interface step took 297 seconds before compilation/rendering were separately instrumented.

Swift CodeQL must observe a real compilation. A cached binary cannot replace extraction. GitHub supports manual `swift build` and recommends one architecture: [Swift build guidance](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages). Release builds use whole-module optimization; Debug avoids release optimization: [SwiftPM build configurations](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/UsingBuildConfigurations.md).

A separate same-source, Intel-hosted Debug/no-index experiment is being evaluated against the Release extraction baseline. Security query suites, actual Release packages, and ARM/Intel functional checks remain unchanged. Do not report a speedup until both timing and extraction coverage are verified.
