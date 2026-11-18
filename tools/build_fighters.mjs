// Builds assets/fighters/{viper,anvil}.glb + data/clips.json from _source/.
//   node tools/build_fighters.mjs [viper|anvil ...]
//
// What it does (see the long comments inline):
//  1. The DAZ exports already share ONE joint hierarchy between all 7 skins (the same node indices appear in every
//     skin's `joints`); the ~1700 other nodes are dead copies ("Pos/Hint/LHWaist", duplicate rigs, helmet, shorts...).
//     We drop everything that is neither a joint, an ancestor of one, nor a skinned mesh node.
//  2. Wraps the scene in a "Fighter" root node carrying the normalisation (1.8 m tall, idle soles on y=0, pelvis XZ at
//     origin, facing +Z). Bone data is untouched, so inverse bind matrices stay valid (every vertex is
//     rootWorld * jointWorld * IBM * v, and the root only multiplies the whole thing).
//  3. Embeds one glTF animation per kept clip of animations.json (+ baked defence clips from defense.json).
//
// Animation conversion (verified against web/js/arena3d.js sampleClip/samplePosition, line ~692-740):
//   source sample = quat(x,y,z,w) pos(x,y,z) in Unity left-handed space;
//   three/glTF local quat = (x,-y,-z,w), local position = (-x,y,z). They are ABSOLUTE local values that REPLACE the
//   bone's node rotation / translation (not deltas over rest) and are applied to all 31 ANIM_BONES.
//   Frames are evenly spaced over the clip: frame i at i*duration/(frames-1) (the web samples tNorm*(frames-1)).
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(ROOT, '_source');
const OUT = path.join(ROOT, 'assets', 'fighters');
const TARGET_HEIGHT = 1.8;
const IDLE_CLIP = 'KB_Idle_1';

// ---------------------------------------------------------------- clip selection
const JUNK = /dance|dancing|hip hop|twerk|wheelchair|guitar|baseball|magic spell|vampiric|shopping cart|chicken|rapping|mime_in|swing dancing|snake hip|butterfly|electrocuted|^bindpose$|^customization$|^menu0$|fake_stair|cross jumps|walker walk|^unityasset::/i;
const LOOP = /(^|[_ ])idle|walk|loop|^kb_sidestep|run|strafe|block$|^h block|^lh block|^rh block|^fh block|bodyblock|^body block|^center block|shadow_boxing|speedbag|warming|crouch_idle|^leg block/i;
// "one-shot" overrides for things the loop regex would catch
const NOT_LOOP = /^kb_crouch_(start|end)|^crouch (in|out)|ko$|^kb_skip|^kb_dodge|taunt_|^up_yours|^kb_turn/i;

const sanitize = n => n.replace(/[\/:,\[\]]/g, '_');

// ---------------------------------------------------------------- tiny math (column-major mat4, like glTF)
const mIdent = () => { const m = new Float64Array(16); m[0] = m[5] = m[10] = m[15] = 1; return m; };
function mTRS(t, q, s) {
  const [x, y, z, w] = q, x2 = x + x, y2 = y + y, z2 = z + z;
  const xx = x * x2, xy = x * y2, xz = x * z2, yy = y * y2, yz = y * z2, zz = z * z2, wx = w * x2, wy = w * y2, wz = w * z2;
  const m = new Float64Array(16);
  m[0] = (1 - (yy + zz)) * s[0]; m[1] = (xy + wz) * s[0]; m[2] = (xz - wy) * s[0];
  m[4] = (xy - wz) * s[1]; m[5] = (1 - (xx + zz)) * s[1]; m[6] = (yz + wx) * s[1];
  m[8] = (xz + wy) * s[2]; m[9] = (yz - wx) * s[2]; m[10] = (1 - (xx + yy)) * s[2];
  m[12] = t[0]; m[13] = t[1]; m[14] = t[2]; m[15] = 1;
  return m;
}
function mMul(a, b) {
  const o = new Float64Array(16);
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) {
    let s = 0; for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
    o[c * 4 + r] = s;
  }
  return o;
}
const qNorm = q => { const l = Math.hypot(q[0], q[1], q[2], q[3]) || 1; return [q[0] / l, q[1] / l, q[2] / l, q[3] / l]; };
const uq = (d, o) => qNorm([d[o], -d[o + 1], -d[o + 2], d[o + 3]]); // Unity -> glTF quaternion
const up = (d, o) => [-d[o], d[o + 1], d[o + 2]];                    // Unity -> glTF position

