/* Les constantes (énumérations) de chrome.* que WebKit ne définit pas : une extension écrit `chrome.declarativeNetRequest.RuleActionType.BLOCK`, pas 'block'. */
(function () {
  extend('declarativeNetRequest', {
    ResourceType: { MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other' },
    RuleActionType: { BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests' },
    HeaderOperation: { APPEND: 'append', SET: 'set', REMOVE: 'remove' },
    RequestMethod: { CONNECT: 'connect', DELETE: 'delete', GET: 'get', HEAD: 'head', OPTIONS: 'options', PATCH: 'patch', POST: 'post', PUT: 'put', OTHER: 'other' },
    DomainType: { FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty' },
    UnsupportedRegexReason: { SYNTAX_ERROR: 'syntaxError', MEMORY_LIMIT_EXCEEDED: 'memoryLimitExceeded' },
    RulesetID: { DYNAMIC: '_dynamic', SESSION: '_session', STATIC: '_static' },
    GUARANTEED_MINIMUM_STATIC_RULES: 30000, MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000, MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_SESSION_RULES: 5000,
  });
  extend('scripting', { ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN' }, StyleOrigin: { AUTHOR: 'AUTHOR', USER: 'USER' } });
  extend('cookies', { SameSiteStatus: { NO_RESTRICTION: 'no_restriction', LAX: 'lax', STRICT: 'strict', UNSPECIFIED: 'unspecified' }, OnChangedCause: { EVICTED: 'evicted', EXPIRED: 'expired', EXPLICIT: 'explicit', EXPIRED_OVERWRITE: 'expired_overwrite', OVERWRITE: 'overwrite' } });
  extend('contextMenus', { ContextType: { ALL: 'all', PAGE: 'page', FRAME: 'frame', SELECTION: 'selection', LINK: 'link', EDITABLE: 'editable', IMAGE: 'image', VIDEO: 'video', AUDIO: 'audio', LAUNCHER: 'launcher', BROWSER_ACTION: 'browser_action', PAGE_ACTION: 'page_action', ACTION: 'action' }, ItemType: { NORMAL: 'normal', CHECKBOX: 'checkbox', RADIO: 'radio', SEPARATOR: 'separator' } });
  extend('webNavigation', { TransitionType: { LINK: 'link', TYPED: 'typed', AUTO_BOOKMARK: 'auto_bookmark', AUTO_SUBFRAME: 'auto_subframe', MANUAL_SUBFRAME: 'manual_subframe', GENERATED: 'generated', START_PAGE: 'start_page', FORM_SUBMIT: 'form_submit', RELOAD: 'reload', KEYWORD: 'keyword', KEYWORD_GENERATED: 'keyword_generated' }, TransitionQualifier: { CLIENT_REDIRECT: 'client_redirect', SERVER_REDIRECT: 'server_redirect', FORWARD_BACK: 'forward_back', FROM_ADDRESS_BAR: 'from_address_bar' } });
  extend('webRequest', { ResourceType: { MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', OTHER: 'other' }, MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20, OnBeforeRequestOptions: { BLOCKING: 'blocking', REQUEST_BODY: 'requestBody', EXTRA_HEADERS: 'extraHeaders' } });
  extend('extension', { ViewType: { TAB: 'tab', POPUP: 'popup' } });
  extend('action', { UserSettings: {} });
})();
