# Sign-up, onboarding with Martina, and Nigerian voices

## Sign-up

`/signup` asks for a name, email, an optional mobile number and a password. Supabase sends a confirmation email; the person types the six-digit code (`verifyOtp`, type `signup`) or taps the link, and lands on `/onboarding`. The mobile number is kept in the account's metadata (`phone`) and offered for the business phone and for Martina's follow-up call.

For the code to appear in the email, the Supabase "Confirm signup" email template must include `{{ .Token }}` (Authentication, Emails, Confirm signup). A suggested body:

```
<h2>Welcome to Counta</h2>
<p>Your code is <b style="font-size:22px;letter-spacing:4px">{{ .Token }}</b>. It works for an hour.</p>
<p>Or <a href="{{ .ConfirmationURL }}">confirm your email</a> on this device.</p>
```

Supabase's built-in email service only sends to members of the Supabase team, a few an hour, so sign-up needs custom SMTP. Set it up in this order, all in the Supabase dashboard:

1. Authentication, Emails, SMTP settings: turn on custom SMTP. Host `smtp.resend.com`, port `465`, username `resend`, password a Resend API key (create one in Resend with sending access only), sender email an address on the domain verified in Resend (the one in `RESEND_FROM`), sender name `Counta`.
2. Authentication, Emails, Confirm signup: paste the template above.
3. Authentication, Sign In / Providers, Email: turn on "Confirm email". While it is off, sign-up sends no email and skips the code.
4. Authentication, Rate Limits: raise the emails-per-hour limit (custom SMTP starts at 30 an hour).
5. Sign up with a spare address. The code arrives, and the email shows in Resend's Emails log.

## Onboarding (`/onboarding`)

The stages, worked out from the person's profile (`kyc_draft`) unless Martina or a button moves the screen:

