# Website blacklist (#126) — design

## Scope

A third, separate blocking list on the blocking page: the forum's own blacklist, served by the `blockuser` plugin at
`home.php?mod=spacecp&ac=plugin&id=blockuser:spacecp` (linked from the forum settings). It is **not** the Discuz friend
blacklist and **not** the notice ignore rules (`filter_note`); both existing features and the local block list are
unchanged. No speculative plugin features: list, lookup, add, remove, and explicit import into the local list.

## Files

| Part | File |
|---|---|
| Models, typed-target parser | `lib/features/blocking/models/website_blocklist.dart` |
| Page parser (`parseWebsiteBlocklistDocument`) + repository | `lib/features/blocking/repository/website_blocklist_repository.dart` |
| State (account + generation) | `lib/features/blocking/cubit/website_blocklist_cubit.dart` |
| Page | `lib/features/blocking/view/website_blocklist_page.dart` (route `/websiteBlocklist`) |
| Entry | `user_block_page.dart`, between the local list and the notice rules |
| Shared guard | `forumPageProblem()` in `notice_ignore_repository.dart` (public wrapper of `checkForumPage`) |

## Observed page structure (read-only inspection, 2026-09-27)

Structure and field names were seen in the authenticated page without any add or remove. The browser DOM showed no
hidden field **values**, so tokens and flag values are never assumed: they are read from the served form and sent as
served. Test fixtures use this structure with made-up values (`test/regression/fixtures/website_blocklist_fixtures.dart`).

| Part | Structure |
|---|---|
| Container | `div#bu_page.bu-page` |
| Quota | `div#bu_quota.bu-quota`, text like `已屏蔽 1／10 人` (full width slash; limit read from the page) |
| Lookup form | `form#bu_qform` GET, action `home.php`, hidden `mod` / `ac` / `id`, optional hidden `mobile=no`, `input#bu_q[name=bu_q]`, unnamed submit |
| Lookup result | `div#bu_confirm` > `div.bu-member` > `span.bu-name > b#bu_confirmname` (name) and `span.bu-uid` (`UID n`) |
| Add form | `form#bu_addform` POST to the plugin page, optionally with `mobile=no` in its action: hidden `formhash`, `blockuseradd`, `buid`; unnamed submit |
| List | `table#bu_list.bu-list`, `thead` (會員 / 加入時間 / 操作), `tbody > tr#bu_row_n` |
| Empty list | No table; `h3#bu_listtitle` immediately followed by `p#bu_empty.bu-empty` containing `名單是空的。`, with zero used quota |
| Row | 1st cell `span.bu-name > a[href=home.php?mod=space&uid=n]` and `span.bu-uid`; 2nd date; 3rd `form.bu-delform` |
| Remove form | `form.bu-delform` POST to the plugin page, optionally with `mobile=no` in its action: hidden `formhash`, `blockuserdel`, `buid`; unnamed submit |

## Protocol handling (fail closed)

