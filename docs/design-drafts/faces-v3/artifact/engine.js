'use strict';
const DPR = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
const L = 600, PX = Math.round(L * DPR);
const FONT = 'system-ui,-apple-system,&quot;SF Pro&quot;,&quot;PingFang TC&quot;,&quot;Helvetica Neue&quot;,sans-serif';
const ROUNDED = 'ui-rounded,&quot;SF Pro Rounded&quot;,system-ui,-apple-system,sans-serif';
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ---------- WebGL：桌布、模糊、玻璃 ---------- */
const GL = (() => {
  const cv = document.createElement('canvas');
  const gl = cv.getContext('webgl2', {premultipliedAlpha: false, preserveDrawingBuffer: true, antialias: false});
  if (!gl) return null;
  const HALF = !!gl.getExtension('EXT_color_buffer_float');   // 高度圖要 16 位，8 位會出現階梯
  const VS = `#version 300 es
  in vec2 aPos; uniform float uFlip; out vec2 vUv;
  void main(){ vUv = vec2(aPos.x*.5+.5, uFlip > .5 ? .5 - aPos.y*.5 : .5 + aPos.y*.5); gl_Position = vec4(aPos, 0., 1.); }`;
  const HEAD = `#version 300 es
  precision highp float; in vec2 vUv; out vec4 o;`;
  const NOISE = `
  float hash(vec2 p){ p = fract(p*vec2(123.34, 456.21)); p += dot(p, p+45.32); return fract(p.x*p.y); }
  float noise(vec2 p){ vec2 i = floor(p), f = fract(p); vec2 u = f*f*(3.-2.*f);
    return mix(mix(hash(i), hash(i+vec2(1,0)), u.x), mix(hash(i+vec2(0,1)), hash(i+vec2(1,1)), u.x), u.y); }
  float fbm(vec2 p){ float v = 0., a = .5; for (int i = 0; i < 6; i++){ v += a*noise(p); p = p*2.03 + vec2(17.1, 9.2); a *= .5; } return v; }
  float fbm3(vec2 p){ float v = 0., a = .5; for (int i = 0; i < 3; i++){ v += a*noise(p); p = p*2.03 + vec2(17.1, 9.2); a *= .5; } return v/.875; }`;
  const FS_WALL = HEAD + NOISE + `
  uniform int uKind; uniform float uSeed; uniform vec2 uRes;
  vec3 srgb(int r, int g, int b){ return vec3(float(r), float(g), float(b))/255.; }
  void main(){
    vec2 uv = vUv; vec3 c; vec2 s = vec2(uSeed);
    if (uKind == 0){            // 天空：上淺下深的藍，雲集中在上半，底部有幾縷
      c = mix(srgb(126,170,226), srgb(70,136,222), smoothstep(.0, 1., uv.y));
      c = mix(c, srgb(150,196,240), smoothstep(.55, 1., uv.y)*.55);
      vec2 p = uv*vec2(2.6, 3.4) + s;
      float warp = fbm(p*1.3 + 3.1);
      float d = fbm(p + vec2(warp*.7, warp*.25));
      float band = smoothstep(.62, .05, uv.y) + smoothstep(.70, .98, uv.y)*.55;
      float cl = smoothstep(.47, .78, d) * band;
      float lit = fbm(p + vec2(-.05, -.09));
      vec3 cloud = mix(srgb(178,190,208), srgb(252,253,255), smoothstep(.38, .72, lit));
      c = mix(c, cloud, clamp(cl*1.15, 0., 1.));
      float ray = smoothstep(.22, .0, abs(uv.x - .42 - (uv.y-.4)*.18)) * smoothstep(.35, .75, uv.y) * smoothstep(1., .7, uv.y);
      c += vec3(.10, .11, .12) * ray * .55;
    } else if (uKind == 1){     // Flow：薰衣草粉的外圈，中間一團藍粉漩渦
      vec2 p = (uv - .5)*2.;
      vec2 q = p + (vec2(fbm3(uv*1.4 + s), fbm3(uv*1.4 + s + 7.3)) - .5)*1.1;
      float a = atan(q.y, q.x), r = length(q*vec2(1., 1.08));
      float m = sin(a*1.3 + fbm3(uv*1.6 + s)*4.5) * .5 + .5;
      vec3 pink = srgb(255,110,200), blue = srgb(66,110,255), cyan = srgb(90,200,255), lav = srgb(222,196,232);
      vec3 core = mix(blue, pink, smoothstep(.25, .75, m));
      core = mix(core, cyan, smoothstep(.75, 1., m)*.6);
      c = mix(core, mix(lav, srgb(244,170,214), smoothstep(.9, 1.4, r)*.6), smoothstep(.45, 1.05, r));
    } else if (uKind == 2){     // 黃昏：iOS 式的柔和色場
      vec2 q = uv + (vec2(fbm(uv*1.8 + s), fbm(uv*1.8 + s + 4.)) - .5)*.35;
      c = mix(srgb(58,54,108), srgb(122,82,138), smoothstep(.0, .8, q.y));
      c = mix(c, srgb(214,138,128), smoothstep(.55, 1.1, q.y + q.x*.25)*.85);
      c = mix(c, srgb(246,196,160), smoothstep(.32, .0, distance(q, vec2(.82, .16)))*.75);
      c = mix(c, srgb(92,78,170), smoothstep(.35, .0, distance(q, vec2(.12, .8)))*.5);
    } else if (uKind == 3){     // Portraits：珊瑚色的牆，下緣一排失焦的綠籬
      c = mix(srgb(232,128,112), srgb(206,96,86), uv.y);
      c += (fbm3(uv*vec2(3., 1.5) + s) - .5)*.06;
      float hedge = smoothstep(.66, .86, uv.y + (fbm3(uv*vec2(3.5, 1.2) + s)-.5)*.16);
      vec3 leaf = mix(srgb(58,98,60), srgb(124,158,96), smoothstep(.3, .7, fbm3(uv*vec2(5., 3.) + s)));
      c = mix(c, leaf, hedge*.85);
    } else if (uKind == 4){     // Home：紫
      c = mix(srgb(84,80,226), srgb(108,102,242), uv.x*.5 + uv.y*.5);
    } else {                    // 夜
      c = mix(srgb(16,22,38), srgb(30,20,40), uv.x*.6 + uv.y*.4);
      c = mix(c, srgb(40,64,108), smoothstep(.45, .0, distance(uv, vec2(.25, .2)))*.55);
    }
    c += (hash(uv*uRes) - .5)/255.*2.;   // 抖動，避免色帶
    o = vec4(clamp(c, 0., 1.), 1.);
  }`;
  const FS_BLUR = HEAD + `
  uniform sampler2D uSrc; uniform vec2 uDir;
  void main(){ vec4 a = vec4(0.); float wsum = 0.;
    for (int i = -12; i <= 12; i++){ float w = exp(-float(i*i)/72.); a += texture(uSrc, vUv + uDir*float(i))*w; wsum += w; }
    o = a/wsum; }`;
  const FS_COPY = HEAD + `uniform sampler2D uSrc; void main(){ o = vec4(texture(uSrc, vUv).rgb, 1.); }`;
  const FS_GLASS = HEAD + `
  uniform sampler2D uBg, uBlur, uMask, uHgt, uShd;
  uniform vec2 uLRes; uniform float uDpr, uBevel, uRefract, uFrost, uLift, uSat, uBright, uRim, uSpec, uShadow, uChroma, uMag;
  uniform vec3 uTint; uniform vec2 uShadowOff; uniform vec2 uC[6]; uniform int uNC; uniform int uMode;
  float hgt(vec2 uv){ float t = clamp((texture(uHgt, uv).a - .5)*2., 0., 1.); return 1. - (1.-t)*(1.-t)*(1.-t); }
  vec3 sat(vec3 c, float s){ float l = dot(c, vec3(.2126, .7152, .0722)); return mix(vec3(l), c, s); }
  void main(){
    vec2 px = 1./uLRes;
    vec3 bg = texture(uBg, vUv).rgb;
    float cov = clamp((texture(uMask, vUv).a - .03)/.97, 0., 1.);
    float sh = uShadow * texture(uShd, vUv - uShadowOff*px).a * (1. - cov);
    vec3 base = bg*(1. - sh);
    if (cov <= .002){ o = vec4(base, 1.); return; }
    vec2 e = px*.75/uDpr*2.;
    float hx = hgt(vUv + vec2(e.x, 0.)) - hgt(vUv - vec2(e.x, 0.));
    float hy = hgt(vUv + vec2(0., e.y)) - hgt(vUv - vec2(0., e.y));
    vec2 g = vec2(hx, hy)/(2.*e.x*uLRes.x)*uBevel;   // 斜率（無因次）
    vec3 n = normalize(vec3(-g, 1.));
    float edge = length(n.xy);
    vec2 nd = edge > 1e-4 ? n.xy/edge : vec2(0.);
    float facing = dot(nd, normalize(vec2(-.6, -.8)));
    if (uMode == 1){   // 凹刻：朝光的內壁暗、背光的內壁亮
      vec3 c = bg*.985;
      c *= 1. - .34*edge*max(0., facing);
      c += .30*edge*max(0., -facing);
      o = vec4(mix(base, clamp(c, 0., 1.), cov), 1.); return;
    }
    vec2 p = vUv*uLRes;
    vec2 cc = uC[0]; float best = 1e9;
    for (int i = 0; i < 6; i++){ if (i >= uNC) break; float d = distance(p, uC[i]); if (d < best){ best = d; cc = uC[i]; } }
    vec2 q = cc + (p - cc)/uMag;
    vec2 off = n.xy*uRefract;
    vec2 uvG = (q + off)*px, uvR = (q + off*(1. + uChroma))*px, uvB = (q + off*(1. - uChroma))*px;
    vec3 sc = vec3(texture(uBg, uvR).r, texture(uBg, uvG).g, texture(uBg, uvB).b);
    vec3 bc = vec3(texture(uBlur, uvR).r, texture(uBlur, uvG).g, texture(uBlur, uvB).b);
    vec3 c = mix(sc, bc, uFrost);
    c = sat(c, uSat)*uBright;
    c = mix(c, uTint, uLift);
    c *= 1. - .10*pow(edge, 1.3)*max(0., -facing);
    float rim = pow(edge, 2.2)*(facing > 0. ? facing : .55*-facing) + .14*pow(edge, 4.);
    float spec = pow(edge, 7.)*(.4 + .6*abs(facing));
    c += uRim*rim + uSpec*spec;
    o = vec4(mix(base, clamp(c, 0., 1.), cov), 1.);
  }`;
  function prog(fs){
    const p = gl.createProgram();
    for (const [type, src] of [[gl.VERTEX_SHADER, VS], [gl.FRAGMENT_SHADER, fs]]){
      const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      gl.attachShader(p, s);
    }
    gl.bindAttribLocation(p, 0, 'aPos'); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    const u = {}; const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
    for (let i = 0; i < n; i++){ const info = gl.getActiveUniform(p, i); const name = info.name.replace(/\[0\]$/, ''); u[name] = gl.getUniformLocation(p, info.name); }
    return {p, u};
  }
  const P = {wall: prog(FS_WALL), blur: prog(FS_BLUR), copy: prog(FS_COPY), glass: prog(FS_GLASS)};
  const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  function tex(){ const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE); return t; }
  const T = {src: tex(), mask: tex(), b1: tex(), b2: tex(), hgt: tex(), shd: tex()};
  const F = {b1: gl.createFramebuffer(), b2: gl.createFramebuffer(), hgt: gl.createFramebuffer(), shd: gl.createFramebuffer()};
  let W = 0;
  function size(w){
    if (w === W) return; W = w; cv.width = cv.height = w;
    for (const k of ['b1', 'b2', 'hgt', 'shd']){ gl.bindTexture(gl.TEXTURE_2D, T[k]);
      if (HALF && k !== 'b2') gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, w, 0, gl.RGBA, gl.HALF_FLOAT, null);
      else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, w, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, F[k]); gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, T[k], 0); }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  }
  function use(pr, flip){ gl.useProgram(pr.p); gl.uniform1f(pr.u.uFlip, flip ? 1 : 0); gl.viewport(0, 0, W, W); }
  function bindTex(unit, t, loc){ gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, t); gl.uniform1i(loc, unit); }
  function draw(){ gl.drawArrays(gl.TRIANGLES, 0, 3); }
  return {
    cv,
    wallpaper(kind, seed){ size(PX); gl.bindFramebuffer(gl.FRAMEBUFFER, null); use(P.wall, true);
      gl.uniform1i(P.wall.u.uKind, kind); gl.uniform1f(P.wall.u.uSeed, seed || 0); gl.uniform2f(P.wall.u.uRes, PX, PX); draw(); },
    upload(canvas, which = 'src'){ size(PX); gl.bindTexture(gl.TEXTURE_2D, T[which]); gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false); gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, canvas); },
    blur(from, to, radius){ // radius：輸出 px；可分離高斯，σ ≈ 0.7·radius；取樣間距不超過 1.25 px，免得銳利遮罩變成階梯
      const sigma = Math.max(1, radius*.7), stepPx = Math.min(1.25, Math.max(.5, sigma/6));
      const iters = Math.min(8, Math.max(1, Math.ceil(Math.pow(sigma/(6*stepPx), 2))));
      const step = stepPx*Math.sqrt(Math.pow(sigma/(6*stepPx), 2)/iters)/W; let src = T[from];
      for (let it = 0; it < iters; it++){
        gl.bindFramebuffer(gl.FRAMEBUFFER, F.b1); use(P.blur, false); bindTex(0, src, P.blur.u.uSrc); gl.uniform2f(P.blur.u.uDir, step, 0); draw();
        gl.bindFramebuffer(gl.FRAMEBUFFER, F[to]); use(P.blur, false); bindTex(0, T.b1, P.blur.u.uSrc); gl.uniform2f(P.blur.u.uDir, 0, step); draw();
        src = T[to];
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    },
    glass(o){
      gl.bindFramebuffer(gl.FRAMEBUFFER, null); use(P.glass, true); const u = P.glass.u;
      bindTex(0, T.src, u.uBg); bindTex(1, o.frost > 0 ? T.b2 : T.src, u.uBlur); bindTex(2, T.mask, u.uMask); bindTex(3, T.hgt, u.uHgt); bindTex(4, T.shd, u.uShd);
      gl.uniform2f(u.uLRes, L, L); gl.uniform1f(u.uDpr, DPR);
      const num = {uBevel: o.bevel ?? 12, uRefract: o.refract ?? 8, uFrost: o.frost ?? 0, uLift: o.lift ?? 0, uSat: o.sat ?? 1, uBright: o.bright ?? 1,
        uRim: o.rim ?? .5, uSpec: o.spec ?? .4, uShadow: o.shadow ?? 0, uChroma: o.chroma ?? 0, uMag: o.mag ?? 1};
      for (const k in num) gl.uniform1f(u[k], num[k]);
      const t = o.tint || [1, 1, 1]; gl.uniform3f(u.uTint, t[0], t[1], t[2]);
      const so = o.shadowOff || [0, 6]; gl.uniform2f(u.uShadowOff, so[0], so[1]);
      const cs = (o.centers && o.centers.length) ? o.centers : [[300, 300]];
      const flat = new Float32Array(12); cs.slice(0, 6).forEach((c, i) => { flat[i*2] = c[0]; flat[i*2+1] = c[1]; });
      gl.uniform2fv(u.uC, flat); gl.uniform1i(u.uNC, Math.min(6, cs.length)); gl.uniform1i(u.uMode, o.mode || 0);
      draw();
    },
  };
})();

