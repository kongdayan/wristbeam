# Project workflow

- Build, compile, test, package, sign and render native showcase images in GitHub Actions. Do not run local Swift builds or install local demo builds.
- Local work is source editing, static source/catalog checks, review of downloaded artifacts, and computer-use verification of the installed GitHub release.
- Keep one installed application at `/Applications/WristBeam.app`. Move superseded application bundles to Trash; preserve accounts, preferences and health data.
- Merge only after the PR checks pass. Publish stable tags through the Release workflow, then verify the public assets.
- Keep product copy concise: titles, values, status, actions and useful guidance. Developer implementation notes, compatibility roadmaps, signing notices and affiliation disclaimers belong in project documentation, not everyday app screens.
- Never publish personal health readings, account credentials, device identifiers or original FIT files. Showcase images use isolated synthetic data.
