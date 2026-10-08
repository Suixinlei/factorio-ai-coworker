# Action classification before the breaking rename

This table describes the current behavior in `mod/scripts/batch_actions.lua`
and `mod/scripts/atomic_actions.lua`. It is the contract to use for the
breaking CLI/RCON rename; old names are not compatibility aliases.

## Atomic actions

An atomic action targets one object, one transfer, one memory write, or one
direct movement/research operation.

| Current behavior | Final category | Public name | Notes |
|---|---|---|---|
| Relative movement by direction and distance | atomic | `move` | One teleport step, capped at 16 tiles. |
| Absolute teleport to coordinates | atomic | `goto` | Current implementation is a single target operation. |
| Mine one selected entity | atomic | `mine` | Batch gather/clear loops this operation. |
| Place one real building | atomic | `place` | Consumes one item. |
| Create one entity ghost | atomic | `create_ghost` | New atomic extracted from blueprint planning. |
| Build one existing ghost | atomic | `build_ghost` | New atomic extracted from ghost construction. |
| Remove one existing ghost | atomic | `remove_ghost` | New atomic extracted from ghost cleanup. |
| Set one assembler recipe | atomic | `set_recipe` | One target machine. |
| Hand-craft a recipe count | atomic | `craft` | One recipe queue request. |
| Pick up one ground item entity | atomic | `pickup` | Atomic handler should select one nearest stack. |
| Send one chat message | atomic | `chat` | One message. |
| Insert one item into one entity inventory | atomic | `insert` | Batch refill/deposit loops this. |
| Take one item from one entity inventory | atomic | `take` | Batch collection loops this. |
| Write one memory summary | atomic | `summary` | One memory update. |
| Queue one technology | atomic | `research` | No multi-tech loop in the current implementation. |
| Review one built entity | atomic | `review_build` | Batch review calls this and aggregates status records. |
| Aim the player at a position | atomic | `shoot` | Sets one shooting target. |
| Write or display notes | atomic | `add_note` / `view_notes` | One note write or one display operation. |
| Create, append, complete, or display todos | atomic | `create_todo` / `add_todo` / `complete_todo` / `view_todo` | Each call changes or reads one todo list operation. |
| Wait one turn | atomic | `wait` | Current handler is a no-op/log operation and needs a later timing fix if real waiting is required. |

## Batch actions

These actions iterate over entities/items/regions or execute a multi-step
workflow built from atomic operations.

| Current behavior | Final category | Public name | Notes |
|---|---|---|---|
| Mine until an inventory target is reached, deconstruct marked entities, or clear a region | batch | `batch_mine` | These are the same repeated `mine` workflow with different target selectors. |
| Insert items into nearby machines or chests | batch | `batch_insert` | Merges refill and deposit; both loop targets and call `insert`. |
| Take exact items from nearest containers | batch | `batch_take` | Loops containers and calls `take`. |
| Pick up all ground item stacks in a scope | batch | `batch_pickup` | Loops stacks and calls atomic `pickup`. |
| Create a coordinate list of ghosts | batch | `batch_create_ghost` | Loops entities and calls `create_ghost`. |
| Generate a mining outpost layout | batch | `batch_create_ghost` with `layout="mining_outpost"` | Generates many ghost plans; uses the blueprint atomic. |
| Audit a build area or remembered build list | batch | `batch_review_build` | Audits a collection of entities/ghosts. |
| Clear ghosts in a scope | batch | `batch_remove_ghost` | Loops ghosts and calls `remove_ghost`. |
| Build ghosts selected by a broad scope or exact list/last plan | batch | `batch_build_ghost` | Merge candidate accepted; this pairs with `build_ghost`. |

Every registered batch action has the corresponding atomic name without `batch_`.

## Names removed from the batch category

`return_home` is not an independent operation: it is `goto` to the stored home
position. It should be removed as a registration; callers use `goto` with the
home target. `batch_goto` and `batch_research` must not be registered.

The old `skill` JSON key, `skills.lua`, `AISkills`, `list_skills`, and
`run_skill` terminology are not part of the new interface. The implementation
names should be `action`, `batch_actions.lua`, `AIBatchActions`,
`list_batch_actions`, and `run_batch_action`.
