// Mount test — bidirectional communication with microkernel
term.color("cyan");
print("=== Microkernel Mount Test ===");
term.reset();

const host = "127.0.0.1";
const port = 4200;

print("Mounting to " + host + ":" + port + "...");
const result = actor.mount(host, port);

if (!result || result === false) {
    term.color("red");
    print("Failed! Is the microkernel running?");
    print("  cd ~/dev/microkernel && ./build/tools/shell/mk-shell");
    term.reset();
} else {
    term.color("green");
    print("Node " + result.nodeId + " (" + result.identity + ")");
    term.reset();

    // Send to microkernel's console
    print("");
    term.color("yellow");
    print(">>> Sending to mk-shell console...");
    term.reset();
    actor.send("console", 0xFF000060, "\n[MiOS] Hello from the GUI shell!\n");
    actor.send("console", 0xFF000060, "[MiOS] I registered /node/mios/console — try sending back!\n");
    actor.send("console", 0xFF000060, "[MiOS] In mk-shell type: send mios-console Hello back!\n\n");

    // Poll for incoming messages (including ones to our registered actors)
    print("");
    term.color("cyan");
    print("Listening for messages (type 'quit' to stop)...");
    print("In mk-shell, send messages to mios-console to see them here.");
    term.reset();

    while (true) {
        const msg = actor.recv();
        if (msg) {
            term.color("green");
            print("<<< [0x" + msg.type.toString(16) + "] " + msg.payload);
            term.reset();
        }
        sleep(100);
    }
}
