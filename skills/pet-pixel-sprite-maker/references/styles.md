# Pixel Pet Style Catalog

When no style is selected, present this menu in Chinese and ask the user to choose one.

## 1. `chibi-pixel-bighead` - 卡通像素大头小人

Use for a cute profile-picture-like pet with a large expressive head and small upper body. This is the first project style.

Base prompt core:

```text
Pixel art style cute cartoon character big headshot portrait based on the provided person image. Preserve the person’s hairstyle, face shape, facial features, expression, outfit colors, accessories, and recognizable styling. Kawaii chibi big-head portrait, large expressive head with small upper body, adorable round face, big sparkling eyes, cheerful smile, detailed hair, vibrant colors, clean blocky pixels, 16-bit retro video game aesthetic, highly detailed pixel art, sharp square edges, no antialiasing look, vibrant palette, suitable for a profile picture. Simple isolated subject, no text, no logo, no watermark.
```

Sprite sheet prompt additions:

```text
Create a 3x3 sprite sheet for a macOS desktop pet using the chibi pixel big-head portrait as the exact character reference. Keep the body small and head large. Same character and outfit in all frames. Flat #ff00ff chroma-key background. Frames: idle, blink, look left, look right, happy poke reaction, thinking, worried with sweat drop, sleepy, celebrate with raised fist and sparkles.
```

Recommended asset slug: `chibi_pet`.

## 2. `everskies-fashion-fullbody` - Everskies 时装全身娃娃

Use for a full-body fashion avatar with stylized proportions, outfit details, and expressive posture.

Prompt core:

```text
Everskies-inspired polished fashion doll pixel art, full-body avatar sprite, crisp visible square pixels, clean pixel clusters, elegant proportions, detailed hair shading, refined makeup, accurate outfit silhouette and accessories from the reference image. Complete standing figure, centered, white or chroma-key background depending on task.
```

Recommended asset slug: `fashion_pet`.

## 3. `retro-rpg-bust` - 复古 RPG 半身像素宠物

Use for a readable bust pet with more mature proportions than chibi while still feeling game-like.

Prompt core:

```text
Premium nostalgic 32-bit RPG portrait sprite, centered bust portrait, front-facing, head and shoulders, faithful facial proportions, readable eyes, detailed hair volume, outfit and accessory cues from the reference, deliberate pixel clusters, crisp hard edges, limited expressive palette.
```

Recommended asset slug: `rpg_bust_pet`.

## 4. `flower-wall-pixel-portrait` - 花墙复古像素人

Use when the input image has a strong floral/photo backdrop and the pet should preserve surrounding flowers as part of the identity.

Prompt core:

```text
Faithful pixel-art bust portrait preserving the person and flower-wall mood from the reference: dark hair, facial expression, outfit, accessories, and recognizable flower clusters around the head. High-density pixel art, compact desktop pet silhouette, no text, no watermark.
```

Recommended asset slug: `flower_pet`.

## 5. `mini-16bit-icon` - 迷你 16-bit 头像图标

Use for a smaller, simpler, icon-first pet where readability at menu-bar size matters more than detail.

Prompt core:

```text
Tiny 16-bit pixel avatar icon, 32x32 or 64x64 pixel style, simplified but recognizable face, hair, outfit colors, and one key accessory from the reference. Crisp blocky pixels, high contrast, minimal details, transparent or chroma-key background.
```

Recommended asset slug: `mini_pet`.
