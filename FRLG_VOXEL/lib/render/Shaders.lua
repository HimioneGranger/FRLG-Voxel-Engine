-- FRLG_VOXEL: the world shaders (+ the atlas colour key). Each is ONE complete literal (vertex and
-- pixel stage in the same string, split by LOVE's VERTEX/PIXEL defines) so the
-- offline GLSL ES gate (es-shader-gate.py) can translate and compile exactly
-- what LOVE builds on Quest.
--
-- GLES rules (memory: LOVE GLES shader precision): never change the default
-- precision; qualify per variable. Atlas and shadow-mask UV varyings are
-- LOVE_HIGHP_OR_MEDIUMP because a tall tileset atlas (100+ rows of 16 px) and
-- a 160-cell route lose whole texels at mediump. OPAQUE has no discard
-- (mobile early-z); CUTOUT discards below u_alphaCut (0 = plain alpha blend).
-- TEX_HI (review item 15): under LOVE_GLSL1_ON_GLSL3 (Quest) LOVE's Texel()
-- is a function whose vec2 parameter takes the pixel stage's default
-- MEDIUMP precision, and LOVE #defines `texture` to its wrapper; undefining
-- it and calling the builtin keeps the highp UV all the way to the sampler.
-- Gated on __VERSION__ >= 130 as well: LOVE first validates glsl1 code with
-- glslang at the BASE language version (texture() does not exist there)
-- while LOVE_GLSL1_ON_GLSL3 is already defined -- the plain #ifdef form
-- fails that validation (desktop LOVE 11.5: "'texture' : no matching
-- overloaded function found") and the whole voxel view would drop to flat.
--
-- Lighting (render/Light.lua): per vertex, base = ambient + fill * n.fill and
-- sun = weight * n.sun; per fragment the sun term is scaled by the shadow
-- mask (R: height below which this xz is in the sun's shadow; G: the
-- occluder's bottom + 1, above which it is -- tour R4), compared with a
-- slope bias 0.03 + 0.15 * (1 - n.y) (review R4). A zero normal means
-- "unlit" (sky, UI card): base 1, no sun, no shadow, no bias.
--
-- Tour review (2026-09-28): R2 -- haze continues from u_fog.z at the fog end
-- to 1.0 at u_fogFar (the far cull distance). R3 -- the magenta/cyan and
-- flat-colour diagnostics (captures-tour-r11r/diag*) showed the reported
-- hairlines are geometry, not atlas bleeding; a half-texel-per-mip tile
-- clamp was tried and left the hairline counts unchanged, so it is not kept
-- (it cost every world fragment). The CUTOUT lod code now also runs on
-- desktop GLSL (it was GLES3-only, so desktop captures skipped the R3 alpha
-- scaling of the previous round).
local V = ...
local _ = V

local Shaders = {}
local FogBackdrop=V.require("render/FogBackdrop")

Shaders.OPAQUE = [[
varying LOVE_HIGHP_OR_MEDIUMP vec2 v_uv;
varying LOVE_HIGHP_OR_MEDIUMP vec2 v_suv;
varying mediump float v_base;
varying mediump float v_sun;
varying mediump float v_y;
varying mediump float v_bias;
varying mediump float v_fog;
// worker "atmos" (GW-P4, coordinator review 2026-09-28): how much this
// fragment faces up (n.y, clamped 0..1). Pools were washing whole wall
// facades near-white because the pool mask is an XZ projection with no
// facing/height term, so a wall directly above a lit doorstep sampled the
// same strength as the ground; v_up lets the pixel stage give ground/sills
// (n.y near 1) most of the light and walls (n.y near 0) only a gentle wash.
varying mediump float v_up;
// urgent fix (W3->W8 report, 2026-09-28): W3's per-building window rects
// (geom.stats.buildingInfo[i].windows, world-space AABBs on the wall's
// south plane) turned into a per-vertex flag by Scene.lua's
// windowFlagsFor (decided per triangle from its centroid, so all three
// vertices agree), attached the SAME way as VertexAO below. Unlike AO this
// needs no separate on/off uniform: 1.0 only on a triangle inside a real
// window's cell/band/face, and LOVE reads a missing/unattached generic
// attribute as 0.0 (same empirical fact VertexAO's comment records) --
// exactly "no glow" -- so every mesh without this attached (every interior,
// every non-wall layer, Sea/Billboards/Panel/BattlePass) is safe by
// construction, with no stale-uniform risk.
varying mediump float v_emit;
varying highp vec2 v_darkXZ;
uniform highp vec3 u_fog;
uniform highp float u_fogFar;
uniform highp vec4 u_radialFog;
#ifdef VERTEX
uniform highp mat4 u_mvp;
uniform mediump vec3 u_sun;
uniform mediump vec3 u_fill;
uniform mediump vec3 u_terms;
uniform highp vec4 u_shadowXf;

attribute vec3 VertexNormal;
// coordinator review round 2 (2026-09-28): W3's ground-contact AO
// (w3\CONTRACT_V2.md V2.8, geom.ao.opaque/cutoutUnder), one float per
// vertex, OFF by default. Scene.lua attaches a real AO-only mesh
// (Mesh:attachAttribute) only to chunks that were baked with it, and sends
// u_aoOn 1 only then -- every other mesh drawn with this shader (Sea,
// Billboards, Panel, BattlePass, and AO-less Scene chunks) never had
// VertexAO attached at all; LOVE reads a missing generic attribute as 0.0
// (confirmed empirically), which is why u_aoOn must gate its use rather
// than trusting the attribute's own default.
attribute float VertexAO;
uniform mediump float u_aoOn;
attribute float VertexEmit;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  v_uv = VertexTexCoord.xy;
  v_emit = VertexEmit;
  v_darkXZ = vertex_position.xz;
  highp float len = length(VertexNormal);
  highp vec2 push = vec2(0.0);
  if (len > 0.0001) {
    mediump vec3 n = VertexNormal / len;
    mediump float ao = mix(1.0, VertexAO, u_aoOn);
    v_base = (u_terms.x + u_terms.z * max(dot(n, u_fill), 0.0)) * ao;
    v_sun = u_terms.y * max(dot(n, u_sun), 0.0) * ao;
    push = n.xz * 0.3;
    v_bias = 0.03 + 0.15 * (1.0 - clamp(n.y, 0.0, 1.0));
    v_up = clamp(n.y, 0.0, 1.0);
  } else {
    v_base = 1.0;
    v_sun = 0.0;
    v_bias = 0.0;
    v_up = 1.0;
  }
  v_suv = (vertex_position.xz + push) * u_shadowXf.xy + u_shadowXf.zw;
  v_y = vertex_position.y;
  highp vec4 p = u_mvp * vertex_position;
  // haze: 0 -> u_fog.z between start and end, then on to 1.0 at u_fogFar
  // (review tour R2: the far cull edge melts fully into the horizon)
  highp float fogDistance = p.w;
  highp float f1 = clamp((fogDistance - u_fog.x) / max(u_fog.y - u_fog.x, 0.001), 0.0, 1.0);
  highp float f2 = clamp((fogDistance - u_fog.y) / max(u_fogFar - u_fog.y, 0.001), 0.0, 1.0)
    * step(u_fog.y + 0.001, u_fogFar) * step(0.001, u_fog.z);
  v_fog = u_fog.z * f1 + (1.0 - u_fog.z) * f2;
  return p;
}
#endif
#ifdef PIXEL
highp float fogAmount() {
 if(u_radialFog.z<=0.0)return v_fog;
 highp float d=length(v_darkXZ-u_radialFog.xy)*u_radialFog.z+u_radialFog.w;
 highp float f1=clamp((d-u_fog.x)/max(u_fog.y-u_fog.x,.001),0.0,1.0);
 highp float f2=clamp((d-u_fog.y)/max(u_fogFar-u_fog.y,.001),0.0,1.0)*step(u_fog.y+.001,u_fogFar)*step(.001,u_fog.z);
 return u_fog.z*f1+(1.0-u_fog.z)*f2;
}

#if defined(LOVE_GLSL1_ON_GLSL3) && __VERSION__ >= 130
#undef texture
#define TEX_HI(s, c) texture(s, c)
#else
#define TEX_HI(s, c) texture2D(s, c)
#endif
uniform mediump vec4 u_fogColor;
uniform vec3 u_worldMul;
uniform vec3 u_worldAdd;
uniform Image u_shadow;
uniform mediump float u_shadowOn;
uniform mediump float u_hscale;
// worker "atmos" (GW-P1/P4, DESIGN.md 3.4; coordinator review 2026-09-28
// against reference-user-20260928/videos-20260928/v17_sheet.jpg, v18_sheet.
// jpg -- see the fixes below): the one time/weather grade, the emissive
// (glow) mask and the warm ground-pool mask. Identity defaults (mul 1,
// add 0, shadowFade 1, emitOn 0, poolOn 0) are always sent by
// Shaders.frame/Shaders.shadow/Shaders.emissive, so the UI card and the
// battle command card (their own ungraded `env`) are unaffected -- uniforms
// keep their last value otherwise.
uniform mediump vec3 u_gradeMul;
uniform mediump vec3 u_gradeAdd;
uniform mediump float u_shadowFade;
uniform Image u_emit;
uniform mediump float u_emitOn;
uniform mediump float u_emitGain;
uniform mediump vec3 u_emitColor;
uniform mediump float u_poolOn;
uniform mediump float u_poolGain;
uniform mediump vec3 u_poolColor;
uniform mediump float u_waterDark;
uniform mediump float u_waterFade;
uniform bool u_darkOn;
uniform highp vec2 u_darkC;
uniform highp float u_darkR;
vec4 applyCaveDark(vec4 color) {
 if (!u_darkOn) return color;
 highp float d = length(v_darkXZ-u_darkC);
 highp float amount = u_darkR <= 0.0 ? 1.0 : smoothstep(.82*u_darkR,1.18*u_darkR,d);
 return vec4(color.rgb*(1.0-amount),color.a);
}
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  mediump vec4 c = TEX_HI(tex, v_uv) * color;
  mediump float lit = 1.0;
  mediump float pool = 0.0;
  if (u_shadowOn > 0.5) {
    // R = occluder top, G = occluder bottom + 1 (0: none): shadowed only
    // between the two, so floating boards and crowns cast offset shadows.
    // B = warm ground-pool strength (render/LightPools.lua), same fetch.
    mediump vec3 sm3 = TEX_HI(u_shadow, v_suv).rgb;
    mediump vec2 sm = sm3.rg * u_hscale;
    mediump float above = smoothstep(0.03, 0.22, sm.x - v_y - v_bias);
    mediump float below = 1.0 - smoothstep(-0.02, 0.10, (sm.y - 1.0) - v_y);
    lit = 1.0 - above * below * u_shadowFade;
    pool = sm3.b;
  } else if (u_poolOn > 0.5) {
    // pools-only mask (no shadow mask on this map): one fetch, no shadow maths
    pool = TEX_HI(u_shadow, v_suv).b;
  }
  mediump float shade = min(v_base + v_sun * lit, 1.04);
  mediump vec3 graded = c.rgb * shade * u_gradeMul + u_gradeAdd;
  // coordinator review round 2 (2026-09-28): open water (ponds, the Sea.lua
  // plane -- both draw through this same OPAQUE shader) stayed vivid,
  // near-daytime blue at night: its raw art is far more saturated than
  // typical ground/wall texels, so the uniform night u_gradeMul left it
  // reading "still bright" even though it darkened by the same factor as
  // everything else. No extra texture fetch: waterK reads how much the
  // ALREADY-SAMPLED texel colour c.rgb is blue-dominant (continuous, not a
  // hard key, so it follows water's whole animation-frame palette instead
  // of a few exact colours) and only darkens further at night (u_waterFade
  // = nightWeight, 0 by day). Window glass is also blue-ish and gets a
  // partial hit here too, but a glass texel of a registered window is fully
  // overwritten by the emissive mix below, so lit panes are unaffected; only
  // unregistered glass reads a little extra dim.
  mediump float waterK = clamp((c.b - max(c.r, c.g) - 0.10) * 3.0, 0.0, 1.0);
  graded *= mix(1.0, u_waterDark, waterK * u_waterFade);
  if (u_emitOn > 0.5) {
    // coordinator review: windows must read as warm yellow, not the atlas'
    // own daytime blue glass tinted by emitGain -- blend toward a fixed
    // warm colour, keeping a little of the texel's own shading (the
    // gradient/mullions) via its luminance so it is not a flat block.
    mediump float emit = TEX_HI(u_emit, v_uv).r;
    mediump float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    mediump float glow = luma * 0.4 + 0.6;
    // glow-precise (2026-09-28): `emit` is the mask alone -- the exact glass
    // texels of W3's registered windows (render/Emissive.lua, built by
    // Scene.lua's glassTexels), 0 on frames, mullions, sills and siding --
    // and v_emit is 1 only on triangles whose centroid is in a registered
    // window's cell/band/face, 0 elsewhere (no per-vertex gradient onto the
    // neighbouring quads). The earlier relaxed colour test on c.rgb (blue-
    // dominant or bright-and-grey above a luma floor) also matched the navy
    // frames and the light siding, so whole wall cells glowed; it is gone.
    // urgent fix (W3->W8 report): u_emitGain must GATE the mix, not just
    // scale the target colour -- folding it only into the target meant
    // gain=0 (indoors / daytime identity default) still mixed fully toward
    // black instead of leaving graded untouched. mix's identity element is
    // t=0, so emitGain now multiplies the blend factor itself.
    mediump float emitMix = emit * u_emitOn * u_emitGain * v_emit;
    graded = mix(graded, u_emitColor * glow, emitMix);
  }
  // coordinator review: pools were washing the whole facade near-white --
  // v_suv is an XZ projection with no facing/height term, so a wall
  // directly above a lit doorstep sampled the same pool strength as the
  // ground. v_up (n.y) restricts most of the strength to upward faces
  // (ground, sills); walls get only a gentle wash. The add is also capped
  // so even a bright wall/ground texel cannot blow out to white.
  mediump float poolW = 0.15 + 0.85 * v_up;
  mediump vec3 poolRaw = c.rgb * pool * poolW * u_poolColor * u_poolGain;
  mediump float poolMax = max(max(poolRaw.r, poolRaw.g), poolRaw.b);
  mediump vec3 poolAdd = poolRaw * (poolMax > 0.55 ? 0.55 / max(poolMax, 0.0001) : 1.0);
  graded += poolAdd;
  graded = clamp(graded*u_worldMul + u_worldAdd*min(1.0, max(max(c.r,c.g),c.b)*4.0),0.0,1.0);
  return applyCaveDark(vec4(mix(graded, u_fogColor.rgb, fogAmount()), 1.0));
}
#endif
]]

Shaders.CUTOUT = [[
varying LOVE_HIGHP_OR_MEDIUMP vec2 v_uv;
varying LOVE_HIGHP_OR_MEDIUMP vec2 v_suv;
varying mediump float v_base;
varying mediump float v_sun;
varying mediump float v_y;
varying mediump float v_bias;
varying mediump float v_fog;
// worker "atmos" (GW-P4): see Shaders.OPAQUE's matching v_up comment (SH6).
varying mediump float v_up;
// urgent fix (W3->W8 report, 2026-09-28): W3's per-building window rects
// (geom.stats.buildingInfo[i].windows, world-space AABBs on the wall's
// south plane) turned into a per-vertex flag by Scene.lua's
// windowFlagsFor (decided per triangle from its centroid, so all three
// vertices agree), attached the SAME way as VertexAO below. Unlike AO this
// needs no separate on/off uniform: 1.0 only on a triangle inside a real
// window's cell/band/face, and LOVE reads a missing/unattached generic
// attribute as 0.0 (same empirical fact VertexAO's comment records) --
// exactly "no glow" -- so every mesh without this attached (every interior,
// every non-wall layer, Sea/Billboards/Panel/BattlePass) is safe by
// construction, with no stale-uniform risk.
varying mediump float v_emit;
varying highp vec2 v_darkXZ;
uniform highp vec3 u_fog;
uniform highp float u_fogFar;
uniform highp vec4 u_radialFog;
#ifdef VERTEX
uniform highp mat4 u_mvp;
uniform mediump vec3 u_sun;
uniform mediump vec3 u_fill;
uniform mediump vec3 u_terms;
uniform highp vec4 u_shadowXf;

attribute vec3 VertexNormal;
// coordinator review round 2 (2026-09-28): W3's ground-contact AO
// (w3\CONTRACT_V2.md V2.8, geom.ao.opaque/cutoutUnder), one float per
// vertex, OFF by default. Scene.lua attaches a real AO-only mesh
// (Mesh:attachAttribute) only to chunks that were baked with it, and sends
// u_aoOn 1 only then -- every other mesh drawn with this shader (Sea,
// Billboards, Panel, BattlePass, and AO-less Scene chunks) never had
// VertexAO attached at all; LOVE reads a missing generic attribute as 0.0
// (confirmed empirically), which is why u_aoOn must gate its use rather
// than trusting the attribute's own default.
attribute float VertexAO;
uniform mediump float u_aoOn;
attribute float VertexEmit;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  v_uv = VertexTexCoord.xy;
  v_emit = VertexEmit;
  v_darkXZ = vertex_position.xz;
  highp float len = length(VertexNormal);
  highp vec2 push = vec2(0.0);
  if (len > 0.0001) {
    mediump vec3 n = VertexNormal / len;
    mediump float ao = mix(1.0, VertexAO, u_aoOn);
    v_base = (u_terms.x + u_terms.z * max(dot(n, u_fill), 0.0)) * ao;
    v_sun = u_terms.y * max(dot(n, u_sun), 0.0) * ao;
    push = n.xz * 0.3;
    v_bias = 0.03 + 0.15 * (1.0 - clamp(n.y, 0.0, 1.0));
    v_up = clamp(n.y, 0.0, 1.0);
  } else {
    v_base = 1.0;
    v_sun = 0.0;
    v_bias = 0.0;
    v_up = 1.0;
  }
  v_suv = (vertex_position.xz + push) * u_shadowXf.xy + u_shadowXf.zw;
  v_y = vertex_position.y;
  highp vec4 p = u_mvp * vertex_position;
  // haze: 0 -> u_fog.z between start and end, then on to 1.0 at u_fogFar
  // (review tour R2: the far cull edge melts fully into the horizon)
  highp float fogDistance = p.w;
  highp float f1 = clamp((fogDistance - u_fog.x) / max(u_fog.y - u_fog.x, 0.001), 0.0, 1.0);
  highp float f2 = clamp((fogDistance - u_fog.y) / max(u_fogFar - u_fog.y, 0.001), 0.0, 1.0)
    * step(u_fog.y + 0.001, u_fogFar) * step(0.001, u_fog.z);
  v_fog = u_fog.z * f1 + (1.0 - u_fog.z) * f2;
  return p;
}
#endif
#ifdef PIXEL
highp float fogAmount() {
 if(u_radialFog.z<=0.0)return v_fog;
 highp float d=length(v_darkXZ-u_radialFog.xy)*u_radialFog.z+u_radialFog.w;
 highp float f1=clamp((d-u_fog.x)/max(u_fog.y-u_fog.x,.001),0.0,1.0);
 highp float f2=clamp((d-u_fog.y)/max(u_fogFar-u_fog.y,.001),0.0,1.0)*step(u_fog.y+.001,u_fogFar)*step(.001,u_fog.z);
 return u_fog.z*f1+(1.0-u_fog.z)*f2;
}

#if defined(LOVE_GLSL1_ON_GLSL3) && __VERSION__ >= 130
#undef texture
#define TEX_HI(s, c) texture(s, c)
#else
#define TEX_HI(s, c) texture2D(s, c)
#endif
#if !defined(GL_ES) || __VERSION__ >= 300 || defined(GL_OES_standard_derivatives)
#define HAS_DERIV 1
#endif
uniform mediump vec4 u_fogColor;
uniform vec3 u_worldMul;
uniform vec3 u_worldAdd;
uniform mediump float u_alphaCut;
// Lab 57: 1.0 while a premultiplied-alpha card is drawn (Billboards): its rgb is already scaled by alpha, so the
// haze colour must be scaled by alpha too or semi-transparent texels get a bright fog fringe. 0.0 = every other draw.
uniform mediump float u_premul;
uniform Image u_shadow;
uniform mediump float u_shadowOn;
uniform mediump float u_hscale;
uniform highp vec2 u_texSize;
// worker "atmos" (GW-P1/P4, DESIGN.md 3.4): see Shaders.OPAQUE's matching
// block for the identity-default contract and the coordinator-review fixes
// (warm emissive tint, v_up-weighted capped pools).
uniform mediump vec3 u_gradeMul;
uniform mediump vec3 u_gradeAdd;
uniform mediump float u_shadowFade;
uniform Image u_emit;
uniform mediump float u_emitOn;
uniform mediump float u_emitGain;
uniform mediump vec3 u_emitColor;
uniform mediump float u_poolOn;
uniform mediump float u_poolGain;
uniform mediump vec3 u_poolColor;
uniform mediump float u_waterDark;
uniform mediump float u_waterFade;
uniform bool u_darkOn;
uniform highp vec2 u_darkC;
uniform highp float u_darkR;
vec4 applyCaveDark(vec4 color) {
 if (!u_darkOn) return color;
 highp float d = length(v_darkXZ-u_darkC);
 highp float amount = u_darkR <= 0.0 ? 1.0 : smoothstep(.82*u_darkR,1.18*u_darkR,d);
 return vec4(color.rgb*(1.0-amount),color.a);
}
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  mediump vec4 c = TEX_HI(tex, v_uv) * color;
  mediump float lod = 0.0;
#ifdef HAS_DERIV
  if (u_texSize.x > 0.5) {
    highp vec2 tp = v_uv * u_texSize;
    highp vec2 ddx = dFdx(tp);
    highp vec2 ddy = dFdy(tp);
    highp float d2 = max(max(dot(ddx, ddx), dot(ddy, ddy)), 1e-8);
    lod = max(0.5 * log2(d2), 0.0);
  }
#endif
  // review R3: mipmapped cutouts average alpha down with distance; scale it
  // back up by the sampled lod so far canopies and grass do not thin out
  c.a = c.a * (1.0 + lod * 0.25);
  if (c.a < u_alphaCut) discard;
  mediump float lit = 1.0;
  mediump float pool = 0.0;
  if (u_shadowOn > 0.5) {
    mediump vec3 sm3 = TEX_HI(u_shadow, v_suv).rgb;
    mediump vec2 sm = sm3.rg * u_hscale;
    mediump float above = smoothstep(0.03, 0.22, sm.x - v_y - v_bias);
    mediump float below = 1.0 - smoothstep(-0.02, 0.10, (sm.y - 1.0) - v_y);
    lit = 1.0 - above * below * u_shadowFade;
    pool = sm3.b;
  } else if (u_poolOn > 0.5) {
    pool = TEX_HI(u_shadow, v_suv).b;
  }
  mediump float shade = min(v_base + v_sun * lit, 1.04);
  mediump vec3 graded = c.rgb * shade * u_gradeMul + u_gradeAdd;
  // coordinator review round 2: see Shaders.OPAQUE's matching comment.
  mediump float waterK = clamp((c.b - max(c.r, c.g) - 0.10) * 3.0, 0.0, 1.0);
  graded *= mix(1.0, u_waterDark, waterK * u_waterFade);
  if (u_emitOn > 0.5) {
    mediump float emit = TEX_HI(u_emit, v_uv).r;
    mediump float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    mediump float glow = luma * 0.4 + 0.6;
    // glow-precise: see Shaders.OPAQUE's matching comment (mask-only emit).
    // urgent fix (W3->W8 report): u_emitGain must GATE the mix, not just
    // scale the target colour -- folding it only into the target meant
    // gain=0 (indoors / daytime identity default) still mixed fully toward
    // black instead of leaving graded untouched. mix's identity element is
    // t=0, so emitGain now multiplies the blend factor itself.
    mediump float emitMix = emit * u_emitOn * u_emitGain * v_emit;
    graded = mix(graded, u_emitColor * glow, emitMix);
  }
  mediump float poolW = 0.15 + 0.85 * v_up;
  mediump vec3 poolRaw = c.rgb * pool * poolW * u_poolColor * u_poolGain;
  mediump float poolMax = max(max(poolRaw.r, poolRaw.g), poolRaw.b);
  mediump vec3 poolAdd = poolRaw * (poolMax > 0.55 ? 0.55 / max(poolMax, 0.0001) : 1.0);
  graded += poolAdd;
  graded = clamp(graded*u_worldMul + u_worldAdd*min(1.0, max(max(c.r,c.g),c.b)*4.0),0.0,1.0);
  return applyCaveDark(vec4(mix(graded, u_fogColor.rgb * mix(1.0, min(c.a, 1.0), u_premul), fogAmount()), min(c.a, 1.0)));
}
#endif
]]

