(function() {
    var xhr = new XMLHttpRequest();
    var totalData = 100 * 1024 * 1024;
    var bytesReceived = 0;
    var i, t0;
    var NUM_PIPELINE = 10;

    function onError(event) {
        console.log('onError');
    }

    function onAbort(event) {
        console.log('onAbort');
    }

    function stateChange() {
        var past, bps;
        if (xhr.readyState == 4 && xhr.status == 200) {
            bytesReceived += xhr.response.byteLength;
            if (bytesReceived < totalData) {
                xhr.open('GET', 'http://localhost:8080/video', true);
                xhr.send();
            } else {
                past = (Date.now() - t0) / 1000.0;
                bps = bytesReceived * 8 / past;
                alert((bps / 1000.0) + ' kbps');
            }
        }
    }

    t0 = Date.now();
    xhr.onreadystatechange = stateChange;
    xhr.addEventListener('error', onError, false);
    xhr.addEventListener('abort', onAbort, false);
    xhr.responseType = 'arraybuffer';
    for (i = 0; i < NUM_PIPELINE; i++) {
        xhr.open('GET', 'http://localhost:8080/video', true);
        xhr.send();
    }
})();

