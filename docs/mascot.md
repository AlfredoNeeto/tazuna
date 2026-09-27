# Frenatus - the Tazuna mascot

The character bible. Every image of the mascot is drawn from this file, not from memory: the
sources live in `docs/assets/tazuna/src/`, `scripts/render-mascot.ps1` renders them, and the
self-test refuses a sprite that leaves the palette or a render that drifts from its source.

## Project interpretation

Tazuna (手綱, the reins) is the part of a harness the rider holds. The project is an engineering
harness for coding agents, Claude Code and Cursor alike: the model is the strength, and the
harness steers it before acting (guides) and checks it after acting (sensors). The mascot has to
say that without a caption and without belonging to any one agent: a strong animal, barded and
bridled, whose reins are held by someone outside the picture. It must be original, readable at
32 px on GitHub's light and dark themes, and drawn as dark, detailed gothic, baroque and
tenebrist pixel art in the spirit of Blasphemous - Spanish Holy Week, gilded altarpieces,
reliquaries - without copying any of its characters. The palette belongs to the mascot, not to a
vendor: no agent's colours and no agent's logo.

## Design objective

One character, one dominant silhouette, one metaphor: **strength steered by its harness, never
caged**. Noble, collected and calm; not a monster, not cute. It has to work as a 32 px avatar, a
64 px sprite, a README banner and a 1280x640 social preview, and every future drawing has to be
reproducible from this file.

## Concept 1

**Temple** - a Spanish fighting bull in a gilded processional harness, the verification seal set
in a medallion on its brow, the reins falling out of the frame. *Temple* is the bullfighter's art
of governing the charge without breaking it, and the temper of steel tested before it is
trusted. Rejected: with so many gold bands the long head reads as a helmet or a mask, the bull
survives only in its horns, and at 32 px the face narrows to nothing.

## Concept 2

**Auriga** (Latin, the charioteer) - a hooded processional guide whose vestments are built from
tack, braced against a taut rein that an unseen force pulls. Rejected: the chest clusters into
one knot of gold, the hands stay crude, the pull does not reach the body, and at 32 px the face
is a few pixels. A human figure also puts the harness on a person instead of on the strength it
steers.

## Concept 3

**Frenatus** (Latin, "the bridled one") - the head and neck of a black Andalusian war-horse in
gilded barding, the seal set in its chanfron, two straight reins leaving the frame. Reins belong
to a horse, so the metaphor needs no caption; the reins are the only straight lines in a drawing
of curves, and they survive at 32 px. Chosen by the owner on 2026-09-27 from the three concepts,
each drawn by its own designer.

## Recommended direction

Frenatus. It replaces Tameshi, the samurai drawn two days earlier: the armour said "tested" but
never "reins", it was built on one agent's colours, and the harness now serves more than one
agent.

A black Andalusian war-horse in profile, facing left, the head flexed at the poll: power held
in the hand, not in a cage. A fluted gold chanfron runs down the face; gilded lames ride the
crest; a crimson velvet caparison edged with twisted gold cord covers the chest. Behind the head
stands a resplendor, the ray-crowned halo of a Holy Week float. The bridle, the bit and two
straight, taut reins are the guides; the reins leave the frame on the right, towards a hand
that is never drawn, because that hand is the harness. The seal set in the chanfron is the
sensor: dark garnet glass at rest. Verification is drawn as shape, not colour: on pass the glass
opens into a star and the rays reach full length; on fail the glass cracks, the halo's ring
breaks, the rays shrink to stubs and the eye closes. The reins stay taut in every state: the
harness never lets go, the seal answers.

## Character bible

### Name

Frenatus (Latin, "bridled, held by the bit"), from *frenum*: the bit, the bridle, the rein, and a
check on something. Its Spanish heir *freno* still means both the horse's bit and a brake: the
harness steers before the turn and stops a turn that would end unverified. Said "fre-NA-tus".
Written in Latin letters everywhere; no text inside any sprite.

### Role

The face of Tazuna: the README banner, the footer sprite, the repository avatar and the social
preview. It stands for the model inside the harness: the horse is the strength, the bridle, the
barding and the reins are the harness, and the hand on the reins stays outside the picture,
whichever agent it belongs to.

### Concept

The model is the horse: black, heavy, powerful, trusted with a halo. The harness makes that
strength useful: guides before the turn (bridle, bit, reins) and a sensor after it (the seal on
the chanfron). The resplendor is the reliquary halo of a Holy Week float, and it answers to the
seal: trust follows the test.

### Personality