// ---------------------------------------------------------------- GLB io
function readGlb(file) {
  const b = fs.readFileSync(file);
  const jl = b.readUInt32LE(12);
  const json = JSON.parse(b.subarray(20, 20 + jl).toString('utf8'));
  const bl = b.readUInt32LE(20 + jl);
  const bin = b.subarray(28 + jl, 28 + jl + bl);
  return { json, bin };
}
function writeGlb(file, json, bin) {
  let js = Buffer.from(JSON.stringify(json), 'utf8');
  js = Buffer.concat([js, Buffer.alloc((4 - js.length % 4) % 4, 0x20)]);
  const bn = Buffer.concat([bin, Buffer.alloc((4 - bin.length % 4) % 4)]);
  const head = Buffer.alloc(12); head.write('glTF', 0); head.writeUInt32LE(2, 4);
  head.writeUInt32LE(12 + 8 + js.length + 8 + bn.length, 8);
  const ch = (len, type) => { const h = Buffer.alloc(8); h.writeUInt32LE(len, 0); h.write(type, 4, 'latin1'); return h; };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, Buffer.concat([head, ch(js.length, 'JSON'), js, ch(bn.length, 'BIN\0'), bn]));
}
const COMP = { 5120: [Int8Array, 1], 5121: [Uint8Array, 1], 5122: [Int16Array, 2], 5123: [Uint16Array, 2], 5125: [Uint32Array, 4], 5126: [Float32Array, 4] };
const NCOMP = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT4: 16 };
function readAccessor(json, bin, idx) {
  const a = json.accessors[idx], v = json.bufferViews[a.bufferView];
  const [Ctor, size] = COMP[a.componentType], n = NCOMP[a.type];
  const stride = v.byteStride || size * n, base = (v.byteOffset || 0) + (a.byteOffset || 0);
  const out = new Float64Array(a.count * n);
  const dv = new DataView(bin.buffer, bin.byteOffset, bin.byteLength);
  const get = { 5120: 'getInt8', 5121: 'getUint8', 5122: 'getInt16', 5123: 'getUint16', 5125: 'getUint32', 5126: 'getFloat32' }[a.componentType];
  const norm = a.normalized ? { 5121: 255, 5123: 65535, 5120: 127, 5122: 32767 }[a.componentType] : 1;
  for (let i = 0; i < a.count; i++) for (let k = 0; k < n; k++) {
    out[i * n + k] = (size === 1 ? dv[get](base + i * stride + k) : dv[get](base + i * stride + k * size, true)) / norm;
  }
  return out;
}

// ---------------------------------------------------------------- source animation data
const animMeta = JSON.parse(fs.readFileSync(path.join(SRC, 'data', 'animations.json'), 'utf8'));
const samplesBuf = zlib.gunzipSync(fs.readFileSync(path.join(SRC, 'data', 'animation-samples.bin.gz')));
const samples = new Float32Array(samplesBuf.buffer, samplesBuf.byteOffset, samplesBuf.byteLength / 4);
const defense = JSON.parse(fs.readFileSync(path.join(SRC, 'data', 'defense.json'), 'utf8'));
const BONES = animMeta.boneNames; // 31
const FPB = animMeta.fieldsPerBone; // 7
const keptClips = Object.entries(animMeta.clips).filter(([n]) => !JUNK.test(n) && !n.startsWith('UnityAsset::'));