/* ---------- 文字與向量：SVG 圖層（可用 SF 的寬度軸） ---------- */
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
function T(s, x, y, size, o = {}){
  const fv = o.wdth ? `font-variation-settings:'wdth' ${o.wdth};` : '';
  return `<text x="${x}" y="${y}" text-anchor="${o.anchor || 'middle'}" font-family="${o.fam || FONT}" font-weight="${o.w || 600}" font-size="${size}" letter-spacing="${o.ls || 0}" fill="${o.fill || '#fff'}" ${o.op != null ? `fill-opacity="${o.op}"` : ''} style="${fv}${o.css || ''}" ${o.extra || ''}>${esc(s)}</text>`;
}
function svgImage(inner){
  const s = `<svg xmlns="http://www.w3.org/2000/svg" width="${PX}" height="${PX}" viewBox="0 0 600 600">${inner}</svg>`;
  const img = new Image(); img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(s);
  return img.decode().then(() => img);
}
const maskCv = document.createElement('canvas'); maskCv.width = maskCv.height = PX;
const maskCtx = maskCv.getContext('2d');
async function drawMask(src){
  maskCtx.setTransform(1, 0, 0, 1, 0, 0); maskCtx.globalCompositeOperation = 'source-over'; maskCtx.clearRect(0, 0, PX, PX);
  if (typeof src === 'string') maskCtx.drawImage(await svgImage(src), 0, 0, PX, PX);
  else { maskCtx.setTransform(DPR, 0, 0, DPR, 0, 0); src(maskCtx); maskCtx.setTransform(1, 0, 0, 1, 0, 0); }
  return maskCv;
}

class Painter {
  constructor(canvas){ this.cv = canvas; canvas.width = canvas.height = PX; this.c = canvas.getContext('2d'); this.c.setTransform(DPR, 0, 0, DPR, 0, 0); }
  blitGL(){ const c = this.c; c.save(); c.setTransform(1, 0, 0, 1, 0, 0); c.drawImage(GL.cv, 0, 0); c.restore(); }
  wall(kind, seed){ GL.wallpaper(kind, seed); this.blitGL(); }
  fill(col){ this.c.fillStyle = col; this.c.fillRect(0, 0, L, L); }
  async svg(inner){ this.c.drawImage(await svgImage(inner), 0, 0, L, L); }
  async glass(src, o){
    const m = await drawMask(src);
    GL.upload(this.cv, 'src'); GL.upload(m, 'mask');
    GL.blur('mask', 'hgt', (o.bevel ?? 12)*.75*DPR);
    if (o.shadow) GL.blur('mask', 'shd', (o.shadowBlur ?? 8)*1.4*DPR);
    if ((o.frost || 0) > 0) GL.blur('src', 'b2', (o.blur || 22)*DPR);
    GL.glass(o); this.blitGL();
  }
}

