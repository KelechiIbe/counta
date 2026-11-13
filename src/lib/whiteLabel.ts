// Whether a public page shows "Powered by Counta". An unknown business (a page still loading, an error or a "waiting" screen)
// shows nothing, so a client who opens a white-labelled document never sees the Counta name on a transient screen.
export function showPoweredBy(org?: { white_label?: boolean } | null, whiteLabel?: boolean): boolean {
  if (whiteLabel === undefined && !org) return false;
  return !(whiteLabel ?? org?.white_label === true);
}
