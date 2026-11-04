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

