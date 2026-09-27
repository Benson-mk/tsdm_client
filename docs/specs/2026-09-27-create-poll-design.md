# Create ordinary poll (#128)

## User flow

The forum page offers "Create poll" (small FAB above the new-thread FAB) only when the loaded page itself links to `forum.php?mod=post&action=newthread&fid=<fid>&special=1` for the account still in use. Links inside thread rows or moderator rules, viewing permission and the `specialtype=poll` filter are not treated as an offer. The offer is cleared while the forum reloads or fails. The ordinary new-thread editor shows a "Switch to poll" action in the same case; both editors carry subject and body across an intentional switch (same account and forum only). Nothing is posted on a switch.

The poll page always GETs the special=1 form and validates it before offering input. Input: optional thread type (when the forum has types; "No thread type" is always offered), subject, optional body, choice rows (three initially, as the website's JS does; add/remove up to the forum's `maxoptions`), max selections, duration in days, and the served "results visible after voting" / "public voters" checkboxes. Review opens an inline confirmation inside the page (forum, type, subject, body, exact numbered choices, single/multiple, duration, flags, checked other options); "Back to edit" sends nothing. "Create poll" first checks a fresh form, then posts once.

## Form validation

- Same-origin `#postform` action `forum.php?mod=post&action=newthread&fid=<fid>&topicsubmit=yes`, matching FID, served UID of the owning account, hidden `formhash`/`posttime`/`wysiwyg`, `special=1`, `polls=yes`, `tpolloption` 1/2, the bulk `polloptions` textarea, `maxchoices`, `expiration`.
- `maxoptions` comes only from the real declaration `var maxoptions = parseInt('<digits>');` in inline scripts. A small bounded scanner drops comments and keeps string/regex literals as single tokens, so text inside a comment or string is never a declaration; nothing is evaluated. Missing, conflicting (two declarations), any other assignment to `maxoptions`, an unscannable script mentioning it, or a value <2 falls back to the browser. No limit is hard-coded.
- Any unknown poll-looking field, a CAPTCHA/Q&A field, a filled `pollimage[]`, a non-`1` flag value, or plugin fields `pollplusviewcredit`/`pollpluslockday` with a value other than `0` falls back to the browser. Served neutral `0` plugin values are posted back unchanged; absent fields stay absent.
- A `required` (or `aria-required="true"`) control the app does not fill, a disabled posted control (own `disabled` or inside a disabled `fieldset`: tokens, poll fields incl. `polloptions`/`maxchoices`/`expiration`, flags, plugin fields, `typeid`, `readperm`, passthrough fields), a read-only edited field, or a checkbox inside a disabled fieldset falls back to the browser. Unknown optional template fields (e.g. `adddynamic`, `mygroupid`) are left alone and not posted.
- The generic editor guards (special, specialextra, sortid, JSON editor, scheduled publish, rush reply, reply credit, classified options) are unchanged; poll forms still count as unsupported for the ordinary editor. Editing existing polls is not supported.

## Input rules

- Subject required; `dstrlen` (ASCII 1, any other scalar 2) of the escaped, trimmed subject ≤ served counter (at most 255, the upstream handler limit).
- Body optional (upstream skips the body length rule for special threads).
- Choices are trimmed, blank rows dropped; 2..`maxoptions` choices; a choice containing a line break is rejected because bulk entry is newline separated. The confirmation, count and payload come from the same list.
- Choice length guard: 80 characters counted after upstream `dhtmlspecialchars` (`& " < >`), from the upstream `varchar(80)` column. This is a conservative app guard, not a limit published by the forum form; the live schema is not verified. The payload is raw text.
- Max selections 1..number of choices (app rule; the upstream handler clamps rather than rejects).
- Duration: empty or any all-zero value is unlimited and is posted as empty; otherwise a canonical positive integer (`007` → `7`). `00` or padded zero is never posted (it would end the poll immediately). No maximum is assumed.
- No duplicate-text rule (none upstream).
- Thread type is optional: upstream `model_thread.php` returns `post_type_isnull` only when `!$this->param['special']`, so polls are exempt even on boards that require a type for ordinary threads. No selection (or the served `0`) is accepted; a positive selection must be one of the served choices.
- A flag or checked other option the current form no longer offers is kept on screen with an error until the user turns it off; it is never dropped silently.

## Payload

