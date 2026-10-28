import { mark } from './lib.js';
chrome.action.onClicked.addListener(async (tab) => { await chrome.action.setBadgeText({ text: mark(tab && tab.id ? 'M' : 'X') }); });
