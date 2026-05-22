---
name: pet-pixel-sprite-maker
description: Use when the user provides a person image and wants to make a CodexBar pet in selectable pixel-art styles, including base portrait generation, 3x3 interaction sprite sheets, transparent PNG frame extraction, and integration into this Swift app as a selectable pet.
---

# Pet Pixel Sprite Maker

## Overview

Turn a user-provided person image into a selectable CodexBar pixel pet. The default flow is: show style choices first, generate a style-locked character, generate a 3x3 interaction sprite sheet, split it into transparent PNG frames, then wire it into the app as a new `PetVariant`.

Use the system `imagegen` skill for image generation. Use this skill for project-specific prompts, assets, frame naming, and Swift integration.

## Style Selection

If the user has not chosen a style, stop after presenting the style menu from [references/styles.md](references/styles.md). Do not generate images yet.

The first style is the current default:

`chibi-pixel-bighead` - 卡通像素大头小人，kawaii chibi big-head portrait, 16-bit/64x64 pixel feel, expressive face, small upper body.

After the user chooses a style, load only the matching style section from [references/styles.md](references/styles.md).

## Workflow

1. Confirm the input image is visible in context. If the user gives a local file path, inspect it with `view_image` before generating.
2. If no style is selected, present the style list and ask the user to choose one.
3. Generate a base character reference for the selected style.
4. Generate a `3 columns x 3 rows` sprite sheet on a flat `#ff00ff` chroma-key background.
5. Split the sheet with `scripts/split_pet_sprite_sheet.py`.
6. Inspect the preview image for consistency, missing body parts, leftover key color, and frame order.
7. Save frames under `Resources/Pets/<variant>_frames/`:
   `idle.png`, `blink.png`, `look_left.png`, `look_right.png`, `happy.png`, `thinking.png`, `worried.png`, `sleepy.png`, `celebrate.png`.
8. Save `Resources/Pets/<variant>_pixel.png` as a copy of `idle.png`.
9. Patch the app:
   - Add a `PetVariant` case in `Sources/codexbar/Config.swift`.
   - Add the display name in `PetVariant.displayName`.
   - Add bitmap loading for `Resources/Pets/<variant>_frames` in `Sources/codexbar/PixelPet.swift`.
   - Map `PetMood` and gaze/reaction to the 9 frame names.
   - Keep existing pets working; do not overwrite old resources unless explicitly requested.
10. Build with:
    `CLANG_MODULE_CACHE_PATH=/Users/hubo/Dee_codexbar/.build/clang-module-cache swift build`
11. Package and restart with the project’s `build.sh` when the user wants it applied immediately.

## Sprite Sheet Contract

Frame order is fixed left-to-right, top-to-bottom:

1. `idle` - cheerful neutral forward look
2. `blink` - same pose, eyes closed
3. `look_left` - eyes/head slightly left
4. `look_right` - eyes/head slightly right
5. `happy` - poke reaction, bigger smile, small raised hand
6. `thinking` - finger near cheek/chin, eyes up-left
7. `worried` - worried brows/mouth, tiny sweat drop
8. `sleepy` - droopy or closed eyes
9. `celebrate` - bright smile, raised fist, sparkles allowed

Prompt constraints:

- Same character identity, proportions, hairstyle, outfit, and palette in every frame.
- One character per cell.
- No labels, dividers, shadows, frames, text, logos, or watermark.
- Perfectly flat `#ff00ff` background and no `#ff00ff` in the subject.
- Generous padding; no cropped hair, hands, shoulders, or sparkles.

## Split Script

Run:

```bash
python3 skills/pet-pixel-sprite-maker/scripts/split_pet_sprite_sheet.py \
  --input /path/to/generated_sheet.png \
  --out-dir Resources/Pets/<variant>_frames \
  --preview /private/tmp/<variant>_preview.png \
  --still Resources/Pets/<variant>_pixel.png \
  --canvas-size 192
```

The script auto-samples the chroma key from the sheet border, removes it, crops each cell to its visible subject, rescales with nearest-neighbor, writes the 9 frames, and creates a white-background preview.

## App Integration Notes

For bitmap pets, prefer loading frames from resources over drawing with character grids. Use `.interpolation(.none)` in SwiftUI so pixel art remains crisp.

Use a stable display box. Current bitmap pets use a larger box than the original 16x16 mascot; keep footer height and bubble layout in `NotchPanel.swift` large enough that the pet does not feel tiny.
