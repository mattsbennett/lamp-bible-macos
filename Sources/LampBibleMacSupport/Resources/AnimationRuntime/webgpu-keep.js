// Lamp's animation renderer: keeps a WebGPU frame on the page's own canvas
// when work reaches it (decisions/0025). A WebGPU canvas holds its frame only
// until the frame is shown, which no signal reports and which differs by
// WebKit version, so the snapshot Lamp takes after render(t) saw the frame
// before. Here `getContext("webgpu")` hands out the context of a twin canvas
// that is never on the page; the page's canvas becomes a plain 2D canvas,
// and every twin being drawn is copied onto it in the task that submits.
(() => {
  if (!("gpu" in navigator) || typeof GPUCanvasContext === "undefined") return;
  // One registry for every frame of the page, in the top window, so a queue
  // from one frame copies a canvas drawn in another and frames agree about
  // which context a canvas gave.
  let registry;
  try {
    registry = window.top.__lampWebGPUKeep || (window.top.__lampWebGPUKeep = { twins: new Map(), kinds: new WeakMap(), transferred: new WeakSet(), drew: new Set() });
  } catch {
    registry = { twins: new Map(), kinds: new WeakMap(), transferred: new WeakSet(), drew: new Set() };
  }
  const report = (message) => { try { webkit.messageHandlers.lampError.postMessage(message); } catch {} };
  const original = HTMLCanvasElement.prototype.getContext;
  const transfer = HTMLCanvasElement.prototype.transferControlToOffscreen;
  const widthField = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, "width");
  const heightField = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, "height");
  const setAttribute = Element.prototype.setAttribute;
  const removeAttribute = Element.prototype.removeAttribute;

  // A twin, by its page canvas: { page, twin, flat (the page's 2D), context,
  // drawing (asked for this frame's texture in this task) }.
  const twinOf = (canvas) => registry.twins.get(canvas);
  const byContext = new WeakMap();

  /// The twin's frame is over: what the spec empties a canvas for. The page
  /// canvas keeps the last frame copied to it until the next is.
  const endFrame = (entry) => { entry.drawing = false; };

  /// The twin at the page canvas's size, however it was set, before a frame
  /// is drawn on it; never a copy scaled.
  const follow = (entry) => {
    const width = widthField.get.call(entry.page), height = heightField.get.call(entry.page);
    if (widthField.get.call(entry.twin) !== width) widthField.set.call(entry.twin, width);
    if (heightField.get.call(entry.twin) !== height) heightField.set.call(entry.twin, height);
  };

  /// Copies every twin being drawn onto its page canvas, now.
  const keep = () => {
    for (const entry of registry.twins.values()) {
      if (!entry.drawing) continue;
      const width = widthField.get.call(entry.twin), height = heightField.get.call(entry.twin);
      // An empty canvas has nothing to keep, and drawImage would throw.
      if (width === 0 || height === 0) continue;
      try {
        entry.flat.clearRect(0, 0, width, height);
        entry.flat.drawImage(entry.twin, 0, 0);
      } catch (error) {
        report("Lamp could not keep a WebGPU frame: " + (error && error.message || error));
      }
    }
  };

  HTMLCanvasElement.prototype.getContext = function (kind, options) {
    if (kind === "webgpu") {
      if (registry.transferred.has(this)) {
        throw new DOMException("The canvas has been transferred to an OffscreenCanvas.", "InvalidStateError");
      }
      const existing = twinOf(this);
      if (existing) return existing.context;
      const other = registry.kinds.get(this);
      if (other && other !== "webgpu") return null;
      const twin = document.createElement("canvas");
      // The page canvas's own 2D context, taken now, so the page can't take
      // another kind afterwards and the copy always has somewhere to go.
      const flat = original.call(this, "2d");
      if (!flat) return null;
      const context = original.call(twin, "webgpu", options);
      if (!context) return null;
      const entry = { page: this, twin, flat, context, drawing: false };
      Object.defineProperty(context, "canvas", { get: () => entry.page, configurable: true });
      registry.twins.set(this, entry);
      registry.kinds.set(this, "webgpu");
      registry.drew.add("webgpu");
      byContext.set(context, entry);
      follow(entry);
      return context;
    }
    // A canvas with a WebGPU context gives no other, as the browser's does.
    if (twinOf(this)) return null;
    const context = original.call(this, kind, options);
    if (context) {
      registry.kinds.set(this, kind);
      if (/^(webgl|webgl2|experimental-webgl)$/.test(kind)) registry.drew.add("webgl");
    }
    return context;
  };

  HTMLCanvasElement.prototype.transferControlToOffscreen = function () {
    // Nothing here sees what a canvas draws offscreen, so one drawing with
    // WebGPU can't be sent; and one sent gives WebGPU no more, as the
    // browser refuses. In 2D or WebGL it goes as ever.
    if (twinOf(this)) throw new DOMException("Lamp keeps no WebGPU frame drawn offscreen.", "InvalidStateError");
    const offscreen = transfer.call(this);
    registry.transferred.add(this);
    return offscreen;
  };

  // The size setters always end the frame, as they empty a canvas.
  for (const [name, field] of [["width", widthField], ["height", heightField]]) {
    Object.defineProperty(HTMLCanvasElement.prototype, name, { ...field, set(value) {
      field.set.call(this, value);
      const entry = twinOf(this);
      if (entry) { endFrame(entry); follow(entry); }
    } });
  }
  const sizeAttribute = (name) => typeof name === "string" && /^(width|height)$/i.test(name);
  Element.prototype.setAttribute = function (name, value) {
    const result = setAttribute.call(this, name, value);
    const entry = this instanceof HTMLCanvasElement && sizeAttribute(name) && twinOf(this);
    if (entry) { endFrame(entry); follow(entry); }
    return result;
  };
  Element.prototype.removeAttribute = function (name) {
    const result = removeAttribute.call(this, name);
    const entry = this instanceof HTMLCanvasElement && sizeAttribute(name) && twinOf(this);
    if (entry) { endFrame(entry); follow(entry); }
    return result;
  };

  const configure = GPUCanvasContext.prototype.configure;
  GPUCanvasContext.prototype.configure = function (descriptor) {
    const entry = byContext.get(this);
    if (entry) { endFrame(entry); follow(entry); }
    return configure.call(this, descriptor);
  };
  const unconfigure = GPUCanvasContext.prototype.unconfigure;
  GPUCanvasContext.prototype.unconfigure = function () {
    const entry = byContext.get(this);
    const result = unconfigure.call(this);
    if (entry) {
      endFrame(entry);
      entry.flat.clearRect(0, 0, widthField.get.call(entry.page), heightField.get.call(entry.page));
    }
    return result;
  };
  const currentTexture = GPUCanvasContext.prototype.getCurrentTexture;
  GPUCanvasContext.prototype.getCurrentTexture = function () {
    const entry = byContext.get(this);
    if (entry) {
      follow(entry);
      if (!entry.drawing) {
        entry.drawing = true;
        // A frame is a frame of the task that asked for its texture, as the
        // browser's own is.
        setTimeout(() => endFrame(entry), 0);
      }
    }
    return currentTexture.call(this);
  };
  // Kept wherever work reaches a texture: a submit, or a write or copy
  // straight into one.
  for (const name of ["submit", "writeTexture", "copyExternalImageToTexture"]) {
    const call = GPUQueue.prototype[name];
    if (typeof call !== "function") continue;
    GPUQueue.prototype[name] = function () {
      const result = call.apply(this, arguments);
      keep();
      return result;
    };
  }
})();