/* ---------- 指針（Apple 樣式：細頸接粗桿） ---------- */
function hand(c, cx, cy, deg, len, w, color, o = {}){
  const neck = o.neck ?? Math.min(len*.2, 34), nw = o.neckW ?? Math.max(2, w*.32);
  c.save(); c.translate(cx, cy); c.rotate(deg*Math.PI/180);
  if (o.shadow){ c.shadowColor = o.shadow; c.shadowBlur = o.shadowBlur ?? 6; c.shadowOffsetX = o.sx ?? 0; c.shadowOffsetY = o.sy ?? 2; }
  c.fillStyle = color; c.lineCap = 'round';
  c.beginPath(); c.roundRect(-nw/2, -neck - 1, nw, neck + 1, nw/2); c.fill();
  c.beginPath(); c.roundRect(-w/2, -len, w, len - neck + w*.1, w/2); c.fill();
  c.restore();
}
function secondHand(c, cx, cy, deg, len, tail, w, color, o = {}){
  c.save(); c.translate(cx, cy); c.rotate(deg*Math.PI/180);
  if (o.shadow){ c.shadowColor = o.shadow; c.shadowBlur = 4; c.shadowOffsetY = 1; }
  c.strokeStyle = color; c.lineWidth = w; c.lineCap = 'round';
  c.beginPath(); c.moveTo(0, tail); c.lineTo(0, -len); c.stroke();
  c.restore();
}
const H_DEG = (10 + 9/60)*30, M_DEG = 9*6;

/* ---------- 👀：照 Apple Color Emoji 取樣，與 App 的 drawEye 同一組參數 ---------- */
const EXPR = {
  idle:     {rx:31, ry:45, sep:36, top:0,   bot:0,   tilt:0,   smile:0, ps:1,    pdx:-13, pdy:6,  blush:0},
  curious:  {rx:32, ry:47, sep:37, top:0,   bot:0,   tilt:0,   smile:0, ps:1,    pdx:-13, pdy:6,  blush:0},
  happy:    {rx:31, ry:45, sep:36, top:0,   bot:0,   tilt:0,   smile:1, ps:0,    pdx:0,   pdy:6,  blush:.6},
  focus:    {rx:31, ry:45, sep:36, top:.34, bot:.22, tilt:0,   smile:0, ps:1,    pdx:0,   pdy:0,  blush:0},
  sleepy:   {rx:31, ry:45, sep:36, top:.55, bot:0,   tilt:0,   smile:0, ps:1,    pdx:0,   pdy:12, blush:0},
  surprised:{rx:33, ry:50, sep:38, top:0,   bot:0,   tilt:0,   smile:0, ps:.62,  pdx:0,   pdy:0,  blush:0},
  worried:  {rx:31, ry:45, sep:36, top:.3,  bot:0,   tilt:.38, smile:0, ps:1,    pdx:0,   pdy:14, blush:0},
  love:     {rx:31, ry:45, sep:36, top:0,   bot:0,   tilt:0,   smile:0, ps:1.25, pdx:0,   pdy:2,  blush:1, heart:1},
};
const EXPR_ZH = {idle:'平常', curious:'好奇', happy:'開心', focus:'專心', sleepy:'睏', surprised:'驚訝', worried:'擔心', love:'喜歡'};
const EYE = (e = 'idle') => ({p: {...EXPR[e]}, blink: 1});
const eyeCv = document.createElement('canvas'); eyeCv.width = eyeCv.height = PX;
const eyeCtx = eyeCv.getContext('2d');
function heartPath(c, x, y, s){
  c.beginPath(); c.moveTo(x, y + s*.85); c.bezierCurveTo(x - s*1.6, y - s*.1, x - s*.7, y - s*1.25, x, y - s*.45);
  c.bezierCurveTo(x + s*.7, y - s*1.25, x + s*1.6, y - s*.1, x, y + s*.85); c.closePath();
}
/* h：膠囊高；眼睛高 = 0.81h，和 App 的 420×156 膠囊同比例 */
function drawEmojiEyes(target, cx, cy, h, st, o = {}){
  const p = st.p, open = o.asleep ? 0 : Math.max(0, Math.min(1, st.blink ?? 1));
  const e = eyeCtx; e.setTransform(1, 0, 0, 1, 0, 0); e.globalCompositeOperation = 'source-over'; e.clearRect(0, 0, PX, PX); e.setTransform(DPR, 0, 0, DPR, 0, 0);
  const u = h*.404/45;
  for (const side of [-1, 1]){
    const rx = p.rx*u, ryF = p.ry*u, ry = ryF*(.1 + .9*open), ex = cx + side*p.sep*u, ey = cy;
    if (open < .25){   // 闔眼：一道往下彎的眼瞼線
      e.save(); e.strokeStyle = o.lid || 'rgba(255,255,255,.92)'; e.lineWidth = Math.max(1.4, ryF*.11); e.lineCap = 'round';
      e.beginPath(); e.moveTo(ex - rx*.82, ey); e.quadraticCurveTo(ex, ey + ryF*.42, ex + rx*.82, ey); e.stroke(); e.restore(); continue;
    }
    e.save();
    e.beginPath(); e.ellipse(ex, ey, rx, ry, 0, 0, Math.PI*2); e.clip();
    e.fillStyle = '#fff'; e.fillRect(ex - rx - 1, ey - ry - 1, rx*2 + 2, ry*2 + 2);
    // 眼白：中間純白，沿橢圓邊一圈內陰影，邊上落到 0.58 灰（枕形）
    e.save(); e.translate(ex, ey); e.scale(1, ry/rx);
    const g = e.createRadialGradient(0, 0, 0, 0, 0, rx*1.002);
    g.addColorStop(0, 'rgba(255,255,255,0)'); g.addColorStop(.80, 'rgba(251,251,251,.6)'); g.addColorStop(.89, 'rgb(230,230,230)');
    g.addColorStop(.955, 'rgb(194,194,194)'); g.addColorStop(1, 'rgb(148,148,148)');
    e.fillStyle = g; e.fillRect(-rx - 1, -rx - 1, rx*2 + 2, rx*2 + 2); e.restore();
    const irisA = Math.max(0, Math.min(1, (open - .5)/.2));
    if (p.ps > .02 && irisA > .01){
      e.globalAlpha = irisA;
      const gx = st.gaze ? st.gaze[0]*13 : p.pdx, gy = st.gaze ? p.pdy + st.gaze[1]*7 : p.pdy;
      const qx = ex + gx*u, qy = ey + gy*u*(ry/ryF);
      if (p.heart){
        const s = 18*u*p.ps; e.fillStyle = '#000'; heartPath(e, qx, qy, s); e.fill();
        e.fillStyle = 'rgba(255,255,255,.85)'; e.beginPath(); e.arc(qx - 6*u*p.ps, qy - 7*u*p.ps, 3.2*u*Math.max(.6, Math.min(1.2, p.ps)), 0, Math.PI*2); e.fill();
      } else {
        const ir = Math.max(1.5, rx*.54*p.ps);
        e.save(); e.beginPath(); e.arc(qx, qy, ir, 0, Math.PI*2); e.clip();
        // 虹膜：上半棕、下三分之一轉金（底光）
        const lg = e.createLinearGradient(qx, qy - ir, qx, qy + ir);
        [['#5a2a00', 0], ['#683900', .42], ['#7a4800', .62], ['#b78600', .80], ['#e2ab00', .92], ['#d9a400', 1]].forEach(([c, t]) => lg.addColorStop(t, c));
        e.fillStyle = lg; e.fillRect(qx - ir, qy - ir, ir*2, ir*2);
        const pr = ir*.64, rg = e.createRadialGradient(qx, qy, 0, qx, qy, pr*1.12);
        rg.addColorStop(0, '#291201'); rg.addColorStop(.86, '#2b1301'); rg.addColorStop(.94, 'rgba(58,26,0,.95)'); rg.addColorStop(1, 'rgba(58,26,0,0)');
        e.fillStyle = rg; e.fillRect(qx - ir, qy - ir, ir*2, ir*2); e.restore();
        e.strokeStyle = 'rgba(60,27,0,.9)'; e.lineWidth = Math.max(.5, ir*.06); e.beginPath(); e.arc(qx, qy, ir*.97, 0, Math.PI*2); e.stroke();
        e.fillStyle = '#fff'; e.beginPath(); e.arc(qx - ir*.375, qy - ir*.56, ir*.30, 0, Math.PI*2); e.fill();
      }
      e.globalAlpha = 1;
    }
    // 眼皮：形狀本身切掉（不塗黑），所以在玻璃或漸層膠囊上也成立
    e.globalCompositeOperation = 'destination-out'; e.fillStyle = '#000';
    e.translate(ex, ey); e.rotate(p.tilt*side);
    if (p.top > .005){ const line = -ry + 2*ry*p.top, w = rx*2.5, hh = Math.max(ry*.6, 3);
      e.fillRect(-rx*2, -ry*3, rx*4, line - hh + ry*3); e.beginPath(); e.ellipse(0, line - hh/2, w/2, hh/2, 0, 0, Math.PI*2); e.fill(); }
    if (p.bot > .005) e.fillRect(-rx*2, ry - 2*ry*p.bot, rx*4, ry*3);
    if (p.smile > .01){ e.beginPath(); e.ellipse(0, ry*(1.55 - .75*p.smile), rx*1.5, ry*1.05, 0, 0, Math.PI*2); e.fill(); }
    e.restore();
    if (p.blush > .01){   // 臉頰紅暈
      const bx = ex + side*rx*1.05, by = ey + ryF*.62, bg = e.createRadialGradient(bx, by, 0, bx, by, rx*.75);
      bg.addColorStop(0, `rgba(255,105,130,${.55*p.blush})`); bg.addColorStop(1, 'rgba(255,105,130,0)');
      e.fillStyle = bg; e.beginPath(); e.ellipse(bx, by, rx*.75, rx*.45, 0, 0, Math.PI*2); e.fill();
    }
  }
  const t = target; t.save(); t.setTransform(1, 0, 0, 1, 0, 0); t.globalAlpha = o.alpha ?? 1; t.drawImage(eyeCv, 0, 0); t.restore();
}

