# Production runs and jobs

Inventory → Production & jobs lets staff issue raw materials, packaging and spares out of stock to something that uses them. There are two kinds.

A **production run** makes a finished item from materials: bread from flour and yeast, blocks from cement and sand, a batch of soap. Materials issued to a run sit in work in progress until someone records what it made. The run's whole cost, materials plus any labour, power or other costs added at the end, then moves into the finished item at a unit cost the run worked out.

A **job** consumes stock without making an item for sale: a generator service, a customer's AC repair, a roof, a fit-out. Stock issued to a job is charged straight to the account the job names, such as direct materials for a customer job, repairs and maintenance for upkeep, or capital work in progress for building work.

Refs run per business: RUN-0001 for runs, JOB-0001 for jobs.

## Recipes

A recipe (bill of materials) says what one batch of an item takes: a yield (one batch makes 50 loaves) and each material with its quantity in its selling unit and an expected wastage percentage. Recipes live on the Recipes tab and need Edit costs and prices. They do three things.

1. Fill from recipe on the issue screen proposes what is still needed for the run's planned quantity, after what has already gone to it.
2. The run's drawer compares the recipe with what was actually used, scaled to the quantity made, and shows anything more than 5% over in red. That gap is where waste and leakage hide.
3. The recipe's cost at today's average costs appears beside the real cost per unit when output is recorded, with the margin at the current selling price.

## Who can do what

A ninth permission, **Issue to jobs** (`issue_stock`), lets a person open runs and jobs and issue or return stock. Owner, manager and staff templates have it; cashier does not. Recording a run's output and cancelling a run need Approve adjustments, because they set a cost and can write value off. Closing a job needs only Issue to jobs.

## On the phone

The phone app has an Issue to a job tile. The person picks an open run or job at their branch (or opens a quick job by name), adds items by search or barcode, or fills from the recipe, and issues. With no data the issue waits on the phone and posts later with the time it was made, flagged offline, and its client UUID stops a retry from posting twice. Production runs are opened from the full app, where the output item and planned quantity are set.

## What posts

Codes are the defaults. The roles are set in Settings → Chart of accounts like every other role.

| Event | Function | Debit | Credit |
| --- | --- | --- | --- |
| Issue to a production run | `issue_materials` | 1202 Inventory - Work in Progress, qty × WAC | the material's inventory account |
| Return from a run | `issue_materials` with `p_return` | the material's inventory account | 1202, at the cost it left at |
| Issue to a job | `issue_materials` | the job's account (default 5202 Direct Materials & Expenses) | the material's inventory account |
| Return from a job | `issue_materials` with `p_return` | the material's inventory account | the job's account |
| Labour and other costs added at output | `complete_production` | 1202 | 5400 (role `production_absorbed`) |
| Output of a run | `complete_production` | the finished item's inventory account, the run's whole cost | 1202 |
| Run cancelled with value still in progress | `close_job` with `p_cancel` | 6805 Inventory Write-Downs (role `stock_loss`) | 1202 |

Issues relieve stock first expiry first out at weighted average cost. A return goes back at the average cost the material left at, so a run's work in progress never carries a gain or loss from the return itself. Output adds to the finished item's quantity and recomputes its weighted average cost. When a run's unit cost comes out more than 1% above the item's previous average, a price check opens in Pricing. Issuing more than the books show at the branch is allowed, because the material is physically there, but the screen names the items that went below zero so someone counts them.

Each run's work in progress is the sum of its journals on 1202 (source type `production`, source id the run), so the Stock valuation report lists open runs as "Work in progress · RUN-…" lines and still agrees to the ledger.

A job can be charged to 5202, 5207, 5209, 5305, 5306, 6208, 6209, 6216 or 1521. The run's own 1202 is fixed. Labour absorbed into a run is credited to 5400 by default (5401, 5201, 5304 or 5306 are allowed), so the wages stay in their expense account and the part that became stock leaves cost of sales through the inventory movement line.

## Tables and functions

`jobs` holds both kinds: ref, kind, name, branch, status (open, completed, cancelled), output item, planned and produced quantity, output unit cost, charge account, customer, due date, notes and a client UUID. `recipes` holds one row per output item with its yield and lines. Movements gain a `job_id` and three types: `issue`, `issue_return` and `production_in`.

| Function | Permission | Purpose |
| --- | --- | --- |
| `save_job(org, job)` | Issue to jobs | Open or edit a run or job; idempotent on the client UUID |
| `issue_materials(job, lines, return, client_uuid, device, offline, recorded_at)` | Issue to jobs | Issue or return stock; returns the journal ref, value and any lines the books now show below zero |
| `complete_production(job, qty, extra)` | Approve adjustments | Post output with extra costs, batch number and best-before date, then close the run |
| `close_job(job, cancel, note)` | Issue to jobs (cancelling a run: Approve adjustments) | Close a job or cancel either kind |
| `save_recipe(org, item, yield, lines, notes)` | Edit costs and prices | Save a recipe; empty lines remove it |
| `get_jobs(org, closed_days)` | Member | Open and recent runs and jobs with materials, costs (masked without See margins), recipes and the accounts a job can use |

Two reports sit under Reports → Production: **Production runs and jobs** (every run or job in the period with materials, returns, other costs, output and cost per unit) and **Stock issued to jobs** (each issue and return with run or job, branch, item, quantity, cost and who did it). The Stock movement summary has issued and produced columns, and the month-end pack includes the runs and jobs report.
