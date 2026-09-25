# Tameshi - the Tazuna mascot

The character bible. Every image of the mascot is drawn from this file, not from memory: the
sources live in `docs/assets/tazuna/src/`, `scripts/render-mascot.ps1` renders them, and the
self-test refuses a sprite that leaves the palette or a render that drifts from its source.

## Project interpretation

Tazuna (手綱, the reins) is the part of a horse harness the rider holds. The project is a Claude
Code harness: the model is the strength, the harness steers it before acting (guides) and checks
it after acting (sensors). The mascot has to say that in one silhouette: a warrior whose armour
has been tested, holding reins. It must be original, readable at 32 px on GitHub's light and dark
themes, drawn as dark, detailed pixel art in the spirit of Blasphemous, Dark Souls and Sekiro, and
never a copy of any of their characters. The palette is built on the Claude colours so the project
stays visibly a Claude Code tool, without using Clawd.

## Design objective

One character, one dominant silhouette feature, one metaphor: **the model empowered and steered
by its harness, never trapped**. Solemn and serene, a calm battle-worn warrior; not a monster,
not cute. It has to work as a 32 px avatar, a 64 px sprite, a README banner and a 1280x640 social
preview, and every future drawing has to be reproducible from this file.

## Concept 1

**Kura** (鞍, the saddle) - a rider and a horse, the rein taut between them. The strongest
metaphor: the pixels say "reins" without a caption. Rejected because the rider's face reads as a
mask or a skull, the centre muddies at 32 px, and rider plus horse doubles the cost of every view
and pose. Its bold terracotta rein and its calm pale face were grafted onto the chosen concept.

## Concept 2

**Kaina** (腕, the arm) - a shinobi whose prosthetic arm swaps tools. Rejected: it reads cute
rather than epic, the hood vanishes on GitHub dark, and a shinobi with a tool arm borrows too
much of Sekiro's premise.

## Concept 3

**Tameshi** (試し, the test) - a suit of bullet-tested armour whose crest seal is the
verification light. The only concept recognisable from a one-colour silhouette (two horns and a
disc). Chosen 3-0 by the panel and by the owner on 2026-09-25, with the six defects the panel
listed fixed in production: a dark dent instead of a lit eye, a bold rein, a narrower body with
wear and one story detail, rim light for the dark theme, thicker rays, and a settled profile.

## Recommended direction

Tameshi. A Sengoku-era suit of armour in Claude terracotta and gold over dark iron. The maedate
crest - a gold seal with a struck dent, flanked by two kuwagata horns - floats one pixel above
the helmet bowl so the silhouette stays two horns and a disc at any size. A calm pale face is
visible between the brim and the half mask. A bold lacquered rein crosses the chest, held in
both gauntlets. Verification is drawn as shape, not colour: on pass the seal blazes and rays
rise from it; on fail the seal splits, the head bows and the rein falls slack.

## Character bible

### Name

Tameshi (試し, "the test"), from *tameshi gusoku*, bullet-tested armour: the armourer fired a
musket at the finished breastplate and, if it held, stamped a seal recording the test. Said
"ta-MÊ-shi". Written in Latin letters everywhere; no kanji inside any sprite.

### Role

The face of Tazuna: the README banner, the footer sprite, the repository avatar and the social
preview. It stands for the harness, not for the model: the armour and the reins, never the
strength inside them.

### Concept

The model is the warrior's strength. The harness is the armour it wears and the reins it holds.
The seal on the crest lights only when the work has been tested the way the armourer tested
steel. The dent on the chest plate is the shot it survived.

### Personality

Calm, methodical, watchful, unhurried. A senior engineer who has been paged at three in the
morning and does not raise their voice. Solemn but not grim; serene, never chaotic, aggressive,
goofy or childish.

### Visual identity

Dark iron with terracotta lacing and gold fittings. Blocky armour, a floating gold crest,
a pale face under a half mask. Light comes from the upper left; the right side of every plate
steps one shade down. Wear shows as a dent on the chest and rim light on worn edges, never as
gore.

### Body proportions

Head (crest excluded) about one third of the standing height; shoulders wider than the hips;
short legs. On the 64x64 grid: crest rows 0-13, one transparent row at 14, helmet 15-26, face
and mask 27-34, torso 34-48, skirt 49-56, legs 57-63. The mirror axis sits between columns 31
and 32.

### Head design

A ridged iron *hachi* bowl with a gold brim, turned-back *fukigaeshi* wings in terracotta at
each side, and a laced *shikoro* neck guard behind the face. The bowl carries a rim light on its
upper left edge instead of a black outline there, so it separates from GitHub dark.

### Eyes

Two dark slits, three pixels wide, on a pale face. They are the expression system's main
instrument: closed arcs for happy and success, narrowed for focused, uneven for confused, round
and lit for surprised, lowered and dim for error.

### Face

Pale (`#e8e6dc`, shaded `#b0aea5`) and visible between the brim and the *menpo* half mask,
so the model reads as present and serene inside the armour, not caged. The mask covers the jaw
only, in dark iron with a nose ridge and a mouth grille.

