# Setting up Counta's LIRS bot on Google Cloud Run

The bot (`bots/lirs`) files personal income tax on LIRS e-Tax for Counta (docs/lirs-etax-bot.md). It runs on Google Cloud
Run: Google builds it from this repository, starts it when Counta has work for it, and stops it when there is none. These
steps take about 20 minutes. Every command goes into Cloud Shell, one block at a time.

What you need: a Google Cloud project with billing on, where you are an Owner (or have Cloud Run Admin, Service Account
Admin, Secret Manager Admin and Cloud Build Editor), and the Counta admin portal.

## 1. Open Cloud Shell in the project

1. Go to https://console.cloud.google.com and choose the project for Counta in the project list at the top.
2. Click the Cloud Shell button (`>_`) at the top right. A terminal opens at the bottom of the page.
3. Make sure it points at the right project (put your project's id in place of `PROJECT_ID`):

```
gcloud config set project PROJECT_ID
gcloud config get-value project
```

## 2. Turn on the services the bot uses

```
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com
```

## 3. Give the bot its own Google account

```
gcloud iam service-accounts create counta-lirs-bot --display-name="Counta LIRS bot"
```

## 4. Make the secret Counta and the bot share

This makes a random 64-character secret, keeps it in Secret Manager, and lets only the bot's account read it.

```
openssl rand -hex 32 | tr -d '\n' | gcloud secrets create lirs-bot-secret --replication-policy=automatic --data-file=-
gcloud secrets add-iam-policy-binding lirs-bot-secret \
  --member="serviceAccount:counta-lirs-bot@$(gcloud config get-value project).iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

## 5. Get the code

```
git clone https://github.com/KelechiIbe/counta.git
cd counta/bots/lirs
```

If you have done this before, use `cd ~/counta && git pull && cd bots/lirs` instead.

## 6. Build and start the bot

```
gcloud run deploy counta-lirs-bot \
  --source . \
  --region europe-west1 \
  --service-account "counta-lirs-bot@$(gcloud config get-value project).iam.gserviceaccount.com" \
  --allow-unauthenticated \
  --no-cpu-throttling \
  --cpu 1 --memory 2Gi \
  --min-instances 0 --max-instances 1 --concurrency 4 \
  --timeout 900 \
  --set-env-vars "COUNTA_BOT_URL=https://krtqqhndmncarwusukrw.supabase.co/functions/v1/taxstreem/lirs" \
  --set-secrets "LIRS_BOT_SECRET=lirs-bot-secret:latest"
```

- When it asks to create an Artifact Registry repository, answer `Y`.
- The first build takes five to ten minutes (the image carries a Chromium browser). It ends with
  `Service URL: https://counta-lirs-bot-….run.app`. Keep that address for step 8.

What the settings do:

- `--allow-unauthenticated`: Counta's database and functions call the bot over the internet. Every call must carry a
  signature made with the shared secret; the bot refuses anything else, and its only open page says whether it is up.
- `--no-cpu-throttling`: the bot answers Counta at once and carries on working.
- `--max-instances 1`: one browser, one person at a time, as e-Tax keeps one session per account.
- `--min-instances 0`: nothing runs, and nothing is billed, while there is no work.

If Google refuses `--allow-unauthenticated` with a message about an organisation policy ("do not belong to a permitted
customer"), the organisation blocks public services: ask whoever administers it to allow this one service.

## 7. Check that it answers

```
curl -s "$(gcloud run services describe counta-lirs-bot --region europe-west1 --format='value(status.url)')/health"; echo
```

It answers `{"ok":true,"busy":false}`.

## 8. Tell Counta where the bot is

1. Show the secret in Cloud Shell:

   ```
   gcloud secrets versions access latest --secret=lirs-bot-secret; echo
   ```

2. In Counta's admin portal, Keys and integrations, TaxStreem: set **LIRS bot address** to the Service URL from step 6 and
   **LIRS bot secret** to the 64 characters, and save each.
3. Type `clear` in Cloud Shell. Do not paste the secret anywhere else.

From then on Counta wakes the bot when someone files a Lagos return or asks for a transfer account, and every five minutes
while a job is due (a retry or a payment check).

## Watching it work

Cloud Run, `counta-lirs-bot`, Logs: each job is a line such as `{"job":"…","kind":"file","done":true}`, and a failure says
why. Passwords never appear. In Counta, each person's row shows the step the bot is on, the bill, and the payment.

## Updating the bot

```
cd ~/counta && git pull && cd bots/lirs
```

then the deploy command in step 6 again. Counta keeps working with the old version until the new one is up.

## Cost

Google bills the bot only while it is up: from a wake-up until about 15 minutes after its last call. At 1 vCPU and 2 GiB
that is about US$0.08 an hour at Cloud Run's list price; days with no filing cost nothing. A paid bill is checked every
15 minutes for up to three days, which keeps the bot up for those days.

## Later

- When Counta moves to Google Cloud, `COUNTA_BOT_URL` changes to the new functions address (redeploy with the new value),
  and the e-Tax passwords move from Supabase Vault to Secret Manager.
- The bot keeps nothing of its own: no database, no files. Deleting the service stops it; the jobs wait in Counta.