function clipFrames(c) {
  // returns per-frame arrays: q[frame][bone] = [x,y,z,w] (gltf space), p[frame][bone] = [x,y,z]
  const q = [], p = [];
  for (let f = 0; f < c.frames; f++) {
    const qf = [], pf = [];
    for (let b = 0; b < BONES.length; b++) {
      const o = c.offset + (f * BONES.length + b) * FPB;
      qf.push(uq(samples, o)); pf.push(up(samples, o + 4));
    }
    q.push(qf); p.push(pf);
  }
  // hemisphere continuity per bone
  for (let f = 1; f < c.frames; f++) for (let b = 0; b < BONES.length; b++) {
    const a = q[f - 1][b], r = q[f][b];
    if (a[0] * r[0] + a[1] * r[1] + a[2] * r[2] + a[3] * r[3] < 0) q[f][b] = [-r[0], -r[1], -r[2], -r[3]];
  }
  return { q, p };
}
// sample a clip at normalised phase (web: tNorm*(frames-1)) — nlerp is plenty here
function sampleAt(fr, frames, phase, b) {
  const t = Math.max(0, Math.min(1, phase)) * (frames - 1), i0 = Math.floor(t), i1 = Math.min(frames - 1, i0 + 1), a = t - i0;
  const q0 = fr.q[i0][b], q1 = fr.q[i1][b];
  const q = qNorm(q0.map((v, k) => v + (q1[k] - v) * a));
  const p = fr.p[i0][b].map((v, k) => v + (fr.p[i1][b][k] - v) * a);
  return { q, p };
}

