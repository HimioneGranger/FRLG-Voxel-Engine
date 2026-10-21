# Standards-based bare-hand approval prototype

This is stage one of the Battle Art hand rebuild. It intentionally contains a
bare hand only. Do not add or fit Ash's glove until the user approves the hand
shape, size, handedness, wrist alignment, and controller-driven articulation
on Quest.

The rig and texture come from Godot's MIT-licensed OpenXR hand tracking demo.
The original glTF assets were converted into self-contained GLBs. The q83
refinement adds one UV-seam-aware Loop subdivision and a subtle increase in
finger/palm depth: 2,142 vertices / 3,752 triangles per hand. It preserves the
texture, skeleton, authored rest transforms, controller origin and visual scale.
`tools/round_standard_hand.py` generates these assets from the original GLBs;
it refuses repeated subdivision. `tools/qa_rounded_hand.py` verifies the rig,
physical bounds, weights and thumb/palm clearance in seven controller poses.
See
`LICENSE.godot-demo-projects.md` for the bundled license.

The authored mesh has palm thickness on X, finger spread on Y and fingertips
toward -Z. Dorsal is -X on the left and +X on the right. The earlier +Y dorsal
metadata was inaccurate; the geometry and renderer basis have not been rotated.

Thin flat holders may opt into `gripStyle = "flat_support"` to avoid the usual
0.58 minimum holding curl; `thumbGrip` optionally sets independent thumb contact.
Unspecified styles preserve existing ball/controller grips and holding thumbs.

The renderer-neutral style ID remains `ash_fingerless_v1`; Battle Art alone
resolves that ID to these temporary bare-hand visuals. Once approved, Battle
Art can add the modeled glove shell without changing VR Interaction.
