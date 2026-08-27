(function () {
  if (document.getElementById('http-warning-banner')) return;

  const banner = document.createElement('div');
  banner.id = 'http-warning-banner';
  banner.style.cssText = [
    'position: fixed',
    'top: 0',
    'left: 0',
    'right: 0',
    'z-index: 2147483647',
    'background: #b91c1c',
    'color: #fff',
    'font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
    'font-size: 13px',
    'line-height: 1.4',
    'padding: 8px 12px',
    'display: flex',
    'align-items: center',
    'justify-content: space-between',
    'gap: 12px',
    'box-shadow: 0 2px 6px rgba(0,0,0,0.35)',
    'box-sizing: border-box',
  ].join(';');

  const label = document.createElement('span');
  label.innerHTML =
    '<strong style="margin-right:6px;background:#7f1d1d;padding:2px 6px;border-radius:3px;font-size:11px;letter-spacing:.5px">HTTP</strong>' +
    '<strong>Insecure connection</strong> — This page is not encrypted. Data sent here may be visible to others on the network.';

  const dismiss = document.createElement('button');
  dismiss.textContent = 'Dismiss';
  dismiss.style.cssText = [
    'flex-shrink: 0',
    'background: transparent',
    'border: 1px solid rgba(255,255,255,0.55)',
    'border-radius: 4px',
    'color: #fff',
    'cursor: pointer',
    'font-size: 11px',
    'padding: 2px 10px',
    'white-space: nowrap',
  ].join(';');
  dismiss.addEventListener('click', () => banner.remove());

  banner.appendChild(label);
  banner.appendChild(dismiss);
  document.body.insertBefore(banner, document.body.firstChild);

  chrome.runtime.sendMessage({ type: 'HTTP_PAGE' });
})();