// ---------------------------------------------------------------- per-fighter build
function buildFighter(name) {
  const { json: src, bin: srcBin } = readGlb(path.join(SRC, 'fighters', name + '.glb'));
  const parent = new Array(src.nodes.length).fill(-1);
  src.nodes.forEach((n, i) => (n.children || []).forEach(c => { parent[c] = i; }));

  // --- which skin is the body? (its joint list is a superset of all other skins; verify)
  const bodyMeshNode = src.nodes.findIndex(n => n.skin !== undefined && (n.name || '').startsWith('M3DMale_LOD0'));
  const bodySkinIdx = src.nodes[bodyMeshNode].skin;
  const bodyJoints = new Set(src.skins[bodySkinIdx].joints);
  for (const s of src.skins) for (const j of s.joints) if (!bodyJoints.has(j)) throw new Error(`${name}: clothing joint ${src.nodes[j].name} missing from body skin`);
  // --- joints identical across skins (same node indices) => single hierarchy already; just drop the dead nodes.
  const keep = new Set();
  const markUp = i => { for (let p = i; p >= 0 && !keep.has(p); p = parent[p]) keep.add(p); };
  src.skins.forEach(s => s.joints.forEach(markUp));
  const meshNodes = src.nodes.map((n, i) => i).filter(i => src.nodes[i].mesh !== undefined);
  const jointSet = new Set(src.skins.flatMap(s => s.joints));
  // Armature node = nearest non-joint ancestor of 'hip'
  const hipNode = src.skins[bodySkinIdx].joints.find(j => src.nodes[j].name === 'hip');
  const armatureOld = parent[hipNode];

  // --- new node list: [0]=Fighter root, then armature subtree, then every mesh node flattened under the root
  const newIndex = new Map();
  const nodes = [];
  const root = { name: 'Fighter', children: [] };
  nodes.push(root);
  const addTree = old => {
    const n = src.nodes[old];
    const idx = nodes.length; newIndex.set(old, idx);
    const o = { name: n.name };
    if (n.translation) o.translation = n.translation;
    if (n.rotation) o.rotation = n.rotation;
    if (n.scale) o.scale = n.scale;
    nodes.push(o);
    const kids = (n.children || []).filter(c => keep.has(c) && !meshNodes.includes(c) && (jointSet.has(c) || hasJointDesc(c)));
    if (kids.length) o.children = kids.map(addTree);
    return idx;
  };
  const jointDescCache = new Map();
  function hasJointDesc(i) {
    if (jointDescCache.has(i)) return jointDescCache.get(i);
    const r = jointSet.has(i) || (src.nodes[i].children || []).some(hasJointDesc);
    jointDescCache.set(i, r); return r;
  }
  const armIdx = addTree(armatureOld);
  root.children.push(armIdx);
  const meshOut = [];
  for (const old of meshNodes) {
    const idx = nodes.length; newIndex.set(old, idx);
    const n = src.nodes[old];
    nodes.push({ name: n.name, mesh: n.mesh, skin: n.skin });
    root.children.push(idx); meshOut.push(idx);
  }
  const jointNames = new Map([...jointSet].map(j => [src.nodes[j].name, newIndex.get(j)]));
  if (jointNames.size !== jointSet.size) throw new Error(name + ': duplicate joint names');

  // --- skins: same joints, remapped; skeleton = armature
  const skins = src.skins.map(s => ({ ...s, joints: s.joints.map(j => newIndex.get(j)), skeleton: armIdx }));

  // --- FK helpers on the NEW node list
  const nodeParent = new Array(nodes.length).fill(-1);
  nodes.forEach((n, i) => (n.children || []).forEach(c => { nodeParent[c] = i; }));
  const order = []; // parents before children
  (function walk(i) { order.push(i); (nodes[i].children || []).forEach(walk); })(0);
  const restT = nodes.map(n => n.translation || [0, 0, 0]);
  const restQ = nodes.map(n => n.rotation || [0, 0, 0, 1]);
  const worlds = (T, Q) => {
    const w = new Array(nodes.length);
    for (const i of order) {
      const l = mTRS(T[i], Q[i], nodes[i].scale || [1, 1, 1]);
      w[i] = nodeParent[i] >= 0 ? mMul(w[nodeParent[i]], l) : l;
    }
    return w;
  };
  const boneIdx = BONES.map(b => { const i = jointNames.get(b); if (i === undefined) throw new Error(name + ': missing bone ' + b); return i; });

  // --- body vertex data for sizing / floor
  const bodyMesh = src.meshes[src.nodes[bodyMeshNode].mesh];
  const bodySkin = src.skins[bodySkinIdx];
  const ibm = readAccessor(src, srcBin, bodySkin.inverseBindMatrices);
  const prims = bodyMesh.primitives.map(p => ({
    pos: readAccessor(src, srcBin, p.attributes.POSITION),
    jts: readAccessor(src, srcBin, p.attributes.JOINTS_0),
    wts: readAccessor(src, srcBin, p.attributes.WEIGHTS_0),
  }));
  // Rest-pose bbox over ALL meshes (what the web's Box3.setFromObject does: model scale = 1.8/height).
  let minY = Infinity, maxY = -Infinity;
  for (const m of src.meshes) for (const p of m.primitives) {
    const a = src.accessors[p.attributes.POSITION]; minY = Math.min(minY, a.min[1]); maxY = Math.max(maxY, a.max[1]);
  }
  const scale = TARGET_HEIGHT / (maxY - minY);

  const skinnedMinY = (T, Q) => {
    const w = worlds(T, Q);
    const sk = bodySkin.joints.map((j, k) => mMul(w[newIndex.get(j)], ibm.subarray(k * 16, k * 16 + 16)));
    let lo = Infinity;
    for (const pr of prims) for (let i = 0; i < pr.pos.length / 3; i++) {
      let y = 0;
      for (let k = 0; k < 4; k++) {
        const wt = pr.wts[i * 4 + k]; if (!wt) continue;
        const m = sk[pr.jts[i * 4 + k]], x0 = pr.pos[i * 3], y0 = pr.pos[i * 3 + 1], z0 = pr.pos[i * 3 + 2];
        y += wt * (m[1] * x0 + m[5] * y0 + m[9] * z0 + m[13]);
      }
      if (y < lo) lo = y;
    }
    return lo;
  };
  // idle pose frame 0 of KB_Idle_1 for the floor
  const idleClip = animMeta.clips[IDLE_CLIP];
  const idleFr = clipFrames(idleClip);
  const poseT = restT.map(t => t.slice()), poseQ = restQ.map(q => q.slice());
  BONES.forEach((b, bi) => { poseQ[boneIdx[bi]] = idleFr.q[0][bi]; poseT[boneIdx[bi]] = idleFr.p[0][bi]; });
  const restFloor = skinnedMinY(restT, restQ), idleFloor = skinnedMinY(poseT, poseQ);
  // pelvis XZ in the rest pose (web centres the rig on its pelvis at load time)
  const wRest = worlds(restT, restQ), pel = wRest[jointNames.get('pelvis')];
  const px = pel[12], pz = pel[14];
  root.scale = [scale, scale, scale];
  root.translation = [-px * scale, -idleFloor * scale, -pz * scale];
  console.log(`${name}: rest height ${(maxY - minY).toFixed(4)} -> scale ${scale.toFixed(4)}; rest floor ${restFloor.toFixed(4)}, idle floor ${idleFloor.toFixed(4)}; pelvis xz ${px.toFixed(3)},${pz.toFixed(3)}`);

  // --- output accessors/bufferViews: copy the originals, append animation data
  const json = {
    asset: { version: '2.0', generator: 'KnockNight build_fighters.mjs' },
    scene: 0, scenes: [{ name: 'Fighter', nodes: [0] }],
    nodes, skins,
    meshes: src.meshes, materials: src.materials, textures: src.textures, images: src.images, samplers: src.samplers,
    accessors: src.accessors.slice(), bufferViews: src.bufferViews.slice(), buffers: [{ byteLength: 0 }],
    animations: [],
  };
  for (const k of Object.keys(json)) if (json[k] === undefined) delete json[k];
  const chunks = [Buffer.from(srcBin)];
  let binLen = srcBin.length;
  const addView = (f32, count, type, withMinMax) => {
    const buf = Buffer.from(f32.buffer, f32.byteOffset, f32.byteLength);
    const pad = (4 - binLen % 4) % 4; if (pad) { chunks.push(Buffer.alloc(pad)); binLen += pad; }
    json.bufferViews.push({ buffer: 0, byteOffset: binLen, byteLength: buf.length });
    chunks.push(buf); binLen += buf.length;
    const acc = { bufferView: json.bufferViews.length - 1, componentType: 5126, count, type };
    if (withMinMax) { acc.min = [Math.min(...f32)]; acc.max = [Math.max(...f32)]; }
    json.accessors.push(acc); return json.accessors.length - 1;
  };

  const stats = {};
  const meta = [];
  // isConstTranslation: true if a bone's translation is within eps of its node rest all through the clip -> omit track
  const EPS = 1e-4;
  let omittedT = 0, keptT = 0;
  function addAnimation(animName, duration, frames, getQ, getP, hipOnlyPos) {
    const times = new Float32Array(frames);
    for (let f = 0; f < frames; f++) times[f] = frames > 1 ? f * duration / (frames - 1) : 0;
    const tAcc = addView(times, frames, 'SCALAR', true);
    const samplersOut = [], channels = [];
    for (let bi = 0; bi < BONES.length; bi++) {
      const node = boneIdx[bi];
      const qa = new Float32Array(frames * 4);
      for (let f = 0; f < frames; f++) qa.set(getQ(f, bi), f * 4);
      samplersOut.push({ input: tAcc, output: addView(qa, frames, 'VEC4'), interpolation: 'LINEAR' });
      channels.push({ sampler: samplersOut.length - 1, target: { node, path: 'rotation' } });
      const pTrack = getP && (!hipOnlyPos || BONES[bi] === 'hip');
      if (pTrack) {
        let moving = false;
        const pa = new Float32Array(frames * 3);
        for (let f = 0; f < frames; f++) {
          const pv = getP(f, bi); pa.set(pv, f * 3);
          for (let k = 0; k < 3; k++) if (Math.abs(pv[k] - restT[node][k]) > EPS) moving = true;
        }
        if (moving || BONES[bi] === 'hip') {
          samplersOut.push({ input: tAcc, output: addView(pa, frames, 'VEC3'), interpolation: 'LINEAR' });
          channels.push({ sampler: samplersOut.length - 1, target: { node, path: 'translation' } });
          keptT++;
        } else omittedT++;
      }
    }
    json.animations.push({ name: animName, samplers: samplersOut, channels });
  }

  const usedNames = new Set();
  const uniq = n => { let s = sanitize(n), k = 2; while (usedNames.has(s)) s = sanitize(n) + '_' + k++; usedNames.add(s); return s; };

  for (const [cname, c] of keptClips) {
    const fr = clipFrames(c);
    const aname = uniq(cname);
    addAnimation(aname, c.duration, c.frames, (f, b) => fr.q[f][b], (f, b) => fr.p[f][b], false);
    // hip travel in fighter metres: x -> fighter right/left (+X = fighter's left), z -> forward (+Z)
    const hb = BONES.indexOf('hip'); let maxD = 0, minY2 = Infinity, maxY2 = -Infinity;
    const h0 = fr.p[0][hb], h1 = fr.p[c.frames - 1][hb];
    for (let f = 0; f < c.frames; f++) {
      const h = fr.p[f][hb]; maxD = Math.max(maxD, Math.hypot(h[0] - h0[0], h[2] - h0[2]));
      minY2 = Math.min(minY2, h[1]); maxY2 = Math.max(maxY2, h[1]);
    }
    const r = v => Math.round(v * scale * 10000) / 10000;
    const net = Math.hypot(h1[0] - h0[0], h1[2] - h0[2]);
    meta.push({
      name: aname, source: cname, tag: c.tag, duration: c.duration, frames: c.frames, fps: 30,
      loop: LOOP.test(cname) && !NOT_LOOP.test(cname),
      hip: {
        start: [r(h0[0]), r(h0[1]), r(h0[2])],
        endDelta: [r(h1[0] - h0[0]), r(h1[1] - h0[1]), r(h1[2] - h0[2])],
        netXZ: r(net), maxXZ: r(maxD), yMin: r(minY2), yMax: r(maxY2),
        rootTravel: r(maxD) > 0.25,
      },
    });
  }

  // --- baked authored defence clips ('driver' rig = the DAZ viper/anvil skeleton; roster-a/b/c are the Meshy rigs)
  const drv = defense.rigs.driver;
  const baseC = animMeta.clips[defense.baseClip], baseFr = clipFrames(baseC);
  const hb = BONES.indexOf('hip');
  const baseHip = sampleAt(baseFr, baseC.frames, defense.basePhase, hb).p; // glTF-space hip position of neutral source
  // Defence quaternions are web/glTF-space local quats keyed by drv.bones; hip is a DELTA in fighter-local metres
  // (defense-motion.js: hipGoal = hipNow + frame.hip * rootScale), where rootScale there == our `scale`.
  const dBoneIdx = drv.bones.map(b => jointNames.get(b));
  const defMeta = [];
  const bakeDef = (dname, track, samplesArr, frames, duration, loop, extra) => {
    const stride = track.stride;
    const q = [], hip = [];
    for (let f = 0; f < frames; f++) {
      hip.push([samplesArr[f * stride], samplesArr[f * stride + 1], samplesArr[f * stride + 2]]);
      q.push(drv.bones.map((_, j) => { const o = f * stride + 3 + j * 4; return qNorm([samplesArr[o], samplesArr[o + 1], samplesArr[o + 2], samplesArr[o + 3]]); }));
    }
    for (let f = 1; f < frames; f++) for (let j = 0; j < drv.bones.length; j++) {
      const a = q[f - 1][j], r = q[f][j];
      if (a[0] * r[0] + a[1] * r[1] + a[2] * r[2] + a[3] * r[3] < 0) q[f][j] = [-r[0], -r[1], -r[2], -r[3]];
    }
    // map to the BONES order used by addAnimation; bones absent from the defence rig keep the neutral-source pose
    const qOf = (f, bi) => { const j = drv.bones.indexOf(BONES[bi]); return j >= 0 ? q[f][j] : sampleAt(baseFr, baseC.frames, defense.basePhase, bi).q; };
    const pOf = (f, bi) => { const d = hip[f]; return [baseHip[0] + d[0] / scale, baseHip[1] + d[1] / scale, baseHip[2] + d[2] / scale]; };
    const aname = uniq(dname);
    addAnimation(aname, duration, frames, qOf, pOf, true);
    const r4 = v => Math.round(v * 10000) / 10000, hl = hip[frames - 1];
    // defence hip values are DELTAS (metres, fighter space) from the neutral hip (Idle @ phase 0.2), not absolute positions
    const hipMeta = { deltaFromNeutral: true, endDelta: hl.map(r4), maxXZ: r4(Math.max(...hip.map(h => Math.hypot(h[0], h[2])))),
      yMin: r4(Math.min(...hip.map(h => h[1]))), yMax: r4(Math.max(...hip.map(h => h[1]))), rootTravel: false };
    defMeta.push({ name: aname, duration, frames, fps: Math.round((frames - 1) / duration), loop, defense: true, hip: hipMeta, ...extra });
  };
  for (const [dn, t] of Object.entries(drv.clips)) {
    bakeDef('DEF_' + dn, t, t.samples, t.frames, t.duration, false,
      { in: t.in, peakEnd: t.peakEnd, out: t.out, maxHold: t.maxHold, headInheritance: t.headInheritance, holdClip: t.hold.frames > 1 ? 'DEF_' + dn + '_hold' : null,
        isCounter: dn.startsWith('counter_') });
    if (t.hold.frames > 1) bakeDef('DEF_' + dn + '_hold', t, t.hold.samples, t.hold.frames, t.hold.duration, true, { holdOf: 'DEF_' + dn });
  }
  console.log(`${name}: ${meta.length} source clips + ${defMeta.length} defence clips; translation tracks kept ${keptT}, omitted (constant == rest) ${omittedT}`);

  json.buffers[0].byteLength = binLen;
  const outFile = path.join(OUT, name + '.glb');
  writeGlb(outFile, json, Buffer.concat(chunks));
  console.log(`${name}: wrote ${outFile} (${(fs.statSync(outFile).size / 1e6).toFixed(1)} MB, ${nodes.length} nodes, ${skins.length} skins)`);
  return { meta, defMeta, scale, idleFloor, bones: BONES };
}

const wanted = process.argv.slice(2).length ? process.argv.slice(2) : ['viper', 'anvil'];
let first = null;
for (const n of wanted) { const r = buildFighter(n); first ||= r; }
// clips.json is identical for both fighters (same animation source) except the normalisation scale, which differs by <2%.
const clipsJson = {
  note: 'Hip values are metres in fighter space after normalisation (+Z forward, +X = fighter left, Y up), measured on the first fighter built (' + wanted[0] + '). Clip time = frame * duration/(frames-1).',
  rootNode: 'Fighter', skeleton: 'Skeleton3D', idleFloorClip: IDLE_CLIP,
  bones: { hands: ['lHand', 'rHand'], feet: ['lFoot', 'rFoot'], toes: ['lMetatarsals', 'rMetatarsals'], head: 'head', pelvis: 'pelvis', hip: 'hip' },
  clips: Object.fromEntries([...first.meta, ...first.defMeta].map(m => [m.name, m])),
};
fs.mkdirSync(path.join(ROOT, 'data'), { recursive: true });
fs.writeFileSync(path.join(ROOT, 'data', 'clips.json'), JSON.stringify(clipsJson, null, 1));
console.log('wrote data/clips.json with', Object.keys(clipsJson.clips).length, 'clips');
