// Lamp's animation renderer: keeps a WebGPU frame on the page's own canvas
// when work reaches it (decisions/0025). A WebGPU canvas holds its frame only
// until the frame is shown, which no signal reports and which differs by
// WebKit version, so the snapshot Lamp takes after render(t) saw the frame
// before. Here `getContext("webgpu")` hands out the context of a twin canvas
// that is never on the page; the page's canvas becomes a plain 2D canvas,
// and a twin is copied onto it in the task that submits work drawing on it.
(() => {
  // One registry for every frame of the page, in the top window, so a queue
  // from one frame copies a canvas drawn in another and frames agree about
  // which context a canvas gave.
  const fresh = () => ({
    twins: new WeakMap(), kinds: new WeakMap(), transferred: new WeakSet(), drew: new Set(),
    byContext: new WeakMap(), canvasTexture: new WeakMap(), viewTexture: new WeakMap(), drawsOn: new WeakMap(),
  });
  let registry;
  try {
    registry = window.top.__lampWebGPUKeep || (window.top.__lampWebGPUKeep = fresh());
  } catch {
    registry = fresh();
  }
  const report = (message) => { try { webkit.messageHandlers.lampError.postMessage(message); } catch {} };
  const original = HTMLCanvasElement.prototype.getContext;
  const webGL = /^(webgl|webgl2|experimental-webgl)$/;

  // Where the web view has no WebGPU, only what drew is noted.
  if (!("gpu" in navigator) || typeof GPUCanvasContext === "undefined") {
    HTMLCanvasElement.prototype.getContext = function (kind, options) {
      const context = original.call(this, kind, options);
      if (context && webGL.test(kind)) registry.drew.add("webgl");
      return context;
    };
    return;
  }

  const transfer = HTMLCanvasElement.prototype.transferControlToOffscreen;
  const widthField = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, "width");
  const heightField = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, "height");
  const setAttribute = Element.prototype.setAttribute;
  const removeAttribute = Element.prototype.removeAttribute;

  // A twin, by its page canvas: { page, twin, flat (the page's 2D), context,
  // texture (this frame's, once asked for) }. Held weakly, so a canvas the
  // page drops goes with its twin.
  const twinOf = (canvas) => registry.twins.get(canvas);
  // This frame's canvas textures, to their twins, and the textures each view
  // and each command buffer drew on: shared by every frame of the page, so a
  // device in one drawing on a canvas in another is seen.
  const { byContext, canvasTexture, viewTexture, drawsOn } = registry;

  /// The twin's frame is over: what the spec empties a canvas for. The page
  /// canvas keeps the last frame copied to it until the next is.
  const endFrame = (entry) => {
    if (entry.texture) canvasTexture.delete(entry.texture);
    entry.texture = null;
  };

  /// The twin at the page canvas's size, however it was set, before a frame
  /// is drawn on it; never a copy scaled. `always` sets it even at the same
  /// size, as an assignment does, which resets a canvas.
  const follow = (entry, always = false) => {
    const width = widthField.get.call(entry.page), height = heightField.get.call(entry.page);
    if (always || widthField.get.call(entry.twin) !== width) widthField.set.call(entry.twin, width);
    if (always || heightField.get.call(entry.twin) !== height) heightField.set.call(entry.twin, height);
  };

  const clearPage = (entry) => {
    entry.flat.clearRect(0, 0, widthField.get.call(entry.page), heightField.get.call(entry.page));
  };

  /// Copies a twin onto its page canvas, now: only one whose current
  /// texture work has just reached, since a read of a canvas before it is
  /// drawn can be all a later read gets in that frame.
  const keep = (entry) => {
    const width = widthField.get.call(entry.twin), height = heightField.get.call(entry.twin);
    // An empty canvas has nothing to keep, and drawImage would throw.
    if (width === 0 || height === 0) return;
    try {
      entry.flat.clearRect(0, 0, width, height);
      entry.flat.drawImage(entry.twin, 0, 0);
    } catch (error) {
      report("Lamp could not keep a WebGPU frame: " + (error && error.message || error));
    }
  };
  const keepTexture = (texture) => {
    const entry = texture && canvasTexture.get(texture);
    if (entry) keep(entry);
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
      const entry = { page: this, twin, flat, context, texture: null };
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
      if (webGL.test(kind)) registry.drew.add("webgl");
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
  // Nor one drawn on an offscreen canvas in the page: what it draws reaches
  // no snapshot.
  if (typeof OffscreenCanvas !== "undefined") {
    const offscreenContext = OffscreenCanvas.prototype.getContext;
    OffscreenCanvas.prototype.getContext = function (kind, options) {
      if (kind === "webgpu") {
        const message = "Lamp keeps no WebGPU frame drawn on an OffscreenCanvas: draw on a canvas in the page, "
          + "or make the video another way and bring it in with prepare_video.";
        report(message);
        throw new DOMException(message, "NotSupportedError");
      }
      const context = offscreenContext.call(this, kind, options);
      if (context && webGL.test(kind)) registry.drew.add("webgl");
      return context;
    };
  }

  // The size setters always end the frame, as they empty a canvas, the same
  // size given again included.
  for (const [name, field] of [["width", widthField], ["height", heightField]]) {
    Object.defineProperty(HTMLCanvasElement.prototype, name, { ...field, set(value) {
      field.set.call(this, value);
      const entry = twinOf(this);
      if (entry) { endFrame(entry); follow(entry, true); }
    } });
  }
  const sizeAttribute = (name) => typeof name === "string" && /^(width|height)$/i.test(name);
  Element.prototype.setAttribute = function (name, value) {
    const result = setAttribute.call(this, name, value);
    const entry = this instanceof HTMLCanvasElement && sizeAttribute(name) && twinOf(this);
    if (entry) { endFrame(entry); follow(entry, true); }
    return result;
  };
  Element.prototype.removeAttribute = function (name) {
    const result = removeAttribute.call(this, name);
    const entry = this instanceof HTMLCanvasElement && sizeAttribute(name) && twinOf(this);
    if (entry) { endFrame(entry); follow(entry, true); }
    return result;
  };

  const configure = GPUCanvasContext.prototype.configure;
  GPUCanvasContext.prototype.configure = function (descriptor) {
    const entry = byContext.get(this);
    // A compute shader writing straight into the canvas reaches nothing Lamp
    // follows, so a canvas set up for it is refused by name.
    if (entry && descriptor && (descriptor.usage & GPUTextureUsage.STORAGE_BINDING)) {
      const message = "Lamp keeps no WebGPU frame a compute shader writes into the canvas: write to a texture of "
        + "your own and draw it onto the canvas with a render pass.";
      report(message);
      throw new DOMException(message, "NotSupportedError");
    }
    if (entry) { endFrame(entry); follow(entry); }
    const result = configure.call(this, descriptor);
    // Configuring empties the canvas, as the spec has it.
    if (entry) clearPage(entry);
    return result;
  };
  const unconfigure = GPUCanvasContext.prototype.unconfigure;
  GPUCanvasContext.prototype.unconfigure = function () {
    const entry = byContext.get(this);
    const result = unconfigure.call(this);
    if (entry) { endFrame(entry); clearPage(entry); }
    return result;
  };
  const currentTexture = GPUCanvasContext.prototype.getCurrentTexture;
  GPUCanvasContext.prototype.getCurrentTexture = function () {
    const entry = byContext.get(this);
    if (entry && !entry.texture) follow(entry);
    const texture = currentTexture.call(this);
    if (entry && entry.texture !== texture) {
      if (entry.texture) canvasTexture.delete(entry.texture);
      entry.texture = texture;
      canvasTexture.set(texture, entry);
      // A frame is a frame of the task that asked for its texture, as the
      // browser's own is.
      setTimeout(() => { if (entry.texture === texture) endFrame(entry); }, 0);
    }
    return texture;
  };

  // Which textures work draws on: a view knows its texture; a pass, its
  // attachments; an encoder, its passes and copies; a command buffer, its
  // encoder's.
  const createView = GPUTexture.prototype.createView;
  GPUTexture.prototype.createView = function (descriptor) {
    const view = createView.call(this, descriptor);
    if (canvasTexture.has(this)) viewTexture.set(view, this);
    return view;
  };
  const note = (encoder, texture) => {
    if (!texture || !canvasTexture.has(texture)) return;
    let set = drawsOn.get(encoder);
    if (!set) drawsOn.set(encoder, set = new Set());
    set.add(texture);
  };
  // A view, or a texture given as one, which newer WebKit takes.
  const textureOf = (target) => target && (viewTexture.get(target) || (canvasTexture.has(target) ? target : null));
  const beginRenderPass = GPUCommandEncoder.prototype.beginRenderPass;
  GPUCommandEncoder.prototype.beginRenderPass = function (descriptor) {
    // Read once, and handed on as read: a sequence may be an iterator.
    if (descriptor && descriptor.colorAttachments && !Array.isArray(descriptor.colorAttachments)) {
      descriptor = { ...descriptor, colorAttachments: Array.from(descriptor.colorAttachments) };
    }
    for (const attachment of (descriptor && descriptor.colorAttachments) || []) {
      if (!attachment) continue;
      note(this, textureOf(attachment.view));
      note(this, textureOf(attachment.resolveTarget));
    }
    return beginRenderPass.call(this, descriptor);
  };
  for (const name of ["copyTextureToTexture", "copyBufferToTexture"]) {
    const call = GPUCommandEncoder.prototype[name];
    if (typeof call !== "function") continue;
    GPUCommandEncoder.prototype[name] = function (source, destination) {
      note(this, destination && destination.texture);
      return call.apply(this, arguments);
    };
  }
  const finish = GPUCommandEncoder.prototype.finish;
  GPUCommandEncoder.prototype.finish = function (descriptor) {
    const buffer = finish.call(this, descriptor);
    const textures = drawsOn.get(this);
    if (textures) drawsOn.set(buffer, textures);
    return buffer;
  };

  // Kept where work reaches a canvas's texture: a submit of buffers drawing
  // on one, or a write or copy straight into one.
  const queue = GPUQueue.prototype;
  const submit = queue.submit;
  queue.submit = function (buffers) {
    buffers = Array.from(buffers || []);
    const result = submit.call(this, buffers);
    const reached = new Set();
    for (const buffer of buffers) for (const texture of drawsOn.get(buffer) || []) reached.add(texture);
    for (const texture of reached) keepTexture(texture);
    return result;
  };
  const writeTexture = queue.writeTexture;
  if (typeof writeTexture === "function") {
    queue.writeTexture = function (destination) {
      const result = writeTexture.apply(this, arguments);
      keepTexture(destination && destination.texture);
      return result;
    };
  }
  const copyExternal = queue.copyExternalImageToTexture;
  if (typeof copyExternal === "function") {
    queue.copyExternalImageToTexture = function (source, destination) {
      const result = copyExternal.apply(this, arguments);
      keepTexture(destination && destination.texture);
      return result;
    };
  }
})();