/* ---------- 膠囊：依年代換材質 ---------- */
const MAT_ZH = {black: '純黑', smoke: '黑透漸層', glass: '玻璃', siri: 'Siri 聆聽'};
function capPath(c, cx, cy, w, h){ c.beginPath(); c.roundRect(cx - w/2, cy - h/2, w, h, h/2); }
async function capsule(P, cx, cy, w, mat, o = {}){
  const h = w/2.69, c = P.c;
  if (mat === 'black'){ c.fillStyle = '#000'; capPath(c, cx, cy, w, h); c.fill(); return h; }
  if (mat === 'glass'){
    await P.glass(m => { m.fillStyle = '#fff'; capPath(m, cx, cy, w, h); m.fill(); },
      {bevel: h*.2, refract: h*.11, frost: .12, blur: 10, lift: .04, tint: o.tint || [1, 1, 1], sat: 1.2, bright: 1.03, rim: .42, spec: .38, chroma: .06,
       shadow: .16, shadowOff: [0, h*.07], shadowBlur: h*.14, centers: [[cx, cy]]});
    return h;
  }
  // 黑透漸層：背後先霜化壓暗，再疊一層中間實、兩端透的黑
  await P.glass(m => { m.fillStyle = '#fff'; capPath(m, cx, cy, w, h); m.fill(); },
    {bevel: h*.2, refract: 3, frost: 1, blur: 18, lift: .55, tint: [0, 0, 0], sat: 1.1, rim: .1, spec: .06, chroma: 0});
  c.save(); capPath(c, cx, cy, w, h); c.clip();
  const lg = c.createLinearGradient(cx - w/2, 0, cx + w/2, 0);
  lg.addColorStop(0, 'rgba(0,0,0,.08)'); lg.addColorStop(.26, 'rgba(0,0,0,.86)'); lg.addColorStop(.74, 'rgba(0,0,0,.86)'); lg.addColorStop(1, 'rgba(0,0,0,.08)');
  c.fillStyle = lg; c.fillRect(cx - w/2, cy - h/2, w, h); c.restore();
  if (mat === 'siri'){   // Siri 聆聽：外圈一道 Apple Intelligence 色的光
    c.save();
    let g;
    if (c.createConicGradient){ g = c.createConicGradient(-Math.PI/2, cx, cy); [['#ff9b3d', 0], ['#ff4fa6', .28], ['#9b5cff', .52], ['#3d9bff', .76], ['#ff9b3d', 1]].forEach(([k, t]) => g.addColorStop(t, k)); }
    else { g = c.createLinearGradient(cx - w/2, 0, cx + w/2, 0); g.addColorStop(0, '#ff9b3d'); g.addColorStop(.5, '#9b5cff'); g.addColorStop(1, '#3d9bff'); }
    c.strokeStyle = g; c.lineWidth = h*.07; c.shadowColor = 'rgba(190,110,255,.85)'; c.shadowBlur = h*.45;
    capPath(c, cx, cy, w + h*.05, h*1.05); c.stroke(); c.shadowBlur = h*.18; c.stroke(); c.restore();
  }
  return h;
}
async function island(P, cx, cy, w, mat, st, o = {}){
  const h = await capsule(P, cx, cy, w, mat, o);
  drawEmojiEyes(P.c, cx, cy, h, st, o);
}

/* ---------- 錶面 ---------- */
const W = '#fff';
const FACES = [];
function face(title, sub, tag, fn){ FACES.push({title, sub, tag, fn}); }
const TIME_GLASS = {bevel: 13, refract: 10, frost: .55, blur: 22, lift: .3, tint: [1, 1, 1], sat: 1.25, bright: 1.08, rim: .62, spec: .55, chroma: .06, centers: [[300, 180]]};

