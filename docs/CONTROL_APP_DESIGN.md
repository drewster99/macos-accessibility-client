# control_app Design — Name-First App Driving

**Status:** Implemented (v1.1) — tree persistence, incremental expand, parent-climb recovery,
settling mutating verbs; verified on live AX
**Date:** 2026-06-25
**Scope:** A high-level entry point that resolves an app by name/bundle/pid/window-title,
selects a window, and returns a compact, enriched, ref-bearing hierarchy the model can
drive — plus the verbs to drive it (`action`, `change_text`, `change_value`, `expand`,
`refresh`). Builds on the addressing model (§4) and serialization (§9) of
[MCP_DESIGN.md](./MCP_DESIGN.md).

---

## 1. Motivation

Every existing AX tool (`ui_snapshot`, `find`, `perform_action`, …) requires a **pid**.
But the model almost always knows the *name* ("Safari"), not the pid. Today that forces a
`list_apps` round-trip purely to translate a name the model already has into an opaque
integer, then thread that integer through every call.

`control_app` collapses "I know the app, give me something I can drive" into one call:
**name → resolution → window selection → enriched hierarchy with refs.** The model then
acts via small verbs that take a `ref`.

`ui_snapshot` is **left as-is** — its fate is decided later. `control_app` is additive.

---

## 2. Tool surface

| Tool | Signature | Purpose |
|------|-----------|---------|
| `control_app` | `(identity: String, window: String? = nil, timeout: Double = 10)` | Resolve app + window(s), return hierarchy |
| `action` | `(ref: String, action: String)` | Perform an AX action by name (semantic AXPress etc.; non-disruptive, works off-screen) |
| `click` | `(ref: String)` | Real synthetic click on the element — brings its app frontmost, clicks its activation point. Use when `action "press"` misbehaves (Catalyst) or for click-only targets |
| `change_text` | `(ref: String, value: String)` | Set `AXValue` as a **CFString** (semantic, non-disruptive; may skip per-keystroke handlers) |
| `type` | `(text: String, ref: String? = nil, via: "keys"\|"paste")` | Real keystrokes; with `ref`, brings app frontmost + focuses the field first. Fires validation/search-as-you-type |
| `change_value` | `(ref: String, value: Double)` | Set `AXValue` as a **CFNumber** (range-enforced) |
| `expand` | `(ref: String, timeout: Double = 5)` | Load `[N hidden]` descendants from `ref` (no re-read of loaded nodes) |
| `refresh` | `(ref: String, timeout: Double = 7)` | Discard + reload the subtree under `ref` |

**Default timeouts:** `control_app` 10s · `refresh` 7s · `expand` 5s · everything else 4s.