1. **Welcome.** Talk to Martina, type to her, or fill everything in by tapping. English or Pidgin.
2. **Find the business.** `mono` function, action `cac_search`: the CAC register through Mono Lookup, by name or RC number. "Not on CAC" keeps the name, status and address as given (`kyc_manual`).
3. **What Counta found.** `cac_select` fetches the company profile, directors and shareholders (from their own lookups when the profile leaves them out), persons with significant control, the secretary, and the Tax ID the NRS holds for the RC number. The `ai` function (action `business_insights`) searches the web with Gemini and Google Search: a summary, website and social pages, examples of what the business sells, a suggested category and goods or services, and up to three candid observations. Everything Mono and the web return is written by the server (`svc_kyc_store`), never by the browser.
4. **Questions.** Goods, services or both; the category (the web's suggestion first); yearly sales band (up to ₦50m, ₦50m to ₦100m, above ₦100m); how customers pay and how the business pays; why Counta; examples; and whether VAT, withholding tax and income tax returns are filed. Each answer is saved as it is given (`kyc_answer`) and tips appear as answers come in.
5. **Summary.** Editable trading name, phone, email and address, and every answer with a Change button.
6. **Score.** `kyc_submit` sets the business up from the CAC record and returns the compliance score out of ten (`compliance_score`), with what is sorted and what to do next. The ten rules and their wording live in `compliance_rules`, so TaxStreem can change the advice without a release.
7. **CAC document.** Fetched from CAC for the business (`cac_status_report`, a PDF) or uploaded (status report, application for registration, certificate). It is stored in `documents/<business>/kyc/`, which only the owner can open, and read by Gemini (`read_cac_document`): the name, RC number and date are checked against the CAC record.
8. **Into Counta.** Home shows the checklist until every step is done or skipped.

**What is kept about people.** Directors, shareholders and the secretary are kept by name, role, appointment date and shares. Dates of birth, ID numbers, phone numbers, email addresses and home addresses from CAC are dropped before anything is stored, and the profile is only shown to the business's owner.

**Allowances.** Per person per day: 20 CAC searches, 6 company lookups, 6 Tax ID lookups, 3 status reports, 8 web searches and 6 document readings (`svc_kyc_take`).

## A director's NIN, and TaxStreem's review

After the score, onboarding asks a director to type or say their NIN. Mono looks it up and the database compares the names
with the directors on the CAC record; only the outcome and the last four digits are kept. If it does not match, the owner
adds the NIN slip, which Gemini reads and the database compares again. A slip that still matches no director waits for
TaxStreem (`identity_status = 'review'`), and the business's wallet, payment links and payouts stay locked until then.

When a slip waits, Counta emails the review address and every reviewer on the admin portal's Team page. The review address
is "Email for NIN slip reviews" under Keys and services, Counta, and is admin@taxstreem.com when left empty. The email names
the business and links to `/admin/reviews`; it carries no NIN and nothing from the slip. A reviewer needs a Counta account
and an authenticator code, and is added by an admin on the Team page.

## The checklist on Home

Steps are checked from what really happened (`private.guide_steps`): business found, questions answered, profile submitted, CAC document on file (optional), an active business account number, a voice chosen, a first sale, a bank linked (optional), a bank statement uploaded (optional), products added (optional), another team member (optional). The owner can skip optional steps, hide the checklist, and agree to one follow-up call.

## Martina, the guide

An ElevenLabs agent (`voice` function, agent kind `guide`) with Counta's tools as client tools. The web app asks the voice function for a token (`guide_token`: a WebRTC conversation token, or a signed URL for typing only). The agent requires a token (`enable_auth`), so nobody can start it from outside Counta; each conversation may change only the voice, the opening line and text-only mode, never the instructions. Recordings are not kept and transcripts go after 30 days. Eight conversations a day and 25 a week per person (`svc_guide_session`).

The tools (find_business, choose_business, web_insights, not_registered, save_answers, show_summary, submit_profile, get_score, fetch_cac_report, open_upload, show_screen, get_account_number, offer_voices, set_voice, play_payment_demo, mark_step, set_language, call_consent, celebrate, get_progress) run in the browser as the signed-in person, through the same calls the screens make, so Martina can do nothing the person could not do with a tap. Taps on screen are told to Martina as context, so she keeps up.

**Follow-up calls.** Someone who agreed and gave a number, started within the last week, and has been away three hours gets at most two calls, a day apart, between 9:00 and 18:30 Lagos time (cron `counta-guide-followups` every 15 minutes, `voice` action `guide_followups`). Saying "don't call me again" withdraws the consent. Calls need a phone number connected in ElevenLabs (Twilio or SIP trunk).

## Nigerian voices

The voices on offer are the three most used female and three most used male Nigerian voices in the ElevenLabs voice library (or the voices in `ELEVENLABS_VOICE_IDS`), added to TaxStreem's ElevenLabs account and listed in `tts_voices`. The owner or a manager picks one in onboarding or Settings, English or Pidgin, and which events are spoken. "Payment received" (transfers, links and QR payments) and voice sales on the phone app are said in that voice (`speak`), with the words built from the database (`voice_say`), never from the browser. Without a connection, over the allowance (600 phrases and 60,000 characters a day per business), or if ElevenLabs is slow, the device's own voice says the same words. Phone calls to vendors and staff use the business's voice too.

## Secrets (Supabase Edge Function secrets)

| Secret | For |
|---|---|
| `ELEVENLABS_API_KEY` | Voices, announcements, Martina, calls |
| `MONO_LOOKUP_SECRET_KEY` | CAC and Tax ID lookups, when the lookup product is on a different Mono app (otherwise `MONO_SECRET_KEY` is used) |
| `ELEVENLABS_VOICE_IDS` (optional) | Comma-separated voice ids to offer instead of searching the library |
| `ELEVENLABS_VOICE_ID` (optional) | Martina's default voice |
| `ELEVENLABS_TTS_MODEL` (optional) | Announcement model, default `eleven_flash_v2_5` |
| `ELEVENLABS_PHONE_NUMBER_ID` (optional) | Which connected number places calls |

## Tests

SQL: `t_voice.sql` (voices, allowances, profile, answers, submit, score, document, storage rules, guide, sessions, follow-ups). Edge: `test_onboard.ts` against mock Mono Lookup, Gemini with Google Search and ElevenLabs. UI: `onboard.py` at desktop and phone widths, with Martina's tools driven through a test-only hook (`VITE_GUIDE_TEST=1` builds only).
