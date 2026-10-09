// Proves that the background worker runs, answers messages and can set the toolbar badge.
chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
  if (message && message.type === 'hello') { sendResponse({ ok: true }); }
});
chrome.action.setBadgeText({ text: 'ok' });