async function homeBase(P, wallKind){
  P.wall(wallKind, 2.3);
  await P.svg(T('10月24日 星期六', 300, 88, 26, {w: 600, fill: W, op: .82}));
  await P.glass(T('10:09', 300, 238, 158, {w: 620, wdth: 92, ls: -2}), TIME_GLASS);
}
face('眼睛', '桌寵預設。2026 年的 HomeView 屬於 Liquid Glass 年代，所以膠囊是玻璃。', '玻璃', async P => {
  await homeBase(P, 2); await island(P, 300, 405, 300, 'glass', EYE());
});
face('Portraits', 'Compressed 數字頂到上緣、實心霜玻璃。真實照片會把主體摳到數字前，膠囊躲在人後面。', '玻璃', async P => {
  P.wall(3, 1.7);
  await P.glass(T('1009', 300, 352, 452, {w: 640, wdth: 34, ls: -8}), {bevel: 15, refract: 12, frost: .78, blur: 28, lift: .14, tint: [1, 1, 1], sat: 1.15, bright: 1.13, rim: .5, spec: .45, chroma: .06, centers: [[300, 200]]});
  await island(P, 300, 476, 170, 'glass', EYE());
});
face('Flow', '數字吹成水珠：1 是膠囊、0 沒有字腔。膠囊也是一顆玻璃水珠，漂在數字旁。', '玻璃', async P => {
  P.wall(1, 4.2);
  const blobs = `<rect x="212" y="70" width="74" height="216" rx="37" fill="#fff"/><rect x="304" y="64" width="198" height="226" rx="96" fill="#fff"/>
    <rect x="94" y="304" width="198" height="242" rx="97" fill="#fff"/><rect x="306" y="314" width="82" height="132" rx="41" fill="#fff"/>
    <rect x="404" y="304" width="92" height="216" rx="46" fill="#fff"/><circle cx="356" cy="490" r="32" fill="#fff"/>`;
  await P.glass(blobs, {bevel: 44, refract: 34, frost: .06, blur: 10, lift: .05, tint: [1, 1, 1], sat: 1.35, bright: 1.07, rim: .6, spec: .75, chroma: .1,
    shadow: .14, shadowOff: [0, 10], shadowBlur: 16, mag: .82, centers: [[249, 178], [403, 177], [193, 425], [347, 380], [450, 412], [356, 490]]});
  await island(P, 120, 150, 150, 'glass', EYE());
});
face('Modular', '照官方的 2×2：日期、指針、正在播放；膠囊住在右下那一格。平面錶面用純黑。', '純黑', async P => {
  P.fill('#97a9ac');
  const c = P.c, cx = 438, cy = 160, r = 116;
  let s = T('週六 10月', 58, 97, 46, {w: 700, anchor: 'start', fill: W, ls: -.5});
  s += T('24', 52, 268, 196, {w: 600, anchor: 'start', fill: '#0a0a0a', ls: -6});
  for (let i = 0; i < 60; i++){ const a = i*Math.PI/30, x1 = cx + Math.sin(a)*(r - 6), y1 = cy - Math.cos(a)*(r - 6), x2 = cx + Math.sin(a)*r, y2 = cy - Math.cos(a)*r;
    s += `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="#111" stroke-width="${i % 5 ? 1.4 : 2.4}" stroke-linecap="round"/>`; }
  for (let i = 1; i <= 12; i++){ const a = i*Math.PI/6; s += T(i, cx + Math.sin(a)*90, cy - Math.cos(a)*90 + 9.5, 27, {w: 500, fill: '#0a0a0a'}); }
  s += `<defs><linearGradient id="art" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#9cc8f0"/><stop offset=".55" stop-color="#e9f2fb"/><stop offset="1" stop-color="#6fa6dc"/></linearGradient></defs>
    <rect x="42" y="318" width="130" height="130" rx="11" fill="url(#art)"/><circle cx="112" cy="378" r="16" fill="#e8553d"/><path d="M84 400 l28 -10 l26 14" stroke="#2c3550" stroke-width="5" fill="none" stroke-linecap="round"/>`;
  s += T('♫', 268, 352, 40, {w: 400, fill: W});
  s += T('晴天', 43, 478, 20, {w: 700, anchor: 'start', fill: '#0a0a0a', ls: .5}) + T('周杰倫', 43, 502, 19, {w: 500, anchor: 'start', fill: '#3d4648', op: .85});
  s += `<rect x="42" y="516" width="128" height="44" rx="22" fill="#000" fill-opacity=".12"/><path d="M66 528 l15 10 l-15 10 z" fill="#0a0a0a"/>` + T('播放', 112, 545, 21, {w: 600, fill: '#0a0a0a'});
  s += T('HomePlay', 322, 336, 22, {w: 600, anchor: 'start', fill: W}) + T('已接電源・100%', 322, 556, 20, {w: 500, anchor: 'start', fill: '#0a0a0a'});
  await P.svg(s);
  hand(c, cx, cy, H_DEG, 62, 7.5, '#0a0a0a', {neck: 16, neckW: 3}); hand(c, cx, cy, M_DEG, 100, 6.5, '#0a0a0a', {neck: 16, neckW: 3});
  secondHand(c, cx, cy, 180, 108, 18, 1.6, '#fff');
  c.fillStyle = '#0a0a0a'; c.beginPath(); c.arc(cx, cy, 6, 0, 7); c.fill(); c.fillStyle = '#fff'; c.beginPath(); c.arc(cx, cy, 3, 0, 7); c.fill();
  await island(P, 412, 448, 190, 'black', EYE());
});
face('天氣', '大溫度是透明的玻璃，透出雲；膠囊在溫度右邊，眼睛望向天空。', '玻璃', async P => {
  P.wall(0, 3.3);
  let s = `<g fill="#fff"><circle cx="66" cy="54" r="8"/><g stroke="#fff" stroke-width="2.2" stroke-linecap="round">${[0,45,90,135,180,225].map(a => { const t = (a - 90)*Math.PI/180; return `<line x1="${66 + Math.cos(t)*12}" y1="${54 + Math.sin(t)*12}" x2="${66 + Math.cos(t)*16}" y2="${54 + Math.sin(t)*16}"/>`; }).join('')}</g>
    <path d="M52 76 h26 a9 9 0 0 0 0 -18 a12 12 0 0 0 -22 -2 a8 8 0 0 0 -4 20z"/></g>`;
  s += T('晴時多雲', 92, 72, 25, {w: 600, anchor: 'start', fill: W}) + T('高 25° 低 19°', 46, 104, 23, {w: 600, anchor: 'start', fill: W});
  s += T('10:09', 554, 92, 54, {w: 600, anchor: 'end', fill: W, ls: -.5});
  await P.svg(s);
  await P.glass(T('22°', 46, 318, 236, {w: 400, anchor: 'start', ls: -4}), {bevel: 15, refract: 13, frost: .22, blur: 14, lift: .2, tint: [.94, .97, 1], sat: 1.2, bright: 1.08, rim: .8, spec: .65, chroma: .08, centers: [[200, 230]]});
  await island(P, 470, 262, 150, 'glass', {p: {...EXPR.idle, pdx: -6, pdy: -10}, blink: 1});
  const cols = [92, 230, 374, 512], vals = [['17:21', '日落'], ['11 km/h', '風速'], ['76%', '濕度'], ['21', 'AQI']];
  const ic = [
    x => `<g stroke="#fff" stroke-width="2.4" fill="none" stroke-linecap="round"><path d="M${x-24} 458 h48"/><path d="M${x-14} 452 a14 14 0 0 1 28 0"/><path d="M${x} 418 v14 M${x-6} 426 l6 6 6-6"/><path d="M${x-26} 446 l5 2 M${x+26} 446 l-5 2 M${x-18} 434 l4 4 M${x+18} 434 l-4 4"/></g>`,
    x => `<g stroke="#fff" stroke-width="2.4" fill="none" stroke-linecap="round"><path d="M${x-22} 432 h26 a7 7 0 1 0 -7 -7"/><path d="M${x-22} 442 h34 a7 7 0 1 1 -7 7"/><path d="M${x-16} 452 h14"/></g>`,
    x => `<g stroke="#fff" stroke-width="2.4" fill="none" stroke-linecap="round"><path d="M${x-24} 430 q6 -6 12 0 t12 0 t12 0"/><path d="M${x-24} 442 q6 -6 12 0 t12 0"/><path d="M${x-24} 454 q6 -6 12 0"/></g><path d="M${x+14} 438 q8 12 0 18 q-8 -6 0 -18z" fill="#fff"/>`,
    x => { let g = ''; let k = 0; for (let i = -3; i <= 3; i++) for (let j = -3; j <= 3; j++){ if (i*i + j*j > 10) continue; k++; g += `<circle cx="${x + i*7}" cy="${440 + j*7}" r="1.7" fill="#fff" fill-opacity="${.55 + .45*((k*37) % 10)/10}"/>`; } return g; },
  ];
  let b = ''; cols.forEach((x, i) => { b += ic[i](x) + T(vals[i][0], x, 500, 25, {w: 600, fill: W}) + T(vals[i][1], x, 533, 25, {w: 600, fill: W}); });
  await P.svg(b);
});
face('行事曆', '月曆照官方排，今天的「24」用圓頭粗筆畫壓在後面。膠囊坐在月份和時間之間，是 iOS 27 的黑透漸層。', '黑透漸層', async P => {
  P.fill('#eeeeef');
  let s = `<g fill="none" stroke="#ff4b47" stroke-width="46" stroke-linecap="round" stroke-linejoin="round">
    <path d="M150 248 C152 186 268 178 270 246 C272 302 166 372 150 450 L282 450"/><path d="M420 452 L420 196 L322 372 L466 372"/></g>`;
  s += T('2026年10月', 46, 78, 35, {w: 600, anchor: 'start', fill: '#f2433d', ls: -.3}) + T('10:09', 556, 78, 35, {w: 600, anchor: 'end', fill: '#f2433d'});
  '日一二三四五六'.split('').forEach((d, i) => { s += T(d, 80 + i*71.2, 141, 31, {w: 700, fill: '#1c5fd8'}); });
  const first = [27, 28, 29, 30, 1, 2, 3];
  for (let r = 0; r < 6; r++) for (let col = 0; col < 7; col++){
    const idx = r*7 + col - 4, inMonth = idx >= 0 && idx < 31, v = inMonth ? idx + 1 : (idx < 0 ? first[col] : idx - 30);
    const x = 80 + col*71.2, y = 204 + r*63.2;
    if (inMonth && v === 24) s += `<circle cx="${x}" cy="${y - 11}" r="31" fill="#0b2a5c"/>` + T(v, x, y, 32, {w: 600, fill: '#fff'});
    else s += T(v, x, y, 32, {w: 600, fill: '#1c5fd8', op: inMonth ? 1 : .32});
  }
  await P.svg(s);
  await island(P, 356, 66, 118, 'smoke', {p: {...EXPR.idle, pdx: 10, pdy: 12}, blink: 1});
});
face('Home Modular', '紫色玻璃磚照官方的格局，資料來自 HomePlay Home 小幫手；膠囊住在右下那塊磚。', '玻璃', async P => {
  P.wall(4, 1.1);
  const ribbons = `<g fill="#fff" transform="rotate(-38 300 300)"><rect x="-120" y="40" width="900" height="120" rx="60"/><rect x="-60" y="250" width="820" height="150" rx="75"/><rect x="-200" y="470" width="900" height="110" rx="55"/></g>
    <g fill="#fff" transform="rotate(52 300 300)"><rect x="80" y="-120" width="110" height="420" rx="55"/><rect x="380" y="320" width="120" height="420" rx="60"/></g>`;
  await P.glass(ribbons, {bevel: 40, refract: 26, frost: .15, blur: 12, lift: .14, tint: [.62, .6, 1], sat: 1.15, bright: 1.12, rim: .45, spec: .35, chroma: .05, shadow: .25, shadowOff: [10, 16], shadowBlur: 24});
  const tiles = `<rect x="12" y="12" width="374" height="374" rx="34" fill="#fff"/><circle cx="487" cy="99" r="88" fill="#fff"/><rect x="398" y="200" width="190" height="186" rx="30" fill="#fff"/>
    <rect x="12" y="398" width="182" height="190" rx="30" fill="#fff"/><rect x="206" y="398" width="182" height="190" rx="30" fill="#fff"/><rect x="400" y="398" width="188" height="190" rx="30" fill="#fff"/>`;
  await P.glass(tiles, {bevel: 16, refract: 10, frost: .38, blur: 18, lift: .12, tint: [.86, .85, 1], sat: 1.1, bright: 1.08, rim: .55, spec: .45, chroma: .04, shadow: .18, shadowOff: [0, 6], shadowBlur: 12,
    centers: [[199, 199], [487, 99], [493, 293], [103, 493], [297, 493], [494, 493]]});
  const c = P.c;
  let s = T('24', 199, 228, 172, {w: 600, fill: W, ls: -5});
  s += `<g stroke="#fff" stroke-width="4" fill="none" stroke-linecap="round" stroke-linejoin="round"><path d="M50 326 l14 14 l14 -14"/><path d="M320 340 l14 -14 l14 14"/></g>`;
  s += T('溫控', 199, 325, 21, {w: 700, fill: W}) + T('客廳', 199, 350, 19, {w: 600, fill: W, op: .62});
  for (let i = 0; i < 12; i++){ const a = i*Math.PI/6; s += `<line x1="${487 + Math.sin(a)*60}" y1="${99 - Math.cos(a)*60}" x2="${487 + Math.sin(a)*74}" y2="${99 - Math.cos(a)*74}" stroke="#fff" stroke-width="4.5" stroke-linecap="round"/>`; }
  s += `<path d="M502 238 a24 24 0 1 0 18 38 a19 19 0 0 1 -18 -38z" fill="#fff"/><path d="M520 232 l2.5 6 l6 2.5 l-6 2.5 l-2.5 6 l-2.5 -6 l-6 -2.5 l6 -2.5z" fill="#fff"/>`;
  s += T('晚安', 493, 330, 21, {w: 700, fill: W}) + T('場景', 493, 355, 19, {w: 600, fill: W, op: .62});
  s += `<g stroke="#fff" stroke-width="3.6" stroke-linecap="round">${[-16,-10,-4,2,8,14].map((dx, i) => `<line x1="${103 + dx}" y1="${448 - [8,16,22,22,16,8][i]}" x2="${103 + dx}" y2="${448 + [8,16,22,22,16,8][i]}"/>`).join('')}</g>`;
  s += T('對講', 103, 528, 21, {w: 700, fill: W}) + T('全家', 103, 553, 19, {w: 600, fill: W, op: .62});
  s += `<path d="M284 444 v-10 a13 13 0 0 1 26 0 v10" stroke="#fff" stroke-width="5" fill="none"/><rect x="276" y="442" width="42" height="34" rx="7" fill="#fff"/>`;
  s += T('門鎖', 297, 528, 21, {w: 700, fill: W}) + T('大門', 297, 553, 19, {w: 600, fill: W, op: .62});
  s += T('HomePlay', 494, 528, 21, {w: 700, fill: W}) + T('看著你', 494, 553, 19, {w: 600, fill: W, op: .62});
  await P.svg(s);
  hand(c, 487, 99, H_DEG, 38, 7, '#fff', {neck: 10, neckW: 3}); hand(c, 487, 99, M_DEG, 62, 6, '#fff', {neck: 10, neckW: 3});
  secondHand(c, 487, 99, 180, 70, 12, 1.4, '#fff'); c.fillStyle = '#fff'; c.beginPath(); c.arc(487, 99, 4.5, 0, 7); c.fill();
  await island(P, 494, 452, 130, 'glass', EYE(), {tint: [.9, .9, 1]});
});
face('Typograph', '數字照官方疊壓；指針細頸接粗桿、帶陰影，秒針貫穿。純黑膠囊在右下角，指針從它上面掃過。', '純黑', async P => {
  P.fill('#3f9b5f');
  let s = T('12', 300, 265, 330, {w: 400, fill: '#0a0a0a', ls: -22}) + T('9', 112, 430, 336, {w: 400, fill: '#0a0a0a'}) + T('3', 494, 440, 336, {w: 400, fill: '#0a0a0a'}) + T('6', 292, 566, 336, {w: 400, fill: '#0a0a0a'});
  s += T('週六 24', 38, 560, 26, {w: 700, anchor: 'start', fill: '#0a0a0a'});
  await P.svg(s);
  await island(P, 492, 532, 150, 'black', {p: {...EXPR.idle, pdx: -10, pdy: -6}, blink: 1});
  const c = P.c;
  hand(c, 300, 300, H_DEG, 168, 17, '#fff', {neck: 30, neckW: 5, shadow: 'rgba(0,0,0,.38)', shadowBlur: 7, sy: 3});
  hand(c, 300, 300, M_DEG, 262, 15, '#fff', {neck: 30, neckW: 5, shadow: 'rgba(0,0,0,.38)', shadowBlur: 7, sy: 3});
  secondHand(c, 300, 300, 180, 268, 46, 2, '#fff', {shadow: 'rgba(0,0,0,.3)'});
  c.fillStyle = '#fff'; c.beginPath(); c.arc(300, 300, 10, 0, 7); c.fill(); c.fillStyle = '#3f9b5f'; c.beginPath(); c.arc(300, 300, 4.5, 0, 7); c.fill();
});
face('浮雕指針', '數字刻進同色的底、沿圓周轉向；玻璃膠囊取代 6 點，透出粉色。', '玻璃', async P => {
  const c = P.c; const g = c.createRadialGradient(220, 160, 40, 300, 300, 520); g.addColorStop(0, '#e2bcba'); g.addColorStop(1, '#c99c9c');
  c.fillStyle = g; c.fillRect(0, 0, L, L);
  let s = '';
  [[12,0],[1,30],[2,60],[3,90],[4,120],[5,150],[7,210],[8,240],[9,270],[10,300],[11,330]].forEach(([n, d]) => {
    const a = d*Math.PI/180, x = 300 + Math.sin(a)*248, y = 300 - Math.cos(a)*248;
    s += `<g transform="translate(${x} ${y}) rotate(${d})">${T(n, 0, 32, 92, {w: 300, fill: '#fff'})}</g>`; });
  await P.glass(s, {mode: 1, bevel: 5});
  await island(P, 300, 518, 140, 'glass', {p: {...EXPR.idle, pdx: 0, pdy: -4}, blink: 1}, {tint: [1, .92, .93]});
  const sh = {shadow: 'rgba(70,20,25,.4)', shadowBlur: 9, sx: 3, sy: 6};
  hand(c, 300, 300, H_DEG, 158, 17, '#6c2a2e', {neck: 34, neckW: 5, ...sh}); hand(c, 300, 300, M_DEG, 238, 14, '#6c2a2e', {neck: 34, neckW: 5, ...sh});
  secondHand(c, 300, 300, 180, 268, 0, 2.6, '#ff47a0', {shadow: 'rgba(70,20,25,.3)'});
  c.fillStyle = '#ff47a0'; c.beginPath(); c.arc(300, 300, 8, 0, 7); c.fill(); c.fillStyle = '#fff'; c.beginPath(); c.arc(300, 300, 3, 0, 7); c.fill();
});
face('黑', 'OLED 全黑。純黑膠囊和背景融成一體，只看得到 👀。', '純黑', async P => {
  P.fill('#000'); await island(P, 300, 300, 260, 'black', EYE());
});
face('黑（夜間）', '亮度降到 0.3 nit：眼睛闔上，眼瞼線和時間都是暗紅色，沒有光暈。', '純黑', async P => {
  P.fill('#000');
  drawEmojiEyes(P.c, 300, 262, 96, EYE(), {asleep: true, lid: '#6a1611'});
  await P.svg(T('10:09', 300, 404, 92, {w: 300, fill: '#5a120e'}));
});
face('Growth', '這個月每天第一次打開就點亮一顆；黑透漸層膠囊在環中央，開心地笑。', '黑透漸層', async P => {
  P.wall(5, .7);
  let s = '';
  for (let i = 0; i < 31; i++){ const a = i/31*Math.PI*2, x = 300 + Math.sin(a)*228, y = 300 - Math.cos(a)*228;
    s += i < 24 ? `<circle cx="${x}" cy="${y}" r="7.5" fill="#6fe3c2" fill-opacity="${i === 23 ? 1 : .9}"/>` : `<circle cx="${x}" cy="${y}" r="6" fill="#fff" fill-opacity=".16"/>`; }
  s += T('這個月陪你 24 天', 300, 430, 27, {w: 700, fill: W}) + T('每天第一次打開，環上就多一顆', 300, 462, 18, {w: 500, fill: W, op: .55});
  await P.svg(s);
  await island(P, 300, 300, 230, 'smoke', EYE('happy'));
});

