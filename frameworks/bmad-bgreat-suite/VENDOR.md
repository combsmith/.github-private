# Vendored: BMad B-Great Suite (module "bgr" — ops personas)

Source: https://github.com/petry-projects/bmad-bgreat-suite @ **ae8914e84b87**
Vendored: `src/` only (`agents/bgr-agent-{morgan-sre,riley-devops,sam-security}`,
`skills/bgr-ops-review`, `workflows/`, `templates/`, `module.yaml`,
`module-help.csv`) + `LICENSE`.

The BMAD ops-personas expansion module: Morgan (SRE Lead), Riley (DevOps Lead),
and Sam (Security Lead), with their `bgr-3-create-*` workflows and the
`bgr-ops-review` skill. Consumed by path; persona wiring is layered on top
separately (epic #1304, stories S1–S3).

Pinned to a **commit SHA, not a tag** — the suite publishes no tags.

## bmad-method dependency

The agents reference the `bmad-help` skill from BMAD Method. That dependency is
satisfied by the already-vendored `frameworks/bmad-method/`
(`src/core-skills/bmad-help/`) — it is **not** re-vendored here.

## Refresh
```bash
git clone https://github.com/petry-projects/bmad-bgreat-suite /tmp/bgr-src
git -C /tmp/bgr-src checkout <commit-sha>
rm -rf frameworks/bmad-bgreat-suite/src && cp -r /tmp/bgr-src/src frameworks/bmad-bgreat-suite/src
cp /tmp/bgr-src/LICENSE frameworks/bmad-bgreat-suite/LICENSE
```
Do not hand-edit — local changes are lost on refresh.
