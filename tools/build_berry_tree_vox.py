#!/usr/bin/env python3
"""Build the Crystal fruit-tree sprite as a small MagicaVoxel model.

The source sprite supplies the silhouette and shade bands.  The model is a
revolved, filled canopy with a short trunk; a few exposed gold voxels make the
berries readable from the camera instead of hiding them inside the canopy.
"""

from __future__ import annotations

import struct
import sys
from collections import deque
from pathlib import Path

from PIL import Image


PALETTE = {
    1: (8, 48, 16, 255),       # canopy outline / deepest green
    2: (0, 112, 32, 255),      # dark foliage
    3: (48, 168, 48, 255),     # foliage
    4: (120, 200, 72, 255),    # light foliage
    5: (232, 196, 48, 255),    # berry
    6: (88, 52, 24, 255),      # trunk shadow
    7: (144, 96, 40, 255),     # trunk light
}


def shade(value: int) -> str:
    if value <= 63:
        return "black"
    if value <= 140:
        return "dark"
    if value <= 216:
        return "light"
    return "white"


def sprite_mask(image: Image.Image) -> list[list[bool]]:
    width, height = image.size
    classes = [[shade(image.getpixel((x, y)))
                for x in range(width)] for y in range(height)]

    def flood(passable: set[str]) -> list[list[bool]]:
        outside = [[False] * width for _ in range(height)]
        queue: deque[tuple[int, int]] = deque()

        def seed(x: int, y: int) -> None:
            if (0 <= x < width and 0 <= y < height
                    and not outside[y][x]
                    and classes[y][x] in passable):
                outside[y][x] = True
                queue.append((x, y))

        for x in range(width):
            seed(x, 0)
            seed(x, height - 1)
        for y in range(height):
            seed(0, y)
            seed(width - 1, y)
        while queue:
            x, y = queue.popleft()
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                seed(x + dx, y + dy)
        return outside

    outside = flood({"dark", "light", "white"})
    mask = [[not outside[y][x] and classes[y][x] != "black"
             for x in range(width)] for y in range(height)]
    # If the outline is too open to enclose the canopy, use the lighter
    # interior rule used by the runtime's sprite hull fallback.
    enclosed = sum(mask[y][x] and classes[y][x] != "black"
                   for y in range(height) for x in range(width))
    if enclosed < width * height / 8:
        outside = flood({"light", "white"})
        mask = [[not outside[y][x] and classes[y][x] != "off"
                 for x in range(width)] for y in range(height)]
    return mask


def row_radius(row: list[bool]) -> float | None:
    xs = [x for x, present in enumerate(row) if present]
    if not xs:
        return None
    span = max(xs) - min(xs) + 1
    return max(1.5, span / 2.0)


def palette_index(value: int, trunk: bool, rim: bool, inner: bool) -> int:
    if trunk:
        return 6 if rim or value <= 140 else 7
    if rim:
        return 1 if value <= 63 else 2
    if inner:
        return 4 if value > 140 else 3
    if value <= 63:
        return 2
    if value <= 140:
        return 3
    return 4


def build_model(image: Image.Image) -> list[tuple[int, int, int, int]]:
    image = image.convert("L")
    width, height = image.size
    if (width, height) != (16, 16):
        raise ValueError(f"expected a 16x16 fruit tree frame, got {width}x{height}")

    mask = sprite_mask(image)
    radii = [row_radius(mask[y]) for y in range(16)]
    voxels: dict[tuple[int, int, int], int] = {}
    center = 7.5

    for sprite_y, radius in enumerate(radii):
        if radius is None:
            continue
        z = 15 - sprite_y
        trunk = sprite_y >= 12 or (radius <= 2.6 and sprite_y >= 11)
        radius_sq = radius * radius
        for x in range(16):
            for depth in range(16):
                dx = x + 0.5 - center
                dy = depth + 0.5 - center
                distance_sq = dx * dx + dy * dy
                if distance_sq > radius_sq:
                    continue
                distance = distance_sq ** 0.5
                rim = distance >= radius - 1.0
                inner = distance <= radius * 0.45
                colour = palette_index(image.getpixel((x, sprite_y)),
                                       trunk, rim, inner)
                voxels[(x, depth, z)] = colour

    # Put the fruit on the camera-facing canopy surface.  Interior speckles
    # are occluded by the revolved canopy and are not useful as berries.
    berry_positions = ((4, 8), (11, 8), (6, 10), (9, 10),
                       (5, 12), (10, 12), (7, 14))
    for x, z in berry_positions:
        radius = radii[15 - z]
        if radius is None:
            continue
        dx = x + 0.5 - center
        span = radius * radius - dx * dx
        if span <= 0:
            continue
        depth = min(15, int(center + span ** 0.5 - 0.5))
        while depth >= 0 and (x, depth, z) not in voxels:
            depth -= 1
        if depth >= 0:
            # Move to the exposed voxel at this x/z column.
            while (x, depth + 1, z) in voxels:
                depth += 1
            voxels[(x, depth, z)] = 5

    return [(x, depth, z, colour)
            for (x, depth, z), colour in sorted(voxels.items())]


def u32(value: int) -> bytes:
    return struct.pack("<I", value & 0xFFFFFFFF)


def chunk(identifier: bytes, content: bytes) -> bytes:
    return identifier + u32(len(content)) + u32(0) + content


def encode(voxels: list[tuple[int, int, int, int]]) -> bytes:
    size = chunk(b"SIZE", u32(16) + u32(16) + u32(16))
    body = u32(len(voxels)) + b"".join(bytes(v) for v in voxels)
    xyzi = chunk(b"XYZI", body)
    rgba = bytearray()
    for index in range(1, 257):
        rgba.extend(PALETTE.get(index, (0, 0, 0, 255)))
    palette = chunk(b"RGBA", bytes(rgba))
    children = size + xyzi + palette
    return b"VOX " + u32(150) + b"MAIN" + u32(0) + u32(len(children)) + children


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: build_berry_tree_vox.py SOURCE_FRAME OUTPUT_VOX")
    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    model = build_model(Image.open(source))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(encode(model))
    visible_berries = sum(1 for x, y, z, c in model if c == 5)
    print(f"wrote {output}: voxels={len(model)} visible_berries={visible_berries}")


if __name__ == "__main__":
    main()
