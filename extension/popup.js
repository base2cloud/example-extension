chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
  const urlEl = document.getElementById('url');
  const statusEl = document.getElementById('status');
  const iconEl = document.getElementById('icon');
  const labelEl = document.getElementById('label');
  const detailEl = document.getElementById('detail');

  if (!tab || !tab.url) return;

  urlEl.textContent = tab.url;

  if (tab.url.startsWith('http://')) {
    statusEl.classList.add('insecure');
    iconEl.textContent = '⚠️';
    labelEl.textContent = 'Insecure Connection (HTTP)';
    detailEl.textContent =
      'This page is not encrypted. Data you submit — passwords, form fields — may be visible to others on the network.';
  } else {
    statusEl.classList.add('secure');
    iconEl.textContent = '✅';
    labelEl.textContent = 'Secure Connection (HTTPS)';
    detailEl.textContent = 'Traffic to this page is encrypted. Your data is protected in transit.';
  }
});
