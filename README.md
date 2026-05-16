# iCAN → Rahkaran ECM migration

This repository holds work-in-progress artefacts to migrate organizational and correspondence-related data from **iCAN** (enterprise communication management) into the **ECM** (Electronic Correspondence Management) module of **Rahkaran ERP**.

The approach is phased:

1. **SQL migration scripts** — T‑SQL batches that map entities, maintain ID mapping tables, and load or reconcile data in Rahkaran’s databases (schemas such as `RahkaranSG.ECM`, `RahkaranSG.GNR3`, and legacy `ican` references where applicable).
2. **Executable tooling (planned)** — A small executable will orchestrate running these steps in order, with configuration, logging, and safer execution boundaries than running ad hoc scripts manually.

Nothing in this repo is a turnkey product yet: scripts assume a specific SQL Server topology, naming, and linkage between iCAN and Rahkaran databases. Review and adapt server names, database names, and join keys before running against real systems.

## Repository layout

| Path | Purpose |
|------|---------|
| `queries/` | Migration-oriented SQL scripts (users, departments, roles, correspondence, mapping updates, etc.). |
| `dataBaseSchemaInfo/` | Exported column and constraint listings for ECM-related objects (letters, correspondents, recipients), used as a reference while writing and validating scripts. |

### Scripts in `queries/`

Rough roles of the files present today (exact order may depend on dependencies between mapping tables):

- `userToParty.sql` — Align iCAN users with Rahkaran `Party` entities and persistence of `Migration_*_Map`-style mapping tables.
- `departmentToParty(company).sql` / `departmentToPartysql.sql` — Department / company mapping variants.
- `organizationRoleToParty.sql` — Organization roles to party linkage.
- `RoleToPost.sql` — Role to post mapping for ECM correspondence metadata.
- `adMissingCorespondants.sql` — Create or reconcile missing ECM correspondents.
- `updateIdMappings.sql` — Extend mapping tables with correspondent IDs and related updates against `RahkaranSG.ECM.Correspondent`.
- `Entity_Public_LetterExtractReciepientssql.sql` — Letter / recipient extraction or transformation logic.

Treat filenames as provisional; refactor or rename once the final execution order is fixed.

### Reference under `dataBaseSchemaInfo/`

Flat text snapshots (e.g. `letterColumns.txt`, `correspondentColumns.txt`, constraint lists) documenting ECM tables used while authoring queries. Regenerate these if Rahkaran’s ECM schema differs in your environment.

## Prerequisites (for running scripts)

- **Microsoft SQL Server** with access to both source (iCAN) and target (Rahkaran / ECM) databases, or equivalents reachable via consistent three-part names as in your scripts.
- **Backups** and a **non-production** database for first runs.
- Permissions to **create or alter mapping tables**, run transactional batches, and **insert/update** ECM and GNR data as required by each script.

Always run scripts in **test** environments first and verify row counts and business rules against samples before production.

## Roadmap

- [ ] Finalize SQL: ordering, idempotency, error handling, and documentation per script.
- [ ] Freeze **execution order** and **mapping table** conventions.
- [ ] Implement the **migration executable**: configuration (connection strings, paths), scripted step runner, structured logging, and dry-run option.
- [ ] Optional: packaging instructions (e.g. single-file CLI, installer, or container — TBD).

## Contributing / maintenance

Keep script headers and phases (e.g. “STEP”, “PHASE”) clear so the future executable can map steps to discrete operations. Prefer explicit transactions and repeatable mapping keys so reruns remain diagnosable.

## License

Unspecified — add a `LICENSE` file when this project’s distribution terms are decided.