/* ---------- AI System 6 系列：原生 1-bit，再以整數倍放大 ---------- */
class Mac1 {
  constructor(n){ this.n = n; this.cv = document.createElement('canvas'); this.cv.width = this.cv.height = n; this.c = this.cv.getContext('2d', {willReadFrequently: true}); this.c.imageSmoothingEnabled = false; }
  pattern(){ const p = document.createElement('canvas'); p.width = p.height = 2; const k = p.getContext('2d'); k.fillStyle = '#fff'; k.fillRect(0, 0, 2, 2); k.fillStyle = '#000'; k.fillRect(0, 0, 1, 1); k.fillRect(1, 1, 1, 1); return this.c.createPattern(p, 'repeat'); }
  desktop(){ this.c.fillStyle = this.pattern(); this.c.fillRect(0, 0, this.n, this.n); }
  rect(x, y, w, h, fill = '#fff', stroke = '#000'){ const c = this.c; c.fillStyle = fill; c.fillRect(x, y, w, h); if (stroke){ c.fillStyle = stroke; c.fillRect(x, y, w, 1); c.fillRect(x, y + h - 1, w, 1); c.fillRect(x, y, 1, h); c.fillRect(x + w - 1, y, 1, h); } }
  text(s, x, y, size, bold, align = 'left'){ const c = this.c; c.fillStyle = '#000'; c.font = `${bold ? 'bold ' : ''}${size}px Geneva, Monaco, "Helvetica Neue", sans-serif`; c.textAlign = align; c.textBaseline = 'alphabetic'; c.fillText(s, x, y); return c.measureText(s).width; }
  bitmap(rows, x, y, s = 1){ const c = this.c; rows.forEach((r, j) => [...r].forEach((ch, i) => {
    const black = ch === 'X' || (ch === ':' && (i + j) % 2 === 0), white = ch === '.' || ch === ':';
    if (black){ c.fillStyle = '#000'; c.fillRect(x + i*s, y + j*s, s, s); } else if (white){ c.fillStyle = '#fff'; c.fillRect(x + i*s, y + j*s, s, s); } })); }
  menubar(items){ const c = this.c; this.rect(0, 0, this.n, 20, '#fff', null); c.fillStyle = '#000'; c.fillRect(0, 19, this.n, 1);
    this.bitmap(EYES_MENU, 10, 5); let x = 34; for (const it of items){ x += this.text(it, x, 14, 12, true) + 14; } }
  window(x, y, w, h, title){ const c = this.c; this.rect(x, y, w, h); c.fillStyle = '#000'; c.fillRect(x + 1, y + h, w, 1); c.fillRect(x + w, y + 1, 1, h);
    c.fillRect(x, y + 18, w, 1);
    for (let k = 4; k <= 14; k += 2) c.fillRect(x + 2, y + k, w - 4, 1);
    c.fillStyle = '#fff'; c.fillRect(x + 8, y + 3, 13, 13); this.rect(x + 9, y + 4, 11, 11);
    c.font = 'bold 12px Geneva, Monaco, sans-serif'; const tw = c.measureText(title).width;
    c.fillStyle = '#fff'; c.fillRect(x + w/2 - tw/2 - 6, y + 2, tw + 12, 15); this.text(title, x + w/2, y + 14, 12, true, 'center'); }
  button(cx, cy, w, h, dflt){ const c = this.c; c.lineWidth = 1; c.strokeStyle = '#000'; c.fillStyle = '#fff';
    c.beginPath(); c.roundRect(cx - w/2 + .5, cy - h/2 + .5, w - 1, h - 1, 8); c.fill(); c.stroke();
    if (dflt){ c.lineWidth = 3; c.beginPath(); c.roundRect(cx - w/2 - 3.5, cy - h/2 - 3.5, w + 7, h + 7, 11); c.stroke(); c.lineWidth = 1; } }
  eyes(cx, cy, s = 1){ const w = EYE1[0].length*s; this.bitmap(EYE1, cx - w - 1*s, cy - EYE1.length*s/2, s); this.bitmap(EYE1, cx + 1*s, cy - EYE1.length*s/2, s); }
  finish(P){   // 門檻化成真正的 1-bit，再最近鄰放大
    const c = this.c, im = c.getImageData(0, 0, this.n, this.n), d = im.data;
    for (let i = 0; i < d.length; i += 4){ const a = d[i+3]/255, lum = (d[i]*.3 + d[i+1]*.59 + d[i+2]*.11)*a + 255*(1 - a); const v = lum < 140 ? 0 : 255; d[i] = d[i+1] = d[i+2] = v; d[i+3] = 255; }
    c.putImageData(im, 0, 0);
    const t = P.c; t.save(); t.imageSmoothingEnabled = false; t.drawImage(this.cv, 0, 0, L, L); t.restore();
  }
}
/* 1-bit 👀：瞳孔往左看，眼白右下用 50% 網點做出枕形陰影 */
const EYE1 = [
  "....XXXXX....",
  "..XX.....XX..",
  ".X.........X.",
  ".X.........X.",
  "X...........X",
  "X...........X",
  "X.XXXXX.....X",
  "XXXXXXXX....X",
  "XX..XXXX....X",
  "XX..XXXX...:X",
  "XXXXXXXX..:.X",
  "X.XXXXX..:.:X",
  "X.......:.:.X",
  ".X.....:.:.X.",
  ".X...:.:.:.X.",
  "..XX.:.:.XX..",
  "....XXXXX....",
];
const EYES_MENU = ["..XX....XX..", ".X..X..X..X.", "XXX.X.XXX.X.", "XXX.X.XXX.X.", ".X..X..X..X.", "..XX....XX.."].map(r => r.padEnd(12, '.'));
const HD = ["XXXXXXXXXXXXXXXXXXXXXXXXXXXX", "X..........................X", "X..........................X", "X.XX.......................X", "X..........................X", "X..........................X", "XXXXXXXXXXXXXXXXXXXXXXXXXXXX", ".X........................X.", ".XXXXXXXXXXXXXXXXXXXXXXXXXX."];
const TRASH = ["......XXXXX......", "XXXXXXX...XXXXXXX", "X...............X", "XXXXXXXXXXXXXXXXX", ".X.............X.", ".X..X..X..X..X.X.", ".X..X..X..X..X.X.", ".X..X..X..X..X.X.", ".X..X..X..X..X.X.", ".X..X..X..X..X.X.", ".X..X..X..X..X.X.", ".X..X..X..X..X.X.", ".X..X..X..X..X.X.", ".X.............X.", "..XXXXXXXXXXXXX.."];
const MAC = [ // 小型一體機輪廓，螢幕留給 👀
  ".XXXXXXXXXXXXXXXXXXXXXX.", "X......................X", "X..XXXXXXXXXXXXXXXXXX..X", "X..X................X..X", "X..X................X..X", "X..X................X..X",
  "X..X................X..X", "X..X................X..X", "X..X................X..X", "X..X................X..X", "X..X................X..X", "X..X................X..X",
  "X..X................X..X", "X..XXXXXXXXXXXXXXXXXX..X", "X......................X", "X......................X", "X..XX.......XXXXXXXX...X", "X......................X",
  "X......................X", "XXXXXXXXXXXXXXXXXXXXXXXX", "X......................X", "XXXXXXXXXXXXXXXXXXXXXXXX"];
