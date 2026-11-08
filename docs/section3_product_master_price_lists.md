# Blueprint Section 3: Product Master & Price Lists

Traces each requirement of `Instalux_ERP_Developer_Blueprint_11p.pdf`, section 3
and the parts of pages 1, 10 and 11 that bind it, to its code and test. Test
names are in `test/core/` unless a folder is given.

Status: **Done**, or **Open** where the blueprint leaves a decision to the owner
or accountant, or belongs to a later section.

## Governing rule (page 1)

| Requirement | Where | Test | Status |
|---|---|---|---|
| No price, discount or balance is invented; a missing value stays unapproved until reviewed | Review rows hold a null price (`price_list_import_service.dart`); no policy means no cost (`BuyQuote.netCost`); unverified VAT gives no number (`vatOf`); migrated data waits as `pending_review` | `price_list_import_test`: "a missing or unreadable price stops the row"; `pricing_policy_test`: "with no recorded policy no percentage is assumed"; `schema11_upgrade_test` | Done |
| A price list is a dated version, not a price written over the old one | `PriceListService.createVersion` | `price_list_test`: "old versions are never overwritten" | Done |
| Profit is net sale minus actual allocated purchase cost | `SalesService.post` keeps the FIFO cost on each line and the net after allocation | `pricing_policy_test`: "the blueprint example" | Done |

## 3.1 Product master

| Requirement | Where | Test | Status |
|---|---|---|---|
| Fixed internal Product ID that never changes | `Products.code`; `ProductService.update` refuses a change, and the form shows it read-only | `product_test`: "blank code: a Product ID is given; it never changes" | Done |
| Original Manufacturer Code | `Products.manufacturerCode` | `product_test`: "maker codes stay text" | Done |
| Match Key for search and stopping duplicates | `Products.matchKey`, `matchKeyOf` | `product_test`: "the match key ignores…", "the same maker code under the same brand and variant is a duplicate" | Done |
| Code stored as text: leading zeros, letters and hyphens kept | Text column. A code Excel holds as a number stops for review, since its zeros may be gone | `product_test`; `price_list_import_test`: "a code Excel holds as a number" | Done |
| Brand, Category, Subcategory, Series, Name, Description, Dimensions, Color/Variant, Finish, Unit | `Products` columns, `product_form_dialog.dart` | `product_test`: "every master field is kept"; `features/section3_screens_test` | Done |
| Barcode, Technical Specs, VAT Basis/Rate when verified | Same; VAT fields default to not verified | Same | Done |
| No stock balance or changing purchase cost in the master | `cost_price` and price columns removed in schema 11 | `schema11_upgrade_test`: "price columns are gone" | Done |
| Prices in Price List History | `PriceListService.history`, `price_history_dialog.dart` | `price_list_test` | Done |
| Quantities and cost in stock and FIFO layers | `StockMovements`, `CostLayers`; weighted average removed | `fifo_test`, `money_in_out_test` | Done |

## 3.2 Two ways to enter prices

| Requirement | Where | Test | Status |
|---|---|---|---|
| Full import creates a new Price List ID and version | `PriceListImportService.import` | `price_list_import_test`: "known codes get a price…" | Done |
| Match codes; add a price for a known product | `_classify` | Same | Done |
| Create a Product ID for a new product | `_createProduct` | Same | Done |
| Stop duplicate or ambiguous rows for review | `_classify`; `PriceListService.reviewQueue`, `resolveMatch`, `resolveCreate`, `resolveSkip`; "قيد المراجعة" tab | `price_list_import_test`: "a duplicate row stops", "an ambiguous code stops", group "review queue" | Done |
| Single or small group: brand, list/version, effective date, then code, list price, variant and missing data, with no file | `PriceListImportService.enterRows`, `_EntryDialog` | `price_list_import_test`: group "single or small-group entry" | Done |

## 3.3 Price List record

| Requirement | Where | Test | Status |
|---|---|---|---|
| Own Price List ID, Brand, List Type, Currency, Effective From/To, import date, source file/pages, row count | `PriceLists` columns | `price_list_test`: "the record holds…" | Done |
| VAT status after verification from the source | `vatStatus`, `vatRateBp`, `PriceListService.setVat` | `price_list_test`: "VAT stays unverified…" | Done |
| Never overwrite or erase history | `addEntries` refuses a priced product; no delete exists; `withdraw` keeps the rows | `price_list_test` | Done |
| Close the previous version's period | `createVersion(closePrevious: true)` | `price_list_test`: "V1 ends June 30 when V2 starts July 1" | Done |
| Link every transaction with the version it used at approval | `priceListId` and `listPrice` on sales and purchase invoice items and order lines | `pricing_policy_test`: "the blueprint example", "a purchase order approves…" | Done |
| Several lists per brand (Ceramic, Bathtubs, Premium, Economic, spare parts) | `listType`; one quote per brand and type; the person picks (`pickSellQuote`) | `price_list_test`: "more than one list for a brand"; `pricing_policy_test`: "two lists in force" | Done |
| Quote or order on V1 keeps V1; new ones use V2 | `SalesOrderService.confirm` and `deliver` with `PricingSnapshot` | `pricing_policy_test`: "an order approved on V1 keeps V1" | Done, duration Open (see decisions) |

## 3.4 Discount engine