### Harness design

Two elements and no more. The **reins**: a lacquered cord three pixels thick in `#d97757` with a
`#c15f3c` underside, crossing the chest from the left fist at the hip to the raised right fist;
taut on pass, slack on fail, looped at the belt when a hand is busy. The **seal**: the gold
maedate disc with the proof dent, the harness's verification light, dark at rest.

### Primary colors

Terracotta `#d97757` (lacing, rein), dark iron `#3d3929` (helmet, mask, chest, legs), ink
`#141413` (outline, dent, eye slits).

### Secondary colors

Gold `#e3b25b` and `#b4833a` (seal, horns, brim, hems), lacing shades `#c96442`, `#c15f3c`,
`#87422a`, iron shades `#5a5851` and `#8a877d`.

### Accent colors

Cream `#faf9f5` (horn highlights, the blazing core, eye glints), pale `#e8e6dc` and `#b0aea5`
(face, knots, rim light), deep gold `#755526` (hem cords).

### Mandatory features

The two horns and the seal disc, separated from the helmet by one transparent row. The dark dent
at the seal's heart. The pale face between brim and mask. The rein across the chest. The dent on
the chest plate. Terracotta lacing on shoulders and skirt.

### Forbidden features

No copy of the Penitent One (Blasphemous): no cone helmet, no bare torso, no thorns, no blood. No
copy of Wolf (Sekiro): no prosthetic arm, no scarf, no straw. No Dark Souls character, no
Elden Ring character, no Bloodborne character by name or by silhouette: no Solaire, no Artorias,
no Chosen Undead. No Clawd and no Anthropic logo. No kanji or text inside a sprite. No weapon
drawn: the warrior holds reins, a scroll, a lens, a lantern, never a blade. No lit dot in the
seal's dent. No gore, no skull, no monster.

### Pixel-art rules

One character per pixel on a text grid, fourteen colours, no anti-aliasing, no gradients, no
half-transparency. Every shape is outlined in `#141413` except where a rim light replaces the
outline on the lit side. Every row that holds a figure pixel holds at least one pixel with a
3:1 contrast against GitHub dark `#0d1117`. Larger sizes are integer scales of the 64x64 master;
nothing is redrawn at 128 px.

### Signature silhouette

Two horns curling out and back in, flanking a disc, floating above a rounded helmet on square
shoulders. Reduced to one colour, the crest and the body remain two separate shapes.

### Accessories

By pose only: a scroll of code, a lens, a plan unrolled between both hands, a paper lantern.
Each is held in the right hand or both hands; the rein stays in the left fist or looped at the
belt. No accessory appears in the views or the expressions.

### Expression system

Eight expressions on the same body. Neutral: slits, seal dark. Happy: closed arcs. Thinking:
eyes up and to the right, one brow raised. Focused: narrowed slits under low brows. Confused:
one eye higher than the other. Surprised: round lit eyes. Success: closed arcs, the seal blazes
cream and rays rise above the crest, the rein taut. Error: eyes lowered and dim, the seal split
by a jagged seam with a chip gone from the rim, the head bowed two pixels, the rein fallen
slack. Pass and fail differ by shape before they differ by colour.

## Harness architecture

| Harness idea | Drawn as |
| --- | --- |
| Guides - steer before acting | the reins, held forward across the chest |
| Sensors - check after acting | the crest seal: dark at rest, blazing on pass, split on fail |
| Tested by someone who is not the author | the dent on the chest plate, the shot the armour survived |
| The model, empowered not trapped | the calm pale face visible inside the armour |
| Skills and tools | what the right hand holds in the poses: scroll, lens, plan, lantern |

## Pixel art specification

- **Canvas size**: 64x64 for every view, expression and pose; 32x32 for the icon, drawn natively
  as a bust, never downscaled.
- **Palette**: the fourteen colours below, no others. The renderer rejects any source that adds
  one.
- **Pixel density**: one character per pixel; the smallest readable detail is a 2x2 block (the
  dent, the eye glint).
- **Outline rules**: one pixel of `#141413` around every layer where it meets transparency; the
  outline gives way to a rim light (`#8a877d` on iron, `#b4833a` on gold, `#c15f3c` on lacing) on
  the upper-left edge of a shape so the figure reads on dark backgrounds.
- **Shading rules**: light from the upper left; the right third of every plate steps one shade
  down (`#d97757` to `#c96442`, `#e3b25b` to `#b4833a`, `#3d3929` to `#141413`); no dithering.
- **Animation compatibility**: the head is a separate layer that can bow; the crest is a separate
  layer that can change state; the rein is a separate layer with four states (ready, taut,
  slack, loop). Frames are 64x64 on the same palette.

## Color palette

