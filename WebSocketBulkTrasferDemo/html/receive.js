(function() {
    var ws;
    var t0;
    var totalData = 100 * 1024 * 1024;
    var bytesReceived = 0;

    function onOpen(event) {
        console.log('onOpen');
    }

    function onMessage(event) {
        var past, bps;
        bytesReceived += event.data.byteLength;
        document.getElementById('progress').textContent = bytesReceived + ' received';
        if (totalData < bytesReceived) {
            past = (Date.now() - t0) / 1000.0;
            t0 = Date.now();
            bps = bytesReceived * 8 / past;
            bytesReceived = 0;
            document.getElementById('bps').textContent = (bps / (1000.0 * 1000.0)) + ' Mbps';
        }
    }

    function onError(event) {
        console.log('onError');
    }

    function onClose(event) {
        console.log('onClose');
    }

    t0 = Date.now();
    ws = new WebSocket('ws://localhost:8080/video');
    ws.binaryType = 'arraybuffer';
    ws.onopen = onOpen;
    ws.onmessage = onMessage;
    ws.onerror = onError;
    ws.onclose = onClose;
})();