| Requirement | Where | Test | Status |
|---|---|---|---|
| Buying and Selling policies are separate; changing one never affects the other | `BuyingPolicies`, `SellingPolicies`, separate services | `pricing_policy_test`: "buying and selling are independent" | Done |
| Buying: Supplier + Brand + Price List, then All/Category/Product | `BuyingPolicyService.policyFor` | `pricing_policy_test`: "Supplier A and Supplier B" | Done |
| Priority Product, then Category, then All | `PolicyScope.rank` | `pricing_policy_test`: both "exception priority" tests | Done |
| Base and extra purchase discount; none assumed | `baseDiscountBp`, `extraDiscountBp`; a purchase order refuses a line with no policy | `pricing_policy_test` | Done |
| Selling: Brand + Price List + B2C/B2B/Project + scope | `SellingPolicyService.policyFor` | `pricing_policy_test`: "each pricing type has its own discount" | Done |
| Customer discount or negotiation, with permission to approve the exception | `SellQuote.totalBp`, `SellingPolicyService.check`, `ApprovalRequiredException`, `ApprovalService` | `pricing_policy_test`: "a discount past the policy limit" | Done |
| Base 21% plus one point is 22% | `SellQuote.totalBp` | `pricing_policy_test`: "base 21% and one more point is 22%" | Done |
| Invoice discount split proportionally over lines | `allocateProportionally`, `invoiceDiscountShare`, `netTotal`; old invoices split in the upgrade | `pricing_policy_test`, `schema11_upgrade_test` | Done |
| Before approval: list price, each discount and source, final price, VAT, FIFO/expected cost, gross profit, margin, limits and approvals | `SalePreviewService`, `sale_preview_dialog.dart`, on sales and order confirmation | `pricing_policy_test`, `features/section3_screens_test`, `features/sales_flow_test` | Done |

## Page 10 scenario

| Requirement | Test | Status |
|---|---|---|
| Supplier recorded separately from brand | `schema11_upgrade_test` | Done |
| Opening stock by SKU, location, quantity and actual cost, not list price | `product_test`: "opening stock becomes a movement and a FIFO layer", "opening stock needs its actual cost"; `import_test` | Done |
| List 1,000, supplier 30% = 700, customer 20% = 800, profit 100, margin 12.5%, markup 14.29%, kept apart | `pricing_policy_test`: "the blueprint example" | Done |
| Below FIFO cost forbidden unless a written owner exception | `pricing_policy_test`: "below FIFO cost is refused", "the invoice discount counts" | Done |
| Discount, margin or credit overrun needs approval | `pricing_policy_test`; credit limit in `money_in_out_test` | Done |

## Page 11, acceptance item 1 (Products and Pricing)

Full and single import, no duplicates, list history, VAT, supplier and customer
discounts: covered by the tests above. Run with `flutter test`.

## Decisions for the owner and accountant

The blueprint (11.3) requires these to be approved before go-live. The system
holds a safe default until then; none is invented as fact.

1. **VAT on invoice totals.** VAT is verified per list, shown before approval and
   stored on each sale line, but invoice totals and payments do not add it yet.
   That belongs with the accounting and tax sections.
2. **Input VAT recoverability.** A buy quote shows net cost and VAT, but the FIFO
   layer holds the net cost only. Confirm whether unrecoverable VAT joins the cost.
3. **Price Lock terms and duration.** An approved order keeps its version with no
   expiry. Confirm whether a lock should end after a set period.
4. **Stacking discounts.** Base and extra, and policy, customer and negotiation,
   are added together, following the 21% + 1 = 22% example. Confirm this holds for
   buying discounts too.
5. **Pricing types.** Customer levels map to retail = B2C, wholesale = B2B,
   contractor = Project. Confirm.
6. **Who may approve.** "Written owner exception" and "approval" are the admin
   role. There is no separate owner role.
7. **Cashier limit.** With no limit set on a policy, a cashier may give 5% beyond
   policy and customer discounts, carried over from 1.1.0. Confirm or set limits.
8. **Manual prices.** A product with no approved list price can only be sold by an
   admin, and it is logged. Until the lists are loaded, cashiers cannot sell such
   products. This is an interpretation of the governing rule.
9. **Cost visibility.** FIFO cost, profit and margin are shown before approval to
   the admin only, keeping the existing rule that cashiers do not see cost.
10. **Currency.** The Currency field exists but only EGP is accepted: there is no
    exchange rate in the system to convert with.
11. **Lists with no codes.** Some makers' lists, such as Plaza, have no codes. The
    exact name then identifies the product within its brand and colour, and a new
    name makes a new product. A renamed item would become a new product. Confirm.
12. **Old and new stock.** Stock counts as new when its list price equals today's
    price, even under a later version. Selling takes the oldest first and uses
    today's list price, not the price the stock came in under. Confirm.

## Reviewing migrated data (after upgrading from 1.1.0)

Nothing is deleted, but nobody verified the old values, so they wait:

- Old supplier lists become versions marked "قيد المراجعة" with VAT unverified.
- Prices on products become lists per brand and level, also waiting.
- Old supplier discounts become buying policies, switched off, needing a brand and
  a price list.
- The old product code becomes both the Product ID and the Manufacturer Code.
  Where those differ in real life, correct the Manufacturer Code.
- Two products whose codes normalize to one match key both survive the upgrade.
  An import stops such a code for review.
