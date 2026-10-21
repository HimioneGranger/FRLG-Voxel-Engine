-- Shared by the native world shaders and the interactive verification preview.
-- Feet and roots are in the same map-local cell units. The authored flex value
-- works for flat leaves as well as upright ones; world height is not a weight.
local M = { VERSION = "grass-deform-2-segments", MAX_HORIZONTAL_DISPLACEMENT = .18 }
M.GLSL = [[
uniform highp vec4 u_grassPositions[4];
uniform highp vec4 u_grassDirections[4];
uniform highp vec4 u_grassBody;
uniform highp vec4 u_grassVelocity;
uniform highp float u_grassRadius;
uniform highp float u_grassVerticalGate;
uniform mediump float u_grassOn;

vec3 grassInfluence(vec3 root, vec4 foot, vec2 direction) {
  vec2 delta = root.xz - foot.xz;
  float distanceToFoot = length(delta);
  float falloff = clamp(1.0 - distanceToFoot / max(u_grassRadius, 0.01), 0.0, 1.0);
  falloff = falloff * falloff * (3.0 - 2.0 * falloff);
  float vertical = 1.0 - smoothstep(u_grassVerticalGate * 0.45,
                                    u_grassVerticalGate, abs(root.y - foot.y));
  float weight = falloff * vertical * foot.w;
  vec2 away = delta / max(distanceToFoot, 0.015);
  vec2 push = away * 0.78 + direction * 0.34;
  push /= max(1.0, length(push));
  return vec3(push * weight, weight);
}

vec3 grassSegment(vec3 root, vec4 start, vec4 finish) {
  vec3 delta = finish.xyz - start.xyz;
  float d2 = dot(delta.xz, delta.xz);
  float along = d2 > 0.000001 ? clamp(dot(root.xz - start.xz, delta.xz) / d2, 0.0, 1.0) : 0.0;
  vec4 foot = vec4(mix(start.xyz, finish.xyz, along), start.w);
  vec2 direction = delta.xz / max(sqrt(d2), 0.0001);
  return grassInfluence(root, foot, direction);
}

void grassBend(inout vec3 point, inout vec3 normal, vec3 root, float flex) {
  // 0 ordinary geometry; 1 reactive grass; 2 resting grass (retain leaf shade).
  if (u_grassOn < 0.5 || u_grassOn > 1.5 || flex <= 0.0) return;
  vec3 total = grassInfluence(root, u_grassBody, u_grassVelocity.xz *
                            clamp(u_grassVelocity.w, 0.0, 1.0));
  for (int i = 0; i < 4; i++) {
    total += grassSegment(root, u_grassPositions[i], u_grassDirections[i]);
  }
  vec2 push = total.xy / max(1.0, total.z);
  float amount = min(length(push), 1.0);
  // Preserve authored positions/normals exactly outside every influence.
  // Reconstructing Y or normalizing again can change resting edge pixels.
  if (amount <= 0.0) return;
  float weight = clamp(flex, 0.0, 1.0);
  weight *= weight;
  point.xz += push * (0.18 * weight);
  float compress = 1.0 - 0.45 * amount * weight;
  point.y = root.y + (point.y - root.y) * compress;
  // Stable lighting approximation for the compressed leaf surface. This avoids
  // rigidly retaining an upright highlight while a leaf is pressed down.
  normal = normalize(normal / vec3(1.0, compress, 1.0));
}
]]

local function replaceOnce(source, needle, replacement)
  local start, stop = source:find(needle, 1, true)
  assert(start, "Retro grass shader seam missing: " .. needle)
  assert(not source:find(needle, stop + 1, true), "Retro grass shader seam ambiguous")
  return source:sub(1, start - 1) .. replacement .. source:sub(stop + 1)
end