All verbs return `{ success, hierarchy }` (§6) rooted at the relevant node, **without** the
legend (that's `control_app`-only). `expand` is **incremental** (reuse loaded, fetch frontier);
`refresh` is a **full** re-read; the mutating verbs (`action`/`change_text`/`change_value`)
perform → settle → refresh one level up and return that (§12, §13).

`change_text` vs `change_value` are split deliberately: the tool name picks the CF type, so
there is no type-sniffing. (`AXUIElementSetAttributeValue` accepts any `CFTypeRef`; the
string-only behavior of today's `setValue` wrapper is just a wrapper limitation, not an API
one.)

> **Existing tools referenced below** (`reveal` = `AXScrollToVisible`, `element_detail`,
> `find`, `list_apps`) are pre-existing server tools from [MCP_DESIGN.md](./MCP_DESIGN.md) §8,
> not new to this design. `control_app` composes with them.

---

## 3. Identity resolution

`identity` is resolved as an ordered **cascade** — first matcher to hit wins. The only
special-casing is the all-digits→pid test in step 1; everything after is just "try each
matcher in order," no heuristic type detection:

1. **All-digits** → treat as `pid`; find the running app with that pid.
2. **Bundle id** → exact match, then case-insensitive.
3. **App name** (`localizedName`) → exact match, then case-insensitive.
4. **Window-title fallback** → any running app owning a window whose title contains
   `identity` (**case-insensitive substring**).
5. No match → `{ "success": false, "error": "no_match" }`.

Rules:
- **Resolution searches all running apps regardless of activation policy** (not just
  `.regular`), so menu-bar/agent apps are reachable. `list_apps` keeps its `.regular`
  *display* filter — that's a display concern, not a resolution one.
- **Running apps only (v1).** AX needs a live pid. Auto-launch-if-installed is a future
  option, explicitly out of scope now.
- **Ambiguity is its own outcome.** If step 3 or 4 matches more than one app, return
  `{ "success": false, "error": "ambiguous", "candidates": [ … ] }` so the model can re-call
  with a pid. pid and bundle id cannot be ambiguous.
- **All-digit app names are unreachable by name.** An app literally named `"1234"` is captured
  as a pid by step 1; use its bundle id or pid.
- **Matching is intentionally asymmetric.** The title fallback (step 4) is case-insensitive
  *substring* (forgiving discovery); the explicit `window` arg (§4) is case-sensitive *exact*
  (precise selection). This can surprise callers — it's deliberate, not an oversight.

```json
{ "success": false, "error": "ambiguous",
  "candidates": [ { "pid": 1234, "name": "Safari", "bundleId": "com.apple.Safari",
                    "windowTitles": ["MCP Inspector", "Displays"] } ] }
```

---

## 4. Window selection

- **`window` provided & non-empty** → **case-sensitive exact** title match selects that
  window. Not found → `{ "success": false, "error": "window_not_found" }`.
- **`window` omitted** → **all windows**, in the order `AXWindows` returns them (native
  order — front-to-back z-order on a best-effort basis, *not* a documented AX guarantee).

**Root shape.** The returned hierarchy is always rooted at the **`AXApplication`** node. When
`window` selects a single window, only that window appears as the app's child (others
omitted). `expand`/`refresh` instead root the returned hierarchy at the **given `ref`'s
subtree** — which may be any node, not necessarily the app or a window.

---

## 5. Coverage & budget

"All windows, full depth" is **budget-bounded** by `timeout`. The walk is **global
breadth-first across the entire app** (all windows at once), deepening level by level:
every window gets its chrome/toolbars/tabs before *any* window's deep content is walked.
Whatever is not reached when the timer fires renders as `[N hidden]` and is loadable via
`expand`/`refresh`. This prevents one window's web content (or a giant table) from starving
the others.

`[N hidden]` / `[more hidden]` always mean **"not loaded yet within the budget,"** never
"discarded":
- **`[N hidden]`** — exact count known (the common case; see *How the count is determined*).
- **`[more hidden]`** — unloaded children exist but the count is unknowable (count read
  errored/timed out, or a virtualized collection exposes no count attribute).
- **(no marker)** — reliably zero remaining.

**How the count is determined.** For ordinary containers, reading `AXChildren` returns child
*references* (not subtrees), so `.count` is one cheap read. For collections,
`AXRowCount`/`AXColumnCount` give the true total even when rows are virtualized. A marker is
emitted only when the registry flags the node as an **unexpanded frontier** (§12) or a
collection whose total exceeds the rendered rows. The count is **unknowable** — yielding
`[more hidden]` — only when that count read errors/times out, or a virtualized collection
exposes neither a count attribute nor an enumerable rows/children array. The detection rule is
simply *"did the count read succeed?"*

---

## 6. Response envelope

Every control verb returns **`{ success, hierarchy }`** — a success/fail flag followed by an
updated **partial** (budget-bounded) hierarchy. `hierarchy` is a text outline (one element per
line, §7) embedded as a string — far more token-efficient than nested JSON, and it carries the
refs the model passes back.

**`control_app`** (the entry point — adds app metadata; legend prefixes the outline here only):
```json
{ "success": true, "pid": 81194, "bundleId": "com.apple.Safari", "name": "Safari",
  "hierarchy": "// HIERARCHY …\ne1 application \"Safari\" …" }
```

**`expand` / `refresh`** (rooted at the ref; **no legend**; `resolvedFrom` appears when a stale
ref was recovered by climbing to a live ancestor, §12):
```json
{ "success": true, "ref": "e9", "hierarchy": "e9 group …", "resolvedFrom": "e6" }
```