-- Colour key (review R2): copies an atlas with the listed ground-palette
-- colours made transparent (alpha 0, rgb kept so lower mips stay green).
-- Used by Mip.keyed to build the cutoutKeyed atlas on the GPU.
Shaders.KEY = [[
varying LOVE_HIGHP_OR_MEDIUMP vec2 v_uv;
#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  v_uv = VertexTexCoord.xy;
  return transform_projection * vertex_position;
}
#endif
#ifdef PIXEL
#if defined(LOVE_GLSL1_ON_GLSL3) && __VERSION__ >= 130
#undef texture
#define TEX_HI(s, c) texture(s, c)
#else
#define TEX_HI(s, c) texture2D(s, c)
#endif
uniform mediump vec3 u_key0;
uniform mediump vec3 u_key1;
uniform mediump vec3 u_key2;
uniform mediump vec3 u_key3;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  mediump vec4 c = TEX_HI(tex, v_uv);
  mediump float k = min(min(distance(c.rgb, u_key0), distance(c.rgb, u_key1)),
    min(distance(c.rgb, u_key2), distance(c.rgb, u_key3)));
  if (k < 0.012) c.a = 0.0;
  return c;
}
#endif
]]

Shaders.FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
}

local compiled, failed = {}, {}
Shaders.stats = { compiles = 0, ms = 0 } -- Lab 57: first-use shader compiles (read by the eye-pass probe)

