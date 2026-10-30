# Project workflow

- During UI repair, build, test, sign and render locally. Cloud CI is temporarily unnecessary unless the user requests it or work is ready for external delivery.
- Before submitting a PR, update the local application with the verified local build and validate the actual application and relevant device flows with the user. Create the PR after local validation passes; keep any existing PR as a draft until then.
- Local work includes source editing, static source/catalog checks, review of downloaded artifacts, and computer-use verification of the installed application.
- Keep one installed application at `/Applications/WristBeam.app`. Move superseded application bundles to Trash; preserve accounts, preferences and health data.
- Merge only after the PR checks pass. Routine development, tests and commits do not authorize a public release. Local updates using verified local builds are authorized for validation before a PR. Bump release versions, create or push release tags, run the Release workflow, or publish releases only when the user explicitly requests that delivery. When requested, publish stable tags through the Release workflow and verify the public assets.
- Keep product copy concise: titles, values, status, actions and useful guidance. Developer implementation notes, compatibility roadmaps, signing notices and affiliation disclaimers belong in project documentation, not everyday app screens.
- Never publish personal health readings, account credentials, device identifiers or original FIT files. Showcase images use isolated synthetic data.
