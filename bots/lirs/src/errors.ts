// What can go wrong, and whether trying again later can help.

// e-Tax would not let the person in: a wrong Payer ID or password, or e-Tax wants a new password first.
// Counta marks the login as not working and does not try again until it is saved again.
export class LoginRefused extends Error {}

// Something about the job or the portal that trying again will not change (e-Tax refused the data, a return already
// confirmed by someone else, a missing file). The message is for the person, in plain words.
export class Refused extends Error {}

// e-Tax ended the session part way (usually someone signed in to the same account elsewhere). Tried again shortly.
export class SessionLost extends Error {}

// The portal answered with an error worth trying again (INTERNAL_ERROR, a page that did not load).
export class Transient extends Error {}

export function retryable(e: unknown) {
  return !(e instanceof LoginRefused || e instanceof Refused);
}

// Never let a password reach a log, a report or an answer.
export function scrub(text: string, secrets: (string | undefined | null)[]) {
  let s = String(text ?? '');
  for (const x of secrets) if (x && x.length >= 3) s = s.split(x).join('•••');
  return s;
}
