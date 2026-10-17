# Leak radar and daily spot checks

Most Nigerian retailers and distributors lose more to stock that quietly goes missing than to anything a report shows, and they find out once a year at the stock-take, long after the trail is cold. Leak radar is the Insights tab (the default one for anyone with See margins) that turns every count, write-off and cash-up Counta already holds into three answers: how much is leaking, where, and what to count next. Daily spot checks then act on the answer without anyone remembering to.

## What the tab shows

- **Leaking a month**: value that went missing, damaged or expired over the chosen 30, 90 or 180 days, as a monthly rate.
- **Went missing**: count shortfalls not explained as breakage or expiry, net of stock found, and that figure as a share of cost of sales (shrink %).
- **Damaged or expired**: breakage, expiry and quarantine.
- **Count accuracy**: the share of counted lines within 2% of the books (inventory record accuracy).
- **Cash short**: takings below recorded sales on the days cash was recorded.
- **Losses by week** for the last twelve weeks.
- **Count these next**: the items most likely to have lost money since anyone last checked them, with why (never counted, below zero on the books, lost before, fast mover).
- **By branch**: the same figures per branch.
- **Losses found on items each person sold** (owner only): when a count finds stock missing, its value is shared among the people who sold that item at that branch since it was last counted, in proportion to how much each sold. It needs at least three counts with missing stock in the period before it shows anything, and the screen says plainly that it is a reason to watch and count more often, never proof of who took anything.

## The risk score

`private.item_risk(org, days)` scores every item and branch with stock:

risk = units sold or issued since it was last counted (at most 120 days) × its loss rate × unit cost, plus a small amount for value sitting unchecked, plus the whole value of any quantity the books show below zero

The loss rate is the item's own share of units that went missing when it has a history of losses, otherwise the business's overall rate, never below 0.5%. The result reads as naira likely to have gone since the last check, so the list sorts by money, not by guesswork.

## Daily spot checks

The owner chooses how many items per branch (off, 3, 5, 8, 10 or 15). Each morning at 05:30 Lagos time the `counta-spot-checks` cron job runs `private.cron_spot_checks()`, which for every branch:

1. takes the riskiest items that are not already in an open count and were not counted in the last seven days;
2. gives them to one person with Count stock at that branch, preferring people who can log in, people other than the owner, and among those the one who sold those items least in the last fourteen days, so nobody checks their own sales;
3. creates a blind count session marked `spot_check` and sends that person a push notification.

The counter sees the items on the phone under Counts for you, counts what is on the shelf without seeing the book quantity, and the usual approval flow posts any difference. A manager can also press **Send spot checks now**. Five items a day per branch covers the riskiest few hundred lines a quarter, which is why the screen says daily spot checks replace the month-end stock-take.

| Function | Permission |
| --- | --- |
| `leak_radar(org, days)` | See margins (the people section is owner only) |
| `run_spot_checks(org, n)` | Approve adjustments |
| `set_spot_checks(org, n)` | Owner |
