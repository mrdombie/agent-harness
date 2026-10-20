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

## Before the picture goes anywhere

```bash
python3 -I "$KIT_ROOT/scripts/picture-evidence.py" lint <picture.html>
```

It refuses a picture with no regions, a missing phone or laptop frame, or a
real-data case neither drawn nor excused. Then the `design-critic` agent runs in
**picture mode**, which grades the same things by eye (its `REAL DATA:` line), and
only a picture that comes back `KIT: MATCH` with `REAL DATA: COVERED` is sent.
