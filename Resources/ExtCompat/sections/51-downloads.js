/* chrome.downloads : les téléchargements d'Orée. */
(function () {
  const N = native;
  extend('downloads', {
    State: { IN_PROGRESS: 'in_progress', INTERRUPTED: 'interrupted', COMPLETE: 'complete' },
    DangerType: { FILE: 'file', URL: 'url', CONTENT: 'content', UNCOMMON: 'uncommon', HOST: 'host', UNWANTED: 'unwanted', SAFE: 'safe', ACCEPTED: 'accepted' },
    FilenameConflictAction: { UNIQUIFY: 'uniquify', OVERWRITE: 'overwrite', PROMPT: 'prompt' },
    InterruptReason: { FILE_FAILED: 'FILE_FAILED', NETWORK_FAILED: 'NETWORK_FAILED', USER_CANCELED: 'USER_CANCELED' },
    HttpMethod: { GET: 'GET', POST: 'POST' },
    download: api((options = {}) => N('downloads.download', options)),
    search: api((query = {}) => N('downloads.search', query)),
    pause: api((id) => N('downloads.pause', { id })),
    resume: api((id) => N('downloads.resume', { id })),
    cancel: api((id) => N('downloads.cancel', { id })),
    erase: api((query = {}) => N('downloads.erase', query)),
    removeFile: api((id) => N('downloads.removeFile', { id })),
    open: api((id) => N('downloads.open', { id })),
    show: api((id) => N('downloads.show', { id })),
    showDefaultFolder: () => { N('downloads.showDefaultFolder').catch(() => {}); },
    acceptDanger: api(async () => {}), setShelfEnabled: () => {}, setUiOptions: api(async () => {}),
    getFileIcon: unsupported('downloads.getFileIcon()'), drag: () => {},
    onCreated: nativeEvent('downloads.onCreated'), onChanged: nativeEvent('downloads.onChanged'), onErased: nativeEvent('downloads.onErased'), onDeterminingFilename: makeEvent(),
  });
})();
