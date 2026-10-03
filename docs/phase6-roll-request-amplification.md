# Phase 6 roll request amplification

Phase 6 keeps every RNG draw and formula in the optimized TypeScript roll Edge Function. It only moves already-decided state transitions behind narrower transactional RPC boundaries.

## Request boundaries

`roll_prepare_context_v2` extends the existing initial context with Deepcore, Deep Sea, pet definitions, and the two equipped-item bonus columns. Normal batches reuse those invocation-stable values. Deep Sea batches refresh their mutable event boundary/feed context inside `roll_begin_batch_subroll_v2`, together with the existing serialized subroll transition.

`roll_route_result` preserves the existing precedence in one request:

1. A completed Deepcore/Deep Sea deposit wins.
2. An explicit filter/Auto Keep decision keeps the specimen.
3. Bundle routing runs.
4. Auto Craft runs only when the specimen was neither deposited nor protected by a bundle.

`roll_commit_result` atomically persists the JS-generated primary and optional Vein Hunter specimens, grants relics, commits equipment state, performs critical bookkeeping, and attempts filter auto-sale. A sale error retains the inserted specimen. The last successful subroll also clears its matching lease; `release_server_roll` remains unchanged and the Edge Function still calls it from `finally` after any error or abort where the successful release was not confirmed.

## Representative PostgREST budget

The counts below cover the production-dominant ordinary path. Optional event actions, pet awards, consumable actions, and single-roll background bookkeeping add the same feature-specific calls on either side unless explicitly consolidated.

| Path | Before Phase 6 | After Phase 6 | Reduction |
|---|---:|---:|---:|
| Sold single roll | 12 | 5 | 58.3% |
| Kept single roll | 10 | 4 | 60.0% |
| Sold ×4 | 26 | 13 | 50.0% |
| Kept ×4 | 18 | 9 | 50.0% |

The after counts are one lease claim, one initial context, one commit, and the intentionally asynchronous background-bookkeeping call for a kept single roll; routing adds one call when bundle/Auto Craft precedence must be evaluated. A ×4 folds background bookkeeping into each commit, adds three serialized subroll refreshes and one commit per subroll, and adds routing only for non-kept results. Successful final release is part of the last commit; the standalone release request is reserved for failure cleanup.

The sampled `[ROLL_TIMING]` event retains per-phase latency and flags and now includes `roll_route_result_ms` and `roll_commit_result_ms`. Compare response-path p50/p95 and error rates before and after deployment. Do not include player IDs in timing logs.

## Deployment validation

Nothing in this change is deployed automatically. Apply `supabase/migrations/20261002053827_phase6_roll_request_amplification.sql`, then deploy the existing optimized `supabase/functions/roll` with its current `verify_jwt=false` configuration. The function performs authenticated user verification and rate limiting internally; do not replace it with an older implementation.

After deployment:

1. Run representative authenticated single and ×4 rolls covering KEEP, SELL, bundle, Auto Craft, full inventory, Deepcore, and Deep Sea.
2. Confirm no increase in roll HTTP errors, `invalid_roll_lease`, `invalid_genuine_roll`, incomplete batches, or cleanup failures.
3. Query API Gateway logs for the same duration and comparable roll volume before and after. Group by the RPC/table path and confirm the old direct `bundle_route_roll`, `commit_equipment_roll`, `sell_inventory_gem`, `inventory_gems` insert, `deepcore_get_roll_context`, `deep_sea_get_roll_context`, `game_pets`, and `player_equipment` hot-path requests are replaced by the Phase 6 RPCs.
4. Normalize calls by completed roll, not only by wall-clock traffic. The representative target is at least 40% fewer roll-related PostgREST calls.
5. Compare `edge_logs` record count and serialized attribute bytes per completed roll. Allow enough time for the Logs Ingest graph to move beyond the pre-deployment window.

The production motivation baseline was 73,963 `edge_logs` records in one hour. Phase 6 should reduce gateway log ingestion because every removed PostgREST request also removes its gateway event; the exact byte reduction depends on the live mix of single/×4, keep/sell, bundle, Auto Craft, events, and pet awards.