-- Decorate before battle/portal/tree source factories derive their variants.
-- Keep their original position/effect declarations and v_uv assignment intact.
function M.decorate(source)
  local prefix = "varying mediump float v_grassShade;\n#ifdef VERTEX\n"
    .. "attribute vec3 VertexGrassRoot;\nattribute float VertexGrassFlex;\n"
    .. "attribute float VertexGrassShade;\nattribute vec3 VertexGrassOffset;\n" .. M.GLSL .. "\n#endif\n"
  source = replaceOnce(source, "  v_uv = VertexTexCoord.xy;",
    "  vec3 grassOffset = u_grassOn > 0.5 ? VertexGrassOffset : vec3(0.0);\n"
    .. "  vec3 grassPoint = vertex_position.xyz + grassOffset;\n"
    .. "  vec3 grassNormal = VertexNormal;\n"
    .. "  grassBend(grassPoint, grassNormal, VertexGrassRoot + grassOffset, VertexGrassFlex);\n"
    .. "  vertex_position.xyz = grassPoint;\n"
    .. "  v_grassShade = u_grassOn > 0.5 ? VertexGrassShade : 1.0;\n"
    .. "  v_uv = VertexTexCoord.xy;")
  source = replaceOnce(source, "length(VertexNormal)", "length(grassNormal)")
  source = replaceOnce(source, "VertexNormal / len", "grassNormal / len")
  source = replaceOnce(source, "  mediump vec4 c = TEX_HI(tex, v_uv) * color;",
    "  mediump vec4 c = TEX_HI(tex, v_uv) * color;\n  c.rgb *= v_grassShade;")
  return prefix .. source
end

local positions, directions, body = {}, {}, {0,0,0,0}
for i=1,4 do positions[i]={0,0,0,0};directions[i]={0,0,0,0} end
local unpack = unpack or table.unpack
function M.send(shader, u, ox, oz, active)
  if active==false then shader:send("u_grassOn",2);return end
  ox, oz = ox or 0, oz or 0
  for i=1,4 do
    local j=(i-1)*4
    positions[i][1]=u.positions[j+1]-ox
    positions[i][2]=u.positions[j+2]
    positions[i][3]=u.positions[j+3]-oz
    positions[i][4]=u.positions[j+4]
    -- Both ends are positions, not a normalized direction; translate both.
    directions[i][1]=u.directions[j+1]-ox
    directions[i][2]=u.directions[j+2]
    directions[i][3]=u.directions[j+3]-oz
    directions[i][4]=u.directions[j+4]
  end
  body[1],body[2],body[3],body[4]=u.body[1]-ox,u.body[2],u.body[3]-oz,u.body[4]
  shader:send("u_grassPositions", unpack(positions))
  shader:send("u_grassDirections", unpack(directions))
  shader:send("u_grassBody", body)
  shader:send("u_grassVelocity", u.velocity)
  shader:send("u_grassRadius", u.radius)
  shader:send("u_grassVerticalGate", u.verticalGate)
  shader:send("u_grassOn", 1)
end
-- Conservative whole-chunk rejection. Swept segments are tested as boxes so
-- diagonal paths may do extra work, but can never miss a touched plant.
function M.affects(u,x0,y0,z0,x1,y1,z1)
  local r,h=u.radius,u.verticalGate
  local b=u.body
  if b[4]>0 and b[1]+r>=x0 and b[1]-r<=x1 and b[3]+r>=z0 and b[3]-r<=z1 and b[2]+h>=y0 and b[2]-h<=y1 then return true end
  local a,e=u.positions,u.directions
  for j=1,13,4 do
    if a[j+3]>0 and math.max(a[j],e[j])+r>=x0 and math.min(a[j],e[j])-r<=x1
      and math.max(a[j+2],e[j+2])+r>=z0 and math.min(a[j+2],e[j+2])-r<=z1
      and math.max(a[j+1],e[j+1])+h>=y0 and math.min(a[j+1],e[j+1])-h<=y1 then return true end
  end
  return false
end
function M.disable(shader)
  if shader and shader:hasUniform("u_grassOn") then shader:send("u_grassOn",0) end
end
return M
