import AppKit
import WebKit

/// Installed only in the live preview; exported HTML stays a plain document.
enum MarkdownImageViewer {
    static let script = #"""
    (() => {
      const style = document.createElement('style');
      style.textContent = `
        body > :not(#hx-image-viewer) img { cursor: zoom-in; }
        #hx-image-viewer { position:fixed; inset:0; width:100vw; height:100vh;
          max-width:none; max-height:none; margin:0; padding:0; border:0;
          overflow:hidden; background:transparent; color:#fff; color-scheme:dark; }
        #hx-image-viewer::backdrop { background:rgba(0,0,0,.76); }
        #hx-image-viewer button { display:inline-flex; align-items:center; justify-content:center;
          flex:none; width:34px; height:34px; padding:0; border:0; border-radius:5px;
          font:13px -apple-system,sans-serif; color:#fff; background:transparent; cursor:pointer; }
        #hx-image-viewer button:hover { background:rgba(255,255,255,.16); }
        #hx-image-viewer button:disabled { opacity:.3; cursor:default; background:transparent; }
        #hx-image-viewer button:focus-visible { outline:2px solid rgba(255,255,255,.45); outline-offset:2px; }
        #hx-image-viewer button svg { width:19px; height:19px; fill:none; stroke:currentColor;
          stroke-width:1.6; stroke-linecap:round; stroke-linejoin:round; }
        #hx-image-viewer .hx-image-close { position:absolute; top:16px; right:16px;
          width:44px; height:44px; border-radius:50%; background:rgba(25,25,25,.8); z-index:2; }
        #hx-image-viewer .hx-image-close:focus { outline:none; box-shadow:none; }
        #hx-image-viewer .hx-image-toolbar { position:absolute; bottom:20px; left:50%;
          transform:translateX(-50%); display:flex; align-items:center; gap:4px;
          max-width:calc(100% - 24px); padding:7px 10px; border-radius:7px;
          background:rgba(28,28,28,.85); box-shadow:0 4px 20px rgba(0,0,0,.18);
          backdrop-filter:blur(16px); -webkit-backdrop-filter:blur(16px); z-index:2; }
        #hx-image-viewer .hx-image-counter, #hx-image-viewer .hx-image-scale {
          min-width:48px; text-align:center; white-space:nowrap; font:13px -apple-system,sans-serif;
          font-variant-numeric:tabular-nums; }
        #hx-image-viewer .hx-image-separator { width:1px; height:20px;
          margin:0 5px; background:rgba(255,255,255,.24); }
        #hx-image-viewer .hx-image-stage { position:absolute; inset:48px 48px 80px;
          overflow:hidden; touch-action:none; }
        #hx-image-viewer img { position:absolute; left:50%; top:50%; display:block;
          margin:0; max-width:none; max-height:none; border-radius:0; user-select:none;
          -webkit-user-drag:none; transform-origin:center; cursor:zoom-in; }
        #hx-image-viewer.hx-pannable img { cursor:grab; }
        #hx-image-viewer.hx-dragging img { cursor:grabbing; }
        @media(max-width:480px) {
          #hx-image-viewer .hx-image-stage { inset:64px 12px 80px; }
          #hx-image-viewer .hx-image-toolbar { gap:0; padding:6px; }
          #hx-image-viewer .hx-image-separator { margin:0 2px; }
        }
        @media print { #hx-image-viewer { display:none !important; } }
      `;
      document.head.append(style);
      const viewer = document.createElement('dialog');
      viewer.id = 'hx-image-viewer';
      viewer.setAttribute('aria-label', '图片放大查看');
      const stage = document.createElement('div');
      stage.className = 'hx-image-stage';
      const enlarged = document.createElement('img');
      enlarged.draggable = false;
      stage.append(enlarged);
      const toolbar = document.createElement('div');
      toolbar.className = 'hx-image-toolbar';
      toolbar.setAttribute('role', 'toolbar');
      toolbar.setAttribute('aria-label', '图片查看工具');
      const button = (action, label, paths) => {
        const element = document.createElement('button');
        element.type = 'button';
        element.dataset.action = action;
        element.title = label;
        element.setAttribute('aria-label', label);
        element.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + paths + '</svg>';
        return element;
      };
      const close = button('close', '关闭图片预览 (Esc)', '<path d="m6 6 12 12M18 6 6 18"/>');
      close.className = 'hx-image-close';
      const previous = button('previous', '上一张 (←)', '<path d="m14 5-7 7 7 7"/>');
      const next = button('next', '下一张 (→)', '<path d="m10 5 7 7-7 7"/>');
      const counter = document.createElement('span');
      counter.className = 'hx-image-counter';
      counter.setAttribute('aria-live', 'polite');
      const zoomOut = button('zoom-out', '缩小 (-)', '<circle cx="10" cy="10" r="7"/><path d="m15 15 6 6M7 10h6"/>');
      const zoomIn = button('zoom-in', '放大 (+)', '<circle cx="10" cy="10" r="7"/><path d="m15 15 6 6M7 10h6M10 7v6"/>');
      const scaleLabel = button('fit', '适应窗口 (0)', '');
      scaleLabel.className = 'hx-image-scale';
      const original = button('original', '原始尺寸 (1:1)', '<rect x="2" y="5" width="20" height="14" rx="1"/><path d="M7 9v6M17 9v6M12 10v.1M12 14v.1"/>');
      const rotate = button('rotate', '顺时针旋转 90°', '<rect x="4" y="10" width="10" height="10" rx="1"/><path d="M8 6a8 8 0 0 1 12 7M20 5v8h-5"/>');
      const separator = () => {
        const element = document.createElement('span');
        element.className = 'hx-image-separator';
        element.setAttribute('aria-hidden', 'true');
        return element;
      };
      toolbar.append(previous, counter, next, separator(), zoomOut, scaleLabel, zoomIn,
                     original, separator(), rotate);
      viewer.append(stage, close, toolbar);
      document.body.append(viewer);
      let images = [], sourceImage = null, returnFocus = null, index = 0;
      let previousOverflow = '', scale = 1, rotation = 0, panX = 0, panY = 0;
      let fitsWindow = true, drag = null, suppressClick = false;
      const dimensions = () => rotation % 180 === 0
        ? [sourceImage.naturalWidth, sourceImage.naturalHeight]
        : [sourceImage.naturalHeight, sourceImage.naturalWidth];
      const fitScale = () => {
        const [width, height] = dimensions();
        return Math.min(1, stage.clientWidth / width, stage.clientHeight / height);
      };
      const update = () => {
        const [width, height] = dimensions();
        const limitX = Math.max(0, (width * scale - stage.clientWidth) / 2);
        const limitY = Math.max(0, (height * scale - stage.clientHeight) / 2);
        panX = Math.max(-limitX, Math.min(limitX, panX));
        panY = Math.max(-limitY, Math.min(limitY, panY));
        enlarged.style.width = sourceImage.naturalWidth + 'px';
        enlarged.style.height = sourceImage.naturalHeight + 'px';
        enlarged.style.transform = `translate(-50%, -50%) translate(${panX}px, ${panY}px) rotate(${rotation}deg) scale(${scale})`;
        scaleLabel.textContent = Math.round(scale * 100) + '%';
        viewer.classList.toggle('hx-original', scale === 1);
        viewer.classList.toggle('hx-pannable', limitX > 0 || limitY > 0);
        zoomOut.disabled = scale <= Math.min(.1, fitScale());
        zoomIn.disabled = scale >= 8;
      };
      const fit = () => {
        fitsWindow = true;
        scale = fitScale();
        panX = panY = 0;
        update();
      };
      const setScale = value => {
        fitsWindow = false;
        scale = Math.max(Math.min(.1, fitScale()), Math.min(8, value));
        update();
      };
      const show = newIndex => {
        if (newIndex < 0 || newIndex >= images.length) return;
        index = newIndex;
        sourceImage = images[index];
        enlarged.src = sourceImage.currentSrc || sourceImage.src;
        enlarged.alt = sourceImage.alt;
        rotation = 0;
        counter.textContent = `${index + 1}/${images.length}`;
        previous.disabled = index === 0;
        next.disabled = index === images.length - 1;
        fit();
      };
      previous.addEventListener('click', () => show(index - 1));
      next.addEventListener('click', () => show(index + 1));
      zoomOut.addEventListener('click', () => setScale(scale / 1.25));
      zoomIn.addEventListener('click', () => setScale(scale * 1.25));
      scaleLabel.addEventListener('click', fit);
      original.addEventListener('click', () => setScale(1));
      rotate.addEventListener('click', () => {
        rotation = (rotation + 90) % 360;
        panX = panY = 0;
        if (fitsWindow) fit(); else update();
      });
      enlarged.addEventListener('click', () => {
        if (suppressClick) { suppressClick = false; return; }
        if (fitsWindow) setScale(1); else fit();
      });
      stage.addEventListener('pointerdown', event => {
        if (event.target !== enlarged || event.button !== 0) return;
        suppressClick = false;
        drag = {id:event.pointerId, x:event.clientX, y:event.clientY, panX, panY};
        enlarged.setPointerCapture(event.pointerId);
      });
      stage.addEventListener('pointermove', event => {
        if (!drag || event.pointerId !== drag.id) return;
        const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
        if (Math.abs(dx) + Math.abs(dy) > 4) suppressClick = true;
        if (!suppressClick) return;
        viewer.classList.add('hx-dragging');
        panX = drag.panX + dx;
        panY = drag.panY + dy;
        update();
      });
      const endDrag = () => { drag = null; viewer.classList.remove('hx-dragging'); };
      stage.addEventListener('pointerup', event => {
        if (enlarged.hasPointerCapture(event.pointerId)) enlarged.releasePointerCapture(event.pointerId);
        endDrag();
      });
      stage.addEventListener('pointercancel', endDrag);
      stage.addEventListener('wheel', event => {
        event.preventDefault();
        setScale(scale * Math.exp(-Math.max(-100, Math.min(100, event.deltaY)) * .005));
      }, {passive:false});
      close.addEventListener('click', () => viewer.close());
      viewer.addEventListener('click', event => {
        if (suppressClick) { suppressClick = false; return; }
        if (event.target === viewer || event.target === stage) viewer.close();
      });
      viewer.addEventListener('keydown', event => {
        if (event.metaKey || event.ctrlKey || event.altKey) return;
        const actions = {
          Escape: () => viewer.close(), ArrowLeft: () => show(index - 1),
          ArrowRight: () => show(index + 1), '+': () => setScale(scale * 1.25),
          '=': () => setScale(scale * 1.25), '-': () => setScale(scale / 1.25),
          '0': fit, '1': () => setScale(1)
        };
        if (!actions[event.key]) return;
        event.preventDefault();
        event.stopPropagation();
        actions[event.key]();
      });
      viewer.addEventListener('close', () => {
        // A close event can arrive after a new image has already been opened.
        if (viewer.open) return;
        document.documentElement.style.overflow = previousOverflow;
        enlarged.removeAttribute('src');
        endDrag();
        returnFocus?.focus({preventScroll:true});
        window.webkit?.messageHandlers.hxCloseImageViewer?.postMessage(null);
      });
      window.addEventListener('resize', () => {
        if (!viewer.open) return;
        if (fitsWindow) fit(); else update();
      });
      window.hxOpenImageGallery = gallery => {
        images = gallery.images;
        suppressClick = false;
        previousOverflow = document.documentElement.style.overflow;
        document.documentElement.style.overflow = 'hidden';
        viewer.showModal();
        show(gallery.index);
        close.focus();
      };
      const openImage = image => {
        if (!image.complete || !image.naturalWidth || viewer.open) return;
        images = Array.from(document.querySelectorAll('body img')).filter(item =>
          !viewer.contains(item) && item.complete && item.naturalWidth > 0);
        returnFocus = image;
        if (window.hxUsesWindowImageViewer) {
          image.focus({preventScroll:true});
          window.webkit.messageHandlers.hxOpenImageViewer.postMessage({
            index: images.indexOf(image),
            images: images.map(item => ({src:item.currentSrc || item.src, alt:item.alt,
              naturalWidth:item.naturalWidth, naturalHeight:item.naturalHeight}))
          });
          return;
        }
        suppressClick = false;
        previousOverflow = document.documentElement.style.overflow;
        document.documentElement.style.overflow = 'hidden';
        viewer.showModal();
        show(images.indexOf(image));
        close.focus();
      };
      document.querySelectorAll('body img').forEach(image => {
        if (viewer.contains(image)) return;
        image.tabIndex = 0;
        image.setAttribute('role', 'button');
        image.setAttribute('aria-label', image.alt ? '放大查看：' + image.alt : '放大查看图片');
        image.addEventListener('click', event => {
          event.preventDefault();
          event.stopPropagation();
          openImage(image);
        });
        image.addEventListener('keydown', event => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            event.stopPropagation();
            openImage(image);
          }
        });
      });
    })();
    """#
}

/// The document preview only sends image metadata. The viewer itself belongs to
/// the window, so SwiftUI's clipped document column cannot clip the overlay.
@MainActor
final class MarkdownPreviewWebView: WKWebView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateImageViewerScope()
    }

    func updateImageViewerScope() {
        evaluateJavaScript("window.hxUsesWindowImageViewer = \(window != nil ? "true" : "false");")
    }
}

@MainActor
final class MarkdownImageMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class MarkdownWindowImageOverlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var webView: WKWebView?
    private(set) var container: NSView?
    private weak var hostWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var windowButtons: [(NSButton, Bool)] = []
    private var gallery: [String: Any]?

    func present(gallery: [String: Any], in window: NSWindow, source: WKWebView, baseURL: URL?) {
        guard let contentView = window.contentView,
              let images = gallery["images"] as? [[String: Any]], !images.isEmpty,
              let index = gallery["index"] as? Int, images.indices.contains(index),
              images.allSatisfy({ image in
                  guard let src = image["src"] as? String, URL(string: src) != nil,
                        let width = image["naturalWidth"] as? Double,
                        let height = image["naturalHeight"] as? Double else { return false }
                  return width.isFinite && height.isFinite && width > 0 && height > 0
              }) else { return }
        dismiss()
        hostWindow = window
        previousResponder = window.firstResponder ?? source
        self.gallery = gallery
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let imageHandler = MarkdownLocalImageSchemeHandler()
        imageHandler.setAllowedDirectory(baseURL)
        configuration.setURLSchemeHandler(imageHandler, forURLScheme: MarkdownLocalImageScheme.name)
        configuration.userContentController.addUserScript(WKUserScript(
            source: MarkdownImageViewer.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        configuration.userContentController.add(MarkdownImageMessageHandler(target: self), name: "hxCloseImageViewer")
        let overlay = NSView(frame: contentView.bounds)
        overlay.identifier = NSUserInterfaceItemIdentifier("MarkdownWindowImageOverlay")
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        let viewer = WKWebView(frame: overlay.bounds, configuration: configuration)
        viewer.autoresizingMask = [.width, .height]
        viewer.setValue(false, forKey: "drawsBackground")
        viewer.underPageBackgroundColor = .clear
        viewer.navigationDelegate = self
        overlay.addSubview(viewer)
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        container = overlay
        webView = viewer
        windowButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let button = window.standardWindowButton(type) else { return nil }
            let state = (button, button.isHidden)
            button.isHidden = true
            return state
        }
        NotificationCenter.default.addObserver(self, selector: #selector(dismiss), name: NSWindow.willCloseNotification, object: window)
        window.makeFirstResponder(viewer)
        // Native dimming covers the whole window immediately, including while the
        // selected image loads. Only the selected image is requested by this page.
        viewer.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:transparent;overflow:hidden}
        #hx-image-viewer::backdrop{background:transparent !important}</style>
        </head><body></body></html>
        """, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let gallery else { return }
        webView.callAsyncJavaScript("window.hxOpenImageGallery(gallery);", arguments: ["gallery": gallery], in: nil, in: .page) { [weak self] result in
            if case .failure = result { self?.dismiss() }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame else { return }
        dismiss()
    }

    @objc func dismiss() {
        if let hostWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: hostWindow)
        }
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "hxCloseImageViewer")
        container?.removeFromSuperview()
        windowButtons.forEach { button, wasHidden in button.isHidden = wasHidden }
        if let previousResponder { hostWindow?.makeFirstResponder(previousResponder) }
        webView = nil
        container = nil
        gallery = nil
        windowButtons = []
        hostWindow = nil
        previousResponder = nil
    }
}
