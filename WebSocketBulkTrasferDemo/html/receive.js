(function() {
    var ws;
    var totalData = 100 * 1024 * 1024;
    var bytesReceived = 0;
    var i, t0;

    function onOpen(event) {
        alert('onOpen');
    }

    function onError(event) {
        console.log('onError');
        alert('onError');
    }

    function onClose(event) {
        console.log('onClose');
    }

    t0 = Date.now();
    ws = new WebSocket('ws://localhost:8080/video');
    ws.onopen = onOpen;
    ws.onerror = onError;
    ws.onclose = onClose;
})();