Calm, collected, proud, unhurried: a war-horse that has learned the bit. Powerful but never
wild; serene, never aggressive, frantic, goofy or childish.

### Visual identity

Gothic, baroque and tenebrist: a Spanish war-horse painted the way an Andalusian altarpiece is
lit. A black coat with a cool violet sheen, a fluted gilded chanfron and crest lames, a crimson
velvet caparison with a twisted gold cord, a resplendor of rays. One hard light from the upper
left; the right and the lower body sink into shadow, so more than half of the figure lives in it.
A crimson back light catches the shadow side: the ear, the plume, the jowl. Gilded ornament -
rivets, flutes, keepers, the sun embroidered on the velvet - is the only detail allowed to
glitter in the dark.

### Body proportions

A head-and-neck bust in profile, facing left, on the 64x64 grid, cropped by the right and bottom
edges. The resplendor is centred at column 28, row 18.5, its beaded ring between radius 15.3 and
17.6, its rays reaching the top and left edges. The head runs from the ear at the top to the
chin at row 57; the muzzle sits in columns 13-24 from row 41; the crest leaves the frame on the
right; the caparison fills the lower right.

### Head design

A fluted gold chanfron with a central embossed ridge, rivets and a brow boss; a gold brow guard
over the eye; one pricked ear; a small reliquary finial between the ear and the crest; a crimson
plume swept back; a crimson browband with gold studs; a madroño, the Andalusian tassel, at the
cheek.

### Eyes

One eye, in profile, under the gold brow guard: a dark almond with a bone catchlight at column 35,
row 19. After the seal it is the expression system's second instrument: open and calm at rest
and on pass, closed to a lash line on fail.

### Face

A black coat, not skin: lit planes in `#4b3f4e` and `#7d7082` beside the chanfron and on the jowl,
shadow in `#2f2530` and `#1c1419`. The muzzle carries a studded noseband (the cavesson, on row
44), a bit ring and a curb shank. No teeth, no foam, no flared nostril: the mouth is quiet.

### Harness design

Guides and one sensor, nothing more. The **guides**: bridle, browband, cheek strap, cavesson, bit
and two reins - leather `#6c4326` over `#3a2215` with gold keepers - running straight from the
bit out of the right edge, taut in every state. The **sensor**: the seal, a garnet disc in a
gold ring set in the chanfron, its glass at columns 22-24, rows 30-32. The hand on the reins is
never drawn: it is the harness.

### Primary colors

Coat `#2f2530` (the black horse), gold `#d9a948` (chanfron, lames, halo), crimson `#bd2e37`
(caparison, plume, back light), ink `#0c0809` (outline).

### Secondary colors

Coat shades `#1c1419`, `#4b3f4e` and `#7d7082`; gold shades `#a5752a` and `#6a4716`; crimson
shades `#7f1721` and `#3e0c13`; leather `#6c4326` and `#3a2215`.

### Accent colors