function Shaders.get(kind)
  -- W6 (battle P-B1): battle/BattleCut.lua swaps in cutaway variants of the
  -- world shaders around Scene:draw while a battle is staged
  local o = Shaders.override
  if o and o[kind] then return o[kind] end
  if compiled[kind] then return compiled[kind] end
  if failed[kind] then return nil, failed[kind] end
  local source = Shaders[kind]
  if type(source) ~= "string" then return nil, "unknown shader " .. tostring(kind) end
  local tc = love.timer and love.timer.getTime and love.timer.getTime() or 0
  local ok, shader = pcall(love.graphics.newShader, source)
  -- Lab 57 eye-pass probe: first-use compile cost (allocation-free counters)
  Shaders.stats.compiles = Shaders.stats.compiles + 1
  Shaders.stats.ms = Shaders.stats.ms + ((love.timer and love.timer.getTime and love.timer.getTime() or 0) - tc) * 1000
  if not ok or not shader then
    failed[kind] = tostring(shader)
    return nil, failed[kind]
  end
  compiled[kind] = shader
  return shader
end

-- Quiet send: a uniform the GLSL compiler optimised away must not throw.
function Shaders.send(shader, name, ...)
  local ok = pcall(shader.send, shader, name, ...)
  return ok
end

-- 1x1 stand-in bound to u_shadow whenever no mask applies.
local blank
function Shaders.blank()
  if blank then return blank end
  local ok, data = pcall(love.image.newImageData, 1, 1, "rgba8")
  if not ok then return nil end
  data:setPixel(0, 0, 0, 0, 0, 1)
  local okI, img = pcall(love.graphics.newImage, data)
  if okI then blank = img end
  return blank
