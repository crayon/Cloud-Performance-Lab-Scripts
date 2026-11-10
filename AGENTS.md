# Cloud Performance Lab Scripts (agent notes)

This repo is **public on GitHub**, and so are these notes: keep them customer-neutral. What the scripts do is in `README.md` and each cloud folder's `README.md`.

## Rules
- **Public repo.** Never commit customer output (`*.xlsx`, `*.csv`), customer names, account/subscription/project IDs, tenant IDs or internal hostnames. Keep commit messages and comments customer-neutral.
- **Read-only by design.** The collectors call only read/list/metrics APIs and write only to the working directory. Never add a write, tag or agent-install call; customers run these under read-only roles and the READMEs promise exactly that.
- **Output columns are a contract** with Cloud Performance Lab's inventory import (`cloud-performance-lab`, alias `cpl`). Renaming, removing or reordering a column, or changing a sentinel value, needs the matching change in CPL in the same piece of work, and the folder README's column table updated.
- **Keep the three clouds parallel.** AWS, Azure and GCP follow the same inventory/CPU/memory/network/disk pattern; a change in one usually belongs in all three, or say why not.
- Minimal dependencies: customers install from `requirements.txt` (Python) or Az modules (PowerShell 7). Don't add a package without a strong reason.

## Before finishing
- Python: `python3 -m py_compile AWS/*.py GCP/*.py` and `uvx ruff@0.15.22 check AWS GCP` with no new findings (main had 6 on 2026-11-02; don't fix unrelated ones in a feature change).
- PowerShell: `pwsh -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('Azure/metrics_availability_assessment.ps1',[ref]$null,[ref]$e); $e.Count"` prints `0`.
- No live cloud runs against customer accounts; test only against your own dev subscription/account, and only when asked.

<!-- way-of-working:start -->
This repo uses the Way of Working (the `way-of-working` Claude Code plugin). Run session start from the `wow-tracker` skill before anything else: it reconciles PR state against the Notion Tasks board and checks that `docs/agents/wow.md` matches the installed plugin version. Every ticket (issues, wayfinder maps and deliverables) lives in the Notion Tasks board, never in GitHub/ADO issues or local files. Specs and other repo-hosted deliverables are files in this repo, and their Notion ticket links to the file. See `docs/agents/` for this repo's issue-tracker pointer and identifiers.
<!-- way-of-working:end -->