Served hidden values plus `special=1`, `polls=yes`, `subject`, `message`, `tpolloption=2`, `polloptions` (newline joined), `maxchoices`, canonical `expiration`, checked served flags, neutral plugin fields, `typeid` (the selected positive type, or `0` when a selector is served and nothing is selected, as the website posts), a preselected `readperm`, checked served bool options and the served empty `save`. `polloption[]` is not posted (the Android client cannot encode repeated keys). Poll drafts are never created in the app: a website poll draft starts its duration at the first save and editing polls uses a different protocol.

## Fresh form check before sending

"Create poll" never posts the form loaded when the page opened. It first GETs a fresh special=1 form of the same forum and account and validates it completely (permission, served UID, schema, token). The POST then uses the fresh form's token, post time and passthrough fields, which may legitimately change. The confirmed poll is re-validated against the fresh form; if its limits, flags, types, other options, plugin fields, read permission or editor mode would change or invalidate that exact poll, nothing is sent: the page returns to the editor with the input kept, the fields in question highlighted and a notice to review again or use the browser. Denied, unsupported, guest and network failures of this check also send nothing and say so ("Nothing was sent"); reviewing again retries the check safely. Going back during the check cancels it.

This preflight stage is distinct from sending: an interruption during the check is never reported as a possibly sent request. Selected additional checkboxes retain the user's checked state during validation, including options that were initially unchecked on the website form.

The editor and confirmation use separate scrolling state, so entering the confirmation starts at its heading even on a narrow phone after scrolling to the end of a long form. Both mode-switch callbacks synchronously validate the original account session before carrying any text, including the interval before an account-change stream event arrives.

## Session lifetime

The session ends synchronously when the page's route leaves the navigator (pop, replacement such as the mode switch or "open thread", programmatic removal) — at the pop itself, not when the exit animation finishes — and when the cubit closes. A route-active predicate is checked before every operation and again immediately before the POST, so callbacks captured earlier (e.g. a confirm tap during the reverse animation) and pending checks cannot post. A request already sent is never cancelled or treated as unsent. Account changes still erase private input during the exit animation.

## Submission and result

One `postForm(singleAttempt: true)`, guarded by a busy marker, the route/session state and the account/operation generation. Double taps, a stale form load or a result arriving after an account change cannot post or show anything. An account change (A→B→A included) permanently ends the session and clears input. If it happens while a dispatched POST has no known result, the warning that the earlier result is unknown is sticky for the session: later account events (e.g. switching back to A) keep it, without keeping any poll content.

- `published`: the new thread, fetched as its author, has a normal header without status label.
- `moderated`: an `alert_right` message mentioning moderation, or the header's moderating label (`审核中`/`審核中`/`Under Review`, upstream defaults; unknown labels are not proof).
- `rejected`: only an explicit `alert_error` message (upstream `showmessage` uses it for returnable failures); input kept, plain text shown, sending allowed again.
- `unconfirmed`: transport error, non-200, redirect or message link without verification, `alert_info`, classless or unknown message classes (upstream uses `alert_info` for forwards whose message is not `*_succeed` and for notes), draft/ignored/hidden/unknown header, verification page of another account. A same-site thread link in such a message is only verified with a GET, never by posting again. Input is kept, but sending is blocked until the user chooses "I checked it was not created"; the page links to the forum (app and browser) and the thread when its id is known.

A redirect, a new TID, `alert_right` or an owner-visible post list alone never counts as published: the author can read their own pending, ignored, hidden and draft threads. Status parsing is limited to the subject header, never post text. The canonical link may be rewritten (`thread-<tid>-1-1.html`, upstream `viewthread.php`) and is checked with the same same-site thread-URL validation as redirects. In the status line after the subject, only the copy-link anchor back to the same thread is ignored; any other text, including anchor text, is a status label, and the author's `hiderecover` link (thread hidden below the report threshold) is never visible.

## Verification

Synthetic fixtures only: parser (observed form, dynamic limit, comment/string/regex-safe `maxoptions` scanning, neutral/non-neutral plugin fields, flags, required/disabled/read-only controls, foreign action/FID/special, CAPTCHA, missing bulk entry, denial, forum entry detection, ordinary guards), validation and payload (CJK/emoji/escaped subject boundaries, choice guard with entities, 0/00/padded expiry, optional types, unavailable flags/options), repository outcomes (`alert_error`/`alert_info`/classless messages, rewritten canonical, hidden marker), fresh form check (refreshed token, reduced limit, removed flag, failure and retry, cancellation, route exit, A→B→A while pending), cubit races, route lifetime and widget flows including a 360×800 phone with 1.3 text scale and the mode switch via a router. No live poll was created or published; the live Chinese wording of the moderation message and header label, and the live option column size, are not verified.