| Char | Hex | Role | Base |
| --- | --- | --- | --- |
| K | `#141413` | outline, dent, eye slits | Claude ink |
| D | `#3d3929` | iron: helmet, mask, chest, legs | Claude dark |
| n | `#5a5851` | iron ridges, gauntlets | darker shade of `#8a877d` |
| G | `#8a877d` | iron rim light | Clawd art grey |
| g | `#b0aea5` | face shade, knots | Claude grey |
| c | `#e8e6dc` | face, lacing knots | Claude light |
| C | `#faf9f5` | horn highlight, blazing core, glints | Claude cream |
| T | `#d97757` | lacing and rein, lit | Claude terracotta |
| r | `#c96442` | lacing turned from the light | Claude terracotta dark |
| t | `#c15f3c` | lacing mid shade, rein underside | Claude terracotta deep |
| R | `#87422a` | lacing shadow, failed core | darker shade of `#c15f3c` |
| A | `#e3b25b` | gold: seal, horns, brim | Clawd art gold |
| a | `#b4833a` | gold shade, hems | Clawd art gold dark |
| m | `#755526` | deepest gold, cords | darker shade of `#b4833a` |

Eleven base colours from the Claude palette and the Clawd art, plus three darker shades of
those hues for depth. Nothing else.

## Character sheet

Sources in `docs/assets/tazuna/src/<name>.txt`: palette lines `<char> #rrggbb`, a line `---`,
then rows of equal width, one character per pixel, `.` transparent. `scripts/render-mascot.ps1`
writes `docs/assets/tazuna/<name>.svg` for each, `docs/assets/banner.svg` and
`docs/assets/social-preview.png`.

Only the sprites something shows are kept:

| Name | Shown in |
| --- | --- |
| `view-front` | the banner at rest, the social preview |
| `expr-success` | the banner's lit frame, the README's passed verification and footer |
| `expr-error` | the README's failed verification |
| `icon-32` | the GitHub avatar |

The other views, expressions and poses stay specified above. To add a sprite, write its source
under `docs/assets/tazuna/src/` against this bible, then run `.\scripts\render-mascot.ps1`.

## GitHub usage

- **README banner**: `docs/assets/banner.svg`, 960x300 on an ink card, the front view at 3.5x
  beside the title. Every 6 s it switches to `expr-success` for 2 s and lights the `Verify` step with
  it; a viewer who prefers reduced motion sees only the front view.
- **README footer**: one sprite from `docs/assets/tazuna/`, shown at 128 px.
- **Social preview**: upload `docs/assets/social-preview.png` (1280x640) in Settings > General.
- **Avatar**: `docs/assets/tazuna/icon-32.svg`, or the same at any integer scale.
- **Themes**: every sprite is checked on white `#ffffff` and on GitHub dark `#0d1117`; the rim
  light rule exists for the second.

## Image generation prompt

Use this when a tool other than the text grids draws new art of the mascot. References are for
mood only; the character is original.

> Pixel art, 64x64 grid, one colour per pixel, no anti-aliasing, transparent background.
> Tameshi, the mascot of Tazuna: a calm samurai in bullet-tested Sengoku-era armour from Japan.
> A gold maedate crest - a round seal with a small dark dent struck in its centre - floats one
> pixel above a ridged dark-iron helmet, flanked by two gold kuwagata horns that curl out and
> back in. A gold brim, terracotta turned-back wings, a laced neck guard. A pale, serene face
> with two dark eye slits shows between the brim and a dark-iron half mask over the jaw. Square
> laced shoulder plates and a laced skirt in terracotta; a dark-iron chest plate with one small
> dent; dark-iron forearms and greaves with a grey rim light on the upper-left edges. A bold
> lacquered terracotta rein, three pixels thick, held forward across the chest from the left
> fist at the hip to the raised right fist. Light from the upper left. Solemn, serene,
> battle-worn, in the mood of Blasphemous, Dark Souls and Sekiro for mood only, copying no
> character from them. Palette, exactly and only: `#141413` `#3d3929` `#5a5851` `#8a877d`
> `#b0aea5` `#e8e6dc` `#faf9f5` `#d97757` `#c96442` `#c15f3c` `#87422a` `#e3b25b` `#b4833a`
> `#755526`. No text, no kanji, no weapon, no glow in the dent, no Clawd, no Anthropic logo.

## Consistency checklist

Every new sprite passes all of these; the self-test enforces the ones marked with a case id.

- [ ] 64x64 (icon: 32x32), equal-width rows, only palette characters (M5, M25)
- [ ] every colour is one of the fourteen above (M3, M4)
- [ ] the crest sits in rows 0-13 (icon: 0-8) with a transparent pixel under every column of it (M6)
- [ ] the dent at columns 31-32, rows 7-8 (icon: 15-16, 3-4) is `#141413` or `#3d3929` (M8)
- [ ] the rein crosses columns 20-43 inside rows 40-52 at three pixels thick (icon: columns 8-23, rows 22-30, two pixels) (M7)
- [ ] every figure row holds a pixel at 3:1 contrast on `#0d1117` (M9)
- [ ] the face shows at least eight pale pixels in rows 27-31, columns 24-39 (M10)
- [ ] pass and fail differ by at least four pixels of shape (M12)
- [ ] the committed `.svg` matches a fresh render of its source (M27)
- [ ] the seal's dent is never lit; the rein is never thinner than the rule; no text inside a sprite
