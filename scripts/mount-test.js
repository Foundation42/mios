// Mount test — connect to real microkernel via mount protocol
term.color("cyan");
print("=== Microkernel Mount Test ===");
term.reset();

const host = "127.0.0.1";
const port = 4200;

print("Mounting to " + host + ":" + port + "...");
const result = actor.mount(host, port);

if (!result || result === false) {
    term.color("red");
    print("Failed! Is the microkernel running? (cd ~/dev/microkernel && ./build/tools/shell/mk-shell)");
    term.reset();
} else {
    term.color("green");
    print("Connected! Node ID: " + result.nodeId + ", Identity: " + result.identity);
    term.reset();

    // Try sending a log message
    print("");
    term.color("yellow");
    print("Sending MSG_LOG to node...");
    term.reset();

    // MSG_LOG = 0xFF000003, send to actor_id_make(result.nodeId, 1) = the runtime
    const dest = result.nodeId * 0x100000000 + 1;  // node_id << 32 | seq 1
    actor.send(dest, 0xFF000003, "Hello from MiOS!");

    // Try to receive any messages
    sleep(200);
    let msg = actor.recv();
    let count = 0;
    while (msg) {
        term.color("green");
        print("Recv: src=" + msg.source + " type=0x" + msg.type.toString(16) + " payload=\"" + msg.payload + "\"");
        term.reset();
        count++;
        msg = actor.recv();
    }

    if (count === 0) {
        term.color("dim");
        print("(no messages received — that's ok, log messages are fire-and-forget)");
        term.reset();
    }

    print("");
    term.color("cyan");
    print("Mount test complete! Bridge is live.");
    term.reset();
}