**`action` / `change_text` / `change_value`** (mutate → settle → refresh one level up): `success`
mirrors the mutation's own `ok`; `hierarchy` is the settled post-action view from the parent
(omitted only if the parent vanished *because* the action worked — still `success:true`):
```json
{ "success": true, "ok": true, "ref": "e14", "value": 0.5, "hierarchy": "e6 group …" }
```

- **On failure:** `success:false` with `error`; `candidates` only for `"ambiguous"`; `hierarchy`
  omitted.
- The legend (§7) is sent **only on `control_app`** — follow-up responses are bare partials.

---

## 7. Hierarchy format

A **legend header** prefixes the outline once (not per-node):

```
// HIERARCHY — one element per line, indented by tree depth:
//   <ref> type "label" #id ="value" [min–max] (valueDescription) url="…" placeholder="text" {states} - actions [N hidden]
// Only the parts that apply are shown. <ref> (e.g. e10) is the handle for every call —
// pass it whole, INCLUDING the leading letter.
//   "label"       AXTitle, else AXDescription, else AXHelp
//   #id           AXIdentifier (developer-assigned name; stable when present)
//   ="value"      current AXValue (text or number); range controls append [min–max]
//   (description) AXValueDescription — human gloss of the value, e.g. (72%), (Large)
//   url="…"       AXURL destination (links etc.), truncated
//   placeholder=  AXPlaceholderValue (shown even when a value is present)
//   {states}      every TRUE boolean attribute, AX-stripped (AXEnabled inverted -> {disabled})
//   - actions     performable actions, AX-stripped: press, menu, inc, dec, raise, …
//   [N hidden]    N children not loaded yet ([more hidden] if the count is unknown) — call expand/refresh
//
// DRIVE IT:
//   action("e14", "press")               perform an action
//   change_text("e10", "My cool Mac")    set a text value
//   change_value("e14", 0.5)             set a numeric value (slider/scrollbar; 0–1 or min–max)
//   expand("e2", timeout: 2.0)           load [N hidden] descendants (breadth-first) until done/timeout
//   refresh("e2", timeout: 2.0)          discard + reload the subtree until done/timeout
// expand/refresh return THIS SAME hierarchy, rooted at the given ref.
//
// e1 application "Safari" {frontmost}
//   e2 window "Displays" {focused,main} - raise [2 hidden]
//     e10 textField "Name" #computerName ="Andrew's Mac" placeholder="Enter a name" {focused} - confirm
//     e14 slider "Brightness" =0.72 [0–1] (72%) - inc,dec
//     e18 comboBox "Resolution" ="1512 × 982" - menu,press [5 hidden]
```

### Line grammar

```
<ref> type "label" #id ="value" [min–max] (valueDescription) url="…" placeholder="text" {states} - actions [N hidden]
```

Each segment is optional and appears only when present:

- **`<ref>`** — session handle (e.g. `e10`), the letter is part of it. The root node is the
  **`AXApplication`** element.
- **`type`** — humanized **subrole-or-role**. A small **alias map wins first**; otherwise
  subrole-preferred, `AX` stripped, first char lowercased. Starter alias map (easily extended):
  `AXStandardWindow→window`, `AXTabButton→tab`, `AXOpaqueProviderList→tablist`. Non-aliased
  roles stay literal: `AXCloseButton→closeButton`, `AXMinimizeButton→minimizeButton`,
  `AXButton→button`.
- **`"label"`** — first non-empty of `AXTitle` → `AXDescription` → `AXHelp`.
- **`#id`** — `AXIdentifier` when present.
- **`="value"`** — current `AXValue` (string or number), truncated ~500 chars like the
  inspector. Range controls append **`[min–max]`** from `AXMinValue`/`AXMaxValue` (omitted
  when neither bound exists).