Gold specular `#f9e7a8` (flutes, ray tips, the lit seal), crimson specular `#e25a5c` (velvet,
plume), bone `#e2d6bb` (the eye's catchlight, the lit glass).

### Mandatory features

The resplendor behind the head. The seal in the chanfron, dark at rest. Two straight reins from
the bit to the right edge. The fluted gold chanfron and the crest lames. One pricked ear, the
plume and the madroño. The crimson caparison and its twisted gold cord. The eye under the brow
guard.

### Forbidden features

No copy of the Penitent One (Blasphemous): no capirote, no thorns, no bare torso, no blood, no
sword. No Torrent (Elden Ring), no Souls steed and no other game's horse by name or by
silhouette: no horned spirit horse. No Clawd, no Anthropic logo, no Cursor logo, and no agent's
brand colour. No rider and no hand on the reins: the holder stays outside the picture. No chain,
no cage, no whip, no spurs, no blinkers: the horse is steered, not restrained. No lit pixel in
the seal at rest. No text inside a sprite. No gore, no skull, no monster.

### Pixel-art rules

Tenebrist, baroque and gothic, in that order of priority: value first, ornament second, shape
third. One character per pixel on a text grid, sixteen colours, no anti-aliasing, no gradients,
no dithering, no half-transparency. Shadow is drawn as hard value bands inside a material's ramp,
never by mixing materials. Ink `#0c0809` closes the silhouette: no pixel other than ink faces
transparency, so the rays read on GitHub light and the ink vanishes on GitHub dark; the rim light
and the crimson back light sit inside it. Every row that holds a figure pixel holds at least one
pixel with a 3:1 contrast against GitHub dark `#0d1117` and one against white `#ffffff`. Larger
sizes are integer scales of the 64x64 master; nothing is redrawn at 128 px.

### Signature silhouette

A beaded ring of rays behind a horse's head in profile; an ear, a finial and a swept plume on
top; a segmented crest leaving the frame on the right; two straight reins below the muzzle.
Reduced to one colour: a sunburst, a horse's head and two lines.

### Accessories

None in the kept sprites. A future pose may hang only processional objects from the harness - a
lantern on the breastcollar, a scroll in a saddle case - and never adds a rider, a weapon or a
chain.

### Expression system

Three states on one drawing, different by shape before colour. Rest (`view-front`): the glass
dark garnet, the rays at mid length, the eye open. Pass (`expr-success`): the glass turns bone
and gold, four points break the ring into a star, and the rays reach full length, past the
frame. Fail (`expr-error`): an ink fissure cracks the glass and notches its ring, the halo's ring
breaks on the upper left, the rays shrink to stubs, and the eye closes to a lash line. The reins
stay taut in all three.

## Harness architecture

| Harness idea | Drawn as |
| --- | --- |
| Guides - steer before acting | the bridle, the bit and the two reins, straight and taut |
| Sensors - check after acting | the seal in the chanfron: dark at rest, a star on pass, cracked on fail |
| Trust follows the test | the resplendor: full on pass, broken on fail |
| The model, empowered not caged | a barded, haloed horse; no chain, no blinkers, no cage |
| Any agent inside the harness | the hand on the reins stays outside the picture |
| The workflow leads the model | in the banner, the lead line from the cavesson runs under the five steps |

## Pixel art specification

- **Canvas size**: 64x64 for the view and the expressions; 32x32 for the icon, drawn natively as
  a closer crop, never downscaled.
- **Palette**: the sixteen colours below, no others. The renderer rejects any source that adds
  one.
- **Pixel density**: one character per pixel; the smallest readable detail is the 3x3 glass of the
  seal (the icon's is 2x2).
- **Outline rules**: one pixel of ink `#0c0809` closes the silhouette wherever it meets
  transparency, rays and halo included; inside it the upper-left edges carry a rim light and the
  shadow side a crimson back light (`#bd2e37`, `#e25a5c`).
- **Shading rules**: tenebrist, from one light at the upper left. The ramps: coat `#7d7082` >
  `#4b3f4e` > `#2f2530` > `#1c1419`; gold `#f9e7a8` > `#d9a948` > `#a5752a` > `#6a4716` > `#3a2215`;
  crimson `#e25a5c` > `#bd2e37` > `#7f1721` > `#3e0c13`; leather `#6c4326` > `#3a2215`. The seal's
  glass stays `#3e0c13` and `#1c1419` at rest. No dithering.
- **Animation compatibility**: the resplendor and the seal are the state layers; the eye is the
  third. The head, the harness and the reins never move between frames. Frames are 64x64 on the
  same palette.

## Color palette

| Char | Hex | Role |
| --- | --- | --- |
| K | `#0c0809` | ink: outline, the fissure, the eye |
| k | `#1c1419` | coat, deepest shadow; the seal's centre at rest |
| h | `#2f2530` | coat, shadow: the black horse |
| H | `#4b3f4e` | coat, lit plane |
| j | `#7d7082` | coat sheen under the key light |
| r | `#3e0c13` | crimson, deepest; the seal's glass at rest |
| R | `#7f1721` | crimson, mid |
| c | `#bd2e37` | crimson, lit; the back light |
| p | `#e25a5c` | crimson specular: velvet, plume |
| l | `#3a2215` | leather, dark; the deepest gold |
| L | `#6c4326` | leather: reins, cheek strap, cavesson |
| y | `#6a4716` | gold, shadow |
| o | `#a5752a` | gold, mid |
| O | `#d9a948` | gold, lit: chanfron, lames, halo |
| W | `#f9e7a8` | gold specular: flutes, ray tips, the lit seal |
| b | `#e2d6bb` | bone: the eye's catchlight, the lit glass |

Sixteen colours in four material ramps - coat, crimson, gold, leather - plus ink and bone.
Nothing else.

## Character sheet

Sources in `docs/assets/tazuna/src/<name>.txt`: palette lines `<char> #rrggbb`, a line `---`,
then rows of equal width, one character per pixel, `.` transparent. `scripts/render-mascot.ps1`
writes `docs/assets/tazuna/<name>.svg` for each, `docs/assets/banner.svg` and
`docs/assets/social-preview.png`.

Only these four sprites are kept. `expr-error` is shown nowhere: it stays as the fail state
that the checks measure the rest and pass states against.

| Name | Shown in |
| --- | --- |
| `view-front` | the banner at rest, the social preview |
| `expr-success` | the banner's lit frame, the README's footer |
| `expr-error` | nowhere; the fail state for the checks |
| `icon-32` | the GitHub avatar |

To add a sprite, write its source under `docs/assets/tazuna/src/` against this bible, then run
`.\scripts\render-mascot.ps1`.

## GitHub usage

- **README banner**: `docs/assets/banner.svg`, 960x300 on a dark card framed in gold. The front
  view stands at 3.5x in the lower-right corner, cropped by the card, its reins leaving the card
  on the right. A lead line continues the cavesson to the left under the five steps, with a gold
  ferrule under each: the workflow leads the model. Every 6 s the horse switches to
  `expr-success` for 2 s and the `Verify` step lights with it; a viewer who prefers reduced
  motion sees only the front view.
- **README footer**: one sprite from `docs/assets/tazuna/`, shown at 128 px. The mascot appears
  only in the banner and the footer, never between the sections (P14).
- **Social preview**: upload `docs/assets/social-preview.png` (1280x640) in Settings > General.
- **Avatar**: `docs/assets/tazuna/icon-32.svg`, or the same at any integer scale.
- **Themes**: every sprite is checked on white `#ffffff` and on GitHub dark `#0d1117`; the ink
  rule exists for the first, the rim and back light for the second.

## Image generation prompt

Use this when a tool other than the text grids draws new art of the mascot. References are for
mood only; the character is original.

> Gothic, baroque, tenebrist pixel art, 64x64 grid, one colour per pixel, no anti-aliasing,
> transparent background.
> Frenatus, the mascot of Tazuna: the head and neck of a black Andalusian war-horse in profile,
> facing left, head flexed at the poll, calm and collected. A fluted gold chanfron with a central
> ridge and rivets runs down its face; set in it, a round seal of dark garnet glass in a gold
> ring. A gold brow guard over a heavy-lidded eye, one pricked ear, a small reliquary finial, a
> crimson plume swept back, a crimson browband with gold studs and a madroño tassel. Gilded lames
> along the crest leave the frame on the right; a crimson velvet caparison with a twisted gold
> cord and an embroidered sun fills the lower right. A bridle, a studded cavesson, a bit ring and
> two straight, taut leather reins with gold keepers run from the bit out of the frame on the
> right, held by no one in the picture. Behind the head, a beaded gold resplendor with long and
> short rays. One hard light from the upper left, tenebrist: the right and the lower body sink
> into shadow, a crimson back light catches the ear, the plume and the jowl, one pixel of ink
> closes the silhouette. Noble and serene, in the mood of Blasphemous and of Spanish Holy Week
> for mood only, copying no character. Palette, exactly and only: `#0c0809` `#1c1419` `#2f2530`
> `#4b3f4e` `#7d7082` `#3e0c13` `#7f1721` `#bd2e37` `#e25a5c` `#3a2215` `#6c4326` `#6a4716`
> `#a5752a` `#d9a948` `#f9e7a8` `#e2d6bb`. No text, no rider, no hand, no chain, no weapon, no
> lit glass in the seal, no agent's logo.

## Consistency checklist

Every new sprite passes all of these; the self-test enforces the ones marked with a case id.

- [ ] 64x64 (icon: 32x32), equal-width rows, only palette characters (M5, M25)
- [ ] every colour is one of the sixteen above, with the ink, the garnet, the gold and the leather (M3, M4)
- [ ] no pixel other than ink faces transparency (M6)
- [ ] the reins run straight and unbroken from (24,47) and (24,55) to (63,35) and (63,43), leather over its shade (icon: from (13,27) and (12,31) to (31,19) and (31,24), one pixel) (M7)
- [ ] the seal's glass at columns 22-24, rows 30-32 (icon: 9-10, 16-17) is `#3e0c13` or `#1c1419` at rest, bone and gold on pass, cracked with ink on fail (M8)
- [ ] every figure row holds a pixel at 3:1 on `#0d1117` and on `#ffffff` (M9)
- [ ] the resplendor, counted in columns 0-15 and rows 0-33, grows on pass and shrinks on fail (M10)
- [ ] pass and fail differ by at least four pixels of shape (M12)
- [ ] the eye's bone catchlight shows at rest and on pass and is gone on fail (M28)
- [ ] at least half of every sprite is shadow and the right half is darker than the left (M29, M30)
- [ ] the committed `.svg` matches a fresh render of its source (M27)
- [ ] the reins never slacken and the seal is never lit at rest; no text inside a sprite
