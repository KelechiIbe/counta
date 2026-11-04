# Counta's LIRS e-Tax bot

Files a person's personal income tax return on LIRS e-Tax with their own login, raises the bill, fetches the one-time
transfer account when someone pays, and checks for the payment. How it works: `docs/lirs-etax-bot.md`. Setting it up on
Google Cloud Run: `docs/lirs-bot-cloud-run.md`.

```
npm ci
npm test          # the bot against a stand-in e-Tax, payments page and checkout (test/mock.ts)
npm start         # needs COUNTA_BOT_URL and LIRS_BOT_SECRET
```

- `src/server.ts`: `GET /health`, and `POST /tick` signed with `LIRS_BOT_SECRET`.
- `src/runner.ts`: takes jobs from Counta one at a time and reports back.
- `src/etax.ts`: signs in on e-Tax's login page and makes the taxpayer screens' own API calls.
- `src/file.ts`, `src/bill.ts`: the return, step by step, and the bill.
- `src/lasg.ts`: the Lagos State payments page and Flutterwave's checkout.