const SYS6 = [];
function sys6(title, sub, fn){ SYS6.push({title, sub, fn}); }
function labelUnder(m, s, cx, y){ m.c.font = '9px Geneva, Monaco, sans-serif'; const w = Math.ceil(m.c.measureText(s).width); m.rect(cx - w/2 - 2, y - 9, w + 4, 12, '#fff', null); m.text(s, cx, y, 9, false, 'center'); }
sys6('Finder', '預設桌面：50% 網點桌布、Chicago 選單列、條紋標題列的視窗、右上硬碟、右下垃圾桶。膠囊是一顆預設按鈕：圓角框外再一圈粗框。', P => {
  const m = new Mac1(300); m.desktop(); m.menubar(['File', 'Edit', 'View', 'Special']);
  m.bitmap(HD, 232, 34); labelUnder(m, 'HomePlay HD', 246, 56);
  m.bitmap(TRASH, 238, 236); labelUnder(m, 'Trash', 246, 263);
  m.window(30, 70, 196, 168, 'HomePlay');
  m.text('10:09', 128, 146, 50, true, 'center');
  m.text('Saturday, October 24, 2026', 128, 166, 12, false, 'center');
  m.button(128, 206, 80, 30, true); m.eyes(128, 206, 1);
  m.finish(P);
});
sys6('Alarm Clock', 'System 6 的桌上附件「Alarm Clock」放大成錶面：時間列、日期列、三個切換圖示；下面是按鈕膠囊。', P => {
  const m = new Mac1(150); m.desktop(); m.menubar(['File', 'Edit']);
  m.window(14, 34, 122, 64, 'Alarm Clock');
  m.text('10:09:41 AM', 22, 66, 12, true); m.bitmap(["X.....", "XX....", "XXX...", "XXXX..", "XXX...", "XX....", "X....."], 122, 58);
  m.c.fillStyle = '#000'; m.c.fillRect(15, 71, 120, 1);
  m.text('10/24/26', 22, 86, 12, true);
  m.bitmap(["..XXX..", ".X...X.", "X..X..X", "X..XX.X", "X.....X", ".X...X.", "..XXX.."], 92, 79); m.bitmap(["XXXXXXX", "X.X.X.X", "XXXXXXX", "X.X.X.X", "X.X.X.X", "XXXXXXX"], 104, 80); m.bitmap([".X...X.", "..XXX..", ".X...X.", "X..X..X", "X..XX.X", ".X...X.", "..XXX.."], 116, 79);
  m.button(75, 124, 50, 20, true); m.eyes(75, 124, 1);
  m.finish(P);
});
sys6('Welcome', '開機與連線時的畫面：笑臉 Mac 的螢幕裡是 👀，下面是「Welcome to HomePlay.」的雙框對話盒。', P => {
  const m = new Mac1(150); m.desktop();
  m.bitmap(MAC, 51, 14, 2);
  const small = ["..XXX..", ".X...X.", "XXX...X", "XXX...X", "XXX...X", ".X...X.", "..XXX.."];
  m.bitmap(small, 61, 23, 2); m.bitmap(small, 75, 23, 2);
  m.rect(20, 74, 110, 34); m.rect(22, 76, 106, 30);
  m.text('Welcome to', 75, 89, 12, true, 'center'); m.text('HomePlay.', 75, 102, 12, true, 'center');
  m.finish(P);
});
sys6('About', '「About the Finder」改成關於這台 HomePlay：版本、iPhone 電量和陪伴天數用當年的記憶體長條表示。', P => {
  const m = new Mac1(300); m.desktop(); m.menubar(['File', 'Edit', 'View', 'Special']);
  m.window(18, 46, 264, 212, 'About HomePlay');
  m.bitmap(MAC, 34, 76); m.c.fillStyle = '#fff'; m.c.fillRect(38, 79, 16, 10);
  const small = ["..XXX..", ".X...X.", "XXX...X", "XXX...X", "XXX...X", ".X...X.", "..XXX.."]; m.bitmap(small, 37, 80); m.bitmap(small, 46, 80);
  m.text('HomePlay', 70, 90, 24, true); m.text('Version 0.6.1', 72, 106, 9);
  m.c.fillStyle = '#000'; m.c.fillRect(28, 116, 244, 1);
  m.text('iPhone Battery: 100%', 34, 134, 12, false); m.text('Plugged in', 266, 134, 12, false, 'right');
  m.c.fillRect(28, 142, 244, 1);
  const rows = [['iPhone', 1], ['With you', 24/31], ['CarPlay', .62]];
  rows.forEach(([n, v], i) => { const y = 162 + i*24; m.bitmap(EYES_MENU, 34, y - 9); m.text(n, 52, y, 12, false);
    m.rect(130, y - 10, 136, 12); m.c.fillStyle = '#000'; m.c.fillRect(131, y - 9, Math.round(134*v), 10); });
  m.button(150, 280, 70, 24, true); m.eyes(150, 280, 1);
  m.finish(P);
});