- **`(valueDescription)`** — `AXValueDescription`, the human gloss, when present.
- **`url="…"`** — `AXURL` destination (links and any element exposing it), truncated (§10).
- **`placeholder="…"`** — `AXPlaceholderValue`, shown **even when a value is present** (it
  names the field's purpose).
- **`{states}`** — see §8.
- **`- actions`** — see §9.
- **`[N hidden]` / `[more hidden]`** — not-yet-loaded children, counted or (when uncountable)
  not (§5).

### Ordering

**Sibling order is preserved exactly as `AXChildren` returns it.** We do **not** reorder
controls ahead of containers — that would destroy visual/tab/reading order, and v1 alters
nothing structural (§11). The only ordering rule is per-node: an element's own metadata
(`type`/label/value/states/actions) prints on its line *before* its indented children, which
is inherent to an outline, not a reordering.

---

## 8. States — generic booleans

States are rendered by **enumerating every boolean attribute on every node** and showing
those that are **true**, with `AX` stripped and first char lowercased: `{focused,main,modal}`,
`{frontmost,enhancedUserInterface}`, etc. No curated list — whatever booleans the element
exposes.

- **Show-when-true only.** A false boolean is omitted (no `{enabled}` noise on every line).
- **`AXEnabled` is the one inversion:** hidden when true, rendered as **`{disabled}`** when
  false. Disabled controls are **shown, not hidden** — a disabled control is information, and
  it will naturally have an empty action list.
- **`AXDisclosing` is the one boolean exception:** it does **not** render as `{disclosing}`;
  instead it drives the `disclose`/`collapse` capability on outline rows (§10).
- The **`AXApplication` root** is where app-level booleans live (`AXFrontmost`,
  `AXEnhancedUserInterface`, `AXIsScribbleActive`, `AXHidden`).

> Performance note: enumerating all attributes per node is more AX round-trips than reading a
> fixed set. We accept this for v1 to keep the rule simple and complete; revisit only if it
> measurably hurts.

---

## 9. Actions

Performable actions from `AXUIElementCopyActionNames`, normalized:

- **Standard `AX*` → short verbs** (reversible — `AX` re-prefixed on perform; input accepts
  either form): `AXPress`→`press`, `AXShowMenu`→`menu`, `AXPick`→`pick`,
  `AXIncrement`→`inc`, `AXDecrement`→`dec`, `AXConfirm`→`confirm`, `AXCancel`→`cancel`,
  `AXRaise`→`raise`, `AXZoomWindow`→`zoom`.
- **Custom/app-defined actions** (e.g. `close tab`) — the **outline shows a display-safe
  label**: `cleanActionName(original)` collapsed to one line and truncated (~40 chars). The
  **raw original string is retained in `ElementRegistry`** per ref, because
  `AXUIElementPerformAction` requires the *exact* string `AXUIElementCopyActionNames` returned
  — which for some apps is a multi-line blob (`Name:…\nTarget:…\nSelector:…`) that must never
  reach the line-based outline.
- **Synthetic capabilities** (not AX actions; mapped to attribute writes): `disclose` /
  `collapse` toggle `AXDisclosing`. `change_text` / `change_value` are separate tools, not in
  the action list.

**Action resolution.** `action(ref, x)` matches `x` against that ref's retained raw action
list, accepting the short verb (`press`), the full AX name (`AXPress`), the cleaned/truncated
label (`Move next`), or the exact raw original — then performs the **raw original** string.
Collisions (two actions cleaning to one label — rare) resolve to the first; pass the exact raw
string to disambiguate. No match → error listing the ref's valid actions.

> Normalization is renaming, not hiding. **No actions are dropped in v1** (`scrollToVisible`,
> the `Move previous/next/Remove from toolbar` toolbar-customization actions, etc. all stay
> visible). A noise-filter pass is a later, opt-in refinement (§12).

---

## 10. Role-specific rendering

- **Range controls** (`AXSlider`, `AXScrollBar`, `AXProgressIndicator`, `AXLevelIndicator`,
  steppers): render `=value [min–max] (description)` on the control itself; driven by
  `change_value` **only when `AXValue` is settable and numeric** (guard via
  `AXUIElementIsAttributeSettable`). Read-only controls like `AXProgressIndicator` expose no
  settable value; steppers/incrementors may instead offer `inc`/`dec` actions rather than a
  settable value. The `AXValueIndicator` child (the thumb/knob — it only mirrors the parent's
  value) is **not v1 behavior to drop** (see §11) but conceptually belongs to its parent.
  Scrollbars use `AXValue` 0–1 with no explicit min/max. **No reliable page-forward/back AX
  action exists** — scroll via `change_value` (jump to proportion) or `reveal`.
- **Text fields** (`AXTextField`): `="value"` when present; `placeholder="…"` always shown
  when present; the role implies settable, drive with `change_text`.
- **Combo boxes** (`AXComboBox`): `="value"`; open via `action(ref,"press"/"menu")`; option
  rows usually don't exist in the tree until opened — and they often appear in a **transient
  menu/window *outside* the combo box's subtree**, so after opening, `refresh` the **window
  (or app)**, not the combo `ref`. Set via `change_text` if editable, else open +
  `action(optionRef,"press")`.
- **Links** (`AXLink`): label + `url="…"` (from `AXURL`, truncated; shown for any element
  exposing `AXURL`) + `press`. (Web pages contain many; volume is bounded by the budget.)
- **Collection containers** (`AXTable`, `AXOutline`, `AXGrid`, `AXList`, layout/collection
  areas): show **shape/counts** (`[R rows × C cols]` / `[N items]`, header via
  `AXColumnTitles` once on the container line) + render the **union (deduped)** of
  `AXVisibleRows`/`AXVisibleCells` and `AXSelectedRows`/`AXSelectedCells` (selected rows are
  often also visible — never render them twice). The remainder is `[N hidden]` where the total
  comes from `AXRowCount`/`AXColumnCount`, or `[more hidden]` when no count attribute exists
  (§5). Cell index ranges (`AXRowIndexRange`/`AXColumnIndexRange`) live in `element_detail`,
  not the outline.
- **Outline** (`AXOutline`) additionally: rows are flat AX siblings, so **indent each row by
  `AXDisclosureLevel`** to reproduce the visual tree; expose **`disclose`** (collapsed,
  expandable) / **`collapse`** (expanded); render only visible + selected rows, rest
  `[N hidden]`. `disclose`/`collapse` toggle `AXDisclosing` **when it's settable**; otherwise
  press the row's disclosure-triangle child; if neither is available, the capability isn't
  offered.

---

## 11. v1 conservative stance — hide nothing structural

To validate correctness before optimizing for brevity, v1 **renders the entire loaded tree**:

- **No flatten** — every container line stays, full nesting preserved (Electron/web will show
  `group > group > group` chains; accepted cost).
- **No decorative-drop** — unlabeled spacer images and wrapper groups are shown.
- **No action-dropping** — all actions visible (only renamed, §9).

What stays because it is deferral or formatting, not structural omission:
- **`[N hidden]` / `[more hidden]`** — budget deferral (§5), not omission; loadable via
  `expand`/`refresh` (virtualized offscreen rows may need `reveal`/scroll first).
- **Action-name normalization** (§9) and the additive `=value`/`{states}`/`#id`/etc. rendering.
- **Collection containers** showing visible + selected with the rest `[N hidden]` — same
  budget/deferral mechanism, `expand` pulls the rest.

Brevity optimizations (flatten transparent wrappers, drop decorative leaves, action
noise-filter) become a later, opt-in pass once the full output is proven out (§12).

---

## 12. Refs, identity, persistence, and recovery

**Ref identity is persisted for the whole host lifetime** in `ElementRegistry`, keyed by
`CFEqual` on the live `AXUIElement`. The same element always maps to the same ref across every
call, and the ref allocator is a monotonic counter, so a ref is minted once and **never reused
or repointed** — `e5` is always the same element. New elements get fresh numbers; a re-walk
re-encounters known elements and returns their existing refs.

**The tree is persisted per pid** (`controlTrees[pid]`), with a child→parent ref map. This one
structure powers three things:
- **Incremental `expand`** — reuse already-loaded nodes verbatim, recurse to the
  `[N hidden]`/`[more hidden]` frontier, load only those from live AX (budget-bounded), splice
  back in. Loaded nodes can be stale by design; that's what `refresh` is for.
- **Full `refresh`** — discard + re-read the subtree authoritatively, splice back in.
- **Parent-climb stale recovery** — a dead `AXUIElement` can't report its own parent, so a
  stale ref is recovered by reading the **persisted parent links**: climb to the nearest live
  ancestor, re-walk from there, return that partial hierarchy with `resolvedFrom` naming the
  ref it resolved at. Climbs stop at the app root (always alive while the app runs). This
  **replaces** locator-based recovery for control refs — it never silently repoints `e5`, only
  surfaces a live ancestor's current view (or a loud `stale_ref` if the whole branch is gone).

**Multi-app is free.** Refs are globally unique and each records its pid, so the model can drive
two apps back-to-back with no collisions; each app keeps its own tree side-by-side. Re-entering
`control_app` on one app leaves the other untouched.

**Eviction is by liveness, never by the clock.** A 1-hour-old ref to a live window is valid; a
1-second-old ref to a closed dialog is dead — only liveness distinguishes them, checked lazily
at use-time. Trees/handles are evicted when the **app terminates** (`evictDeadApps`, a
`kill(pid,0)` sweep run at each `control_app`) or under size pressure (the dead-handle prune).
Nothing is force-refreshed or TTL-evicted.

**Rename (done):** `AXSession` → **`ElementRegistry`** (`AX*` read as an Apple type and it's a
ref registry, not a "session"). `AXElement` keeps its name — it genuinely wraps `AXUIElement`.

---

## 13. set_value internals & enforcement

- `change_text` → `AXUIElementSetAttributeValue(el, kAXValueAttribute, str as CFString)`.
- `change_value` → same call with a **`CFNumber`**. Reads `AXMinValue`/`AXMaxValue` and
  **rejects out-of-range** input (no silent clamp):
  ```json
  { "success": false, "error": "out_of_range", "given": 1.4, "min": 0, "max": 1 }
  ```
  It rejects, with **distinct errors**, when: out of range (`out_of_range`); `AXValue` not
  settable (`not_settable`); current value isn't numeric / attribute unsupported
  (`not_numeric`); the AX write returns an error or times out (`write_failed`); or the ref is
  stale (`stale_ref`, §4). Settability is guarded via `AXUIElementIsAttributeSettable`.

---

## 14. Error responses (summary)

| Condition | Shape |
|-----------|-------|
| No Accessibility grant | existing `accessibility_not_granted` (with `howToFix`/`deepLink`) |
| Identity matched nothing | `{ success:false, error:"no_match" }` |
| Identity matched >1 app | `{ success:false, error:"ambiguous", candidates:[…] }` |
| `window` not found | `{ success:false, error:"window_not_found" }` |
| `change_value` rejected | one of `out_of_range` (with `given`/`min`/`max`), `not_settable`, `not_numeric`, `write_failed` |
| Stale `ref` (no live ancestor) | `{ success:false, error:"stale_ref" }` — otherwise recovered by parent-climb with `resolvedFrom` (§12) |
| `action` with unknown action | `{ success:false, error:"no_such_action", valid:[…] }` |

---

## 15. Non-goals / deferred

Deferred items are tracked in [ROADMAP.md](./ROADMAP.md).

- **`control_focused()`** zero-arg entry — **not** doing it (system-wide focus query stays in
  `focused_element`/`element_at`).
- **Auto-launch** of non-running apps.
- **Flatten / decorative-drop / action noise-filter** — deferred to a post-validation pass.
- **`AXValueIndicator` dropping** and other brevity heuristics — deferred (see §11).
- **`replace_range`** (parameterized `AXReplaceRangeWithText`) text editing — a future tool;
  `change_text` covers whole-field set for v1.
- **Large / per-app semantic role relabeling** — not in v1. (A *small* starter alias map for a
  few high-traffic roles ships in v1; see §7.)
- **`ui_snapshot`** disposition — decided later; left untouched.

---

## 16. Build order

1. Rename `AXSession` → `ElementRegistry`.
2. Resolver (identity cascade → window selection → ambiguity result → JSON envelope).
3. Generic-bool node renderer + legend header (§7–§10).
4. Verbs: `action`, `change_text`, `change_value`, `expand`, `refresh`.
