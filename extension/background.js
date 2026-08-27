const RED = '#b91c1c';

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message.type === 'HTTP_PAGE' && sender.tab) {
    chrome.action.setBadgeText({ text: 'HTTP', tabId: sender.tab.id });
    chrome.action.setBadgeBackgroundColor({ color: RED, tabId: sender.tab.id });
  }
});

// Clear badge when the tab navigates away from an HTTP URL
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'loading' && tab.url && !tab.url.startsWith('http://')) {
    chrome.action.setBadgeText({ text: '', tabId });
  }
});
