# Phone calls and push notifications

## Phone calls (ElevenLabs Agents)

Martina places two kinds of outbound call.

**Vendor orders.** From an open purchase order (Reorder, or the screen that appears after "Approve & send"), someone who can approve purchase orders taps *Call vendor*. `prepare_vendor_call` checks the order and the vendor's phone number, turns the number into +234 form and records a `voice_calls` row with the facts Martina reads out: business, vendor, order reference, lines, total, delivery branch, a contact name and number, and the vendor's usual lead time. The `voice` edge function then places the call with `POST /v1/convai/twilio/outbound-call` (or the SIP trunk endpoint), passing those facts as dynamic variables.

**Reminders.** From Locations & staff, an owner or manager taps the phone icon beside a person and picks a topic: counts waiting for approval, a count to finish, invoices to confirm, a transfer to receive, or price checks to decide. `prepare_reminder_call` refuses when nothing is actually waiting, so nobody gets called about an empty queue.

Both agents are created by the `voice` function on the first call and patched whenever their prompt version or the configured voice changes; their ids live in `voice_agents`. Each agent says it is an AI assistant calling for the business, speaks Nigerian English and switches to Pidgin when the other person does, never takes or discusses payment details, and ends politely when asked. Calls are capped at five minutes for vendors and two and a half for reminders.

Results come back through ElevenLabs' conversation record. A pg_cron job (`counta-voice-poll`) asks the `voice` function once a minute to refresh calls that are still live, and the app refreshes any live call it is showing. When a call ends, `voice_call_update` stores the outcome fields (order confirmed, delivery date, unavailable items, price changes, callback time for vendors; will act and when for reminders), the summary and the transcript. A confirmed vendor order is marked sent by phone with a note on the order, and the person who started the call gets a notification.

### Switching it on

1. Create an ElevenLabs API key with access to Agents and phone numbers and store it as `ELEVENLABS_API_KEY` (Vault or Edge Function secret).
2. Connect a number in ElevenLabs under Phone Numbers. A Twilio number is the simplest route: buy one in Twilio, or verify the business's own line as a Twilio caller ID, then import it into ElevenLabs with the Twilio account SID and auth token. A SIP trunk from a Nigerian carrier works too.
3. Optional: set `ELEVENLABS_PHONE_NUMBER_ID` when the account has several numbers, and `ELEVENLABS_VOICE_ID` to pick a voice.

Settings > Phone calls shows whether calls are switched on and from which number.

## Push notifications

Rows inserted into `public.notifications` are pushed to every active device of that user. The trigger `notifications_push` calls the `push` edge function through `pg_net` with the hook secret; the function signs each message with the VAPID key and drops subscriptions the push service reports as gone (404/410) or that fail five times in a row. `private.notify` and `private.notify_perm` create the rows, de-duplicating by tag for ten minutes, and stay quiet while the sample business is being generated.

| Event | Who hears | Opens |
| --- | --- | --- |
| Count submitted for approval or reasons | People who approve adjustments | `/inventory/counts?open=<id>` |
| Count rejected for a recount | The counter | `/m/count/<id>` |
| Invoice needs review after reading | The person who captured it and owners | `/inventory/receive?open=<id>` |
| Transfer sent | People who receive stock at the destination | `/m` |
| Transfer received | The person who sent it | `/inventory/locations` |
| Price proposal opened | People who edit prices | `/inventory/pricing` |
| Phone call finished | The person who started it | `/inventory/reorder` or `/inventory/locations` |

On the device, `public/push-sw.js` shows the notification and, on tap, focuses an open Counta window and routes it to the link (or opens a new window). The app asks to be installed first: Chrome on Android shows its own install prompt, and on iPhone the banner walks through Share, then Add to Home Screen. iPhones only allow push for apps added to the Home Screen, on iOS 16.4 or later. Settings > Notifications turns push on or off per device and sends a test.
