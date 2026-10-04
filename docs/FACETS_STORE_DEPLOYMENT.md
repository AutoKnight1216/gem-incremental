# Facets Store deployment

The website and backend are integration-ready, but nothing in this change deploys to Supabase or creates Buy Me a Coffee products.

## 1. Apply the database migration

Apply `supabase/migrations/20261004030718_facets_store_v1.sql` to project `igrddscmrdrrwtvyspbf`. Run the Supabase database advisors afterwards and resolve any new security or performance findings before opening checkout.

## 2. Create fixed Buy Me a Coffee Shop products

Create exactly these five products in SGD. Do not create a custom-amount product.

| Product | Price |
|---|---:|
| 100 Facets | S$1.00 |
| 250 Facets | S$2.50 |
| 500 Facets | S$5.00 |
| 1,000 Facets | S$10.00 |
| 2,500 Facets | S$25.00 |

Add one required question to every product: `Enter your Gem Incremental Facet claim code`. Keep the products unpublished until the webhook test passes.

Copy each real BMC Shop item ID and checkout URL into `public.facet_pack_definitions`. Never guess these values. Example (replace every placeholder):

```sql
update public.facet_pack_definitions set provider_product_id='<BMC_ITEM_ID>', checkout_url='<BMC_CHECKOUT_URL>' where id='facets-100';
```

Repeat for all five rows.

## 3. Deploy and configure the webhook

Deploy `bmc-facets-webhook` from this repository. Its `verify_jwt = false` setting is intentional because Buy Me a Coffee cannot send a Supabase user JWT; the function instead verifies the raw request body with BMC's HMAC-SHA256 signature.

In Buy Me a Coffee, open **Integrations → New webhook**, use:

`https://igrddscmrdrrwtvyspbf.supabase.co/functions/v1/bmc-facets-webhook`

Subscribe to `extra_purchase.created` and `extra_purchase.refunded`. Store the webhook's real signing secret as the Supabase Edge Function secret `BMC_WEBHOOK_SECRET`. Never place it in browser code or this repository.

Send BMC test events first. Test events are signature-checked and recorded as ignored; they never mint Facets. Then make one small live purchase with a generated claim code, confirm one ledger credit, resend the same payload to confirm it is idempotent, and refund it to confirm the matching debit/audit event.

## 4. Open checkout

Only publish the five BMC products after the product IDs, checkout URLs, webhook signing secret, live credit test and refund test all pass. The Store buttons remain disabled while checkout URLs are missing.

Facets are cosmetic-only, account-bound, non-tradable, non-marketable, non-giftable and cannot convert to cash or gameplay currencies. Supporter recognition remains outside this system.