/* ---------- 互動舞台 ---------- */
const stage = {cv: document.getElementById('stage'), expr: 'idle', wall: 2, mat: 'glass', p: {...EXPR.idle}, t: {...EXPR.idle}, blink: 1, gaze: null, tg: null,
  base: null, busy: false, dirty: true, nextBlink: performance.now() + 1500, blinkStart: 0};
const WALL_ZH = [[2, '黃昏'], [0, '天空'], [1, '粉藍'], [5, '夜'], [3, '珊瑚']];
async function stageBase(){
  const off = document.createElement('canvas'); const P = new Painter(off);
  await homeBase(P, stage.wall);
  await capsule(P, 300, 405, 300, stage.mat);
  stage.base = off; stage.dirty = true;
}
function stageFrame(){
  if (!stage.base) return;
  const out = stage.cv.getContext('2d'); if (stage.cv.width !== PX){ stage.cv.width = stage.cv.height = PX; }
  out.setTransform(1, 0, 0, 1, 0, 0); out.drawImage(stage.base, 0, 0);
  out.setTransform(DPR, 0, 0, DPR, 0, 0);
  drawEmojiEyes(out, 300, 405, 300/2.69, {p: stage.p, blink: stage.blink, gaze: stage.gaze});
}
function stageTick(now){
  const dt = Math.min(.05, (now - (stage.last || now))/1000); stage.last = now;
  let moving = false;
  const a = reduced ? 1 : 1 - Math.exp(-dt/.09);
  for (const k of Object.keys(stage.t)){ const d = (stage.t[k] ?? 0) - (stage.p[k] ?? 0); if (Math.abs(d) > .002){ stage.p[k] = (stage.p[k] ?? 0) + d*a; moving = true; } else stage.p[k] = stage.t[k]; }
  stage.p.heart = stage.t.heart || 0;
  if (stage.tg){ stage.gaze = stage.gaze || [stage.p.pdx/13, 0]; const b = reduced ? 1 : 1 - Math.exp(-dt/.06);
    for (const i of [0, 1]){ const d = stage.tg[i] - stage.gaze[i]; if (Math.abs(d) > .003){ stage.gaze[i] += d*b; moving = true; } } }
  if (!reduced && now > stage.nextBlink && stage.expr !== 'happy'){ stage.blinkStart = now; stage.nextBlink = now + 3000 + Math.random()*3200; }
  if (stage.blinkStart){ const t = now - stage.blinkStart; stage.blink = t < 110 ? 1 - t/110 : t < 270 ? (t - 110)/160 : 1; if (t >= 270) stage.blinkStart = 0; moving = true; }
  if (moving || stage.dirty){ stage.dirty = false; stageFrame(); }
  requestAnimationFrame(stageTick);
}
function chips(el, items, cur, onPick){
  for (const [key, label] of items){ const b = document.createElement('button'); b.type = 'button'; b.textContent = label; b.setAttribute('aria-pressed', String(key === cur));
    b.addEventListener('click', () => { el.querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', String(x === b))); onPick(key); }); el.appendChild(b); }
}

/* ---------- 規格對照與膠囊材質 ---------- */
async function specTiles(){
  const a = new Painter(document.getElementById('specOld')); a.wall(0, 3.3);
  await a.svg(T('1009', 300, 470, 400, {w: 150, wdth: 62, fill: '#46506e', op: .28, extra: 'stroke="#fff" stroke-width="2.4" stroke-opacity=".95"'}));
  const b = new Painter(document.getElementById('specNew')); b.wall(0, 3.3);
  await b.glass(T('1009', 300, 352, 452, {w: 640, wdth: 34, ls: -8}), {bevel: 14, refract: 12, frost: .7, blur: 26, lift: .28, tint: [.95, .97, 1], sat: 1.25, bright: 1.1, rim: .6, spec: .5, chroma: .06, centers: [[300, 200]]});
}
async function materialTiles(){
  const host = document.getElementById('mats');
  for (const [mat, era] of [['black', '2022 · Dynamic Island'], ['glass', '2025 · Liquid Glass'], ['smoke', '2026 · iOS 27'], ['siri', '任何年代 · 按住 F5']]){
    const fig = document.createElement('figure');
    fig.innerHTML = `<canvas class="tile" width="600" height="600" aria-label="${MAT_ZH[mat]}膠囊"></canvas><figcaption><b>${MAT_ZH[mat]}</b>　${era}</figcaption>`;
    host.appendChild(fig);
    const P = new Painter(fig.querySelector('canvas'));
    P.wall(0, 5.1); await island(P, 300, 300, 400, mat, EYE(mat === 'siri' ? 'curious' : 'idle'));
  }
}

/* ---------- 開始 ---------- */
(async () => {
  if (!GL){ document.querySelectorAll('canvas.tile').forEach(c => { c.style.background = '#888'; }); return; }
  const mk = (hostId, list, cap) => list.map(f => {
    const fig = document.createElement('figure');
    fig.innerHTML = `<canvas class="tile" width="600" height="600" aria-label="${f.title} 錶面樣稿"></canvas><figcaption><b>${f.title}</b>　${cap(f)}<br>${f.sub}</figcaption>`;
    document.getElementById(hostId).appendChild(fig); return {f, cv: fig.querySelector('canvas')};
  });
  const items = mk('faces', FACES, f => `<span class="tag">膠囊：${f.tag}</span>`);
  const retro = mk('sys6', SYS6, () => '<span class="tag">1-bit</span>');
  chips(document.getElementById('matBtns'), Object.entries(MAT_ZH), 'glass', k => { stage.mat = k; stageBase(); });
  chips(document.getElementById('exprBtns'), Object.keys(EXPR).map(k => [k, EXPR_ZH[k]]), 'idle', k => { stage.expr = k; stage.t = {...EXPR[k]}; stage.dirty = true; });
  chips(document.getElementById('bgBtns'), WALL_ZH, 2, k => { stage.wall = k; stageBase(); });
  stage.cv.addEventListener('pointermove', e => { const r = stage.cv.getBoundingClientRect();
    stage.tg = [Math.max(-1, Math.min(1, ((e.clientX - r.left)/r.width - .5)*2.4)), Math.max(-1, Math.min(1, ((e.clientY - r.top)/r.height - .66)*2.4))]; });
  stage.cv.addEventListener('pointerleave', () => { stage.tg = [stage.p.pdx/13, 0]; });
  await stageBase(); stageFrame(); requestAnimationFrame(stageTick);
  await materialTiles();
  for (const it of items){ await it.f.fn(new Painter(it.cv)); await new Promise(r => setTimeout(r, 0)); }
  for (const it of retro){ it.f.fn(new Painter(it.cv)); }
  await specTiles();
})();
