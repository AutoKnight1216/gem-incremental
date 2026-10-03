# Bank cheques

Players can write a cheque to one existing player's username from their wallet. The full face value is held immediately. The recipient cashes it from the Bank page and receives the face value less a 7.5% tax, rounded to cents. For example, a $100 cheque pays $92.50 and burns $7.50. The sender can cancel a pending cheque for a full refund. Cashing and cancellation are mutually exclusive, enforced by a row lock and status check.

Cheques are limited to whole-dollar face values from $1 to $1 trillion and 20 pending cheques per sender. Username matching ignores case, rejects ambiguous matches, and stores the recipient's user ID so a later username change cannot redirect the money. Browser roles cannot read or write the cheque table; authenticated players use account-scoped RPCs.

## Deployment

Apply `supabase/migrations/20261003143000_bank_cheques.sql` after the existing bank and economy cash ledger migrations. It adds the cheque table, the four RPCs, and economy ledger classifications. Publish the Bank page and `cloudBank.js` after the migration. No Edge Function deployment is needed. This repository does not automatically deploy Supabase migrations from a merge.

The source and browser wiring checks are in `tests/bank-cheques-test.mjs`. The AI database-access rule in `AGENTS.md` prevents database-backed validation during this change; the migration has not been applied to a live database here.
