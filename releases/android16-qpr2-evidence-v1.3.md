# BinderLab Android 16 QPR2 evidence v1.3

`android16-qpr2-evidence-v1.3` is a documentation and verification hardening release.

Evidence capture: reused from v1.2; no new device capture.

- The original logs, `evidence/analysis.json`, capture metadata, evidence manifest, and evidence source commit are unchanged from v1.2.
- The README now states exactly which modes have per-marker `elapsedRealtimeNanos()` values and uses tag-fixed evidence links.
- GitHub Actions dependencies are pinned to full commit SHAs and maintained through Dependabot.
- The release workflow completes rebuild, replay, provenance generation, and release-asset staging before it creates the annotated tag.
- Verification assets are published both as a temporary Actions artifact and as persistent GitHub Release downloads.

This release does not claim a new device run, new timing sample, or broader platform guarantee.