* **Reads**: GET the plugin page (list) and the same page with `&bu_q=<uid>` (lookup, read-only: it only opens the
  confirmation). Both must be a normal forum page of the expected account (`checkForumPage` with identity), complete
  (`</html>`), with exactly one `#bu_page` holding `table#bu_list` or the observed explicit empty-list marker.
  The empty variant must have one plain-text `p#bu_empty.bu-empty` immediately after `h3#bu_listtitle`, zero used
  quota, and no table, list rows, remove forms or pagination. Missing or contradictory evidence is an error, never
  an empty list. A `#bu_qform` present must be the observed GET form: routing only in its hidden fields, each once
  (a GET form replaces the action's query, so routing in the action as well is refused). The desktop variant may
  additionally contain exactly one hidden `mobile=no`; another value, duplicate or unknown hidden field is refused.
* **Rows**: only `tbody > tr` of `table#bu_list`, each with three cells where the row id `bu_row_n`, the profile link
  and the `UID n` label name the same uid (strict decimal, 1 to 2^31-1; a repeated query parameter is refused). Any
  other row, a row linking another user, the account itself or a uid twice rejects the page.
* **Quota and completeness**: the quota is the single `n／m` (or `n/m`) pair in `#bu_quota`; nothing is hard-coded.
  A list is **complete** only when the page prints a count equal to its rows and has no pagination; without a count
  it is incomplete. Only a complete list is called empty, gives a total, can be imported from and proves absence.
* **Forms**: only the observed shape is used — POST to exactly `home.php?mod=spacecp&ac=plugin&id=blockuser:spacecp`
  (same origin, default port, no user info, exactly these three parameters once and optionally one `mobile=no`), hidden `formhash`, the flag of the
  form (`blockuseradd` in `#bu_addform` inside `#bu_confirm`, `blockuserdel` in the row's `form.bu-delform`) and
  `buid`, each once and not blank, and one unnamed submit button. The other flag, another field, a named or second
  button, a disabled field or a target in the action make the form unusable (the row stays listed without remove; the
  lookup offers no add). A remove form's `buid` must be its row's uid; the add form's `buid` and the confirmation's
  `UID n` must be the uid asked for, otherwise the lookup is a target mismatch. Unobserved variants (bulk delete,
  checkboxes, operation words) are not supported. After validating a desktop action, its optional layout flag is
  removed from the URL because the network client appends `mobile=no` itself; the request contains it only once.
* **Writes**: add = fresh lookup GET of exactly the chosen uid (name must still match the confirmed one) → one
  `postForm(singleAttempt: true)`; remove = fresh list GET → the row's form → one POST. The caller's validity check
  (account + generation) runs before the fresh read and again right before the POST: a confirmation that expired
  meanwhile — also A → B → A — sends nothing. The list is always read again afterwards — also after a lost answer or
  a redirect — and only it decides: add is confirmed by presence, remove by absence in a complete list. A forum refusal
  (e.g. list full) is shown with the forum's text; refused-but-changed or unverifiable results are "sent, please
  reload". Nothing is ever retried.
* **Logs** contain failure kinds and counts only: no HTML, tokens or names.

## State and races

`WebsiteBlocklistCubit` is created per page and holds `owner` + `generation`. The uid named by each
`AuthStatusAuthed` / `AuthStatusNotAuthed` event (not the current user at delivery time) starts a new generation
when it differs from the owner, clearing rows, lookup, typed input and names; the same account's refresh and the
replayed status change nothing, and A → B → A is two changes. Confirmations capture the generation before the dialog;
answers are dropped unless generation, owner and current account still match. `writing` is set before the first
await (duplicate taps return `busy`); a write never starts while the list is read, and no read or lookup starts
during a write, so an older page never replaces the list read after a change. Lookups carry a sequence number: only
the latest is shown, and a write, an input edit or refused input drop the result and any pending answer.

On an account change the page immediately removes its own confirmation (without displaying the target through an
exit animation) and clears its own scoped messenger; other routes and pages' messages are left alone. The scrollable
confirmation remains usable at large text sizes. A write whose account changed after it was sent reports "may have been sent, result not
checked — switch back and reload" rather than "nothing was sent"; one cancelled before sending says nothing was sent.

## Import

Per row, explicit tap, through the app-wide `UserBlockCubit.block(expectedOwner:)` — the same serialized repository
that keeps unrelated and unreadable entries. Only from a complete website list of the current generation while the
local list of the same owner is known (`ready`); failed/unknown local state is never treated as empty. Labels: "Also
blocked on this device" / "Website only", plus a count of local-only users (shown only for a complete list). Nothing
is uploaded or removed on either side. No batch import (so no partial-batch state). The imported row (uid presence
and name) is taken from the list current at import time, not from the row tapped before a reload.

## Limitations

* Structure and field names follow the read-only observation above; hidden values (token, flag values, `buid`) were
  not visible there, so the tests use synthetic values and only prove that served values are preserved.
* No live add/remove was performed: the POST round trip, the forum's answer to it and its "not found" lookup page
  were not observed. The empty-list page and its successful UID lookup were verified read-only with an authorized
  test account. Unobserved empty or error layouts remain unsupported with the website fallback.

## Desktop query form correction (2026-09-27)

The Android preview could reject the initial list before attempting a member lookup, logging `lookup form not
understood`. Inspection of the forum's actual network response confirmed that its GET form includes the additional
hidden field `mobile=no`, matching the layout requested by the app's network client. The original parser required
exactly the three routing fields and therefore rejected this valid desktop form. This was not evidence that the
queried member did not exist. Further read-only inspection confirmed that the add and remove forms also carry
`mobile=no` in their action URLs; rejecting every extra action parameter made those forms unavailable as well.

The parser now permits this one optional GET hidden field and one optional POST action parameter, each with exactly
the observed value. The GET action must still be bare `home.php`, and POST routing, hidden fields, tokens and target
binding retain their checks. Synthetic parser tests cover list and lookup with the desktop forms and reject
unsupported values, duplicates, unknown parameters and foreign actions. Transport tests verify reads do not send
any POST and that adding or removing through a fake adapter sends once, retains the served body, sends only one
layout parameter and reloads the list once for confirmation. No real add/remove was performed for this correction.

## Empty-list and landscape correction (2026-09-27)

Preview build 101 still failed with `list table not found` for accounts with no blocked users. Read-only inspection
confirmed that the plugin omits `table#bu_list` and instead serves the explicit empty marker documented above,
including on a successful UID lookup page. The production parser now accepts that verified shape with a matching
zero quota while retaining all identity, target and form checks. Both full live HTML responses passed local parser
verification; private HTML and tokens are not committed. Synthetic regressions reject missing, duplicate, misplaced
or contradictory markers and exercise lookup, first addition and last removal with an in-memory server, including
single-submit behavior. No live blacklist was changed.

Website blacklist, local blocking, activities and my titles each apply SafeArea to their own body. Existing bottom
padding is retained on the blocking pages; the shared padding helper is unchanged. Landscape widget tests exercise
nonzero left/right insets and bottom padding. Android device retesting is still required.
