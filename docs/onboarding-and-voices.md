# Sign-up, onboarding with Martina, and Nigerian voices

## Sign-up

`/signup` asks for a name, email, an optional mobile number and a password. Supabase sends a confirmation email; the person types the code (`verifyOtp`, type `signup`; Counta's project sends eight digits and the field takes six to ten) or taps the link, and lands on `/onboarding`. The mobile number is kept in the account's metadata (`phone`) and offered for the business phone and for Martina's follow-up call.

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
4. **Questions.** Goods, services or both; the category (the web's suggestion first); yearly sales band (up to ₦50m, ₦50m to ₦100m, above ₦100m); how customers pay and how the business pays; why Counta; examples; and whether VAT, withholding tax and income tax returns are filed. The screen shows one question at a time, in that order (`QUESTION_ORDER` in `src/lib/onboard.ts`, the same list in the voice function): the one Martina is asking, or the first still open. A row of dots shows progress and opens any question; Back goes to the one before. A tap on a single-answer question saves it and moves on; questions with several answers (how customers pay, how the business pays, why Counta, examples) save each pick quietly and move on when the person taps Done. Each answer is saved as it is given (`kyc_answer`) and tips appear as answers come in.
5. **Summary.** Editable trading name, phone, email and address, and every answer with a Change button, which opens that question on its own.
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

The tools (find_business, choose_business, web_insights, not_registered, save_answers, show_question, show_summary, submit_profile, get_score, fetch_cac_report, open_upload, show_screen, get_account_number, offer_voices, set_voice, play_payment_demo, mark_step, set_language, call_consent, celebrate, get_progress) run in the browser as the signed-in person, through the same calls the screens make, so Martina can do nothing the person could not do with a tap. She calls `show_question` as she asks each question, so the screen shows only that one.

**Taps on screen.** A tap that answers her (a question, the business picked from the search, "That's us", a voice chosen, the NIN checked, the CAC document read, Set up my business) reaches Martina as the person's own words, marked "(Tapped on screen)", with a note of what the screen now shows (`answer` in `GuideProvider`). Her instructions say the choice is already saved: she confirms it in a few words and goes on, and drops whatever she was explaining. If she is mid-sentence when the tap comes, her voice is turned down at once and comes back when that speech stops or her reply begins (twelve seconds at most). The NIN itself never goes to her: she hears only whether it matched. Smaller moves (Back, a dot, Change on the summary) reach her as background, which she does not answer. While she is talking, her panel never covers onboarding's buttons: on a wide screen the page moves left of it, and below 1180 pixels the panel shrinks to her name, her last line and the controls, with the buttons above it.

**How she talks** (`TALK` in `supabase/functions/voice/guide.ts`, used by the guide, the assistant and the phone calls). Short turns of one or two sentences, never reading out what is on screen, stopping as soon as the person says "ok", "got it", "yes" or starts answering, and never going back to finish a sentence they cut off. Answers are confirmed in a few words. She writes no sounds or stage directions (no sighs, laughs or "hmm"), shows feeling in words only when it fits (a short "well done" for a real win, "sorry about that" when something goes wrong), and is never excited. Murmurs such as "mm-hmm" and "uh-huh" do not cut her off (`interruption_ignore_terms`); "ok", "yes" and "wait" do.

**Her voice model** (admin portal, Martina and voices). Eleven v4 Turbo is the default and the most natural; it is the only one that takes the expressive cues the warm and lively manners use. Turbo v2.5 and Flash v2.5 read plainly and add no sighs or laughs of their own. The choice is saved with her manner (`admin_save_setting('martina', {"voice_model": …})`, one of the three) and reaches ElevenLabs the next time anyone starts a conversation with her. If ElevenLabs refuses the newer settings, the voice function tries again without the murmur list, then without the model, logs the refusal, and Martina carries on as before.

**Follow-up calls.** Someone who agreed and gave a number, started within the last week, and has been away three hours gets at most two calls, a day apart, between 9:00 and 18:30 Lagos time (cron `counta-guide-followups` every 15 minutes, `voice` action `guide_followups`). Saying "don't call me again" withdraws the consent. Calls need a phone number connected in ElevenLabs (Twilio or SIP trunk).

## Martina, the assistant, and "Hello Martina"

The same kind of agent (`voice` function, agent kind `assistant`, token `assistant_token`) answers questions about the business everywhere in Counta: the AI Assistant page, the corner launcher and the phone app's Martina tab. Her mark is TaxStreem's speech-bubble icon (`MartinaMark` and `MartinaAvatar` in `src/components/Icon.tsx`; the original files are in `public/brand/`). In a conversation the dot inside the bubble brightens with her voice and rings ripple out while she listens.

**Doing things on a yes** (`src/guide/actions.ts`). Martina can record a sale (`record_sale`, through `record_quick_sale` at list prices, marked as recorded by voice), issue an invoice to a customer already in Counta and send it by WhatsApp or email (`issue_invoice`), approve a supplier bill waiting for approval (`approve_bill`) and remind a customer who owes (`remind_customer`). Each tool first checks everything and holds the action on screen with Approve and Cancel; Martina reads it back. `confirm_action` carries it out only when the last thing the person said since the read-back is a clear yes (English or Pidgin; anything with "no", "wait", "cancel" or "change" in it is not a yes). The app checks the words itself rather than trusting the agent, and a tap on Approve does the same. An action waits at most ten minutes and is dropped when the conversation ends. The database's own permission checks still apply to every call.

Money out is never done by voice: `pay_bill` opens the bill on screen and the person taps Pay; payouts, bulk payments and tax payments are opened for a tap the same way.

**Hands-free** (`src/guide/handsFree.ts`). Each device can switch on "Hands-free: say Hello Martina" (the AI Assistant page, the phone's Martina tab, or under a conversation). While Counta is open and on screen, the browser's own speech recogniser listens for "Hello Martina" (also "Hi", "Hey", "OK" and "Good morning Martina", and the ways recognisers mishear her name). Hearing it, Counta chimes, stops listening so the microphone is free, and opens a voice conversation with whatever was said after her name (`assistant_token` with `hands_free`; with a request she starts by answering it, without one she says "Yes, <name>?"). The conversation closes after twenty seconds of quiet (a minute while an action waits for a yes) or after her goodbye (`finish`), and listening starts again. It pauses while the phone's voice sale is recording and while Counta is in the background.

The recogniser belongs to the browser: Chrome and Edge send what the microphone hears to Google's speech service, Safari to Apple's. A web app cannot listen while it is closed or the phone is locked; that would need a native app. Firefox has no recogniser, so the switch says so.

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

SQL: `t_voice.sql` (voices, allowances, profile, answers, submit, score, document, storage rules, guide, sessions, follow-ups) and `t_voicemodel.sql` (the voice model setting). Edge: `test_onboard.ts` against mock Mono Lookup, Gemini with Google Search and ElevenLabs. UI: `onboard.py` at desktop and phone widths, with Martina's tools driven through a test-only hook (`VITE_GUIDE_TEST=1` builds only) and a stand-in conversation that logs what each tap sends her and when her voice is turned down.
