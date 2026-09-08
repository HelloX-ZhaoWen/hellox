import Foundation

/// Installed only in the live preview; exported HTML stays a plain document.
enum MarkdownImageViewer {
    static let script = #"""
    (() => {
      const style = document.createElement('style');
      style.textContent = `
        body > :not(#hx-image-viewer) img { cursor: zoom-in; }
        #hx-image-viewer { position:fixed; inset:0; width:100vw; height:100vh;
          max-width:none; max-height:none; margin:0; padding:0; border:0;
          background:rgba(0,0,0,.93); color:white; }
        #hx-image-viewer::backdrop { background:rgba(0,0,0,.8); }
        #hx-image-viewer .hx-image-toolbar { position:absolute; top:16px; right:20px;
          display:flex; gap:12px; z-index:1; }
        #hx-image-viewer button { font:14px -apple-system,sans-serif; color:white;
          background:#333; border:1px solid #666; border-radius:8px; padding:8px 14px; cursor:pointer; }
        #hx-image-viewer button:focus-visible { outline:2px solid #009aff; outline-offset:3px; }
        #hx-image-viewer .hx-image-stage { position:absolute; inset:68px 20px 20px;
          overflow:auto; display:flex; }
        #hx-image-viewer img { display:block; flex:none; margin:auto; object-fit:contain;
          max-width:100%; max-height:100%; width:auto; height:auto; border-radius:0; cursor:zoom-in; }
        #hx-image-viewer.hx-original img { max-width:none; max-height:none; cursor:zoom-out; }
        @media print { #hx-image-viewer { display:none !important; } }
      `;
      document.head.append(style);
      const viewer = document.createElement('dialog');
      viewer.id = 'hx-image-viewer';
      viewer.setAttribute('aria-label', '图片放大查看');
      const toolbar = document.createElement('div');
      toolbar.className = 'hx-image-toolbar';
      const zoom = document.createElement('button');
      zoom.textContent = '原始尺寸';
      const close = document.createElement('button');
      close.textContent = '关闭 (Esc)';
      close.setAttribute('aria-label', '关闭图片预览');
      toolbar.append(zoom, close);
      const stage = document.createElement('div');
      stage.className = 'hx-image-stage';
      const enlarged = document.createElement('img');
      stage.append(enlarged);
      viewer.append(toolbar, stage);
      document.body.append(viewer);
      let sourceImage = null;
      let previousOverflow = '';
      const toggleZoom = () => {
        const original = viewer.classList.toggle('hx-original');
        zoom.textContent = original ? '适应窗口' : '原始尺寸';
      };
      zoom.addEventListener('click', toggleZoom);
      enlarged.addEventListener('click', toggleZoom);
      close.addEventListener('click', () => viewer.close());
      viewer.addEventListener('click', event => {
        if (event.target === viewer || event.target === stage) viewer.close();
      });
      viewer.addEventListener('keydown', event => {
        if (event.key === 'Escape') {
          event.preventDefault();
          event.stopPropagation();
          viewer.close();
        }
      });
      viewer.addEventListener('close', () => {
        document.documentElement.style.overflow = previousOverflow;
        enlarged.removeAttribute('src');
        sourceImage?.focus({preventScroll:true});
      });
      const openImage = image => {
        if (!image.complete || !image.naturalWidth || viewer.open) return;
        sourceImage = image;
        enlarged.src = image.currentSrc || image.src;
        enlarged.alt = image.alt;
        viewer.classList.remove('hx-original');
        zoom.textContent = '原始尺寸';
        previousOverflow = document.documentElement.style.overflow;
        document.documentElement.style.overflow = 'hidden';
        viewer.showModal();
        stage.scrollTop = stage.scrollLeft = 0;
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
