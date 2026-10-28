chrome.action.onClicked.addListener(() => { chrome.action.setBadgeText({ text: '7' }); });
chrome.runtime.onInstalled.addListener(() => chrome.action.setBadgeText({ text: 'ok' }));
