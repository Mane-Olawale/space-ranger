# ADR-009 — Trash tier by default, permanent deletion opt-in

**Status:** Accepted (PLAN.md §2.14, §4.4, §4.6) · **Date:** 2026-11-02

Every plan executes in one of three tiers — `dryRun`, `trash` (default) and `permanent` — and the default moves items to the Trash through `NSWorkspace.recycle` in batches of 500, recording the resulting paths in the ledger so `LedgerStore.restore` can put them back. Permanent deletion (`unlinkat` recursion in-process or the root helper) requires an explicit per-plan confirmation, per-item confirmation for medium/high risk, and an open-file pre-flight. Undo matters more than freeing space a few seconds earlier, and the audit's partial `rm -rf` failures (EC-04/EC-26) showed how little feedback irreversible deletion gives. **Alternatives rejected:** permanent by default (fast, irreversible, the `quickclean.sh` defect B7) and a proprietary quarantine folder (duplicates what the Trash already offers, invisible to Finder's own undo and "Empty Trash").
