// Canvas text sprites for villa and resident names. System fonts only, so nothing is fetched.
import * as THREE from 'three';

const FONT_PX = 44;
const FONT = `600 ${FONT_PX}px system-ui, -apple-system, "PingFang SC", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif`;

function pill(ctx, x, y, w, h) {
  const r = h / 2;
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.arc(x + w - r, y + r, r, -Math.PI / 2, Math.PI / 2);
  ctx.lineTo(x + r, y + h);
  ctx.arc(x + r, y + r, r, Math.PI / 2, (Math.PI * 3) / 2);
  ctx.closePath();
}

/** A camera-facing name tag, `height` world units tall before any parent scale. */
export function makeLabel(text, { height = 0.3, color = '#2d3b48', background = 'rgba(255,255,255,0.88)', accent = null } = {}) {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  ctx.font = FONT;
  const pad = 24;
  const h = FONT_PX + 28;
  const w = Math.max(h, Math.ceil(Math.min(ctx.measureText(text).width, 1200)) + pad * 2);
  canvas.width = w;
  canvas.height = h;
  ctx.font = FONT; // resizing the canvas resets the context state
  ctx.fillStyle = background;
  pill(ctx, 0, 0, w, h);
  ctx.fill();
  if (accent) {
    ctx.lineWidth = 5;
    ctx.strokeStyle = accent;
    pill(ctx, 2.5, 2.5, w - 5, h - 5);
    ctx.stroke();
  }
  ctx.fillStyle = color;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, w / 2, h / 2 + 2);

  const map = new THREE.CanvasTexture(canvas);
  map.colorSpace = THREE.SRGBColorSpace;
  map.minFilter = THREE.LinearFilter;
  map.generateMipmaps = false;
  // Tags keep their exact colours: no tone mapping and no fog at the far end of the street.
  const material = new THREE.SpriteMaterial({ map, transparent: true, depthWrite: false, toneMapped: false, fog: false });
  const sprite = new THREE.Sprite(material);
  sprite.scale.set((height * w) / h, height, 1);
  sprite.renderOrder = 10;
  sprite.userData.text = text;
  sprite.userData.dispose = () => {
    map.dispose();
    material.dispose();
  };
  return sprite;
}