end

-- Per-frame constants shared by every world draw.
-- env = { light = {sun, fill, terms}, fog = {start, end, max}, fogFar,
--         fogColor }
local function frameLab52(shader, env, alphaCut)
  V.require("grass/GrassDeform").disable(shader)
  Shaders.send(shader, "u_sun", env.light.sun)
  Shaders.send(shader, "u_fill", env.light.fill)
  Shaders.send(shader, "u_terms", env.light.terms)
  Shaders.send(shader, "u_fog", env.fog)
  Shaders.send(shader, "u_fogFar", env.fogFar or 0)
  Shaders.send(shader, "u_fogColor", env.fogColor)
  Shaders.send(shader, "u_hscale", env.light.hscale or 8)
  -- worker "atmos" (GW-P1/P4): identity defaults whenever env.grade is
  -- absent. u_emitOn/u_emit and u_poolOn are per-record uniforms, sent by
  -- Shaders.emissive/Shaders.shadow instead (Scene.lua's drawLayer).
  local grade = env.grade
  local mul = grade and grade.mul or { 1, 1, 1 }
  local add = grade and grade.add or { 0, 0, 0 }
  local shadowFade = grade and grade.shadowFade
  if shadowFade == nil then shadowFade = 1 end
  local poolGain = (grade and grade.poolGain) or 0
  local poolColor = (grade and grade.poolColor) or { 1, 1, 1 }
  -- urgent fix (W3->W8 report, 2026-09-28): this defaulted to 1, so any
  -- draw with no env.grade at all (indoors, UI/battle cards) rendered
  -- window glow at FULL strength regardless of hour. poolGain above already
  -- had the correct "or 0" identity default; emitGain now matches it. The
  -- shader-side mix fix (search "emitMix" above) makes gain=0 a true no-op
  -- instead of merely darkening the mix target.
  local emitGain = (grade and grade.emitGain) or 0
  -- coordinator review 2026-09-28: warm yellow default (matches
  -- reference-user-20260928/videos-20260928/v17/v18's lit windows); a
  -- caller can override via env.grade.emitColor (AtmosState.emissive.color).
  local emitColor = (grade and grade.emitColor) or { 1.0, 0.82, 0.42 }
  -- coordinator review round 2 (2026-09-28): water darkens further at
  -- night than the uniform grade alone gives it (its raw art is more
  -- saturated than typical ground/wall texels). waterFade defaults 0 (no
  -- effect) whenever env.grade is absent or provides no waterFade, exactly
  -- like every other atmos uniform here.
  local waterDark = (grade and grade.waterDark) or 0.5
  local waterFade = (grade and grade.waterFade) or 0
  Shaders.send(shader, "u_gradeMul", mul)
  Shaders.send(shader, "u_gradeAdd", add)
  Shaders.send(shader, "u_shadowFade", shadowFade)
  Shaders.send(shader, "u_emitGain", env.lightingManaged and 0 or emitGain)
  Shaders.send(shader, "u_emitColor", emitColor)
  Shaders.send(shader, "u_poolGain", env.lightingManaged and 0 or poolGain)
  Shaders.send(shader, "u_poolColor", poolColor)
  Shaders.send(shader, "u_waterDark", waterDark)
  Shaders.send(shader, "u_waterFade", waterFade)
  -- coordinator review round 2 bugfix: u_emitOn (and the new u_aoOn) are
  -- per-record uniforms (Shaders.emissive/Shaders.ao, Scene.lua's
  -- drawLayer), but a shader's uniforms persist across draw calls AND
  -- across frames. Sky.lua/Sea.lua/Panel.lua/BattlePass.lua call
  -- Shaders.frame but never Shaders.emissive/Shaders.ao, so without an
  -- explicit reset here they would silently inherit whatever u_emitOn/
  -- u_aoOn (and whatever stale u_emit texture) the LAST Scene.lua chunk of
  -- the PREVIOUS frame happened to leave bound -- latent since GW-P4 (an
  -- emissive pair usually draws last and leaves emitOn=0 most frames, so it
  -- rarely showed), caught while adding u_aoOn. u_shadowOn/u_poolOn already
  -- get this reset from Shaders.shadow(shader, nil), which every such
  -- caller does call.
  Shaders.send(shader, "u_emitOn", 0)
  Shaders.send(shader, "u_aoOn", 0)
  if alphaCut then Shaders.send(shader, "u_alphaCut", alphaCut) end
end

-- Shadow mask for the next draws (nil = none). worker "atmos" (GW-P4):
-- poolsOnly = true binds `image` as a pools-only mask instead (u_shadowOn
-- stays 0, u_poolOn goes 1; DESIGN.md 3.4 "Pools without shadows").
local function shadowLab52(shader, image, sx, sz, ox, oz, poolsOnly)
  if image and poolsOnly then
    Shaders.send(shader, "u_shadow", image)
    Shaders.send(shader, "u_shadowXf", { sx, sz, ox or 0, oz or 0 })
    Shaders.send(shader, "u_shadowOn", 0)
    Shaders.send(shader, "u_poolOn", 1)
  elseif image then
    Shaders.send(shader, "u_shadow", image)
    Shaders.send(shader, "u_shadowXf", { sx, sz, ox or 0, oz or 0 })
    Shaders.send(shader, "u_shadowOn", 1)
    Shaders.send(shader, "u_poolOn", 0)
  else
    local b = Shaders.blank()
    if b then Shaders.send(shader, "u_shadow", b) end
    Shaders.send(shader, "u_shadowXf", { 0, 0, 0, 0 })
    Shaders.send(shader, "u_shadowOn", 0)
    Shaders.send(shader, "u_poolOn", 0)
  end
end

-- worker "atmos" (GW-P4, DESIGN.md 3.5): the emissive (glow) mask for the
-- draws that follow (nil = none, u_emitOn 0).
local function emissiveLab52(shader, image)
  if image then
    Shaders.send(shader, "u_emit", image)
    Shaders.send(shader, "u_emitOn", 1)
  else
    local b = Shaders.blank()
    if b then Shaders.send(shader, "u_emit", b) end
    Shaders.send(shader, "u_emitOn", 0)
  end
end

-- worker "atmos" (coordinator review round 2, w3\CONTRACT_V2.md V2.8):
-- gates VertexAO's use for the draws that follow. `on` must be true only
-- for a mesh Scene.lua actually attached a real AO buffer to
-- (Mesh:attachAttribute) -- everything else reads VertexAO as LOVE's
-- missing-attribute default (0.0), which would read as "fully occluded"
-- if u_aoOn let it through, so off (0) means "ignore VertexAO, use 1.0".
local function aoLab52(shader, on)
  Shaders.send(shader, "u_aoOn", on and 1 or 0)
end

-- Atlas size for the CUTOUT lod estimate (0,0 = off: sky gradient, sea
-- plane, sprite sheets, UI card).
local function texSizeLab52(shader, image)
  local w, h = 0, 0
  if image and image.getDimensions then
    local ok, a, b = pcall(image.getDimensions, image)
    if ok then w, h = a, b end
  end
  Shaders.send(shader, "u_texSize", { w, h })
end

-- ------------------------------------------------------------ Lab 55
-- FRAME HOIST (OutdoorPerf.hoist): the uniforms Shaders.frame/shadow/emissive/
-- ao own are sent only when the value differs from the last value sent to
-- that shader object through these functions (LOVE keeps a shader's uniforms
-- across draws and frames, and reapplies them after a context reload). Only
-- names no other code writes are cached (grep: u_alphaCut and u_texSize also
-- have outside writers, so they are never cached). The value every draw sees
-- is the value Lab 52 sent. Lab 52 sent ~25 uniforms per Shaders.frame,
-- 6-7 times per eye, almost all unchanged. EYE SCRATCH (OutdoorPerf.scratch):
-- the shadow-transform and atlas-size tables are reused (send copies them).
-- Switching either off runs the Lab 52 functions above unchanged; a switch
-- change bumps OutdoorPerf.epoch, which empties the cache.
local Perf = V.require("render/OutdoorPerf")
local caches = setmetatable({}, { __mode = "k" })
local cacheEpoch = -1
local function cacheFor(shader)
  if Perf.epoch ~= cacheEpoch then
    for k in pairs(caches) do caches[k] = nil end
    cacheEpoch = Perf.epoch
  end
  local c = caches[shader]
  if not c then c = {}; caches[shader] = c end
  return c
end
Shaders._cacheFor = cacheFor -- test seam
function Shaders.invalidateCache(shader)
  if shader then caches[shader] = nil else for k in pairs(caches) do caches[k] = nil end end
end
local function sendRaw(shader, name, ...) return Shaders.send(shader, name, ...) end
-- number / image / boolean value
local function sendS(c, shader, name, v)
  if v ~= nil and c[name] == v then return end
  c[name] = v
  sendRaw(shader, name, v)
end
-- vector value (array table): element-wise compare against a kept copy
local function sendT(c, shader, name, t)
  if type(t) ~= "table" then c[name] = nil; return sendRaw(shader, name, t) end
  local s = c[name]
  local n = #t
  if type(s) == "table" and s.n == n then
    local same = true
    for i = 1, n do if s[i] ~= t[i] then same = false; break end end
    if same then return end
  elseif type(s) ~= "table" then
    s = {}; c[name] = s -- once per shader and name
  end
  for i = 1, n do s[i] = t[i] end
  s.n = n
  sendRaw(shader, name, t)
end
-- 4 scalars through one reused send table
local xf4 = { 0, 0, 0, 0 }
local function send4(c, shader, name, a, b, d, e)
  local s = c[name]
  if type(s) == "table" and s[1] == a and s[2] == b and s[3] == d and s[4] == e then return end
  if type(s) ~= "table" then s = {}; c[name] = s end
  s[1], s[2], s[3], s[4] = a, b, d, e
  xf4[1], xf4[2], xf4[3], xf4[4] = a, b, d, e
  sendRaw(shader, name, xf4)
end
local ONE3, ZERO3, WHITE3, EMIT3 = { 1, 1, 1 }, { 0, 0, 0 }, { 1, 1, 1 }, { 1.0, 0.82, 0.42 }
local GrassDeform55 = V.require("grass/GrassDeform")

local function frameHoist(shader, env, alphaCut)
  GrassDeform55.disable(shader)
  local c = cacheFor(shader)
  local light = env.light
  sendT(c, shader, "u_sun", light.sun)
  sendT(c, shader, "u_fill", light.fill)
  sendT(c, shader, "u_terms", light.terms)
  sendT(c, shader, "u_fog", env.fog)
  sendS(c, shader, "u_fogFar", env.fogFar or 0)
  sendT(c, shader, "u_fogColor", env.fogColor)
  sendS(c, shader, "u_hscale", light.hscale or 8)
  local grade = env.grade
  local shadowFade = grade and grade.shadowFade
  if shadowFade == nil then shadowFade = 1 end
  sendT(c, shader, "u_gradeMul", grade and grade.mul or ONE3)
  sendT(c, shader, "u_gradeAdd", grade and grade.add or ZERO3)
  sendS(c, shader, "u_shadowFade", shadowFade)
  sendS(c, shader, "u_emitGain", env.lightingManaged and 0 or (grade and grade.emitGain) or 0)
  sendT(c, shader, "u_emitColor", (grade and grade.emitColor) or EMIT3)
  sendS(c, shader, "u_poolGain", env.lightingManaged and 0 or (grade and grade.poolGain) or 0)
  sendT(c, shader, "u_poolColor", (grade and grade.poolColor) or WHITE3)
  sendS(c, shader, "u_waterDark", (grade and grade.waterDark) or 0.5)
  sendS(c, shader, "u_waterFade", (grade and grade.waterFade) or 0)
  sendS(c, shader, "u_emitOn", 0)
  sendS(c, shader, "u_aoOn", 0)
  if alphaCut then sendRaw(shader, "u_alphaCut", alphaCut) end
end

local function shadowHoist(shader, image, sx, sz, ox, oz, poolsOnly)
  local c = cacheFor(shader)
  if image and poolsOnly then
    sendS(c, shader, "u_shadow", image)
    send4(c, shader, "u_shadowXf", sx, sz, ox or 0, oz or 0)
    sendS(c, shader, "u_shadowOn", 0)
    sendS(c, shader, "u_poolOn", 1)
  elseif image then
    sendS(c, shader, "u_shadow", image)
    send4(c, shader, "u_shadowXf", sx, sz, ox or 0, oz or 0)
    sendS(c, shader, "u_shadowOn", 1)
    sendS(c, shader, "u_poolOn", 0)
  else
    local b = Shaders.blank()
    if b then sendS(c, shader, "u_shadow", b) end
    send4(c, shader, "u_shadowXf", 0, 0, 0, 0)
    sendS(c, shader, "u_shadowOn", 0)
    sendS(c, shader, "u_poolOn", 0)
  end
end

-- EYE SCRATCH without FRAME HOIST: the Lab 52 sends, one reused table
local function shadowScratch(shader, image, sx, sz, ox, oz, poolsOnly)
  if image then
    xf4[1], xf4[2], xf4[3], xf4[4] = sx, sz, ox or 0, oz or 0
    Shaders.send(shader, "u_shadow", image)
    Shaders.send(shader, "u_shadowXf", xf4)
    Shaders.send(shader, "u_shadowOn", poolsOnly and 0 or 1)
    Shaders.send(shader, "u_poolOn", poolsOnly and 1 or 0)
  else
    local b = Shaders.blank()
    if b then Shaders.send(shader, "u_shadow", b) end
    xf4[1], xf4[2], xf4[3], xf4[4] = 0, 0, 0, 0
    Shaders.send(shader, "u_shadowXf", xf4)
    Shaders.send(shader, "u_shadowOn", 0)
    Shaders.send(shader, "u_poolOn", 0)
  end
end

local function emissiveHoist(shader, image)
  local c = cacheFor(shader)
  if image then
    sendS(c, shader, "u_emit", image)
    sendS(c, shader, "u_emitOn", 1)
  else
    local b = Shaders.blank()
    if b then sendS(c, shader, "u_emit", b) end
    sendS(c, shader, "u_emitOn", 0)
  end
end

local size2 = { 0, 0 }
local function texSizeScratch(shader, image)
  local w, h = 0, 0
  if image and image.getDimensions then
    local ok, a, b = pcall(image.getDimensions, image)
    if ok then w, h = a, b end
  end
  size2[1], size2[2] = w, h
  Shaders.send(shader, "u_texSize", size2)
end

Shaders.DARK_KINDS = {"OPAQUE","CUTOUT"}
local darkCenter = {0,0}
local radialUniform = {0,0,0,0}
-- Every pass resets the state; map-record centers subtract the same translation
-- as rec.mvp, while world-space cards/sea use the original center.
-- Battle-only world-coordinate seam: connected maps draw local vertices
-- through a translated MVP. Other passes start at root origin, never inherit
-- the previous map's cut origin. Ordinary field shaders receive nothing.
local cutOrigin={0,0,0}
function Shaders.dark(shader,env,rec)
  FogBackdrop.send(shader,env,rec)
  local cut=Shaders.override
  if cut and (shader==cut.OPAQUE or shader==cut.CUTOUT)then
    cutOrigin[1],cutOrigin[2],cutOrigin[3]=rec and rec.ox or 0,0,rec and rec.oz or 0
    Shaders.send(shader,"u_cutOrigin",cutOrigin)
  end
  local r=env and env.radialFog
  radialUniform[1]=r and r[1]-(rec and rec.ox or 0) or 0
  radialUniform[2]=r and r[2]-(rec and rec.oz or 0) or 0
  radialUniform[3],radialUniform[4]=r and r[3] or 0,r and r[4] or 0
  if Perf.hoist then sendT(cacheFor(shader),shader,"u_radialFog",radialUniform)
  else Shaders.send(shader,"u_radialFog",radialUniform) end
  local d=env and env.dark
  local c=Perf.hoist and cacheFor(shader) or nil
  if c then
    sendS(c,shader,"u_darkOn",d~=nil)
    sendS(c,shader,"u_darkR",d and d.radiusTiles or 0)
  else
    Shaders.send(shader,"u_darkOn",d~=nil)
    Shaders.send(shader,"u_darkR",d and d.radiusTiles or 0)
  end
  darkCenter[1]=d and d.center[1]-(rec and rec.ox or 0) or 0
  darkCenter[2]=d and d.center[2]-(rec and rec.oz or 0) or 0
  if c then sendT(c,shader,"u_darkC",darkCenter)
  else Shaders.send(shader,"u_darkC",darkCenter) end
end
local WORLD_ONE,WORLD_ZERO={1,1,1},{0,0,0}
function Shaders.frame(shader, env, alphaCut)
  V.require("render/FrlgTreeLod").disable(shader)
  local wl=env.worldLighting
  if Perf.hoist then
    local c=cacheFor(shader);sendT(c,shader,'u_worldMul',wl and wl.mul or WORLD_ONE);sendT(c,shader,'u_worldAdd',wl and wl.add or WORLD_ZERO)
  else
    Shaders.send(shader,'u_worldMul',wl and wl.mul or WORLD_ONE);Shaders.send(shader,'u_worldAdd',wl and wl.add or WORLD_ZERO)
  end
  Shaders.dark(shader,env)
  if Perf.hoist then return frameHoist(shader, env, alphaCut) end
  return frameLab52(shader, env, alphaCut)
end
function Shaders.shadow(shader, image, sx, sz, ox, oz, poolsOnly)
  if Perf.hoist then return shadowHoist(shader, image, sx, sz, ox, oz, poolsOnly) end
  if Perf.scratch then return shadowScratch(shader, image, sx, sz, ox, oz, poolsOnly) end
  return shadowLab52(shader, image, sx, sz, ox, oz, poolsOnly)
end
function Shaders.emissive(shader, image)
  if Perf.hoist then return emissiveHoist(shader, image) end
  return emissiveLab52(shader, image)
end
function Shaders.ao(shader, on)
  if Perf.hoist then return sendS(cacheFor(shader), shader, "u_aoOn", on and 1 or 0) end
  return aoLab52(shader, on)
end
function Shaders.texSize(shader, image)
  if Perf.scratch then return texSizeScratch(shader, image) end
  return texSizeLab52(shader, image)
end

function Shaders.release()
  for k, s in pairs(compiled) do
    if s.release then pcall(s.release, s) end
    compiled[k] = nil
  end
  for k in pairs(failed) do failed[k] = nil end
  Shaders.invalidateCache() -- Lab 55
end

Shaders.OPAQUE=FogBackdrop.decorate(Shaders.OPAQUE)
Shaders.CUTOUT=FogBackdrop.decorate(Shaders.CUTOUT)
local GrassDeform=V.require("grass/GrassDeform")
Shaders.OPAQUE=GrassDeform.decorate(Shaders.OPAQUE)
Shaders.CUTOUT=GrassDeform.decorate(Shaders.CUTOUT)
Shaders.CUTOUT=V.require("render/FrlgTreeLod").decorate(Shaders.CUTOUT)
return Shaders
