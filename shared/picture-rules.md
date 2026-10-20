# A picture of the target: what it must draw, and how it says so

The picture the owner approves binds the build: it is committed as the project's
approved picture (`.design/<surface>-mock.html` by default), the build is held to it
in parity mode, and **the evidence the pull request owes is read off it**. So a
picture carries two things a machine reads, and the drawer writes both.

## 1. Every frame is a named evidence region

Mark each frame the picture draws — each state, each width, each theme — with:

```html
<section data-evidence-shot="voices-menu-phone-dark"
         data-evidence-route="/settings/voices"
         data-evidence-viewport="phone"
         data-evidence-theme="dark"
         data-evidence-shows="the voice menu open over the grid"
         data-evidence-setup='press Meta+K ;; click the "Voice" menuitem'>
```

- `data-evidence-shot`: lower-case letters, digits and dashes; CI saves the shot as `<name>.png`.
- `data-evidence-viewport`: `laptop` (1440 wide) or `phone` (390 wide). A picture draws both.
- `data-evidence-theme`: `light` or `dark`, for every theme the picture draws.
- `data-evidence-setup`: the project's screen steps (`design.renderSteps`), `;;` between them,
  for a state that is not what the route loads in: a menu open, a tab chosen, a row expanded.

The ship step writes every region into the capture plan CI photographs, and lists
them under `## Required evidence`. The independent design critic
(`scripts/critic-judge.sh`) fails the pull request while any region has no pinned
shot. One builder listed the one region it built; the picture had four, and two
were never photographed.

## 2. It is drawn with real data

People meet a screen with real data, not a tidy still. The picture draws, and says
it draws, each of these:

| Case | What the picture shows |
|---|---|
| `duplicate-names` | two or more rows with the same display name, and how a person tells them apart |
| `longest-names` | the longest names and labels the data holds, wrapping or truncating as built |
| `empty` | the empty state, as its own frame |
| `scrolled` | the page scrolled to the bottom, on laptop and on phone |

Say so on any element: `data-real-data="duplicate-names longest-names empty scrolled"`.
A case the screen cannot have is excused with its reason:
`data-real-data-na="duplicate-names: this screen lists no people"`.
One picture used tidy unique names; the real data had five "Sam Member" rows that
nobody could tell apart.

## Pictures approved before these rules (2026-10-20)

An older approved picture carries no markers and was not drawn to the real-data
table. It is not failed for either:

- **Its regions are derived.** Each outermost frame or screen it draws becomes a
  region, named by its id, label, heading or caption, at laptop and phone and light
  and dark where it draws them; a picture with no frames falls back to the PR's
  `## Evidence routes` at laptop 1440 / phone 390 x light / dark. A derived region is
  covered by CI's shot of the same route, width and theme. The judge's status says
  which derivation it used (`regions marked`, `derived from frames (N)`, `derived
  from the PR routes (N)`).
- **Real data, and both widths, are owed from 2026-10-20.** The approval date is the
  picture's `data-picture-approved="YYYY-MM-DD"`, else the earliest of its first
  commit and the ticket's "Picture approved" comment. Earlier, or no date known:
  exempt. The critic still grades real data on the built screen.

To label one for good, without changing anything it renders (attributes only; it
prints the diff and checks the file minus the added attributes is the original):

```bash
python3 -I "$KIT_ROOT/scripts/picture-label.py" --route /the/route --approved 2026-10-14 .design/<surface>-mock.html
```

## The moment it is approved: publish it for any machine

The page a picture is drawn on opens only for the person who drew it, so a builder on another
machine cannot read the picture that binds its build. Whoever records the approval
publishes the file itself, in the same motion:

```bash
bash "$KIT_ROOT/scripts/picture-approve.sh" <ticket> <picture.html>
```

It puts the file in a secret gist and posts a ticket comment starting
**Picture for any machine** with the gist and raw URLs and the file's sha256. Run
again on the same file, it does nothing; a new version of the picture is published
again. A picture recorded as approved without that comment is not approved for any
machine but the one that drew it.

## Before the picture goes anywhere

```bash
python3 -I "$KIT_ROOT/scripts/picture-evidence.py" lint <picture.html>
```

It refuses a picture with no regions, a missing phone or laptop frame, or a
real-data case neither drawn nor excused. Then the `design-critic` agent runs in
**picture mode**, which grades the same things by eye (its `REAL DATA:` line), and
only a picture that comes back `KIT: MATCH` with `REAL DATA: COVERED` is sent.
