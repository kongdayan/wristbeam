# CI performance

Each CI run publishes a **CI timing** job summary and a small `ci-timings` JSON/Markdown artifact retained for seven days. It reports initial scheduling/provisioning wait, completed job and step wall times, the slowest steps, and comparison with up to five successful runs of the same workflow/event. It uses the current run attempt, paginates job results and excludes unfinished/skipped durations. Runner and toolchain changes can affect comparisons; a small sample is not a performance guarantee. Parallel job durations are not total user wait time or CPU usage.

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
| [PR #12 baseline 39188476710](https://github.com/kongdayan/wristbeam/actions/runs/39188476710) | 896 s | 154 s | 1,121 s |

These historical runs have different commits and hosted machines. They identify a recurring bottleneck, not a controlled speedup comparison. In PR #12's initial completed native jobs, Intel took 463 seconds and ARM took 631 seconds. The 195 XCTest methods themselves took approximately 9 and 7 seconds; the rest includes compiler, rendering, integration and package work. The ARM interface step took 297 seconds before compilation/rendering were separately instrumented. A later instrumented run at the same application source revision measured compilation at 54.336 seconds and rendering at 179.358 seconds; largest-child memory was approximately 376 MiB and 975 MiB respectively. This separates the workload rather than demonstrating a rendering speedup.

Swift CodeQL must observe a real compilation. A cached binary cannot replace extraction. GitHub supports manual `swift build` and recommends one architecture: [Swift build guidance](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages). Release builds use whole-module optimization; Debug avoids release optimization: [SwiftPM build configurations](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/UsingBuildConfigurations.md).

## Experiments

The [Intel Debug/no-index probe](https://github.com/kongdayan/wristbeam/actions/runs/39189609429) uses the same application source tree as the PR #12 baseline. Its compilation/extraction step took 645 seconds, analysis 197 seconds, and the entire job 933 seconds: approximately 28% and 17% less compilation and job wall time in this sample. The measured build command used 638.29 seconds wall time, 801.76 seconds user CPU, 248.69 seconds system CPU, and about 1.20 GiB maximum-child RSS. Step wall time also includes runner command setup.

The same 28 Swift security rules completed with no reported analysis errors or warnings. The extracted database and source archive sizes were nearly identical; these sizes are supporting evidence, not proof of exact file/line coverage. Source review found one `#if DEBUG` block adding updater fixture handling, with no Release-only alternative. The benchmark uses a manual dispatch while the baseline is a PR run; hosted machine variability and event-specific analysis make this a directional comparison, not a guaranteed percentage improvement.

CI now uses Debug/no-index for Swift extraction on the existing Intel runner. This avoids Release whole-module optimization and IDE indexing for a job whose output is a source-analysis database. Actual Release packaging, ARM/Intel functional checks, and the security-extended query suite remain unchanged. Review new compilation-condition branches when changing this configuration. An Apple Silicon Release probe is retained as a separate experiment; it has not been adopted.

### API availability

Timing reports retry transient GitHub API errors and timeouts up to three attempts,
with a 20-second timeout per request. Current-run metadata and jobs are required.
Historical comparison is optional: an unavailable or deleted historical run is
omitted after retries, and the JSON/Markdown report explicitly records the gap.
Only successfully retrieved runs contribute to sample counts and medians.
Authentication, schema and other unexpected errors still fail the report.

## Work selection and storage budget

Routine PRs and main pushes use one macOS 15 Apple Silicon build. It still runs
protocol regression, developer HTTP/TLS/MCP/webhook integration, native XCTest,
signed packaging, installed-language/update lifecycle and real-package rejection
checks. A successful routine PR does not upload its package or screenshots.

| Change or explicit request | Native builds | UI rendering | Swift CodeQL | Uploaded packages |
| --- | --- | --- | --- | --- |
| Documentation, CI reports, pure Python pipeline tests | None | None | None | None |
| Swift protocol/cloud changes | One ARM | None | Yes | Main only |
| UI, themes, localization or display-model changes | One ARM | One ARM | For Swift changes | Main only |
| Version preparation on main; release fallback; manual full validation | macOS 14/15/26 ARM + macOS 15 Intel | All ARM targets; compile on Intel | Yes | Main/release or explicit request |
| Manual showcase | One ARM unless full is selected | Yes | Per security workflow | Only if explicitly selected |

Quality, secret scanning, Python/Actions CodeQL and the required `CI passed` gate
remain active. The scope planner uses changed repository paths, with conservative
native validation for unknown files. Expected skips are checked by the gate;
a failed selected job cannot be treated as a skip. Swift CodeQL also runs weekly
and through its standalone manual workflow. Builds and tests remain in Actions.

Use the CI workflow's **Run workflow** options for full validation, downloadable
test packages or README showcase images. Full validation alone does not require
keeping every package. A showcase explicitly uploads the full interface and
framed README image sets; routine UI tests render in temporary runner storage.

| Artifact | Retention |
| --- | --- |
| Main-branch native packages | 7 days |
| Explicit test/release-check packages | 3 days |
| Requested screenshots/showcase and failed-interaction screenshot | 3 days |
| CI and Swift compile timing metadata | 7 days |

The daily Linux-only **Actions artifact maintenance** workflow removes old known
artifact types (cancelled runs expire after one day) and never changes Releases, logs, caches or unknown user artifacts.
It pins primary packages from the latest successful full main CI and the latest
successful package-bearing CI for each open PR. Active or unavailable run metadata
is retained. Manual maintenance defaults to a dry run; `--apply` is required for
CLI deletion. A manifest records selected/deleted IDs and estimated bytes.

```sh
python3 scripts/prune-actions-artifacts.py --repo OWNER/REPO --output /tmp/cleanup.json
```

### Inventory before optimization — 2026-10-24

The repository held 398 unexpired Actions artifacts totaling 1,777.3 MiB. Showcase
and native-interface images accounted for 1,275.0 MiB (about 72%). There were no
Actions caches. This is current artifact occupancy, not a bill or a claim about
free-minute balances. Standard hosted runner execution in public repositories is
free under [GitHub's billing rules](https://docs.github.com/en/actions/concepts/billing-and-usage).

The previous PR matrix duplicated native builds on macOS 14 ARM, macOS 15 ARM
and Intel, plus a separate Swift CodeQL compilation. Main added a fourth native
build. New path selection and on-demand images reduce recurring work and storage;
measured timings remain available in each run, rather than promising a fixed
speedup across different hosted machines. Release reuse still requires both native
packages from a successful same-commit main CI and verifies source/run/hash identity.
