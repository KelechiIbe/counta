# Gemini on Vertex AI with Application Default Credentials

The `ai` and `atlas` edge functions reach Gemini through Vertex AI in Google Cloud project `infrastructure-staging-477918`, region `us-central1`. They sign in the way Google's own libraries do with Application Default Credentials (ADC), from a credential stored as a Supabase Edge Function secret. A Gemini API key is used only when no ADC credential is set.

## Why a secret holds the credential

ADC looks for a credential in three places: the file named by `GOOGLE_APPLICATION_CREDENTIALS`, the file `gcloud auth application-default login` writes, and the metadata server of a Google Cloud machine. A Supabase Edge Function has none of these, so the contents of that file go into the secret `GOOGLE_APPLICATION_CREDENTIALS_JSON`. `supabase/functions/ai/google.ts` (copied unchanged to `atlas`) reads it, exchanges it for an access token at Google's token endpoint, keeps the token until five minutes before it expires, and calls

`POST https://us-central1-aiplatform.googleapis.com/v1/projects/infrastructure-staging-477918/locations/us-central1/publishers/google/models/<model>:generateContent`

with the same request body the Gemini API takes.

| Credential type | Where it comes from | Notes |
| --- | --- | --- |
| `service_account` | A JSON key for a service account | Recommended for a server. A signed JWT is exchanged for a token. |
| `authorized_user` | `gcloud auth application-default login` | Works, but a person's refresh token can be revoked or expire under the organisation's session rules. Calls carry `x-goog-user-project`. |
| `impersonated_service_account` | `gcloud auth application-default login --impersonate-service-account=<email>` | For organisations that do not allow service account keys. The person needs Service Account Token Creator on that account. |
| `external_account` | Workload identity federation | Not usable here: Supabase has no token source to federate from. |

## Setting it up

1. In project `infrastructure-staging-477918`, enable the Vertex AI API.
2. Create a service account (for example `counta-ai`) and give it the Vertex AI User role (`roles/aiplatform.user`).
3. Create a JSON key for it.
4. In Supabase, Edge Functions, Secrets, add `GOOGLE_APPLICATION_CREDENTIALS_JSON` with the whole key file as the value (pasting it on one line is fine; base64 of the file also works). Add `GOOGLE_CLOUD_PROJECT` = `infrastructure-staging-477918` and `GOOGLE_CLOUD_LOCATION` = `us-central1`.
5. In Counta, Settings, AI reading, press Test the connection. It sends one short request and reports the answer or Google's reason for refusing.

The functions read the secrets again every minute, so nothing needs redeploying. Delete the key file from your computer once the secret is saved, and never commit it to the repository.

## Models

The default is `gemini-3.8-flash` (or `GEMINI_MODEL`). Vertex AI serves the newer Gemini models on its global endpoint rather than in every region, so a model `us-central1` does not have is asked for on the global endpoint and remembered. When a model is busy or not offered at all, the functions try `gemini-3.6-flash`, `gemini-3.5-flash` and then `gemini-2.5-flash`. A refused permission (401 or 403) stops at once with the reason, because no other model would fix it.

Gemini 3 and later models are left at their default temperature (Google warns that a lower one makes them loop or lose accuracy); a temperature is set only for 2.x models. Quick structured jobs ask for low thinking: `thinkingLevel: LOW` on Gemini 3 and later, a thinking budget of 0 on 2.5.
